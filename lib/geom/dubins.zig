//! The shortest route between two directed ends with a bound on bending.
//!
//! A route leaves a start vector (a position, a direction and a lead: how
//! far it first runs straight on) and arrives at an end vector (arriving
//! along its direction, the last `lead` of it straight), bending nowhere
//! more sharply than a circle of radius `radius` (the most bend allowed
//! over distance, 1 / radius). Between the two leads it is the shortest
//! such curve: a Dubins path, made of at most three pieces, each an arc of
//! that radius or a straight line (LSL, RSR, LSR, RSL, RLR, LRL). So the
//! whole route is exact lines and circular arcs, flattened only to draw.
//!
//! Units are the caller's (mm on the canvas); angles are radians,
//! anticlockwise from +x; y points up.

const std = @import("std");
const Point = @import("root.zig").Point;

/// A directed end: where, which way (radians), and how far the route runs
/// straight there: away from it at the start, into it at the end.
pub const Vector = struct {
    at: Point,
    angle: f64,
    lead: f64 = 0,
};

/// One piece of a route.
pub const Piece = union(enum) {
    line: struct { a: Point, b: Point },
    /// A circular arc: its centre, radius, the angle (from the centre) it
    /// starts at, and its sweep (positive anticlockwise: a left turn).
    arc: struct { c: Point, r: f64, start: f64, sweep: f64 },

    pub fn length(p: Piece) f64 {
        return switch (p) {
            .line => |l| std.math.hypot(l.b.x - l.a.x, l.b.y - l.a.y),
            .arc => |a| a.r * @abs(a.sweep),
        };
    }

    /// The point at fraction `t` (0..1) along it.
    pub fn at(p: Piece, t: f64) Point {
        return switch (p) {
            .line => |l| .{ .x = l.a.x + (l.b.x - l.a.x) * t, .y = l.a.y + (l.b.y - l.a.y) * t },
            .arc => |a| .{ .x = a.c.x + a.r * @cos(a.start + a.sweep * t), .y = a.c.y + a.r * @sin(a.start + a.sweep * t) },
        };
    }
};

/// A route: up to five pieces (lead, three, lead), its length, and its
/// direction where it arrives.
pub const Route = struct {
    pieces: [5]Piece = undefined,
    n: usize = 0,
    length: f64 = 0,
    end_angle: f64 = 0,

    pub fn items(r: *const Route) []const Piece {
        return r.pieces[0..r.n];
    }

    /// Points along it, no further from the true curve than `tol`, into
    /// `out` (its first point included); as many as fit.
    pub fn flatten(r: *const Route, tol: f64, out: []Point) []Point {
        var k: usize = 0;
        for (r.items(), 0..) |p, i| {
            if (i == 0 and k < out.len) {
                out[k] = p.at(0);
                k += 1;
            }
            const steps: usize = switch (p) {
                .line => 1,
                .arc => |a| blk: {
                    // A chord of angle θ strays r(1 − cos θ/2) from its arc.
                    const t = @max(tol, 1e-9);
                    const step = if (t >= a.r) std.math.pi / 2.0 else 2 * std.math.acos(1 - t / a.r);
                    break :blk @max(1, @as(usize, @intFromFloat(@ceil(@abs(a.sweep) / @max(step, 1e-6)))));
                },
            };
            for (1..steps + 1) |s| {
                if (k >= out.len) return out[0..k];
                out[k] = p.at(@as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps)));
                k += 1;
            }
        }
        return out[0..k];
    }

    fn add(r: *Route, p: Piece) void {
        if (p.length() <= 1e-12) return;
        r.pieces[r.n] = p;
        r.n += 1;
        r.length += p.length();
    }
};

const two_pi = 2 * std.math.pi;

fn mod2pi(x: f64) f64 {
    const m = @mod(x, two_pi);
    return if (m < 0) m + two_pi else m;
}

const Turn = enum { l, s, r };
const Word = [3]Turn;
const words = [_]Word{ .{ .l, .s, .l }, .{ .r, .s, .r }, .{ .l, .s, .r }, .{ .r, .s, .l }, .{ .r, .l, .r }, .{ .l, .r, .l } };

