//! Composite objects (the owner, 2026-11-26): regular polygons and arrays
//! made as sealed groups (`constraint.group`) of a kind, holding their
//! construction properties. Their geometry and constraints are the
//! ordinary ones (`polygon.zig`, `arrays.zig`), in the sketch's one solve;
//! the group says they are one object, what kind, and how it was made.
//!
//! Changing a property (`setProp`: five sides to six, eight columns to
//! twelve) makes the object again where it is now, in the same group.
//! Constraints from outside to its geometry are carried over to the
//! geometry that plays the same part (the centre, the first side, the
//! outer ring, the right edge); those on parts that are gone are dropped,
//! and counted. `Remap` says which old geometry became which, for what
//! the sketch's users hold (an array grid's parts, inks, a caption's
//! point).

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");
const polygon = @import("polygon.zig");
const arrays = @import("arrays.zig");
const connector = @import("connector.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const Constraint = root.Constraint;
const group = root.group;
const GroupId = group.GroupId;

pub const Error = root.Error || group.Error || error{NotAnObject};

/// Old geometry to new, after an object is made again (`to` null: gone).
pub const Remap = struct {
    pairs: std.ArrayList(struct { from: GeomId, to: ?GeomId }) = .empty,
    /// Constraints from outside dropped, their part being gone.
    dropped: usize = 0,

    pub fn deinit(r: *Remap, a: Allocator) void {
        r.pairs.deinit(a);
    }

    pub fn get(r: *const Remap, g: GeomId) ?GeomId {
        for (r.pairs.items) |p| if (p.from == g) return p.to;
        return g;
    }

    /// Whether geometry `g` was part of the object made again.
    pub fn moved(r: *const Remap, g: GeomId) bool {
        for (r.pairs.items) |p| if (p.from == g) return true;
        return false;
    }
};

fn since(s: *const Sketch, a: Allocator, first: usize) Allocator.Error![]GeomId {
    var out: std.ArrayList(GeomId) = .empty;
    for (first..s.geometry.items.len) |g| try out.append(a, @intCast(g));
    return out.toOwnedSlice(a);
}

fn seal(s: *Sketch, a: Allocator, first: usize, kind: group.Kind) Error!GroupId {
    const ids = try since(s, a, first);
    defer a.free(ids);
    return s.makeGroup(a, ids, &.{}, kind, true);
}

/// A regular polygon (`polygon.addRegular`) as an object.
pub fn addPolygon(s: *Sketch, a: Allocator, c: Point, corner: Point, n: u32, construction: bool) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try polygon.addRegular(s, a, c, corner, n, construction);
    const id = try seal(s, a, first, .regular_polygon);
    try s.groups.setProp(a, id, "sides", @floatFromInt(n));
    try s.groups.setProp(a, id, "construction", if (construction) 1 else 0);
    return id;
}

/// A polar array (`arrays.addPolar`) as an object.
pub fn addPolar(s: *Sketch, a: Allocator, c: Point, r: f64, first_angle: f64, sweep: f64, cols: u32, rings: u32) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try arrays.addPolar(s, a, c, r, first_angle, sweep, cols, rings);
    const id = try seal(s, a, first, .polar_array);
    try s.groups.setProp(a, id, "columns", @floatFromInt(cols));
    try s.groups.setProp(a, id, "rings", @floatFromInt(rings));
    try s.groups.setProp(a, id, "sweep", @min(sweep, 2 * std.math.pi));
    return id;
}

/// A rectangular array (`arrays.addRect`) as an object.
pub fn addRect(s: *Sketch, a: Allocator, b: geom.Box, cols: u32, rows: u32) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try arrays.addRect(s, a, b, cols, rows);
    const id = try seal(s, a, first, .rect_array);
    try s.groups.setProp(a, id, "columns", @floatFromInt(cols));
    try s.groups.setProp(a, id, "rows", @floatFromInt(rows));
    return id;
}

fn count(g: *const group.Group, name: []const u8) u32 {
    return @intFromFloat(@max(0, @round(g.prop(name) orelse 0)));
}

/// The part a member plays, which survives a change of counts: a tag and
/// an index (`last` for the last of a run, which stays the last).
const Role = struct {
    tag: u8,
    i: u32 = 0,
};

const last: u32 = std.math.maxInt(u32);

