//! A caption's leader: a connection (`connector.zig`) of segments, out
//! square to a side or along a curve's radius, then a level jog, ending at
//! the point a caption's text is held to. Its geometry is ordinary
//! constrained construction geometry, so it follows the side or curve
//! when it moves, turns or grows, and its lengths are dimensions.

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");
const connector = @import("connector.zig");

const Allocator = std.mem.Allocator;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const PointRef = root.PointRef;

pub const From = connector.From;
pub const AddError = connector.AddError;

pub const Leader = struct {
    /// Its connection, in `Sketch.connectors`.
    connector: usize,
    /// Out along the normal, then across (segments: its path's two).
    radial: GeomId,
    across: GeomId,
    /// Where the caption is held: the connection's end point.
    end: PointRef,
    /// It runs right (the caption's left edge on `end`), else left.
    right: bool,
};

/// Adds a caption's leader at point `p` (on a side, a circle or an arc):
/// `out` along the normal, then `across` (mm).
pub fn addLeader(s: *Sketch, a: Allocator, p: PointRef, out: f64, across: f64) AddError!Leader {
    return addLeaderFrom(s, a, .{ .point = p }, out, across);
}

/// Adds a caption's leader from `from`: `out` along the normal, then
/// `across` (mm).
pub fn addLeaderFrom(s: *Sketch, a: Allocator, from: From, out: f64, across: f64) AddError!Leader {
    const ci = try connector.add(s, a, from, .segments, out, across);
    const c = s.connectors.items[ci];
    return .{ .connector = ci, .radial = c.path.items[0], .across = c.path.items[1], .end = .{ .geom = c.end, .role = .point }, .right = c.right };
}

test "a leader from a polar array's ring follows it when it turns" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const refs = try root.arrays.addPolar(&s, a, .{ .x = 0, .y = 0 }, 10, std.math.pi / 2.0, 2 * std.math.pi, 8, 1);
    const pr = refs.polar;
    // The end of the border at 45° (anticlockwise from up: 135°, left).
    const p: PointRef = .{ .geom = pr.second, .role = .end };
    const at = try s.point(p);
    const lead = try addLeader(&s, a, p, 3, 4);
    _ = try s.solve(testing.allocator);
    const e = try s.point(lead.end);
    try testing.expectEqual(at.x >= 0, lead.right);
    const r = std.math.hypot(at.x, at.y);
    const bend = try s.point(.{ .geom = lead.radial, .role = .end });
    try testing.expectApproxEqAbs(r + 3, std.math.hypot(bend.x, bend.y), 1e-6);
    try testing.expectApproxEqAbs(bend.y, e.y, 1e-6);
    try testing.expectApproxEqAbs(4, @abs(e.x - bend.x), 1e-6);
}

test "a leader from a side runs out square to it, away from the drawing, and follows it" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    // A square's right side, from (10, -10) up to (10, 10), and its left.
    const right_side = try s.addSegment(a, .{ .x = 10, .y = -10 }, .{ .x = 10, .y = 10 }, false);
    _ = try s.addSegment(a, .{ .x = -10, .y = 10 }, .{ .x = -10, .y = -10 }, false);
    const lead = try addLeaderFrom(&s, a, .{ .curve = right_side }, 3, 4);
    _ = try s.solve(testing.allocator);
    try testing.expect(lead.right);
    const st = try s.point(.{ .geom = lead.radial, .role = .start });
    const bend = try s.point(.{ .geom = lead.radial, .role = .end });
    const e = try s.point(lead.end);
    try testing.expectApproxEqAbs(10, st.x, 1e-6);
    try testing.expectApproxEqAbs(0, st.y, 1e-6);
    try testing.expectApproxEqAbs(13, bend.x, 1e-6);
    try testing.expectApproxEqAbs(17, e.x, 1e-6);
    try testing.expectApproxEqAbs(0, e.y, 1e-6);
    // The side turned a little: the leader stays square to it.
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = right_side, .role = .start }, .at = .{ .x = 10, .y = -10 } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = right_side, .role = .end }, .at = .{ .x = 12, .y = 10 } } } });
    _ = try s.solve(testing.allocator);
    const st2 = try s.point(.{ .geom = lead.radial, .role = .start });
    const bend2 = try s.point(.{ .geom = lead.radial, .role = .end });
    const e2 = try s.point(lead.end);
    try testing.expectApproxEqAbs(0, (bend2.x - st2.x) * 2 + (bend2.y - st2.y) * 20, 1e-6);
    try testing.expectApproxEqAbs(bend2.y, e2.y, 1e-6);
}

test "a leader from a circle starts at its upper right and stays there as it grows" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const ci = try s.addCircle(a, .{ .x = 0, .y = 0 }, 10, false);
    const lead = try addLeaderFrom(&s, a, .{ .curve = ci }, 3, 4);
    _ = try s.solve(testing.allocator);
    const st = try s.point(.{ .geom = lead.radial, .role = .start });
    try testing.expectApproxEqAbs(10.0 / std.math.sqrt2, st.x, 1e-6);
    try testing.expectApproxEqAbs(10.0 / std.math.sqrt2, st.y, 1e-6);
    _ = try s.addConstraint(a, .{ .kind = .{ .radius = .{ .g = ci, .value = 20 } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = ci, .role = .centre }, .at = .{ .x = 0, .y = 0 } } } });
    _ = try s.solve(testing.allocator);
    const st2 = try s.point(.{ .geom = lead.radial, .role = .start });
    try testing.expectApproxEqAbs(20.0 / std.math.sqrt2, st2.x, 1e-6);
    try testing.expectApproxEqAbs(20.0 / std.math.sqrt2, st2.y, 1e-6);
}
