//! Names Graven makes up (decided 2026-11-20): identifiers,
//! `[A-Za-z][A-Za-z0-9]*` in ASCII, so a later script can use them bare:
//! Panel1, Track1, K12. They are unique among the objects of one
//! container (a panel's tracks, grids and art; the document's flows …),
//! not across the document; a container's objects share one namespace
//! whatever their kind. Paths join names with "." (Keyboard.Row1).
//!
//! Names a person types are theirs and stay free for now.

const std = @import("std");

/// Whether `s` is an identifier: a letter, then letters and digits.
pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// `text` as an identifier, into `buf`: its letters and digits, a word
/// after a space or other separator starting in capitals ("Rounded
/// rectangle" → RoundedRectangle, "keys" → keys); one starting with a digit
/// gets an N before it; one with no letters or digits is `fallback`.
pub fn identifier(buf: []u8, text: []const u8, fallback: []const u8) []const u8 {
    var n: usize = 0;
    var word_start = false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            word_start = n > 0;
            continue;
        }
        if (n == 0 and std.ascii.isDigit(c)) {
            if (n >= buf.len) break;
            buf[n] = 'N';
            n += 1;
        }
        if (n >= buf.len) break;
        buf[n] = if (word_start) std.ascii.toUpper(c) else c;
        word_start = false;
        n += 1;
    }
    return if (n == 0) fallback else buf[0..n];
}

/// `prefix` followed by the lowest number from 1 that `taken` (on
/// `ctx`) does not hold: Track1, Track2 …
pub fn fresh(buf: []u8, prefix: []const u8, ctx: anytype, comptime taken: fn (@TypeOf(ctx), []const u8) bool) []const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const candidate = std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, n }) catch return prefix;
        if (!taken(ctx, candidate)) return candidate;
    }
}

/// `name` itself when it is free, else as `fresh`.
pub fn freshOrSame(buf: []u8, name: []const u8, ctx: anytype, comptime taken: fn (@TypeOf(ctx), []const u8) bool) []const u8 {
    if (!taken(ctx, name)) {
        if (name.len > buf.len) return name;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    return fresh(buf, name, ctx, taken);
}

const testing = std.testing;

test "identifiers: a letter, then letters and digits" {
    try testing.expect(isIdentifier("Track1"));
    try testing.expect(isIdentifier("K12"));
    try testing.expect(!isIdentifier("Track 1"));
    try testing.expect(!isIdentifier("1st"));
    try testing.expect(!isIdentifier(""));
    try testing.expect(!isIdentifier("A-2"));
}

test "a label made an identifier: words joined, capitals at their starts" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("RoundedRectangle", identifier(&buf, "Rounded rectangle", "X"));
    try testing.expectEqualStrings("keys", identifier(&buf, "keys", "X"));
    try testing.expectEqualStrings("PCKeyboardANSI104", identifier(&buf, "PC keyboard (ANSI 104)", "X"));
    try testing.expectEqualStrings("N3dPanel", identifier(&buf, "3d panel", "X"));
    try testing.expectEqualStrings("X", identifier(&buf, " — ", "X"));
}

test "fresh: the lowest number free" {
    const Taken = struct {
        fn f(names: []const []const u8, name: []const u8) bool {
            for (names) |n| if (std.mem.eql(u8, n, name)) return true;
            return false;
        }
    };
    var buf: [32]u8 = undefined;
    const have: []const []const u8 = &.{ "Track1", "Track3" };
    try testing.expectEqualStrings("Track2", fresh(&buf, "Track", have, Taken.f));
    try testing.expectEqualStrings("Grid", freshOrSame(&buf, "Grid", have, Taken.f));
    try testing.expectEqualStrings("Track31", freshOrSame(&buf, "Track3", have, Taken.f));
}