/// Each member's role, in the order the builder made them.
fn roles(s: *const Sketch, a: Allocator, g: *const group.Group) Error![]Role {
    var out: std.ArrayList(Role) = .empty;
    errdefer out.deinit(a);
    switch (g.kind) {
        .regular_polygon => {
            const n = count(g, "sides");
            try out.append(a, .{ .tag = 0 }); // the circle through the corners
            for (0..n) |i| try out.append(a, .{ .tag = 1, .i = @intCast(i) });
            try out.append(a, .{ .tag = 2 }); // the inscribed circle
        },
        .rect_array => {
            const cols = count(g, "columns");
            const rows = count(g, "rows");
            for (0..cols + 1) |i| try out.append(a, if (i == 0) .{ .tag = 0 } else if (i == cols) .{ .tag = 1 } else .{ .tag = 2, .i = @intCast(i) });
            for (0..rows + 1) |j| try out.append(a, if (j == 0) .{ .tag = 3 } else if (j == rows) .{ .tag = 4 } else .{ .tag = 5, .i = @intCast(j) });
        },
        .polar_array => {
            const cols = count(g, "columns");
            const rings = count(g, "rings");
            const full = (g.prop("sweep") orelse 0) >= 2 * std.math.pi - 1e-9;
            const lines: u32 = if (full) cols else cols + 1;
            try out.append(a, .{ .tag = 0 }); // the centre
            for (0..lines) |i| try out.append(a, if (!full and i == lines - 1) .{ .tag = 1, .i = last } else .{ .tag = 1, .i = @intCast(i) });
            for (1..rings + 1) |k| {
                if (k == rings) {
                    try out.append(a, .{ .tag = 2, .i = last }); // the outer ring
                } else {
                    try out.append(a, .{ .tag = 2, .i = @intCast(k) });
                    if (full) try out.append(a, .{ .tag = 3, .i = @intCast(k) }); // its mark
                }
            }
        },
        else => return error.NotAnObject,
    }
    _ = s;
    return out.toOwnedSlice(a);
}

/// Where the object is now, to make it again there.
const Placement = union(enum) {
    polygon: struct { c: Point, corner: Point },
    polar: struct { c: Point, r: f64, first: f64 },
    rect: geom.Box,
};

fn placement(s: *const Sketch, g: *const group.Group) Error!Placement {
    const m = g.geometry.items;
    switch (g.kind) {
        .regular_polygon => {
            if (m.len < 2) return error.NotAnObject;
            return .{ .polygon = .{ .c = try s.point(.{ .geom = m[0], .role = .centre }), .corner = try s.point(.{ .geom = m[1], .role = .start }) } };
        },
        .polar_array => {
            if (m.len < 2) return error.NotAnObject;
            const c = try s.point(.{ .geom = m[0] });
            const e = try s.point(.{ .geom = m[1], .role = .end });
            return .{ .polar = .{ .c = c, .r = std.math.hypot(e.x - c.x, e.y - c.y), .first = std.math.atan2(e.y - c.y, e.x - c.x) } };
        },
        .rect_array => {
            const cols = count(g, "columns");
            if (m.len < cols + 1) return error.NotAnObject;
            const tl = try s.point(.{ .geom = m[0], .role = .start });
            const br = try s.point(.{ .geom = m[cols], .role = .end });
            return .{ .rect = .{ .x0 = @min(tl.x, br.x), .x1 = @max(tl.x, br.x), .y0 = @min(tl.y, br.y), .y1 = @max(tl.y, br.y) } };
        },
        else => return error.NotAnObject,
    }
}

/// Object `id`'s array parts by ID (for an array grid), as made.
pub fn arrayRefs(s: *const Sketch, id: GroupId) Error!arrays.Refs {
    const g = try s.groups.get(id);
    const m = g.geometry.items;
    switch (g.kind) {
        .polar_array => {
            const cols = count(g, "columns");
            const full = (g.prop("sweep") orelse 0) >= 2 * std.math.pi - 1e-9;
            const lines: u32 = if (full) cols else cols + 1;
            if (m.len < lines + 2) return error.NotAnObject;
            return .{ .polar = .{ .centre = m[0], .first = m[1], .second = m[1 + (1 % lines)], .outer = m[m.len - 1] } };
        },
        .rect_array => {
            const cols = count(g, "columns");
            const rows = count(g, "rows");
            if (m.len < cols + rows + 2) return error.NotAnObject;
            return .{ .rect = .{ .left = m[0], .right = m[cols], .top = m[cols + 1], .bottom = m[cols + 1 + rows] } };
        },
        else => return error.NotAnObject,
    }
}

/// The object directly holding geometry `g`, if any (the outermost sealed
/// group round it).
pub fn objectOf(s: *const Sketch, g: GeomId) ?GroupId {
    if (g >= s.geometry.items.len) return null;
    const at = s.groups.objectOf(s.geometry.items[g].group);
    return if (at == group.none) null else at;
}

// Sealing (the owner, 2026-11-26): an object's members and its own
// constraints are not edited one by one; only its properties, the
// transforms it leaves free, and constraints from its parts to what is
// outside it. These say what that rule refuses; the editor applies it.

