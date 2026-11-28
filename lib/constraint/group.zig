//! Groups: a tree over geometry and constraints (the owner, 2026-11-26).
//!
//! A group holds geometry, constraints and other groups. A composite
//! object (a regular polygon, an array, a connection, a caption) is a
//! sealed group of a kind, with that kind's construction properties: its
//! members are internal, edited only through those properties and the
//! transforms they leave free. Deconstructing it opens the group (its
//! members editable, still together); regrouping seals it again;
//! ungrouping removes the group, its members joining its parent.
//!
//! Grouping is two-way, and quick either way (the owner, 2026-11-26):
//!
//! - a group lists its own geometry, constraints and child groups;
//! - each geometry and each constraint names the innermost group holding
//!   it (`Geometry.group`, `Constraint.group`), so its peers are that
//!   group's members and its other groups are found up the parents.
//!
//! The groups form a tree: a primitive is in one innermost group and in
//! that group's ancestors, never in two groups side by side. A constraint
//! is in the innermost group holding all the geometry it names (the
//! reference geometry, the origin and axes, is in none), so one between a
//! member and anything outside belongs to the level outside: an external
//! constraint, editable there.
//!
//! Only the primitives' side is saved: a group's member lists are rebuilt
//! from it (`rebuild`), so the two directions cannot disagree in a file.
//! Every change goes through this file, which keeps both.
//!
//! Members stay in their sketch's one solve: sealing is an editing rule,
//! not a solve of its own (the owner, 2026-11-26).

const std = @import("std");
const geometry = @import("geometry.zig");

const Allocator = std.mem.Allocator;
const Geometry = geometry.Geometry;
const Constraint = geometry.Constraint;
const GeomId = geometry.GeomId;
const ConstraintId = geometry.ConstraintId;

pub const GroupId = geometry.GroupId;
pub const none = geometry.no_group;

/// What a group was made as.
pub const Kind = enum {
    /// Grouped by hand (or a composite whose shape no longer holds).
    plain,
    regular_polygon,
    rect_array,
    polar_array,
    /// A polar grid, a macro object: one `geometry.PolarGrid`, its counts
    /// properties (`columns`, `rings`).
    polar_grid,
    /// A tessellation, a macro object: one `geometry.Tessellation`, its
    /// tile's sides and `whole` properties.
    tessellation,
    connection,
    caption,
};

/// A construction property: sides, columns, rings, sweep (radians) …
pub const Prop = struct {
    name: []const u8,
    value: f64,
};

/// What its transforms are relative to: an origin and a direction
/// (radians from the x axis). A plain group's is its own; a composite's
/// comes from its geometry (its centre, its first corner), and this is
/// unused.
pub const Frame = struct {
    x: f64 = 0,
    y: f64 = 0,
    angle: f64 = 0,
};

pub const Group = struct {
    parent: GroupId = none,
    kind: Kind = .plain,
    /// An object (members not editable) rather than an open group.
    sealed: bool = false,
    /// Ungrouped: kept so IDs hold, holding nothing.
    removed: bool = false,
    props: std.ArrayList(Prop) = .empty,
    frame: Frame = .{},
    /// Its own members (not those of its child groups). Rebuilt from the
    /// primitives, never saved.
    geometry: std.ArrayList(GeomId) = .empty,
    constraints: std.ArrayList(ConstraintId) = .empty,
    children: std.ArrayList(GroupId) = .empty,

    pub const unsaved = .{ "geometry", "constraints", "children" };

    /// A construction property's value, if it has it.
    pub fn prop(g: *const Group, name: []const u8) ?f64 {
        for (g.props.items) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }
};

pub const Error = Allocator.Error || error{ NoSuchGroup, NotSiblings, Sealed };

