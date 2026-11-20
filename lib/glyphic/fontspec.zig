//! Face specifications (decided 2026-11-20: font specification is
//! glyphic's): what a style asks for to set a treatment (its text, bold,
//! italic, monospace …) as a family with a weight, a slant and a width, and
//! the matching of that against the faces an application has, as CSS
//! Fonts Level 4 matches: the family first, then the width, the slant and
//! the weight, each with its own order of nearest alternatives. Faces are
//! described by their measured values where the application has them
//! (fontsearch measures weight, width and italic from the font), else by
//! their style names ("SemiBold Condensed Italic").
//!
//! A treatment not matched exactly is made another way where it can be
//! (`Making`): the math font's own alphabet, or synthesized (slanted,
//! grown); what was done is reported, never silent.

const std = @import("std");

/// How upright a face is.
pub const Slant = enum { upright, italic, oblique };

/// What a style asks for.
pub const Spec = struct {
    family: []const u8,
    /// CSS weight, 1 to 1000: 400 regular, 700 bold.
    weight: u16 = 400,
    slant: Slant = .upright,
    /// Width, percent of normal: 75 condensed, 125 expanded.
    width: u16 = 100,
};

/// A face an application has: its family and style names, and what it is.
pub const Described = struct {
    family: []const u8,
    style: []const u8,
    weight: u16 = 400,
    slant: Slant = .upright,
    width: u16 = 100,
};

/// The treatments a style maps to faces.
pub const Treatment = enum {
    text,
    bold,
    italic,
    bold_italic,
    mono,
    math,

    /// The role name a style's faces use for it.
    pub fn role(t: Treatment) []const u8 {
        return @tagName(t);
    }

    pub fn ofRole(name: []const u8) ?Treatment {
        return std.meta.stringToEnum(Treatment, name);
    }

    /// What it asks of the text face's family when a style names nothing
    /// for it: bold 700, italic slanted, both; the rest nothing.
    pub fn derived(t: Treatment, text: Spec) ?Spec {
        var s = text;
        switch (t) {
            .text => return text,
            .bold => s.weight = 700,
            .italic => s.slant = .italic,
            .bold_italic => {
                s.weight = 700;
                s.slant = .italic;
            },
            .mono, .math => return null,
        }
        return s;
    }
};

/// How a treatment is made when its face is not exactly what was asked.
pub const Making = enum {
    /// A face as asked.
    face,
    /// Another face of the family, the nearest (`match`).
    nearest,
    /// The math font's Unicode alphabet (Mathematical Italic, Bold …).
    unicode_math,
    /// Slanted or grown from an upright or lighter face.
    synthesized,
};

// Style names ----------------------------------------------------------------

const weight_words = [_]struct { []const u8, u16 }{
    .{ "thin", 100 },       .{ "hairline", 100 },  .{ "extralight", 200 }, .{ "ultralight", 200 },
    .{ "light", 300 },      .{ "book", 400 },      .{ "regular", 400 },    .{ "normal", 400 },
    .{ "roman", 400 },      .{ "medium", 500 },    .{ "semibold", 600 },   .{ "demibold", 600 },
    .{ "demi", 600 },       .{ "bold", 700 },      .{ "extrabold", 800 },  .{ "ultrabold", 800 },
    .{ "heavy", 900 },      .{ "black", 900 },     .{ "extrablack", 950 }, .{ "ultrablack", 950 },
};

const width_words = [_]struct { []const u8, u16 }{
    .{ "ultracondensed", 50 }, .{ "extracondensed", 62 }, .{ "condensed", 75 },  .{ "semicondensed", 87 },
    .{ "narrow", 75 },         .{ "compressed", 75 },     .{ "semiexpanded", 112 }, .{ "expanded", 125 },
    .{ "extended", 125 },      .{ "wide", 125 },          .{ "extraexpanded", 150 }, .{ "ultraexpanded", 200 },
};

