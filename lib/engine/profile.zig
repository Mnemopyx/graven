//! Contact profiles: an element's ink extent, left and right, in horizontal
//! bands on a grid shared by the whole label.
//!
//! Profiles decide placement only. Curves are flattened to build them, within
//! a tolerance well under the band height; the geometry itself stays exact,
//! and DRC still measures the real outlines.

const std = @import("std");
const geom = @import("graven_geom");

const Allocator = std.mem.Allocator;
const Point = geom.Point;

pub const Profile = struct {
    /// Band index of left[0]: band i covers heights [i*band, (i+1)*band).
    first: i64 = 0,
    /// Leftmost and rightmost ink in each band; +inf and -inf where a band
    /// has none.
    left: []f64 = &.{},
    right: []f64 = &.{},

    pub const empty: Profile = .{};

    pub fn isEmpty(p: Profile) bool {
        return p.left.len == 0;
    }

    /// The profile of `outline` (already placed, mm) on bands `band` high.
    pub fn fromOutline(a: Allocator, outline: geom.Outline, band: f64) !Profile {
        const b = outline.bounds();
        if (b.isEmpty()) return .empty;
        const first: i64 = @intFromFloat(@floor(b.y0 / band));
        const last: i64 = @intFromFloat(@floor(b.y1 / band));
        const n: usize = @intCast(last - first + 1);
        var p: Profile = .{ .first = first, .left = try a.alloc(f64, n), .right = try a.alloc(f64, n) };
        @memset(p.left, std.math.inf(f64));
        @memset(p.right, -std.math.inf(f64));
        const tol = band / 4;
        for (outline.contours) |c| {
            for (c.segments) |s| switch (s) {
                .line => |q| p.addLine(q[0], q[1], band),
                .quad => |q| {
                    const steps = pieces(&q, tol);
                    var prev = q[0];
                    for (1..steps + 1) |k| {
                        const pt = quadAt(q, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps)));
                        p.addLine(prev, pt, band);
                        prev = pt;
                    }
                },
                .cubic => |q| {
                    const steps = pieces(&q, tol);
                    var prev = q[0];
                    for (1..steps + 1) |k| {
                        const pt = cubicAt(q, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps)));
                        p.addLine(prev, pt, band);
                        prev = pt;
                    }
                },
                .conic => |q| {
                    const steps = pieces(&q.p, tol) * 2;
                    var prev = q.p[0];
                    for (1..steps + 1) |k| {
                        const pt = q.at(@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps)));
                        p.addLine(prev, pt, band);
                        prev = pt;
                    }
                },
            };
        }
        return p;
    }

    /// Widens the bands a line segment passes through to include it.
    fn addLine(p: *Profile, p0: Point, p1: Point, band: f64) void {
        const lo = @min(p0.y, p1.y);
        const hi = @max(p0.y, p1.y);
        var i: i64 = @intFromFloat(@floor(lo / band));
        const top: i64 = @intFromFloat(@floor(hi / band));
        while (i <= top) : (i += 1) {
            const k = i - p.first;
            if (k < 0 or k >= p.left.len) continue;
            const ya = @as(f64, @floatFromInt(i)) * band;
            const yb = ya + band;
            if (p0.y == p1.y) {
                p.widen(@intCast(k), @min(p0.x, p1.x), @max(p0.x, p1.x));
                continue;
            }
            // The part of the segment inside the band, by its x at each end.
            const ta = std.math.clamp((ya - p0.y) / (p1.y - p0.y), 0, 1);
            const tb = std.math.clamp((yb - p0.y) / (p1.y - p0.y), 0, 1);
            const xa = p0.x + (p1.x - p0.x) * ta;
            const xb = p0.x + (p1.x - p0.x) * tb;
            p.widen(@intCast(k), @min(xa, xb), @max(xa, xb));
        }
    }

    fn widen(p: *Profile, k: usize, x0: f64, x1: f64) void {
        p.left[k] = @min(p.left[k], x0);
        p.right[k] = @max(p.right[k], x1);
    }

    /// The union of two profiles, newly allocated.
    pub fn join(a: Allocator, p: Profile, q: Profile) !Profile {
        if (p.isEmpty()) return q;
        if (q.isEmpty()) return p;
        const first = @min(p.first, q.first);
        const last = @max(p.first + @as(i64, @intCast(p.left.len)), q.first + @as(i64, @intCast(q.left.len))) - 1;
        const n: usize = @intCast(last - first + 1);
        var out: Profile = .{ .first = first, .left = try a.alloc(f64, n), .right = try a.alloc(f64, n) };
        @memset(out.left, std.math.inf(f64));
        @memset(out.right, -std.math.inf(f64));
        for ([_]Profile{ p, q }) |src| {
            const off: usize = @intCast(src.first - first);
            for (src.left, src.right, 0..) |l, r, k| {
                out.left[off + k] = @min(out.left[off + k], l);
                out.right[off + k] = @max(out.right[off + k], r);
            }
        }
        return out;
    }

    /// A copy widened `n` bands up and down: each band takes the furthest
    /// ink within `n` bands of it. Measured against this, a neighbour cannot
    /// reach into a concavity narrower than about 2n bands (the middle of a
    /// Sigma), yet still tucks under ink further away than that (a raised
    /// superscript).
    pub fn reached(a: Allocator, p: Profile, n: usize) !Profile {
        if (p.isEmpty() or n == 0) return p;
        const len = p.left.len + 2 * n;
        var out: Profile = .{ .first = p.first - @as(i64, @intCast(n)), .left = try a.alloc(f64, len), .right = try a.alloc(f64, len) };
        @memset(out.left, std.math.inf(f64));
        @memset(out.right, -std.math.inf(f64));
        for (p.left, p.right, 0..) |l, r, k| {
            for (out.left[k .. k + 2 * n + 1], out.right[k .. k + 2 * n + 1]) |*ol, *or_| {
                ol.* = @min(ol.*, l);
                or_.* = @max(or_.*, r);
            }
        }
        return out;
    }

    pub fn shift(p: *Profile, dx: f64) void {
        for (p.left) |*l| l.* += dx;
        for (p.right) |*r| r.* += dx;
    }

    /// The smallest horizontal clearance from `prev`'s right edge to `next`'s
    /// left edge over the bands where both have ink, or null if they share no
    /// band (one sits wholly above or below the other).
    pub fn clearance(prev: Profile, next: Profile) ?f64 {
        var best: ?f64 = null;
        const lo = @max(prev.first, next.first);
        const hi = @min(prev.first + @as(i64, @intCast(prev.left.len)), next.first + @as(i64, @intCast(next.left.len)));
        var i = lo;
        while (i < hi) : (i += 1) {
            const r = prev.right[@intCast(i - prev.first)];
            const l = next.left[@intCast(i - next.first)];
            if (r == -std.math.inf(f64) or l == std.math.inf(f64)) continue;
            const g = l - r;
            best = if (best) |b| @min(b, g) else g;
        }
        return best;
    }
};