pub const Groups = struct {
    list: std.ArrayList(Group) = .empty,

    pub fn deinit(gs: *Groups, a: Allocator) void {
        for (gs.list.items) |*g| freeGroup(g, a);
        gs.list.deinit(a);
    }

    fn freeGroup(g: *Group, a: Allocator) void {
        for (g.props.items) |p| a.free(p.name);
        g.props.deinit(a);
        g.geometry.deinit(a);
        g.constraints.deinit(a);
        g.children.deinit(a);
    }

    /// A copy in `a`, sharing nothing with this one.
    pub fn clone(gs: *const Groups, a: Allocator) Allocator.Error!Groups {
        var c: Groups = .{};
        errdefer c.deinit(a);
        for (gs.list.items) |g| {
            try c.list.append(a, .{ .parent = g.parent, .kind = g.kind, .sealed = g.sealed, .removed = g.removed, .frame = g.frame });
            const at = &c.list.items[c.list.items.len - 1];
            for (g.props.items) |p| try at.props.append(a, .{ .name = try a.dupe(u8, p.name), .value = p.value });
            try at.geometry.appendSlice(a, g.geometry.items);
            try at.constraints.appendSlice(a, g.constraints.items);
            try at.children.appendSlice(a, g.children.items);
        }
        return c;
    }

    pub fn get(gs: *const Groups, id: GroupId) Error!*Group {
        if (id == none or id >= gs.list.items.len or gs.list.items[id].removed) return error.NoSuchGroup;
        return &gs.list.items[id];
    }

    /// The group directly holding group `id` (`none` at the top).
    pub fn parentOf(gs: *const Groups, id: GroupId) GroupId {
        if (id == none or id >= gs.list.items.len) return none;
        return gs.list.items[id].parent;
    }

    /// Whether group `inner` is `outer` or inside it.
    pub fn within(gs: *const Groups, inner: GroupId, outer: GroupId) bool {
        if (outer == none) return true;
        var at = inner;
        while (at != none) : (at = gs.parentOf(at)) if (at == outer) return true;
        return false;
    }

    /// The outermost sealed group holding group `id`, or `id` itself when
    /// sealed and in none (`none` when nothing round it is sealed): the
    /// object a click on its member chooses.
    pub fn objectOf(gs: *const Groups, id: GroupId) GroupId {
        var found: GroupId = none;
        var at = id;
        while (at != none) : (at = gs.parentOf(at)) {
            if (gs.list.items[at].sealed) found = at;
        }
        return found;
    }

    fn depth(gs: *const Groups, id: GroupId) usize {
        var n: usize = 0;
        var at = id;
        while (at != none) : (at = gs.parentOf(at)) n += 1;
        return n;
    }

    /// The innermost group holding both `x` and `y`.
    pub fn common(gs: *const Groups, x: GroupId, y: GroupId) GroupId {
        var a_ = x;
        var b_ = y;
        var da = gs.depth(a_);
        var db = gs.depth(b_);
        while (da > db) : (da -= 1) a_ = gs.parentOf(a_);
        while (db > da) : (db -= 1) b_ = gs.parentOf(b_);
        while (a_ != b_) {
            a_ = gs.parentOf(a_);
            b_ = gs.parentOf(b_);
        }
        return a_;
    }

    /// The group constraint `c` belongs in: the innermost holding all the
    /// geometry it names.
    pub fn home(gs: *const Groups, geo: []const Geometry, c: Constraint) GroupId {
        var buf: [4]geometry.Ref = undefined;
        const rs = geometry.refs(c, &buf);
        if (rs.len == 0) return none;
        var at: GroupId = groupOfRef(geo, rs[0]);
        for (rs[1..]) |r| at = gs.common(at, groupOfRef(geo, r));
        return at;
    }

    fn groupOfRef(geo: []const Geometry, r: geometry.Ref) GroupId {
        const g = switch (r) {
            .point => |p| p.geom,
            .geom => |g| g,
        };
        return if (g < geo.len) geo[g].group else none;
    }

    fn listOf(gs: *Groups, id: GroupId) ?*Group {
        return if (id == none or id >= gs.list.items.len) null else &gs.list.items[id];
    }

    fn take(list: anytype, v: anytype) void {
        for (list.items, 0..) |x, i| if (x == v) {
            _ = list.orderedRemove(i);
            return;
        };
    }

    /// Makes a group of geometry `geoms` and groups `groups`, all directly
    /// in one group (or none), as a child of it. Constraints there that
    /// now name only the new group's geometry move into it. Returns its ID.
    pub fn make(gs: *Groups, a: Allocator, geo: []Geometry, cons: []Constraint, geoms: []const GeomId, groups: []const GroupId, kind: Kind, sealed: bool) Error!GroupId {
        var parent: ?GroupId = null;
        for (geoms) |g| {
            const p = geo[g].group;
            if (parent) |q| {
                if (q != p) return error.NotSiblings;
            } else parent = p;
        }
        for (groups) |g| {
            _ = try gs.get(g);
            const p = gs.parentOf(g);
            if (parent) |q| {
                if (q != p) return error.NotSiblings;
            } else parent = p;
        }
        const up = parent orelse none;
        const id: GroupId = @intCast(gs.list.items.len);
        try gs.list.append(a, .{ .parent = up, .kind = kind, .sealed = sealed });
        if (gs.listOf(up)) |p| try p.children.append(a, id);
        const me = &gs.list.items[id];
        for (geoms) |g| {
            if (gs.listOf(up)) |p| take(&p.geometry, g);
            geo[g].group = id;
            try me.geometry.append(a, g);
        }
        for (groups) |g| {
            if (gs.listOf(up)) |p| take(&p.children, g);
            gs.list.items[g].parent = id;
            try me.children.append(a, g);
        }
        // Constraints at the parent's level that are now wholly inside.
        for (cons, 0..) |*c, ci| if (c.group == up) {
            const h = gs.home(geo, c.*);
            if (h != up) {
                if (gs.listOf(up)) |p| take(&p.constraints, @as(ConstraintId, @intCast(ci)));
                c.group = h;
                try gs.list.items[h].constraints.append(a, @intCast(ci));
            }
        };
        return id;
    }

    /// Puts geometry `geoms` (wherever they are) directly in group `id`,
    /// and every constraint naming them where it now belongs: how a
    /// composite object is filled again when rebuilt.
    pub fn adopt(gs: *Groups, a: Allocator, geo: []Geometry, cons: []Constraint, id: GroupId, geoms: []const GeomId) Error!void {
        _ = try gs.get(id);
        for (geoms) |g| {
            if (gs.listOf(geo[g].group)) |p| take(&p.geometry, g);
            geo[g].group = id;
            try gs.list.items[id].geometry.append(a, g);
        }
        for (cons, 0..) |*c, ci| {
            var touches = false;
            for (geoms) |g| if (geometry.refersTo(c.*, g)) {
                touches = true;
                break;
            };
            if (!touches) continue;
            const h = gs.home(geo, c.*);
            if (h == c.group) continue;
            if (gs.listOf(c.group)) |p| take(&p.constraints, @as(ConstraintId, @intCast(ci)));
            c.group = h;
            if (gs.listOf(h)) |p| try p.constraints.append(a, @intCast(ci));
        }
    }

    /// Takes group `id`'s own geometry out of it, into no group (before
    /// it is removed and made again).
    pub fn release(gs: *Groups, geo: []Geometry, id: GroupId) Error!void {
        const g = try gs.get(id);
        for (g.geometry.items) |m| geo[m].group = none;
        g.geometry.clearRetainingCapacity();
    }

    /// Removes group `id`: its geometry, constraints and groups join its
    /// parent. Its ID stays taken.
    pub fn ungroup(gs: *Groups, a: Allocator, geo: []Geometry, cons: []Constraint, id: GroupId) Error!void {
        const g = try gs.get(id);
        const up = g.parent;
        for (g.geometry.items) |m| {
            geo[m].group = up;
            if (gs.listOf(up)) |p| try p.geometry.append(a, m);
        }
        for (g.constraints.items) |m| {
            cons[m].group = up;
            if (gs.listOf(up)) |p| try p.constraints.append(a, m);
        }
        for (g.children.items) |m| {
            gs.list.items[m].parent = up;
            if (gs.listOf(up)) |p| try p.children.append(a, m);
        }
        if (gs.listOf(up)) |p| take(&p.children, id);
        const at = &gs.list.items[id];
        freeGroup(at, a);
        at.* = .{ .parent = none, .removed = true };
    }

    /// Removes group `id` and every group inside it (their geometry is
    /// the caller's to remove). Their IDs stay taken.
    pub fn remove(gs: *Groups, a: Allocator, id: GroupId) Error!void {
        const g = try gs.get(id);
        if (gs.listOf(g.parent)) |p| take(&p.children, id);
        gs.drop(a, id);
    }

    fn drop(gs: *Groups, a: Allocator, id: GroupId) void {
        const kids = gs.list.items[id].children.items;
        for (kids) |c| gs.drop(a, c);
        const at = &gs.list.items[id];
        freeGroup(at, a);
        at.* = .{ .parent = none, .removed = true };
    }

    /// Deconstructs object `id`: its members become editable, still
    /// together; its kind and properties are kept as what it was made as.
    pub fn open(gs: *Groups, id: GroupId) Error!void {
        (try gs.get(id)).sealed = false;
    }

    /// Seals group `id` again: as its kind when `holds` (its kind's
    /// constraints all still hold: the caller checks), else as an object
    /// of no kind (the owner, 2026-11-26).
    pub fn seal(gs: *Groups, id: GroupId, holds: bool) Error!void {
        const g = try gs.get(id);
        g.sealed = true;
        if (!holds) g.kind = .plain;
    }

    pub fn setProp(gs: *Groups, a: Allocator, id: GroupId, name: []const u8, value: f64) Error!void {
        const g = try gs.get(id);
        for (g.props.items) |*p| if (std.mem.eql(u8, p.name, name)) {
            p.value = value;
            return;
        };
        try g.props.append(a, .{ .name = try a.dupe(u8, name), .value = value });
    }

    /// Geometry `g` was added inside group `id` (a builder's, for one).
    pub fn addGeometry(gs: *Groups, a: Allocator, geo: []Geometry, g: GeomId, id: GroupId) Error!void {
        if (id != none) _ = try gs.get(id);
        if (gs.listOf(geo[g].group)) |p| take(&p.geometry, g);
        geo[g].group = id;
        if (gs.listOf(id)) |p| try p.geometry.append(a, g);
    }

    /// Constraint `c`, just added (the last), is put where it belongs.
    pub fn constraintAdded(gs: *Groups, a: Allocator, geo: []const Geometry, cons: []Constraint, c: ConstraintId) Allocator.Error!void {
        const h = gs.home(geo, cons[c]);
        cons[c].group = h;
        if (gs.listOf(h)) |p| try p.constraints.append(a, c);
    }

    /// Constraint `c` (in group `in`) is about to be removed from the
    /// list, so the IDs after it come down by one.
    pub fn constraintRemoved(gs: *Groups, in: GroupId, c: ConstraintId) void {
        if (gs.listOf(in)) |p| take(&p.constraints, c);
        for (gs.list.items) |*g| for (g.constraints.items) |*k| {
            if (k.* > c) k.* -= 1;
        };
    }

    /// The member lists, made again from the primitives' groups and the
    /// groups' parents (after reading a file).
    pub fn rebuild(gs: *Groups, a: Allocator, geo: []Geometry, cons: []Constraint) Allocator.Error!void {
        for (gs.list.items) |*g| {
            g.geometry.clearRetainingCapacity();
            g.constraints.clearRetainingCapacity();
            g.children.clearRetainingCapacity();
        }
        const n = gs.list.items.len;
        for (gs.list.items, 0..) |g, i| {
            if (g.removed) continue;
            if (g.parent != none and g.parent < n) try gs.list.items[g.parent].children.append(a, @intCast(i));
        }
        for (geo, 0..) |*g, i| {
            if (g.group == none) continue;
            if (g.group >= n or gs.list.items[g.group].removed) {
                g.group = none;
                continue;
            }
            try gs.list.items[g.group].geometry.append(a, @intCast(i));
        }
        for (cons, 0..) |*c, i| {
            if (c.group == none) continue;
            if (c.group >= n or gs.list.items[c.group].removed) {
                c.group = none;
                continue;
            }
            try gs.list.items[c.group].constraints.append(a, @intCast(i));
        }
    }

    /// Everything inside group `id`, its child groups' too.
    pub fn internalGeometry(gs: *const Groups, a: Allocator, id: GroupId, out: *std.ArrayList(GeomId)) Error!void {
        const g = try gs.get(id);
        try out.appendSlice(a, g.geometry.items);
        for (g.children.items) |c| try gs.internalGeometry(a, c, out);
    }

    pub fn internalConstraints(gs: *const Groups, a: Allocator, id: GroupId, out: *std.ArrayList(ConstraintId)) Error!void {
        const g = try gs.get(id);
        try out.appendSlice(a, g.constraints.items);
        for (g.children.items) |c| try gs.internalConstraints(a, c, out);
    }
};

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn pointAt(v: u32) Geometry {
    return .{ .kind = .{ .point = .{ .x = v, .y = v + 1 } } };
}

