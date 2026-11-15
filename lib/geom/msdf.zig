//! Multi-channel signed distance fields (MSDF): a glyph's shape kept as a
//! small grid of distances, from which it is drawn at any size, rotated,
//! and grown, with its corners kept sharp.
//!
//! A plain signed distance field stores, per texel, the distance to the
//! outline (positive inside). Sampled between texels and cut at zero it
//! reproduces the outline, but rounds its corners. An MSDF stores three
//! distances, one per channel, each measured only to the edges of that
//! channel's colour; edges meeting at a corner differ in colour, and the
//! median of the three channels then keeps the corner (Chlumský, 2015,
//! after msdfgen).
//!
//! Growing comes for free: cutting the median at -d instead of 0 draws the
//! outline grown by d with round corners, the region `grow.grow` computes
//! exactly, which is what weight matching draws.
//!
//! The method here:
//! - the outline is flattened finely and its overlaps resolved (`fill.nonzero`)
//!   into simple loops, filled on their left; overlapping contours from
//!   variable fonts then cannot confuse the distances;
//! - corners are where a loop turns sharply; the runs between them are
//!   coloured cyan, magenta and yellow in turn (adjacent runs share one
//!   channel), a loop without corners white, one with a single corner
//!   magenta, white and yellow by thirds;
//! - each texel takes, per channel, the nearest edge of that channel, and
//!   its signed pseudo-distance: past an edge's end, the distance to the
//!   line it was heading along;
//! - a texel whose median disagrees with the true inside (by winding) has
//!   its channels negated.
//! Distances are kept as f32 in texels, clamped to the field's range.

const std = @import("std");
const root = @import("root.zig");
const fill = @import("fill.zig");

const Allocator = std.mem.Allocator;
const Point = root.Point;
const Outline = root.Outline;
const Box = root.Box;

/// Channel bits: red, green, blue.
const R: u3 = 1;
const G: u3 = 2;
const B: u3 = 4;
const cyan = G | B;
const magenta = R | B;
const yellow = R | G;
const white = R | G | B;

pub const Field = struct {
    w: u32,
    h: u32,
    /// Three distances per texel, row by row from the bottom, in texels,
    /// positive inside, within ±range.
    data: []f32,
    /// Outline units to texels: texel space = (p - origin) * scale, texel
    /// (i, j)'s centre at (i + 0.5, j + 0.5).
    scale: f64,
    origin: Point,
    range: f64,

    pub fn deinit(f: Field, a: Allocator) void {
        a.free(f.data);
    }

    /// The three channels at texel-space point `q`, bilinearly, edges
    /// clamped.
    pub fn sample(f: Field, q: Point) [3]f32 {
        const x = q.x - 0.5;
        const y = q.y - 0.5;
        const x0f = @floor(x);
        const y0f = @floor(y);
        const tx: f32 = @floatCast(x - x0f);
        const ty: f32 = @floatCast(y - y0f);
        const ia = clampIndex(x0f, f.w);
        const ib = clampIndex(x0f + 1, f.w);
        const j0 = clampIndex(y0f, f.h);
        const j1 = clampIndex(y0f + 1, f.h);
        var out: [3]f32 = undefined;
        for (0..3) |c| {
            const a00 = f.data[(j0 * f.w + ia) * 3 + c];
            const a10 = f.data[(j0 * f.w + ib) * 3 + c];
            const a01 = f.data[(j1 * f.w + ia) * 3 + c];
            const a11 = f.data[(j1 * f.w + ib) * 3 + c];
            const lo = a00 + (a10 - a00) * tx;
            const hi = a01 + (a11 - a01) * tx;
            out[c] = lo + (hi - lo) * ty;
        }
        return out;
    }

    /// The signed distance at outline-space point `p`, in outline units:
    /// the median of the channels.
    pub fn distance(f: Field, p: Point) f64 {
        const s = f.sample(.{ .x = (p.x - f.origin.x) * f.scale, .y = (p.y - f.origin.y) * f.scale });
        return median(s) / f.scale;
    }

    /// Coverage (0..255) of a `w` × `h` raster whose pixel (i, j) centre
    /// (rows from the bottom) maps to outline space by `to_outline`, the
    /// outline grown by `grow` outline units. `px` is outline units per
    /// pixel, for the antialiasing ramp (one pixel wide). Allocated from `a`.
    pub fn rasterize(f: Field, a: Allocator, w: u32, h: u32, to_outline: root.Affine, px: f64, grow: f64) Allocator.Error![]u8 {
        const out = try a.alloc(u8, @as(usize, w) * h);
        for (0..h) |j| for (0..w) |i| {
            const p = to_outline.apply(.{ .x = @as(f64, @floatFromInt(i)) + 0.5, .y = @as(f64, @floatFromInt(j)) + 0.5 });
            const d = (f.distance(p) + grow) / px;
            const c = std.math.clamp(d + 0.5, 0, 1);
            out[j * w + i] = @intFromFloat(@round(c * 255));
        };
        return out;
    }
};

