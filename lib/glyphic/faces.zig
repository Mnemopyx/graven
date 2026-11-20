//! Faces: the named faces an expression is set in ("text", "math",
//! "italic", "greek"…), and which one sets each character.
//!
//! An object's `face` parameter names a member; empty, its kind decides:
//! numbers and words from the text face; operators, relations, symbols,
//! large operators and delimiters from the math face; an italic variable
//! from the italic member, else the math face's Mathematical Italic
//! letters, else the text face slanted. A character a face lacks falls
//! back through the other members in order, and is reported when none
//! has it.

const std = @import("std");
const font = @import("graven_font");
const ex = @import("expr.zig");
const param = @import("param.zig");
const fontspec = @import("fontspec.zig");

pub const Face = font.Face;
const Kind = ex.Kind;

pub const Member = struct { name: []const u8, face: *Face };

pub const FaceSet = struct {
    /// In fallback order; the first is the text face.
    members: []const Member,

    pub fn get(fs: FaceSet, name: []const u8) ?*Face {
        for (fs.members) |m| if (std.mem.eql(u8, m.name, name)) return m.face;
        return null;
    }
};

/// Where a character is set from.
pub const Choice = struct {
    face: *Face,
    /// The codepoint used (a math alphabet's, for a mapped letter).
    cp: u21,
    /// Set italic by slanting an upright face.
    slanted: bool = false,
};

/// The Mathematical Italic letter for a Latin letter (U+1D434…; h is
/// U+210E), else the codepoint itself.
pub fn mathItalic(cp: u21) u21 {
    if (cp == 'h') return 0x210E;
    if (cp >= 'A' and cp <= 'Z') return 0x1D434 + (cp - 'A');
    if (cp >= 'a' and cp <= 'z') return 0x1D44E + (cp - 'a');
    return cp;
}

fn mathKind(k: Kind) bool {
    return switch (k) {
        .operator, .relation, .symbol, .constant, .large_op, .fence, .radical, .accent, .ellipsis => true,
        else => false,
    };
}

/// The face that sets `cp` in an object of `kind` and `shape`, its face
/// parameter `named` (empty: by kind). Bold, the "bold" member (with
/// italic, "bold_italic") comes first. Null when no member has it.
pub fn choose(fs: FaceSet, named: []const u8, kind: Kind, shape: param.Shape, cp: u21) ?Choice {
    return chooseBold(fs, named, kind, shape, false, cp);
}

pub fn chooseBold(fs: FaceSet, named: []const u8, kind: Kind, shape: param.Shape, bold: bool, cp: u21) ?Choice {
    const italic = shape == .italic;
    // Preferred members, in order, then every member as a fallback.
    var order: [8][]const u8 = undefined;
    var n: usize = 0;
    if (bold and named.len == 0) {
        if (italic) {
            if (fs.get("bold_italic")) |f| if (f.glyph(cp) != null) return .{ .face = f, .cp = cp };
        }
        if (fs.get("bold")) |f| if (f.glyph(cp) != null) return .{ .face = f, .cp = cp, .slanted = italic };
    }
    if (named.len > 0) {
        order[n] = named;
        n += 1;
    } else if (italic) {
        for ([_][]const u8{ "italic", "math", "text" }) |s| {
            order[n] = s;
            n += 1;
        }
    } else if (mathKind(kind)) {
        for ([_][]const u8{ "math", "text" }) |s| {
            order[n] = s;
            n += 1;
        }
    } else {
        for ([_][]const u8{ "text", "math" }) |s| {
            order[n] = s;
            n += 1;
        }
    }
    for (order[0..n]) |name| {
        const f = fs.get(name) orelse continue;
        if (try1(f, name, italic, cp)) |c| return c;
    }
    for (fs.members) |m| if (try1(m.face, m.name, italic, cp)) |c| return c;
    return null;
}

fn try1(f: *Face, name: []const u8, italic: bool, cp: u21) ?Choice {
    const is_italic_face = std.mem.eql(u8, name, "italic");
    const is_math = std.mem.eql(u8, name, "math");
    if (italic and is_math) {
        const m = mathItalic(cp);
        if (m != cp and f.glyph(m) != null) return .{ .face = f, .cp = m };
    }
    if (f.glyph(cp) == null) return null;
    return .{ .face = f, .cp = cp, .slanted = italic and !is_italic_face };
}

/// How a treatment of a style is set, from its faces: the face, and how
/// it is made (see `fontspec.Making`; `fallback`: in another treatment's
/// face, as it is, which the render reports).
pub const Resolution = struct {
    face: ?*Face,
    making: Making,

    pub const Making = enum { face, unicode_math, synthesized, fallback, none };
};

/// Treatment `t` of face set `fs`, as `choose` sets it (a face the
/// application found only as the nearest of its family is still `face`
/// here: the application knows that, see `layout.fonts`).
pub fn resolution(fs: FaceSet, t: fontspec.Treatment) Resolution {
    const text = fs.get("text") orelse (if (fs.members.len > 0) fs.members[0].face else null);
    return switch (t) {
        .text => .{ .face = text, .making = if (text != null) .face else .none },
        .math => if (fs.get("math")) |f| .{ .face = f, .making = .face } else .{ .face = text, .making = .fallback },
        .mono => if (fs.get("mono")) |f| .{ .face = f, .making = .face } else .{ .face = text, .making = .fallback },
        .bold => if (fs.get("bold")) |f| .{ .face = f, .making = .face } else .{ .face = text, .making = .fallback },
        .italic => if (fs.get("italic")) |f| .{ .face = f, .making = .face } else if (fs.get("math")) |m| (if (m.glyph(mathItalic('a')) != null) .{ .face = m, .making = .unicode_math } else .{ .face = text, .making = .synthesized }) else .{ .face = text, .making = .synthesized },
        .bold_italic => if (fs.get("bold_italic")) |f| .{ .face = f, .making = .face } else if (fs.get("bold")) |f| .{ .face = f, .making = .synthesized } else .{ .face = text, .making = .fallback },
    };
}

/// A face's cap height, font units (measured from H; 0.7 em without one).
pub fn capUnits(f: *Face) f64 {
    return (f.capHeight() catch null) orelse 0.7 * @as(f64, @floatFromInt(f.upem));
}

test "each treatment's face and how it is made" {
    const testdata = @import("graven_testdata");
    const text = try Face.init(std.testing.allocator, testdata.truetype, 0);
    defer text.deinit();
    const math = try Face.init(std.testing.allocator, testdata.cff, 0);
    defer math.deinit();
    const fs: FaceSet = .{ .members = &.{ .{ .name = "text", .face = text }, .{ .name = "bold", .face = math } } };
    try std.testing.expectEqual(Resolution.Making.face, resolution(fs, .text).making);
    try std.testing.expectEqual(math, resolution(fs, .bold).face.?);
    // No italic face, no math face: the text face slanted.
    try std.testing.expectEqual(Resolution.Making.synthesized, resolution(fs, .italic).making);
    // Bold italic from the bold face slanted; no monospace: the text face.
    try std.testing.expectEqual(Resolution.Making.synthesized, resolution(fs, .bold_italic).making);
    try std.testing.expectEqual(math, resolution(fs, .bold_italic).face.?);
    try std.testing.expectEqual(Resolution.Making.fallback, resolution(fs, .mono).making);
}
