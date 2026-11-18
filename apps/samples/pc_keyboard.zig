//! A PC keyboard (ANSI, 104 tiles) built through the layout library's
//! actions: the first sample the GUI and CLI open.
//!
//! The library knows only tiles, tracks and slots; everything keyboard-
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

/// Rows top to bottom with the space above each, in u. A 2 u tall key is
/// listed in its first row; the flow closes its stretch of the next.
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

/// The one tile prototype: keycap proportions for a cylindrical profile, an
/// 18.1 mm body and a top surface about 12.7 mm wide, offset toward the back,
/// with two tracks over the same part of its face: `top` for symbols and
/// shifted pairs, `words`, smaller, for words.
/// Keys grow from 1u × 1u to the standard widths, and to 2u tall for the
/// keypad + and Enter. Its art is one 1u keycap, shaded darker toward the
/// front where a cylindrical cap slopes away, stretched to every key.
fn keyPrototype(a: std.mem.Allocator, styles: Styles) !layout.model.TilePrototype {
    const body_inset: layout.model.Sides = .all((pitch - 18.1) / 2.0);
    const face_inset: layout.model.Sides = .{ .left = 2.7, .right = 2.7, .top = 1.6, .bottom = 3.6 };
    const art = layout.art;
    const back_to_front = struct {
        fn f(start: art.Color, end: art.Color) art.Fill {
            return .{ .linear = .{ .from = .{ .x = 0.5, .y = 1 }, .to = .{ .x = 0.5, .y = 0 }, .start = start, .end = end } };
        }
    }.f;
    return .{
        .name = "key",
        // Keys are measured in u: 1 u = 19.05 mm, in any track.
        .unit = pitch,
        .body_inset = body_inset,
        .face_inset = face_inset,
        .art = try art.keycap(a, .{
            .pitch = pitch,
            .body_inset = body_inset,
            .face_inset = face_inset,
            .body = back_to_front(.hex("#e9e7e1"), .hex("#cfccc3")),
            .edge = .hex("#9a978f"),
            .face = back_to_front(.hex("#faf9f6"), .hex("#efede8")),
        }),
        // Symbols and shifted pairs in `top`; words, smaller, in `words`,
        // over the same part of the face. Allocated: built from the
        // styles at run time, a literal array would not outlive this call.
        .tracks = try a.dupe(layout.model.TileTrack, &.{
            .{ .name = "top", .style = styles.main, .place = .{ .inset = .all(0.8) } },
            .{ .name = "words", .style = styles.small, .place = .{ .inset = .all(0.8) } },
        }),
        .widths = &.{ 1, 1.25, 1.5, 1.75, 2, 2.25, 2.75, 6.25 },
        .heights = &.{ 1, 2 },
    };
}

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

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const key = try m.addPrototype(try keyPrototype(scratch.allocator(), styles));
    var markup: std.Io.Writer.Allocating = .init(gpa);
    defer markup.deinit();
    var name_buf: [16]u8 = undefined;
    var n: usize = 0;
    for (rows, 0..) |row, ri| {
        // One flow for the whole keyboard: a hard break ends each row. A
        // row with space before it (the function row's gap) starts a
        // paragraph whose style puts it there.
        if (ri > 0) {
            if (row.gap > 0) {
                var nb: [48]u8 = undefined;
                const name = try std.fmt.bufPrint(&nb, "Row gap {d} u", .{row.gap});
                const ps = try m.addParagraphStyle(.{ .name = name, .space_before = row.gap * pitch });
                try m.insertParagraph(p, r, m.flowItems(p, r).len, ps);
            } else try m.place(p, r, null, .{ .what = .hard_break });
        }
        for (row.entries) |e| {
            n += 1;
            const name = try std.fmt.bufPrint(&name_buf, "K{d}", .{n});
            const t = try m.addTile(.{ .designator = name, .w = e.w, .h = e.h, .prototype = key });
            markup.clearRetainingCapacity();
            const w = &markup.writer;
            // A shifted pair: two lines, the shifted symbol on top.
            switch (e.legend) {
                .one, .words => |s| try escape(w, s),
                .pair => |pr| {
                    try escape(w, pr[0]);
                    try w.writeByte('\n');
                    try escape(w, pr[1]);
                },
            }
            try m.setTrackText(t, if (e.legend == .words) "words" else "top", markup.written());
            try m.place(p, r, null, .{ .gap = e.gap, .what = .{ .tile = t } });
        }
    }
    return p;
}

test "the keyboard solves with no overflow and 104 tiles" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const s = try m.addStyle("main", .{ .cap_height = 2.6 });
    const p = try build(gpa, &m, .{ .main = s, .small = s });
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var placed = try layout.solve(gpa, &m, p, &labels);
    defer placed.deinit();
    try std.testing.expectEqual(104, placed.tiles.len);
    for (placed.issues) |i| try std.testing.expect(i.kind != .row_overflow);
    try std.testing.expectApproxEqAbs(22.5 * pitch, placed.bounds.width(), 1e-9);
    try std.testing.expectApproxEqAbs(6.5 * pitch, placed.bounds.height(), 1e-9);
    // Every key's size is one the key prototype allows.
    for (placed.issues) |i| try std.testing.expect(i.kind != .tile_size);
}

test "a key sized outside the key prototype's rules is flagged, not refused" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const s = try m.addStyle("main", .{ .cap_height = 2.6 });
    const p = try build(gpa, &m, .{ .main = s, .small = s });
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    const tab = m.findTile("K38").?;
    for ([_]struct { w: f64, flagged: bool }{ .{ .w = 1.3, .flagged = true }, .{ .w = 1.25, .flagged = false } }) |c| {
        try m.setTileSize(tab, c.w, 1);
        var placed = try layout.solve(gpa, &m, p, &labels);
        defer placed.deinit();
        var flagged = false;
        for (placed.issues) |i| {
            if (i.kind == .tile_size) {
                try std.testing.expectEqual(tab, i.tile.?);
                flagged = true;
            }
        }
        try std.testing.expectEqual(c.flagged, flagged);
    }
}

test "the keyboard saved and read back lays out and exports exactly the same" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const s = try m.addStyle("main", .{ .cap_height = 2.6 });
    const p = try build(gpa, &m, .{ .main = s, .small = s });
    const bytes = try layout.native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try layout.native.decode(gpa, bytes);
    defer back.deinit();
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var a = try layout.solve(gpa, &m, p, &labels);
    defer a.deinit();
    var labels2: layout.Labels = .init(gpa, &.{});
    defer labels2.deinit();
    var b = try layout.solve(gpa, &back, p, &labels2);
    defer b.deinit();
    try std.testing.expectEqual(a.tiles.len, b.tiles.len);
    for (a.tiles, b.tiles) |x, y| {
        try std.testing.expectEqual(x.pitch_box, y.pitch_box);
        try std.testing.expectEqual(x.body, y.body);
    }
    const svg_a = try layout.output.panelSvg(gpa, &a, &.{}, .{});
    defer gpa.free(svg_a);
    const svg_b = try layout.output.panelSvg(gpa, &b, &.{}, .{});
    defer gpa.free(svg_b);
    try std.testing.expectEqualStrings(svg_a, svg_b);
}
