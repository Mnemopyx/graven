//! Library objects with parameters (the owner, 2026-11-28; blueprint
//! "Library objects with parameters"). One tool or one library call makes
//! one object: a sealed group (`lib/constraint/group.zig`) of kind
//! `library`, its type named by a string (`round-rect`), holding its
//! geometry and the constraints of its contract, and a list of parameters.
//!
//! A parameter is not a constraint: it is a measurement over the object's
//! own geometry, written as a dimension (`group.Param.measure`). Read
//! (`value`), it measures the geometry as it is now. Applied (`apply`), it
//! holds that dimension at the value for one solve, the object's other
//! parameters held where they are, then lets go, as a drag holds a point:
//! the geometry moves the least it can, the contract keeps the shape, and
//! afterwards the object is as free to be dragged as before. A size the
//! user wants held is an ordinary dimension; a value one of those will not
//! let a parameter take is refused (`error.Conflict`), the geometry as it
//! was.
//!
//! Everything here works on any library object through the generic
//! interface (its parameters, its group), knowing nothing of its type, so
//! a type an older Graven does not know can still be measured, applied,
//! dragged and exploded. Only the builders (`addRoundRect`) know a type.
//!
//! Explode (`explode`) removes the object level and its parameters
//! entirely: its geometry and constraints stay, ordinary and editable,
//! every distance and angle as it was.

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const Constraint = root.Constraint;
const PointRef = root.PointRef;
const group = root.group;
const GroupId = group.GroupId;
const Param = group.Param;

pub const Error = root.Error || group.Error || error{ NotAnObject, Conflict };

/// A library object's group, or `NotAnObject`.
pub fn object(s: *const Sketch, id: GroupId) Error!*group.Group {
    const g = try s.groups.get(id);
    if (g.kind != .library) return error.NotAnObject;
    return g;
}

/// Whether group `id` is a library object.
pub fn isObject(s: *const Sketch, id: GroupId) bool {
    _ = object(s, id) catch return false;
    return true;
}

/// What dimension `c` measures now: a length (never negative) in mm, or
/// an angle in radians. Null when it names geometry no longer there.
pub fn measure(s: *const Sketch, c: Constraint) ?f64 {
    // A direction: from the x axis, counter-clockwise, in [0, 2 pi).
    if (c.kind == .direction) {
        const d = c.kind.direction;
        const p = s.point(d.a) catch return null;
        const q = s.point(d.b) catch return null;
        const t = std.math.atan2(q.y - p.y, q.x - p.x);
        // Just under zero (a solved 0 degrees) reads as 0, not 360.
        if (t < 0 and t > -1e-9) return 0;
        return if (t < 0) t + 2 * std.math.pi else t;
    }
    const v = s.measure(c) orelse return null;
    return switch (c.kind) {
        .angle => v,
        else => @abs(v),
    };
}

/// Parameter `pid` of object `id`, as the geometry measures it now.
pub fn value(s: *const Sketch, id: GroupId, pid: u32) Error!f64 {
    const g = try object(s, id);
    const p = g.param(pid) orelse return error.NoSuchParameter;
    return measure(s, p.measure) orelse error.NoSuchGeometry;
}

/// Dimension `c` held at `v`: a driving constraint for one solve, on the
/// side its points are on now (a distance to a line has one).
fn held(s: *const Sketch, c: Constraint, v: f64) Constraint {
    var k = c;
    k.driving = true;
    k.expr = "";
    k.group = group.none;
    switch (k.kind) {
        .angle => |*d| d.value = v,
        .direction => |*d| d.value = v,
        .line_distance => |*d| {
            d.value = @abs(v);
            d.side = 1;
            const now = s.measure(k) orelse 0;
            d.side = if (now < 0) -1 else 1;
        },
        inline .distance_x, .distance_y => |*d| {
            d.value = @abs(v);
            d.side = 1;
            const now = s.measure(k) orelse 0;
            d.side = if (now < 0) -1 else 1;
        },
        inline .distance, .radius, .diameter => |*d| d.value = @abs(v),
        else => {},
    }
    return k;
}