/// The three pieces' parameters for `w` (arc angles in radians, the line
/// in units of the radius), from the normalised distance `d` and the two
/// headings relative to the line between the points; null if `w` cannot
/// join them.
fn params(w: Word, d: f64, a: f64, b: f64) ?[3]f64 {
    const sa = @sin(a);
    const sb = @sin(b);
    const ca = @cos(a);
    const cb = @cos(b);
    const cab = @cos(a - b);
    switch (w[0]) {
        .l => if (w[1] == .s and w[2] == .l) {
            const p2 = 2 + d * d - 2 * cab + 2 * d * (sa - sb);
            if (p2 < 0) return null;
            const tmp = std.math.atan2(cb - ca, d + sa - sb);
            return .{ mod2pi(-a + tmp), @sqrt(p2), mod2pi(b - tmp) };
        } else if (w[1] == .s and w[2] == .r) {
            const p2 = -2 + d * d + 2 * cab + 2 * d * (sa + sb);
            if (p2 < 0) return null;
            const p = @sqrt(p2);
            const tmp = std.math.atan2(-ca - cb, d + sa + sb) - std.math.atan2(-2.0, p);
            return .{ mod2pi(-a + tmp), p, mod2pi(-b + tmp) };
        } else {
            // LRL
            const tmp = (6 - d * d + 2 * cab + 2 * d * (sb - sa)) / 8;
            if (@abs(tmp) > 1) return null;
            const p = mod2pi(two_pi - std.math.acos(tmp));
            const t = mod2pi(-a - std.math.atan2(ca - cb, d + sa - sb) + p / 2);
            return .{ t, p, mod2pi(b - a - t + p) };
        },
        .r => if (w[1] == .s and w[2] == .r) {
            const p2 = 2 + d * d - 2 * cab + 2 * d * (sb - sa);
            if (p2 < 0) return null;
            const tmp = std.math.atan2(ca - cb, d - sa + sb);
            return .{ mod2pi(a - tmp), @sqrt(p2), mod2pi(-b + tmp) };
        } else if (w[1] == .s and w[2] == .l) {
            const p2 = -2 + d * d + 2 * cab - 2 * d * (sa + sb);
            if (p2 < 0) return null;
            const p = @sqrt(p2);
            const tmp = std.math.atan2(ca + cb, d - sa - sb) - std.math.atan2(2.0, p);
            return .{ mod2pi(a - tmp), p, mod2pi(b - tmp) };
        } else {
            // RLR
            const tmp = (6 - d * d + 2 * cab + 2 * d * (sa - sb)) / 8;
            if (@abs(tmp) > 1) return null;
            const p = mod2pi(two_pi - std.math.acos(tmp));
            const t = mod2pi(a - std.math.atan2(ca - cb, d - sa + sb) + p / 2);
            return .{ t, p, mod2pi(a - b - t + p) };
        },
        .s => return null,
    }
}

/// A pose as the pieces are laid down.
const Pose = struct { p: Point, h: f64 };

/// Lays piece `turn` of parameter `v` from `pose` (radius `r`): appended
/// to `route` when given; the pose after it.
fn lay(into: ?*Route, pose: Pose, turn: Turn, v: f64, r: f64) Pose {
    switch (turn) {
        .s => {
            const len = v * r;
            const q: Point = .{ .x = pose.p.x + len * @cos(pose.h), .y = pose.p.y + len * @sin(pose.h) };
            if (into) |rt| rt.add(.{ .line = .{ .a = pose.p, .b = q } });
            return .{ .p = q, .h = pose.h };
        },
        .l => {
            const c: Point = .{ .x = pose.p.x - r * @sin(pose.h), .y = pose.p.y + r * @cos(pose.h) };
            const start = pose.h - std.math.pi / 2.0;
            if (into) |rt| rt.add(.{ .arc = .{ .c = c, .r = r, .start = start, .sweep = v } });
            return .{ .p = .{ .x = c.x + r * @cos(start + v), .y = c.y + r * @sin(start + v) }, .h = pose.h + v };
        },
        .r => {
            const c: Point = .{ .x = pose.p.x + r * @sin(pose.h), .y = pose.p.y - r * @cos(pose.h) };
            const start = pose.h + std.math.pi / 2.0;
            if (into) |rt| rt.add(.{ .arc = .{ .c = c, .r = r, .start = start, .sweep = -v } });
            return .{ .p = .{ .x = c.x + r * @cos(start - v), .y = c.y + r * @sin(start - v) }, .h = pose.h - v };
        },
    }
}

/// The shortest route from `from` to `to` bending no more sharply than a
/// circle of `radius` (> 0).
pub fn route(from: Vector, to: Vector, radius: f64) Route {
    const r = @max(radius, 1e-9);
    const q0: Point = .{ .x = from.at.x + from.lead * @cos(from.angle), .y = from.at.y + from.lead * @sin(from.angle) };
    const q1: Point = .{ .x = to.at.x - to.lead * @cos(to.angle), .y = to.at.y - to.lead * @sin(to.angle) };
    const dx = q1.x - q0.x;
    const dy = q1.y - q0.y;
    const d = std.math.hypot(dx, dy) / r;
    const phi = if (d > 0) std.math.atan2(dy, dx) else 0;
    const a = mod2pi(from.angle - phi);
    const b = mod2pi(to.angle - phi);
    // Each word that joins them, checked by laying it down; the shortest.
    var best: ?struct { w: Word, v: [3]f64, len: f64 } = null;
    const tol = 1e-7 * @max(1.0, r);
    for (words) |w| {
        const v = params(w, d, a, b) orelse continue;
        var pose: Pose = .{ .p = q0, .h = from.angle };
        for (0..3) |i| pose = lay(null, pose, w[i], v[i], r);
        const off = std.math.hypot(pose.p.x - q1.x, pose.p.y - q1.y);
        const turn = @abs(std.math.atan2(@sin(pose.h - to.angle), @cos(pose.h - to.angle)));
        if (off > tol or turn > 1e-6) continue;
        const len = (v[0] + v[1] + v[2]) * r;
        if (best == null or len < best.?.len) best = .{ .w = w, .v = v, .len = len };
    }
    var out: Route = .{ .end_angle = to.angle };
    out.add(.{ .line = .{ .a = from.at, .b = q0 } });
    if (best) |bw| {
        var pose: Pose = .{ .p = q0, .h = from.angle };
        for (0..3) |i| pose = lay(&out, pose, bw.w[i], bw.v[i], r);
    } else {
        // Never expected (some word always joins two poses): straight.
        out.add(.{ .line = .{ .a = q0, .b = q1 } });
    }
    out.add(.{ .line = .{ .a = q1, .b = to.at } });
    return out;
}

