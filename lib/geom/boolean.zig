//! Cutting outlines out of an outline, with exact curves: the region inside
//! `base` (even-odd) and outside every cutter (each even-odd), as closed
//! contours, outer ones counter-clockwise and holes clockwise (y up).
//!
//! The segments of all the outlines are split where they cross or touch
//! one another; a piece is kept when the region lies on one side of it and
//! not the other, travelling with the region on its left. Pieces are exact
//! sub-curves of the originals (a conic stays a conic, so an arc stays an
//! arc). Crossings are found on fine polylines and refined on the curves;
//! sides are judged on fine polylines a little off each piece's middle.
//!
//! So a cutter crossing the base's edge leaves a notch, cutters that
//! overlap cut their union, and a cutter outside the base is ignored.

const std = @import("std");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;
const Point = root.Point;
const Segment = root.Segment;
const Contour = root.Contour;
const Outline = root.Outline;
const Box = root.Box;

pub const Error = Allocator.Error || error{
    /// The kept pieces did not join into closed contours (a degenerate
    /// meeting the method does not resolve).
    Unjoined,
};

/// Sub-curve of `s` from parameter `t0` to `t1`, exact.
pub fn sub(s: Segment, t0: f64, t1: f64) Segment {
    return switch (s) {
        .line => .{ .line = .{ s.at(t0), s.at(t1) } },
        .quad => |p| .{ .quad = subPoly(3, p, t0, t1) },
        .cubic => |p| .{ .cubic = subPoly(4, p, t0, t1) },
        .conic => |c| blk: {
            // In homogeneous coordinates a conic is a quadratic: split that.
            const H = [3]f64;
            const h: [3]H = .{
                .{ c.p[0].x, c.p[0].y, 1 },
                .{ c.p[1].x * c.w, c.p[1].y * c.w, c.w },
                .{ c.p[2].x, c.p[2].y, 1 },
            };
            const q = subPoly3(h, t0, t1);
            const w = q[1][2] / @sqrt(q[0][2] * q[2][2]);
            break :blk .{ .conic = .{
                .p = .{
                    .{ .x = q[0][0] / q[0][2], .y = q[0][1] / q[0][2] },
                    .{ .x = q[1][0] / q[1][2], .y = q[1][1] / q[1][2] },
                    .{ .x = q[2][0] / q[2][2], .y = q[2][1] / q[2][2] },
                },
                .w = w,
            } };
        },
    };
}