/// Applies parameter `pid` of object `id` at `v` (mm, or radians): the
/// object's geometry changed the least it can to measure that, its other
/// parameters held as they are, for one solve; nothing is held after.
/// When the sketch's constraints will not let it (a dimension the user
/// placed holds that size), `error.Conflict` and nothing changes.
/// `a` is the sketch's allocator, `gpa` scratch.
pub fn apply(s: *Sketch, a: Allocator, gpa: Allocator, id: GroupId, pid: u32, v: f64) Error!void {
    const g = try object(s, id);
    const p = g.param(pid) orelse return error.NoSuchParameter;
    if (!std.math.isFinite(v)) return error.WrongKind;
    if (p.dimension == .length and !(v > 0)) return error.Negative;
    const saved = try gpa.dupe(f64, s.vars.items);
    defer gpa.free(saved);
    const n0 = s.constraints.items.len;
    defer s.constraints.shrinkRetainingCapacity(n0);
    for (g.params.items) |q| {
        if (q.id == pid) continue;
        const now = measure(s, q.measure) orelse continue;
        try s.constraints.append(a, held(s, q.measure, now));
    }
    try s.constraints.append(a, held(s, p.measure, v));
    const res = try root.solver.solve(s, gpa);
    s.constraints.shrinkRetainingCapacity(n0);
    if (!res.solved or turnedOver(s, g, saved)) {
        @memcpy(s.vars.items, saved);
        return error.Conflict;
    }
    _ = try s.solve(gpa);
}

/// Whether any of object `g`'s sides now runs the other way from how it
/// ran with the values `before`: a shape turned inside out to take a
/// value (a corner rounder than its sides are long) is not the object.
fn turnedOver(s: *const Sketch, g: *const group.Group, before: []const f64) bool {
    const v = s.vars.items;
    for (g.geometry.items) |m| switch (s.geometry.items[m].kind) {
        .segment => |sg| {
            const nx = v[sg.b.x] - v[sg.a.x];
            const ny = v[sg.b.y] - v[sg.a.y];
            const ox = before[sg.b.x] - before[sg.a.x];
            const oy = before[sg.b.y] - before[sg.a.y];
            if (nx * ox + ny * oy < -1e-12) return true;
        },
        else => {},
    };
    return false;
}

/// Explodes object `id`: the object level and its parameters go; its
/// geometry and constraints stay where they are, ordinary (editable,
/// removable one by one), every value as it was.
pub fn explode(s: *Sketch, a: Allocator, id: GroupId) Error!void {
    _ = try object(s, id);
    try s.ungroup(a, id);
}

// Round-rect --------------------------------------------------------------------

/// How a round-rect is placed (the owner, 2026-11-28): about a centre, a
/// point of it that stays in its middle (mirror symmetry), from that to a
/// corner; or by two opposite corners.
pub const RoundRectVariant = enum { centre, corners };

pub const round_rect = "round-rect";

/// Its members, in the order made: the four sides and corner arcs round
/// counter-clockwise from the bottom side (its first), then (about a
/// centre) the centre point.
pub const RoundRect = struct {
    pub const bottom = 0;
    pub const right = 2;
    pub const top = 4;
    pub const left = 6;
    /// The corner arcs: after the bottom, right, top and left sides.
    pub const arcs = [4]u32{ 1, 3, 5, 7 };
    pub const centre = 8;
};

/// The box a round-rect's two clicks give: `p0` its centre and `p1` a
/// corner, or two opposite corners.
pub fn roundRectBox(variant: RoundRectVariant, p0: Point, p1: Point) geom.Box {
    return switch (variant) {
        .centre => blk: {
            const dx = @abs(p1.x - p0.x);
            const dy = @abs(p1.y - p0.y);
            break :blk .{ .x0 = p0.x - dx, .x1 = p0.x + dx, .y0 = p0.y - dy, .y1 = p0.y + dy };
        },
        .corners => .{ .x0 = @min(p0.x, p1.x), .x1 = @max(p0.x, p1.x), .y0 = @min(p0.y, p1.y), .y1 = @max(p0.y, p1.y) },
    };
}

