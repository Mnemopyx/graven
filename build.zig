const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // HarfBuzz, from its single-file amalgamation, built with zig c++ so it
    // shares Zig's C++ runtime (libc++).
    const hb_src = b.dependency("harfbuzz", .{}).path("src");
    const harfbuzz = b.addLibrary(.{
        .name = "harfbuzz",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    harfbuzz.root_module.addCSourceFile(.{
        .file = hb_src.path(b, "harfbuzz.cc"),
        .flags = &.{ "-std=c++17", "-DHB_NO_FEATURES_H", "-fno-exceptions", "-fno-rtti" },
    });
    // Zig 0.17 has no @cImport: HarfBuzz's headers become a module here.
    const hb_c = b.addTranslateC(.{ .root_source_file = b.path("lib/hb/hb.h"), .target = target, .optimize = optimize });
    hb_c.addIncludePath(hb_src);
    hb_c.defineCMacro("HB_NO_FEATURES_H", null);
    const hb = hb_c.createModule();
    hb.linkLibrary(harfbuzz);

    // Brotli's decoder (C), for WOFF2 fonts.
    const brotli_src = b.dependency("brotli", .{}).path("c");
    const brotli_dec = b.addLibrary(.{
        .name = "brotlidec",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    brotli_dec.root_module.addIncludePath(brotli_src.path(b, "include"));
    brotli_dec.root_module.addCSourceFiles(.{
        .root = brotli_src,
        .files = &.{
            "common/constants.c",     "common/context.c",   "common/dictionary.c", "common/platform.c",
            "common/shared_dictionary.c", "common/transform.c", "dec/bit_reader.c", "dec/decode.c",
            "dec/huffman.c",          "dec/state.c",
        },
    });
    const brotli_c = b.addTranslateC(.{ .root_source_file = b.path("lib/brotli/brotli.h"), .target = target, .optimize = optimize });
    brotli_c.addIncludePath(brotli_src.path(b, "include"));
    const brotli = brotli_c.createModule();
    brotli.linkLibrary(brotli_dec);

    // Libraries, dependencies one way only: geom <- font <- glyphic <- layout.
    const testdata = b.createModule(.{ .root_source_file = b.path("lib/testdata/root.zig") });
    const geom = b.addModule("graven_geom", .{
        .root_source_file = b.path("lib/geom/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const font = b.addModule("graven_font", .{
        .root_source_file = b.path("lib/font/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hb", .module = hb },
            .{ .name = "brotli", .module = brotli },
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_testdata", .module = testdata },
        },
    });
    // Styled text as readers find it (RTF first), for importing.
    const richtext = b.addModule("graven_richtext", .{
        .root_source_file = b.path("lib/richtext/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Glyphic: the legend engine (objects, parameters, style contexts,
    // entry syntaxes, layout and setting).
    const glyphic = b.addModule("graven_glyphic", .{
        .root_source_file = b.path("lib/glyphic/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graven_font", .module = font },
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_testdata", .module = testdata },
        },
    });
    // Constraints, generic: unknowns, a least-change solver and its
    // analysis, dimensions, units and expressions (sketches and layouts).
    const constraint = b.addModule("graven_constraint", .{
        .root_source_file = b.path("lib/constraint/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_geom", .module = geom }},
    });
    // Parametric sketches: geometry held by constraints, solved together.
    const sketch = b.addModule("graven_sketch", .{
        .root_source_file = b.path("lib/sketch/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_constraint", .module = constraint },
        },
    });

    // Keyboards: key positions (ISO 9995 grid) and layouts, where bindings
    // and cases of sorts resolve keys named by position or symbol.
    const keys = b.addModule("graven_keys", .{
        .root_source_file = b.path("lib/keys/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const layout = b.addModule("graven_layout", .{
        .root_source_file = b.path("lib/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_font", .module = font },
            .{ .name = "graven_richtext", .module = richtext },
            .{ .name = "graven_testdata", .module = testdata },
            .{ .name = "graven_sketch", .module = sketch },
            .{ .name = "graven_constraint", .module = constraint },
            .{ .name = "graven_glyphic", .module = glyphic },
            .{ .name = "graven_keys", .module = keys },
        },
    });

    // Font search: describing, searching and comparing fonts from any
    // source. A separate tool's library; Graven may use it too.
    const fontsearch = b.addModule("graven_fontsearch", .{
        .root_source_file = b.path("lib/fontsearch/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hb", .module = hb },
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_font", .module = font },
            .{ .name = "graven_testdata", .module = testdata },
        },
    });

    // What differs between systems, chosen by the target: constants, the
    // environment, home and host name, Graven's folders, font folders, a
    // monotonic clock, absolute paths.
    const platform = b.addModule("graven_platform", .{
        .root_source_file = b.path("lib/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Configuration: TOML files, shared and local.
    const config = b.addModule("graven_config", .{
        .root_source_file = b.path("lib/config/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The local font source (installed fonts and the index cache), shared
    // by graven-fonts and Graven.
    const fonts_local = b.createModule(.{
        .root_source_file = b.path("apps/fonts/local.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "graven_fontsearch", .module = fontsearch },
            .{ .name = "graven_font", .module = font },
            .{ .name = "graven_platform", .module = platform },
        },
    });

    // A document's font folders (beside it, and the shared one), loaded as
    // a catalog: the GUI and the CLI find fonts the same way.
    const fonts_folders = b.createModule(.{
        .root_source_file = b.path("apps/fonts/folders.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "graven_layout", .module = layout },
            .{ .name = "graven_fontsearch", .module = fontsearch },
            .{ .name = "graven_platform", .module = platform },
            .{ .name = "graven_glyphic", .module = glyphic },
        },
    });

    // Applications.
    const cli = b.addExecutable(.{
        .name = "graven",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graven_richtext", .module = richtext },
                .{ .name = "graven_layout", .module = layout },
                .{ .name = "graven_fontsearch", .module = fontsearch },
                .{ .name = "graven_glyphic", .module = glyphic },
                .{ .name = "graven_fonts_folders", .module = fonts_folders },
                .{ .name = "graven_fonts_local", .module = fonts_local },
                .{ .name = "graven_platform", .module = platform },
            },
        }),
    });
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the graven CLI").dependOn(&run_cli.step);


    // The font tool: graven-fonts index | search | show | families | install | remove | convert.
    const fonts_tool = b.addExecutable(.{
        .name = "graven-fonts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/fonts/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "graven_fontsearch", .module = fontsearch },
                .{ .name = "graven_font", .module = font },
                .{ .name = "graven_platform", .module = platform },
            },
        }),
    });
    b.installArtifact(fonts_tool);

    // OCCT, optional, from either
    //   -Docct=<prefix>   an OCCT 8.0.1 install built with scripts/build-occt.sh
    //   -Docct-prebuilt   the release archive of one (scripts/package-occt.sh),
    //                     fetched as a package named in build.zig.zon
    // With it: graven-fab, the bridge test, and the GUI's 3D views.
    const occt_prefix = b.option([]const u8, "occt", "OCCT install prefix (enables the OCCT bridge)");
    const occt_prebuilt = b.option(bool, "occt-prebuilt", "Fetch the prebuilt OCCT release archive (enables the OCCT bridge)") orelse false;
    const occt: ?Occt = if (occt_prefix) |prefix| .{ .prefix = prefix } else if (occt_prebuilt) blk: {
        const name = occtPackageName(b, target) orelse break :blk null;
        break :blk if (b.lazyDependency(name, .{})) |dep| .{ .dep = dep } else null;
    } else null;

    // GUI editor: zig build gui (fetches DVUI and SDL3 on first use).
    const gui_step = b.step("gui", "Build and run the GUI editor");
    if (b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 })) |dvui_dep| {
        // FreeType 2.14.1's autohinter subtracts from an empty contour's
        // sentinel (LONG_MIN) when it adjusts accents (aflatin.c, vertical
        // separation): harmless as compiled for release, but a trap in a
        // Debug build's C sanitizer, on ā, ē and the like. The same
        // dependency DVUI links, so its sanitizer is off for FreeType alone.
        if (dvui_dep.builder.lazyDependency("freetype", .{ .target = target, .optimize = optimize })) |ft| {
            ft.artifact("freetype").root_module.sanitize_c = .off;
        }
        const gui = b.addExecutable(.{
            .name = "graven-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("apps/gui/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                    .{ .name = "graven_layout", .module = layout },
                        .{ .name = "graven_config", .module = config },
                    .{ .name = "graven_fontsearch", .module = fontsearch },
                    .{ .name = "graven_fonts_local", .module = fonts_local },
                    .{ .name = "graven_fonts_folders", .module = fonts_folders },
                    .{ .name = "graven_richtext", .module = richtext },
                    .{ .name = "graven_glyphic", .module = glyphic },
                    .{ .name = "graven_platform", .module = platform },
                    .{ .name = "graven_keys", .module = keys },
                },
            }),
        });
        // Its 3D views: through OCCT when the build has it, else a stub
        // that says so.
        gui.root_module.addImport("graven_occt3d", if (occt) |o| occtView3d(b, target, optimize, o, gui.root_module, layout) else b.createModule(.{
            .root_source_file = b.path("apps/gui/occt3d_stub.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "graven_layout", .module = layout }},
        }));
        const install_gui = b.addInstallArtifact(gui, .{});
        const run_gui = b.addRunArtifact(gui);
        run_gui.step.dependOn(&install_gui.step);
        run_gui.addPassthruArgs();
        gui_step.dependOn(&run_gui.step);
        b.step("gui-build", "Build the GUI editor without running it").dependOn(&install_gui.step);
    }
    // The GUI driven without a screen: Graven's frames under DVUI's testing
    // backend, its widgets found by tag (apps/gui/harness_test.zig).
    const gui_test_step = b.step("gui-test", "Drive the GUI headless: the examples made in it");
    // Only the GUI tests whose names hold this text (`-Dgui-filter=tabs`):
    // a change to the interface runs the tests about it.
    const gui_filter = b.option([]const u8, "gui-filter", "Run only the GUI tests whose names contain this");
    if (b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .testing })) |dvui_dep| {
        const t = b.addTest(.{ .filters = if (gui_filter) |f| b.dupeStrings(&.{f}) else &.{}, .root_module = b.createModule(.{
            .root_source_file = b.path("apps/gui/harness_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui_testing") },
                .{ .name = "graven_layout", .module = layout },
                .{ .name = "graven_config", .module = config },
                .{ .name = "graven_fontsearch", .module = fontsearch },
                .{ .name = "graven_fonts_local", .module = fonts_local },
                .{ .name = "graven_fonts_folders", .module = fonts_folders },
                .{ .name = "graven_richtext", .module = richtext },
                .{ .name = "graven_glyphic", .module = glyphic },
                .{ .name = "graven_platform", .module = platform },
                .{ .name = "graven_keys", .module = keys },
                .{ .name = "graven_occt3d", .module = b.createModule(.{
                    .root_source_file = b.path("apps/gui/occt3d_stub.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "graven_layout", .module = layout }},
                }) },
            },
        }) });
        const run = b.addRunArtifact(t);
        // From the repository's root: the examples and their fonts.
        run.setCwd(b.path("."));
        // A scratch config and font index; no message of the day.
        run.setEnvironmentVariable("GRAVEN_CONFIG_DIR", "/tmp/graven-gui-test/config");
        run.setEnvironmentVariable("GRAVEN_FONTS_INDEX", "/tmp/graven-gui-test/fonts-index.json");
        run.setEnvironmentVariable("GRAVEN_MOTD_URL", "none");
        gui_test_step.dependOn(&run.step);
    }

    // Library tests.
    const test_step = b.step("test", "Run library tests");
    // Only the library tests whose names hold this text
    // (`-Dtest-filter=constraint`).
    const test_filter = b.option([]const u8, "test-filter", "Run only the library tests whose names contain this");
    const filters: []const []const u8 = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{};
    for ([_]*std.Build.Module{ geom, font, layout, config, fontsearch, richtext, constraint, sketch, fonts_local, fonts_folders, glyphic, platform }) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .filters = filters, .root_module = mod })).step);
    }
    // The GUI's window-free logic (hot edges' timing).
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/dwell.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/labels.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/locale.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) })).step);
    // The action registry: names, modes, keymaps, checked when built.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/actions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_keys", .module = keys }},
    }) })).step);
    // Keyboards: positions and layouts.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = keys })).step);
    // Pane layouts: names, built-ins, reading the config.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/layouts.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    // The views: splits, tabs, maximizing.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/views.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    // The GUI's text sample.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/text_sample.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_layout", .module = layout }},
    }) })).step);
    // The example documents, read as files.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/examples_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_layout", .module = layout }},
    }) })).step);
    // Digraphs: the table, the user's pairs, typing one.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/digraphs.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    // The scintillating cursor's frames.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/cursor.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    // Display correction's curve.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/display.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    // The background grid's decades and strengths.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/grid.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);

    // The OCCT bridge (options read above): zig build occt-test, fab.
    const fab_mods: FabModules = .{ .layout = layout, .folders = fonts_folders };
    if (occt) |o| addOcctBridge(b, target, optimize, o, fab_mods);
}

