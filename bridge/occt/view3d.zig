//! Parts for viewing in 3D, through OCCT: a part's fabrication slabs built
//! as solids (fab.zig, one a colour), then meshed by OCCT's mesher, for the
//! GUI's manufacturing view to draw (decided 2026-11-19: OCCT models and
//! meshes, Graven draws; blueprint "Manufacturing visualization through
//! OCCT"). The GUI imports this, or apps/gui/occt3d_stub.zig when it is
//! built without OCCT; both answer `available`.

const std = @import("std");
const c = @import("occt_shim");
const layout = @import("graven_layout");
const fab = @import("fab.zig");
const Allocator = std.mem.Allocator;

pub const available = true;

pub const Error = Allocator.Error || error{ Occt, Unavailable };

/// Triangles to draw: positions (mm), each triangle's corners (wound with
/// the outside counter-clockwise) and colour.
pub const Mesh = struct {
    pos: []const [3]f32 = &.{},
    tris: []const [3]u32 = &.{},
    colour: []const layout.model.FabColour = &.{},
};

/// `slabs` as OCCT solids, meshed within `deflection` mm, moved by
/// `offset` (where the part sits), appended to `into` (in `a`).
pub fn meshSlabs(gpa: Allocator, a: Allocator, slabs: []const layout.fab.Slab, offset: [2]f64, deflection: f64, into: *Mesh) Error!void {
    var built = try fab.build(gpa, a, slabs, .{});
    defer built.deinit(gpa);
    var pos: std.ArrayList([3]f32) = .empty;
    var tris: std.ArrayList([3]u32) = .empty;
    var colour: std.ArrayList(layout.model.FabColour) = .empty;
    try pos.appendSlice(a, into.pos);
    try tris.appendSlice(a, into.tris);
    try colour.appendSlice(a, into.colour);
    for (built.parts) |p| {
        var m: c.os_mesh = undefined;
        if (c.os_solid_mesh(p.solid, deflection, 0.6, &m) != c.OS_OK) return error.Occt;
        defer c.os_mesh_free(&m);
        const base: u32 = @intCast(pos.items.len);
        for (0..m.n_verts) |i| try pos.append(a, .{ m.xyz[3 * i] + @as(f32, @floatCast(offset[0])), m.xyz[3 * i + 1] + @as(f32, @floatCast(offset[1])), m.xyz[3 * i + 2] });
        for (0..m.n_tris) |i| {
            try tris.append(a, .{ base + m.idx[3 * i], base + m.idx[3 * i + 1], base + m.idx[3 * i + 2] });
            try colour.append(a, p.colour);
        }
    }
    into.* = .{ .pos = pos.items, .tris = tris.items, .colour = colour.items };
}

/// The bridge's last error, for messages.
pub fn lastError() []const u8 {
    return fab.lastError();
}
