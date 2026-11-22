//! The background grid: graph paper behind everything on the canvas,
//! drawn across the whole canvas area each frame (panels and content go
//! over it; translucent ones show it through).
//!
//! Adaptive, as Fusion 360's sketch grid is: whatever the zoom, about the
//! same density shows. Lines come in levels of the document's unit: in
//! millimetres (and mils) decades, 0.1, 1, 10, 100 mm …; in inches the
//! fractions a ruler has, 1/64, 1/32 … 1/2 in, then the inch and the foot.
//! A level's strength follows how far apart its lines are on screen: none at
//! `fade_lo` pixels or less, full at `fade_hi` or more, between by the
//! logarithm of the spacing. A line takes the strength of the coarsest
//! decade it is on, so the major lines (the coarser decade) are always
//! the stronger ones, and zooming fades decades in and out with no
//! popping. Every line is one device pixel wide; strength is contrast,
//! not weight.
//!
//! Lines (the default), dots at the crossings, or no grid: View › Grid.

const std = @import("std");

/// How grids are drawn; `none` is only read from older settings (whether
/// there is a grid is the document's now).
pub const Mode = enum { lines, dots, pluses, none };

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

/// How a unit is divided: in tenths (millimetres, mils) or as a ruler
/// divides the inch, in halves down to sixty-fourths, and twelve inches to
/// the foot.
pub const Scale = enum {
    decimal,
    imperial,

    /// Level `k`'s spacing in the unit: level 0 is the unit itself.
    pub fn step(sc: Scale, k: i32) f64 {
        return switch (sc) {
            .decimal => std.math.pow(f64, 10, @floatFromInt(k)),
            // Fractions below the inch; above it the foot, then tens of feet.
            .imperial => if (k <= 0)
                std.math.pow(f64, 2, @floatFromInt(@max(k, -imperial_finest)))
            else
                12 * std.math.pow(f64, 10, @floatFromInt(k - 1)),
        };
    }

    /// The finest level there is.
    pub fn finest(sc: Scale) i32 {
        return switch (sc) {
            .decimal => -6,
            .imperial => -imperial_finest,
        };
    }
};

/// 1/64 in: the finest fraction a ruler shows.
const imperial_finest = 6;

/// One level to draw: its spacing in document units, its strength, and how
/// many of its spacings the next coarser level's is (its lines on every
/// `ratio`th are drawn there instead).
pub const Level = struct { step: f64, strength: f32, ratio: i64 = 10 };

/// The levels to draw at `px_per_unit` screen pixels per document unit, as
/// `sc` divides the unit: from the finest with room (`lo`) to the first at
/// full strength (the coarser ones would draw nothing new). At most
/// `out.len`.
pub fn levels(px_per_unit: f64, lo: f64, sc: Scale, out: []Level) []Level {
    if (!(px_per_unit > 0) or !std.math.isFinite(px_per_unit) or out.len == 0) return out[0..0];
    // The finest level whose lines are more than `lo` apart.
    var k: i32 = sc.finest();
    while (sc.step(k) * px_per_unit <= lo and k < 40) k += 1;
    var n: usize = 0;
    while (n < out.len) : (k += 1) {
        const step = sc.step(k);
        const s = strength(step * px_per_unit, lo);
        const ratio: i64 = @intFromFloat(@round(sc.step(k + 1) / step));
        out[n] = .{ .step = step, .strength = s, .ratio = @max(2, ratio) };
        n += 1;
        if (s >= 1) break;
    }
    return out[0..n];
}

/// The levels for a grid of a set spacing (`step` document units): lines
/// at it and, stronger, at ten times it, each as strong as its spacing on
/// screen allows.
pub fn fixed(step: f64, px_per_unit: f64, lo: f64, out: []Level) []Level {
    if (!(step > 0) or !(px_per_unit > 0) or out.len < 2) return out[0..0];
    out[0] = .{ .step = step, .strength = strength(step * px_per_unit, lo), .ratio = 10 };
    out[1] = .{ .step = 10 * step, .strength = strength(10 * step * px_per_unit, lo), .ratio = 10 };
    return out[0..2];
}