/// Geometry `g` is a member of an object (directly or deeper).
pub fn sealedGeometry(s: *const Sketch, g: GeomId) bool {
    return objectOf(s, g) != null;
}

/// Constraint `c` is internal to an object.
pub fn sealedConstraint(s: *const Sketch, c: root.ConstraintId) bool {
    if (c >= s.constraints.items.len) return false;
    return s.groups.objectOf(s.constraints.items[c].group) != group.none;
}

/// Constraint `c`, added, would be internal to an object: everything it
/// names is in one. One naming something outside too is external.
pub fn sealsConstraint(s: *const Sketch, c: Constraint) bool {
    return s.groups.objectOf(s.groups.home(s.geometry.items, c)) != group.none;
}

/// Removes object (or group) `id` whole: every member, the constraints on
/// them (its own and outside ones), and the group with those inside it.
pub fn removeObject(s: *Sketch, a: Allocator, id: GroupId) Error!void {
    var geoms: std.ArrayList(GeomId) = .empty;
    defer geoms.deinit(a);
    try s.groups.internalGeometry(a, id, &geoms);
    for (geoms.items) |g| {
        if (g < s.geometry.items.len and !s.geometry.items[g].removed and !s.geometry.items[g].reference) try s.removeGeometry(g);
    }
    try s.groups.remove(a, id);
}

/// Sets construction property `name` of object `id` to `value` and makes
/// it again, where it is (see the file's comment). What became of its old
/// geometry goes in `remap`. `a` is the sketch's own allocator (its lists
/// grow in it), used for scratch too.
pub fn setProp(s: *Sketch, a: Allocator, id: GroupId, name: []const u8, value: f64, remap: *Remap) Error!void {
    const g = try s.groups.get(id);
    if (g.kind == .plain or g.kind == .connection or g.kind == .caption) return error.NotAnObject;
    const kind = g.kind;
    const where = try placement(s, g);
    const old_roles = try roles(s, a, g);
    defer a.free(old_roles);
    const old = try a.dupe(GeomId, g.geometry.items);
    defer a.free(old);
    if (old.len != old_roles.len) return error.NotAnObject;

    // Constraints from outside on its geometry, to carry over.
    var outside: std.ArrayList(Constraint) = .empty;
    defer outside.deinit(a);
    for (s.constraints.items) |c| {
        if (s.groups.within(c.group, id)) continue;
        for (old) |m| if (root.refersTo(c, m)) {
            try outside.append(a, c);
            break;
        };
    }

    try s.groups.setProp(a, id, name, value);
    const gg = try s.groups.get(id);
    // The new counts must make an object; else nothing changes.
    const ok = switch (kind) {
        .regular_polygon => count(gg, "sides") >= 3,
        .rect_array => count(gg, "columns") >= 1 and count(gg, "rows") >= 1,
        .polar_array => count(gg, "columns") >= 1 and count(gg, "rings") >= 1 and (gg.prop("sweep") orelse 0) > 0,
        else => false,
    };
    if (!ok) return error.WrongKind;

    try s.groups.release(s.geometry.items, id);
    for (old) |m| try s.removeGeometry(m);

    const first = s.geometry.items.len;
    switch (where) {
        .polygon => |p| _ = try polygon.addRegular(s, a, p.c, p.corner, count(gg, "sides"), (gg.prop("construction") orelse 0) != 0),
        .polar => |p| _ = try arrays.addPolar(s, a, p.c, p.r, p.first, gg.prop("sweep").?, count(gg, "columns"), count(gg, "rings")),
        .rect => |b| _ = try arrays.addRect(s, a, b, count(gg, "columns"), count(gg, "rows")),
    }
    const made = try since(s, a, first);
    defer a.free(made);
    try s.groups.adopt(a, s.geometry.items, s.constraints.items, id, made);
    const new_roles = try roles(s, a, try s.groups.get(id));
    defer a.free(new_roles);

    for (old, old_roles) |m, r| {
        var to: ?GeomId = null;
        for (made, new_roles) |n, q| if (q.tag == r.tag and q.i == r.i) {
            to = n;
            break;
        };
        try remap.pairs.append(a, .{ .from = m, .to = to });
    }
    // The constraints from outside, on the new parts.
    for (outside.items) |c_in| {
        var c = c_in;
        if (!root.geometry.mapGeoms(&c, remap, mapOne)) {
            remap.dropped += 1;
            continue;
        }
        _ = s.addConstraint(a, c) catch {
            remap.dropped += 1;
        };
    }
    // Connections attached to its parts.
    for (s.connectors.items) |*k| {
        switch (k.from) {
            .point => |*p| p.geom = remap.get(p.geom) orelse p.geom,
            .curve => |*cv| cv.* = remap.get(cv.*) orelse cv.*,
            .free => {},
        }
        if (k.normal) |n| k.normal = remap.get(n) orelse n;
    }
}

