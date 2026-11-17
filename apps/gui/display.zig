//! Display correction: Graven's own answer to a screen that shows its
//! colours too bright and washed out, for desktops that do no colour
//! management of their own (COSMIC, for one) now that SDL3 no longer sets
//! a window's gamma ramp.
//!
//! Two settings, per channel on the sRGB-encoded value `v` (0 to 1):
//!
//!   v' = white · v^gamma
//!
//! `gamma` above 1 darkens the midtones and deepens colour while black and
//! white stay put; `white` below 1 lowers the brightest the interface gets
//! (paper, panes, highlights). Both at 1: no change.
//!
//! The correction is applied to colours, not to the finished frame (DVUI's
//! frame loop has no pass after the frame is drawn): the interface theme,
//! Graven's palette, the panes' derived themes and the document's fills
//! all go through `fix`. Images placed in a document keep their pixels;
//! `white` still dims them (a colour modulation), `gamma` does not reach
//! them. Exports never see any of it.
//!
//! Kept per machine (`display.gamma`, `display.white` in the local config,
//! since it belongs to the screen, not to the user's way of working);
//! `GRAVEN_DISPLAY=gamma,white` overrides it for a run.

const std = @import("std");

pub const gamma_min: f32 = 0.6;
pub const gamma_max: f32 = 2.4;
pub const white_min: f32 = 0.5;
pub const white_max: f32 = 1;

pub const Correction = struct {
    gamma: f32 = 1,
    white: f32 = 1,

    pub fn isIdentity(c: Correction) bool {
        return c.gamma == 1 and c.white == 1;
    }

    pub fn clamped(c: Correction) Correction {
        return .{
            .gamma = std.math.clamp(if (std.math.isFinite(c.gamma)) c.gamma else 1, gamma_min, gamma_max),
            .white = std.math.clamp(if (std.math.isFinite(c.white)) c.white else 1, white_min, white_max),
        };
    }

    /// "1.4,0.9", "1.4" (white 1), or null when it does not parse.
    pub fn parse(s: []const u8) ?Correction {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " "), ',');
        const g = std.fmt.parseFloat(f32, std.mem.trim(u8, it.next() orelse return null, " ")) catch return null;
        const w = if (it.next()) |t| std.fmt.parseFloat(f32, std.mem.trim(u8, t, " ")) catch return null else 1;
        return (Correction{ .gamma = g, .white = w }).clamped();
    }
};

var current: Correction = .{};
/// The correction as a table, one entry per 8-bit channel value.
var table: [256]u8 = identity();

fn identity() [256]u8 {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, i| e.* = @intCast(i);
    return t;
}

fn tableOf(c: Correction) [256]u8 {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, i| {
        const v = @as(f32, @floatFromInt(i)) / 255;
        const out = c.white * std.math.pow(f32, v, c.gamma);
        e.* = @intFromFloat(@round(std.math.clamp(out, 0, 1) * 255));
    }
    return t;
}

pub fn set(c: Correction) void {
    current = c.clamped();
    table = tableOf(current);
}

pub fn get() Correction {
    return current;
}

/// One 8-bit channel value, corrected.
pub fn channel(v: u8) u8 {
    return table[v];
}

/// A colour (anything with `r`, `g`, `b` bytes) corrected; alpha and any
/// other field as they were.
pub fn fix(c: anytype) @TypeOf(c) {
    var out = c;
    out.r = table[c.r];
    out.g = table[c.g];
    out.b = table[c.b];
    return out;
}

/// An optional colour corrected.
pub fn fixOpt(c: anytype) @TypeOf(c) {
    return if (c) |v| fix(v) else null;
}

/// Every colour field of struct `s` (colours and optional colours, at any
/// depth of plain structs) corrected in place. `Color` is the colour type.
pub fn fixAll(comptime Color: type, s: anytype) void {
    const T = @typeInfo(@TypeOf(s)).pointer.child;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, ty| {
        if (ty == Color) {
            @field(s, name) = fix(@field(s, name));
        } else if (ty == ?Color) {
            @field(s, name) = fixOpt(@field(s, name));
        } else if (@typeInfo(ty) == .@"struct" and comptime hasColor(Color, ty)) {
            fixAll(Color, &@field(s, name));
        }
    }
}

fn hasColor(comptime Color: type, comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".field_types) |ty| {
        if (ty == Color or ty == ?Color) return true;
    }
    return false;
}

// Physical size ------------------------------------------------------------
//
// How many device pixels make a millimetre on this screen, so that "actual
// size" shows a design at the size it will be made. Desktops report no
// trustworthy figure (X11 and Wayland often say 96 dpi whatever the
// screen), so the user measures it: an outline of a bank card (ID-1,
// ISO/IEC 7810: 85.60 x 53.98 mm, corners of 3.18 mm radius) is dragged
// until it covers a real card held against the screen. Until then, an
// estimate: 96 dpi times the desktop's scale.

