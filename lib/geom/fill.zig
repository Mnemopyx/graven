//! Overlap removal: the region a set of polygons fills under the nonzero
//! rule, as simple loops that neither cross nor overlap.
//!
//! Glyphs from variable fonts keep their overlapping and self-crossing
//! contours (an A's crossbar laid over its legs, a V's inner edges crossing
//! at the bottom); the font format fills them by winding. Triangulators that
//! expect simple polygons do not, so callers resolve the region first.
//!
//! The method is a scanline decomposition. Every vertex height and every
//! crossing height is a level; between two levels no edges cross, so each
//! slab is a run of trapezoids whose winding is read left to right. The
//! filled spans' sides are boundary pieces, and where the filled intervals
//! change at a level, horizontal pieces join them. Pieces run with the
//! filled side on their left and chain end to start into loops: outer loops
//! counter-clockwise, holes clockwise (y up). The trapezoids themselves,
//! split in two, are a triangulation of the region.

const std = @import("std");
const Point = @import("root.zig").Point;

const Allocator = std.mem.Allocator;

const Edge = struct {
    a: Point,
    b: Point,
    /// +1 running up, -1 running down.
    dir: i32,
    /// The levels it spans, by index.
    lo: usize = 0,
    hi: usize = 0,

    fn ymin(e: Edge) f64 {
        return @min(e.a.y, e.b.y);
    }
    fn ymax(e: Edge) f64 {
        return @max(e.a.y, e.b.y);
    }

    /// x at height y; exact at the ends.
    fn xAt(e: Edge, y: f64) f64 {
        if (y == e.a.y) return e.a.x;
        if (y == e.b.y) return e.b.x;
        const t = std.math.clamp((y - e.a.y) / (e.b.y - e.a.y), 0, 1);
        return e.a.x + (e.b.x - e.a.x) * t;
    }
};

const Piece = struct { from: Point, to: Point };

pub const Region = struct {
    /// Simple loops, the filled side on their left: outer loops
    /// counter-clockwise, holes clockwise (y up).
    loops: []const []const Point,
    /// The region exactly, as triangles that do not overlap.
    triangles: []const [3]Point,
};

