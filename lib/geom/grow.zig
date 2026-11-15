//! Growing an outline: every edge moved outward by the same distance,
//! convex corners rounded, the region gaining that much ink all round. A
//! thin font drawn heavier this way keeps its shapes and its counters
//! shrink by the same amount, as a heavier stroke would make them.
//!
//! The result is the Minkowski sum of the filled region and a disc,
//! flattened to within a tolerance. Each contour is flattened and its raw
//! offset drawn: every edge moved outward, an arc around each convex
//! corner, and a path through the corner itself at each concave one. The
//! raw offsets, filled under the nonzero rule with the original contours,
//! are exactly the sum: the loops a concave corner or a closing counter
//! makes wind the right way. `fill.nonzero` then resolves them into simple
//! loops.

const std = @import("std");
const root = @import("root.zig");
const fill = @import("fill.zig");

const Allocator = std.mem.Allocator;
const Point = root.Point;
const Segment = root.Segment;
const Contour = root.Contour;
const Outline = root.Outline;

/// `o` grown outward by `d` (its units), as straight segments within `tol`
/// of the exact result, allocated from `a` (an arena suits). A distance of
/// zero or less returns `o` itself.
pub fn grow(a: Allocator, o: Outline, d: f64, tol: f64) Allocator.Error!Outline {
    if (!(d > 0) or o.contours.len == 0) return o;
    var scratch_state: std.heap.ArenaAllocator = .init(a);
    defer scratch_state.deinit();
    const s = scratch_state.allocator();

    // Flatten, dropping repeated points; then face every contour so the
    // filled side is on its left (outer contours counter-clockwise), which
    // fonts do not agree on: TrueType winds outer contours clockwise.
    var polys: std.ArrayList([]Point) = .empty;
    var area: f64 = 0;
    for (o.contours) |c| {
        const p = try flatten(s, c, tol);
        if (p.len < 3) continue;
        area += signedArea(p);
        try polys.append(s, p);
    }
    if (area < 0) for (polys.items) |p| std.mem.reverse(Point, p);

    var all: std.ArrayList([]const Point) = .empty;
    for (polys.items) |p| {
        try all.append(s, p);
        try all.append(s, try offset(s, p, d, tol));
    }
    const region = try fill.nonzero(s, all.items, tol * 1e-3);

    const contours = try a.alloc(Contour, region.loops.len);
    for (region.loops, contours) |loop, *c| {
        const segs = try a.alloc(Segment, loop.len);
        for (loop, 0..) |p, i| segs[i] = .{ .line = .{ p, loop[(i + 1) % loop.len] } };
        c.* = .{ .segments = segs };
    }
    return .{ .contours = contours };
}

/// A contour as points within `tol` of it, the closing point not repeated.
fn flatten(a: Allocator, c: Contour, tol: f64) Allocator.Error![]Point {
    var pts: std.ArrayList(Point) = .empty;
    for (c.segments) |seg| {
        const ps = seg.points();
        // How far the control points stray from the chord bounds how far
        // the curve does; pieces shrink as the square root of it.
        var dev: f64 = 0;
        for (ps[1 .. ps.len - 1]) |q| dev = @max(dev, distToLine(q, ps[0], ps[ps.len - 1]));
        const n: usize = if (seg == .line) 1 else @max(1, @min(256, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol) * 1.5)))));
        for (1..n + 1) |i| {
            const p = seg.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
            if (pts.items.len > 0 and near(pts.items[pts.items.len - 1], p, tol * 1e-3)) continue;
            try pts.append(a, p);
        }
    }
    while (pts.items.len > 1 and near(pts.items[0], pts.items[pts.items.len - 1], tol * 1e-3)) _ = pts.pop();
    return pts.items;
}

/// The raw offset of polygon `p` (filled on its left) by `d` outward.
fn offset(a: Allocator, p: []const Point, d: f64, tol: f64) Allocator.Error![]Point {
    var out: std.ArrayList(Point) = .empty;
    const n = p.len;
    // The largest turn one arc step may make and stay within `tol`.
    const step = 2 * std.math.acos(@max(0, 1 - tol / d));
    for (0..n) |i| {
        const v = p[i];
        const din = unit(sub(v, p[(i + n - 1) % n]));
        const dout = unit(sub(p[(i + 1) % n], v));
        // Outward is to the right of travel.
        const nin: Point = .{ .x = din.y, .y = -din.x };
        const nout: Point = .{ .x = dout.y, .y = -dout.x };
        try out.append(a, add(v, scale(nin, d)));
        const turn = din.cross(dout);
        const dot = din.x * dout.x + din.y * dout.y;
        if (turn > -1e-9) {
            // Convex (a left turn): round the corner.
            // (A straight run, or a hair's turn the wrong way, is no arc.)
            const angle = @max(0, std.math.atan2(turn, dot));
            const k: usize = @max(1, @as(usize, @intFromFloat(@ceil(angle / @max(step, 1e-6)))));
            const a0 = std.math.atan2(nin.y, nin.x);
            for (1..k) |j| {
                const t = a0 + angle * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(k));
                try out.append(a, .{ .x = v.x + d * @cos(t), .y = v.y + d * @sin(t) });
            }
        } else {
            // Concave: through the corner, so the swallowtail closes.
            try out.append(a, v);
        }
        try out.append(a, add(v, scale(nout, d)));
    }
    return out.items;
}

