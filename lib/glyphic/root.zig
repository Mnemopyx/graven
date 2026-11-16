//! Glyphic: Graven's v2 engine, a glyphic styling and positioning engine,
//! built beside the v1 engine (lib/engine) with no dependency on it.
//!
//! Stage 1, the object model: legends' math as conceptual objects with
//! stable identities, named slots, overrides and tags (expr.zig); every
//! decision a typed parameter (param.zig) resolved through style contexts
//! an application configures in the engine and applies to elements or
//! groups (styles.zig), with rules for objects of a kind, an element
//! overriding only in a limited way (cascade.zig); the context an object's place gives it
//! (math style, script level), derived and never stored; Tab's stops,
//! heads and fields in field order (stops.zig); where an expression may
//! break (breaks.zig).
//!
//! Stage 2, the ground (ground.zig): where an expression stands, as a
//! cursor of pieces (baseline paths, open stretches, room, cap height,
//! process limits); lib/layout provides it for tracks.
//!
//! Stage 3, layout (layout.zig, setting.zig): objects into boxes in flat
//! expression space (faces chosen by kind, TeX's spacing, fractions in
//! three forms, scripts, large operators with limits, radicals, fences,
//! accents, relative rotation), then set on the ground: broken into lines
//! at the break candidates, aligned in open stretches, each item stood on
//! the baseline path where it falls; exact outlines out.
//!
//! Stage 4, entry syntaxes (latex.zig, typst.zig, with symbols.zig,
//! entry.zig, reparse.zig): LaTeX and Typst-style math, and legends (text
//! with math between dollars), to objects and back; parsers that never
//! fail, so every prefix gives a whole tree with holes; source spans;
//! identity carried across a reparse.

const std = @import("std");

pub const param = @import("param.zig");
pub const expr = @import("expr.zig");
pub const cascade = @import("cascade.zig");
pub const stops = @import("stops.zig");
pub const breaks = @import("breaks.zig");
pub const ground = @import("ground.zig");
pub const faces = @import("faces.zig");
pub const layout = @import("layout.zig");
pub const setting = @import("setting.zig");
pub const symbols = @import("symbols.zig");
pub const styles = @import("styles.zig");
pub const entry = @import("entry.zig");
pub const latex = @import("latex.zig");
pub const typst = @import("typst.zig");
pub const reparse = @import("reparse.zig");
pub const samples = @import("samples.zig");

pub const Expr = expr.Expr;
pub const Id = expr.Id;
pub const Kind = expr.Kind;
pub const Param = param.Param;
pub const Value = param.Value;
pub const Resolver = cascade.Resolver;
pub const Engine = styles.Engine;
pub const StyleId = expr.StyleId;
pub const Rule = cascade.Rule;
pub const Stop = stops.Stop;

test {
    std.testing.refAllDecls(@This());
    _ = param;
    _ = expr;
    _ = ground;
    _ = @import("layout_test.zig");
    _ = @import("syntax_test.zig");
}

const testing = std.testing;
const num = param.num;
const of = param.of;

test "Leibniz: the object tree" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const l = try samples.leibniz(&e);
    // π/4 = Σ (…) = 1 − 1/3 + 1/5 − 1/7 + ⋯ : 14 objects on the top row.
    try testing.expectEqual(@as(usize, 14), e.node(e.root).items.items.len);
    try testing.expectEqual(Kind.large_op, e.node(l.sigma).kind);
    // The exponent belongs to the parenthesised group, not to ")".
    try testing.expectEqual(l.fence, e.node(e.slot(l.exponent, .base)).items.items[0]);
    try testing.expectEqual(expr.Role.unary, e.node(l.unary_minus).role);
    // The three n are three objects with one symbol.
    for ([_]Id{ l.n_limit, l.n_exponent, l.n_den }) |n| try testing.expectEqualStrings("n", e.node(n).symbol);
    try testing.expectEqualStrings("\\frac", e.node(l.summand).tags.source);
}