/// Enough straight pieces that each stays within `tol` of the curve: the
/// control polygon's length over the tolerance, from 2 to 256.
fn pieces(q: []const Point, tol: f64) usize {
    var len: f64 = 0;
    for (q[1..], 0..) |pt, k| len += @sqrt((pt.x - q[k].x) * (pt.x - q[k].x) + (pt.y - q[k].y) * (pt.y - q[k].y));
    const n = @ceil(@sqrt(len / tol) * 2);
    return @intFromFloat(std.math.clamp(n, 2, 256));
}

fn quadAt(p: [3]Point, t: f64) Point {
    const u = 1 - t;
    return .{
        .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x,
        .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y,
    };
}

fn cubicAt(p: [4]Point, t: f64) Point {
    const u = 1 - t;
    return .{
        .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
        .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
    };
}

const testing = std.testing;

fn rect(a: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) !geom.Outline {
    const p = [4]Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
    const segs = try a.alloc(geom.Segment, 4);
    for (segs, 0..) |*s, k| s.* = .{ .line = .{ p[k], p[(k + 1) % 4] } };
    const cs = try a.alloc(geom.Contour, 1);
    cs[0] = .{ .segments = segs };
    return .{ .contours = cs };
}

test "a rectangle's profile is exact; clearance only counts shared bands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tall = try Profile.fromOutline(a, try rect(a, 0, 0, 5, 7), 0.5);
    const high = try Profile.fromOutline(a, try rect(a, 8, 4, 9, 9), 0.5);
    const low = try Profile.fromOutline(a, try rect(a, 6, 0, 7, 2), 0.5);
    try testing.expectEqual(@as(f64, 0), tall.left[3]);
    try testing.expectEqual(@as(f64, 5), tall.right[3]);
    try testing.expectEqual(@as(?f64, 3), Profile.clearance(tall, high));
    try testing.expectEqual(@as(?f64, null), Profile.clearance(low, high)); // no shared height

    const both = try Profile.join(a, tall, low);
    // low reaches further right (7) but shares no height with high, so the
    // tall rectangle still governs.
    try testing.expectEqual(@as(?f64, 3), Profile.clearance(both, high));
}

