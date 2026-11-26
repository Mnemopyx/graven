const std = @import("std");
const geom = @import("graven_geom");
const sk = @import("root.zig");

const testing = std.testing;
const ga = testing.allocator;
const Sketch = sk.Sketch;

fn pt(x: f64, y: f64) geom.Point {
    return .{ .x = x, .y = y };
}

/// A rectangle of four segments drawn roughly, joined at its corners and
/// kept square, its bottom-left corner on the origin; with `height`, its
/// height is set too. Returns the segments: bottom, right, top, left.
fn rectangle(s: *Sketch, width: f64, height: ?f64) ![4]sk.GeomId {
    const b = try s.addSegment(ga, pt(0.3, -0.2), pt(18.6, 0.4), false);
    const r = try s.addSegment(ga, pt(18.9, 0.1), pt(19.3, 18.2), false);
    const t = try s.addSegment(ga, pt(19.1, 18.55), pt(0.2, 18.4), false);
    const l = try s.addSegment(ga, pt(-0.1, 18.7), pt(0.4, 0.3), false);
    const segs = [4]sk.GeomId{ b, r, t, l };
    for (0..4) |i| _ = try s.addConstraint(ga, .{ .kind = .{ .coincident = .{ .{ .geom = segs[i], .role = .end }, .{ .geom = segs[(i + 1) % 4], .role = .start } } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .horizontal = .{ .geom = b } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .horizontal = .{ .geom = t } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .vertical = .{ .geom = r } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .vertical = .{ .geom = l } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .coincident = .{ .{ .geom = b, .role = .start }, .{ .geom = sk.origin } } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .distance_x = .{ .a = .{ .geom = b, .role = .start }, .b = .{ .geom = b, .role = .end }, .value = width } }, .name = "w" });
    if (height) |h| _ = try s.addConstraint(ga, .{ .kind = .{ .distance_y = .{ .a = .{ .geom = r, .role = .start }, .b = .{ .geom = r, .role = .end }, .value = h } }, .name = "h" });
    return segs;
}

test "a fully constrained rectangle solves exactly and says so" {
    var s = try Sketch.init(testing.allocator);
    defer s.deinit(testing.allocator);
    const segs = try rectangle(&s, 19.05, 19.05);
    const res = try s.solve(testing.allocator);
    try testing.expect(res.solved);
    const top_right = try s.point(.{ .geom = segs[1], .role = .end });
    try testing.expectApproxEqAbs(@as(f64, 19.05), top_right.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 19.05), top_right.y, 1e-9);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const an = try s.analyse(testing.allocator, arena.allocator());
    try testing.expectEqual(@as(usize, 0), an.dof);
    try testing.expect(an.fully_constrained);
    try testing.expectEqual(@as(usize, 0), an.redundant.len);
    try testing.expectEqual(@as(usize, 0), an.free.len);
    // Its output: four exact lines, closed.
    const out = try s.physical(arena.allocator());
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expect((geom.Contour{ .segments = out }).isClosed());
    try testing.expectApproxEqAbs(19.05 * 19.05, (geom.Contour{ .segments = out }).signedArea(), 1e-9);
}

test "what is left free keeps where it was drawn, and is reported" {
    // The keycap body whose top edge is tied to nothing: a 2u-wide key
    // keeps the top where it was drawn on the 1u one.
    var s = try Sketch.init(testing.allocator);
    defer s.deinit(testing.allocator);
    const segs = try rectangle(&s, 19.05, null);
    _ = try s.solve(testing.allocator);
    const top_before = (try s.point(.{ .geom = segs[2], .role = .start })).y;
    // Wider.
    s.constraints.items[s.constraints.items.len - 1].kind.distance_x.value = 38.1;
    const res = try s.solve(testing.allocator);
    try testing.expect(res.solved);
    try testing.expectApproxEqAbs(@as(f64, 38.1), (try s.point(.{ .geom = segs[0], .role = .end })).x, 1e-9);
    try testing.expectApproxEqAbs(top_before, (try s.point(.{ .geom = segs[2], .role = .start })).y, 1e-6);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const an = try s.analyse(testing.allocator, arena.allocator());
    try testing.expectEqual(@as(usize, 1), an.dof);
    try testing.expect(!an.fully_constrained);
    // The top and both sides can move; the bottom cannot.
    try testing.expectEqual(@as(usize, 3), an.free.len);
    for (an.free) |g| try testing.expect(g != segs[0]);
}

