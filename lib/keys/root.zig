//! Keyboards: where a key is, and what it types on the layout in use.
//!
//! A key is named three ways, and this is the one place that resolves them
//! (Travis, 2026-11-24): by the name the layout gives it (`z`, the GUI's
//! business), by its **position** on the keyboard, whatever the layout
//! (`@D01`, the first key of the first letter row), or by the **symbol**
//! printed on it (`'>'`: whichever key types `>`, with Shift if that is
//! what it takes). Key bindings and cases of sorts both ask here.
//!
//! Positions follow ISO/IEC 9995-1's grid, as XKB names keys: rows E
//! (digits), D (first letter row), C (home row), B (bottom row), A (space
//! row); columns from 01 at the left of the row's first letter or digit
//! key, 00 for the key before it (E00 the grave key, B00 the ISO key beside
//! the left Shift). Each position is a USB HID usage, which is what SDL's
//! scancodes are, so the system tells which position a key event came from.
//!
//! A `Layout` is what each position types, with and without Shift: filled
//! from the system by the GUI (and again when the user changes layout);
//! `us` is US English, for tests and where there is no system to ask.

const std = @import("std");

pub const Row = enum(u3) { A, B, C, D, E };

/// A key's place on the keyboard.
pub const Position = struct {
    row: Row,
    col: u8,

    pub fn eql(a: Position, b: Position) bool {
        return a.row == b.row and a.col == b.col;
    }

    /// `D01`, `E00`, `B11` (a row letter and a two-digit column); null for
    /// anything else, or a position not in `grid`.
    pub fn parse(s: []const u8) ?Position {
        if (s.len != 3) return null;
        const row: Row = switch (s[0]) {
            'A' => .A,
            'B' => .B,
            'C' => .C,
            'D' => .D,
            'E' => .E,
            else => return null,
        };
        if (!std.ascii.isDigit(s[1]) or !std.ascii.isDigit(s[2])) return null;
        const p: Position = .{ .row = row, .col = (s[1] - '0') * 10 + (s[2] - '0') };
        return if (index(p) != null) p else null;
    }

    /// As `parse` reads it.
    pub fn name(p: Position) [3]u8 {
        return .{ "ABCDE"[@backingInt(p.row)], '0' + p.col / 10, '0' + p.col % 10 };
    }
};

/// A key of the main block: its position and its USB HID usage (= SDL
/// scancode).
pub const GridKey = struct { pos: Position, hid: u16 };

fn k(comptime s: []const u8, hid: u16) GridKey {
    return .{ .pos = .{ .row = @fromBackingInt(@intCast(s[0] - 'A')), .col = (s[1] - '0') * 10 + (s[2] - '0') }, .hid = hid };
}

/// The main block's keys that type: the positions there are.
pub const grid = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [_]GridKey{
        // Digit row.
        k("E00", 53), k("E01", 30), k("E02", 31), k("E03", 32), k("E04", 33), k("E05", 34),
        k("E06", 35), k("E07", 36), k("E08", 37), k("E09", 38), k("E10", 39), k("E11", 45),
        k("E12", 46),  k("E13", 137), // JIS yen
        // First letter row (QWERTY's Q to ]; D13 is ANSI's backslash).
        k("D01", 20),  k("D02", 26),
        k("D03", 8),   k("D04", 21),
        k("D05", 23),  k("D06", 28),
        k("D07", 24),  k("D08", 12),
        k("D09", 18),  k("D10", 19),
        k("D11", 47),  k("D12", 48),
        k("D13", 49),
        // Home row (C12 is ISO's key left of Enter).
         k("C01", 4),
        k("C02", 22),  k("C03", 7),
        k("C04", 9),   k("C05", 10),
        k("C06", 11),  k("C07", 13),
        k("C08", 14),  k("C09", 15),
        k("C10", 51),  k("C11", 52),
        k("C12", 50),
        // Bottom row (B00 is ISO's key beside the left Shift, B11 JIS's ro).
         k("B00", 100),
        k("B01", 29),  k("B02", 27),
        k("B03", 6),   k("B04", 25),
        k("B05", 5),   k("B06", 17),
        k("B07", 16),  k("B08", 54),
        k("B09", 55),  k("B10", 56),
        k("B11", 135),
        // The space bar.
        k("A03", 44),
    };
};

pub const count = grid.len;

/// `p`'s index in `grid`.
pub fn index(p: Position) ?usize {
    for (grid, 0..) |g, i| if (g.pos.eql(p)) return i;
    return null;
}

