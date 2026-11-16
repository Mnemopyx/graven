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

const testing = std.testing;
const Expr = ex.Expr;
const Id = ex.Id;
const num = param.num;
const of = param.of;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    text: *font.Face,
    math: *font.Face,
    e: Expr,

    fn init() !Fixture {
        return .{
            .arena = .init(testing.allocator),
            .text = try font.Face.init(testing.allocator, testdata.truetype, 0),
            .math = try font.Face.init(testing.allocator, testdata.cff, 0),
            .e = try Expr.init(testing.allocator),
        };
    }

    fn deinit(f: *Fixture) void {
        f.e.deinit();
        f.text.deinit();
        f.math.deinit();
        f.arena.deinit();
    }

    fn faces(f: *Fixture) faces_mod.FaceSet {
        const ms = f.arena.allocator().alloc(faces_mod.Member, 2) catch unreachable;
        ms[0] = .{ .name = "text", .face = f.text };
        ms[1] = .{ .name = "math", .face = f.math };
        return .{ .members = ms };
    }

    fn lay(f: *Fixture, r: *const cascade.Resolver, id: Id) !layout.Laid {
        var l: layout.Layout = .{ .a = f.arena.allocator(), .r = r, .faces = f.faces() };
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
    const r = cascade.Resolver.init(&f.e, .{});
    const l = try f.lay(&r, w);
    try testing.expectEqual(@as(usize, 2), glyphs(l));
    // H's top at 3 mm; H (600 units) and O advance at 3/700 mm a unit.
    try near(3, l.ink.y1);
    try near(3, l.height);
    try near(1200.0 * 3.0 / 700.0, l.width);
    // A tenth of a cap more weight: 0.15 mm all round.
    try f.e.set(w, .weight, num(0.1));
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
    const r = cascade.Resolver.init(&f.e, .{});
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
    try f.e.legend.append(f.e.gpa, .{ .param = .math_style, .value = of(param.MathStyle.display) });
    var r = cascade.Resolver.init(&f.e, .{});
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
    r = cascade.Resolver.init(&f.e, .{});
    l = try f.lay(&r, fr);
    try near(0, l.items.items[0].glyph.m.f);
    try near(0, l.items.items[1].glyph.m.f);
    // A slashed fraction keeps its parts at its own size, in text style too.
    f.e.legend.clearRetainingCapacity();
    r = cascade.Resolver.init(&f.e, .{});
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
    const r = cascade.Resolver.init(&f.e, .{});
    const l = try f.lay(&r, s);
    const sup = l.items.items[1].glyph.m;
    const sub = l.items.items[2].glyph.m;
    try near(0.5 * 3, sup.f);
    try near(-0.24 * 3, sub.f);
    // 0.7 the size: its scale 0.7 of the base's.
    try near(0.7, sup.a / l.items.items[0].glyph.m.a);
    // Hidden, the superscript takes no room.
    try f.e.set(s, .show_sup, of(param.SlotShow.hidden));
    const r2 = cascade.Resolver.init(&f.e, .{});
    try testing.expectEqual(@as(usize, 2), glyphs(try f.lay(&r2, s)));
}

test "a word turned a quarter about its baseline start takes its turned room" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.word(f.e.root, .word, "HO");
    try f.e.set(w, .rotate, num(90));
    try f.e.set(w, .rotate_pivot, of(param.Pivot.baseline_start));
    const r = cascade.Resolver.init(&f.e, .{});
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
    const r2 = cascade.Resolver.init(&f.e, .{});
    try near(1200.0 * 3.0 / 700.0, (try f.lay(&r2, w)).width);
}

test "set on rows: broken after the relation into a second row, each line on its piece's baseline" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_]struct { k: ex.Kind, t: []const u8 }{
        .{ .k = .variable, .t = "HOD" }, .{ .k = .relation, .t = "=" }, .{ .k = .variable, .t = "AHO" },
    }) |w| _ = try f.word(f.e.root, w.k, w.t);
    const r = cascade.Resolver.init(&f.e, .{});
    var rows: ground.Rows = .{ .a = testing.allocator, .origin = .{ .x = 10, .y = 50 }, .length = 12, .pitch = 6, .count = 3, .cap = 3 };
    defer rows.deinit();
    const s = try setting.set(f.arena.allocator(), &r, f.faces(), rows.ground(), .{});
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
    const r = cascade.Resolver.init(&f.e, .{});
    // An eighth of a circle of radius 20 centred on the top, clockwise:
    // 15.7 mm, the word's length.
    var d: ground.Dial = .{ .centre = .{ .x = 0, .y = 0 }, .radius = 20, .start = std.math.pi * 0.625, .sweep = std.math.pi / 4.0, .pitch = 5, .count = 1, .cap = 3 };
    const s = try setting.set(f.arena.allocator(), &r, f.faces(), d.ground(), .{});
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
