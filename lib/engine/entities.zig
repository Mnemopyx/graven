//! The entity table: every named character the markup knows, in one place,
//! so each look-alike codepoint choice is made once.
//!
//! TeX-style names (\alpha, \to) and domain names (\ohm, \micro) resolve
//! here. Raw codepoints (\u{3B1}) bypass the table. Nothing is normalized:
//! the codepoint chosen here is the one stored and rendered.

const std = @import("std");

pub const Class = enum {
    letter,
    symbol,
    /// A unit sign, which font rules may treat specially.
    unit,
};

pub const Entity = struct {
    cp: u21,
    class: Class,
};

fn e(cp: u21, class: Class) Entity {
    return .{ .cp = cp, .class = class };
}

pub const table = std.StaticStringMap(Entity).initComptime(.{
    // Greek, lower case. As in TeX, \epsilon and \phi are the lunate and
    // closed forms; \varepsilon and \varphi the open forms.
    .{ "alpha", e(0x03B1, .letter) },          .{ "beta", e(0x03B2, .letter) },
    .{ "gamma", e(0x03B3, .letter) },          .{ "delta", e(0x03B4, .letter) },
    .{ "epsilon", e(0x03F5, .letter) },        .{ "varepsilon", e(0x03B5, .letter) },
    .{ "zeta", e(0x03B6, .letter) },           .{ "eta", e(0x03B7, .letter) },
    .{ "theta", e(0x03B8, .letter) },          .{ "vartheta", e(0x03D1, .letter) },
    .{ "iota", e(0x03B9, .letter) },           .{ "kappa", e(0x03BA, .letter) },
    .{ "lambda", e(0x03BB, .letter) },         .{ "mu", e(0x03BC, .letter) },
    .{ "nu", e(0x03BD, .letter) },             .{ "xi", e(0x03BE, .letter) },
    .{ "omicron", e(0x03BF, .letter) },        .{ "pi", e(0x03C0, .letter) },
    .{ "varpi", e(0x03D6, .letter) },          .{ "rho", e(0x03C1, .letter) },
    .{ "varrho", e(0x03F1, .letter) },         .{ "sigma", e(0x03C3, .letter) },
    .{ "varsigma", e(0x03C2, .letter) },       .{ "tau", e(0x03C4, .letter) },
    .{ "upsilon", e(0x03C5, .letter) },        .{ "phi", e(0x03D5, .letter) },
    .{ "varphi", e(0x03C6, .letter) },         .{ "chi", e(0x03C7, .letter) },
    .{ "psi", e(0x03C8, .letter) },            .{ "omega", e(0x03C9, .letter) },
    // Greek, upper case.
    .{ "Gamma", e(0x0393, .letter) },          .{ "Delta", e(0x0394, .letter) },
    .{ "Theta", e(0x0398, .letter) },          .{ "Lambda", e(0x039B, .letter) },
    .{ "Xi", e(0x039E, .letter) },             .{ "Pi", e(0x03A0, .letter) },
    .{ "Sigma", e(0x03A3, .letter) },          .{ "Upsilon", e(0x03A5, .letter) },
    .{ "Phi", e(0x03A6, .letter) },            .{ "Psi", e(0x03A8, .letter) },
    .{ "Omega", e(0x03A9, .letter) },
    // Arrows.
             .{ "to", e(0x2192, .symbol) },
    .{ "rightarrow", e(0x2192, .symbol) },     .{ "leftarrow", e(0x2190, .symbol) },
    .{ "gets", e(0x2190, .symbol) },           .{ "leftrightarrow", e(0x2194, .symbol) },
    .{ "uparrow", e(0x2191, .symbol) },        .{ "downarrow", e(0x2193, .symbol) },
    .{ "Rightarrow", e(0x21D2, .symbol) },     .{ "Leftarrow", e(0x21D0, .symbol) },
    .{ "Leftrightarrow", e(0x21D4, .symbol) }, .{ "mapsto", e(0x21A6, .symbol) },
    // Operators and relations.
    .{ "times", e(0x00D7, .symbol) },          .{ "div", e(0x00F7, .symbol) },
    .{ "pm", e(0x00B1, .symbol) },             .{ "mp", e(0x2213, .symbol) },
    .{ "cdot", e(0x22C5, .symbol) },           .{ "ast", e(0x2217, .symbol) },
    .{ "circ", e(0x2218, .symbol) },           .{ "le", e(0x2264, .symbol) },
    .{ "leq", e(0x2264, .symbol) },            .{ "ge", e(0x2265, .symbol) },
    .{ "geq", e(0x2265, .symbol) },            .{ "ne", e(0x2260, .symbol) },
    .{ "neq", e(0x2260, .symbol) },            .{ "approx", e(0x2248, .symbol) },
    .{ "equiv", e(0x2261, .symbol) },          .{ "sim", e(0x223C, .symbol) },
    .{ "propto", e(0x221D, .symbol) },         .{ "minus", e(0x2212, .symbol) },
    // Large operators and other symbols.
    .{ "sum", e(0x2211, .symbol) },            .{ "prod", e(0x220F, .symbol) },
    .{ "int", e(0x222B, .symbol) },            .{ "increment", e(0x2206, .symbol) },
    .{ "infty", e(0x221E, .symbol) },          .{ "partial", e(0x2202, .symbol) },
    .{ "nabla", e(0x2207, .symbol) },          .{ "prime", e(0x2032, .symbol) },
    .{ "surd", e(0x221A, .symbol) },           .{ "angle", e(0x2220, .symbol) },
    .{ "ell", e(0x2113, .letter) },            .{ "hbar", e(0x210F, .letter) },
    .{ "emptyset", e(0x2205, .symbol) },       .{ "langle", e(0x27E8, .symbol) },
    .{ "rangle", e(0x27E9, .symbol) },         .{ "ldots", e(0x2026, .symbol) },
    .{ "cdots", e(0x22EF, .symbol) },          .{ "textbackslash", e(0x005C, .symbol) },
    // Domain names: units, each one deliberately chosen codepoint.
    // \ohm is Greek capital omega (U+03A9), not OHM SIGN (U+2126), which
    // NFC turns into U+03A9 anyway. \micro is Greek small mu (U+03BC),
    // Unicode's recommended form, not MICRO SIGN (U+00B5). \angstrom is
    // U+00C5, not ANGSTROM SIGN (U+212B), which NFC folds to it.
    .{ "ohm", e(0x03A9, .unit) },              .{ "micro", e(0x03BC, .unit) },
    .{ "degree", e(0x00B0, .unit) },           .{ "angstrom", e(0x00C5, .unit) },
});