/// The minor unit (the finest level that shows, at least faintly) and the
/// major one (the strongest drawn) for nudges and the like.
pub fn units(lv: []const Level) ?struct { minor: f64, major: f64 } {
    if (lv.len == 0) return null;
    var minor = lv[lv.len - 1].step;
    for (lv) |l| if (l.strength >= 0.1) {
        minor = l.step;
        break;
    };
    const major = lv[lv.len - 1].step;
    return .{ .minor = minor, .major = if (major > minor) major else minor * @as(f64, @floatFromInt(lv[lv.len - 1].ratio)) };
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
            // A line on the next level is drawn there, stronger.
            if (k + 1 < lv.len and @mod(i, l.ratio) == 0) continue;
            f(ctx, @as(f64, @floatFromInt(i)) * l.step, l.strength);
        }
    }
}

/// `inches` as a ruler reads it, when it is a whole number of
/// sixty-fourths under a foot: "3/16", "1", "1 1/2"; null otherwise.
pub fn fraction(buf: []u8, inches: f64) ?[]const u8 {
    const n64 = @round(inches * 64);
    if (@abs(n64 - inches * 64) > 1e-6 or @abs(inches) >= 12) return null;
    const neg = n64 < 0;
    const total: i64 = @intFromFloat(@abs(n64));
    const whole = @divTrunc(total, 64);
    var num = @mod(total, 64);
    var den: i64 = 64;
    while (num > 0 and @mod(num, 2) == 0) {
        num = @divExact(num, 2);
        den = @divExact(den, 2);
    }
    const sign: []const u8 = if (neg) "-" else "";
    if (num == 0) return std.fmt.bufPrint(buf, "{s}{d}", .{ sign, whole }) catch null;
    if (whole == 0) return std.fmt.bufPrint(buf, "{s}{d}/{d}", .{ sign, num, den }) catch null;
    return std.fmt.bufPrint(buf, "{s}{d} {d}/{d}", .{ sign, whole, num, den }) catch null;
}

const testing = std.testing;

test "the finest decade with room fades in; the first at full strength ends the list" {
    var buf: [4]Level = undefined;
    // 4 px per mm: 1 mm lines 4 px apart (too close), 10 mm 40 px apart,
    // 100 mm 400 px apart (full).
    const lv = levels(4, fade_lo, .decimal, &buf);
    try testing.expectEqual(2, lv.len);
    try testing.expectApproxEqAbs(10, lv[0].step, 1e-9);
    try testing.expect(lv[0].strength > 0 and lv[0].strength < 1);
    try testing.expectApproxEqAbs(100, lv[1].step, 1e-9);
    try testing.expectEqual(1, lv[1].strength);
    // Zooming in brings the 1 mm decade in, faintly.
    const near = levels(7, fade_lo, .decimal, &buf);
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
    const lv = levels(4, fade_lo, .decimal, &buf);
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

test "inches divide in halves to the inch, then the foot" {
    try testing.expectEqual(0.0625, Scale.imperial.step(-4));
    try testing.expectEqual(1, Scale.imperial.step(0));
    try testing.expectEqual(12, Scale.imperial.step(1));
    // 100 px per inch: 1/16 in is 6.25 px (just shows), the levels halve
    // up to the inch, whose lines are 100 px apart.
    var buf: [8]Level = undefined;
    const lv = levels(100, fade_lo, .imperial, &buf);
    try testing.expectEqual(0.0625, lv[0].step);
    try testing.expectEqual(2, lv[0].ratio);
    var k: usize = 0;
    while (lv[k].step < 1) k += 1;
    try testing.expectEqual(12, lv[k].ratio);
    const u = units(lv).?;
    try testing.expect(u.minor < u.major);
    try testing.expectEqual(lv[lv.len - 1].step, u.major);
}

test "millimetres: minor and major are a decade apart or more" {
    var buf: [4]Level = undefined;
    const u = units(levels(4, fade_lo, .decimal, &buf)).?;
    try testing.expectEqual(10, u.minor);
    try testing.expectEqual(100, u.major);
}

test "inches read as fractions" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("3/16", fraction(&b, 0.1875).?);
    try testing.expectEqualStrings("1", fraction(&b, 1).?);
    try testing.expectEqualStrings("1 1/2", fraction(&b, 1.5).?);
    try testing.expectEqualStrings("-1/64", fraction(&b, -1.0 / 64.0).?);
    try testing.expect(fraction(&b, 0.1) == null);
}
