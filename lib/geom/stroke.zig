//! Strokes: the area a pen of a given width covers along a path, as an
//! outline (a stroke font's centreline turned into an outline font's ink).
//!
//! A path comes as polylines (curves flattened to the drawing tolerance
//! first), each open or closed. Every piece of the stroke is a polygon
//! wound counter-clockwise: a rectangle along each segment, a join at each
//! corner on its outer side (miter, within the miter limit, else bevel;
//! round; bevel), and a cap at each open end (butt adds nothing; square a
//! half-width square; round a half disc). The pieces are merged into simple
//! loops by the nonzero rule (`fill.nonzero`), so overlaps where a path
//! crosses itself or turns sharply are one region. Round parts are polygons
//! within the tolerance of the true circle, their vertices on it.

const std = @import("std");
const root = @import("root.zig");
const fill = @import("fill.zig");

const Allocator = std.mem.Allocator;
const Point = root.Point;
const Outline = root.Outline;
const Contour = root.Contour;
const Segment = root.Segment;

pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };

pub const Style = struct {
    width: f64,
    cap: Cap = .butt,
    join: Join = .miter,
    /// The longest a miter may be, as a multiple of the width (SVG's
    /// stroke-miterlimit); past it the corner is bevelled.
    miter_limit: f64 = 4,
};

/// A polyline of a path: its points, and whether its end joins its start.
pub const Polyline = struct {
    pts: []const Point,
    closed: bool = false,
};

/// Polyline `line` cut into its dashes (`pattern`: lengths on and off in
/// turn, mm; an odd count repeats twice over; `offset` into it where the
/// line starts), each an open polyline appended to `out`. A dash of length
/// 0 is a point's worth of line (a dot, under a round or square cap). A
/// pattern with no length at all leaves the line whole.
pub fn dashed(a: Allocator, line: Polyline, pattern: []const f64, offset: f64, out: *std.ArrayList(Polyline)) Allocator.Error!void {
    var period: f64 = 0;
    for (pattern) |d| period += @max(0, d);
    const reps: usize = if (pattern.len % 2 == 1) 2 else 1;
    period *= @floatFromInt(reps);
    if (!(period > 0) or line.pts.len < 2) return out.append(a, line);
    const n = pattern.len * reps;
    // The points round, a closed line's first again at its end.
    var pts: std.ArrayList(Point) = .empty;
    try pts.appendSlice(a, line.pts);
    if (line.closed) try pts.append(a, line.pts[0]);
    // Where in the pattern the line starts.
    var k: usize = 0;
    var left = @mod(offset, period);
    while (left > 0) {
        const d = @max(0, pattern[k % pattern.len]);
        if (left < d) break;
        left -= d;
        k = (k + 1) % n;
    }
    var remain = @max(0, pattern[k % pattern.len]) - left;
    var on = k % 2 == 0;
    var cur: std.ArrayList(Point) = .empty;
    if (on) try cur.append(a, pts.items[0]);
    const dot = 1e-4;
    for (pts.items[0 .. pts.items.len - 1], pts.items[1..]) |p, q| {
        const len = std.math.hypot(q.x - p.x, q.y - p.y);
        if (!(len > 0)) continue;
        var t: f64 = 0;
        while (len - t > remain) {
            t += remain;
            const at: Point = .{ .x = p.x + (q.x - p.x) * t / len, .y = p.y + (q.y - p.y) * t / len };
            if (on) {
                try cur.append(a, at);
                if (cur.items.len == 1 or (cur.items.len == 2 and cur.items[0].x == at.x and cur.items[0].y == at.y)) {
                    // A dot: a point's worth of line along the path.
                    cur.items.len = 1;
                    try cur.append(a, .{ .x = at.x + (q.x - p.x) * dot / len, .y = at.y + (q.y - p.y) * dot / len });
                }
                try out.append(a, .{ .pts = try cur.toOwnedSlice(a) });
            } else {
                cur.clearRetainingCapacity();
                try cur.append(a, at);
            }
            on = !on;
            k = (k + 1) % n;
            remain = @max(0, pattern[k % pattern.len]);
        }
        remain -= len - t;
        if (on) try cur.append(a, q);
    }
    if (on and cur.items.len >= 2) try out.append(a, .{ .pts = try cur.toOwnedSlice(a) });
}

test "dashes: a 10 mm line in 2 on, 1 off is four dashes and a short one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Polyline) = .empty;
    try dashed(a, .{ .pts = &.{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 10, .y = 0 } } }, &.{ 2, 1 }, 0, &out);
    try std.testing.expectEqual(4, out.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 9), out.items[3].pts[0].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), out.items[3].pts[out.items[3].pts.len - 1].x, 1e-9);
    // The second dash runs through the corner point at 4.
    try std.testing.expectEqual(3, out.items[1].pts.len);
    // Dots: 0 on, 1 off.
    out.clearRetainingCapacity();
    try dashed(a, .{ .pts = &.{ .{ .x = 0, .y = 0 }, .{ .x = 3.5, .y = 0 } } }, &.{ 0, 1 }, 0, &out);
    try std.testing.expectEqual(4, out.items.len);
}