fn lerp(a: Point, b: Point, t: f64) Point {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

/// De Casteljau: the first part of `p` up to `t`, then its last part from
/// `t0 / t1`.
fn subPoly(comptime n: usize, p: [n]Point, t0: f64, t1: f64) [n]Point {
    const left = splitLeft(n, p, t1);
    if (t1 <= 0) return left;
    return splitRight(n, left, t0 / t1);
}

fn splitLeft(comptime n: usize, p: [n]Point, t: f64) [n]Point {
    var work = p;
    var out: [n]Point = undefined;
    out[0] = work[0];
    for (1..n) |k| {
        for (0..n - k) |i| work[i] = lerp(work[i], work[i + 1], t);
        out[k] = work[0];
    }
    return out;
}

fn splitRight(comptime n: usize, p: [n]Point, t: f64) [n]Point {
    var work = p;
    var out: [n]Point = undefined;
    out[n - 1] = work[n - 1];
    for (1..n) |k| {
        for (0..n - k) |i| work[i] = lerp(work[i], work[i + 1], t);
        out[n - 1 - k] = work[n - 1 - k];
    }
    return out;
}

fn subPoly3(h: [3][3]f64, t0: f64, t1: f64) [3][3]f64 {
    const L = struct {
        fn l(a: [3]f64, b: [3]f64, t: f64) [3]f64 {
            return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
        }
        fn left(p: [3][3]f64, t: f64) [3][3]f64 {
            const a = l(p[0], p[1], t);
            const b = l(p[1], p[2], t);
            return .{ p[0], a, l(a, b, t) };
        }
        fn right(p: [3][3]f64, t: f64) [3][3]f64 {
            const a = l(p[0], p[1], t);
            const b = l(p[1], p[2], t);
            return .{ l(a, b, t), b, p[2] };
        }
    };
    const left = L.left(h, t1);
    if (t1 <= 0) return left;
    return L.right(left, t0 / t1);
}

/// A segment flattened: its points at evenly spaced parameters.
const Flat = struct {
    pts: []Point,
    box: Box,

    fn steps(s: Segment) usize {
        if (s == .line) return 1;
        const b = s.bounds();
        const diag = @sqrt(b.width() * b.width() + b.height() * b.height());
        // Fine enough to find crossings (refined on the curves after) and to
        // judge sides well inside the side offset.
        return @intFromFloat(std.math.clamp(@ceil(diag / 0.05), 4, 2048));
    }

    fn of(a: Allocator, s: Segment) Allocator.Error!Flat {
        const n = steps(s);
        const pts = try a.alloc(Point, n + 1);
        for (pts, 0..) |*p, i| p.* = s.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
        pts[0] = s.start();
        pts[n] = s.end();
        var b = Box.empty;
        for (pts) |p| b = b.addPoint(p);
        return .{ .pts = pts, .box = b };
    }

    fn t(f: Flat, i: usize, u: f64) f64 {
        return (@as(f64, @floatFromInt(i)) + u) / @as(f64, @floatFromInt(f.pts.len - 1));
    }
};

const Seg = struct {
    s: Segment,
    flat: Flat,
    /// Which input outline it is from: 0 the base, then the cutters.
    from: usize,
    cuts: std.ArrayList(Cut) = .empty,
};

const Cut = struct { t: f64, p: Point };

fn overlaps(a: Box, b: Box, tol: f64) bool {
    return a.x0 <= b.x1 + tol and b.x0 <= a.x1 + tol and a.y0 <= b.y1 + tol and b.y0 <= a.y1 + tol;
}

/// Refines a meeting of `a` near `ta` and `b` near `tb` (Newton on
/// a(ta) - b(tb), with numeric derivatives); null when it does not settle.
fn refine(a: Segment, b: Segment, ta0: f64, tb0: f64) ?[2]f64 {
    var ta = ta0;
    var tb = tb0;
    const h = 1e-7;
    for (0..30) |_| {
        const pa = a.at(ta);
        const pb = b.at(tb);
        const fx = pa.x - pb.x;
        const fy = pa.y - pb.y;
        if (fx * fx + fy * fy < 1e-24) break;
        const da = a.at(ta + h);
        const db = b.at(tb + h);
        const j00 = (da.x - pa.x) / h;
        const j10 = (da.y - pa.y) / h;
        const j01 = -(db.x - pb.x) / h;
        const j11 = -(db.y - pb.y) / h;
        const det = j00 * j11 - j01 * j10;
        if (@abs(det) < 1e-18) break;
        ta -= (fx * j11 - fy * j01) / det;
        tb -= (j00 * fy - j10 * fx) / det;
        ta = std.math.clamp(ta, 0, 1);
        tb = std.math.clamp(tb, 0, 1);
    }
    const pa = a.at(ta);
    const pb = b.at(tb);
    if (@abs(pa.x - pb.x) + @abs(pa.y - pb.y) > 1e-7) return null;
    return .{ ta, tb };
}

/// Where point `p` lies on `f` within `tol`: its parameter, or null.
fn onFlat(f: Flat, p: Point, tol: f64) ?f64 {
    if (!overlaps(f.box, .{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y }, tol)) return null;
    var best: ?f64 = null;
    var best_d = tol * tol;
    for (f.pts[0 .. f.pts.len - 1], f.pts[1..], 0..) |q0, q1, i| {
        const dx = q1.x - q0.x;
        const dy = q1.y - q0.y;
        const len2 = dx * dx + dy * dy;
        const u = if (len2 == 0) 0 else std.math.clamp(((p.x - q0.x) * dx + (p.y - q0.y) * dy) / len2, 0, 1);
        const ex = q0.x + u * dx - p.x;
        const ey = q0.y + u * dy - p.y;
        const d = ex * ex + ey * ey;
        if (d <= best_d) {
            best_d = d;
            best = f.t(i, u);
        }
    }
    return best;
}

/// Refines `t` so `s(t)` is the nearest point to `p` (Newton on the
/// distance's derivative).
fn nearest(s: Segment, p: Point, t0: f64) f64 {
    var t = t0;
    const h = 1e-6;
    for (0..20) |_| {
        const f = struct {
            fn g(seg: Segment, q: Point, x: f64) f64 {
                const a = seg.at(std.math.clamp(x, 0, 1));
                return (a.x - q.x) * (a.x - q.x) + (a.y - q.y) * (a.y - q.y);
            }
        }.g;
        const d1 = (f(s, p, t + h) - f(s, p, t - h)) / (2 * h);
        const d2 = (f(s, p, t + h) - 2 * f(s, p, t) + f(s, p, t - h)) / (h * h);
        if (d2 <= 0) break;
        const next = std.math.clamp(t - d1 / d2, 0, 1);
        if (@abs(next - t) < 1e-13) break;
        t = next;
    }
    return t;
}

/// A segment with its exact bounds, for the inside test.
const Bounded = struct { s: Segment, box: Box };

/// Whether `p` lies inside the segments' contours (even-odd), exactly: the
/// crossings of the horizontal ray right from `p` with the curves
/// themselves, found as roots of their polynomials. A ray through a vertex
/// is moved off it by a hair first.
fn insideExact(segs: []const Bounded, p0: Point, scale: f64) bool {
    var p = p0;
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        const eps = 1e-12 * scale;
        const clear = for (segs) |b| {
            if (@abs(b.s.start().y - p.y) <= eps) break false;
        } else true;
        if (clear) break;
        p.y += 7.3e-12 * scale;
    }
    var inside = false;
    for (segs) |b| {
        if (p.y < b.box.y0 or p.y > b.box.y1 or b.box.x1 <= p.x) continue;
        var roots: [3]f64 = undefined;
        for (rootsAtY(b.s, p.y, &roots)) |t| {
            if (b.s.at(t).x > p.x) inside = !inside;
        }
    }
    return inside;
}

