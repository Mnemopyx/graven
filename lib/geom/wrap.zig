//! Wraps: a closed path round a set of points that keeps at least a
//! margin from each and bends nowhere more sharply than a given radius.
//!
//! The path is the convex hull of discs of the radius: straight lines
//! tangent to two discs and arcs of the discs between them (the Dubins
//! pieces, exact lines and arcs). Where the radius is no more than the
//! margin, the discs are the margin's, about the hull's corners: the hull
//! grown by the margin. Where it is more, each corner's disc moves in
//! along the corner's bisector by the difference, so it still holds the
//! margin's disc about the corner, and every side stays at least the
//! margin out: the hull grown by the margin lies inside the wrap.

const std = @import("std");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = root.Point;
const Segment = root.Segment;
const Outline = root.Outline;

/// The convex hull of `pts`, counter-clockwise, without repeated or
/// collinear points.
pub fn hull(a: Allocator, pts: []const Point) Allocator.Error![]Point {
    if (pts.len == 0) return &.{};
    const sorted = try a.dupe(Point, pts);
    std.mem.sort(Point, sorted, {}, struct {
        fn lt(_: void, p: Point, q: Point) bool {
            return if (p.x != q.x) p.x < q.x else p.y < q.y;
        }
    }.lt);
    const out = try a.alloc(Point, 2 * sorted.len + 1);
    var k: usize = 0;
    const turn = struct {
        fn f(o: Point, p: Point, q: Point) f64 {
            return (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
        }
    }.f;
    for (sorted) |p| {
        while (k >= 2 and turn(out[k - 2], out[k - 1], p) <= 1e-12) k -= 1;
        out[k] = p;
        k += 1;
    }
    const lower = k + 1;
    var i = sorted.len;
    while (i > 1) {
        i -= 1;
        const p = sorted[i - 1];
        while (k >= lower and turn(out[k - 2], out[k - 1], p) <= 1e-12) k -= 1;
        out[k] = p;
        k += 1;
    }
    // The last point is the first again.
    const n = if (k > 1) k - 1 else k;
    return out[0..n];
}

/// The wrap round `pts`: at least `margin` from each, bending no more
/// sharply than `radius` (both > 0 for a curve; 0 gives the hull itself
/// grown by nothing). One counter-clockwise contour of lines and arcs.
pub fn wrap(a: Allocator, pts: []const Point, margin: f64, radius: f64) Allocator.Error!Outline {
    const h = try hull(a, pts);
    if (h.len == 0) return Outline.blank;
    const m = @max(margin, 0);
    const r = @max(radius, m);
    // The discs' centres: the corners, moved in where the radius is more
    // than the margin.
    var centres = h;
    const d = r - m;
    if (d > 0 and h.len >= 2) {
        centres = try a.alloc(Point, h.len);
        for (h, 0..) |p, i| {
            if (h.len == 2) {
                // A segment: in along it, towards the other end.
                const q = h[1 - i];
                const l = @max(dist(p, q), 1e-12);
                const t = @min(d, l / 2);
                centres[i] = .{ .x = p.x + (q.x - p.x) / l * t, .y = p.y + (q.y - p.y) / l * t };
                continue;
            }
            const prev = h[(i + h.len - 1) % h.len];
            const next = h[(i + 1) % h.len];
            const n1 = outward(prev, p);
            const n2 = outward(p, next);
            var bx = n1.x + n2.x;
            var by = n1.y + n2.y;
            const bl = @sqrt(bx * bx + by * by);
            if (bl < 1e-12) {
                bx = n1.x;
                by = n1.y;
            } else {
                bx /= bl;
                by /= bl;
            }
            centres[i] = .{ .x = p.x - d * bx, .y = p.y - d * by };
        }
        centres = try hull(a, centres);
    }
    var segs: std.ArrayList(Segment) = .empty;
    var buf: [4]Segment = undefined;
    if (centres.len == 1 or r == 0 and centres.len < 3) {
        if (r == 0) return Outline.blank;
        try segs.appendSlice(a, root.arc(centres[0], r, 0, 2 * std.math.pi, &buf));
        return one(a, segs.items);
    }
    const n = centres.len;
    for (0..n) |i| {
        const c = centres[i];
        const c_next = centres[(i + 1) % n];
        const c_prev = centres[(i + n - 1) % n];
        const n_in = outward(c_prev, c);
        const n_out = outward(c, c_next);
        // The arc about this centre from the side before to the side after.
        if (r > 0) {
            const a0 = std.math.atan2(n_in.y, n_in.x);
            var sweep = std.math.atan2(n_out.y, n_out.x) - a0;
            while (sweep < 0) sweep += 2 * std.math.pi;
            while (sweep >= 2 * std.math.pi) sweep -= 2 * std.math.pi;
            if (sweep > 1e-9) try segs.appendSlice(a, root.arc(c, r, a0, sweep, &buf));
        }
        // The side to the next centre's disc.
        const p0: Point = .{ .x = c.x + r * n_out.x, .y = c.y + r * n_out.y };
        const p1: Point = .{ .x = c_next.x + r * n_out.x, .y = c_next.y + r * n_out.y };
        try segs.append(a, .{ .line = .{ p0, p1 } });
    }
    return one(a, segs.items);
}

fn one(a: Allocator, segs: []const Segment) Allocator.Error!Outline {
    const contours = try a.alloc(root.Contour, 1);
    contours[0] = .{ .segments = segs };
    return .{ .contours = contours };
}

fn dist(p: Point, q: Point) f64 {
    return @sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y));
}

/// The unit normal to the right of travel from `p` to `q`: outward on a
/// counter-clockwise loop.
fn outward(p: Point, q: Point) Point {
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const l = @max(@sqrt(dx * dx + dy * dy), 1e-300);
    return .{ .x = dy / l, .y = -dx / l };
}

test "a square's wrap with the radius the margin is the square grown, its corners round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sq = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 }, .{ .x = 5, .y = 5 } };
    const o = try wrap(a, &sq, 1, 1);
    const b = o.bounds();
    try std.testing.expectApproxEqAbs(-1, b.x0, 1e-9);
    try std.testing.expectApproxEqAbs(11, b.y1, 1e-9);
    // 12 × 12 less the four corners' squares outside their quarter discs.
    try std.testing.expectApproxEqAbs(144 - 4 + std.math.pi, @abs(o.contours[0].signedArea()), 1e-6);
}

test "a larger radius keeps the margin and rounds the corners at the radius" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sq = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const o = try wrap(a, &sq, 1, 4);
    // Every corner of the square at least the margin inside.
    for (sq) |p| {
        var best: f64 = std.math.inf(f64);
        for (o.contours[0].segments) |s| for (0..65) |i| {
            const q = s.at(@as(f64, @floatFromInt(i)) / 64);
            best = @min(best, dist(p, q));
        };
        try std.testing.expect(best >= 1 - 1e-6);
    }
}
