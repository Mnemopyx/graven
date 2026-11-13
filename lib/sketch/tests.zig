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