/// The radius a new round-rect's corners start at: a fifth of its shorter
/// side.
pub fn startRadius(b: geom.Box) f64 {
    return @min(b.width(), b.height()) / 5;
}

/// A round-rect's outline in box `b` with corner radius `r`, for drawing
/// it while it is placed.
pub fn roundRectShape(a: Allocator, b: geom.Box, r_in: f64, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
    const r = std.math.clamp(r_in, 0, @min(b.width(), b.height()) / 2);
    const x0 = b.x0;
    const x1 = b.x1;
    const y0 = b.y0;
    const y1 = b.y1;
    const pi = std.math.pi;
    var buf: [4]geom.Segment = undefined;
    try out.append(a, .{ .line = .{ .{ .x = x0 + r, .y = y0 }, .{ .x = x1 - r, .y = y0 } } });
    try out.appendSlice(a, geom.arc(.{ .x = x1 - r, .y = y0 + r }, r, -pi / 2.0, pi / 2.0, &buf));
    try out.append(a, .{ .line = .{ .{ .x = x1, .y = y0 + r }, .{ .x = x1, .y = y1 - r } } });
    try out.appendSlice(a, geom.arc(.{ .x = x1 - r, .y = y1 - r }, r, 0, pi / 2.0, &buf));
    try out.append(a, .{ .line = .{ .{ .x = x1 - r, .y = y1 }, .{ .x = x0 + r, .y = y1 } } });
    try out.appendSlice(a, geom.arc(.{ .x = x0 + r, .y = y1 - r }, r, pi / 2.0, pi / 2.0, &buf));
    try out.append(a, .{ .line = .{ .{ .x = x0, .y = y1 - r }, .{ .x = x0, .y = y0 + r } } });
    try out.appendSlice(a, geom.arc(.{ .x = x0 + r, .y = y0 + r }, r, pi, pi / 2.0, &buf));
}