/// The parameters in (0, 1) where `s` meets the line y = `y`.
fn rootsAtY(s: Segment, y: f64, out: *[3]f64) []f64 {
    // y(t) - y (for a conic, its numerator: the denominator is positive)
    // in the power basis, low degree first.
    var c: [4]f64 = .{ 0, 0, 0, 0 };
    switch (s) {
        .line => |p| c = .{ p[0].y - y, p[1].y - p[0].y, 0, 0 },
        .quad => |p| c = .{ p[0].y - y, 2 * (p[1].y - p[0].y), p[0].y - 2 * p[1].y + p[2].y, 0 },
        .conic => |k| {
            const y0 = k.p[0].y - y;
            const y1 = k.p[1].y - y;
            const y2 = k.p[2].y - y;
            c = .{ y0, 2 * (k.w * y1 - y0), y0 - 2 * k.w * y1 + y2, 0 };
        },
        .cubic => |p| c = .{
            p[0].y - y,
            3 * (p[1].y - p[0].y),
            3 * (p[0].y - 2 * p[1].y + p[2].y),
            -p[0].y + 3 * p[1].y - 3 * p[2].y + p[3].y,
        },
    }
    const f = struct {
        fn at(cc: [4]f64, t: f64) f64 {
            return ((cc[3] * t + cc[2]) * t + cc[1]) * t + cc[0];
        }
    }.at;
    // Split [0, 1] where the derivative vanishes; one root at most in each
    // monotone piece, found by bisection.
    var cuts: [4]f64 = undefined;
    var nc: usize = 0;
    cuts[nc] = 0;
    nc += 1;
    const d2 = 3 * c[3];
    const d1 = 2 * c[2];
    const d0 = c[1];
    if (@abs(d2) > 1e-300) {
        const disc = d1 * d1 - 4 * d2 * d0;
        if (disc > 0) {
            const sq = @sqrt(disc);
            var r = [2]f64{ (-d1 - sq) / (2 * d2), (-d1 + sq) / (2 * d2) };
            if (r[0] > r[1]) std.mem.swap(f64, &r[0], &r[1]);
            for (r) |t| if (t > 0 and t < 1) {
                cuts[nc] = t;
                nc += 1;
            };
        }
    } else if (@abs(d1) > 1e-300) {
        const t = -d0 / d1;
        if (t > 0 and t < 1) {
            cuts[nc] = t;
            nc += 1;
        }
    }
    cuts[nc] = 1;
    nc += 1;
    var n: usize = 0;
    for (cuts[0 .. nc - 1], cuts[1..nc]) |lo0, hi0| {
        var lo = lo0;
        var hi = hi0;
        var flo = f(c, lo);
        const fhi = f(c, hi);
        if (flo == 0 or fhi == 0 or (flo > 0) == (fhi > 0)) continue;
        for (0..64) |_| {
            const mid = (lo + hi) / 2;
            const fm = f(c, mid);
            if ((fm > 0) == (flo > 0)) {
                lo = mid;
                flo = fm;
            } else hi = mid;
        }
        const t = (lo + hi) / 2;
        if (t > 0 and t < 1) {
            out[n] = t;
            n += 1;
        }
    }
    return out[0..n];
}

