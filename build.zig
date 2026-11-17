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
    // Parametric sketches: geometry held by constraints, solved together.
    const sketch = b.addModule("graven_sketch", .{
        .root_source_file = b.path("lib/sketch/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_geom", .module = geom }},
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
            .{ .name = "graven_glyphic", .module = glyphic },
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

    // Configuration: TOML files, shared and local.
    const config = b.addModule("graven_config", .{
        .root_source_file = b.path("lib/config/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Applications. Samples build models through the libraries' actions.
    const samples = b.createModule(.{
        .root_source_file = b.path("apps/samples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graven_layout", .module = layout },
        },
    });
    const cli = b.addExecutable(.{
        .name = "graven",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graven_richtext", .module = richtext },
                .{ .name = "graven_layout", .module = layout },
                .{ .name = "graven_samples", .module = samples },
                .{ .name = "graven_fontsearch", .module = fontsearch },
                .{ .name = "graven_glyphic", .module = glyphic },
            },
        }),
    });
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the graven CLI").dependOn(&run_cli.step);

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
        },
    });

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
            },
        }),
    });
    b.installArtifact(fonts_tool);

    // GUI editor: zig build gui (fetches DVUI and SDL3 on first use).
    const gui_step = b.step("gui", "Build and run the GUI editor");
    if (b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 })) |dvui_dep| {
        const gui = b.addExecutable(.{
            .name = "graven-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("apps/gui/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                    .{ .name = "graven_layout", .module = layout },
                    .{ .name = "graven_samples", .module = samples },
                    .{ .name = "graven_config", .module = config },
                    .{ .name = "graven_fontsearch", .module = fontsearch },
                    .{ .name = "graven_fonts_local", .module = fonts_local },
                    .{ .name = "graven_richtext", .module = richtext },
                    .{ .name = "graven_glyphic", .module = glyphic },
                },
            }),
        });
        const install_gui = b.addInstallArtifact(gui, .{});
        const run_gui = b.addRunArtifact(gui);
        run_gui.step.dependOn(&install_gui.step);
        run_gui.addPassthruArgs();
        gui_step.dependOn(&run_gui.step);
        b.step("gui-build", "Build the GUI editor without running it").dependOn(&install_gui.step);
    }

    // Library tests.
    const test_step = b.step("test", "Run library tests");
    for ([_]*std.Build.Module{ geom, font, layout, samples, config, fontsearch, richtext, sketch, fonts_local, glyphic }) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
    // The GUI's window-free logic (hot edges' timing).
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/gui/dwell.zig"),
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

    // Optional OCCT bridge, from either
    //   -Docct=<prefix>   an OCCT 8.0.1 install built with scripts/build-occt.sh
    //   -Docct-prebuilt   the release archive of one (scripts/package-occt.sh),
    //                     fetched as a package named in build.zig.zon
    // then: zig build occt-test ...
    const occt_prefix = b.option([]const u8, "occt", "OCCT install prefix (enables the OCCT bridge)");
    const fab_mods: FabModules = .{ .layout = layout, .samples = samples };
    const occt_prebuilt = b.option(bool, "occt-prebuilt", "Fetch the prebuilt OCCT release archive (enables the OCCT bridge)") orelse false;
    if (occt_prefix) |prefix| {
        addOcctBridge(b, target, optimize, .{ .prefix = prefix }, fab_mods);
    } else if (occt_prebuilt) {
        const name = occtPackageName(b, target) orelse return;
        if (b.lazyDependency(name, .{})) |dep| addOcctBridge(b, target, optimize, .{ .dep = dep }, fab_mods);
    }
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
const FabModules = struct { layout: *std.Build.Module, samples: *std.Build.Module };

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
    fab_mod.addImport("graven_samples", mods.samples);
    const fab_exe = b.addExecutable(.{ .name = "graven-fab", .root_module = fab_mod });
    const install_fab = b.addInstallArtifact(fab_exe, .{});
    b.step("fab", "Build graven-fab (parts as solids, through OCCT)").dependOn(&install_fab.step);
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