/// The nonzero region of `polygons` (each closed implicitly) as simple
/// loops, allocated from `a` (an arena suits). Levels closer than `eps`
/// merge, and loops keep no points closer than `eps`: pass a fraction of
/// the drawing tolerance. Triangulators are thrown by slivers shorter than
/// that.
pub fn nonzero(a: Allocator, polygons: []const []const Point, eps: f64) Allocator.Error!Region {
    var scratch_state: std.heap.ArenaAllocator = .init(a);
    defer scratch_state.deinit();
    const s = scratch_state.allocator();

    // Edges, without horizontal ones: they bound no slab.
    var edges: std.ArrayList(Edge) = .empty;
    for (polygons) |poly| {
        for (poly, 0..) |p, i| {
            const q = poly[(i + 1) % poly.len];
            if (p.y == q.y) continue;
            try edges.append(s, .{ .a = p, .b = q, .dir = if (q.y > p.y) 1 else -1 });
        }
    }
    if (edges.items.len == 0) return .{ .loops = &.{}, .triangles = &.{} };

    // Levels: every vertex, and every crossing strictly inside two edges.
    var ys: std.ArrayList(f64) = .empty;
    for (edges.items) |e| try ys.appendSlice(s, &.{ e.a.y, e.b.y });
    for (edges.items, 0..) |e, i| for (edges.items[i + 1 ..]) |f| {
        if (crossingY(e, f)) |y| try ys.append(s, y);
    };
    std.mem.sort(f64, ys.items, {}, std.sort.asc(f64));
    var levels: std.ArrayList(f64) = .empty;
    for (ys.items) |y| {
        if (levels.items.len == 0 or y - levels.items[levels.items.len - 1] > eps) try levels.append(s, y);
    }
    const lv = levels.items;
    // Every vertex onto its level. Levels closer than `eps` merged, so a
    // vertex may lie a hair off its level; left there, the edge ending at it
    // and the edge leaving it would give two x values a hair apart at the
    // level, and the boundary would not join up there. Snapped, edges that
    // share a vertex share it exactly.
    for (edges.items) |*e| {
        e.lo = nearest(lv, e.ymin());
        e.hi = nearest(lv, e.ymax());
        e.a.y = lv[nearest(lv, e.a.y)];
        e.b.y = lv[nearest(lv, e.b.y)];
    }

    // Per slab, the filled spans' sides at the slab's bottom and top.
    const Span = struct { x0b: f64, x1b: f64, x0t: f64, x1t: f64 };
    const slabs = try s.alloc([]const Span, lv.len -| 1);
    var pieces: std.ArrayList(Piece) = .empty;
    var triangles: std.ArrayList([3]Point) = .empty;
    const Cut = struct { x: f64, xb: f64, xt: f64, dir: i32 };
    var cuts: std.ArrayList(Cut) = .empty;
    for (slabs, 0..) |*slab, k| {
        const y0 = lv[k];
        const y1 = lv[k + 1];
        cuts.clearRetainingCapacity();
        for (edges.items) |e| {
            if (e.lo <= k and e.hi > k) {
                const xb = e.xAt(y0);
                const xt = e.xAt(y1);
                try cuts.append(s, .{ .x = (xb + xt) / 2, .xb = xb, .xt = xt, .dir = e.dir });
            }
        }
        std.mem.sort(Cut, cuts.items, {}, struct {
            fn less(_: void, p: Cut, q: Cut) bool {
                return p.x < q.x;
            }
        }.less);
        var spans: std.ArrayList(Span) = .empty;
        var w: i32 = 0;
        var open: ?Cut = null;
        for (cuts.items) |c| {
            const was = w;
            w += c.dir;
            if (was == 0 and w != 0) open = c;
            if (was != 0 and w == 0) {
                const l = open.?;
                // A span starting where the last ended (contours sharing an
                // edge) continues it, leaving no slit between them.
                if (spans.items.len > 0) {
                    const last = &spans.items[spans.items.len - 1];
                    if (@abs(last.x1b - l.xb) <= eps and @abs(last.x1t - l.xt) <= eps) {
                        last.x1b = c.xb;
                        last.x1t = c.xt;
                        continue;
                    }
                }
                try spans.append(s, .{ .x0b = l.xb, .x1b = c.xb, .x0t = l.xt, .x1t = c.xt });
            }
        }
        // Down each span's left side, up its right: filled side on the left.
        for (spans.items) |sp| {
            const b0: Point = .{ .x = sp.x0b, .y = y0 };
            const b1: Point = .{ .x = sp.x1b, .y = y0 };
            const t0: Point = .{ .x = sp.x0t, .y = y1 };
            const t1: Point = .{ .x = sp.x1t, .y = y1 };
            if (sp.x1b > sp.x0b) try triangles.append(a, .{ b0, b1, t1 });
            if (sp.x1t > sp.x0t) try triangles.append(a, .{ b0, t1, t0 });
            try pieces.append(s, .{ .from = .{ .x = sp.x0t, .y = y1 }, .to = .{ .x = sp.x0b, .y = y0 } });
            try pieces.append(s, .{ .from = .{ .x = sp.x1b, .y = y0 }, .to = .{ .x = sp.x1t, .y = y1 } });
        }
        slab.* = spans.items;
    }

    // At each level, where the filled intervals above and below differ.
    var xs: std.ArrayList(f64) = .empty;
    for (lv, 0..) |y, k| {
        const below: []const Span = if (k > 0) slabs[k - 1] else &.{};
        const above: []const Span = if (k < slabs.len) slabs[k] else &.{};
        xs.clearRetainingCapacity();
        for (below) |sp| try xs.appendSlice(s, &.{ sp.x0t, sp.x1t });
        for (above) |sp| try xs.appendSlice(s, &.{ sp.x0b, sp.x1b });
        if (xs.items.len == 0) continue;
        std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
        var i: usize = 0;
        while (i + 1 < xs.items.len) : (i += 1) {
            const x0 = xs.items[i];
            const x1 = xs.items[i + 1];
            if (x0 == x1) continue;
            const m = (x0 + x1) / 2;
            const in_below = covers(below, m, .top);
            const in_above = covers(above, m, .bottom);
            if (in_below and !in_above) {
                // The top of what is below: run right to left.
                try pieces.append(s, .{ .from = .{ .x = x1, .y = y }, .to = .{ .x = x0, .y = y } });
            } else if (in_above and !in_below) {
                try pieces.append(s, .{ .from = .{ .x = x0, .y = y }, .to = .{ .x = x1, .y = y } });
            }
        }
    }

    return .{ .loops = try chain(a, s, pieces.items, eps), .triangles = triangles.items };
}

fn covers(spans: anytype, x: f64, side: enum { top, bottom }) bool {
    for (spans) |sp| {
        const lo = if (side == .top) sp.x0t else sp.x0b;
        const hi = if (side == .top) sp.x1t else sp.x1b;
        if (x > lo and x < hi) return true;
    }
    return false;
}

