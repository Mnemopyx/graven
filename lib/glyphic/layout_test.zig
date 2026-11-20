//! Layout and setting, checked on the test fonts (H, O, D, A, + and =,
//! cap height 700 units).

const std = @import("std");
const font = @import("graven_font");
const testdata = @import("graven_testdata");
const param = @import("param.zig");
const ex = @import("expr.zig");
const cascade = @import("cascade.zig");
const faces_mod = @import("faces.zig");
const layout = @import("layout.zig");
const setting = @import("setting.zig");
const ground = @import("ground.zig");
const styles = @import("styles.zig");

const testing = std.testing;
const Expr = ex.Expr;
const Id = ex.Id;
const num = param.num;
const of = param.of;

/// The test fonts, and a style context naming them, applied to the
/// expression; `display` a second context setting display style.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    text: *font.Face,
    math: *font.Face,
    e: Expr,
    g: styles.Engine,
    fonts: styles.StyleId = .none,
    display: styles.StyleId = .none,

    fn init() !Fixture {
        var f: Fixture = .{
            .arena = .init(testing.allocator),
            .text = try font.Face.init(testing.allocator, testdata.truetype, 0),
            .math = try font.Face.init(testing.allocator, testdata.cff, 0),
            .e = try Expr.init(testing.allocator),
            .g = .init(testing.allocator),
        };
        f.fonts = try f.g.addStyle("test fonts", .none);
        try f.g.setFace(f.fonts, "text", f.text);
        try f.g.setFace(f.fonts, "math", f.math);
        f.display = try f.g.addStyle("display", f.fonts);
        try f.g.set(f.display, .math_style, of(param.MathStyle.display));
        try f.g.apply(&f.e, f.e.root, f.fonts);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.g.deinit();
        f.e.deinit();
        f.text.deinit();
        f.math.deinit();
        f.arena.deinit();
    }

    fn resolver(f: *Fixture) cascade.Resolver {
        return cascade.Resolver.init(&f.g, &f.e, &.{});
    }

    fn lay(f: *Fixture, r: *const cascade.Resolver, id: Id) !layout.Laid {
        var l: layout.Layout = .{ .a = f.arena.allocator(), .r = r };
        return l.lay(id, 3);
    }

    fn word(f: *Fixture, row: Id, kind: ex.Kind, text: []const u8) !Id {
        const id = try f.e.leaf(kind, text);
        try f.e.append(row, id);
        return id;
    }
};

fn near(want: f64, got: f64) !void {
    try testing.expectApproxEqAbs(want, got, 1e-6);
}

fn glyphs(l: layout.Laid) usize {
    var n: usize = 0;
    for (l.items.items) |it| if (it == .glyph) {
        n += 1;
    };
    return n;
}

test "a run of text: its capitals the cap height, its advance the font's, weight grows its ink" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.word(f.e.root, .word, "HO");
    const r = f.resolver();
    const l = try f.lay(&r, w);
    try testing.expectEqual(@as(usize, 2), glyphs(l));
    // H's top at 3 mm; H (600 units) and O advance at 3/700 mm a unit.
    try near(3, l.ink.y1);
    try near(3, l.height);
    try near(1200.0 * 3.0 / 700.0, l.width);
    // A tenth of a cap more weight (its style's): 0.15 mm all round.
    const heavier = try f.g.addStyle("heavy", f.fonts);
    try f.g.set(heavier, .weight, num(0.1));
    try f.g.apply(&f.e, w, heavier);
    const heavy = try f.lay(&r, w);
    try near(3.15, heavy.ink.y1);
    try near(0.15, heavy.items.items[0].glyph.grow);
}

test "neighbours are spaced by their kinds: a relation thick, an operator medium" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.word(f.e.root, .variable, "H");
    _ = try f.word(f.e.root, .relation, "=");
    _ = try f.word(f.e.root, .variable, "O");
    const r = f.resolver();
    const row = try f.lay(&r, f.e.root);
    const one = try f.lay(&r, a);
    // H, a thick space, =, a thick space, O.
    const eq = try f.lay(&r, f.e.node(f.e.root).items.items[1]);
    const o = try f.lay(&r, f.e.node(f.e.root).items.items[2]);
    try near(one.width + eq.width + o.width + 2 * 0.40 * 3, row.width);
}