test "Leibniz: math style and script level come from the structure" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const l = try samples.leibniz(&e);
    // Set in display style: a style context applied to the expression.
    var g = Engine.init(testing.allocator);
    defer g.deinit();
    const display = try g.addStyle("display", .none);
    try g.set(display, .math_style, of(param.MathStyle.display));
    try g.apply(&e, e.root, display);
    var r = Resolver.init(&g, &e, &.{});
    try testing.expectEqual(cascade.TexStyle.display, r.root);
    try testing.expectEqual(cascade.TexStyle.text, r.context(l.pi).style);
    try testing.expect(r.context(l.four).cramped);
    try testing.expectEqual(@as(u2, 1), r.context(l.n_limit).script_level);
    try testing.expect(r.context(l.n_limit).cramped);
    // The exponent in a numerator: text style for the numerator, script for the exponent.
    try testing.expectEqual(cascade.TexStyle.script, r.context(l.n_exponent).style);
    try testing.expectEqual(@as(u2, 0), r.context(l.n_den).script_level);
    // In text style everything sits a level lower.
    try g.apply(&e, e.root, .none);
    r = Resolver.init(&g, &e, &.{});
    try testing.expectEqual(cascade.TexStyle.script, r.context(l.pi).style);
    try testing.expectEqual(@as(u2, 2), r.context(l.n_exponent).script_level);
}

test "style contexts: innermost applied first, each before its base, an element only in its limited ways" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const l = try samples.leibniz(&e);
    var g = Engine.init(testing.allocator);
    defer g.deinit();
    // A package as a base context; a style built on it; a context for this
    // legend applied to the expression; one applied to a single element.
    const package = try g.addStyle("package", .none);
    try g.setFor(package, .{ .kind = .variable }, .shape, of(param.Shape.italic));
    try g.setFor(package, .{ .kind = .variable }, .scale, num(1.2));
    try g.setFor(package, .{ .kind = .variable, .script_level = 1 }, .scale, num(1.1));
    try g.setFor(package, .{ .kind = .variable }, .weight, num(0.01));
    const style = try g.addStyle("label", package);
    try g.set(style, .weight, num(0.03));
    const legend = try g.addStyle("this legend", .none);
    try g.setFor(legend, .{ .symbol = "n" }, .weight, num(0.04));
    try g.set(legend, .math_style, of(param.MathStyle.display));
    const heavy = try g.addStyle("heavy", .none);
    try g.set(heavy, .weight, num(0.06));
    try g.apply(&e, e.root, legend);
    try g.apply(&e, l.summand, heavy);
    // The label style reaches the expression from outside (its track).
    const r = Resolver.init(&g, &e, &.{style});

    // From the package, through the style's base.
    var v = r.resolve(l.n_limit, .shape);
    try testing.expectEqual(param.Shape.italic, param.as(param.Shape, v.value));
    try testing.expectEqual(cascade.From.style, v.from);
    try testing.expectEqual(package, v.style);
    // π is not a variable: the default.
    v = r.resolve(l.pi, .shape);
    try testing.expectEqual(cascade.From.default, v.from);
    // The more specific rule wins within a context, whatever its order.
    try testing.expectEqual(@as(f32, 1.1), r.get(l.n_limit, .scale).number);
    try testing.expectEqual(@as(f32, 1.2), r.get(l.n_den, .scale).number);
    // Weight: the style's general value over its base's rule for
    // variables; the legend's "every n" over the style; the context
    // applied to the summand over the legend's, for what it holds.
    try testing.expectEqual(@as(f32, 0.03), r.get(l.pi, .weight).number);
    try testing.expectEqual(@as(f32, 0.04), r.get(l.n_limit, .weight).number);
    try testing.expectEqual(legend, r.resolve(l.n_limit, .weight).style);
    try testing.expectEqual(@as(f32, 0.06), r.get(l.n_den, .weight).number);
    try testing.expectEqual(heavy, r.resolve(l.n_exponent, .weight).style);
    // An element overrides its scale; not its weight, which is its style's.
    try e.set(l.n_den, .scale, num(1.5));
    v = r.resolve(l.n_den, .scale);
    try testing.expectEqual(cascade.From.element, v.from);
    try testing.expectError(error.NotForElements, e.set(l.n_den, .weight, num(0.05)));
    // Cleared, the style's value again.
    e.clear(l.n_den, .scale);
    try testing.expectEqual(@as(f32, 1.2), r.get(l.n_den, .scale).number);
    // Faces come from the contexts too, the innermost naming a role first.
    try testing.expectEqual(@as(usize, 0), (try r.faces(testing.allocator, l.pi)).members.len);
}

