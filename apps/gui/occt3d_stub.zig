//! What the GUI imports for 3D views when it is built without OCCT
//! (`zig build gui-build` without -Docct-prebuilt or -Docct): the same
//! interface as bridge/occt/view3d.zig, saying it is not there.

const std = @import("std");
const layout = @import("graven_layout");
const Allocator = std.mem.Allocator;

pub const available = false;

pub const Error = Allocator.Error || error{ Occt, Unavailable };

pub const Mesh = struct {
    pos: []const [3]f32 = &.{},
    tris: []const [3]u32 = &.{},
    colour: []const layout.model.FabColour = &.{},
    /// Faces OCCT would not sweep (simplified too far: a stroke's sides
    /// crossing), left out.
    skipped: usize = 0,
};

pub fn meshSlabs(gpa: Allocator, a: Allocator, slabs: []const layout.fab.Slab, offset: [2]f64, deflection: f64, into: *Mesh) Error!void {
    _ = .{ gpa, a, slabs, offset, deflection, into };
    return error.Unavailable;
}

pub fn lastError() []const u8 {
    return "this build has no OCCT (build it with -Docct-prebuilt)";
}