test "a redundant constraint is named; a conflicting one is named with those it fights" {
    var s = try Sketch.init(testing.allocator);
    defer s.deinit(testing.allocator);
    const segs = try rectangle(&s, 10, 5);
    const width = s.constraints.items.len - 2;
    // The bottom's ends at one height again: redundant, but consistent.
    const extra = try s.addConstraint(ga, .{ .kind = .{ .horizontal = .{ .points = .{ .{ .geom = segs[0], .role = .start }, .{ .geom = segs[0], .role = .end } } } } });
    _ = try s.solve(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var an = try s.analyse(testing.allocator, arena.allocator());
    try testing.expect(an.solved);
    try testing.expect(an.fully_constrained);
    try testing.expectEqual(@as(usize, 1), an.redundant.len);
    try testing.expectEqual(extra, an.redundant[0]);
    // A second width, different: they cannot both hold.
    const clash = try s.addConstraint(ga, .{ .kind = .{ .distance_x = .{ .a = .{ .geom = segs[2], .role = .end }, .b = .{ .geom = segs[2], .role = .start }, .value = 12 } } });
    const res = try s.solve(testing.allocator);
    try testing.expect(!res.solved);
    an = try s.analyse(testing.allocator, arena.allocator());
    try testing.expect(!an.fully_constrained);
    var has_clash = false;
    var has_width = false;
    for (an.conflicting) |c| {
        has_clash = has_clash or c == clash;
        has_width = has_width or c == width;
    }
    try testing.expect(has_clash and has_width);
}

test "arcs, circles, angles and construction lines" {
    var s = try Sketch.init(testing.allocator);
    defer s.deinit(testing.allocator);
    // A construction line through the origin at 30 degrees.
    const line = try s.addLine(ga, pt(0.2, 0.1), 0.6);
    _ = try s.addConstraint(ga, .{ .kind = .{ .point_on = .{ .p = .{ .geom = sk.origin }, .on = line } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .angle = .{ .a = sk.h_axis, .b = line, .value = std.math.pi / 6.0 } } });
    // A quarter arc about the origin, radius 5, from the x axis to the line.
    const arc = try s.addArc(ga, pt(0.1, -0.1), pt(5.2, 0.3), pt(4, 2.5), false);
    _ = try s.addConstraint(ga, .{ .kind = .{ .coincident = .{ .{ .geom = arc, .role = .centre }, .{ .geom = sk.origin } } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .radius = .{ .g = arc, .value = 5 } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .point_on = .{ .p = .{ .geom = arc, .role = .start }, .on = sk.h_axis } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .point_on = .{ .p = .{ .geom = arc, .role = .end }, .on = line } } });
    // A circle on the arc's end, radius 1.
    const circle = try s.addCircle(ga, pt(4.5, 2.4), 0.8, false);
    _ = try s.addConstraint(ga, .{ .kind = .{ .coincident = .{ .{ .geom = circle, .role = .centre }, .{ .geom = arc, .role = .end } } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .radius = .{ .g = circle, .value = 1 } } });
    const res = try s.solve(testing.allocator);
    try testing.expect(res.solved);
    const end = try s.point(.{ .geom = arc, .role = .end });
    try testing.expectApproxEqAbs(5 * @cos(std.math.pi / 6.0), end.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.5), end.y, 1e-9);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const an = try s.analyse(testing.allocator, arena.allocator());
    try testing.expectEqual(@as(usize, 0), an.dof);
    try testing.expect(an.fully_constrained);
    // Output: the arc (one conic, a twelfth of a turn) and the circle (four);
    // not the line.
    const out = try s.physical(arena.allocator());
    try testing.expectEqual(@as(usize, 5), out.len);
    try testing.expectEqual(end.x, out[0].end().x);
    // Infinite lines stay construction.
    try testing.expectError(error.NotConstruction, s.setConstruction(line, false));
}

