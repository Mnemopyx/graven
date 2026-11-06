//! A PC keyboard (ANSI, 104 tiles) built through the layout library's
//! actions: the first sample the GUI and CLI open.
//!
//! The library knows only tiles, rows and slots; everything keyboard-
//! specific (layout, legends, keycap proportions) lives here.

const std = @import("std");
const layout = @import("graven_layout");

const Model = layout.Model;
const StyleId = layout.model.StyleId;

pub const pitch = 19.05;

/// A legend: one line, or a shifted symbol over its base symbol.
const Legend = union(enum) {
    one: []const u8,
    pair: [2][]const u8,
    /// Words, set smaller and wrapped.
    words: []const u8,
};

const Entry = struct {
    legend: Legend,
    w: f64 = 1,
    h: f64 = 1,
    gap: f64 = 0,
};

fn one(s: []const u8) Entry {
    return .{ .legend = .{ .one = s } };
}
fn pair(up: []const u8, down: []const u8) Entry {
    return .{ .legend = .{ .pair = .{ up, down } } };
}
fn words(s: []const u8, w: f64) Entry {
    return .{ .legend = .{ .words = s }, .w = w };
}
fn gapped(e: Entry, gap: f64) Entry {
    var c = e;
    c.gap = gap;
    return c;
}
fn tall(e: Entry) Entry {
    var c = e;
    c.h = 2;
    return c;
}

/// Rows top to bottom with the space above each, in u. A tile spanning
/// two rows is listed in its first row only; `spans` adds it to the next.
const rows = [_]struct { gap: f64, entries: []const Entry }{
    .{ .gap = 0, .entries = &.{
        words("Esc", 1),
        gapped(one("F1"), 1),
        one("F2"),
        one("F3"),
        one("F4"),
        gapped(one("F5"), 0.5),
        one("F6"),
        one("F7"),
        one("F8"),
        gapped(one("F9"), 0.5),
        one("F10"),
        one("F11"),
        one("F12"),
        gapped(words("Print Screen", 1), 0.25),
        words("Scroll Lock", 1),
        words("Pause", 1),
    } },
    .{ .gap = 0.5, .entries = &.{
        pair("~", "`"),
        pair("!", "1"),
        pair("@", "2"),
        pair("#", "3"),
        pair("$", "4"),
        pair("%", "5"),
        pair("^", "6"),
        pair("&", "7"),
        pair("*", "8"),
        pair("(", "9"),
        pair(")", "0"),
        pair("_", "-"),
        pair("+", "="),
        words("Backspace", 2),
        gapped(words("Insert", 1), 0.25),
        words("Home", 1),
        words("Page Up", 1),
        gapped(words("Num Lock", 1), 0.25),
        one("/"),
        one("*"),
        one("-"),
    } },
    .{ .gap = 0, .entries = &.{
        words("Tab", 1.5),
        one("Q"),
        one("W"),
        one("E"),
        one("R"),
        one("T"),
        one("Y"),
        one("U"),
        one("I"),
        one("O"),
        one("P"),
        pair("{", "["),
        pair("}", "]"),
        .{ .legend = .{ .pair = .{ "|", "\\" } }, .w = 1.5 },
        gapped(words("Delete", 1), 0.25),
        words("End", 1),
        words("Page Down", 1),
        gapped(one("7"), 0.25),
        one("8"),
        one("9"),
        tall(one("+")),
    } },
    .{ .gap = 0, .entries = &.{
        words("Caps Lock", 1.75),
        one("A"),
        one("S"),
        one("D"),
        one("F"),
        one("G"),
        one("H"),
        one("J"),
        one("K"),
        one("L"),
        pair(":", ";"),
        pair("\"", "'"),
        words("Enter", 2.25),
        gapped(one("4"), 3.5),
        one("5"),
        one("6"),
    } },
    .{ .gap = 0, .entries = &.{
        words("Shift", 2.25),
        one("Z"),
        one("X"),
        one("C"),
        one("V"),
        one("B"),
        one("N"),
        one("M"),
        pair("<", ","),
        pair(">", "."),
        pair("?", "/"),
        words("Shift", 2.75),
        gapped(one("↑"), 1.25),
        gapped(one("1"), 1.25),
        one("2"),
        one("3"),
        tall(words("Enter", 1)),
    } },
    .{ .gap = 0, .entries = &.{
        words("Ctrl", 1.25),
        words("Super", 1.25),
        words("Alt", 1.25),
        .{ .legend = .{ .one = "" }, .w = 6.25 },
        words("Alt", 1.25),
        words("Super", 1.25),
        words("Menu", 1.25),
        words("Ctrl", 1.25),
        gapped(one("←"), 0.25),
        one("↓"),
        one("→"),
        gapped(.{ .legend = .{ .one = "0" }, .w = 2 }, 0.25),
        one("."),
    } },
};

