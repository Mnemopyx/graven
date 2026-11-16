//! The entry syntaxes: both against the Leibniz series built by hand,
//! round trips, partial input, spans, legends and identity.

const std = @import("std");
const param = @import("param.zig");
const ex = @import("expr.zig");
const entry = @import("entry.zig");
const latex = @import("latex.zig");
const typst = @import("typst.zig");
const reparse = @import("reparse.zig");
const samples = @import("samples.zig");

const testing = std.testing;
const Expr = ex.Expr;

const leibniz_latex = "\\frac{\\pi}{4}=\\sum_{n=0}^{\\infty}\\frac{(-1)^n}{2n+1}=1-\\frac{1}{3}+\\frac{1}{5}-\\frac{1}{7}+\\cdots";
const leibniz_typst = "pi/4 = sum_(n = 0)^oo (-1)^n/(2 n + 1) = 1 - 1/3 + 1/5 - 1/7 + dots.c";

const Parsed = struct {
    e: Expr,
    spans: entry.Spans = .{},
    fn deinit(p: *Parsed) void {
        p.spans.deinit(testing.allocator);
        p.e.deinit();
    }
};

fn parseLatex(src: []const u8, mode: latex.Mode) !Parsed {
    var p: Parsed = .{ .e = try Expr.init(testing.allocator) };
    errdefer p.deinit();
    try latex.parse(&p.e, &p.spans, src, mode);
    return p;
}

fn parseTypst(src: []const u8, mode: typst.Mode) !Parsed {
    var p: Parsed = .{ .e = try Expr.init(testing.allocator) };
    errdefer p.deinit();
    try typst.parse(&p.e, &p.spans, src, mode);
    return p;
}

fn expectSame(a: *const Expr, b: *const Expr) !void {
    if (entry.sameTree(a, a.root, b, b.root)) return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try entry.dump(&w, a, a.root);
    try w.writeAll("\n   vs\n");
    try entry.dump(&w, b, b.root);
    std.debug.print("trees differ:\n{s}\n", .{w.buffered()});
    return error.TestExpectedEqual;
}

fn latexOut(e: *const Expr, mode: latex.Mode) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    try latex.write(&out.writer, e, mode);
    return out.toOwnedSlice();
}

fn typstOut(e: *const Expr, mode: typst.Mode) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    try typst.write(&out.writer, e, mode);
    return out.toOwnedSlice();
}

test "both syntaxes make the Leibniz series as it was built by hand" {
    var hand = try Expr.init(testing.allocator);
    defer hand.deinit();
    _ = try samples.leibniz(&hand);
    var l = try parseLatex(leibniz_latex, .math);
    defer l.deinit();
    try expectSame(&hand, &l.e);
    var t = try parseTypst(leibniz_typst, .math);
    defer t.deinit();
    try expectSame(&hand, &t.e);
}

test "each syntax writes back what it read, and the two translate" {
    var l = try parseLatex(leibniz_latex, .math);
    defer l.deinit();
    const back = try latexOut(&l.e, .math);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(leibniz_latex, back);
    var t = try parseTypst(leibniz_typst, .math);
    defer t.deinit();
    const tback = try typstOut(&t.e, .math);
    defer testing.allocator.free(tback);
    try testing.expectEqualStrings(leibniz_typst, tback);
    // LaTeX → objects → Typst → objects: the same objects.
    const as_typst = try typstOut(&l.e, .math);
    defer testing.allocator.free(as_typst);
    var again = try parseTypst(as_typst, .math);
    defer again.deinit();
    try expectSame(&l.e, &again.e);
    // And Typst → LaTeX → objects.
    const as_latex = try latexOut(&t.e, .math);
    defer testing.allocator.free(as_latex);
    var again2 = try parseLatex(as_latex, .math);
    defer again2.deinit();
    try expectSame(&t.e, &again2.e);
}

test "every prefix parses to a whole tree; missing arguments are holes" {
    for ([_][]const u8{ leibniz_latex, leibniz_typst }, 0..) |src, which| {
        for (0..src.len + 1) |n| {
            var p = if (which == 0) try parseLatex(src[0..n], .math) else try parseTypst(src[0..n], .math);
            p.deinit();
        }
    }
    // \frac{\pi}{ : a fraction, its denominator a hole.
    var a = try parseLatex("\\frac{\\pi}{", .math);
    defer a.deinit();
    const f = a.e.node(a.e.root).items.items[0];
    try testing.expectEqual(ex.Kind.fraction, a.e.node(f).kind);
    try testing.expectEqual(@as(usize, 0), a.e.node(a.e.slot(f, .den)).items.items.len);
    // pi/ : the same in Typst, the π moved into the numerator.
    var b = try parseTypst("pi/", .math);
    defer b.deinit();
    const g = b.e.node(b.e.root).items.items[0];
    try testing.expectEqual(ex.Kind.fraction, b.e.node(g).kind);
    try testing.expectEqualStrings("π", b.e.node(b.e.node(b.e.slot(g, .num)).items.items[0]).text);
    // x^ : scripts with an empty superscript.
    var c = try parseLatex("x^", .math);
    defer c.deinit();
    const s = c.e.node(c.e.root).items.items[0];
    try testing.expect(c.e.slot(s, .sup) != .none);
    // A command half typed stands as upright text.
    var d = try parseLatex("\\sq", .math);
    defer d.deinit();
    try testing.expectEqual(ex.Kind.word, d.e.node(d.e.node(d.e.root).items.items[0]).kind);
}

