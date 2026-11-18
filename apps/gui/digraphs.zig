//! Digraphs: two characters typed after the digraph key (Ctrl+K) that
//! stand for a third: `->` for →, `e'` for é, `SH` for ⇧. They work in any
//! place text is typed, the canvas's own text and the toolkit's fields
//! alike, because they act on the typed text before either sees it (the
//! GUI's `digraphEvents`).
//!
//! The built-in table (`digraph_data.zig`, from scripts/digraphs.py) is
//! RFC 1345's mnemonics, as Vim's are, with Graven's own over them (key
//! symbols for keycaps, the diameter sign). The user's config adds pairs
//! or changes them, and an empty value takes a built-in one away:
//!
//!     [digraphs]
//!     "->" = "⟶"
//!     "kb" = "⌨"
//!     "°C" = "℃"       # any two characters, not only ASCII
//!     "DG" = ""        # no longer a digraph
//!
//! A pair not found as typed is tried reversed (`'e` is é too), unless the
//! reversed pair is the user's empty value.
//!
//! Window-free, so it is tested on its own.

const std = @import("std");
const data = @import("digraph_data.zig");

pub const Pair = [2]u21;

/// The longest result a pair may stand for, bytes.
pub const max_out = 32;

pub const User = struct {
    pair: Pair,
    out: [max_out]u8 = undefined,
    len: u8 = 0,

    pub fn text(u: *const User) []const u8 {
        return u.out[0..u.len];
    }
};

pub const Table = struct {
    user: std.ArrayList(User) = .empty,

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        t.user.deinit(gpa);
    }

    /// Sets `pair` to stand for `out` ("" takes the pair away). False when
    /// `out` is too long.
    pub fn put(t: *Table, gpa: std.mem.Allocator, pair: Pair, out: []const u8) !bool {
        if (out.len > max_out) return false;
        var u: User = .{ .pair = pair, .len = @intCast(out.len) };
        @memcpy(u.out[0..out.len], out);
        for (t.user.items) |*e| if (std.mem.eql(u21, &e.pair, &pair)) {
            e.* = u;
            return true;
        };
        try t.user.append(gpa, u);
        return true;
    }

    /// What `pair` stands for exactly as typed: the user's (null when they
    /// took it away), else the built-in one.
    fn exact(t: *const Table, pair: Pair) union(enum) { found: []const u8, removed, absent } {
        for (t.user.items) |*e| if (std.mem.eql(u21, &e.pair, &pair)) {
            return if (e.len == 0) .removed else .{ .found = e.text() };
        };
        if (pair[0] < 0x80 and pair[1] < 0x80) if (builtin(@intCast(pair[0]), @intCast(pair[1]))) |s| return .{ .found = s };
        return .absent;
    }

    /// What `a` then `b` stands for: as typed, else reversed.
    pub fn lookup(t: *const Table, a: u21, b: u21) ?[]const u8 {
        switch (t.exact(.{ a, b })) {
            .found => |s| return s,
            .removed => return null,
            .absent => {},
        }
        return switch (t.exact(.{ b, a })) {
            .found => |s| s,
            else => null,
        };
    }

    /// The pairs that start with `a` (as typed, then those that only work
    /// reversed), into `out`: each one's second character and result, in
    /// the built-in table's order with the user's after.
    pub fn candidates(t: *const Table, a: u21, out: []Candidate) []Candidate {
        var n: usize = 0;
        const add = struct {
            fn f(o: []Candidate, len: *usize, second: u21, s: []const u8) void {
                for (o[0..len.*]) |c| if (c.second == second) return;
                if (len.* < o.len) {
                    o[len.*] = .{ .second = second, .out = s };
                    len.* += 1;
                }
            }
        }.f;
        // As typed first, then reversed; each through `lookup`, so the
        // user's changes and removals hold.
        for (0..2) |pass| {
            for (data.table) |e| {
                const first: u21 = e.pair[pass];
                if (first != a) continue;
                const second: u21 = e.pair[1 - pass];
                if (t.lookup(a, second)) |s| add(out, &n, second, s);
            }
            for (t.user.items) |*e| if (e.pair[pass] == a and e.len > 0) {
                const second = e.pair[1 - pass];
                if (t.lookup(a, second)) |s| add(out, &n, second, s);
            };
        }
        return out[0..n];
    }
};

pub const Candidate = struct { second: u21, out: []const u8 };

