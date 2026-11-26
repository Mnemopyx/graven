//! An open path of exact segments shortened at its ends by lengths along
//! it (a connection's line stopping where an arrowhead or dot begins),
//! and its directions at its two ends. The cut pieces stay exact (lines,
//! Béziers and conics cut by `boolean.sub`); only where to cut is found
//! by measuring, to well under a micrometre at drawing sizes.

const std = @import("std");
const root = @import("root.zig");
const boolean = @import("boolean.zig");

const Point = root.Point;
const Segment = root.Segment;

/// Chords a curved piece is measured in (then as many again, the two
/// sums extrapolated: a chord sum's error falls as the square of the
/// chord).
const steps = 32;

/// Segment `s`'s length, measured along it.
pub fn length(s: Segment) f64 {
    return lengthTo(s, 1);
}

/// The length of `s` from its start to parameter `t`.
fn lengthTo(s: Segment, t: f64) f64 {
    if (s == .line) return t * dist(s.line[0], s.line[1]);
    const coarse = chords(s, t, steps);
    const fine = chords(s, t, 2 * steps);
    return fine + (fine - coarse) / 3;
}

fn chords(s: Segment, t: f64, n: usize) f64 {
    var l: f64 = 0;
    var p = s.start();
    for (1..n + 1) |k| {
        const q = s.at(t * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
        l += dist(p, q);
        p = q;
    }
    return l;
}

/// The parameter at which `s` has run `d` from its start (0 ≤ d ≤ its
/// length).
fn paramAt(s: Segment, d: f64) f64 {
    if (s == .line) {
        const l = dist(s.line[0], s.line[1]);
        return if (l > 0) std.math.clamp(d / l, 0, 1) else 0;
    }
    var lo: f64 = 0;
    var hi: f64 = 1;
    for (0..48) |_| {
        const mid = (lo + hi) / 2;
        if (lengthTo(s, mid) < d) lo = mid else hi = mid;
    }
    return (lo + hi) / 2;
}

fn dist(a: Point, b: Point) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

/// The path `segs` (pieces joined end to end) without its first `head`
/// and last `tail` (lengths along it), into `out`. Nothing when they
/// meet or cross.
pub fn trimmed(a: std.mem.Allocator, segs: []const Segment, head: f64, tail: f64, out: *std.ArrayList(Segment)) std.mem.Allocator.Error!void {
    const lens = try a.alloc(f64, segs.len);
    defer a.free(lens);
    var total: f64 = 0;
    for (segs, lens) |s, *l| {
        l.* = length(s);
        total += l.*;
    }
    const from = @max(0, head);
    const to = total - @max(0, tail);
    if (!(to > from)) return;
    var at: f64 = 0;
    for (segs, lens) |s, l| {
        defer at += l;
        const a0 = @max(from, at);
        const a1 = @min(to, at + l);
        if (!(a1 > a0) or l <= 0) continue;
        if (a0 <= at and a1 >= at + l) {
            try out.append(a, s);
            continue;
        }
        const t0 = if (a0 <= at) 0 else paramAt(s, a0 - at);
        const t1 = if (a1 >= at + l) 1 else paramAt(s, a1 - at);
        try out.append(a, boolean.sub(s, t0, t1));
    }
}

/// The direction (radians) `s` leaves its start in.
pub fn leaving(s: Segment) f64 {
    const p = s.points();
    for (p[1..]) |q| if (dist(p[0], q) > 1e-12) return std.math.atan2(q.y - p[0].y, q.x - p[0].x);
    return 0;
}

/// The direction (radians) `s` arrives at its end in.
pub fn arriving(s: Segment) f64 {
    const p = s.points();
    const e = p[p.len - 1];
    var k = p.len - 1;
    while (k > 0) {
        k -= 1;
        if (dist(p[k], e) > 1e-12) return std.math.atan2(e.y - p[k].y, e.x - p[k].x);
    }
    return 0;
}

test "a path trimmed at both ends: a line shortened, an arc cut where it has run so far" {
    const testing = std.testing;
    const a = testing.allocator;
    var buf: [4]Segment = undefined;
    const quarter = root.arc(.{ .x = 0, .y = 0 }, 10, 0, std.math.pi / 2.0, &buf);
    var segs: std.ArrayList(Segment) = .empty;
    defer segs.deinit(a);
    try segs.append(a, .{ .line = .{ .{ .x = 10, .y = -5 }, .{ .x = 10, .y = 0 } } });
    try segs.appendSlice(a, quarter);
    var out: std.ArrayList(Segment) = .empty;
    defer out.deinit(a);
    try trimmed(a, segs.items, 2, std.math.pi, &out);
    try testing.expectEqual(2, out.items.len);
    try testing.expectApproxEqAbs(10, out.items[0].start().x, 1e-12);
    try testing.expectApproxEqAbs(-3, out.items[0].start().y, 1e-12);
    // π along the circle of radius 10 back from 90°: at 72°.
    const e = out.items[1].end();
    const th = 72.0 * std.math.pi / 180.0;
    try testing.expectApproxEqAbs(10 * @cos(th), e.x, 1e-7);
    try testing.expectApproxEqAbs(10 * @sin(th), e.y, 1e-7);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, leaving(out.items[0]), 1e-12);
    try testing.expectApproxEqAbs(th + std.math.pi / 2.0, arriving(out.items[1]), 1e-6);
    // Trimmed past each other: nothing.
    out.clearRetainingCapacity();
    try trimmed(a, segs.items, 11, 11, &out);
    try testing.expectEqual(0, out.items.len);
}