/// The stroke of `lines` in `style` as an outline of simple loops (outer
/// counter-clockwise, holes clockwise), round parts within `tol`.
pub fn stroke(a: Allocator, lines: []const Polyline, style: Style, tol: f64) Allocator.Error!Outline {
    if (!(style.width > 0)) return Outline.blank;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const s = scratch.allocator();
    var polys: std.ArrayList([]const Point) = .empty;
    for (lines) |l| try pieces(s, &polys, l, style, tol);
    if (polys.items.len == 0) return Outline.blank;
    const region = try fill.nonzero(s, polys.items, tol * 1e-3);
    return loopsOutline(a, region.loops);
}

/// Loops of points as an outline of line segments.
pub fn loopsOutline(a: Allocator, loops: []const []const Point) Allocator.Error!Outline {
    var contours: std.ArrayList(Contour) = .empty;
    for (loops) |loop| {
        if (loop.len < 3) continue;
        const segs = try a.alloc(Segment, loop.len);
        for (segs, 0..) |*sg, i| sg.* = .{ .line = .{ loop[i], loop[(i + 1) % loop.len] } };
        try contours.append(a, .{ .segments = segs });
    }
    return .{ .contours = contours.items };
}

/// The stroke's pieces for one polyline, each counter-clockwise.
fn pieces(a: Allocator, out: *std.ArrayList([]const Point), l: Polyline, style: Style, tol: f64) Allocator.Error!void {
    const h = style.width / 2;
    // Repeated points dropped (a zero-length segment has no direction).
    var pts: std.ArrayList(Point) = .empty;
    for (l.pts) |p| {
        if (pts.items.len > 0 and near(pts.items[pts.items.len - 1], p, tol * 1e-3)) continue;
        try pts.append(a, p);
    }
    var closed = l.closed;
    while (closed and pts.items.len > 1 and near(pts.items[0], pts.items[pts.items.len - 1], tol * 1e-3)) _ = pts.pop();
    const p = pts.items;
    if (p.len == 0) return;
    if (p.len == 1) {
        // A dot: only a round or square cap shows it.
        switch (style.cap) {
            .butt => {},
            .round => try out.append(a, try disc(a, p[0], h, tol)),
            .square => try out.append(a, try ccw(a, &.{ .{ .x = p[0].x - h, .y = p[0].y - h }, .{ .x = p[0].x + h, .y = p[0].y - h }, .{ .x = p[0].x + h, .y = p[0].y + h }, .{ .x = p[0].x - h, .y = p[0].y + h } })),
        }
        return;
    }
    if (p.len == 2) closed = false;
    const n = p.len;
    const edges = if (closed) n else n - 1;
    for (0..edges) |i| {
        const a0 = p[i];
        const a1 = p[(i + 1) % n];
        const nn = normal(a0, a1);
        try out.append(a, try ccw(a, &.{ add(a0, nn, h), add(a1, nn, h), add(a1, nn, -h), add(a0, nn, -h) }));
    }
    // Joins: at every corner of a closed line, the inner corners of an
    // open one.
    const first: usize = if (closed) 0 else 1;
    const last: usize = if (closed) n else n - 1;
    for (first..last) |i| {
        const prev = p[(i + n - 1) % n];
        const v = p[i];
        const next = p[(i + 1) % n];
        try join(a, out, prev, v, next, h, style, tol);
    }
    if (!closed) {
        try cap(a, out, p[1], p[0], h, style.cap, tol);
        try cap(a, out, p[n - 2], p[n - 1], h, style.cap, tol);
    }
}

fn join(a: Allocator, out: *std.ArrayList([]const Point), prev: Point, v: Point, next: Point, h: f64, style: Style, tol: f64) Allocator.Error!void {
    const n0 = normal(prev, v);
    const n1 = normal(v, next);
    const turn = (Point{ .x = v.x - prev.x, .y = v.y - prev.y }).cross(.{ .x = next.x - v.x, .y = next.y - v.y });
    if (@abs(turn) < 1e-15 and n0.x * n1.x + n0.y * n1.y > 0) return; // straight on
    if (style.join == .round) {
        try out.append(a, try disc(a, v, h, tol));
        return;
    }
    // The outer side: right of travel for a left turn, left for a right.
    const side: f64 = if (turn > 0) -1 else 1;
    const pa = add(v, n0, side * h);
    const pb = add(v, n1, side * h);
    if (style.join == .miter) {
        // The miter's tip: where the two offset edges meet.
        const cos_t = std.math.clamp(n0.x * n1.x + n0.y * n1.y, -1, 1);
        const half = @sqrt((1 + cos_t) / 2); // cos of half the turn
        if (half > 1e-9 and 1 / half <= style.miter_limit) {
            const mx = n0.x + n1.x;
            const my = n0.y + n1.y;
            const ml = @sqrt(mx * mx + my * my);
            const tip: Point = .{ .x = v.x + side * h / half * mx / ml, .y = v.y + side * h / half * my / ml };
            try out.append(a, try ccw(a, &.{ v, pa, tip, pb }));
            return;
        }
    }
    try out.append(a, try ccw(a, &.{ v, pa, pb }));
}