fn coincident(p: GeomId, q: GeomId) Constraint {
    return .{ .kind = .{ .coincident = .{ .{ .geom = p }, .{ .geom = q } } } };
}

test "grouping is two-way: a group lists its members, a member names its group" {
    const a = testing.allocator;
    var geo = [_]Geometry{ pointAt(0), pointAt(2), pointAt(4), pointAt(6) };
    var cons = [_]Constraint{ coincident(0, 1), coincident(1, 2), coincident(2, 3) };
    var gs: Groups = .{};
    defer gs.deinit(a);
    const g = try gs.make(a, &geo, &cons, &.{ 0, 1, 2 }, &.{}, .regular_polygon, true);
    try testing.expectEqual(g, geo[1].group);
    try testing.expectEqual(none, geo[3].group);
    try testing.expectEqualSlices(GeomId, &.{ 0, 1, 2 }, (try gs.get(g)).geometry.items);
    // Wholly inside: internal; reaching out to point 3: external, outside.
    try testing.expectEqualSlices(ConstraintId, &.{ 0, 1 }, (try gs.get(g)).constraints.items);
    try testing.expectEqual(none, cons[2].group);
    try testing.expectEqual(g, gs.objectOf(geo[0].group));
}

test "nested groups: a constraint lives in the innermost group holding its geometry" {
    const a = testing.allocator;
    var geo = [_]Geometry{ pointAt(0), pointAt(2), pointAt(4), pointAt(6) };
    var cons = [_]Constraint{ coincident(0, 1), coincident(1, 2), coincident(2, 3) };
    var gs: Groups = .{};
    defer gs.deinit(a);
    const inner = try gs.make(a, &geo, &cons, &.{ 0, 1 }, &.{}, .connection, true);
    const outer = try gs.make(a, &geo, &cons, &.{2}, &.{inner}, .caption, true);
    try testing.expectEqual(inner, cons[0].group);
    try testing.expectEqual(outer, cons[1].group);
    try testing.expectEqual(none, cons[2].group);
    try testing.expectEqual(outer, gs.parentOf(inner));
    try testing.expect(gs.within(inner, outer));
    // A click on the inner member chooses the outer object.
    try testing.expectEqual(outer, gs.objectOf(geo[0].group));
    var all: std.ArrayList(GeomId) = .empty;
    defer all.deinit(a);
    try gs.internalGeometry(a, outer, &all);
    try testing.expectEqual(@as(usize, 3), all.items.len);
    // Members of different groups cannot be grouped together.
    try testing.expectError(error.NotSiblings, gs.make(a, &geo, &cons, &.{ 0, 3 }, &.{}, .plain, false));
}