test "a field turns relative to what holds it, set on the object or by a rule" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const l = try samples.leibniz(&e);
    // Every fraction in this legend stood on end; one turned its own way.
    var g = Engine.init(testing.allocator);
    defer g.deinit();
    const turned = try g.addStyle("turned", .none);
    try g.setFor(turned, .{ .kind = .fraction }, .rotate, num(90));
    try g.apply(&e, e.root, turned);
    try e.set(l.summand, .rotate, num(-45));
    try e.set(l.summand, .rotate_pivot, of(param.Pivot.baseline_start));
    const r = Resolver.init(&g, &e, &.{});
    try testing.expectEqual(@as(f32, 90), r.get(l.pi_over_4, .rotate).number);
    try testing.expectEqual(turned, r.resolve(l.pi_over_4, .rotate).style);
    try testing.expectEqual(@as(f32, -45), r.get(l.summand, .rotate).number);
    try testing.expectEqual(param.Pivot.baseline_start, param.as(param.Pivot, r.get(l.summand, .rotate_pivot)));
    // By default a turned object takes its rotated room, turning about its ink.
    try testing.expectEqual(param.RotateSpace.box, param.as(param.RotateSpace, r.get(l.pi_over_4, .rotate_space)));
    try testing.expectEqual(param.Pivot.ink_centre, param.as(param.Pivot, r.get(l.pi_over_4, .rotate_pivot)));
    try testing.expectError(param.Error.OutOfRange, e.set(l.pi, .rotate, num(270)));
}

fn expectStops(want: []const Stop, got: []const Stop) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expect(w.eql(g));
}

test "Leibniz: Tab's stops, heads before fields, in field order" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const l = try samples.leibniz(&e);
    var g = Engine.init(testing.allocator);
    defer g.deinit();
    const r = Resolver.init(&g, &e, &.{});
    const s = try stops.list(testing.allocator, &r);
    defer testing.allocator.free(s);
    var want: std.ArrayList(Stop) = .empty;
    defer want.deinit(testing.allocator);
    const a = testing.allocator;
    // [rule] π 4 [Σ] n=0 ∞ [rule] [parens] −1 n 2n+1, then [rule] 1 3 three times.
    try want.appendSlice(a, &.{
        .{ .head = l.pi_over_4 },                    .{ .field = e.slot(l.pi_over_4, .num) },
        .{ .field = e.slot(l.pi_over_4, .den) },     .{ .head = l.sigma },
        .{ .field = e.slot(l.sigma, .sub) },         .{ .field = e.slot(l.sigma, .sup) },
        .{ .head = l.summand },                      .{ .head = l.fence },
        .{ .field = e.slot(l.fence, .body) },        .{ .field = e.slot(l.exponent, .sup) },
        .{ .field = e.slot(l.summand, .den) },
    });
    for (l.tail_fracs) |f| try want.appendSlice(a, &.{ .{ .head = f }, .{ .field = e.slot(f, .num) }, .{ .field = e.slot(f, .den) } });
    try expectStops(want.items, s);
    // Tab and Shift+Tab, wrapping.
    try testing.expect(stops.next(s, .{ .head = l.sigma }, false).?.eql(.{ .field = e.slot(l.sigma, .sub) }));
    try testing.expect(stops.next(s, s[0], true).?.eql(s[s.len - 1]));
}