pub const card_w_mm: f32 = 85.60;
pub const card_h_mm: f32 = 53.98;
pub const card_radius_mm: f32 = 3.18;

/// Plausible bounds, device pixels per mm (about 50 to 1270 dpi).
pub const px_per_mm_min: f32 = 2;
pub const px_per_mm_max: f32 = 50;

/// The measured scale, device pixels per mm; null until measured.
var measured: ?f32 = null;

pub fn setPxPerMm(v: ?f32) void {
    // 0 (or less) in the config: not measured.
    measured = if (v) |x| (if (std.math.isFinite(x) and x > 0) std.math.clamp(x, px_per_mm_min, px_per_mm_max) else null) else null;
}

pub fn measuredPxPerMm() ?f32 {
    return measured;
}

/// 96 dpi at `scale` device pixels per logical pixel.
pub fn estimatePxPerMm(scale: f32) f32 {
    return 96.0 / 25.4 * scale;
}

/// Device pixels per mm: measured, else the estimate.
pub fn pxPerMm(scale: f32) f32 {
    return measured orelse estimatePxPerMm(scale);
}

/// The scale a card outline `width_px` device pixels wide measures.
pub fn fromCardWidth(width_px: f32) f32 {
    return std.math.clamp(width_px / card_w_mm, px_per_mm_min, px_per_mm_max);
}

pub fn dpi(px_per_mm: f32) f32 {
    return px_per_mm * 25.4;
}

const testing = std.testing;

test "card width to scale, and the estimate" {
    // A card 323.5 px wide: 3.78 px/mm, 96 dpi.
    try testing.expectApproxEqAbs(96, dpi(fromCardWidth(85.6 * 96 / 25.4)), 1e-3);
    try testing.expectApproxEqAbs(192, dpi(estimatePxPerMm(2)), 1e-3);
    setPxPerMm(null);
    try testing.expectApproxEqAbs(estimatePxPerMm(1), pxPerMm(1), 1e-6);
    setPxPerMm(4.2);
    defer setPxPerMm(null);
    try testing.expectEqual(4.2, pxPerMm(1));
    setPxPerMm(1000);
    try testing.expectEqual(px_per_mm_max, measuredPxPerMm().?);
}

const Rgb = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

test "identity by default; black and white stay put under gamma" {
    set(.{});
    try testing.expectEqual(Rgb{ .r = 10, .g = 128, .b = 250 }, fix(Rgb{ .r = 10, .g = 128, .b = 250 }));
    set(.{ .gamma = 1.6 });
    defer set(.{});
    try testing.expectEqual(0, channel(0));
    try testing.expectEqual(255, channel(255));
    // Midtones darken, monotonically.
    try testing.expect(channel(128) < 128);
    var prev: u8 = 0;
    for (0..256) |i| {
        const v = channel(@intCast(i));
        try testing.expect(v >= prev);
        prev = v;
    }
}

test "white lowers the brightest; alpha is kept" {
    set(.{ .white = 0.8 });
    defer set(.{});
    const c = fix(Rgb{ .r = 255, .g = 255, .b = 255, .a = 40 });
    try testing.expectEqual(204, c.r);
    try testing.expectEqual(40, c.a);
}

test "parse and clamp" {
    const c = Correction.parse("1.4, 0.9").?;
    try testing.expectApproxEqAbs(1.4, c.gamma, 1e-6);
    try testing.expectApproxEqAbs(0.9, c.white, 1e-6);
    try testing.expectEqual(1, Correction.parse("1.2").?.white);
    try testing.expectEqual(gamma_max, Correction.parse("9").?.gamma);
    try testing.expect(Correction.parse("x") == null);
}

test "fixAll reaches nested and optional colours" {
    set(.{ .white = 0.5 });
    defer set(.{});
    const S = struct { a: Rgb, b: ?Rgb, c: ?Rgb = null, inner: struct { d: ?Rgb }, n: f32 = 3 };
    var s: S = .{ .a = .{ .r = 255, .g = 0, .b = 0 }, .b = .{ .r = 0, .g = 255, .b = 0 }, .inner = .{ .d = .{ .r = 0, .g = 0, .b = 255 } } };
    fixAll(Rgb, &s);
    try testing.expectEqual(128, s.a.r);
    try testing.expectEqual(128, s.b.?.g);
    try testing.expectEqual(128, s.inner.d.?.b);
    try testing.expect(s.c == null);
}