test "a stacked fraction: numerator over the rule on the axis, denominator under; slashed sets them inline" {
    var f = try Fixture.init();
    defer f.deinit();
    const fr = try f.e.structure(.fraction, "", "");
    try f.e.append(f.e.root, fr);
    _ = try f.word(f.e.slot(fr, .num), .variable, "H");
    _ = try f.word(f.e.slot(fr, .den), .variable, "O");
    // Display style: the parts at full size.
    try f.g.apply(&f.e, f.e.root, f.display);
    var r = f.resolver();
    var l = try f.lay(&r, fr);
    var rule: ?[4]geom_Point = null;
    for (l.items.items) |it| if (it == .rule) {
        rule = it.rule.corners;
    };
    const c = rule.?;
    const axis = 0.36 * 3; // the test fonts have no MATH table
    try near(axis - 0.09, c[0].y);
    try near(axis + 0.09, c[2].y);
    // H sits clear above the rule, O clear below it.
    const h = l.items.items[0].glyph.m;
    const o = l.items.items[1].glyph.m;
    try testing.expect(h.f >= axis + 0.09 + 0.45 - 1e-9);
    try testing.expect(o.f + 3 <= axis - 0.09 - 0.45 + 1e-9);
    try near(3, l.height - (h.f)); // H's own height above its baseline
    // Slashed: both on the baseline (the slash is missing from the test font).
    try f.e.set(fr, .fraction_form, of(param.FractionForm.slashed));
    r = f.resolver();
    l = try f.lay(&r, fr);
    try near(0, l.items.items[0].glyph.m.f);
    try near(0, l.items.items[1].glyph.m.f);
    // A slashed fraction keeps its parts at its own size, in text style too.
    try f.g.apply(&f.e, f.e.root, f.fonts);
    r = f.resolver();
    try testing.expectEqual(@as(u2, 0), r.context(f.e.node(f.e.slot(fr, .num)).items.items[0]).script_level);
}

const geom_Point = @import("graven_geom").Point;

test "scripts: raised and dropped by their parameters, at script size" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.e.structure(.scripts, "", "");
    try f.e.append(f.e.root, s);
    _ = try f.word(f.e.slot(s, .base), .variable, "H");
    _ = try f.word(try f.e.openSlot(s, .sup), .variable, "O");
    _ = try f.word(try f.e.openSlot(s, .sub), .variable, "D");
    const r = f.resolver();
    const l = try f.lay(&r, s);
    const sup = l.items.items[1].glyph.m;
    const sub = l.items.items[2].glyph.m;
    try near(0.5 * 3, sup.f);
    try near(-0.24 * 3, sub.f);
    // 0.7 the size: its scale 0.7 of the base's.
    try near(0.7, sup.a / l.items.items[0].glyph.m.a);
    // Hidden, the superscript takes no room.
    try f.e.set(s, .show_sup, of(param.SlotShow.hidden));
    const r2 = f.resolver();
    try testing.expectEqual(@as(usize, 2), glyphs(try f.lay(&r2, s)));
}

test "a word turned a quarter about its baseline start takes its turned room" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.word(f.e.root, .word, "HO");
    try f.e.set(w, .rotate, num(90));
    try f.e.set(w, .rotate_pivot, of(param.Pivot.baseline_start));
    const r = f.resolver();
    const l = try f.lay(&r, w);
    const m = l.items.items[0].glyph.m;
    // Turned: x runs up.
    try near(0, m.a);
    try testing.expect(m.b > 0);
    // Its room: as wide as it was tall, as tall as it was long.
    try near(3, l.width);
    try near(1200.0 * 3.0 / 700.0, l.height);
    // Without room, it keeps its unturned advance.
    try f.e.set(w, .rotate_space, of(param.RotateSpace.none));
    const r2 = f.resolver();
    try near(1200.0 * 3.0 / 700.0, (try f.lay(&r2, w)).width);
}

