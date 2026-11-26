//! Grapheme clusters: what a reader takes for one character. A letter and
//! the accents set on it, an emoji and its skin tone or its ZWJ sequence, a
//! flag's two regional indicators, a Hangul syllable written in jamo: each
//! is one cluster, and the caret and Delete step over it whole.
//!
//! Unicode's extended grapheme cluster rules (UAX #29, section 3.1), with
//! character classes taken from HarfBuzz's Unicode data (general
//! categories) and from the ranges below where a class is not a category
//! (Hangul jamo, regional indicators, Extended_Pictographic). Prepend
//! characters (rare Brahmic and Arabic signs) are taken as ordinary.

const std = @import("std");
const hb = @import("hb");

/// A character's grapheme break class.
pub const Class = enum { other, cr, lf, control, extend, zwj, regional, spacing_mark, l, v, t, lv, lvt, pictographic };

pub fn classOf(cp: u21) Class {
    switch (cp) {
        '\r' => return .cr,
        '\n' => return .lf,
        0x200D => return .zwj,
        0x200C => return .extend,
        // Emoji modifiers (skin tones) and tags (subdivision flags).
        0x1F3FB...0x1F3FF, 0xE0020...0xE007F => return .extend,
        0x1F1E6...0x1F1FF => return .regional,
        0x1100...0x115F, 0xA960...0xA97C => return .l,
        0x1160...0x11A7, 0xD7B0...0xD7C6 => return .v,
        0x11A8...0x11FF, 0xD7CB...0xD7FB => return .t,
        0xAC00...0xD7A3 => return if ((cp - 0xAC00) % 28 == 0) .lv else .lvt,
        // Thai and Lao sara am.
        0x0E33, 0x0EB3 => return .spacing_mark,
        else => {},
    }
    if (pictographic(cp)) return .pictographic;
    const gc = hb.hb_unicode_general_category(hb.hb_unicode_funcs_get_default(), cp);
    return switch (gc) {
        hb.HB_UNICODE_GENERAL_CATEGORY_NON_SPACING_MARK, hb.HB_UNICODE_GENERAL_CATEGORY_ENCLOSING_MARK => .extend,
        hb.HB_UNICODE_GENERAL_CATEGORY_SPACING_MARK => .spacing_mark,
        hb.HB_UNICODE_GENERAL_CATEGORY_CONTROL, hb.HB_UNICODE_GENERAL_CATEGORY_FORMAT, hb.HB_UNICODE_GENERAL_CATEGORY_LINE_SEPARATOR, hb.HB_UNICODE_GENERAL_CATEGORY_PARAGRAPH_SEPARATOR => .control,
        else => .other,
    };
}

/// Extended_Pictographic, by its blocks (close to the property's ranges:
/// unassigned code points in them count too, as the property's do).
fn pictographic(cp: u21) bool {
    return switch (cp) {
        0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139, 0x2194...0x2199, 0x21A9, 0x21AA, 0x231A, 0x231B, 0x2328, 0x23CF, 0x23E9...0x23F3, 0x23F8...0x23FA, 0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB...0x25FE => true,
        0x2600...0x27BF, 0x2934, 0x2935, 0x2B05...0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x3030, 0x303D, 0x3297, 0x3299 => true,
        0x1F000...0x1F0FF, 0x1F10D...0x1F10F, 0x1F12F, 0x1F16C...0x1F171, 0x1F17E, 0x1F17F, 0x1F18E, 0x1F191...0x1F19A, 0x1F1AD...0x1F1E5 => true,
        0x1F201...0x1F20F, 0x1F21A, 0x1F22F, 0x1F232...0x1F23A, 0x1F23C...0x1F23F, 0x1F249...0x1F3FA, 0x1F400...0x1F53D, 0x1F546...0x1F64F, 0x1F680...0x1F6FF => true,
        0x1F774...0x1F77F, 0x1F7D5...0x1F7FF, 0x1F80C...0x1F80F, 0x1F848...0x1F84F, 0x1F85A...0x1F85F, 0x1F888...0x1F88F, 0x1F8AE...0x1F8FF, 0x1F90C...0x1F93A, 0x1F93C...0x1F945, 0x1F947...0x1FAFF, 0x1FC00...0x1FFFD => true,
        else => false,
    };
}

/// The state carried along the text: what came before the next character.
const State = struct {
    prev: ?Class = null,
    /// Regional indicators in a row just before (pairs make flags).
    regional: usize = 0,
    /// An Extended_Pictographic character then Extend*, then (`zwj`) a ZWJ.
    pict: bool = false,
    zwj_after_pict: bool = false,

    /// Whether there is a boundary before a character of class `c`; then
    /// takes it in.
    fn step(s: *State, c: Class) bool {
        const brk = s.breaksBefore(c);
        s.zwj_after_pict = c == .zwj and s.pict;
        s.pict = c == .pictographic or (s.pict and c == .extend);
        s.regional = if (c == .regional) (if (brk and s.prev != .regional) 1 else s.regional + 1) else 0;
        s.prev = c;
        return brk;
    }

    fn breaksBefore(s: State, c: Class) bool {
        const p = s.prev orelse return true; // GB1
        if (p == .cr and c == .lf) return false; // GB3
        if (p == .cr or p == .lf or p == .control) return true; // GB4
        if (c == .cr or c == .lf or c == .control) return true; // GB5
        switch (p) { // GB6-8: Hangul syllables
            .l => if (c == .l or c == .v or c == .lv or c == .lvt) return false,
            .lv, .v => if (c == .v or c == .t) return false,
            .lvt, .t => if (c == .t) return false,
            else => {},
        }
        if (c == .extend or c == .zwj) return false; // GB9
        if (c == .spacing_mark) return false; // GB9a
        if (p == .zwj and c == .pictographic and s.zwj_after_pict) return false; // GB11
        if (p == .regional and c == .regional and s.regional % 2 == 1) return false; // GB12-13
        return true; // GB999
    }
};