fn clampIndex(v: f64, n: u32) usize {
    if (v < 0) return 0;
    const k: usize = @intFromFloat(v);
    return @min(k, n - 1);
}

pub fn median(c: [3]f32) f32 {
    return @max(@min(c[0], c[1]), @min(@max(c[0], c[1]), c[2]));
}

pub const Options = struct {
    /// Texels per outline unit.
    scale: f64,
    /// The distance range kept, texels: distances clamp to ±range, and the
    /// field is padded by it. Growing by more than this cannot be drawn.
    range: f64 = 4,
    /// A turn sharper than this makes a corner, radians.
    corner_angle: f64 = 0.2,
    /// Colour every edge white: a plain signed distance field (corners
    /// rounded), for comparison.
    single_channel: bool = false,
};

/// An edge: a run of a loop's pieces in one colour.
const Edge = struct {
    pts: []const Point,
    color: u3,
    /// Bounds of the whole edge, and of each chunk of `chunk` pieces, for
    /// skipping what cannot be nearer.
    box: Box = Box.empty,
    chunks: []const Box = &.{},
};

const chunk = 16;

fn withBounds(a: Allocator, e: Edge) Allocator.Error!Edge {
    var out = e;
    const pieces = e.pts.len - 1;
    const n = (pieces + chunk - 1) / chunk;
    const boxes = try a.alloc(Box, n);
    var all = Box.empty;
    for (boxes, 0..) |*bx, k| {
        var b = Box.empty;
        const from = k * chunk;
        const to = @min(from + chunk, pieces);
        for (e.pts[from .. to + 1]) |q| b = b.addPoint(q);
        bx.* = b;
        all = all.join(b);
    }
    out.box = all;
    out.chunks = boxes;
    return out;
}

/// The distance from `p` to box `b` (0 inside it).
fn boxDistance(b: Box, p: Point) f64 {
    const dx = @max(b.x0 - p.x, 0, p.x - b.x1);
    const dy = @max(b.y0 - p.y, 0, p.y - b.y1);
    return @sqrt(dx * dx + dy * dy);
}