test "set on rows: broken after the relation into a second row, each line on its piece's baseline" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_]struct { k: ex.Kind, t: []const u8 }{
        .{ .k = .variable, .t = "HOD" }, .{ .k = .relation, .t = "=" }, .{ .k = .variable, .t = "AHO" },
    }) |w| _ = try f.word(f.e.root, w.k, w.t);
    const r = f.resolver();
    var rows: ground.Rows = .{ .a = testing.allocator, .origin = .{ .x = 10, .y = 50 }, .length = 12, .pitch = 6, .count = 3, .cap = 3 };
    defer rows.deinit();
    const s = try setting.set(f.arena.allocator(), &r, rows.ground(), .{});
    try testing.expectEqual(@as(usize, 2), s.lines.len);
    try testing.expectEqual(@as(usize, 2), s.lines[0].end); // "HOD =" then "AHO"
    try testing.expect(!s.overflow);
    // The first glyph on the first baseline at the row's start; the second
    // line's on the next.
    try near(10, s.items[0].glyph.m.e);
    try near(50, s.items[0].glyph.m.f);
    var last_y: f64 = 0;
    for (s.items) |it| if (it == .glyph) {
        last_y = it.glyph.m.f;
    };
    try near(44, last_y);
    // Exact outlines out: one per glyph.
    const outs = try setting.outlines(f.arena.allocator(), s.items, 0.01);
    try testing.expectEqual(s.items.len, outs.len);
}

test "set round a dial: each glyph stands on the arc, turned with it" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.word(f.e.root, .word, "HOHOHO");
    const r = f.resolver();
    // An eighth of a circle of radius 20 centred on the top, clockwise:
    // 15.7 mm, the word's length.
    var d: ground.Dial = .{ .centre = .{ .x = 0, .y = 0 }, .radius = 20, .start = std.math.pi * 0.625, .sweep = std.math.pi / 4.0, .pitch = 5, .count = 1, .cap = 3 };
    const s = try setting.set(f.arena.allocator(), &r, d.ground(), .{});
    try testing.expectEqual(@as(usize, 1), s.lines.len);
    // Each glyph's origin on the circle, its baseline along it: the first
    // leaning one way, the last the other.
    const g0 = s.items[0].glyph.m;
    const g5 = s.items[5].glyph.m;
    try near(20, @sqrt(g0.e * g0.e + g0.f * g0.f));
    try near(20, @sqrt(g5.e * g5.e + g5.f * g5.f));
    try testing.expect(g0.b > 0); // rising on the left
    try testing.expect(g5.b < 0); // falling on the right
}

test "a column: a word a character at a time, each upright, centred, a step apart" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.word(f.e.root, .word, "HOD");
    const r = f.resolver();
    var cols: ground.Columns = .{ .origin = .{ .x = 20, .y = 60 }, .length = 40, .pitch = 8, .count = 2, .cap = 3 };
    const s = try setting.set(f.arena.allocator(), &r, cols.ground(), .{});
    try testing.expectEqual(@as(usize, 3), s.items.len);
    for (s.items, 0..) |it, k| {
        const m = it.glyph.m;
        // Upright: no turn.
        try near(3.0 / 700.0, m.a);
        try near(0, m.b);
        // The first baseline 1.25 cap below the top, then 1.5 cap steps.
        try near(60 - 3.75 - @as(f64, @floatFromInt(k)) * 4.5, m.f);
        // Centred on the column: each glyph's middle (by its advance:
        // H and O 600 units, D 700) at x 20.
        const adv = [_]f64{ 600, 600, 700 };
        try near(20 - adv[k] * 3.0 / 700.0 / 2.0, m.e);
    }
    try testing.expect(!s.overflow);
}