/// Adds a round-rect (the owner, 2026-11-28) in box `b`, corner radius `r`
/// (0: `startRadius`), about a centre point or not (`variant`): four sides
/// and four corner arcs as one library object. Its contract: each arc
/// joined to the sides either side of it and tangent to them (its
/// radius normal to each at their shared end), the arcs'
/// radii equal, three corners square (the fourth follows); about a centre,
/// the centre midway between opposite sides' ends. Its parameters `w`
/// (side to side), `h` (bottom to top) and `r` (corner radius). Held
/// level by its bottom side parallel to the sketch's x axis: a constraint
/// outside the object, removable to turn it.
pub fn addRoundRect(s: *Sketch, a: Allocator, variant: RoundRectVariant, b: geom.Box, r_in: f64, construction: bool) Error!GroupId {
    if (!(b.width() > 0) or !(b.height() > 0)) return error.WrongKind;
    const r = if (r_in > 0) @min(r_in, @min(b.width(), b.height()) / 2) else startRadius(b);
    if (!(r > 0)) return error.WrongKind;
    const x0 = b.x0;
    const x1 = b.x1;
    const y0 = b.y0;
    const y1 = b.y1;
    const first = s.geometry.items.len;
    _ = try s.addSegment(a, .{ .x = x0 + r, .y = y0 }, .{ .x = x1 - r, .y = y0 }, construction);
    _ = try s.addArc(a, .{ .x = x1 - r, .y = y0 + r }, .{ .x = x1 - r, .y = y0 }, .{ .x = x1, .y = y0 + r }, construction);
    _ = try s.addSegment(a, .{ .x = x1, .y = y0 + r }, .{ .x = x1, .y = y1 - r }, construction);
    _ = try s.addArc(a, .{ .x = x1 - r, .y = y1 - r }, .{ .x = x1, .y = y1 - r }, .{ .x = x1 - r, .y = y1 }, construction);
    _ = try s.addSegment(a, .{ .x = x1 - r, .y = y1 }, .{ .x = x0 + r, .y = y1 }, construction);
    _ = try s.addArc(a, .{ .x = x0 + r, .y = y1 - r }, .{ .x = x0 + r, .y = y1 }, .{ .x = x0, .y = y1 - r }, construction);
    _ = try s.addSegment(a, .{ .x = x0, .y = y1 - r }, .{ .x = x0, .y = y0 + r }, construction);
    _ = try s.addArc(a, .{ .x = x0 + r, .y = y0 + r }, .{ .x = x0, .y = y0 + r }, .{ .x = x0 + r, .y = y0 }, construction);
    if (variant == .centre) _ = try s.addPoint(a, .{ .x = (x0 + x1) / 2, .y = (y0 + y1) / 2 }, true);
    const at = struct {
        fn f(base: usize, k: u32) GeomId {
            return @intCast(base + k);
        }
    }.f;
    for (0..4) |i| {
        const side = at(first, @intCast(2 * i));
        const arc = at(first, @intCast(2 * i + 1));
        const next = at(first, @intCast((2 * i + 2) % 8));
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = side, .role = .end }, .{ .geom = arc, .role = .start } } } });
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = arc, .role = .end }, .{ .geom = next, .role = .start } } } });
        // Tangent where they join: the arc's radius to each end normal
        // to the side there.
        _ = try s.addConstraint(a, .{ .kind = .{ .normal = .{ .from = .{ .geom = arc, .role = .centre }, .to = .{ .geom = arc, .role = .start }, .line = side } } });
        _ = try s.addConstraint(a, .{ .kind = .{ .normal = .{ .from = .{ .geom = arc, .role = .centre }, .to = .{ .geom = arc, .role = .end }, .line = next } } });
    }
    const arcs = RoundRect.arcs;
    for (arcs[1..]) |k| _ = try s.addConstraint(a, .{ .kind = .{ .equal = .{ .a = at(first, arcs[0]), .b = at(first, k) } } });
    // Three corners square; the fourth follows from them (stated, it
    // would be redundant).
    for (0..3) |i| _ = try s.addConstraint(a, .{ .kind = .{ .perpendicular = .{ .a = at(first, @intCast(2 * i)), .b = at(first, @intCast(2 * i + 2)) } } });
    if (variant == .centre) {
        // The centre midway between the bottom side's start and the top
        // side's: with the sides square and the corners equal, in the
        // middle of the whole, which is mirrored about it.
        _ = try s.addConstraint(a, .{ .kind = .{ .symmetric = .{
            .p = .{ .geom = at(first, RoundRect.bottom), .role = .start },
            .q = .{ .geom = at(first, RoundRect.top), .role = .start },
            .point = .{ .geom = at(first, RoundRect.centre), .role = .point },
        } } });
    }
    var ids: std.ArrayList(GeomId) = .empty;
    defer ids.deinit(a);
    for (first..s.geometry.items.len) |g| try ids.append(a, @intCast(g));
    const id = try s.makeGroup(a, ids.items, &.{}, .library, true);
    try s.groups.setTypeName(a, id, round_rect);
    try s.groups.setProp(a, id, "construction", if (construction) 1 else 0);
    _ = try s.groups.addParam(a, id, "w", .length, .mm, .{ .kind = .{ .line_distance = .{ .p = .{ .geom = at(first, RoundRect.right), .role = .start }, .line = at(first, RoundRect.left), .value = 0 } } });
    _ = try s.groups.addParam(a, id, "h", .length, .mm, .{ .kind = .{ .line_distance = .{ .p = .{ .geom = at(first, RoundRect.top), .role = .start }, .line = at(first, RoundRect.bottom), .value = 0 } } });
    _ = try s.groups.addParam(a, id, "r", .length, .mm, .{ .kind = .{ .radius = .{ .g = at(first, arcs[0]), .value = 0 } } });
    // Level: outside the object (it names the sketch's axis), so it can
    // be removed to turn it.
    _ = try s.addConstraint(a, .{ .kind = .{ .parallel = .{ .a = at(first, RoundRect.bottom), .b = root.h_axis } } });
    return id;
}

// Arc ---------------------------------------------------------------------------

pub const arc_type = "arc";