/// The MSDF of `o`, its distances in texels. An empty outline gives a 1 × 1
/// field far outside.
pub fn generate(a: Allocator, o: Outline, opts: Options) Allocator.Error!Field {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const s = arena.allocator();

    const b = o.bounds();
    if (b.isEmpty()) {
        const data = try a.alloc(f32, 3);
        @memset(data, @floatCast(-opts.range));
        return .{ .w = 1, .h = 1, .data = data, .scale = opts.scale, .origin = .{ .x = 0, .y = 0 }, .range = opts.range };
    }
    // Flattened to a small fraction of a texel, overlaps resolved.
    const tol = 0.02 / opts.scale;
    var polys: std.ArrayList([]const Point) = .empty;
    for (o.contours) |c| {
        var pts: std.ArrayList(Point) = .empty;
        if (c.segments.len > 0) try pts.append(s, c.segments[0].start());
        for (c.segments) |seg| try flatten(s, &pts, seg, tol);
        if (pts.items.len > 1 and pts.items[0].eql(pts.items[pts.items.len - 1])) _ = pts.pop();
        if (pts.items.len >= 3) try polys.append(s, pts.items);
    }
    const region = try fill.nonzero(s, polys.items, tol * 0.1);

    // Edges by colour.
    var edges: std.ArrayList(Edge) = .empty;
    for (region.loops) |loop| try colorLoop(s, &edges, loop, opts);
    for (edges.items) |*e| e.* = try withBounds(s, e.*);
    // Beyond the range every distance clamps: nothing further need be
    // measured.
    const limit = (opts.range + 1) / opts.scale;

    const pad = opts.range + 1;
    const origin: Point = .{ .x = b.x0 - pad / opts.scale, .y = b.y0 - pad / opts.scale };
    const w: u32 = @intFromFloat(@ceil((b.x1 - b.x0) * opts.scale + 2 * pad));
    const h: u32 = @intFromFloat(@ceil((b.y1 - b.y0) * opts.scale + 2 * pad));
    const data = try a.alloc(f32, @as(usize, w) * h * 3);
    errdefer a.free(data);

    var xs: std.ArrayList(f64) = .empty;
    for (0..h) |j| {
        const y = origin.y + (@as(f64, @floatFromInt(j)) + 0.5) / opts.scale;
        // Where this row crosses the loops: inside between pairs.
        xs.clearRetainingCapacity();
        for (region.loops) |l| {
            var k = l.len - 1;
            for (0..l.len) |m| {
                const p0 = l[m];
                const p1 = l[k];
                if ((p0.y > y) != (p1.y > y)) try xs.append(s, p0.x + (y - p0.y) * (p1.x - p0.x) / (p1.y - p0.y));
                k = m;
            }
        }
        std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
        var cross_at: usize = 0;
        for (0..w) |i| {
            const p: Point = .{ .x = origin.x + (@as(f64, @floatFromInt(i)) + 0.5) / opts.scale, .y = y };
            while (cross_at < xs.items.len and xs.items[cross_at] <= p.x) cross_at += 1;
            const in = cross_at % 2 == 1;
            var ch: [3]f32 = undefined;
            for (0..3) |c| {
                const bit = @as(u3, 1) << @intCast(c);
                const d = channelDistance(edges.items, bit, p, limit);
                ch[c] = @floatCast(std.math.clamp(d * opts.scale, -opts.range, opts.range));
            }
            // The median must agree with the true inside.
            if ((median(ch) > 0) != in) {
                for (&ch) |*v| v.* = -v.*;
            }
            @memcpy(data[(j * w + i) * 3 ..][0..3], &ch);
        }
    }
    return .{ .w = w, .h = h, .data = data, .scale = opts.scale, .origin = origin, .range = opts.range };
}

/// Splits `loop` (filled on its left) at its corners and colours the runs.
fn colorLoop(a: Allocator, edges: *std.ArrayList(Edge), loop: []const Point, opts: Options) Allocator.Error!void {
    const n = loop.len;
    if (n < 3) return;
    const min_cross = @sin(opts.corner_angle);
    var corners: std.ArrayList(usize) = .empty;
    if (!opts.single_channel) for (0..n) |i| {
        const din = unit(sub(loop[i], loop[(i + n - 1) % n]));
        const dout = unit(sub(loop[(i + 1) % n], loop[i]));
        const dot = din.x * dout.x + din.y * dout.y;
        if (dot <= 0 or @abs(din.cross(dout)) > min_cross) try corners.append(a, i);
    };

    // A run of the loop from vertex `from` to vertex `to` (inclusive,
    // wrapping).
    const Run = struct {
        fn take(al: Allocator, l: []const Point, from: usize, to: usize) Allocator.Error![]const Point {
            const len = (to + l.len - from) % l.len + 1;
            const out = try al.alloc(Point, len);
            for (out, 0..) |*q, k| q.* = l[(from + k) % l.len];
            return out;
        }
    };

    switch (corners.items.len) {
        0 => {
            // Smooth all round: one closed white edge.
            const pts = try a.alloc(Point, n + 1);
            @memcpy(pts[0..n], loop);
            pts[n] = loop[0];
            try edges.append(a, .{ .pts = pts, .color = white });
        },
        1 => {
            // A teardrop: thirds magenta, white, yellow from the corner.
            const c = corners.items[0];
            const k1 = n / 3;
            const k2 = 2 * n / 3;
            const cuts = [_]usize{ c, (c + @max(k1, 1)) % n, (c + @max(k2, 2)) % n, c };
            const colors = [_]u3{ magenta, white, yellow };
            for (colors, 0..) |col, k| try edges.append(a, .{ .pts = try Run.take(a, loop, cuts[k], cuts[k + 1]), .color = col });
        },
        else => {
            // Runs between corners: cyan, magenta, yellow in turn; the last
            // differs from both its neighbours.
            const cs = corners.items;
            const cycle = [_]u3{ cyan, magenta, yellow };
            var prev: u3 = 0;
            for (cs, 0..) |c, k| {
                const next = cs[(k + 1) % cs.len];
                var col = cycle[k % 3];
                if (k == cs.len - 1) {
                    for (cycle) |cand| if (cand != prev and cand != cycle[0]) {
                        col = cand;
                        break;
                    };
                }
                try edges.append(a, .{ .pts = try Run.take(a, loop, c, next), .color = col });
                prev = col;
            }
        },
    }
}