test "a column: a structure stays whole and upright; a full column goes on into the next" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.word(f.e.root, .word, "HO HO");
    const fr = try f.e.structure(.fraction, "", "");
    try f.e.append(f.e.root, fr);
    _ = try f.word(f.e.slot(fr, .num), .variable, "H");
    _ = try f.word(f.e.slot(fr, .den), .variable, "O");
    const r = f.resolver();
    // 12 mm columns: room for two characters each.
    var cols: ground.Columns = .{ .origin = .{ .x = 20, .y = 60 }, .length = 10, .pitch = 8, .count = 4, .cap = 3 };
    const s = try setting.set(f.arena.allocator(), &r, cols.ground(), .{});
    // H O (space) H O, then the fraction: its two glyphs and its rule.
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(testing.allocator);
    for (s.items) |it| if (it == .glyph) try xs.append(testing.allocator, it.glyph.m.e);
    try testing.expectEqual(@as(usize, 6), xs.items.len);
    // Columns 8 mm apart: the second H and O in the second, the fraction in the third.
    try testing.expect(xs.items[2] > xs.items[1] + 7);
    try testing.expect(xs.items[4] > xs.items[3] + 7);
    var rules: usize = 0;
    for (s.items) |it| if (it == .rule) {
        rules += 1;
        // Level: its corners at one height pairwise.
        try near(it.rule.corners[0].y, it.rule.corners[1].y);
    };
    try testing.expectEqual(@as(usize, 1), rules);
    try testing.expect(!s.overflow);
}

test "text breaks between words, the space dropped, and at a soft hyphen, drawn" {
    var f = try Fixture.init();
    defer f.deinit();
    var spans: @import("entry.zig").Spans = .{};
    defer spans.deinit(testing.allocator);
    // Three words; rows room for two.
    try @import("latex.zig").parse(&f.e, &spans, "HOD HOD HOD", .legend);
    const r = f.resolver();
    var rows: ground.Rows = .{ .a = testing.allocator, .origin = .{ .x = 0, .y = 50 }, .length = 21, .pitch = 6, .count = 3, .cap = 3 };
    defer rows.deinit();
    const s = try setting.set(f.arena.allocator(), &r, rows.ground(), .{});
    try testing.expectEqual(@as(usize, 2), s.lines.len);
    // The second line starts after the dropped space: at the row's start.
    try testing.expectEqual(@as(usize, 4), s.lines[1].first);
    var first_on_second: ?f64 = null;
    for (s.items) |it| if (it == .glyph and it.glyph.m.f < 50 - 1) {
        if (first_on_second == null) first_on_second = it.glyph.m.e;
    };
    try near(0, first_on_second.?);
    try testing.expect(!s.overflow);
}

test "a soft hyphen breaks a word, the line ending with a hyphen" {
    var f = try Fixture.init();
    defer f.deinit();
    var spans: @import("entry.zig").Spans = .{};
    defer spans.deinit(testing.allocator);
    try @import("latex.zig").parse(&f.e, &spans, "HODA\\-HODA", .legend);
    const r = f.resolver();
    var rows: ground.Rows = .{ .a = testing.allocator, .origin = .{ .x = 0, .y = 50 }, .length = 20, .pitch = 6, .count = 3, .cap = 3 };
    defer rows.deinit();
    const s = try setting.set(f.arena.allocator(), &r, rows.ground(), .{});
    try testing.expectEqual(@as(usize, 2), s.lines.len);
    // The hyphen was asked for (the test fonts have none: reported missing).
    var hyphen = false;
    for (s.missing) |m| if (m.cp == '-') {
        hyphen = true;
    };
    try testing.expect(hyphen);
}

fn boxOf(l: layout.Laid, id: Id) ?layout.ObjectBox {
    for (l.boxes.items) |b| if (b.object == id) return b;
    return null;
}