/// Which points a combination keeps: `inside` is given, for each input,
/// whether the point lies inside it (even-odd), and says whether the point
/// is in the result.
pub const Rule = struct {
    ctx: *const anyopaque,
    inside: *const fn (ctx: *const anyopaque, in: []const bool) bool,
};

/// `base` with every one of `cutters` cut out of it (see the file's
/// comment). The result is allocated from `a`.
pub fn cut(a: Allocator, base: Outline, cutters: []const Outline) Error!Outline {
    const inputs = try a.alloc(Outline, cutters.len + 1);
    defer a.free(inputs);
    inputs[0] = base;
    @memcpy(inputs[1..], cutters);
    const R = struct {
        fn inside(_: *const anyopaque, in: []const bool) bool {
            if (!in[0]) return false;
            for (in[1..]) |x| if (x) return false;
            return true;
        }
    };
    return combine(a, inputs, .{ .ctx = undefined, .inside = R.inside });
}

/// The region `rule` keeps of the plane, given which of `inputs` (each
/// filled even-odd) each point lies in: exact contours, as `cut`'s. Union,
/// difference, and "whose layer is on top here" are all rules.
pub fn combine(a: Allocator, inputs: []const Outline, rule: Rule) Error!Outline {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var segs: std.ArrayList(Seg) = .empty;
    const exact = try sa.alloc([]const Bounded, inputs.len);
    const boxes = try sa.alloc(Box, inputs.len);
    var total = Box.empty;
    for (inputs, 0..) |o, k| {
        var bs: std.ArrayList(Bounded) = .empty;
        var b = Box.empty;
        for (o.contours) |c| for (c.segments) |s| {
            if (s == .line and s.start().eql(s.end())) continue;
            const f = try Flat.of(sa, s);
            try segs.append(sa, .{ .s = s, .flat = f, .from = k });
            const sb = s.bounds();
            try bs.append(sa, .{ .s = s, .box = sb });
            b = b.join(sb);
            total = total.join(f.box);
        };
        exact[k] = bs.items;
        boxes[k] = b;
    }
    if (segs.items.len == 0) return .blank;
    const scale = @max(1.0, @max(total.width(), total.height()));
    const tol = 1e-9 * scale;
    const region: Region = .{ .segs = exact, .boxes = boxes, .member = try sa.alloc(bool, inputs.len), .rule = rule, .scale = scale };

    // Where segments meet: crossings, and ends lying on another segment.
    for (segs.items, 0..) |*sa_, i| for (segs.items[i + 1 ..]) |*sb| {
        if (!overlaps(sa_.flat.box, sb.flat.box, 1e-6 * scale)) continue;
        const fa = sa_.flat;
        const fb = sb.flat;
        for (fa.pts[0 .. fa.pts.len - 1], fa.pts[1..], 0..) |a0, a1, ia| {
            const ab: Box = Box.empty.addPoint(a0).addPoint(a1);
            if (!overlaps(ab, fb.box, tol)) continue;
            for (fb.pts[0 .. fb.pts.len - 1], fb.pts[1..], 0..) |b0, b1, ib| {
                const r: Point = .{ .x = a1.x - a0.x, .y = a1.y - a0.y };
                const q: Point = .{ .x = b1.x - b0.x, .y = b1.y - b0.y };
                const den = r.cross(q);
                if (@abs(den) < 1e-18) continue;
                const w: Point = .{ .x = b0.x - a0.x, .y = b0.y - a0.y };
                const u = w.cross(q) / den;
                const v = w.cross(r) / den;
                if (u < -1e-9 or u > 1 + 1e-9 or v < -1e-9 or v > 1 + 1e-9) continue;
                const got = refine(sa_.s, sb.s, fa.t(ia, std.math.clamp(u, 0, 1)), fb.t(ib, std.math.clamp(v, 0, 1))) orelse continue;
                const p = sa_.s.at(got[0]);
                try sa_.cuts.append(sa, .{ .t = got[0], .p = p });
                try sb.cuts.append(sa, .{ .t = got[1], .p = p });
            }
        }
        // Ends on the other (touching, and runs along one another).
        for ([_]*Seg{ sa_, sb }, [_]*Seg{ sb, sa_ }) |x, y| {
            for ([_]Point{ x.s.start(), x.s.end() }) |p| {
                const t0 = onFlat(y.flat, p, 1e-6 * scale) orelse continue;
                const t = nearest(y.s, p, t0);
                const at = y.s.at(t);
                if (@abs(at.x - p.x) + @abs(at.y - p.y) > 1e-7 * scale) continue;
                try y.cuts.append(sa, .{ .t = t, .p = p });
            }
        }
    };

    // The pieces, each kept when the region is on one side only; the same
    // piece from two outlines (edges along one another) once.
    const Piece = struct { s: Segment, used: bool = false };
    var pieces: std.ArrayList(Piece) = .empty;
    var seen: std.AutoHashMapUnmanaged([6]i64, void) = .empty;
    const q = 1e-6 * scale;
    for (segs.items) |*sg| {
        std.mem.sort(Cut, sg.cuts.items, {}, struct {
            fn lt(_: void, x: Cut, y: Cut) bool {
                return x.t < y.t;
            }
        }.lt);
        var ts: std.ArrayList(Cut) = .empty;
        try ts.append(sa, .{ .t = 0, .p = sg.s.start() });
        for (sg.cuts.items) |c| {
            if (c.t <= 1e-9 or c.t >= 1 - 1e-9) continue;
            const last = ts.items[ts.items.len - 1];
            if (c.t - last.t < 1e-9 or (@abs(c.p.x - last.p.x) + @abs(c.p.y - last.p.y)) < tol) continue;
            try ts.append(sa, c);
        }
        const end: Cut = .{ .t = 1, .p = sg.s.end() };
        if (ts.items.len > 1) {
            const last = ts.items[ts.items.len - 1];
            if (@abs(end.p.x - last.p.x) + @abs(end.p.y - last.p.y) < tol) ts.items.len -= 1;
        }
        try ts.append(sa, end);
        for (ts.items[0 .. ts.items.len - 1], ts.items[1..]) |c0, c1| {
            var piece = sub(sg.s, c0.t, c1.t);
            setEnds(&piece, c0.p, c1.p);
            // Its middle and the way it goes there.
            const m = piece.at(0.5);
            const m2 = piece.at(0.5 + 1e-4);
            const m1 = piece.at(0.5 - 1e-4);
            var dx = m2.x - m1.x;
            var dy = m2.y - m1.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (len < 1e-15) continue;
            dx /= len;
            dy /= len;
            // A hair to each side: a tenth of the piece's chord, so never
            // past a corner, and at most a micrometre.
            const chord = @abs(c1.p.x - c0.p.x) + @abs(c1.p.y - c0.p.y);
            const off = std.math.clamp(0.1 * chord, 1e-9 * scale, 1e-3);
            const left: Point = .{ .x = m.x - dy * off, .y = m.y + dx * off };
            const right: Point = .{ .x = m.x + dy * off, .y = m.y - dx * off };
            const in_l = region.inside(left);
            const in_r = region.inside(right);
            if (in_l == in_r) continue;
            const kept = if (in_l) piece else piece.reversed();
            const key = [6]i64{ cell(kept.start().x, q), cell(kept.start().y, q), cell(kept.end().x, q), cell(kept.end().y, q), cell(kept.at(0.5).x, q * 100), cell(kept.at(0.5).y, q * 100) };
            if ((try seen.getOrPut(sa, key)).found_existing) continue;
            try pieces.append(sa, .{ .s = kept });
        }
    }

    // Joined end to start into contours: pieces found by where they start,
    // in a grid of cells the joining tolerance across.
    var contours: std.ArrayList(Contour) = .empty;
    const join_tol = 1e-6 * scale;
    var starts: std.AutoHashMapUnmanaged([2]i64, std.ArrayList(usize)) = .empty;
    for (pieces.items, 0..) |pc, k| {
        const g = try starts.getOrPut(sa, .{ cell(pc.s.start().x, join_tol), cell(pc.s.start().y, join_tol) });
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(sa, k);
    }
    for (pieces.items) |*first| {
        if (first.used) continue;
        first.used = true;
        var chain: std.ArrayList(Segment) = .empty;
        try chain.append(a, first.s);
        const start = first.s.start();
        while (true) {
            const at = chain.items[chain.items.len - 1].end();
            if (near(at, start, join_tol)) break;
            var best: ?usize = null;
            var best_d: f64 = join_tol;
            const cx = cell(at.x, join_tol);
            const cy = cell(at.y, join_tol);
            var dx: i64 = -1;
            while (dx <= 1) : (dx += 1) {
                var dy: i64 = -1;
                while (dy <= 1) : (dy += 1) {
                    const list = starts.get(.{ cx + dx, cy + dy }) orelse continue;
                    for (list.items) |k| {
                        const pc = pieces.items[k];
                        if (pc.used) continue;
                        const d = @abs(pc.s.start().x - at.x) + @abs(pc.s.start().y - at.y);
                        if (d <= best_d) {
                            best_d = d;
                            best = k;
                        }
                    }
                }
            }
            const k = best orelse return error.Unjoined;
            pieces.items[k].used = true;
            var next = pieces.items[k].s;
            setEnds(&next, at, next.end());
            try chain.append(a, next);
        }
        // Closed exactly.
        setEnds(&chain.items[chain.items.len - 1], chain.items[chain.items.len - 1].start(), start);
        try contours.append(a, .{ .segments = chain.items });
    }
    return .{ .contours = contours.items };
}