fn decode(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Where the grapheme cluster that starts at byte `i` of UTF-8 `text`
/// ends: the next boundary after `i`, or `text.len`. `i` should itself be
/// a boundary (the state before it is taken as a fresh start).
pub fn clusterEnd(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    var s: State = .{};
    var at = i;
    while (at < text.len) {
        const d = decode(text, at);
        if (s.step(classOf(d.cp)) and at > i) return at;
        at += d.len;
    }
    return text.len;
}

/// Iterates the grapheme clusters of `text`, start to end.
pub const Iterator = struct {
    text: []const u8,
    i: usize = 0,
    s: State = .{},
    /// The next cluster's bytes, or null at the end.
    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.i >= it.text.len) return null;
        const start = it.i;
        while (it.i < it.text.len) {
            const d = decode(it.text, it.i);
            const c = classOf(d.cp);
            // Looked at, not yet taken: a boundary here ends the cluster.
            var peek = it.s;
            if (peek.step(c) and it.i > start) return it.text[start..it.i];
            it.s = peek;
            it.i += d.len;
        }
        return it.text[start..it.i];
    }
};

/// Whether byte `i` of `text` is a grapheme cluster boundary (0 and
/// `text.len` are).
pub fn isBoundary(text: []const u8, i: usize) bool {
    if (i == 0 or i >= text.len) return true;
    var it: Iterator = .{ .text = text };
    var at: usize = 0;
    while (it.next()) |c| {
        at += c.len;
        if (at == i) return true;
        if (at > i) return false;
    }
    return false;
}

/// The last boundary before byte `i` (0 at the start).
pub fn prevBoundary(text: []const u8, i: usize) usize {
    var it: Iterator = .{ .text = text };
    var at: usize = 0;
    var last: usize = 0;
    while (it.next()) |c| {
        if (at >= i) break;
        last = at;
        at += c.len;
    }
    return last;
}

/// The first boundary after byte `i` (`text.len` at the end).
pub fn nextBoundary(text: []const u8, i: usize) usize {
    var it: Iterator = .{ .text = text };
    var at: usize = 0;
    while (it.next()) |c| {
        at += c.len;
        if (at > i) return at;
    }
    return text.len;
}

/// How many grapheme clusters `text` holds.
pub fn count(text: []const u8) usize {
    var it: Iterator = .{ .text = text };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

const testing = std.testing;

fn expectClusters(text: []const u8, want: []const []const u8) !void {
    var it: Iterator = .{ .text = text };
    for (want) |w| try testing.expectEqualStrings(w, it.next() orelse return error.TooFew);
    try testing.expectEqual(null, it.next());
}

test "an accent and the letter it sits on are one cluster" {
    try expectClusters("e\u{301}t\u{E9}", &.{ "e\u{301}", "t", "\u{E9}" });
    try expectClusters("a\u{301}\u{323}b", &.{ "a\u{301}\u{323}", "b" });
    try testing.expectEqual(3, nextBoundary("e\u{301}x", 0));
    try testing.expectEqual(0, prevBoundary("e\u{301}x", 3));
    try testing.expect(!isBoundary("e\u{301}x", 1));
    try testing.expect(isBoundary("e\u{301}x", 3));
    try testing.expectEqual(3, clusterEnd("e\u{301}x", 0));
}

test "CR LF, controls, Hangul, flags and emoji sequences" {
    try expectClusters("a\r\nb", &.{ "a", "\r\n", "b" });
    try expectClusters("\u{1100}\u{1161}\u{11A8}x", &.{ "\u{1100}\u{1161}\u{11A8}", "x" });
    try expectClusters("\u{AC00}\u{11A8}", &.{"\u{AC00}\u{11A8}"});
    // Two flags (four regional indicators) and a lone one.
    try expectClusters("\u{1F1EC}\u{1F1E7}\u{1F1E9}\u{1F1EA}\u{1F1EB}", &.{ "\u{1F1EC}\u{1F1E7}", "\u{1F1E9}\u{1F1EA}", "\u{1F1EB}" });
    // Skin tone; a family by ZWJ; a ZWJ after a letter does not join.
    try expectClusters("\u{1F44B}\u{1F3FD}!", &.{ "\u{1F44B}\u{1F3FD}", "!" });
    try expectClusters("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", &.{"\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"});
    try expectClusters("a\u{200D}\u{1F469}", &.{ "a\u{200D}", "\u{1F469}" });
    // A variation selector (emoji presentation) is Extend.
    try expectClusters("\u{2764}\u{FE0F}x", &.{ "\u{2764}\u{FE0F}", "x" });
    try testing.expectEqual(4, count("fi\u{E9}e\u{301}"));
}
