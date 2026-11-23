//! Canvas themes: how what is drawn on the canvas is lit. The document is a
//! stack of translucent layers laid on a light table; a theme is the lamp
//! under them and the pigments its emphasis is drawn in. The window's
//! chrome (title bar, rulers, panes) follows the desktop instead, and
//! exports never see any of it.
//!
//! - Light Table: a white lamp; every colour shown as it is.
//! - Black Light Table: a near-UV lamp. Ordinary materials do not
//!   fluoresce, so a colour is shown by how much of the lamp it passes:
//!   its lightness on a ramp from near-black to the lamp's violet (`lit`).
//!   Paper and tile faces glow violet, ink and edges are dark against them.
//!   What is emphasised (selection, cursor, guides, construction, warnings)
//!   is drawn in fluorescent pigments, which glow (`glows`).

const std = @import("std");

pub const Theme = enum {
    light_table,
    black_light_table,

    pub fn label(t: Theme) []const u8 {
        return switch (t) {
            .light_table => "Light Table",
            .black_light_table => "Black Light Table",
        };
    }

    pub fn next(t: Theme) Theme {
        return all[(@as(usize, @intFromEnum(t)) + 1) % all.len];
    }
};

pub const all = [_]Theme{ .light_table, .black_light_table };

pub var current: Theme = .light_table;

/// An sRGB colour with 8-bit channels, as `dvui.Color` is.
fn rgb(r: u8, g: u8, b: u8) struct { r: u8, g: u8, b: u8 } {
    return .{ .r = r, .g = g, .b = b };
}

/// The Black Light Table's ramp: what passes no light, and the lamp itself
/// seen through clear film.
pub const uv_dark = rgb(0x08, 0x05, 0x12);
pub const uv_lamp = rgb(0x52, 0x34, 0xae);

/// The fluorescent pigments (sRGB): highlighter yellow for the selection,
/// green for guides and names, pink for construction, orange for what
/// fails a check.
pub const fluor_select = rgb(0xe6, 0xff, 0x2e);
pub const fluor_guide = rgb(0x3c, 0xff, 0x8c);
pub const fluor_construction = rgb(0xff, 0x52, 0xd6);
pub const fluor_overflow = rgb(0xff, 0x7a, 0x1c);
/// A tile missing a glyph: the warning pigment, faint, over the face.
pub const fluor_missing = rgb(0x6e, 0x2c, 0x2a);

/// Whether emphasis glows (a soft halo round its strokes).
pub fn glows() bool {
    return current == .black_light_table;
}

/// A document colour as the current lamp shows it (alpha kept).
pub fn lit(c: anytype) @TypeOf(c) {
    return switch (current) {
        .light_table => c,
        .black_light_table => uv(c),
    };
}

/// Under near-UV: the colour's lightness (sRGB luma) on the dark-to-lamp
/// ramp, slightly eased so mid greys keep apart.
pub fn uv(c: anytype) @TypeOf(c) {
    const r: f32 = @floatFromInt(c.r);
    const g: f32 = @floatFromInt(c.g);
    const b: f32 = @floatFromInt(c.b);
    const y = std.math.clamp((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255, 0, 1);
    const t = std.math.pow(f32, y, 1.15);
    var out = c;
    out.r = mix(uv_dark.r, uv_lamp.r, t);
    out.g = mix(uv_dark.g, uv_lamp.g, t);
    out.b = mix(uv_dark.b, uv_lamp.b, t);
    return out;
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const v = @as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * t;
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

test "light table leaves colours alone; black light maps by lightness" {
    const C = struct { r: u8, g: u8, b: u8, a: u8 = 255 };
    current = .light_table;
    try std.testing.expectEqual(C{ .r = 1, .g = 2, .b = 3 }, lit(C{ .r = 1, .g = 2, .b = 3 }));
    current = .black_light_table;
    defer current = .light_table;
    const w = lit(C{ .r = 255, .g = 255, .b = 255, .a = 100 });
    try std.testing.expectEqual(C{ .r = uv_lamp.r, .g = uv_lamp.g, .b = uv_lamp.b, .a = 100 }, w);
    const k = lit(C{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expectEqual(C{ .r = uv_dark.r, .g = uv_dark.g, .b = uv_dark.b }, k);
}