test "the box: bounded geometry only, or around the infinite geometry" {
    var s = try Sketch.init(testing.allocator);
    defer s.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try s.box(arena.allocator()) == null);
    // A horizontal and a vertical line crossing at (30, 20): a box about
    // that crossing, the least size.
    _ = try s.addLine(ga, pt(0, 20), 0);
    _ = try s.addLine(ga, pt(30, 0), std.math.pi / 2.0);
    var b = (try s.box(arena.allocator())).?;
    try testing.expectApproxEqAbs(@as(f64, 25), b.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 35), b.x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 15), b.y0, 1e-9);
    // Bounded geometry takes over, construction included.
    _ = try s.addCircle(ga, pt(100, 100), 20, true);
    b = (try s.box(arena.allocator())).?;
    try testing.expectApproxEqAbs(@as(f64, 80), b.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 120), b.y1, 1e-9);
}

test "dragging moves a point only where its constraints let it; removing takes its constraints" {
    var s = try Sketch.init(ga);
    defer s.deinit(ga);
    // A segment from the origin, horizontal, its length free.
    const seg = try s.addSegment(ga, pt(0.1, 0.2), pt(10, 0.5), false);
    _ = try s.addConstraint(ga, .{ .kind = .{ .coincident = .{ .{ .geom = seg, .role = .start }, .{ .geom = sk.origin } } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .horizontal = .{ .geom = seg } } });
    _ = try s.solve(ga);
    // Dragged up and along: it can only go along.
    const res = try s.drag(ga, ga, .{ .geom = seg, .role = .end }, pt(14, 6));
    try testing.expect(res.solved);
    const end = try s.point(.{ .geom = seg, .role = .end });
    try testing.expectApproxEqAbs(@as(f64, 14), end.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0), end.y, 1e-9);
    try testing.expectEqual(@as(usize, 2), s.constraints.items.len);
    // Removed, it takes its constraints with it and counts for nothing.
    try s.removeGeometry(seg);
    try testing.expectEqual(@as(usize, 0), s.constraints.items.len);
    var arena: std.heap.ArenaAllocator = .init(ga);
    defer arena.deinit();
    const an = try s.analyse(ga, arena.allocator());
    try testing.expectEqual(@as(usize, 0), an.dof);
    try testing.expectError(error.NoSuchGeometry, s.point(.{ .geom = seg, .role = .end }));
    // A dimension's value changes in place.
    const c = try s.addCircle(ga, pt(5, 5), 2, false);
    const rid = try s.addConstraint(ga, .{ .kind = .{ .radius = .{ .g = c, .value = 2 } } });
    try s.setValue(rid, 3);
    _ = try s.solve(ga);
    try testing.expectApproxEqAbs(@as(f64, 3), s.vars.items[s.geometry.items[c].kind.circle.r], 1e-9);
}

fn mkSeg(s: *Sketch, a: geom.Point, b: geom.Point) !sk.GeomId {
    return s.addSegment(ga, a, b, false);
}

fn fixIn(s: *Sketch, al: std.mem.Allocator, g: sk.GeomId, role: @FieldType(sk.PointRef, "role"), at: geom.Point) !void {
    _ = try s.addConstraint(al, .{ .kind = .{ .fixed = .{ .p = .{ .geom = g, .role = role }, .at = at } } });
}

fn fix(s: *Sketch, g: sk.GeomId, role: @FieldType(sk.PointRef, "role"), at: geom.Point) !void {
    _ = try s.addConstraint(ga, .{ .kind = .{ .fixed = .{ .p = .{ .geom = g, .role = role }, .at = at } } });
}

test "parallel, perpendicular and equal" {
    var s = try Sketch.init(ga);
    defer s.deinit(ga);
    const a = try mkSeg(&s, pt(0, 0), pt(10, 1));
    const b = try mkSeg(&s, pt(0, 5), pt(7, 6.5));
    const c = try mkSeg(&s, pt(20, 0), pt(21, 8));
    try fix(&s, a, .start, pt(0, 0));
    try fix(&s, a, .end, pt(10, 0));
    try fix(&s, b, .start, pt(0, 5));
    try fix(&s, c, .start, pt(20, 0));
    _ = try s.addConstraint(ga, .{ .kind = .{ .parallel = .{ .a = a, .b = b } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .perpendicular = .{ .a = a, .b = c } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .equal = .{ .a = a, .b = b } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .equal = .{ .a = b, .b = c } } });
    try testing.expect((try s.solve(ga)).solved);
    const be = try s.point(.{ .geom = b, .role = .end });
    try testing.expectApproxEqAbs(@as(f64, 10), be.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), be.y, 1e-9);
    const ce = try s.point(.{ .geom = c, .role = .end });
    try testing.expectApproxEqAbs(@as(f64, 20), ce.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), ce.y, 1e-9);
    var arena: std.heap.ArenaAllocator = .init(ga);
    defer arena.deinit();
    try testing.expect((try s.analyse(ga, arena.allocator())).fully_constrained);
}