/// Adds an arc as a library object (the owner, 2026-11-28: parameterized
/// arcs): about `c`, counter-clockwise from `p0` to `p1`'s angle. It has
/// no contract beyond its own (its ends on one circle); its parameters `r`
/// (its radius), `start` and `end` (its ends' directions from its centre,
/// counter-clockwise from the x axis). However it was placed (by its
/// centre, by three points, tangent to a line), it is the same object.
/// Returns its geometry; its object is that geometry's group.
pub fn addArc(s: *Sketch, a: Allocator, c: Point, p0: Point, p1: Point, construction: bool) Error!GeomId {
    const g = try s.addArc(a, c, p0, p1, construction);
    const id = try s.makeGroup(a, &.{g}, &.{}, .library, true);
    try s.groups.setTypeName(a, id, arc_type);
    _ = try s.groups.addParam(a, id, "r", .length, .mm, .{ .kind = .{ .radius = .{ .g = g, .value = 0 } } });
    _ = try s.groups.addParam(a, id, "start", .angle, .deg, .{ .kind = .{ .direction = .{ .a = .{ .geom = g, .role = .centre }, .b = .{ .geom = g, .role = .start }, .value = 0 } } });
    _ = try s.groups.addParam(a, id, "end", .angle, .deg, .{ .kind = .{ .direction = .{ .a = .{ .geom = g, .role = .centre }, .b = .{ .geom = g, .role = .end }, .value = 0 } } });
    return g;
}

/// The arc tangent at `p` to direction `t` (a unit vector, the way it
/// leaves `p`) that ends at `q`: its centre and its ends counter-clockwise
/// (`from_p`: it runs from `p`, else to it). Null when `q` is on the line.
pub fn tangentArc(p: Point, t: Point, q: Point) ?struct { c: Point, a: Point, b: Point, from_p: bool } {
    const n: Point = .{ .x = -t.y, .y = t.x };
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const along = n.x * dx + n.y * dy;
    if (@abs(along) < 1e-9 * @max(1, @sqrt(dx * dx + dy * dy))) return null;
    const rho = (dx * dx + dy * dy) / (2 * along);
    const c: Point = .{ .x = p.x + n.x * rho, .y = p.y + n.y * rho };
    // Turning left (centre to its left): counter-clockwise from p.
    return if (rho > 0) .{ .c = c, .a = p, .b = q, .from_p = true } else .{ .c = c, .a = q, .b = p, .from_p = false };
}

// Tests -------------------------------------------------------------------------

const testing = std.testing;

fn param(s: *const Sketch, id: GroupId, name: []const u8) !u32 {
    const g = try object(s, id);
    return (g.paramNamed(name) orelse return error.NoSuchParameter).id;
}

test "a round-rect: its contract leaves position, size and corner free; parameters measure, apply, follow a drag" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_]RoundRectVariant{ .corners, .centre }) |variant| {
        var s = try Sketch.init(gpa);
        defer s.deinit(gpa);
        const b = roundRectBox(variant, .{ .x = 10, .y = 5 }, .{ .x = 50, .y = 25 });
        const id = try addRoundRect(&s, gpa, variant, b, 0, false);
        _ = try s.solve(gpa);
        const an = try s.analyse(gpa, arena.allocator());
        // Free: x, y, w, h, r (its turn held by the level constraint).
        try testing.expectEqual(@as(usize, 5), an.dof);
        try testing.expectEqual(@as(usize, 0), an.redundant.len);
        try testing.expectEqual(@as(usize, 0), an.conflicting.len);
        // The level constraint is outside the object; its own inside.
        const g = try object(&s, id);
        try testing.expectEqualStrings(round_rect, g.type_name);
        try testing.expectEqual(group.none, s.constraints.items[s.constraints.items.len - 1].group);
        try testing.expectEqual(id, s.constraints.items[0].group);
        const w = try param(&s, id, "w");
        const h = try param(&s, id, "h");
        const r = try param(&s, id, "r");
        try testing.expectApproxEqAbs(b.width(), try value(&s, id, w), 1e-9);
        try testing.expectApproxEqAbs(b.height(), try value(&s, id, h), 1e-9);
        try testing.expectApproxEqAbs(b.height() / 5, try value(&s, id, r), 1e-9);
        // Applied: the others held.
        try apply(&s, gpa, gpa, id, w, 60);
        try testing.expectApproxEqAbs(60, try value(&s, id, w), 1e-6);
        try testing.expectApproxEqAbs(b.height(), try value(&s, id, h), 1e-6);
        try apply(&s, gpa, gpa, id, r, 3);
        try testing.expectApproxEqAbs(3, try value(&s, id, r), 1e-6);
        try testing.expectApproxEqAbs(60, try value(&s, id, w), 1e-6);
        // Not held after: a corner dragged out resizes it, the contract kept.
        const corner: PointRef = .{ .geom = @intCast(3 + RoundRect.right), .role = .start };
        const at = try s.point(corner);
        _ = try s.drag(gpa, gpa, corner, .{ .x = at.x + 8, .y = at.y });
        try testing.expect(try value(&s, id, w) > 60.5);
        const r1 = try value(&s, id, r);
        for (RoundRect.arcs) |k| {
            const ar = s.geometry.items[3 + k].kind.arc;
            const c = s.val(ar.c);
            const p = s.val(ar.a);
            try testing.expectApproxEqAbs(r1, std.math.hypot(p.x - c.x, p.y - c.y), 1e-6);
        }
        // A corner too round for its sides is refused, nothing changed.
        const before = try value(&s, id, h);
        try testing.expectError(error.Conflict, apply(&s, gpa, gpa, id, r, 100));
        try testing.expectApproxEqAbs(before, try value(&s, id, h), 1e-9);
    }
}