test "every object has its box: leaves, a structure, its fields; a shift moves the box with the ink" {
    var f = try Fixture.init();
    defer f.deinit();
    const h = try f.word(f.e.root, .variable, "H");
    const fr = try f.e.structure(.fraction, "", "");
    try f.e.append(f.e.root, fr);
    const o = try f.word(f.e.slot(fr, .num), .variable, "O");
    const d = try f.word(f.e.slot(fr, .den), .variable, "D");
    var r = f.resolver();
    var row = try f.lay(&r, f.e.root);
    // The row, H, the fraction, its two fields and their two leaves.
    try testing.expectEqual(@as(usize, 7), row.boxes.items.len);
    const top = boxOf(row, f.e.root).?;
    try testing.expectEqual(@as(u8, 0), top.nest);
    try near(row.width, top.corners[1].x);
    try testing.expectEqual(@as(u8, 1), boxOf(row, h).?.nest);
    try testing.expectEqual(@as(u8, 1), boxOf(row, fr).?.nest);
    try testing.expectEqual(@as(u8, 2), boxOf(row, f.e.slot(fr, .num)).?.nest);
    try testing.expectEqual(@as(u8, 3), boxOf(row, o).?.nest);
    // O's box over D's: the numerator above the denominator.
    try testing.expect(boxOf(row, o).?.baseline[0].y > boxOf(row, d).?.baseline[0].y);
    // H's box: its advance by its height, on the baseline.
    const hb = boxOf(row, h).?;
    const hl = try f.lay(&r, h);
    try near(0, hb.baseline[0].y);
    try near(hl.width, hb.corners[1].x - hb.corners[0].x);
    try near(hl.height, hb.corners[2].y);
    // Raised by a fifth of a cap: the box goes up with the glyph.
    try f.e.set(h, .shift_y, num(0.2));
    r = f.resolver();
    row = try f.lay(&r, f.e.root);
    try near(0.6, boxOf(row, h).?.baseline[0].y);
    try near(hl.height + 0.6, boxOf(row, h).?.corners[2].y);
}

test "space before: further from the object before, what follows moving with it" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.word(f.e.root, .variable, "H");
    const eq = try f.word(f.e.root, .relation, "=");
    const o = try f.word(f.e.root, .variable, "O");
    var r = f.resolver();
    const plain = try f.lay(&r, f.e.root);
    const eq_x = boxOf(plain, eq).?.corners[0].x;
    const o_x = boxOf(plain, o).?.corners[0].x;
    // The relation a tenth of a cap (0.3 mm) further from H: it and O move.
    try f.e.set(eq, .space_before, num(0.1));
    r = f.resolver();
    const nudged = try f.lay(&r, f.e.root);
    try near(eq_x + 0.3, boxOf(nudged, eq).?.corners[0].x);
    try near(o_x + 0.3, boxOf(nudged, o).?.corners[0].x);
    try near(plain.width + 0.3, nudged.width);
    // Closer: negative.
    try f.e.set(eq, .space_before, num(-0.1));
    r = f.resolver();
    try near(eq_x - 0.3, boxOf(try f.lay(&r, f.e.root), eq).?.corners[0].x);
}

test "set: a nudge on a line's first object moves the line, not its breaks; boxes come out on the path" {
    var f = try Fixture.init();
    defer f.deinit();
    const first = try f.word(f.e.root, .variable, "HOD");
    _ = try f.word(f.e.root, .relation, "=");
    _ = try f.word(f.e.root, .variable, "AHO");
    var rows: ground.Rows = .{ .a = testing.allocator, .origin = .{ .x = 10, .y = 50 }, .length = 12, .pitch = 6, .count = 3, .cap = 3 };
    defer rows.deinit();
    var r = f.resolver();
    const plain = try setting.set(f.arena.allocator(), &r, rows.ground(), .{});
    try f.e.set(first, .space_before, num(0.5));
    r = f.resolver();
    const s = try setting.set(f.arena.allocator(), &r, rows.ground(), .{});
    // The same lines, the first 1.5 mm further along.
    try testing.expectEqual(plain.lines.len, s.lines.len);
    try testing.expectEqual(plain.lines[0].end, s.lines[0].end);
    try near(plain.items[0].glyph.m.e + 1.5, s.items[0].glyph.m.e);
    // A box per object (each top object and its own), on the baselines.
    try testing.expectEqual(@as(usize, 3), s.boxes.len);
    try near(50, s.boxes[0].baseline[0].y);
    try near(10 + 1.5, s.boxes[0].baseline[0].x);
    try near(44, s.boxes[2].baseline[0].y);
}