test "tangent: a circle on a line, and two circles touching outside" {
    var s = try Sketch.init(ga);
    defer s.deinit(ga);
    const line = try mkSeg(&s, pt(-10, 0.5), pt(10, -0.3));
    try fix(&s, line, .start, pt(-10, 0));
    try fix(&s, line, .end, pt(10, 0));
    const c1 = try s.addCircle(ga, pt(0, 7), 4, false);
    try fix(&s, c1, .centre, pt(0, 6));
    _ = try s.addConstraint(ga, .{ .kind = .{ .tangent = .{ .a = c1, .b = line } } });
    const c2 = try s.addCircle(ga, pt(9, 6), 2, false);
    _ = try s.addConstraint(ga, .{ .kind = .{ .point_on = .{ .p = .{ .geom = c2, .role = .centre }, .on = sk.h_axis } } });
    _ = try s.addConstraint(ga, .{ .kind = .{ .tangent = .{ .a = c1, .b = c2 } } });
    // Just one way for c2 along the axis: fix its side by its centre's x.
    _ = try s.addConstraint(ga, .{ .kind = .{ .distance_x = .{ .a = .{ .geom = sk.origin }, .b = .{ .geom = c2, .role = .centre }, .value = 8 } } });
    const res = try s.solve(ga);
    try testing.expect(res.solved);
    // c1's radius is its height above the line.
    try testing.expectApproxEqAbs(@as(f64, 6), s.vars.items[s.geometry.items[c1].kind.circle.r], 1e-9);
    // c2 sits at (8, 0), 10 from c1's centre: touching outside, its
    // radius is what is left of that after c1's 6.
    try testing.expectApproxEqAbs(@as(f64, 4), s.vars.items[s.geometry.items[c2].kind.circle.r], 1e-9);
}

test "symmetric about a line and about a point" {
    var s = try Sketch.init(ga);
    defer s.deinit(ga);
    const p = try s.addPoint(ga, pt(3, 4), false);
    const q = try s.addPoint(ga, pt(-2, 5), false);
    try fix(&s, p, .point, pt(3, 4));
    _ = try s.addConstraint(ga, .{ .kind = .{ .symmetric = .{ .p = .{ .geom = p }, .q = .{ .geom = q }, .line = sk.v_axis } } });
    try testing.expect((try s.solve(ga)).solved);
    const qq = try s.point(.{ .geom = q });
    try testing.expectApproxEqAbs(@as(f64, -3), qq.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), qq.y, 1e-9);
    const r = try s.addPoint(ga, pt(-2, -5), false);
    _ = try s.addConstraint(ga, .{ .kind = .{ .symmetric = .{ .p = .{ .geom = p }, .q = .{ .geom = r }, .point = .{ .geom = sk.origin } } } });
    try testing.expect((try s.solve(ga)).solved);
    const rr = try s.point(.{ .geom = r });
    try testing.expectApproxEqAbs(@as(f64, -3), rr.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -4), rr.y, 1e-9);
}