/// The inputs' polygons and boxes, for judging which side of a piece the
/// region is on.
const Region = struct {
    segs: []const []const Bounded,
    boxes: []const Box,
    member: []bool,
    rule: Rule,
    scale: f64,

    fn inside(r: Region, p: Point) bool {
        for (r.segs, r.boxes, r.member) |segs, b, *m| {
            m.* = p.x >= b.x0 and p.x <= b.x1 and p.y >= b.y0 and p.y <= b.y1 and insideExact(segs, p, r.scale);
        }
        return r.rule.inside(r.rule.ctx, r.member);
    }
};

fn cell(v: f64, size: f64) i64 {
    return @intFromFloat(@floor(v / size));
}

fn near(p: Point, q: Point, tol: f64) bool {
    return @abs(p.x - q.x) + @abs(p.y - q.y) <= tol;
}

fn setEnds(s: *Segment, p0: Point, p1: Point) void {
    switch (s.*) {
        .line => |*p| p.* = .{ p0, p1 },
        .quad => |*p| {
            p[0] = p0;
            p[2] = p1;
        },
        .cubic => |*p| {
            p[0] = p0;
            p[3] = p1;
        },
        .conic => |*c| {
            c.p[0] = p0;
            c.p[2] = p1;
        },
    }
}

const testing = std.testing;