fn cap(a: Allocator, out: *std.ArrayList([]const Point), from: Point, end: Point, h: f64, kind: Cap, tol: f64) Allocator.Error!void {
    switch (kind) {
        .butt => {},
        .round => try out.append(a, try disc(a, end, h, tol)),
        .square => {
            const nn = normal(from, end);
            const d: Point = .{ .x = nn.y * h, .y = -nn.x * h }; // along, outward
            const e2: Point = .{ .x = end.x + d.x, .y = end.y + d.y };
            try out.append(a, try ccw(a, &.{ add(end, nn, h), add(e2, nn, h), add(e2, nn, -h), add(end, nn, -h) }));
        },
    }
}

/// A disc of radius `r` about `c` as a polygon whose sides stray no more
/// than `tol` inside the circle.
fn disc(a: Allocator, c: Point, r: f64, tol: f64) Allocator.Error![]const Point {
    const step = 2 * std.math.acos(@max(0, 1 - @min(tol, r) / r));
    const k: usize = @max(8, @min(720, @as(usize, @intFromFloat(@ceil(2 * std.math.pi / @max(step, 1e-6))))));
    const pts = try a.alloc(Point, k);
    for (pts, 0..) |*q, i| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(k));
        q.* = .{ .x = c.x + r * @cos(t), .y = c.y + r * @sin(t) };
    }
    return pts;
}

/// The unit normal to the left of travel from `p` to `q`.
fn normal(p: Point, q: Point) Point {
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const l = @sqrt(dx * dx + dy * dy);
    return .{ .x = -dy / l, .y = dx / l };
}

fn add(p: Point, d: Point, s: f64) Point {
    return .{ .x = p.x + d.x * s, .y = p.y + d.y * s };
}

fn near(p: Point, q: Point, eps: f64) bool {
    return @abs(p.x - q.x) <= eps and @abs(p.y - q.y) <= eps;
}

/// `pts` copied, wound counter-clockwise.
fn ccw(a: Allocator, pts: []const Point) Allocator.Error![]const Point {
    var s: f64 = 0;
    for (pts, 0..) |p, i| s += p.cross(pts[(i + 1) % pts.len]);
    const out = try a.alloc(Point, pts.len);
    if (s >= 0) @memcpy(out, pts) else for (pts, 0..) |p, i| {
        out[pts.len - 1 - i] = p;
    }
    return out;
}

fn area(o: Outline) f64 {
    var s: f64 = 0;
    for (o.contours) |c| s += c.signedArea();
    return s;
}

test "a straight stroke with butt caps is its rectangle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try stroke(a, &.{.{ .pts = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } } }}, .{ .width = 2 }, 1e-3);
    try std.testing.expectApproxEqAbs(20, area(o), 1e-9);
    const b = o.bounds();
    try std.testing.expectApproxEqAbs(-1, b.y0, 1e-12);
    try std.testing.expectApproxEqAbs(10, b.x1, 1e-12);
}

test "caps: square adds a half width at each end, round a half disc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line: []const Polyline = &.{.{ .pts = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } } }};
    const sq = try stroke(a, line, .{ .width = 2, .cap = .square }, 1e-3);
    try std.testing.expectApproxEqAbs(24, area(sq), 1e-9);
    const rd = try stroke(a, line, .{ .width = 2, .cap = .round }, 1e-4);
    try std.testing.expectApproxEqAbs(20 + std.math.pi, area(rd), 1e-3);
}

test "an L with a miter joint fills its corner square; bevel cuts it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l: []const Polyline = &.{.{ .pts = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } } }};
    const mi = try stroke(a, l, .{ .width = 2 }, 1e-3);
    // Two 10 × 2 bands overlapping in a 1 × 1 square, plus the corner's
    // missing 1 × 1 square: 40 - 1 + 1.
    try std.testing.expectApproxEqAbs(40, area(mi), 1e-9);
    const bv = try stroke(a, l, .{ .width = 2, .join = .bevel }, 1e-3);
    try std.testing.expectApproxEqAbs(39.5, area(bv), 1e-9);
}

test "a closed square stroked is a frame with a hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sq: []const Polyline = &.{.{ .pts = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } }, .closed = true }};
    const o = try stroke(a, sq, .{ .width = 2 }, 1e-3);
    try std.testing.expectEqual(2, o.contours.len);
    try std.testing.expectApproxEqAbs(12 * 12 - 8 * 8, area(o), 1e-9);
}