/// The position of the key with HID usage (SDL scancode) `hid`.
pub fn atHid(hid: u16) ?Position {
    for (grid) |g| if (g.hid == hid) return g.pos;
    return null;
}

/// What a key types: UTF-8, empty for nothing (or a dead key).
pub const Sym = struct {
    buf: [8]u8 = undefined,
    len: u8 = 0,

    pub fn of(s: []const u8) Sym {
        var out: Sym = .{};
        const n: u8 = @intCast(@min(s.len, out.buf.len));
        @memcpy(out.buf[0..n], s[0..n]);
        out.len = n;
        return out;
    }

    pub fn ofCodepoint(cp: u21) Sym {
        var out: Sym = .{};
        out.len = std.unicode.utf8Encode(cp, &out.buf) catch 0;
        return out;
    }

    pub fn slice(s: *const Sym) []const u8 {
        return s.buf[0..s.len];
    }
};

/// Where a symbol is typed: a position, with Shift or not.
pub const Found = struct { pos: Position, shift: bool };

/// What each key of `grid` types, without and with Shift.
pub const Layout = struct {
    lower: [count]Sym = @splat(.{}),
    upper: [count]Sym = @splat(.{}),

    /// What the key at `p` types (with Shift: `shift`); empty for nothing.
    pub fn typed(l: *const Layout, p: Position, shift: bool) []const u8 {
        const i = index(p) orelse return "";
        return if (shift) l.upper[i].slice() else l.lower[i].slice();
    }

    /// The key that types `sym`: unshifted where one does, else with
    /// Shift; null when no key of the layout types it. A letter typed
    /// with Caps Lock is found as the key's shifted one.
    pub fn find(l: *const Layout, sym: []const u8) ?Found {
        if (sym.len == 0) return null;
        for (grid, 0..) |g, i| if (std.mem.eql(u8, l.lower[i].slice(), sym)) return .{ .pos = g.pos, .shift = false };
        for (grid, 0..) |g, i| if (std.mem.eql(u8, l.upper[i].slice(), sym)) return .{ .pos = g.pos, .shift = true };
        return null;
    }

    /// Sets what the key at `p` types.
    pub fn set(l: *Layout, p: Position, lower: []const u8, upper: []const u8) void {
        const i = index(p) orelse return;
        l.lower[i] = .of(lower);
        l.upper[i] = .of(upper);
    }
};

/// US English (ANSI), the layout for tests and where there is no system
/// to ask.
pub const us: Layout = blk: {
    var l: Layout = .{};
    const rows = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "E00", "`1234567890-=", "~!@#$%^&*()_+" },
        .{ "D01", "qwertyuiop[]\\", "QWERTYUIOP{}|" },
        .{ "C01", "asdfghjkl;'", "ASDFGHJKL:\"" },
        .{ "B01", "zxcvbnm,./", "ZXCVBNM<>?" },
    };
    @setEvalBranchQuota(100_000);
    for (rows) |r| {
        var p = Position.parse(r[0]).?;
        for (r[1], r[2]) |lo, up| {
            l.set(p, &.{lo}, &.{up});
            p.col += 1;
        }
    }
    l.set(.{ .row = .A, .col = 3 }, " ", " ");
    break :blk l;
};

const testing = std.testing;

test "positions parse and print, only those on the grid" {
    const p = Position.parse("D01").?;
    try testing.expectEqual(Row.D, p.row);
    try testing.expectEqual(1, p.col);
    try testing.expectEqualStrings("D01", &p.name());
    try testing.expect(Position.parse("D20") == null);
    try testing.expect(Position.parse("Q01") == null);
    try testing.expect(Position.parse("D1") == null);
    try testing.expectEqual(Position.parse("C01").?, atHid(4).?);
}

test "US layout: what keys type, and which key types a symbol" {
    try testing.expectEqualStrings("q", us.typed(Position.parse("D01").?, false));
    try testing.expectEqualStrings("!", us.typed(Position.parse("E01").?, true));
    const gt = us.find(">").?;
    try testing.expect(gt.pos.eql(Position.parse("B09").?) and gt.shift);
    const dot = us.find(".").?;
    try testing.expect(dot.pos.eql(Position.parse("B09").?) and !dot.shift);
    try testing.expect(us.find("é") == null);
}

test "another layout: German's > is on the ISO key, with Shift" {
    var de = us;
    de.set(Position.parse("B00").?, "<", ">");
    de.set(Position.parse("B09").?, ".", ":");
    const gt = de.find(">").?;
    try testing.expect(gt.pos.eql(Position.parse("B00").?) and gt.shift);
}