fn rect(a: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) !Outline {
    const segs = try a.alloc(Segment, 4);
    segs[0] = .{ .line = .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 } } };
    segs[1] = .{ .line = .{ .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 } } };
    segs[2] = .{ .line = .{ .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } } };
    segs[3] = .{ .line = .{ .{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 } } };
    const cs = try a.alloc(Contour, 1);
    cs[0] = .{ .segments = segs };
    return .{ .contours = cs };
}

fn circle(a: Allocator, c: Point, r: f64) !Outline {
    var buf: [4]Segment = undefined;
    const arcs = root.arc(c, r, 0, 2 * std.math.pi, &buf);
    const cs = try a.alloc(Contour, 1);
    cs[0] = .{ .segments = try a.dupe(Segment, arcs) };
    return .{ .contours = cs };
}

test "a sub-curve is the curve between its parameters" {
    var buf: [4]Segment = undefined;
    const q = root.arc(.{ .x = 0, .y = 0 }, 2, 0, std.math.pi / 2.0, &buf)[0];
    const s = sub(q, 0.25, 0.75);
    try testing.expect(s == .conic);
    for ([_]f64{ 0, 0.3, 0.5, 1 }) |t| {
        const p = s.at(t);
        try testing.expectApproxEqAbs(@as(f64, 2), @sqrt(p.x * p.x + p.y * p.y), 1e-12);
    }
    try testing.expectApproxEqAbs(q.at(0.25).x, s.start().x, 1e-12);
    try testing.expectApproxEqAbs(q.at(0.75).y, s.end().y, 1e-12);
    const cu: Segment = .{ .cubic = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 3, .y = -1 }, .{ .x = 4, .y = 2 } } };
    const cs = sub(cu, 0.2, 0.9);
    try testing.expectApproxEqAbs(cu.at(0.2 + 0.7 * 0.4).x, cs.at(0.4).x, 1e-12);
}