fn mapOne(r: *Remap, g: GeomId) ?GeomId {
    return r.get(g);
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

test "a polygon is an object; more sides make it again in place, outside constraints carried over" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const id = try addPolygon(&s, al, .{ .x = 5, .y = 5 }, .{ .x = 15, .y = 5 }, 5, false);
    const g = try s.groups.get(id);
    try testing.expect(g.sealed);
    try testing.expectEqual(group.Kind.regular_polygon, g.kind);
    try testing.expectEqual(@as(?f64, 5), g.prop("sides"));
    // Its centre held to the origin from outside: an external constraint.
    const circle = g.geometry.items[0];
    _ = try s.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = circle, .role = .centre }, .{ .geom = root.origin } } } });
    try testing.expectEqual(group.none, s.constraints.items[s.constraints.items.len - 1].group);
    _ = try s.solve(al);
    try testing.expectEqual(id, objectOf(&s, g.geometry.items[3]).?);

    var remap: Remap = .{};
    try setProp(&s, al, id, "sides", 6, &remap);
    const g6 = try s.groups.get(id);
    try testing.expectEqual(@as(usize, 6 + 2), g6.geometry.items.len);
    try testing.expectEqual(@as(usize, 0), remap.dropped);
    const new_circle = remap.get(circle).?;
    try testing.expect(new_circle != circle);
    _ = try s.solve(al);
    const c = try s.point(.{ .geom = new_circle, .role = .centre });
    try testing.expectApproxEqAbs(0, c.x, 1e-6);
    try testing.expectApproxEqAbs(0, c.y, 1e-6);
    // Still fully its own: its constraints are internal, the origin's not.
    var inside: usize = 0;
    for (s.constraints.items) |k| {
        if (k.group == id) inside += 1;
    }
    try testing.expect(inside > 6);
    const an = try s.analyse(al, al);
    try testing.expectEqual(@as(usize, 0), an.conflicting.len);
    try testing.expectEqual(@as(usize, 0), an.redundant.len);
}

test "arrays as objects: counts changed in place, their parts found again" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const p = try addPolar(&s, al, .{ .x = 0, .y = 0 }, 20, std.math.pi / 2.0, 2 * std.math.pi, 8, 2);
    const q = try addRect(&s, al, .{ .x0 = 30, .y0 = 0, .x1 = 60, .y1 = 20 }, 3, 2);
    _ = try s.solve(al);
    var remap: Remap = .{};
    try setProp(&s, al, p, "columns", 12, &remap);
    try setProp(&s, al, q, "rows", 4, &remap);
    _ = try s.solve(al);
    const cp = try arrays.cells(&s, try arrayRefs(&s, p));
    try testing.expectApproxEqAbs(2 * std.math.pi / 12.0, cp.polar.step, 1e-6);
    try testing.expectApproxEqAbs(20, cp.polar.r, 1e-6);
    const cq = try arrays.cells(&s, try arrayRefs(&s, q));
    try testing.expectApproxEqAbs(30, cq.rect.x1 - cq.rect.x0, 1e-6);
    try testing.expectApproxEqAbs(20, cq.rect.y1 - cq.rect.y0, 1e-6);
    try testing.expectEqual(@as(?f64, 4), (try s.groups.get(q)).prop("rows"));
}

test "a sealed object: its members and own constraints refused one by one, removed whole" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const id = try addPolygon(&s, al, .{ .x = 5, .y = 5 }, .{ .x = 15, .y = 5 }, 5, false);
    const g = try s.groups.get(id);
    const side = g.geometry.items[1];
    const other = g.geometry.items[2];
    try testing.expect(sealedGeometry(&s, side));
    try testing.expect(sealedConstraint(&s, g.constraints.items[0]));
    // Inside it: refused. To the origin: external.
    try testing.expect(sealsConstraint(&s, .{ .kind = .{ .parallel = .{ .a = side, .b = other } } }));
    try testing.expect(!sealsConstraint(&s, .{ .kind = .{ .coincident = .{ .{ .geom = side, .role = .start }, .{ .geom = root.origin } } } }));
    _ = try s.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = side, .role = .start }, .{ .geom = root.origin } } } });
    const before = s.constraints.items.len;
    try removeObject(&s, al, id);
    for (s.geometry.items[side..]) |x| try testing.expect(x.removed);
    try testing.expect(s.constraints.items.len < before);
    try testing.expectError(error.NoSuchGroup, s.groups.get(id));
    try testing.expect(!sealedGeometry(&s, side));
}