test "a radical's index is toggled from its head, kept while hidden" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const rad = try e.structure(.radical, "√", "");
    try e.append(e.root, rad);
    try e.append(e.slot(rad, .body), try e.leaf(.variable, "x"));
    var g = Engine.init(testing.allocator);
    defer g.deinit();
    var r = Resolver.init(&g, &e, &.{});
    const a = testing.allocator;
    var s = try stops.list(a, &r);
    try expectStops(&.{ .{ .head = rad }, .{ .field = e.slot(rad, .body) } }, s);
    a.free(s);
    // On: an empty index field, the caret's next place; head, index, radicand.
    const idx = (try stops.toggle(&e, &r, rad, .index)).?;
    try e.append(idx, try e.leaf(.number, "3"));
    s = try stops.list(a, &r);
    try expectStops(&.{ .{ .head = rad }, .{ .field = idx }, .{ .field = e.slot(rad, .body) } }, s);
    a.free(s);
    // Off: skipped by Tab, its 3 kept; on again, the same 3.
    try testing.expectEqual(null, try stops.toggle(&e, &r, rad, .index));
    s = try stops.list(a, &r);
    try expectStops(&.{ .{ .head = rad }, .{ .field = e.slot(rad, .body) } }, s);
    a.free(s);
    try testing.expectEqual(idx, (try stops.toggle(&e, &r, rad, .index)).?);
    try testing.expectEqual(@as(usize, 1), e.node(idx).items.items.len);
    // A style can hide indexes; the object's own setting still wins.
    const hide = try g.addStyle("no indexes", .none);
    try g.setFor(hide, .{ .kind = .radical }, .show_index, of(param.SlotShow.hidden));
    r = Resolver.init(&g, &e, &.{hide});
    try testing.expect(stops.shown(&r, rad, .index));
    e.clear(rad, .show_index);
    try testing.expect(!stops.shown(&r, rad, .index));
    try testing.expectError(error.NoSuchSlot, stops.toggle(&e, &r, rad, .body));
}

test "Leibniz: breaks after relations and binary operators, never inside structures" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const l = try samples.leibniz(&e);
    var g = Engine.init(testing.allocator);
    defer g.deinit();
    var r = Resolver.init(&g, &e, &.{});
    const a = testing.allocator;
    var c = try breaks.candidates(a, &r);
    // After each =, and after −, +, −, but not after the last + (before ⋯).
    try testing.expectEqual(@as(usize, 5), c.len);
    try testing.expectEqual(l.sigma, c[0].before);
    try testing.expectEqual(@as(f32, 500), c[0].cost);
    try testing.expectEqual(@as(f32, 500), c[1].cost);
    try testing.expectEqual(@as(f32, 700), c[2].cost);
    for (c) |cand| try testing.expect(cand.before != l.ellipsis);
    a.free(c);
    // A forced break before the second =, a forbidden one after it, and a
    // package that makes relation breaks dearer.
    try e.set(l.second_eq, .break_before, of(param.BreakMark.force));
    const top = e.node(e.root).items.items;
    const after_eq = top[std.mem.indexOfScalar(Id, top, l.second_eq).? + 1];
    try e.set(after_eq, .break_before, of(param.BreakMark.forbid));
    const pkg = try g.addStyle("dear relations", .none);
    try g.set(pkg, .relation_break_cost, num(900));
    r = Resolver.init(&g, &e, &.{pkg});
    c = try breaks.candidates(a, &r);
    defer a.free(c);
    try testing.expectEqual(@as(usize, 5), c.len);
    try testing.expectEqual(@as(f32, 900), c[0].cost);
    try testing.expect(c[1].forced and c[1].before == l.second_eq);
    for (c) |cand| try testing.expect(cand.before != after_eq);
}