/// The signed pseudo-distance from `p` to the nearest edge with channel
/// `bit`, outline units, positive inside.
fn channelDistance(edges: []const Edge, bit: u3, p: Point, limit: f64) f64 {
    var best: ?Near = null;
    var best_edge: ?*const Edge = null;
    var bound = limit;
    for (edges) |*e| {
        if (e.color & bit == 0) continue;
        if (boxDistance(e.box, p) > bound) continue;
        const near = nearest(e, p, bound) orelse continue;
        if (best == null or closer(near, best.?)) {
            best = near;
            best_edge = e;
            bound = @min(bound, near.dist * (1 + 1e-9) + 1e-12);
        }
    }
    // Nothing within the range: far outside, until the sign is checked.
    const nb = best orelse return -limit;
    const e = best_edge.?;
    var d = nb.signed;
    // Past an end of an open run, the distance to the line it was heading
    // along, when nearer.
    const closed = e.pts[0].eql(e.pts[e.pts.len - 1]);
    if (!closed) {
        if (nb.at_start) {
            const dir = unit(sub(e.pts[1], e.pts[0]));
            const q = sub(p, e.pts[0]);
            if (q.x * dir.x + q.y * dir.y < 0) {
                const pd = dir.cross(q);
                if (@abs(pd) <= @abs(d)) d = pd;
            }
        } else if (nb.at_end) {
            const m = e.pts.len;
            const dir = unit(sub(e.pts[m - 1], e.pts[m - 2]));
            const q = sub(p, e.pts[m - 1]);
            if (q.x * dir.x + q.y * dir.y > 0) {
                const pd = dir.cross(q);
                if (@abs(pd) <= @abs(d)) d = pd;
            }
        }
    }
    return d;
}

const Near = struct {
    dist: f64,
    signed: f64,
    /// How square the approach is to the piece (|cross| of its direction
    /// with the unit vector to p): breaks ties at shared vertices.
    ortho: f64,
    at_start: bool,
    at_end: bool,
};

fn closer(a: Near, b: Near) bool {
    const eps = 1e-9 * @max(1, b.dist);
    if (a.dist < b.dist - eps) return true;
    if (a.dist > b.dist + eps) return false;
    return a.ortho > b.ortho;
}

/// The nearest point of edge `e` to `p`, if any is within `bound`.
fn nearest(e: *const Edge, p: Point, bound: f64) ?Near {
    const pts = e.pts;
    var best: Near = .{ .dist = std.math.inf(f64), .signed = 0, .ortho = 0, .at_start = false, .at_end = false };
    var lim = bound;
    for (e.chunks, 0..) |bx, ci| {
        if (boxDistance(bx, p) > lim) continue;
        const from = ci * chunk;
        const to = @min(from + chunk, pts.len - 1);
        for (from..to) |k| {
            const a0 = pts[k];
            const ab = sub(pts[k + 1], a0);
            const len2 = ab.x * ab.x + ab.y * ab.y;
            if (len2 == 0) continue;
            const ap = sub(p, a0);
            const t = std.math.clamp((ap.x * ab.x + ap.y * ab.y) / len2, 0, 1);
            const q: Point = .{ .x = a0.x + ab.x * t, .y = a0.y + ab.y * t };
            const qp = sub(p, q);
            const dist = @sqrt(qp.x * qp.x + qp.y * qp.y);
            const dir = unit(ab);
            const cr = dir.cross(qp);
            const near: Near = .{
                .dist = dist,
                .signed = if (cr >= 0) dist else -dist,
                .ortho = if (dist > 0) @abs(cr) / dist else 1,
                .at_start = k == 0 and t == 0,
                .at_end = k == pts.len - 2 and t == 1,
            };
            if (closer(near, best)) {
                best = near;
                lim = @min(lim, dist * (1 + 1e-9) + 1e-12);
            }
        }
    }
    return if (best.dist <= bound) best else null;
}