test "a round-rect about its centre stays centred when sized" {
    const gpa = testing.allocator;
    var s = try Sketch.init(gpa);
    defer s.deinit(gpa);
    const id = try addRoundRect(&s, gpa, .centre, roundRectBox(.centre, .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 10 }), 0, false);
    _ = try s.solve(gpa);
    // The centre held where it is, as the user would hold it.
    const c: PointRef = .{ .geom = 3 + RoundRect.centre, .role = .point };
    _ = try s.addConstraint(gpa, .{ .kind = .{ .coincident = .{ c, .{ .geom = root.origin, .role = .point } } } });
    _ = try s.solve(gpa);
    try apply(&s, gpa, gpa, id, try param(&s, id, "w"), 70);
    const right = s.val(s.geometry.items[3 + RoundRect.right].kind.segment.a);
    const left = s.val(s.geometry.items[3 + RoundRect.left].kind.segment.a);
    try testing.expectApproxEqAbs(35, right.x, 1e-6);
    try testing.expectApproxEqAbs(-35, left.x, 1e-6);
}

test "a dimension the user placed wins over a parameter; explode leaves ordinary geometry" {
    const gpa = testing.allocator;
    var s = try Sketch.init(gpa);
    defer s.deinit(gpa);
    const id = try addRoundRect(&s, gpa, .corners, .{ .x0 = 0, .y0 = 0, .x1 = 40, .y1 = 20 }, 4, false);
    _ = try s.solve(gpa);
    const w = try param(&s, id, "w");
    // Its width pinned by an ordinary dimension, outside the object's
    // contract (it names only its members, but is the user's).
    const g = try object(&s, id);
    const pin = try s.addConstraint(gpa, held(&s, g.param(w).?.measure, 40));
    // The user's, so outside the object: not part of its contract.
    try testing.expectEqual(group.none, s.constraints.items[pin].group);
    try testing.expect(!root.composite.sealedConstraint(&s, pin));
    _ = try s.solve(gpa);
    try testing.expectError(error.Conflict, apply(&s, gpa, gpa, id, w, 55));
    try testing.expectApproxEqAbs(40, try value(&s, id, w), 1e-9);
    // Its height still applies.
    try apply(&s, gpa, gpa, id, try param(&s, id, "h"), 30);
    try testing.expectApproxEqAbs(30, try value(&s, id, try param(&s, id, "h")), 1e-6);
    try s.removeConstraint(pin);
    // Exploded: no object, no parameters; the contract stays, ordinary.
    const n = s.constraints.items.len;
    try explode(&s, gpa, id);
    try testing.expectError(error.NoSuchGroup, s.groups.get(id));
    try testing.expectEqual(n, s.constraints.items.len);
    for (s.constraints.items) |c| try testing.expectEqual(group.none, c.group);
    for (s.geometry.items) |x| try testing.expectEqual(group.none, x.group);
    try testing.expect(root.composite.objectOf(&s, 3) == null);
    // Free of the old contract: one corner's radius alone may change now.
    try s.removeConstraint(0);
    _ = try s.solve(gpa);
}