/// The height where two edges cross strictly inside both, if they do.
fn crossingY(e: Edge, f: Edge) ?f64 {
    if (e.ymax() <= f.ymin() or f.ymax() <= e.ymin()) return null;
    if (@max(e.a.x, e.b.x) < @min(f.a.x, f.b.x) or @max(f.a.x, f.b.x) < @min(e.a.x, e.b.x)) return null;
    const r = Point{ .x = e.b.x - e.a.x, .y = e.b.y - e.a.y };
    const q = Point{ .x = f.b.x - f.a.x, .y = f.b.y - f.a.y };
    const denom = r.x * q.y - r.y * q.x;
    if (denom == 0) return null;
    const d = Point{ .x = f.a.x - e.a.x, .y = f.a.y - e.a.y };
    const t = (d.x * q.y - d.y * q.x) / denom;
    const u = (d.x * r.y - d.y * r.x) / denom;
    if (!(t > 0 and t < 1 and u > 0 and u < 1)) return null;
    return e.a.y + t * r.y;
}

/// The index of the level nearest `y`.
fn nearest(levels: []const f64, y: f64) usize {
    var lo: usize = 0;
    var hi: usize = levels.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (levels[mid] < y) lo = mid + 1 else hi = mid;
    }
    if (lo == levels.len) return levels.len - 1;
    if (lo > 0 and y - levels[lo - 1] < levels[lo] - y) return lo - 1;
    return lo;
}

const Key = [2]u64;

fn key(p: Point) Key {
    // Fold -0 into 0 so equal points hash alike.
    return .{ @bitCast(p.x + 0.0), @bitCast(p.y + 0.0) };
}

/// Pieces joined end to start into loops, with repeated and collinear
/// points dropped.
fn chain(a: Allocator, s: Allocator, pieces: []const Piece, eps: f64) Allocator.Error![]const []const Point {
    var starts: std.AutoHashMapUnmanaged(Key, std.ArrayList(u32)) = .empty;
    for (pieces, 0..) |p, i| {
        if (p.from.eql(p.to)) continue;
        const g = try starts.getOrPut(s, key(p.from));
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(s, @intCast(i));
    }
    const used = try s.alloc(bool, pieces.len);
    @memset(used, false);
    for (pieces, used) |p, *u| u.* = p.from.eql(p.to);

    var loops: std.ArrayList([]const Point) = .empty;
    var pts: std.ArrayList(Point) = .empty;
    for (pieces, 0..) |first, i| {
        if (used[i]) continue;
        used[i] = true;
        pts.clearRetainingCapacity();
        try pts.append(s, first.from);
        var at = first.to;
        while (!at.eql(first.from)) {
            try pts.append(s, at);
            // Where loops touch at a point, the sharpest left turn keeps
            // each one apart.
            const prev = pts.items[pts.items.len - 2];
            const in = Point{ .x = at.x - prev.x, .y = at.y - prev.y };
            const next = blk: {
                var best: ?u32 = null;
                var best_turn: f64 = -std.math.inf(f64);
                if (starts.getPtr(key(at))) |list| for (list.items) |j| {
                    if (used[j]) continue;
                    const out = Point{ .x = pieces[j].to.x - at.x, .y = pieces[j].to.y - at.y };
                    const turn = std.math.atan2(in.x * out.y - in.y * out.x, in.x * out.x + in.y * out.y);
                    if (turn > best_turn) {
                        best = j;
                        best_turn = turn;
                    }
                };
                if (best != null) break :blk best;
                // No piece starts exactly here: take the nearest unused one
                // within `eps`, so a hair's gap never cuts a loop short.
                var best_d: f64 = eps;
                for (pieces, 0..) |pc, j| {
                    if (used[j]) continue;
                    const d = @max(@abs(pc.from.x - at.x), @abs(pc.from.y - at.y));
                    if (d <= best_d) {
                        best = @intCast(j);
                        best_d = d;
                    }
                }
                break :blk best;
            } orelse break; // open: cannot happen for a closed region
            used[next] = true;
            at = pieces[next].to;
        }
        const loop = try simplify(a, s, pts.items, eps);
        if (loop.len >= 3) try loops.append(a, loop);
    }
    return loops.items;
}

/// Drops points within `eps` of the last kept, then points on a straight
/// run between their neighbours.
fn simplify(a: Allocator, s: Allocator, all: []const Point, eps: f64) Allocator.Error![]const Point {
    var spaced: std.ArrayList(Point) = .empty;
    for (all) |p| {
        if (spaced.items.len > 0) {
            const q = spaced.items[spaced.items.len - 1];
            if (@abs(p.x - q.x) <= eps and @abs(p.y - q.y) <= eps) continue;
        }
        try spaced.append(s, p);
    }
    while (spaced.items.len > 1) {
        const p = spaced.items[spaced.items.len - 1];
        const q = spaced.items[0];
        if (@abs(p.x - q.x) > eps or @abs(p.y - q.y) > eps) break;
        _ = spaced.pop();
    }
    const pts = spaced.items;
    var out: std.ArrayList(Point) = .empty;
    const n = pts.len;
    for (pts, 0..) |p, i| {
        const prev = pts[(i + n - 1) % n];
        const next = pts[(i + 1) % n];
        const u = Point{ .x = p.x - prev.x, .y = p.y - prev.y };
        const v = Point{ .x = next.x - p.x, .y = next.y - p.y };
        const cross = u.x * v.y - u.y * v.x;
        const dot = u.x * v.x + u.y * v.y;
        const scale = @sqrt(u.x * u.x + u.y * u.y) * @sqrt(v.x * v.x + v.y * v.y);
        if (@abs(cross) <= 1e-12 * scale and dot >= 0) continue;
        try out.append(a, p);
    }
    return out.items;
}