/// The OCCT build to link: an install prefix, or the fetched release archive.
const Occt = union(enum) {
    prefix: []const u8,
    dep: *std.Build.Dependency,

    fn path(o: Occt, b: *std.Build, sub: []const u8) std.Build.LazyPath {
        return switch (o) {
            .prefix => |p| .{ .cwd_relative = b.fmt("{s}/{s}", .{ p, sub }) },
            .dep => |d| d.path(sub),
        };
    }

    /// Its MANIFEST (written by scripts/build-occt.sh), or null.
    fn manifest(o: Occt, b: *std.Build) ?[]const u8 {
        const io = b.graph.io;
        return switch (o) {
            .prefix => |p| std.Io.Dir.cwd().readFileAlloc(io, b.fmt("{s}/MANIFEST", .{p}), b.allocator, .limited(4096)) catch null,
            .dep => |d| blk: {
                const root = d.builder.root;
                const sub = if (root.sub_path.len == 0) "MANIFEST" else b.fmt("{s}/MANIFEST", .{root.sub_path});
                break :blk root.root_dir.handle.readFileAlloc(io, sub, b.allocator, .limited(4096)) catch null;
            },
        };
    }
};

/// The build.zig.zon name of the prebuilt OCCT archive for `target`
/// (occt_<arch>_<os>_<abi>), or null, with the reason reported, when there
/// is none.
fn occtPackageName(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    const t = target.result;
    const name = b.fmt("occt_{s}_{s}_{s}", .{ @tagName(t.cpu.arch), @tagName(t.os.tag), @tagName(t.abi) });
    for (b.available_deps) |d| if (std.mem.eql(u8, d[0], name)) return name;
    occtFail(b, b.fmt(
        "-Docct-prebuilt: no prebuilt OCCT for this target (no {s} in build.zig.zon). " ++
            "Build one with scripts/build-occt.sh and use -Docct=<prefix>.",
        .{name},
    ));
    return null;
}