/// Whether `p` is inside simple loops `loops` (even-odd, which for simple
/// non-crossing loops is the region).
fn inside(loops: []const []const Point, p: Point) bool {
    var in = false;
    for (loops) |l| {
        var j = l.len - 1;
        for (0..l.len) |i| {
            const a = l[i];
            const b = l[j];
            if ((a.y > p.y) != (b.y > p.y)) {
                const x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y);
                if (p.x < x) in = !in;
            }
            j = i;
        }
    }
    return in;
}

fn flatten(a: Allocator, pts: *std.ArrayList(Point), s: root.Segment, tol: f64) Allocator.Error!void {
    if (s == .line) return pts.append(a, s.end());
    const ps = s.points();
    var dev: f64 = 0;
    for (ps[1 .. ps.len - 1]) |q| dev = @max(dev, distToLine(q, ps[0], ps[ps.len - 1]));
    const n: usize = @max(2, @min(512, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol) * 1.5)))));
    for (1..n + 1) |i| try pts.append(a, s.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
}

fn distToLine(q: Point, a: Point, b: Point) f64 {
    const ab = sub(b, a);
    const l = @sqrt(ab.x * ab.x + ab.y * ab.y);
    if (l == 0) return @sqrt((q.x - a.x) * (q.x - a.x) + (q.y - a.y) * (q.y - a.y));
    return @abs(ab.cross(sub(q, a))) / l;
}

fn sub(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn unit(a: Point) Point {
    const l = @sqrt(a.x * a.x + a.y * a.y);
    return if (l == 0) a else .{ .x = a.x / l, .y = a.y / l };
}

const testing = std.testing;

fn squareOutline(buf: *[4]root.Segment, x0: f64, y0: f64, x1: f64, y1: f64, ccw: bool) Outline {
    const p = [4]Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
    for (0..4) |i| {
        const j = if (ccw) i else 3 - i;
        const k = if (ccw) (i + 1) % 4 else (6 - i) % 4;
        buf[i] = .{ .line = .{ p[j], p[k] } };
    }
    return .{ .contours = &.{} };
}

/// The coverage area of a raster, in outline units squared.
fn coveredArea(cov: []const u8, px: f64) f64 {
    var s: f64 = 0;
    for (cov) |c| s += @as(f64, @floatFromInt(c)) / 255;
    return s * px * px;
}

test "a square: distances inside and out, its area drawn at any size, its corners sharp" {
    const a = testing.allocator;
    var segs: [4]root.Segment = undefined;
    _ = squareOutline(&segs, 0, 0, 10, 10, false); // clockwise, as TrueType
    const o: Outline = .{ .contours = &.{.{ .segments = &segs }} };
    const f = try generate(a, o, .{ .scale = 2 });
    defer f.deinit(a);
    // Signed distances: 5 at the centre (clamped to the range, 4 texels =
    // 2 units), 1 unit inside an edge, 1 outside.
    try testing.expectApproxEqAbs(@as(f64, 2), f.distance(.{ .x = 5, .y = 5 }), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1), f.distance(.{ .x = 1, .y = 5 }), 0.05);
    try testing.expectApproxEqAbs(@as(f64, -1), f.distance(.{ .x = -1, .y = 5 }), 0.05);

    // Drawn 8 times finer than the field: area within 1 %.
    const px = 1.0 / 16.0;
    const m: root.Affine = .{ .a = px, .d = px, .e = -1, .f = -1 };
    const cov = try f.rasterize(a, 12 * 16, 12 * 16, m, px, 0);
    defer a.free(cov);
    try testing.expectApproxEqRel(@as(f64, 100), coveredArea(cov, px), 0.01);

    // Grown by 1: the square, its sides moved out, its corners round.
    const g = try f.rasterize(a, 12 * 16, 12 * 16, m, px, 1);
    defer a.free(g);
    try testing.expectApproxEqRel(@as(f64, 100 + 40 + std.math.pi), coveredArea(g, px), 0.01);

    // The corner is sharp: a point a fifth of a texel in from both sides
    // is inside, one as far out diagonally is outside.
    try testing.expect(f.distance(.{ .x = 0.1, .y = 0.1 }) > 0);
    try testing.expect(f.distance(.{ .x = -0.1, .y = -0.1 }) < 0);
    // A plain distance field rounds it: the same point inside reads out.
    const plain = try generate(a, o, .{ .scale = 2, .single_channel = true });
    defer plain.deinit(a);
    try testing.expect(plain.distance(.{ .x = 0.1, .y = 0.1 }) < f.distance(.{ .x = 0.1, .y = 0.1 }));
}

