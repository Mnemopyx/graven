//! Regular polygons as sketch geometry: `n` segments joined end to end
//! round a construction circle, held regular by ordinary constraints, so
//! each side, corner and the circle can be picked and constrained as any
//! other geometry.
//!
//! The constraints: every side equal to the first (n - 1), and the
//! interior angle, (n - 2)·180°/n, between consecutive sides at every
//! corner: driving at n - 3, reference at the other three. With all
//! sides equal, those angles are the ones left free (an equilateral
//! polygon of n sides has n - 3 shape freedoms); more would be redundant.
//! A construction circle passes through three corners (any three fix a
//! circle; the rest lie on it already); another, about the same centre,
//! touches the first side (and so every side, at its middle). What is left free: the centre, the size
//! (the circle's radius) and the turn.

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const Error = root.Error;

/// A regular polygon's geometry, by ID.
pub const Refs = struct {
    /// The construction circle through its corners.
    circle: GeomId,
    /// The construction circle touching its sides at their middles.
    inner: GeomId,
    /// The first side (from the corner dragged to, anticlockwise).
    first: GeomId,
    sides: u32,
};

/// Adds a regular polygon of `n` sides (3 or more) centred at `c`, a
/// corner at `corner`, its sides construction when `construction`.
pub fn addRegular(s: *Sketch, a: Allocator, c: Point, corner: Point, n: u32, construction: bool) Error!Refs {
    if (n < 3) return error.WrongKind;
    const r = @sqrt((corner.x - c.x) * (corner.x - c.x) + (corner.y - c.y) * (corner.y - c.y));
    if (!(r > 0)) return error.WrongKind;
    const t0 = std.math.atan2(corner.y - c.y, corner.x - c.x);
    const step = 2 * std.math.pi / @as(f64, @floatFromInt(n));
    const circle = try s.addCircle(a, c, r, true);
    var sides: std.ArrayList(GeomId) = .empty;
    defer sides.deinit(a);
    for (0..n) |i| {
        const ta = t0 + @as(f64, @floatFromInt(i)) * step;
        const tb = ta + step;
        const p0: Point = .{ .x = c.x + r * @cos(ta), .y = c.y + r * @sin(ta) };
        const p1: Point = .{ .x = c.x + r * @cos(tb), .y = c.y + r * @sin(tb) };
        try sides.append(a, try s.addSegment(a, p0, p1, construction));
    }
    const interior = std.math.pi - step;
    for (sides.items, 0..) |g, i| {
        const next = sides.items[(i + 1) % n];
        // Joined end to start.
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = g, .role = .end }, .{ .geom = next, .role = .start } } } });
        if (i > 0) _ = try s.addConstraint(a, .{ .kind = .{ .equal = .{ .a = sides.items[0], .b = g } } });
        // The interior angle at the corner between this side and the next
        // (from the next side's direction back to this one's).
        // The interior angle, (n - 2)·180°/n, at every corner: driving at
        // n - 3 of them, reference (shown, not driving) at the last three,
        // which follow from the rest (driving, they would be redundant).
        _ = try s.addConstraint(a, .{ .kind = .{ .angle = .{ .a = next, .b = g, .value = interior } }, .driving = i < n - 3 });
        if (i < 3) _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = g, .role = .start }, .on = circle } } });
    }
    // The inscribed circle: about the same centre, touching each side at
    // its middle (tangent to the first; the rest follow, the polygon being
    // regular).
    const inner = try s.addCircle(a, c, r * @cos(step / 2), true);
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = inner, .role = .centre }, .{ .geom = circle, .role = .centre } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .tangent = .{ .a = inner, .b = sides.items[0] } } });
    return .{ .circle = circle, .inner = inner, .first = sides.items[0], .sides = n };
}

test "a regular polygon: four freedoms left, none redundant, sides equal" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_]u32{ 3, 4, 5, 6, 7, 8, 12 }) |n| {
        var s = try Sketch.init(gpa);
        defer s.deinit(gpa);
        const refs = try addRegular(&s, gpa, .{ .x = 1, .y = 2 }, .{ .x = 11, .y = 2 }, n, false);
        _ = try s.solve(gpa);
        const an = try s.analyse(gpa, arena.allocator());
        try std.testing.expectEqual(@as(usize, 4), an.dof);
        try std.testing.expectEqual(@as(usize, 0), an.redundant.len);
        try std.testing.expectEqual(@as(usize, 0), an.conflicting.len);
        // A corner dragged out: still regular, larger.
        _ = try s.drag(gpa, gpa, .{ .geom = refs.first, .role = .start }, .{ .x = 16, .y = 2 });
        var segs: std.ArrayList(geom.Segment) = .empty;
        defer segs.deinit(gpa);
        for (0..n) |i| try s.appendSegments(gpa, s.geometry.items[refs.first + i], &segs);
        const l0 = len(segs.items[0]);
        for (segs.items) |sg| try std.testing.expectApproxEqAbs(l0, len(sg), 1e-6);
        try std.testing.expect(l0 > 2 * 10 * @sin(std.math.pi / @as(f64, @floatFromInt(n))) + 0.1);
        // The inscribed circle followed: its radius the apothem.
        const ri = s.vars.items[s.geometry.items[refs.inner].kind.circle.r];
        try std.testing.expectApproxEqAbs(l0 / (2 * @tan(std.math.pi / @as(f64, @floatFromInt(n)))), ri, 1e-6);
    }
}

fn len(sg: geom.Segment) f64 {
    const p = sg.start();
    const q = sg.end();
    return std.math.hypot(p.x - q.x, p.y - q.y);
}