fn signedArea(p: []const Point) f64 {
    var s: f64 = 0;
    for (p, 0..) |q, i| s += q.cross(p[(i + 1) % p.len]);
    return s / 2;
}

fn distToLine(q: Point, a: Point, b: Point) f64 {
    const ab = sub(b, a);
    const l = @sqrt(ab.x * ab.x + ab.y * ab.y);
    if (l == 0) return @sqrt((q.x - a.x) * (q.x - a.x) + (q.y - a.y) * (q.y - a.y));
    return @abs(ab.cross(sub(q, a))) / l;
}

fn near(a: Point, b: Point, eps: f64) bool {
    return @abs(a.x - b.x) <= eps and @abs(a.y - b.y) <= eps;
}

fn sub(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn add(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn scale(a: Point, k: f64) Point {
    return .{ .x = a.x * k, .y = a.y * k };
}
fn unit(a: Point) Point {
    const l = @sqrt(a.x * a.x + a.y * a.y);
    return if (l == 0) a else scale(a, 1 / l);
}

const testing = std.testing;

fn square(x0: f64, y0: f64, x1: f64, y1: f64, ccw: bool) [4]Segment {
    const p = [4]Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
    var s: [4]Segment = undefined;
    for (0..4) |i| {
        const j = if (ccw) i else 3 - i;
        const k = if (ccw) (i + 1) % 4 else (6 - i) % 4;
        s[i] = .{ .line = .{ p[j], p[k] } };
    }
    return s;
}

fn regionArea(o: Outline) f64 {
    var s: f64 = 0;
    for (o.contours) |c| s += c.signedArea();
    return @abs(s);
}

test "a square grows by its perimeter times d, plus a disc at its corners" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ true, false }) |ccw| {
        const sq = square(0, 0, 10, 10, ccw);
        const g = try grow(a, .{ .contours = &.{.{ .segments = &sq }} }, 1, 1e-4);
        try testing.expectApproxEqAbs(100 + 40 + std.math.pi, regionArea(g), 1e-2);
        const b = g.bounds();
        try testing.expectApproxEqAbs(@as(f64, -1), b.x0, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 11), b.y1, 1e-9);
    }
}

test "a counter shrinks, and closes when the growth is more than half its width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A 10 square with a 4 square hole, wound opposite (TrueType's way).
    const outer = square(0, 0, 10, 10, false);
    const hole = square(3, 3, 7, 7, true);
    const o: Outline = .{ .contours = &.{ .{ .segments = &outer }, .{ .segments = &hole } } };
    const g = try grow(a, o, 1, 1e-4);
    // Outer 140 + pi; the hole, inset by 1, is 2 by 2 with square corners.
    try testing.expectApproxEqAbs(140 + std.math.pi - 4, regionArea(g), 1e-2);
    try testing.expectEqual(@as(usize, 2), g.contours.len);
    const closed = try grow(a, o, 2.5, 1e-4);
    try testing.expectEqual(@as(usize, 1), closed.contours.len);
    try testing.expectApproxEqAbs(15 * 15 - 25 + 25 * std.math.pi / 4.0, regionArea(closed), 5e-2);
}

test "an L's inner corner stays sharp" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 0, .y = 4 } };
    var segs: [6]Segment = undefined;
    for (0..6) |i| segs[i] = .{ .line = .{ pts[i], pts[(i + 1) % 6] } };
    const g = try grow(a, .{ .contours = &.{.{ .segments = &segs }} }, 0.5, 1e-4);
    // 7 + perimeter 16 * 0.5 + five convex quarter discs, less the 0.5
    // square where the inner corner's two edges' strips overlap.
    const expect = 7 + 8 + 5 * std.math.pi * 0.25 / 4.0 - 0.25;
    try testing.expectApproxEqAbs(expect, regionArea(g), 1e-2);
}

test "straight runs and hairline turns the wrong way make no arc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A square with a collinear point in its bottom edge, and one nudged a
    // hair inward (a turn of about -1e-12) in its top edge.
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 5, .y = 10 - 1e-11 }, .{ .x = 0, .y = 10 } };
    var segs: [6]Segment = undefined;
    for (0..6) |i| segs[i] = .{ .line = .{ pts[i], pts[(i + 1) % 6] } };
    const g = try grow(a, .{ .contours = &.{.{ .segments = &segs }} }, 1, 1e-4);
    try testing.expectApproxEqAbs(140 + std.math.pi, regionArea(g), 1e-2);
}