test "a counter stays a counter, whichever way the contours wind" {
    const a = testing.allocator;
    var outer: [4]root.Segment = undefined;
    var hole: [4]root.Segment = undefined;
    _ = squareOutline(&outer, 0, 0, 10, 10, true);
    _ = squareOutline(&hole, 3, 3, 7, 7, false);
    const o: Outline = .{ .contours = &.{ .{ .segments = &outer }, .{ .segments = &hole } } };
    const f = try generate(a, o, .{ .scale = 2 });
    defer f.deinit(a);
    try testing.expect(f.distance(.{ .x = 5, .y = 5 }) < 0); // in the counter
    try testing.expect(f.distance(.{ .x = 1.5, .y = 5 }) > 0); // in the stroke
    const px = 1.0 / 16.0;
    const cov = try f.rasterize(a, 12 * 16, 12 * 16, .{ .a = px, .d = px, .e = -1, .f = -1 }, px, 0);
    defer a.free(cov);
    try testing.expectApproxEqRel(@as(f64, 84), coveredArea(cov, px), 0.01);
}

test "overlapping contours (a variable font's) fill as one" {
    const a = testing.allocator;
    var s1: [4]root.Segment = undefined;
    var s2: [4]root.Segment = undefined;
    _ = squareOutline(&s1, 0, 0, 6, 6, true);
    _ = squareOutline(&s2, 4, 0, 10, 6, true);
    const o: Outline = .{ .contours = &.{ .{ .segments = &s1 }, .{ .segments = &s2 } } };
    const f = try generate(a, o, .{ .scale = 2 });
    defer f.deinit(a);
    try testing.expect(f.distance(.{ .x = 5, .y = 3 }) > 0); // the overlap
    const px = 1.0 / 16.0;
    const cov = try f.rasterize(a, 12 * 16, 8 * 16, .{ .a = px, .d = px, .e = -1, .f = -1 }, px, 0);
    defer a.free(cov);
    try testing.expectApproxEqRel(@as(f64, 60), coveredArea(cov, px), 0.01);
}

test "curves: a circle's area, and the area of its growth" {
    const a = testing.allocator;
    var buf: [4]root.Segment = undefined;
    const circle = root.arc(.{ .x = 0, .y = 0 }, 5, 0, 2 * std.math.pi, &buf);
    const o: Outline = .{ .contours = &.{.{ .segments = circle }} };
    const f = try generate(a, o, .{ .scale = 3 });
    defer f.deinit(a);
    const px = 1.0 / 24.0;
    const m: root.Affine = .{ .a = px, .d = px, .e = -7, .f = -7 };
    const cov = try f.rasterize(a, 14 * 24, 14 * 24, m, px, 0);
    defer a.free(cov);
    try testing.expectApproxEqRel(std.math.pi * 25, coveredArea(cov, px), 0.01);
    const g = try f.rasterize(a, 14 * 24, 14 * 24, m, px, 1);
    defer a.free(g);
    try testing.expectApproxEqRel(std.math.pi * 36, coveredArea(g, px), 0.01);
}
