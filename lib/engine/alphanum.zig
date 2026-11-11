//! Math alphabets as Unicode encodes them: the Mathematical Alphanumeric
//! Symbols (U+1D400–U+1D7FF), with the letters encoded earlier in
//! Letterlike Symbols (ℝ, ℂ, ℌ, ℬ …) filling the block's holes.
//!
//! When no member of a composed font sets an alphabet (\mathbb, \mathfrak
//! …) from ordinary letters, its letters become these characters, set in
//! whichever face has them.

const std = @import("std");
const Alphabet = @import("markup.zig").Alphabet;

/// The first capital of each lettered alphabet in the block; small letters
/// follow 26 later.
const Base = struct { capital: u21, digit: ?u21 = null };

fn base(alphabet: Alphabet, bold: bool, italic: bool) ?Base {
    return switch (alphabet) {
        .normal => if (bold and italic)
            .{ .capital = 0x1D468 }
        else if (bold)
            .{ .capital = 0x1D400, .digit = 0x1D7CE }
        else if (italic)
            .{ .capital = 0x1D434 }
        else
            null,
        .script, .calligraphic => if (bold) .{ .capital = 0x1D4D0 } else .{ .capital = 0x1D49C },
        .fraktur => if (bold) .{ .capital = 0x1D56C } else .{ .capital = 0x1D504 },
        .double_struck => .{ .capital = 0x1D538, .digit = 0x1D7D8 },
        .sans_serif => if (bold and italic)
            .{ .capital = 0x1D63C }
        else if (bold)
            .{ .capital = 0x1D5D4, .digit = 0x1D7EC }
        else if (italic)
            .{ .capital = 0x1D608 }
        else
            .{ .capital = 0x1D5A0, .digit = 0x1D7E2 },
        .monospace => .{ .capital = 0x1D670, .digit = 0x1D7F6 },
    };
}

/// Holes in the block: letters encoded earlier, at their own codepoints.
fn hole(cp: u21) ?u21 {
    return switch (cp) {
        0x1D455 => 0x210E, // italic h: ℎ
        0x1D49D => 0x212C, // script B: ℬ
        0x1D4A0 => 0x2130, // script E: ℰ
        0x1D4A1 => 0x2131, // script F: ℱ
        0x1D4A3 => 0x210B, // script H: ℋ
        0x1D4A4 => 0x2110, // script I: ℐ
        0x1D4A7 => 0x2112, // script L: ℒ
        0x1D4A8 => 0x2133, // script M: ℳ
        0x1D4AD => 0x211B, // script R: ℛ
        0x1D4BA => 0x212F, // script e: ℯ
        0x1D4BC => 0x210A, // script g: ℊ
        0x1D4C4 => 0x2134, // script o: ℴ
        0x1D506 => 0x212D, // fraktur C: ℭ
        0x1D50B => 0x210C, // fraktur H: ℌ
        0x1D50C => 0x2111, // fraktur I: ℑ
        0x1D515 => 0x211C, // fraktur R: ℜ
        0x1D51D => 0x2128, // fraktur Z: ℨ
        0x1D53A => 0x2102, // double-struck C: ℂ
        0x1D53F => 0x210D, // double-struck H: ℍ
        0x1D545 => 0x2115, // double-struck N: ℕ
        0x1D547 => 0x2119, // double-struck P: ℙ
        0x1D548 => 0x211A, // double-struck Q: ℚ
        0x1D549 => 0x211D, // double-struck R: ℝ
        0x1D551 => 0x2124, // double-struck Z: ℤ
        else => null,
    };
}

/// `cp` in `alphabet` (bold, italic) as Unicode encodes it, or null when
/// it has no such form (punctuation, Greek outside bold and italic, an
/// alphabet without that weight).
pub fn remap(cp: u21, alphabet: Alphabet, bold: bool, italic: bool) ?u21 {
    const b = base(alphabet, bold, italic) orelse return null;
    const mapped: u21 = switch (cp) {
        'A'...'Z' => b.capital + (cp - 'A'),
        'a'...'z' => b.capital + 26 + (cp - 'a'),
        '0'...'9' => (b.digit orelse return null) + (cp - '0'),
        else => return null,
    };
    return hole(mapped) orelse mapped;
}

test "letters map into the block, holes to Letterlike Symbols" {
    const t = std.testing;
    try t.expectEqual(0x1D538, remap('A', .double_struck, false, false));
    try t.expectEqual(0x211D, remap('R', .double_struck, false, false)); // ℝ
    try t.expectEqual(0x1D7DF, remap('7', .double_struck, false, false));
    try t.expectEqual(0x1D56C, remap('A', .fraktur, true, false));
    try t.expectEqual(0x210C, remap('H', .fraktur, false, false)); // ℌ
    try t.expectEqual(0x1D68A, remap('a', .monospace, false, false));
    try t.expectEqual(0x2134, remap('o', .script, false, false)); // ℴ
    try t.expectEqual(0x210E, remap('h', .normal, false, true)); // ℎ
    try t.expectEqual(null, remap('A', .normal, false, false));
    try t.expectEqual(null, remap('+', .fraktur, false, false));
    try t.expectEqual(null, remap('3', .fraktur, false, false));
}
