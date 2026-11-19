//! Outlines simplified to a tolerance: curves flattened, then runs of
//! nearly straight pieces merged (Douglas–Peucker), so no point of the
//! result strays from the original by more than the tolerance. For viewing
//! (the manufacturing view's 3D parts, decided 2026-11-19: a plan's "Max
//! error"), not for output.
//!
//! Regions that share a boundary (an inlay's legend, and the hole round it
//! in the material) must simplify it alike, or slivers open between them.
//! So each segment is flattened from its lesser end, and each closed
//! contour is simplified from its lesser point, counter-clockwise, whatever
//! its own start and direction: the same contour, from either side, gives
//! the same points.
//!
//! A contour that would collapse below three points (a shape thinner than
//! the tolerance) is kept as flattened, never lost. A stroke thinner than
//! twice the tolerance can still have its two sides cross once simplified;
//! such a face is the caller's to skip or report.

const std = @import("std");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;
const Point = root.Point;
const Segment = root.Segment;
const Contour = root.Contour;
const Outline = root.Outline;

/// `o` as straight segments within `tol` of it, each contour's direction
/// kept; contours that collapse below three points are dropped.
pub fn outline(a: Allocator, o: Outline, tol: f64) Allocator.Error!Outline {
    var out: std.ArrayList(Contour) = .empty;
    for (o.contours) |c| {
        const pts = try contour(a, c, tol);
        if (pts.len < 3) continue;
        const segs = try a.alloc(Segment, pts.len);
        for (pts, 0..) |p, i| segs[i] = .{ .line = .{ p, pts[(i + 1) % pts.len] } };
        try out.append(a, .{ .segments = segs });
    }
    return .{ .contours = out.items };
}

/// One closed contour simplified: its points, the closing one not repeated,
/// in its own direction.
pub fn contour(a: Allocator, c: Contour, tol: f64) Allocator.Error![]Point {
    var pts: std.ArrayList(Point) = .empty;
    // Each segment adds the points after its start, so every vertex comes
    // once: the last is the first segment's start.
    for (c.segments) |s| try flattenCanonical(a, &pts, s, tol);
    var p = pts.items;
    if (p.len < 4) return p;
    // Canonical: from the lesser point, counter-clockwise.
    const ccw = signedArea(p) >= 0;
    if (!ccw) std.mem.reverse(Point, p);
    var least: usize = 0;
    for (p, 0..) |q, i| if (less(q, p[least])) {
        least = i;
    };
    std.mem.rotate(Point, p, least);
    // Closed Douglas–Peucker: split at the point farthest from the first,
    // simplify both halves.
    var far: usize = 1;
    var far_d: f64 = -1;
    for (p, 0..) |q, i| {
        const d = dist2(q, p[0]);
        if (d > far_d) {
            far_d = d;
            far = i;
        }
    }
    const keep = try a.alloc(bool, p.len + 1);
    @memset(keep, false);
    keep[0] = true;
    keep[far] = true;
    keep[p.len] = true;
    // The ring closed for the second half: index p.len stands for p[0].
    const ring = try a.alloc(Point, p.len + 1);
    @memcpy(ring[0..p.len], p);
    ring[p.len] = p[0];
    try dp(a, ring, keep, 0, far, tol);
    try dp(a, ring, keep, far, p.len, tol);
    var out: std.ArrayList(Point) = .empty;
    for (0..p.len) |i| if (keep[i]) try out.append(a, p[i]);
    // A shape thinner than the tolerance (a superscript minus) would
    // collapse to a line: kept as flattened rather than lost.
    if (out.items.len >= 3) p = out.items;
    if (!ccw) std.mem.reverse(Point, p);
    return p;
}

/// Douglas–Peucker between kept points `i` and `j` (iterative).
fn dp(a: Allocator, pts: []const Point, keep: []bool, from: usize, to: usize, tol: f64) Allocator.Error!void {
    var stack: std.ArrayList([2]usize) = .empty;
    try stack.append(a, .{ from, to });
    while (stack.pop()) |ij| {
        const i = ij[0];
        const j = ij[1];
        if (j <= i + 1) continue;
        var best: usize = i;
        var best_d: f64 = -1;
        for (i + 1..j) |k| {
            const d = distToSegment(pts[k], pts[i], pts[j]);
            if (d > best_d) {
                best_d = d;
                best = k;
            }
        }
        if (best_d > tol) {
            keep[best] = true;
            try stack.append(a, .{ i, best });
            try stack.append(a, .{ best, j });
        }
    }
}

fn less(p: Point, q: Point) bool {
    return p.x < q.x or (p.x == q.x and p.y < q.y);
}

fn dist2(p: Point, q: Point) f64 {
    return (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y);
}

fn distToSegment(p: Point, s0: Point, s1: Point) f64 {
    const dx = s1.x - s0.x;
    const dy = s1.y - s0.y;
    const l2 = dx * dx + dy * dy;
    const t = if (l2 > 0) std.math.clamp(((p.x - s0.x) * dx + (p.y - s0.y) * dy) / l2, 0, 1) else 0;
    return @sqrt(dist2(p, .{ .x = s0.x + t * dx, .y = s0.y + t * dy }));
}

