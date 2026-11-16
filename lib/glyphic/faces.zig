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
/// parameter `named` (empty: by kind). Null when no member has it.
pub fn choose(fs: FaceSet, named: []const u8, kind: Kind, shape: param.Shape, cp: u21) ?Choice {
    const italic = shape == .italic;
    // Preferred members, in order, then every member as a fallback.
    var order: [8][]const u8 = undefined;
    var n: usize = 0;
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

/// A face's cap height, font units (measured from H; 0.7 em without one).
pub fn capUnits(f: *Face) f64 {
    return (f.capHeight() catch null) orelse 0.7 * @as(f64, @floatFromInt(f.upem));
}