test "a reference dimension reports and does not drive; parameters drive by expression" {
    // Its strings live in an arena, as the model's do.
    var ar: std.heap.ArenaAllocator = .init(ga);
    defer ar.deinit();
    const al = ar.allocator();
    var s = try Sketch.init(al);
    const a = try s.addSegment(al, pt(0, 0), pt(12, 0), false);
    try fixIn(&s, al, a, .start, pt(0, 0));
    _ = try s.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = a } } });
    const len = try s.addConstraint(al, .{ .kind = .{ .distance = .{ .a = .{ .geom = a, .role = .start }, .b = .{ .geom = a, .role = .end }, .value = 12 } } });
    // A second length, as reference: it adds no constraint, and reads 12.
    const ref = try s.addConstraint(al, .{ .kind = .{ .distance_x = .{ .a = .{ .geom = a, .role = .start }, .b = .{ .geom = a, .role = .end }, .value = 99 } }, .driving = false });
    _ = try s.solve(ga);
    var arena: std.heap.ArenaAllocator = .init(ga);
    defer arena.deinit();
    var an = try s.analyse(ga, arena.allocator());
    try testing.expect(an.fully_constrained);
    try testing.expectEqual(@as(usize, 0), an.redundant.len);
    try testing.expectApproxEqAbs(@as(f64, 12), s.constraints.items[ref].kind.distance_x.value, 1e-9);
    // The length from a parameter.
    try s.setParam(al, "w", "19.05");
    try s.setParam(al, "inset", "w / 10");
    try s.setExpr(al, len, "w - 2*inset");
    _ = try s.solve(ga);
    try testing.expectApproxEqAbs(19.05 * 0.8, (try s.point(.{ .geom = a, .role = .end })).x, 1e-9);
    try testing.expectApproxEqAbs(19.05 * 0.8, s.constraints.items[ref].kind.distance_x.value, 1e-9);
    // A new size re-solves from it.
    try s.setParam(al, "w", "38.1");
    _ = try s.solve(ga);
    try testing.expectApproxEqAbs(38.1 * 0.8, (try s.point(.{ .geom = a, .role = .end })).x, 1e-9);
    // A bad expression is reported and leaves the value.
    try s.setExpr(al, len, "w - nope");
    try testing.expectEqual(sk.expr.Error.UnknownName, s.exprError(len).?);
    _ = try s.solve(ga);
    try testing.expectApproxEqAbs(38.1 * 0.8, (try s.point(.{ .geom = a, .role = .end })).x, 1e-9);
    try testing.expectError(error.BadName, s.setParam(al, "2w", "1"));
    // Its parameters copy with the sketch.
    var copy = try s.clone(ga);
    defer {
        for (copy.constraints.items) |c| {
            ga.free(c.name);
            ga.free(c.expr);
        }
        for (copy.params.items) |p| {
            ga.free(p.name);
            ga.free(p.expr);
        }
        copy.deinit(ga);
    }
    try testing.expectEqualStrings("w / 10", copy.params.items[1].expr);
    an = try s.analyse(ga, arena.allocator());
    try testing.expect(an.fully_constrained);
}

test "output joins into closed profiles; a parameter switches construction geometry on" {
    var ar: std.heap.ArenaAllocator = .init(ga);
    defer ar.deinit();
    const al = ar.allocator();
    var s = try Sketch.init(al);
    // A rectangle drawn with one side the other way round, and a circle.
    _ = try s.addSegment(al, pt(0, 0), pt(10, 0), false);
    _ = try s.addSegment(al, pt(10, 0), pt(10, 5), false);
    _ = try s.addSegment(al, pt(0, 5), pt(10, 5), false);
    _ = try s.addSegment(al, pt(0, 5), pt(0, 0), false);
    _ = try s.addCircle(al, pt(20, 2), 1, false);
    // A loose piece, and a bump that is construction until asked for.
    _ = try s.addSegment(al, pt(30, 0), pt(31, 0), false);
    const bump = try s.addCircle(al, pt(5, 2), 0.5, true);
    try s.setParam(al, "homing", "0");
    try s.setPhysicalWhen(al, bump, "homing");
    var p = try s.profiles(al);
    try testing.expectEqual(@as(usize, 2), p.contours.len);
    try testing.expectEqual(@as(usize, 1), p.open);
    for (p.contours) |c| try testing.expect(c.isClosed());
    try testing.expectApproxEqAbs(@as(f64, 50), @abs(p.contours[0].signedArea()), 1e-9);
    try s.setParam(al, "homing", "1");
    p = try s.profiles(al);
    try testing.expectEqual(@as(usize, 3), p.contours.len);
    try testing.expectError(error.WrongKind, s.setPhysicalWhen(al, try s.addLine(al, pt(0, 0), 0), "homing"));
}