fn area(loop: []const Point) f64 {
    var sum: f64 = 0;
    for (loop, 0..) |p, i| {
        const q = loop[(i + 1) % loop.len];
        sum += p.x * q.y - q.x * p.y;
    }
    return sum / 2;
}

const testing = std.testing;

fn totalArea(loops: []const []const Point) f64 {
    var sum: f64 = 0;
    for (loops) |l| sum += area(l);
    return sum;
}

fn rect(x0: f64, y0: f64, x1: f64, y1: f64) [4]Point {
    return .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
}

test "overlapping squares become one outline" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r1 = rect(0, 0, 2, 2);
    const r2 = rect(1, 1, 3, 3);
    const region = try nonzero(arena.allocator(), &.{ &r1, &r2 }, 1e-9);
    const loops = region.loops;
    try testing.expectEqual(1, loops.len);
    try testing.expectEqual(8, loops[0].len);
    try testing.expectApproxEqAbs(@as(f64, 7), area(loops[0]), 1e-12);
    // The triangles cover the same area, once.
    var sum: f64 = 0;
    for (region.triangles) |t| sum += area(&t);
    try testing.expectApproxEqAbs(@as(f64, 7), sum, 1e-12);
}

test "a hole wound the other way stays a hole; one wound alike is filled" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const outer = rect(0, 0, 4, 4);
    const r = rect(1, 1, 3, 3);
    const hole = [_]Point{ r[3], r[2], r[1], r[0] };
    const holed = (try nonzero(arena.allocator(), &.{ &outer, &hole }, 1e-9)).loops;
    try testing.expectEqual(2, holed.len);
    try testing.expectApproxEqAbs(@as(f64, 12), totalArea(holed), 1e-12);
    const filled = (try nonzero(arena.allocator(), &.{ &outer, &r }, 1e-9)).loops;
    try testing.expectEqual(1, filled.len);
    try testing.expectApproxEqAbs(@as(f64, 16), totalArea(filled), 1e-12);
}

test "a self-crossing contour resolves into simple loops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // A bow tie: two triangles meeting at (1, 1), the second wound backwards.
    const bow = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 2 } };
    const region = try nonzero(arena.allocator(), &.{&bow}, 1e-9);
    const loops = region.loops;
    try testing.expectEqual(2, loops.len);
    // Both lobes filled, each counter-clockwise.
    for (loops) |l| try testing.expectApproxEqAbs(@as(f64, 1), area(l), 1e-12);
}

test "an A: legs crossing at the apex and a crossbar laid over them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Adwaita Sans's A in outline: the inner edges cross below the apex.
    const legs = [_]Point{
        .{ .x = 0.7, .y = 0 },  .{ .x = 8, .y = 20 },     .{ .x = 10.9, .y = 20 },  .{ .x = 18.3, .y = 0 },
        .{ .x = 15.6, .y = 0 }, .{ .x = 9.2, .y = 18.8 }, .{ .x = 9.7, .y = 18.8 }, .{ .x = 3.4, .y = 0 },
    };
    const reversed = [_]Point{ legs[7], legs[6], legs[5], legs[4], legs[3], legs[2], legs[1], legs[0] };
    const bar = rect(4.3, 5.6, 14.6, 7.8);
    const region = try nonzero(arena.allocator(), &.{ &reversed, &bar }, 1e-9);
    const loops = region.loops;
    // One outline, its counter a hole closing at the crossing; no area
    // counted twice where the bar lies over the legs.
    var outer: usize = 0;
    var holes: usize = 0;
    for (loops) |l| {
        if (area(l) > 0) outer += 1 else holes += 1;
    }
    try testing.expectEqual(1, outer);
    try testing.expectEqual(1, holes);
    const legs_area = area(&reversed);
    try testing.expect(totalArea(loops) < legs_area + 10.3 * 2.2);
}

test "contours sharing an edge leave no slit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r1 = rect(0, 0, 1, 2);
    const r2 = rect(1, 0, 2, 2);
    const region = try nonzero(arena.allocator(), &.{ &r1, &r2 }, 1e-9);
    const loops = region.loops;
    try testing.expectEqual(1, loops.len);
    try testing.expectEqual(4, loops[0].len);
    try testing.expectApproxEqAbs(@as(f64, 4), area(loops[0]), 1e-12);
}