/// A face described from its style name: its words read, run together and
/// lower-cased ("Semi Bold" as "semibold"), longest first.
pub fn describe(family: []const u8, style: []const u8) Described {
    var d: Described = .{ .family = family, .style = style };
    var buf: [96]u8 = undefined;
    var n: usize = 0;
    for (style) |c| {
        if (c == ' ' or c == '-' or c == '_') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    var rest = buf[0..n];
    if (std.mem.indexOf(u8, rest, "italic")) |i| {
        d.slant = .italic;
        rest = cut(rest, i, "italic".len);
    } else if (std.mem.indexOf(u8, rest, "oblique")) |i| {
        d.slant = .oblique;
        rest = cut(rest, i, "oblique".len);
    }
    // Widths before weights ("semicondensed" before "semi").
    var best: usize = 0;
    var wide: ?struct { at: usize, len: usize, w: u16 } = null;
    for (width_words) |w| if (w[0].len > best) if (std.mem.indexOf(u8, rest, w[0])) |i| {
        best = w[0].len;
        wide = .{ .at = i, .len = w[0].len, .w = w[1] };
    };
    if (wide) |h| {
        d.width = h.w;
        rest = cut(rest, h.at, h.len);
    }
    best = 0;
    var hit: ?struct { at: usize, len: usize, w: u16 } = null;
    for (weight_words) |w| if (w[0].len > best) if (std.mem.indexOf(u8, rest, w[0])) |i| {
        best = w[0].len;
        hit = .{ .at = i, .len = w[0].len, .w = w[1] };
    };
    if (hit) |h| d.weight = h.w;
    return d;
}

/// A face described from measured values (fontsearch's: weight and
/// width as OpenType gives them, italic or not); an italic whose name says
/// oblique is oblique.
pub fn measured(family: []const u8, style: []const u8, weight: f32, width: f32, italic: bool) Described {
    const named = describe(family, style);
    return .{
        .family = family,
        .style = style,
        .weight = @intFromFloat(std.math.clamp(@round(weight), 1, 1000)),
        .width = @intFromFloat(std.math.clamp(@round(width), 25, 200)),
        .slant = if (!italic) .upright else if (named.slant == .oblique) .oblique else .italic,
    };
}

/// `s` without `len` bytes at `at` (in place).
fn cut(s: []u8, at: usize, len: usize) []u8 {
    std.mem.copyForwards(u8, s[at..], s[at + len ..]);
    return s[0 .. s.len - len];
}

// Matching -------------------------------------------------------------------

/// The face in `faces` for `want`: one of its family (case aside) with the
/// nearest width, then slant, then weight, as CSS orders the alternatives;
/// `exact` when nothing was given up. Null when no face is of the family.
pub fn match(faces: []const Described, want: Spec) ?struct { index: usize, exact: bool } {
    var best: ?usize = null;
    var best_key: [3]u32 = undefined;
    for (faces, 0..) |f, i| {
        if (!std.ascii.eqlIgnoreCase(f.family, want.family)) continue;
        const key = [3]u32{ widthRank(want.width, f.width), slantRank(want.slant, f.slant), weightRank(want.weight, f.weight) };
        if (best == null or lessKey(key, best_key)) {
            best = i;
            best_key = key;
        }
    }
    const i = best orelse return null;
    const f = faces[i];
    return .{ .index = i, .exact = f.weight == want.weight and f.slant == want.slant and f.width == want.width };
}

/// The face in `faces` for a family and style name, as a document names
/// it: that exact name first, else matched (`match`) as its name reads.
pub fn matchName(faces: []const Described, family: []const u8, style: []const u8) ?struct { index: usize, exact: bool } {
    for (faces, 0..) |f, i| {
        if (std.ascii.eqlIgnoreCase(f.family, family) and std.ascii.eqlIgnoreCase(f.style, style)) return .{ .index = i, .exact = true };
    }
    const d = describe(family, style);
    const m = match(faces, .{ .family = family, .weight = d.weight, .slant = d.slant, .width = d.width }) orelse return null;
    return .{ .index = m.index, .exact = false };
}

fn lessKey(a: [3]u32, b: [3]u32) bool {
    for (a, b) |x, y| if (x != y) return x < y;
    return false;
}

/// CSS: at or below normal width, narrower first, then wider; above it,
/// wider first, then narrower. The rank grows with distance; the other
/// side comes after every face on the preferred side.
fn widthRank(want: u16, got: u16) u32 {
    const w: i32 = want;
    const g: i32 = got;
    if (g == w) return 0;
    const narrower_first = w <= 100;
    const preferred = if (narrower_first) g < w else g > w;
    const d: u32 = @intCast(@abs(g - w));
    return if (preferred) d else 10_000 + d;
}

/// CSS: italic, then oblique, then upright; oblique, then italic, then
/// upright; upright, then oblique, then italic.
fn slantRank(want: Slant, got: Slant) u32 {
    const order: [3]Slant = switch (want) {
        .italic => .{ .italic, .oblique, .upright },
        .oblique => .{ .oblique, .italic, .upright },
        .upright => .{ .upright, .oblique, .italic },
    };
    for (order, 0..) |s, k| if (s == got) return @intCast(k);
    return 3;
}

/// CSS: for 400 to 500, the weights up to 500 above it first, then those
/// below it (nearest first), then those above 500; below 400, lighter
/// first then heavier; above 500, heavier first then lighter.
fn weightRank(want: u16, got: u16) u32 {
    const w: i32 = want;
    const g: i32 = got;
    if (g == w) return 0;
    const d: u32 = @intCast(@abs(g - w));
    if (w >= 400 and w <= 500) {
        if (g > w and g <= 500) return d;
        if (g < w) return 1000 + d;
        return 2000 + d;
    }
    if (w < 400) return if (g < w) d else 1000 + d;
    return if (g > w) d else 1000 + d;
}

// Tests ------------------------------------------------------------------------

const testing = std.testing;

test "style names read as weight, slant and width" {
    const d = describe("Inter", "SemiBold Condensed Italic");
    try testing.expectEqual(@as(u16, 600), d.weight);
    try testing.expectEqual(Slant.italic, d.slant);
    try testing.expectEqual(@as(u16, 75), d.width);
    try testing.expectEqual(@as(u16, 700), describe("X", "Bold").weight);
    try testing.expectEqual(@as(u16, 800), describe("X", "Extra Bold").weight);
    try testing.expectEqual(@as(u16, 400), describe("X", "Regular").weight);
    try testing.expectEqual(@as(u16, 300), describe("X", "Light Oblique").weight);
    try testing.expectEqual(Slant.oblique, describe("X", "Light Oblique").slant);
    try testing.expectEqual(@as(u16, 87), describe("X", "SemiCondensed").width);
    try testing.expectEqual(@as(u16, 600), describe("X", "Demi").weight);
}

test "matching as CSS: family, width, slant, weight" {
    const faces = [_]Described{
        describe("Geist", "Regular"),
        describe("Geist", "Medium"),
        describe("Geist", "SemiBold"),
        describe("Geist", "Bold"),
        describe("Geist", "Black"),
        describe("Geist", "Italic"),
        describe("Geist", "Light"),
        describe("Other", "Bold"),
    };
    // Exact.
    const b = match(&faces, .{ .family = "geist", .weight = 700 }).?;
    try testing.expectEqualStrings("Bold", faces[b.index].style);
    try testing.expect(b.exact);
    // 800 missing: heavier first (Black), not Bold.
    try testing.expectEqualStrings("Black", faces[match(&faces, .{ .family = "Geist", .weight = 800 }).?.index].style);
    // 450: up to 500 first (Medium).
    try testing.expectEqualStrings("Medium", faces[match(&faces, .{ .family = "Geist", .weight = 450 }).?.index].style);
    // 350: lighter first (Light).
    try testing.expectEqualStrings("Light", faces[match(&faces, .{ .family = "Geist", .weight = 350 }).?.index].style);
    // Bold italic: italic wins over weight (the regular Italic), not exact.
    const bi = match(&faces, .{ .family = "Geist", .weight = 700, .slant = .italic }).?;
    try testing.expectEqualStrings("Italic", faces[bi.index].style);
    try testing.expect(!bi.exact);
    // No such family.
    try testing.expect(match(&faces, .{ .family = "None" }) == null);
    // A name as written first, else as it reads.
    try testing.expect(matchName(&faces, "Geist", "SemiBold").?.exact);
    try testing.expectEqualStrings("SemiBold", faces[matchName(&faces, "Geist", "Semi Bold").?.index].style);
}

test "a treatment named nothing asks the text face's family" {
    const text: Spec = .{ .family = "Geist", .weight = 400 };
    const bi = Treatment.bold_italic.derived(text).?;
    try testing.expectEqual(@as(u16, 700), bi.weight);
    try testing.expectEqual(Slant.italic, bi.slant);
    try testing.expect(Treatment.mono.derived(text) == null);
    try testing.expectEqual(Treatment.bold_italic, Treatment.ofRole("bold_italic").?);
}