test "a curve's profile follows the curve, not its control points" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An arch: base (0,0)-(6,0), quadratic control (3,6), apex 3 high.
    const segs = [_]geom.Segment{
        .{ .line = .{ .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 } } },
        .{ .quad = .{ .{ .x = 6, .y = 0 }, .{ .x = 3, .y = 6 }, .{ .x = 0, .y = 0 } } },
    };
    const cs = [_]geom.Contour{.{ .segments = &segs }};
    const p = try Profile.fromOutline(a, .{ .contours = &cs }, 0.25);
    // Bands reach the apex (3), not the control point (6).
    try testing.expectEqual(@as(usize, 13), p.left.len);
    // The arch is y = 12t(1-t), x = 6(1-t). In the top band (2.75 to 3) it
    // spans t = 0.5 +/- sqrt(0.25 - 2.75/12), so x from 3 - 6r to 3 + 6r.
    const r = @sqrt(0.25 - 2.75 / 12.0);
    try testing.expectApproxEqAbs(12 * r, p.right[11] - p.left[11], 0.0625);
    // Near the base it spans nearly all 6.
    try testing.expect(p.right[0] - p.left[0] > 5.5);
}

test "reach bridges narrow concavities but not wide separations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A C-like shape: arms at heights 0..1 and 4..5 reaching to x = 5, a
    // spine at x 0..1 between them.
    const arms = try Profile.join(a, try Profile.fromOutline(a, try rect(a, 0, 0, 5, 1), 0.5), try Profile.fromOutline(a, try rect(a, 0, 4, 5, 5), 0.5));
    const c = try Profile.join(a, arms, try Profile.fromOutline(a, try rect(a, 0, 0, 1, 5), 0.5));
    const mid = try Profile.fromOutline(a, try rect(a, 3, 2, 4, 3), 0.5);
    // Unreached, the middle block sits in the mouth: 2 clear of the spine.
    try testing.expectEqual(@as(?f64, 2), Profile.clearance(c, mid));
    // Reached by 1.5 (3 bands), the arms close the mouth: the block is 1 inside them.
    try testing.expectEqual(@as(?f64, -2), Profile.clearance(try Profile.reached(a, c, 3), mid));
    // A block high above stays unconstrained by anything within reach.
    const high = try Profile.fromOutline(a, try rect(a, 3, 8, 4, 9), 0.5);
    try testing.expectEqual(@as(?f64, null), Profile.clearance(try Profile.reached(a, c, 3), high));
}