/// The built-in table's entry for `a` `b`, by binary search (it is sorted).
fn builtin(a: u8, b: u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = data.table.len;
    const key = [2]u8{ a, b };
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, &data.table[mid].pair, &key)) {
            .eq => return data.table[mid].out,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// How many pairs the built-in table has.
pub const builtin_count = data.table.len;

/// A config key's pair: the part after `digraphs.`, quoted or bare, as
/// two characters. Null when it is not two characters.
pub fn parseKey(part: []const u8) ?Pair {
    var s = part;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    const view = std.unicode.Utf8View.init(s) catch return null;
    var it = view.iterator();
    const a = it.nextCodepoint() orelse return null;
    const b = it.nextCodepoint() orelse return null;
    if (it.nextCodepoint() != null) return null;
    return .{ a, b };
}

/// Typing a digraph: what the digraph key starts, fed the typed characters
/// one at a time.
pub const Entry = struct {
    /// Waiting for the first character, then the second.
    state: enum { off, first, second } = .off,
    first: u21 = 0,

    pub const Fed = union(enum) {
        /// Taken; another is wanted.
        more,
        /// The pair is complete: what it stands for.
        done: []const u8,
        /// The pair stands for nothing.
        none: Pair,
    };

    pub fn start(e: *Entry) void {
        e.* = .{ .state = .first };
    }

    pub fn active(e: *const Entry) bool {
        return e.state != .off;
    }

    pub fn cancel(e: *Entry) void {
        e.* = .{};
    }

    /// Backspace: the first character again, or off when there is none.
    pub fn back(e: *Entry) void {
        e.state = if (e.state == .second) .first else .off;
    }

    pub fn feed(e: *Entry, t: *const Table, cp: u21) Fed {
        switch (e.state) {
            .off => unreachable,
            .first => {
                e.first = cp;
                e.state = .second;
                return .more;
            },
            .second => {
                const a = e.first;
                e.* = .{};
                return if (t.lookup(a, cp)) |s| .{ .done = s } else .{ .none = .{ a, cp } };
            },
        }
    }
};

const testing = std.testing;

test "the built-in table: sorted, RFC 1345's pairs, Graven's over them" {
    for (data.table[1..], data.table[0 .. data.table.len - 1]) |b, a| try testing.expect(std.mem.order(u8, &a.pair, &b.pair) == .lt);
    const t: Table = .{};
    try testing.expectEqualStrings("é", t.lookup('e', '\'').?);
    try testing.expectEqualStrings("é", t.lookup('\'', 'e').?);
    try testing.expectEqualStrings("→", t.lookup('-', '>').?);
    try testing.expectEqualStrings("α", t.lookup('a', '*').?);
    try testing.expectEqualStrings("±", t.lookup('+', '-').?);
    try testing.expectEqualStrings("ß", t.lookup('s', 's').?);
    // Graven's own: key symbols, and <= as less-or-equal.
    try testing.expectEqualStrings("⇧", t.lookup('S', 'H').?);
    try testing.expectEqualStrings("⌫", t.lookup('B', 'S').?);
    try testing.expectEqualStrings("≤", t.lookup('<', '=').?);
    try testing.expectEqualStrings("⌀", t.lookup('D', 'm').?);
    try testing.expectEqual(null, t.lookup('q', 'q'));
}

test "the user's pairs: added, changed, taken away, any characters" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    _ = try t.put(gpa, .{ '-', '>' }, "⟶");
    _ = try t.put(gpa, .{ 0xB0, 'C' }, "℃");
    _ = try t.put(gpa, .{ 'D', 'G' }, "");
    try testing.expectEqualStrings("⟶", t.lookup('-', '>').?);
    try testing.expectEqualStrings("℃", t.lookup(0xB0, 'C').?);
    try testing.expectEqualStrings("℃", t.lookup('C', 0xB0).?);
    // Taken away, as typed and reversed alike.
    try testing.expectEqual(null, t.lookup('D', 'G'));
    try testing.expectEqual(null, t.lookup('G', 'D'));
    try testing.expect(!try t.put(gpa, .{ 'x', 'x' }, &@as([40]u8, @splat('a'))));
}

test "candidates for a first character, the user's changes holding" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    _ = try t.put(gpa, .{ 'e', '*' }, "");
    _ = try t.put(gpa, .{ 'e', 'u' }, "€");
    var buf: [64]Candidate = undefined;
    const cs = t.candidates('e', &buf);
    var acute = false;
    var euro = false;
    for (cs) |c| {
        try testing.expect(c.second != '*');
        if (c.second == '\'') acute = std.mem.eql(u8, c.out, "é");
        if (c.second == 'u') euro = true;
    }
    try testing.expect(acute and euro);
}

test "config keys: two characters, quoted or bare" {
    try testing.expectEqual(Pair{ '-', '>' }, parseKey("\"->\"").?);
    try testing.expectEqual(Pair{ 'k', 'b' }, parseKey("kb").?);
    try testing.expectEqual(Pair{ 0xB0, 'C' }, parseKey("\"°C\"").?);
    try testing.expectEqual(null, parseKey("abc"));
    try testing.expectEqual(null, parseKey("a"));
}

test "typing a digraph: two characters, back, and a pair that is none" {
    const t: Table = .{};
    var e: Entry = .{};
    e.start();
    try testing.expectEqual(Entry.Fed.more, e.feed(&t, 'a'));
    e.back();
    try testing.expectEqual(Entry.Fed.more, e.feed(&t, 'o'));
    try testing.expectEqualStrings("ö", e.feed(&t, ':').done);
    try testing.expect(!e.active());
    e.start();
    _ = e.feed(&t, 'q');
    try testing.expectEqual(Pair{ 'q', 'q' }, e.feed(&t, 'q').none);
}