fn signedArea(p: []const Point) f64 {
    var s: f64 = 0;
    for (p, 0..) |q, i| s += q.cross(p[(i + 1) % p.len]);
    return s / 2;
}

/// A segment's points after its start, chords within `tol`, sampled from
/// its lesser end so a segment and its reverse give the same points.
fn flattenCanonical(a: Allocator, pts: *std.ArrayList(Point), s: Segment, tol: f64) Allocator.Error!void {
    const p = s.start();
    const q = s.end();
    if (less(p, q) or p.eql(q)) return flatten(a, pts, s, tol);
    var tmp: std.ArrayList(Point) = .empty;
    try tmp.append(a, q);
    try flatten(a, &tmp, s.reversed(), tol);
    var k = tmp.items.len - 1;
    while (k > 0) {
        k -= 1;
        try pts.append(a, tmp.items[k]);
    }
}

fn flatten(a: Allocator, pts: *std.ArrayList(Point), s: Segment, tol: f64) Allocator.Error!void {
    const n: usize = switch (s) {
        .line => 1,
        .conic => |c| blk: {
            if (!(c.w > 0 and c.w < 1)) break :blk 16;
            const e = c.ellipse();
            const r = @max(@sqrt(e.a.x * e.a.x + e.a.y * e.a.y), @sqrt(e.b.x * e.b.x + e.b.y * e.b.y));
            const step = 2 * std.math.acos(@max(0, 1 - tol / @max(r, 1e-12)));
            break :blk @max(2, @min(256, @as(usize, @intFromFloat(@ceil(2 * e.half / @max(step, 1e-6))))));
        },
        .quad => |p| blk: {
            const dev = 0.25 * @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            break :blk @max(1, @min(256, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol))))));
        },
        .cubic => |p| blk: {
            const d1 = @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const d2 = @sqrt(sq(p[1].x - 2 * p[2].x + p[3].x) + sq(p[1].y - 2 * p[2].y + p[3].y));
            break :blk @max(1, @min(256, @as(usize, @intFromFloat(@ceil(@sqrt(0.75 * @max(d1, d2) / tol))))));
        },
    };
    for (1..n) |i| try pts.append(a, s.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
    try pts.append(a, s.end());
}

fn sq(x: f64) f64 {
    return x * x;
}

const testing = std.testing;

fn polyContour(a: Allocator, p: []const Point) !Contour {
    const segs = try a.alloc(Segment, p.len);
    for (p, 0..) |q, i| segs[i] = .{ .line = .{ q, p[(i + 1) % p.len] } };
    return .{ .segments = segs };
}

test "a near-straight run merges; a corner stays; within the tolerance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A square whose bottom edge wobbles by 0.01 in ten pieces.
    var pts: std.ArrayList(Point) = .empty;
    for (0..10) |i| try pts.append(a, .{ .x = @floatFromInt(i), .y = if (i % 2 == 1) 0.01 else 0 });
    try pts.appendSlice(a, &.{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } });
    const s = try contour(a, try polyContour(a, pts.items), 0.05);
    try testing.expectEqual(4, s.len);
    // Finer than the wobble: kept.
    try testing.expect((try contour(a, try polyContour(a, pts.items), 0.005)).len > 4);
}

test "a bar thinner than the tolerance is kept, not lost" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bar = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 0.6, .y = 0 }, .{ .x = 0.6, .y = 0.07 }, .{ .x = 0, .y = 0.07 } };
    const s = try outline(a, .{ .contours = &.{try polyContour(a, &bar)} }, 0.05);
    try testing.expectEqual(1, s.contours.len);
    try testing.expectEqual(4, s.contours[0].segments.len);
}

test "a contour and its reverse, from different starts, give the same points" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A circle of 64 points, slightly irregular.
    var fwd: std.ArrayList(Point) = .empty;
    for (0..64) |i| {
        const t = @as(f64, @floatFromInt(i)) / 64 * 2 * std.math.pi;
        const r = 3 + 0.02 * @sin(7 * t);
        try fwd.append(a, .{ .x = r * @cos(t), .y = r * @sin(t) });
    }
    var back: std.ArrayList(Point) = .empty;
    for (0..64) |i| try back.append(a, fwd.items[(64 + 17 - i) % 64]);
    const sf = try contour(a, try polyContour(a, fwd.items), 0.05);
    const sb = try contour(a, try polyContour(a, back.items), 0.05);
    try testing.expectEqual(sf.len, sb.len);
    // Same set of points (the reverse runs the other way).
    std.mem.reverse(Point, sb);
    var found: usize = 0;
    for (sf) |p| for (sb) |q| {
        if (p.eql(q)) found += 1;
    };
    try testing.expectEqual(sf.len, found);
    try testing.expect(sf.len < 64);
}