/// The OCCT steps, failing with `msg`.
fn occtFail(b: *std.Build, msg: []const u8) void {
    const fail = &b.addFail(msg).step;
    b.step("occt-test", "Build and run the OCCT bridge test").dependOn(fail);
    b.step("fab", "Build graven-fab (parts as solids, through OCCT)").dependOn(fail);
}

/// Static OCCT toolkits needed for planar faces, XDE and STEP output.
const occt_toolkits = [_][]const u8{
    "TKDESTEP",   "TKXCAF", "TKVCAF",      "TKV3d",     "TKService",  "TKHLR",
    "TKMesh",     "TKCAF",  "TKLCAF",      "TKCDF",     "TKXSBase",   "TKDE",
    "TKBO",       "TKPrim", "TKShHealing", "TKTopAlgo", "TKGeomAlgo", "TKBRep",
    "TKGeomBase", "TKG3d",  "TKG2d",       "TKMath",    "TKernel",
};

/// The Graven modules graven-fab uses.
const FabModules = struct { layout: *std.Build.Module, folders: *std.Build.Module };

fn addOcctBridge(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, occt: Occt, mods: FabModules) void {
    // A build is tied to the zig that made it: its C++ is Zig's libc++.
    if (occt.manifest(b)) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, "zig=")) {
            const built = std.mem.trim(u8, line["zig=".len..], " \r");
            const running = @import("builtin").zig_version_string;
            if (!std.mem.eql(u8, built, running)) {
                occtFail(b, b.fmt("OCCT was built with zig {s}, but this is zig {s}: rebuild it with scripts/build-occt.sh", .{ built, running }));
                return;
            }
        };
    }
    // Zig 0.17 has no @cImport: the shim header becomes a module here.
    const shim_h = b.addTranslateC(.{
        .root_source_file = b.path("bridge/occt/occt_shim.h"),
        .target = target,
        .optimize = optimize,
    });

    const shim = shim_h.createModule();

    // The bridge test.
    const test_mod = occtModule(b, target, optimize, occt, b.path("bridge/occt/test/main.zig"), shim);
    const exe = b.addExecutable(.{ .name = "occt-bridge-test", .root_module = test_mod });
    b.installArtifact(exe);
    b.step("occt-test", "Build and run the OCCT bridge test").dependOn(&b.addRunArtifact(exe).step);

    // graven-fab: parts' fabrication plans built into solids.
    const fab = b.createModule(.{
        .root_source_file = b.path("bridge/occt/fab.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "occt_shim", .module = shim },
            .{ .name = "graven_layout", .module = mods.layout },
        },
    });
    const fab_mod = occtModule(b, target, optimize, occt, b.path("apps/fab/main.zig"), shim);
    fab_mod.addImport("occt_fab", fab);
    fab_mod.addImport("graven_layout", mods.layout);
    fab_mod.addImport("graven_fonts_folders", mods.folders);
    const fab_exe = b.addExecutable(.{ .name = "graven-fab", .root_module = fab_mod });
    const install_fab = b.addInstallArtifact(fab_exe, .{});
    b.step("fab", "Build graven-fab (parts as solids, through OCCT)").dependOn(&install_fab.step);
}