test "spans: which bytes made each object" {
    var p = try parseLatex(leibniz_latex, .math);
    defer p.deinit();
    const top = p.e.node(p.e.root).items.items;
    const sp = p.spans.get(top[0]);
    try testing.expectEqual(@as(u32, 0), sp.start);
    try testing.expectEqual(@as(u32, "\\frac{\\pi}{4}".len), sp.end);
    // The n of the lower limit, by its position.
    const at = std.mem.indexOf(u8, leibniz_latex, "n=0").?;
    const id = p.spans.at(at).?;
    try testing.expectEqualStrings("n", p.e.node(id).text);
    try testing.expectEqual(ex.Kind.variable, p.e.node(id).kind);
}

test "HP-15C legends: text with math, read and written back as they were" {
    const legends = [_][]const u8{ "$\\sqrt{x}$", "$x^2$", "$e^x$", "$10^x$", "$1/x$", "Δ\\%", "$x<0$", "$x\\le y$", "$\\mathrm{SIN}^{-1}$", "$x$⇄", "$\\int_y^x$", "$x$⇄$y$", "CL$x$", "LST$x$", "$\\bar{x}$", "$x!$", "$\\hat{y},r$", "C$y,x$", "→H.MS", "Re⇄Im" };
    for (legends) |src| {
        var p = try parseLatex(src, .legend);
        defer p.deinit();
        const back = try latexOut(&p.e, .legend);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(src, back);
        // And through Typst to the same objects.
        const t = try typstOut(&p.e, .legend);
        defer testing.allocator.free(t);
        var q = try parseTypst(t, .legend);
        defer q.deinit();
        try expectSame(&p.e, &q.e);
    }
    // 1/x in LaTeX is an inline slash, not a fraction; ∫ takes limits.
    var p = try parseLatex("$1/x$", .legend);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.e.node(p.e.root).items.items.len);
    var q = try parseLatex("$\\int_y^x$", .legend);
    defer q.deinit();
    const int = q.e.node(q.e.root).items.items[0];
    try testing.expectEqual(ex.Kind.large_op, q.e.node(int).kind);
    try testing.expectEqualStrings("y", q.e.node(q.e.node(q.e.slot(int, .sub)).items.items[0]).text);
}

test "a reparse keeps what was set on the objects that stayed" {
    var old = try parseLatex("x+y", .math);
    defer old.deinit();
    const y = old.e.node(old.e.root).items.items[2];
    try old.e.set(y, .scale, param.num(1.3));
    old.e.node(old.e.root).style = @enumFromInt(0);
    // Edited: a term added before and after.
    var new = try parseLatex("w+x+y+z", .math);
    defer new.deinit();
    var map = try reparse.carry(testing.allocator, &old.e, &new.e);
    defer map.deinit(testing.allocator);
    const ny = map.get(y).?;
    try testing.expectEqualStrings("y", new.e.node(ny).text);
    try testing.expectEqual(@as(f32, 1.3), new.e.override(ny, .scale).?.number);
    // The style context applied to the expression stays applied.
    try testing.expectEqual(@as(ex.StyleId, @enumFromInt(0)), new.e.node(new.e.root).style);
    // y changed to z: a new object, nothing carried.
    var edited = try parseLatex("x+z", .math);
    defer edited.deinit();
    var m2 = try reparse.carry(testing.allocator, &old.e, &edited.e);
    defer m2.deinit(testing.allocator);
    try testing.expectEqual(null, m2.get(y));
}

test "legend text: words, spaces and soft hyphens, each an object, read and written back" {
    var p = try parseLatex("SHIFT LOCK hy\\-phen\\allowbreak AB $x$", .legend);
    defer p.deinit();
    const top = p.e.node(p.e.root).items.items;
    const kinds = [_]ex.Kind{ .word, .space, .word, .space, .word, .soft_hyphen, .word, .word, .space, .variable };
    try testing.expectEqual(kinds.len, top.len);
    for (kinds, top) |k, id| try testing.expectEqual(k, p.e.node(id).kind);
    // \allowbreak: a break allowed before AB.
    try testing.expect(p.e.override(top[7], .break_before) != null);
    const back = try latexOut(&p.e, .legend);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("SHIFT LOCK hy\\-phen\\allowbreak AB $x$", back);
    // Typst writes the soft hyphen as -?, and reads it back.
    const t = try typstOut(&p.e, .legend);
    defer testing.allocator.free(t);
    var q = try parseTypst(t, .legend);
    defer q.deinit();
    try expectSame(&p.e, &q.e);
}

