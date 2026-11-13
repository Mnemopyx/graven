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

    // Libraries, dependencies one way only: geom <- font <- engine <- layout.
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
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_testdata", .module = testdata },
        },
    });
    const engine = b.addModule("graven_engine", .{
        .root_source_file = b.path("lib/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hb", .module = hb },
            .{ .name = "graven_geom", .module = geom },
            .{ .name = "graven_font", .module = font },
            .{ .name = "graven_testdata", .module = testdata },
        },
    });
    // Styled text as readers find it (RTF first), for importing.
    const richtext = b.addModule("graven_richtext", .{
        .root_source_file = b.path("lib/richtext/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const layout = b.addModule("graven_layout", .{
        .root_source_file = b.path("lib/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graven_engine", .module = engine },
            .{ .name = "graven_richtext", .module = richtext },
            .{ .name = "graven_testdata", .module = testdata },
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

    // Parametric sketches: geometry held by constraints, solved together.
    const sketch = b.addModule("graven_sketch", .{
        .root_source_file = b.path("lib/sketch/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_geom", .module = geom }},
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
            .{ .name = "graven_engine", .module = engine },
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
                .{ .name = "graven_engine", .module = engine },
                .{ .name = "graven_samples", .module = samples },
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

    // The font search tool: graven-fonts index | search | show.
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
                    .{ .name = "graven_engine", .module = engine },
                    .{ .name = "graven_samples", .module = samples },
                    .{ .name = "graven_config", .module = config },
                    .{ .name = "graven_fontsearch", .module = fontsearch },
                    .{ .name = "graven_fonts_local", .module = fonts_local },
                    .{ .name = "graven_richtext", .module = richtext },
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
    for ([_]*std.Build.Module{ geom, font, engine, layout, samples, config, fontsearch, richtext, sketch }) |mod| {
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

    // Optional OCCT bridge: zig build occt-test -Docct=<prefix>
    // <prefix> is an OCCT 8.0.1 install built static with scripts/build-occt.sh.
    if (b.option([]const u8, "occt", "OCCT install prefix (enables the OCCT bridge)")) |occt| {
        addOcctBridge(b, target, optimize, occt);
    }
}

/// Static OCCT toolkits needed for planar faces, XDE and STEP output.
const occt_toolkits = [_][]const u8{
    "TKDESTEP",   "TKXCAF", "TKVCAF",      "TKV3d",     "TKService",  "TKHLR",
    "TKMesh",     "TKCAF",  "TKLCAF",      "TKCDF",     "TKXSBase",   "TKDE",
    "TKBO",       "TKPrim", "TKShHealing", "TKTopAlgo", "TKGeomAlgo", "TKBRep",
    "TKGeomBase", "TKG3d",  "TKG2d",       "TKMath",    "TKernel",
};

fn addOcctBridge(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, occt: []const u8) void {
    // Zig 0.17 has no @cImport: the shim header becomes a module here.
    const shim_h = b.addTranslateC(.{
        .root_source_file = b.path("bridge/occt/occt_shim.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("bridge/occt/test/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addImport("occt_shim", shim_h.createModule());
    mod.addIncludePath(b.path("bridge/occt"));
    mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/opencascade", .{occt}) });
    mod.addCSourceFile(.{ .file = b.path("bridge/occt/occt_shim.cpp"), .flags = &.{"-std=c++17"} });
    for (occt_toolkits) |tk| {
        mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/lib{s}.a", .{ occt, tk }) });
    }

    const exe = b.addExecutable(.{ .name = "occt-bridge-test", .root_module = mod });
    b.installArtifact(exe);
    b.step("occt-test", "Build and run the OCCT bridge test").dependOn(&b.addRunArtifact(exe).step);
}