/// The GUI's 3D module through OCCT (bridge/occt/view3d.zig), with `gui`
/// (its root module) linking the shim and OCCT.
fn occtView3d(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, occt: Occt, gui: *std.Build.Module, layout: *std.Build.Module) *std.Build.Module {
    const shim = b.addTranslateC(.{
        .root_source_file = b.path("bridge/occt/occt_shim.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    linkOcct(b, gui, occt);
    return b.createModule(.{
        .root_source_file = b.path("bridge/occt/view3d.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "occt_shim", .module = shim },
            .{ .name = "graven_layout", .module = layout },
        },
    });
}

/// `mod` linking the OCCT shim and OCCT's toolkits (C++).
fn linkOcct(b: *std.Build, mod: *std.Build.Module, occt: Occt) void {
    mod.link_libc = true;
    mod.link_libcpp = true;
    mod.addIncludePath(b.path("bridge/occt"));
    mod.addIncludePath(occt.path(b, "include/opencascade"));
    mod.addCSourceFile(.{ .file = b.path("bridge/occt/occt_shim.cpp"), .flags = &.{"-std=c++17"} });
    for (occt_toolkits) |tk| mod.addObjectFile(occt.path(b, b.fmt("lib/lib{s}.a", .{tk})));
}

/// A module rooted at `root` that links the OCCT shim and OCCT itself.
fn occtModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, occt: Occt, root: std.Build.LazyPath, shim: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addImport("occt_shim", shim);
    mod.addIncludePath(b.path("bridge/occt"));
    mod.addIncludePath(occt.path(b, "include/opencascade"));
    mod.addCSourceFile(.{ .file = b.path("bridge/occt/occt_shim.cpp"), .flags = &.{"-std=c++17"} });
    for (occt_toolkits) |tk| {
        mod.addObjectFile(occt.path(b, b.fmt("lib/lib{s}.a", .{tk})));
    }
    return mod;
}
