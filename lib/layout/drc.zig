//! Rule types and checks against process and specification profiles,
//! plus design checks (cohesion, identical legends).
//!
//! First check: ink in the worksheet's margins. Panels may reach into the
//! margins; their ink may not.

const std = @import("std");
const engine = @import("graven_engine");
const model = @import("model.zig");
const place = @import("place.zig");

const geom = engine.geom;
const Box = geom.Box;

/// A panel extending past the sheet's edge, as a sheet change can leave
/// one: panels are never moved to fit.
pub const OffSheet = struct {
    panel: usize,
    /// How far it reaches past the sheet, mm: the largest overhang.
    amount: f64,
};

/// Panels extending past the sheet.
pub fn offSheet(gpa: std.mem.Allocator, m: *const model.Model) ![]OffSheet {
    var out: std.ArrayList(OffSheet) = .empty;
    errdefer out.deinit(gpa);
    const s = m.sheet.box();
    for (m.panels.items, 0..) |p, pi| {
        const b = p.box();
        const amount = @max(@max(s.x0 - b.x0, b.x1 - s.x1), @max(s.y0 - b.y0, b.y1 - s.y1));
        if (amount > 1e-9) try out.append(gpa, .{ .panel = pi, .amount = amount });
    }
    return out.toOwnedSlice(gpa);
}

test "a sheet change that leaves a panel over the edge is reported" {
    const gpa = std.testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    _ = try m.placePanel(.{ .name = "P", .origin = .{ .x = 400, .y = 10 }, .w = 150, .h = 100 });
    const none = try offSheet(gpa, &m);
    defer gpa.free(none);
    try std.testing.expectEqual(0, none.len);
    try m.setSheet(.standard(1, .portrait)); // 297 x 420
    const found = try offSheet(gpa, &m);
    defer gpa.free(found);
    try std.testing.expectEqual(1, found.len);
    try std.testing.expectApproxEqAbs(253, found[0].amount, 1e-9);
}

/// A label whose ink reaches into the worksheet's margins.
pub const MarginIntrusion = struct {
    panel: usize,
    tile: model.TileId,
    slot: usize,
    /// The label's ink box on the worksheet, mm.
    ink: Box,
    /// How far it reaches past the ink area, mm: the largest overhang on
    /// any side.
    amount: f64,
};

/// Labels whose ink box leaves the sheet's ink area. `placed` holds one
/// solve per panel, in panel order. The ink box bounds the exact outlines,
/// so a label inside it is inside the area.
pub fn marginIntrusions(gpa: std.mem.Allocator, m: *const model.Model, placed: []const place.Placed) ![]MarginIntrusion {
    var out: std.ArrayList(MarginIntrusion) = .empty;
    errdefer out.deinit(gpa);
    const area = m.sheet.inkArea();
    for (placed, 0..) |p, pi| {
        const o = m.panels.items[pi].origin;
        for (p.labels) |l| {
            const ink = l.render.ink;
            if (ink.isEmpty()) continue;
            const x = o.x + l.origin.x;
            const y = o.y + l.origin.y;
            const b: Box = .{ .x0 = x + ink.x0, .y0 = y + ink.y0, .x1 = x + ink.x1, .y1 = y + ink.y1 };
            const amount = @max(@max(area.x0 - b.x0, b.x1 - area.x1), @max(area.y0 - b.y0, b.y1 - area.y1));
            if (amount > 0) try out.append(gpa, .{ .panel = pi, .tile = l.tile, .slot = l.slot, .ink = b, .amount = amount });
        }
    }
    return out.toOwnedSlice(gpa);
}

test "ink past a margin is found; a panel in the margin alone is not" {
    const gpa = std.testing.allocator;
    const testdata = @import("graven_testdata");
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};

    var m: model.Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .upright = 0, .cap_height = 3 });
    // A panel reaching 15 mm into the 20 mm left margin.
    const p = try m.placePanel(.{ .name = "P", .origin = .{ .x = 5, .y = 100 }, .w = 60, .h = 30 });
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 30 }, .w = 3, .h = 1, .pitch = 19.05 });
    _ = try m.addRow(p, r, 0);
    for ([_][]const u8{ "K1", "K2" }) |d| {
        const t = try m.addTile(.{ .designator = d, .face_inset = .all(2) });
        try m.addSlot(t, .{ .name = "top", .style = style, .content = "H" });
        try m.place(p, r, 0, null, .{ .tile = t });
    }
    var labels: place.Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try place.solve(gpa, &m, p, &labels);
    defer s.deinit();

    const found = try marginIntrusions(gpa, &m, &.{s});
    defer gpa.free(found);
    // K1's legend starts about 7 mm across the sheet: inside the margin.
    // K2's starts past 26 mm: clear of it.
    try std.testing.expectEqual(1, found.len);
    try std.testing.expectEqual(m.findTile("K1").?, found[0].tile);
    try std.testing.expect(found[0].amount > 0);
}