test "a distance is never negative and has no start or end: the side is kept as drawn" {
    var arena: std.heap.ArenaAllocator = .init(ga);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const p = try s.addPoint(al, pt(-4, -3), false);
    // From the point to the origin or from the origin to the point: the
    // same distance, positive, and the point stays left of and below it.
    const ab = try s.addConstraint(al, .{ .kind = .{ .distance_x = .{ .a = .{ .geom = sk.origin }, .b = .{ .geom = p }, .value = 10 } } });
    const ba = try s.addConstraint(al, .{ .kind = .{ .distance_y = .{ .a = .{ .geom = p }, .b = .{ .geom = sk.origin }, .value = -6 } } });
    try testing.expectEqual(6, s.constraints.items[ba].kind.distance_y.value);
    _ = try s.solve(ga);
    const q = try s.point(.{ .geom = p });
    try testing.expectApproxEqAbs(@as(f64, -10), q.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -6), q.y, 1e-9);
    // A negative value is refused.
    try testing.expectError(error.Negative, s.setValue(ab, -2));
    // An older sketch's signed distance and expression: made positive, the
    // side kept.
    try s.setParam(al, "w", "20");
    s.constraints.items[ab].kind.distance_x.value = -10;
    s.constraints.items[ab].kind.distance_x.side = 1;
    s.constraints.items[ab].expr = "-w / 2";
    try s.upgradeSigns(al);
    try testing.expectEqualStrings("w / 2", s.constraints.items[ab].expr);
    try testing.expectEqual(-1, s.constraints.items[ab].kind.distance_x.side);
    _ = try s.solve(ga);
    try testing.expectApproxEqAbs(@as(f64, -10), (try s.point(.{ .geom = p })).x, 1e-9);
}

test "runs: a path through two-way points is one run, a loop closes, a three-way point ends runs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const L = struct {
        fn f(x0: f64, y0: f64, x1: f64, y1: f64) geom.Segment {
            return .{ .line = .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } } };
        }
    }.f;
    // An L, its second piece given backwards: one open run of two.
    const l = try Sketch.runs(al, &.{ L(0, 0, 10, 0), L(10, 10, 10, 0) });
    try std.testing.expectEqual(1, l.len);
    try std.testing.expectEqual(2, l[0].segments.len);
    try std.testing.expect(!l[0].closed);
    // A square: one closed run of four.
    const sq = try Sketch.runs(al, &.{ L(0, 0, 10, 0), L(10, 0, 10, 10), L(10, 10, 0, 10), L(0, 10, 0, 0) });
    try std.testing.expectEqual(1, sq.len);
    try std.testing.expect(sq[0].closed);
    try std.testing.expectEqual(4, sq[0].segments.len);
    // A T: three runs, each ending at the junction.
    const t = try Sketch.runs(al, &.{ L(-5, 0, 0, 0), L(0, 0, 5, 0), L(0, 0, 0, 5) });
    try std.testing.expectEqual(3, t.len);
}

test "a group of sketch geometry: constraints inside it are its own, and stay right as geometry goes" {
    var s = try Sketch.init(ga);
    defer s.deinit(ga);
    const segs = try rectangle(&s, 20, 10);
    const obj = try s.makeGroup(ga, &segs, &.{}, .plain, true);
    const g = try s.groups.get(obj);
    // Its corners, sides and dimensions are internal; its hold on the
    // origin (reference geometry, in no group) is outside.
    for (s.constraints.items, 0..) |c, ci| {
        const to_origin = sk.refersTo(c, sk.origin);
        try testing.expectEqual(to_origin, c.group == sk.group.none);
        if (!to_origin) try testing.expect(std.mem.indexOfScalar(u32, g.constraints.items, @intCast(ci)) != null);
    }
    // A constraint added between two members joins the group.
    const c = try s.addConstraint(ga, .{ .kind = .{ .equal = .{ .a = segs[0], .b = segs[2] } } });
    try testing.expectEqual(obj, s.constraints.items[c].group);
    // Removing a side drops its constraints, and the group's IDs follow.
    try s.removeGeometry(segs[1]);
    for ((try s.groups.get(obj)).constraints.items) |k| try testing.expectEqual(obj, s.constraints.items[k].group);
    // A copy (in an arena: a sketch's names live as long as its document).
    var arena: std.heap.ArenaAllocator = .init(ga);
    defer arena.deinit();
    const copy = try s.clone(arena.allocator());
    try testing.expectEqual((try s.groups.get(obj)).constraints.items.len, (try copy.groups.get(obj)).constraints.items.len);
    _ = try s.solve(ga);
    try s.ungroup(ga, obj);
    for (s.constraints.items) |k| try testing.expectEqual(sk.group.none, k.group);
}