const testing = std.testing;

fn endOf(rt: *const Route) Point {
    const last = rt.items()[rt.n - 1];
    return last.at(1);
}

test "a route ends where asked, its pieces joined, and is no shorter than the straight line" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..2000) |_| {
        const from: Vector = .{ .at = .{ .x = rnd.float(f64) * 100 - 50, .y = rnd.float(f64) * 100 - 50 }, .angle = rnd.float(f64) * two_pi, .lead = rnd.float(f64) * 5 };
        const to: Vector = .{ .at = .{ .x = rnd.float(f64) * 100 - 50, .y = rnd.float(f64) * 100 - 50 }, .angle = rnd.float(f64) * two_pi, .lead = rnd.float(f64) * 5 };
        const radius = 0.5 + rnd.float(f64) * 10;
        const rt = route(from, to, radius);
        const e = endOf(&rt);
        try testing.expectApproxEqAbs(to.at.x, e.x, 1e-6);
        try testing.expectApproxEqAbs(to.at.y, e.y, 1e-6);
        const s = rt.items()[0].at(0);
        try testing.expectApproxEqAbs(from.at.x, s.x, 1e-9);
        try testing.expectApproxEqAbs(from.at.y, s.y, 1e-9);
        for (rt.items()[1..], 0..) |p, i| {
            const prev = rt.items()[i].at(1);
            const here = p.at(0);
            try testing.expectApproxEqAbs(prev.x, here.x, 1e-6);
            try testing.expectApproxEqAbs(prev.y, here.y, 1e-6);
        }
        try testing.expect(rt.length + 1e-9 >= std.math.hypot(to.at.x - from.at.x, to.at.y - from.at.y));
        for (rt.items()) |p| if (p == .arc) try testing.expectApproxEqAbs(radius, p.arc.r, 1e-12);
    }
}

test "straight ahead is a straight line; a U-turn is a half circle" {
    const a = route(.{ .at = .{ .x = 0, .y = 0 }, .angle = 0, .lead = 1 }, .{ .at = .{ .x = 10, .y = 0 }, .angle = 0, .lead = 1 }, 2);
    try testing.expectApproxEqAbs(10, a.length, 1e-9);
    for (a.items()) |p| try testing.expect(p == .line);
    // Leaving east, arriving west 4 below: a right half turn of radius 2.
    const u = route(.{ .at = .{ .x = 0, .y = 0 }, .angle = 0 }, .{ .at = .{ .x = 0, .y = -4 }, .angle = std.math.pi }, 2);
    try testing.expectApproxEqAbs(2 * std.math.pi, u.length, 1e-9);
    try testing.expectEqual(1, u.n);
}

test "flattened, a route stays within the tolerance of its arcs" {
    const rt = route(.{ .at = .{ .x = 0, .y = 0 }, .angle = 0, .lead = 2 }, .{ .at = .{ .x = -5, .y = -12 }, .angle = 0, .lead = 2 }, 3);
    var buf: [512]Point = undefined;
    const pts = rt.flatten(0.01, &buf);
    try testing.expect(pts.len > 4);
    for (rt.items()) |p| if (p == .arc) {
        const a = p.arc;
        // Every midpoint of a chord on this arc is within tol of it.
        for (pts[0 .. pts.len - 1], pts[1..]) |q0, q1| {
            const m: Point = .{ .x = (q0.x + q1.x) / 2, .y = (q0.y + q1.y) / 2 };
            const r0 = std.math.hypot(q0.x - a.c.x, q0.y - a.c.y);
            const r1 = std.math.hypot(q1.x - a.c.x, q1.y - a.c.y);
            if (@abs(r0 - a.r) > 1e-9 or @abs(r1 - a.r) > 1e-9) continue;
            try testing.expect(a.r - std.math.hypot(m.x - a.c.x, m.y - a.c.y) <= 0.01 + 1e-9);
        }
    };
}