test "deconstruct, regroup, ungroup" {
    const a = testing.allocator;
    var geo = [_]Geometry{ pointAt(0), pointAt(2), pointAt(4) };
    var cons = [_]Constraint{coincident(0, 1)};
    var gs: Groups = .{};
    defer gs.deinit(a);
    const g = try gs.make(a, &geo, &cons, &.{ 0, 1 }, &.{}, .regular_polygon, true);
    try gs.setProp(a, g, "sides", 5);
    try gs.open(g);
    try testing.expect(!(try gs.get(g)).sealed);
    try testing.expectEqual(@as(?f64, 5), (try gs.get(g)).prop("sides"));
    // Its shape no longer holds: an object of no kind.
    try gs.seal(g, false);
    try testing.expectEqual(Kind.plain, (try gs.get(g)).kind);
    try gs.ungroup(a, &geo, &cons, g);
    try testing.expectEqual(none, geo[0].group);
    try testing.expectEqual(none, cons[0].group);
    try testing.expectError(error.NoSuchGroup, gs.get(g));
}

test "removing a constraint keeps the groups' constraint IDs right; rebuild from the primitives" {
    const a = testing.allocator;
    var geo = [_]Geometry{ pointAt(0), pointAt(2), pointAt(4), pointAt(6) };
    var cons_list: std.ArrayList(Constraint) = .empty;
    defer cons_list.deinit(a);
    try cons_list.appendSlice(a, &.{ coincident(2, 3), coincident(0, 1), coincident(1, 0) });
    var gs: Groups = .{};
    defer gs.deinit(a);
    const g = try gs.make(a, &geo, cons_list.items, &.{ 0, 1 }, &.{}, .plain, false);
    try testing.expectEqualSlices(ConstraintId, &.{ 1, 2 }, (try gs.get(g)).constraints.items);
    gs.constraintRemoved(cons_list.items[0].group, 0);
    _ = cons_list.orderedRemove(0);
    try testing.expectEqualSlices(ConstraintId, &.{ 0, 1 }, (try gs.get(g)).constraints.items);
    try cons_list.append(a, coincident(0, 1));
    try gs.constraintAdded(a, &geo, cons_list.items, 2);
    try testing.expectEqualSlices(ConstraintId, &.{ 0, 1, 2 }, (try gs.get(g)).constraints.items);
    // As read from a file: the lists made again from the primitives.
    var copy = try gs.clone(a);
    defer copy.deinit(a);
    for (copy.list.items) |*x| {
        x.geometry.clearRetainingCapacity();
        x.constraints.clearRetainingCapacity();
    }
    try copy.rebuild(a, &geo, cons_list.items);
    try testing.expectEqualSlices(GeomId, &.{ 0, 1 }, (try copy.get(g)).geometry.items);
    try testing.expectEqualSlices(ConstraintId, &.{ 0, 1, 2 }, (try copy.get(g)).constraints.items);
}