test "an object of a type this Graven does not know is still measured and applied through its parameters" {
    const gpa = testing.allocator;
    var s = try Sketch.init(gpa);
    defer s.deinit(gpa);
    const seg = try s.addSegment(gpa, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, false);
    const id = try s.makeGroup(gpa, &.{seg}, &.{}, .library, true);
    try s.groups.setTypeName(gpa, id, "some-future-thing");
    const len = try s.groups.addParam(gpa, id, "len", .length, .mm, .{ .kind = .{ .distance = .{ .a = .{ .geom = seg, .role = .start }, .b = .{ .geom = seg, .role = .end }, .value = 0 } } });
    try testing.expectError(error.NameTaken, s.groups.addParam(gpa, id, "len", .length, .mm, .{ .kind = .{ .radius = .{ .g = seg, .value = 0 } } }));
    try testing.expectApproxEqAbs(10, try value(&s, id, len), 1e-9);
    try apply(&s, gpa, gpa, id, len, 25);
    try testing.expectApproxEqAbs(25, try value(&s, id, len), 1e-6);
    // A copy (as undo keeps) has the same parameters, the same IDs.
    var c = try s.clone(gpa);
    defer {
        c.deinit(gpa);
    }
    try testing.expectApproxEqAbs(25, try value(&c, id, len), 1e-6);
}

test "an arc as a library object: radius, start and end applied one at a time, a user dimension outside it" {
    const gpa = testing.allocator;
    var s = try Sketch.init(gpa);
    defer s.deinit(gpa);
    const g = try addArc(&s, gpa, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 10 }, false);
    _ = try s.solve(gpa);
    const id = s.geometry.items[g].group;
    try testing.expectEqualStrings(arc_type, (try object(&s, id)).type_name);
    const r = try param(&s, id, "r");
    const start = try param(&s, id, "start");
    const end = try param(&s, id, "end");
    try testing.expectApproxEqAbs(10, try value(&s, id, r), 1e-9);
    try testing.expectApproxEqAbs(0, try value(&s, id, start), 1e-9);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, try value(&s, id, end), 1e-9);
    // The end swung round to 200 degrees, past a half turn: start and
    // radius held.
    try apply(&s, gpa, gpa, id, end, std.math.degreesToRadians(200));
    try testing.expectApproxEqAbs(std.math.degreesToRadians(200), try value(&s, id, end), 1e-6);
    try testing.expectApproxEqAbs(0, try value(&s, id, start), 1e-6);
    try testing.expectApproxEqAbs(10, try value(&s, id, r), 1e-6);
    try apply(&s, gpa, gpa, id, r, 4);
    try testing.expectApproxEqAbs(4, try value(&s, id, r), 1e-6);
    try testing.expectApproxEqAbs(std.math.degreesToRadians(200), try value(&s, id, end), 1e-6);
    // A radius dimension the user puts on it is the user's, not its own.
    const dim = try s.addConstraint(gpa, .{ .kind = .{ .radius = .{ .g = g, .value = 4 } } });
    try testing.expect(!root.composite.sealedConstraint(&s, dim));
    try testing.expect(!root.composite.sealsConstraint(&s, s.constraints.items[dim]));
    try testing.expectError(error.Conflict, apply(&s, gpa, gpa, id, r, 6));
}

test "a tangent arc leaves a line's end along it, turning either way" {
    const left = tangentArc(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 10, .y = 10 }).?;
    try testing.expect(left.from_p);
    try testing.expectApproxEqAbs(0, left.c.x, 1e-9);
    try testing.expectApproxEqAbs(10, left.c.y, 1e-9);
    const right = tangentArc(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 10, .y = -10 }).?;
    try testing.expect(!right.from_p);
    try testing.expectApproxEqAbs(-10, right.c.y, 1e-9);
    try testing.expect(tangentArc(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 }) == null);
}