/// The entities a parse uses: the built-in table, with configured names
/// taking precedence. Configuration can remap a built-in name (\\micro to
/// U+00B5) or add new ones; the parser does not change.
pub const Table = struct {
    overrides: std.StringHashMapUnmanaged(Entity) = .empty,

    /// The built-in table alone.
    pub const builtin: Table = .{};

    pub fn get(t: *const Table, name: []const u8) ?Entity {
        if (t.overrides.get(name)) |ent| return ent;
        return table.get(name);
    }

    /// Adds or remaps `name`; the name is copied.
    pub fn set(t: *Table, gpa: std.mem.Allocator, name: []const u8, ent: Entity) !void {
        const gop = try t.overrides.getOrPut(gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, name) catch |err| {
                t.overrides.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = ent;
    }

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        var it = t.overrides.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        t.overrides.deinit(gpa);
    }
};

/// The named characters written by escaping them: \{ \} \_ \^ \& \% \# \$ \~
pub fn escaped(c: u8) ?u21 {
    return switch (c) {
        '{', '}', '_', '^', '&', '%', '#', '$', '~' => c,
        else => null,
    };
}

test "look-alike choices are made once" {
    try std.testing.expectEqual(@as(u21, 0x03A9), table.get("ohm").?.cp);
    try std.testing.expectEqual(@as(u21, 0x03A9), table.get("Omega").?.cp);
    try std.testing.expectEqual(Class.unit, table.get("ohm").?.class);
    try std.testing.expectEqual(@as(u21, 0x03BC), table.get("micro").?.cp);
    try std.testing.expect(table.get("sqrt") == null);
}

test "configuration remaps a built-in name and adds new ones" {
    var t: Table = .{};
    defer t.deinit(std.testing.allocator);
    try t.set(std.testing.allocator, "micro", .{ .cp = 0x00B5, .class = .unit });
    try t.set(std.testing.allocator, "mho", .{ .cp = 0x2127, .class = .unit });
    try std.testing.expectEqual(@as(u21, 0x00B5), t.get("micro").?.cp);
    try std.testing.expectEqual(@as(u21, 0x2127), t.get("mho").?.cp);
    try std.testing.expectEqual(@as(u21, 0x03A9), t.get("ohm").?.cp);
    try std.testing.expectEqual(@as(u21, 0x03BC), Table.builtin.get("micro").?.cp);
}