test "overrides in Graven's call form: parsed onto the object, written back, in both syntaxes" {
    // One object: the overrides go on it, and its span covers the call.
    var p = try parseLatex("\\set(scale: 1.2, rotate: 15){\\pi}r^2", .math);
    defer p.deinit();
    const pi = p.e.node(p.e.root).items.items[0];
    try testing.expectEqual(ex.Kind.constant, p.e.node(pi).kind);
    try testing.expectEqual(@as(f32, 1.2), p.e.override(pi, .scale).?.number);
    try testing.expectEqual(@as(f32, 15), p.e.override(pi, .rotate).?.number);
    try testing.expectEqual(0, p.spans.get(pi).start);
    const out = try latexOut(&p.e, .math);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\\set(scale: 1.2, rotate: 15){\\pi}r^2", out);
    // The same in Typst, and back.
    const t = try typstOut(&p.e, .math);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("set(pi, scale: 1.2, rotate: 15) r^2", t);
    var q = try parseTypst(t, .math);
    defer q.deinit();
    try expectSame(&p.e, &q.e);
    try testing.expectEqual(@as(f32, 1.2), q.e.override(q.e.node(q.e.root).items.items[0], .scale).?.number);
}

test "the call form: several objects stay grouped; a style's parameter and partial input are let be" {
    var p = try parseLatex("\\set(shift_y: 0.1, fraction_form: slashed){a+b}", .math);
    defer p.deinit();
    const g = p.e.node(p.e.root).items.items[0];
    try testing.expectEqual(ex.Kind.group, p.e.node(g).kind);
    try testing.expectEqual(@as(f32, 0.1), p.e.override(g, .shift_y).?.number);
    const out = try latexOut(&p.e, .math);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\\set(shift_y: 0.1, fraction_form: slashed){a+b}", out);
    // Weight is a style's, not an element's: left out.
    var w = try parseLatex("\\set(weight: 0.1, scale: 2){x}", .math);
    defer w.deinit();
    const wo = try latexOut(&w.e, .math);
    defer testing.allocator.free(wo);
    try testing.expectEqualStrings("\\set(scale: 2){x}", wo);
    // Being typed: every prefix parses.
    const full = "\\set(scale: 1.5){x}";
    for (0..full.len + 1) |n| {
        var part = try parseLatex(full[0..n], .math);
        part.deinit();
    }
    // In a legend's math.
    var l = try parseLatex("Area $\\set(scale: 1.2){\\pi}r^2$", .legend);
    defer l.deinit();
    const lo = try latexOut(&l.e, .legend);
    defer testing.allocator.free(lo);
    try testing.expectEqualStrings("Area $\\set(scale: 1.2){\\pi}r^2$", lo);
}

test "operator names: upright words, written back as commands, and as names in Typst" {
    var p = try parseLatex("\\sin x+\\log y", .math);
    defer p.deinit();
    const sin = p.e.node(p.e.root).items.items[0];
    try testing.expectEqual(ex.Kind.word, p.e.node(sin).kind);
    try testing.expectEqualStrings("sin", p.e.node(sin).text);
    const out = try latexOut(&p.e, .math);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\\sin x+\\log y", out);
    const t = try typstOut(&p.e, .math);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("sin x + log y", t);
}

test "an object's overrides rewritten in place: wrapped, changed, unwrapped, the rest kept as typed" {
    const gpa = testing.allocator;
    const src = "A = \\pi r^{2}";
    var p = try parseLatex(src, .math);
    defer p.deinit();
    const pi = entry.objectAt(&p.e, p.spans, 5).?;
    try testing.expectEqualStrings("π", p.e.node(pi).text);
    try p.e.set(pi, .scale, param.num(1.2));
    const one = try entry.rewriteCall(gpa, src, p.spans.get(pi), &p.e, pi);
    defer gpa.free(one);
    try testing.expectEqualStrings("A = \\set(scale: 1.2){\\pi} r^{2}", one);
    // Again from that source: its arguments rewritten.
    var q = try parseLatex(one, .math);
    defer q.deinit();
    const pi2 = entry.objectAt(&q.e, q.spans, 10).?;
    try q.e.set(pi2, .shift_y, param.num(0.1));
    const two = try entry.rewriteCall(gpa, one, q.spans.get(pi2), &q.e, pi2);
    defer gpa.free(two);
    try testing.expectEqualStrings("A = \\set(scale: 1.2, shift_y: 0.1){\\pi} r^{2}", two);
    // Cleared: unwrapped.
    q.e.clear(pi2, .scale);
    q.e.clear(pi2, .shift_y);
    const three = try entry.rewriteCall(gpa, one, q.spans.get(pi2), &q.e, pi2);
    defer gpa.free(three);
    try testing.expectEqualStrings(src, three);
}