test "holes inside, across the edge, overlapping and outside: one exact body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plate = try rect(a, 0, 0, 20, 10);
    const cutters = [_]Outline{
        // Inside: a hole.
        try circle(a, .{ .x = 5, .y = 5 }, 2),
        // Across the right edge: a notch.
        try circle(a, .{ .x = 20, .y = 5 }, 2),
        // Two overlapping: one hole, their union.
        try rect(a, 10, 2, 13, 5),
        try rect(a, 12, 4, 15, 7),
        // Outside: nothing.
        try circle(a, .{ .x = 40, .y = 5 }, 1),
    };
    const body = try cut(a, plate, &cutters);
    // The plate with its notch (one contour), and two holes.
    try testing.expectEqual(@as(usize, 3), body.contours.len);
    var outer: usize = 0;
    for (body.contours) |c| {
        try testing.expect(c.isClosed());
        if (c.signedArea() > 0) outer += 1;
        // Arcs stay arcs.
    }
    try testing.expectEqual(@as(usize, 1), outer);
    const pi = std.math.pi;
    const union_area = 3 * 3 + 3 * 3 - 1 * 1;
    const want: f64 = 200.0 - pi * 4.0 - pi * 4.0 / 2.0 - union_area;
    try testing.expectApproxEqAbs(want, body.signedArea(), 1e-9);
    var conics: usize = 0;
    for (body.contours) |c| for (c.segments) |s| {
        if (s == .conic) conics += 1;
    };
    try testing.expect(conics >= 4 + 2);
}

test "a hole touching the edge along a side leaves a notch, no sliver" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plate = try rect(a, 0, 0, 20, 10);
    const cutters = [_]Outline{try rect(a, 0, 3, 4, 6)};
    const body = try cut(a, plate, &cutters);
    try testing.expectEqual(@as(usize, 1), body.contours.len);
    try testing.expectApproxEqAbs(@as(f64, 200 - 12), body.signedArea(), 1e-9);
}
