//! The background grid: graph paper behind everything on the canvas,
//! drawn across the whole canvas area each frame (panels and content go
//! over it; translucent ones show it through).
//!
//! Adaptive, as Fusion 360's sketch grid is: whatever the zoom, about the
//! same density shows. Lines come in decades of the document's unit (in
//! mm, 0.1, 1, 10, 100 mm …; in inches, 0.1, 1, 10 in), and a decade's
//! strength follows how far apart its lines are on screen: none at
//! `fade_lo` pixels or less, full at `fade_hi` or more, between by the
//! logarithm of the spacing. A line takes the strength of the coarsest
//! decade it is on, so the major lines (the coarser decade) are always
//! the stronger ones, and zooming fades decades in and out with no
//! popping. Every line is one device pixel wide; strength is contrast,
//! not weight.
//!
//! Lines (the default), dots at the crossings, or no grid: View › Grid.

const std = @import("std");

pub const Mode = enum { lines, dots, none };

/// Below this spacing on screen (pixels) a decade is not drawn.
pub const fade_lo: f64 = 6;
/// At or above this spacing, a decade is at full strength.
pub const fade_hi: f64 = 200;
/// Dots need more room than lines to read as a grid and not a tint.
pub const dots_lo: f64 = 12;

/// A decade's strength, 0 to 1, from its spacing on screen.
pub fn strength(spacing_px: f64, lo: f64) f32 {
    if (!(spacing_px > lo)) return 0;
    if (spacing_px >= fade_hi) return 1;
    const t = std.math.log10(spacing_px / lo) / std.math.log10(fade_hi / lo);
    // Eased, so the finer decade stays quiet until it has room.
    return @floatCast(t * t);
}

/// The most lines of one decade along one axis that are drawn.
pub const max_lines: f64 = 4000;

/// One decade to draw: its spacing in document units and its strength.
pub const Level = struct { step: f64, strength: f32 };

/// The decades to draw at `px_per_unit` screen pixels per document unit:
/// from the finest with room (`lo`) to the first at full strength (the
/// coarser ones would draw nothing new). At most four.
pub fn levels(px_per_unit: f64, lo: f64, out: *[4]Level) []Level {
    if (!(px_per_unit > 0) or !std.math.isFinite(px_per_unit)) return out[0..0];
    // The finest decade whose lines are more than `lo` apart.
    var k: i32 = @intFromFloat(@floor(std.math.log10(lo / px_per_unit)));
    while (std.math.pow(f64, 10, @floatFromInt(k)) * px_per_unit <= lo) k += 1;
    var n: usize = 0;
    while (n < out.len) : (k += 1) {
        const step = std.math.pow(f64, 10, @floatFromInt(k));
        const s = strength(step * px_per_unit, lo);
        out[n] = .{ .step = step, .strength = s };
        n += 1;
        if (s >= 1) break;
    }
    return out[0..n];
}

/// Calls `f(ctx, at, strength)` once for each line of the grid between
/// `lo` and `hi` (document units, along one axis): each at the strength of
/// the coarsest decade it is on.
pub fn lines(lv: []const Level, lo: f64, hi: f64, ctx: anytype, comptime f: fn (@TypeOf(ctx), f64, f32) void) void {
    for (lv, 0..) |l, k| {
        if (l.strength <= 0) continue;
        if (!(hi >= lo) or !std.math.isFinite(lo) or !std.math.isFinite(hi)) return;
        // Never more lines than a screen could show (a view gone wrong).
        if ((hi - lo) / l.step > max_lines) continue;
        const first: i64 = @intFromFloat(@ceil(lo / l.step));
        const last: i64 = @intFromFloat(@floor(hi / l.step));
        var i = first;
        while (i <= last) : (i += 1) {
            // A line on the next decade is drawn there, stronger.
            if (k + 1 < lv.len and @mod(i, 10) == 0) continue;
            f(ctx, @as(f64, @floatFromInt(i)) * l.step, l.strength);
        }
    }
}

const testing = std.testing;

test "the finest decade with room fades in; the first at full strength ends the list" {
    var buf: [4]Level = undefined;
    // 4 px per mm: 1 mm lines 4 px apart (too close), 10 mm 40 px apart,
    // 100 mm 400 px apart (full).
    const lv = levels(4, fade_lo, &buf);
    try testing.expectEqual(2, lv.len);
    try testing.expectApproxEqAbs(10, lv[0].step, 1e-9);
    try testing.expect(lv[0].strength > 0 and lv[0].strength < 1);
    try testing.expectApproxEqAbs(100, lv[1].step, 1e-9);
    try testing.expectEqual(1, lv[1].strength);
    // Zooming in brings the 1 mm decade in, faintly.
    const near = levels(7, fade_lo, &buf);
    try testing.expectApproxEqAbs(1, near[0].step, 1e-9);
    try testing.expect(near[0].strength < 0.05);
}

test "strength rises smoothly with spacing, from nothing to full" {
    try testing.expectEqual(0, strength(fade_lo, fade_lo));
    try testing.expectEqual(1, strength(fade_hi, fade_lo));
    var prev: f32 = 0;
    var p: f64 = fade_lo;
    while (p < fade_hi) : (p += 1) {
        const s = strength(p, fade_lo);
        try testing.expect(s >= prev);
        prev = s;
    }
}

test "each line once, at its coarsest decade's strength" {
    var buf: [4]Level = undefined;
    const lv = levels(4, fade_lo, &buf);
    const Count = struct {
        major: usize = 0,
        minor: usize = 0,
        fn f(c: *@This(), at: f64, s: f32) void {
            _ = at;
            if (s >= 1) c.major += 1 else c.minor += 1;
        }
    };
    var c: Count = .{};
    // 0 to 200 mm: majors at 0, 100, 200; minors at 10, 20 … but not 100.
    lines(lv, 0, 200, &c, Count.f);
    try testing.expectEqual(3, c.major);
    try testing.expectEqual(18, c.minor);
}
