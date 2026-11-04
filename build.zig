const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Libraries.
    const font = b.addModule("graven_font", .{
        .root_source_file = b.path("lib/font/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const layout = b.addModule("graven_layout", .{
        .root_source_file = b.path("lib/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graven_font", .module = font }},
    });

    // Applications.
    const cli = b.addExecutable(.{
        .name = "graven",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "graven_layout", .module = layout }},
        }),
    });
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the graven CLI").dependOn(&run_cli.step);

    // Library tests.
    const test_step = b.step("test", "Run library tests");
    for ([_]*std.Build.Module{ font, layout }) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

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
