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

/// A panel out of compliance: its outline past the sheet's edge, or its ink
/// area past the sheet's ink area (into the sheet's margins). Sheet and
/// margin changes can leave panels so; they are never moved to fit.
pub const PanelIssue = struct {
    panel: usize,
    /// How far the outline reaches past the sheet, mm; 0 if it does not.
    off_sheet: f64,
    /// How far the ink area reaches past the sheet's ink area, mm; 0 if
    /// it does not.
    ink_outside: f64,
};

/// Panels out of compliance.
pub fn panelIssues(gpa: std.mem.Allocator, m: *const model.Model) ![]PanelIssue {
    var out: std.ArrayList(PanelIssue) = .empty;
    errdefer out.deinit(gpa);
    for (m.panels.items, 0..) |p, pi| {
        const off = overhang(p.box(), m.sheet.box());
        const ink = overhang(p.inkArea(), m.sheet.inkArea());
        if (off > 1e-9 or ink > 1e-9) try out.append(gpa, .{ .panel = pi, .off_sheet = @max(off, 0), .ink_outside = @max(ink, 0) });
    }
    return out.toOwnedSlice(gpa);
}

/// How far box `a` reaches past box `b` on its worst side; negative inside.
fn overhang(a: Box, b: Box) f64 {
    return @max(@max(b.x0 - a.x0, a.x1 - b.x1), @max(b.y0 - a.y0, a.y1 - b.y1));
}

test "a sheet change that leaves a panel out of compliance is reported" {
    const gpa = std.testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    _ = try m.placePanel(.{ .name = "P", .origin = .{ .x = 400, .y = 10 }, .w = 150, .h = 100 });
    const none = try panelIssues(gpa, &m);
    defer gpa.free(none);
    try std.testing.expectEqual(0, none.len);
    try m.setSheet(.standard(1, .portrait)); // 297 x 420
    const found = try panelIssues(gpa, &m);
    defer gpa.free(found);
    try std.testing.expectEqual(1, found.len);
    try std.testing.expectApproxEqAbs(253, found[0].off_sheet, 1e-9);
    try std.testing.expectApproxEqAbs(258, found[0].ink_outside, 1e-9); // 545 - 287
}

test "a panel reaching only into the sheet's margins complies; its ink area there does not" {
    const gpa = std.testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    // Outline from x = 16 (inside the 20 mm margin), ink area from 21.
    _ = try m.placePanel(.{ .name = "P", .origin = .{ .x = 16, .y = 50 }, .w = 100, .h = 50 });
    const ok = try panelIssues(gpa, &m);
    defer gpa.free(ok);
    try std.testing.expectEqual(0, ok.len);
    try m.movePanel(0, .{ .x = 15, .y = 50 });
    _ = try m.placePanel(.{ .name = "Q", .origin = .{ .x = 12, .y = 200 }, .w = 100, .h = 50 });
    const found = try panelIssues(gpa, &m);
    defer gpa.free(found);
    try std.testing.expectEqual(1, found.len);
    try std.testing.expectEqual(1, found[0].panel);
    try std.testing.expectApproxEqAbs(3, found[0].ink_outside, 1e-9);
}

/// A label whose ink reaches into the worksheet's margins.
pub const MarginIntrusion = struct {
    panel: usize,
    /// The tile whose slot holds the label; null for a label placed
    /// directly on the panel, `slot` then being its index there.
    tile: ?model.TileId,
    slot: usize,
    /// The label's ink box on the worksheet, mm.
    ink: Box,
    /// How far it reaches past the ink area, mm: the largest overhang on
    /// any side.
    amount: f64,
};

/// Labels whose ink box leaves their panel's ink area or the sheet's.
/// `placed` holds one solve per panel, in panel order. The ink box bounds
/// the exact outlines, so a label inside it is inside the area.
pub fn marginIntrusions(gpa: std.mem.Allocator, m: *const model.Model, placed: []const place.Placed) ![]MarginIntrusion {
    var out: std.ArrayList(MarginIntrusion) = .empty;
    errdefer out.deinit(gpa);
    const sheet = m.sheet.inkArea();
    for (placed, 0..) |p, pi| {
        const panel = m.panels.items[pi];
        const o = panel.origin;
        const pa = panel.inkArea();
        const area: Box = .{ .x0 = @max(sheet.x0, pa.x0), .y0 = @max(sheet.y0, pa.y0), .x1 = @min(sheet.x1, pa.x1), .y1 = @min(sheet.y1, pa.y1) };
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
    // No panel margins: this test is about the sheet's.
    try m.setPanelMargins(p, .{});
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 30 }, .w = 3, .h = 1, .pitch = 19.05 });
    _ = try m.addRow(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .face_inset = .all(2), .slots = &.{.{ .name = "top", .style = style }} });
    for ([_][]const u8{ "K1", "K2" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setContent(t, "top", "H");
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