/// Writes `text` as label markup, escaping what markup treats specially.
pub fn escape(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '{', '}', '_', '^', '&', '%', '#', '$', '~' => try w.print("\\{c}", .{c}),
        '\\' => try w.writeAll("\\textbackslash{}"),
        else => try w.writeByte(c),
    };
}

pub const Styles = struct {
    /// Single symbols and shifted pairs.
    main: StyleId,
    /// Words, set smaller and wrapped.
    small: StyleId,
};

/// Keycap proportions for a cylindrical profile: an 18.1 mm body and a top
/// surface about 12.7 mm wide, offset toward the back.
const body_inset: layout.model.Sides = .all((pitch - 18.1) / 2.0);
const face_inset: layout.model.Sides = .{ .left = 2.7, .right = 2.7, .top = 1.6, .bottom = 3.6 };
const slot_inset: layout.model.Sides = .all(0.8);

/// Adds the keyboard as a new panel; returns its index. Tiles are named K1,
/// K2 … row by row, left to right.
pub fn build(gpa: std.mem.Allocator, m: *Model, styles: Styles) !usize {
    const width = 22.5;
    const height = 6.5;
    const margin = 10.0;
    const p = try m.addPanel("PC keyboard (ANSI 104)", width * pitch + 2 * margin, height * pitch + 2 * margin);
    const r = try m.addRegion(p, .{
        .name = "keys",
        .origin = .{ .x = margin, .y = height * pitch + margin },
        .w = width,
        .h = height,
        .pitch = pitch,
    });

    var markup: std.Io.Writer.Allocating = .init(gpa);
    defer markup.deinit();
    var name_buf: [16]u8 = undefined;
    var n: usize = 0;
    var spanning: ?layout.TileId = null;
    var spanning_row: usize = 0;
    for (rows, 0..) |row, ri| {
        _ = try m.addRow(p, r, row.gap);
        for (row.entries) |e| {
            n += 1;
            const name = try std.fmt.bufPrint(&name_buf, "K{d}", .{n});
            const t = try m.addTile(.{ .designator = name, .w = e.w, .h = e.h, .body_inset = body_inset, .face_inset = face_inset });
            markup.clearRetainingCapacity();
            const w = &markup.writer;
            var style = styles.main;
            switch (e.legend) {
                .one => |s| try escape(w, s),
                .pair => |pr| {
                    try escape(w, pr[0]);
                    try w.writeAll("\\\\");
                    try escape(w, pr[1]);
                },
                .words => |s| {
                    try escape(w, s);
                    style = styles.small;
                },
            }
            try m.addSlot(t, .{ .name = "top", .style = style, .content = markup.written(), .place = .{ .inset = slot_inset } });
            try m.place(p, r, ri, null, .{ .tile = t, .gap = e.gap });
            if (e.h > 1) {
                // Spanning down: it also takes a place at the end of the next row.
                spanning = t;
                spanning_row = ri + 1;
            }
        }
        // A tile spanning from the row above ends the row it crosses.
        if (spanning) |t| if (spanning_row == ri) {
            try m.place(p, r, ri, null, .{ .tile = t });
            spanning = null;
        };
    }
    return p;
}

test "the keyboard solves with no overflow and 104 tiles" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const s = try m.addStyle("main", .{ .upright = 0, .cap_height = 2.6 });
    const p = try build(gpa, &m, .{ .main = s, .small = s });
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var placed = try layout.solve(gpa, &m, p, &labels);
    defer placed.deinit();
    try std.testing.expectEqual(104, placed.tiles.len);
    for (placed.issues) |i| try std.testing.expect(i.kind != .row_overflow);
    try std.testing.expectApproxEqAbs(22.5 * pitch, placed.bounds.width(), 1e-9);
    try std.testing.expectApproxEqAbs(6.5 * pitch, placed.bounds.height(), 1e-9);
}
