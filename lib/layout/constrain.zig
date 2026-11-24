//! Parametric constraints: solving them, and checking them.
//!
//! An object's features are linear in two numbers per axis: where its
//! object origin is (`o`) and how big it is (`s`). With its origin a
//! fraction `f` across it (0 at its low edge, ½ at its middle, 1 at its
//! high edge), its low edge is at o − f·s, its high edge at o + (1 − f)·s,
//! its centre at o + (½ − f)·s, and its origin at o. So every constraint
//! (a feature at a distance from another, equal sizes) is one linear
//! equation in one axis, and the axes solve apart.
//!
//! Each feature is a point of basic geometry, and each constraint one of
//! `graven_constraint`'s on those points, solved there (see `solve`).
//!
//! Constraints hold exactly. Within them, things move as little as they
//! can, and what a constraint was applied to (its end `a`) moves before
//! what it refers to (`b`, or the parent, which never moves for its
//! children): each object's origin and size are weighted by how far they
//! may give, sizes giving less than positions, so a constrained object
//! moves rather than stretches unless two of its edges are held apart.
//! A resize keeps the origin where it is.
//!
//! Solving runs after every action (see `history.apply`), so adding a
//! constraint, changing its value, or moving something it relies on moves
//! what it constrains into place. A constraint that contradicts those
//! before it, or cannot be met (an end missing, a parent with no edges),
//! is left out and flagged.

const std = @import("std");
const geom = @import("graven_geom");
const model = @import("model.zig");
const native = @import("native.zig");
const gc = @import("graven_constraint");

const Allocator = std.mem.Allocator;
const Model = model.Model;
const ObjectId = model.ObjectId;
const Feature = model.Feature;

pub const Issue = struct {
    constraint: ObjectId,
    kind: enum {
        /// An end names an object that is not there (removed, say).
        missing_object,
        /// Its ends' objects are in different workspaces (frames of one
        /// workspace are fine: their offsets are known).
        cross_parent,
        /// It refers to its parent's edges, and the parent has none (the
        /// canvas, or a frame without a boundary).
        no_parent_edge,
        /// Its ends are on different axes.
        mixed_axes,
        /// It contradicts constraints before it: left out.
        conflict,
        /// Meeting it turns its object inside out (a negative size).
        inverted,
        /// It names a feature its object lacks (a panel's baseline).
        no_feature,
    },
};

/// Where an object is, and what it is.
/// A construction line is placed by its point: a horizontal one's height
/// and a vertical one's place across are what a constraint holds.
const Kind = enum { panel, region, art, image, figure_place, control_point, guide };
/// What an object sits in: a workspace (panels, content layouts set
/// straight on it, images) or a panel (its content layouts, line art),
/// whose frame its position is in.
pub const Parent = model.Parent;

const Loc = struct {
    kind: Kind,
    parent: Parent,
    /// Panel index (panels, line art), or space index (images, figure
    /// placements, construction lines); content layouts and control
    /// points are found by `parent`.
    holder: usize = 0,
    index: usize = 0,
    /// A control point's index in its track's path.
    sub: usize = 0,
};

fn locate(m: *const Model, id: ObjectId) ?Loc {
    if (id == .none) return null;
    for (0..m.parentCount()) |pk| {
        const pa = m.parentAt(pk);
        for (m.regionsIn(pa), 0..) |r, k| {
            if (r.id == id) return .{ .kind = .region, .parent = pa, .index = k };
            for (r.path.items, 0..) |cp, j| if (cp.id == id) return .{ .kind = .control_point, .parent = pa, .index = k, .sub = j };
        }
    }
    for (m.panels.items, 0..) |p, pi| {
        if (p.id == id) return .{ .kind = .panel, .parent = .{ .space = m.spaceOf(pi) }, .holder = pi };
        for (p.art.items, 0..) |x, k| if (x.id == id) return .{ .kind = .art, .parent = .{ .panel = pi }, .holder = pi, .index = k };
    }
    for (m.spaces.items, 0..) |s, si| {
        for (s.images.items, 0..) |im, k| if (im.id == id) return .{ .kind = .image, .parent = .{ .space = si }, .holder = si, .index = k };
        for (s.figure_places.items, 0..) |fp, k| if (fp.id == id) return .{ .kind = .figure_place, .parent = .{ .space = si }, .holder = si, .index = k };
        for (s.guides.items, 0..) |g, k| if (g.id == id) return .{ .kind = .guide, .parent = .{ .space = si }, .holder = si, .index = k };
    }
    return null;
}

fn parentEql(a: Parent, b: Parent) bool {
    return a.eql(b);
}

/// An object's extent on one axis, where its origin is across it, and
/// whether it may be resized.
const Shape = struct { lo: f64, hi: f64, f: f64, resizable: bool };

fn frac(t: model.Third) f64 {
    return switch (t) {
        .low => 0,
        .mid => 0.5,
        .high => 1,
    };
}

fn shapeOf(m: *const Model, loc: Loc, vertical: bool) Shape {
    const pick = struct {
        fn f(b: geom.Box, holds: model.OriginPoint, v: bool, resizable: bool) Shape {
            return if (v)
                .{ .lo = b.y0, .hi = b.y1, .f = frac(holds.y), .resizable = resizable }
            else
                .{ .lo = b.x0, .hi = b.x1, .f = frac(holds.x), .resizable = resizable };
        }
    }.f;
    // A panel, or the panel holding line art (nothing else is found by
    // `holder` in the panels).
    const p: *model.Panel = if (loc.kind == .panel or loc.kind == .art) &m.panels.items[loc.holder] else undefined;
    return switch (loc.kind) {
        .panel => pick(p.box(), p.holds, vertical, true),
        .region => blk: {
            const r = m.regionsIn(loc.parent)[loc.index];
            break :blk pick(r.softArea(), r.holds, vertical, true);
        },
        .art => blk: {
            const x = p.art.items[loc.index];
            var b = x.box();
            if (b.isEmpty()) b = .{ .x0 = x.at.x, .y0 = x.at.y, .x1 = x.at.x, .y1 = x.at.y };
            break :blk pick(b, x.holds, vertical, x.figure != .none);
        },
        .image => blk: {
            const im = m.spaces.items[loc.holder].images.items[loc.index];
            break :blk pick(im.box(), im.holds, vertical, true);
        },
        .figure_place => blk: {
            const fp = m.spaces.items[loc.holder].figure_places.items[loc.index];
            break :blk pick(fp.box(), fp.holds, vertical, true);
        },
        .control_point => blk: {
            const at = controlPointAt(m.regionsIn(loc.parent)[loc.index], loc.sub);
            const v = if (vertical) at.y else at.x;
            break :blk .{ .lo = v, .hi = v, .f = 0, .resizable = false };
        },
        // A construction line: its point, on each axis.
        .guide => blk: {
            const at = m.spaces.items[loc.holder].guides.items[loc.index].at;
            const v = if (vertical) at.y else at.x;
            break :blk .{ .lo = v, .hi = v, .f = 0, .resizable = false };
        },
    };
}

/// Where a track's control point is in its panel's frame: at the start of
/// a row, half a row in (as the editor draws the path).
pub fn controlPointAt(r: model.TileRegion, k: usize) geom.Point {
    const cp = r.path.items[k];
    return if (r.major() == .row)
        .{ .x = r.origin.x + cp.along * r.pitch, .y = r.origin.y - (cp.across + 0.5) * r.pitch }
    else
        .{ .x = r.origin.x + (cp.across + 0.5) * r.pitch, .y = r.origin.y - cp.along * r.pitch };
}

/// Moves object `loc` on one axis so its origin is at `o` and its size
/// `s`.
fn place(m: *Model, loc: Loc, vertical: bool, o: f64, s: f64) void {
    const sh = shapeOf(m, loc, vertical);
    const lo = o - sh.f * s;
    // A panel, or the panel holding line art (nothing else is found by
    // `holder` in the panels).
    const p: *model.Panel = if (loc.kind == .panel or loc.kind == .art) &m.panels.items[loc.holder] else undefined;
    switch (loc.kind) {
        .panel => if (vertical) {
            p.origin.y = lo;
            p.h = s;
        } else {
            p.origin.x = lo;
            p.w = s;
        },
        .region => {
            const r = &m.regionsIn(loc.parent)[loc.index];
            if (vertical) {
                r.origin.y = lo + s;
                r.h = s / r.pitch;
            } else {
                r.origin.x = lo;
                r.w = s / r.pitch;
            }
        },
        .art => {
            const x = &p.art.items[loc.index];
            if (vertical) x.at.y += lo - sh.lo else x.at.x += lo - sh.lo;
            // A figure's placement: its ink made again at the width (its
            // height follows, its proportions kept).
            if (!vertical and x.figure != .none and @abs(s - (sh.hi - sh.lo)) > 1e-9) {
                if (m.figureIndex(x.figure)) |fi| if (m.figureShapes(fi, s)) |shapes| {
                    if (shapes.len > 0) x.shapes = shapes;
                } else |_| {};
            }
        },
        .control_point => {
            const r = &m.regionsIn(loc.parent)[loc.index];
            const cp = &r.path.items[loc.sub];
            // Back from the panel frame to u along and across.
            if (r.major() == .row) {
                if (vertical) cp.across = @max(0, (r.origin.y - o) / r.pitch - 0.5) else cp.along = (o - r.origin.x) / r.pitch;
            } else {
                if (vertical) cp.along = (r.origin.y - o) / r.pitch else cp.across = @max(0, (o - r.origin.x) / r.pitch - 0.5);
            }
        },
        .image => {
            const im = &m.spaces.items[loc.holder].images.items[loc.index];
            if (vertical) {
                im.at.y = lo;
                im.h = s;
            } else {
                im.at.x = lo;
                im.w = s;
            }
        },
        // Its boundary at `lo`, `s` long: the ink inside it at the
        // margin (a placement keeps its proportions: the editor's resize
        // keeps them; here each axis is as given).
        .figure_place => {
            const fp = &m.spaces.items[loc.holder].figure_places.items[loc.index];
            // A wrap: its bounds scale with the ink's width.
            if (fp.border.fractions()) |fr| {
                if (vertical) {
                    fp.at.y = lo - fr.y0 * fp.w;
                } else {
                    const w = @max(s / @max(fr.x1 - fr.x0, 1e-9), 1e-3);
                    if (fp.w > 0) fp.h = w * fp.h / fp.w;
                    fp.w = w;
                    fp.at.x = lo - fr.x0 * w;
                }
                return;
            }
            const ink = @max(s - 2 * fp.margin, 1e-3);
            if (vertical) {
                fp.at.y = lo + fp.margin;
                fp.h = ink;
            } else {
                fp.at.x = lo + fp.margin;
                fp.w = ink;
            }
        },
        .guide => {
            const g = &m.spaces.items[loc.holder].guides.items[loc.index];
            if (vertical) g.at.y = o else g.at.x = o;
        },
    }
}

/// A feature of a parent, in the frame its children are placed in; null
/// for an edge of a workspace without a boundary (the canvas).
fn parentFeature(m: *const Model, parent: Parent, f: Feature) ?f64 {
    const space_bound = struct {
        fn of(mm: *const Model, si: usize) ?geom.Box {
            return if (si < mm.spaces.items.len) mm.spaces.items[si].bound else null;
        }
    }.of;
    var bound: ?geom.Box = null;
    var holds: model.OriginPoint = .{};
    switch (parent) {
        .space => |si| bound = space_bound(m, si),
        .panel => |pi| {
            const p = m.panels.items[pi];
            bound = .{ .x0 = 0, .y0 = 0, .x1 = p.w, .y1 = p.h };
            holds = p.holds;
        },
    }
    if (f == .origin_x or f == .origin_y) {
        const b = bound orelse return 0;
        // A space's origin is its coordinates' origin; a panel's is its
        // object origin, in its own frame.
        if (parent == .space) return 0;
        return if (f == .origin_x) b.x0 + frac(holds.x) * b.width() else b.y0 + frac(holds.y) * b.height();
    }
    const b = bound orelse return null;
    return switch (f) {
        .left => b.x0,
        .right => b.x1,
        .centre_x => (b.x0 + b.x1) / 2,
        .bottom => b.y0,
        .top => b.y1,
        .centre_y => (b.y0 + b.y1) / 2,
        .origin_x, .origin_y => unreachable,
        .baseline => null,
    };
}

/// The parent object `id` sits in; null for none (or not a positioning
/// object).
pub fn parentOf(m: *const Model, id: ObjectId) ?Parent {
    return (locate(m, id) orelse return null).parent;
}

/// The space a parent is in.
pub fn spaceOf(m: *const Model, parent: Parent) usize {
    return switch (parent) {
        .space => |si| si,
        .panel => |pi| m.spaceOf(pi),
    };
}

/// Where a parent's frame sits in its space: a panel's origin corner (0
/// for a workspace).
pub fn frameOffset(m: *const Model, parent: Parent) geom.Point {
    return switch (parent) {
        .space => .{ .x = 0, .y = 0 },
        .panel => |pi| m.panels.items[pi].origin,
    };
}

/// Object `id`'s box in its parent's frame (a point's is that point);
/// null when it is not a positioning object.
pub fn boxOf(m: *const Model, id: ObjectId) ?geom.Box {
    const loc = locate(m, id) orelse return null;
    const x = shapeOf(m, loc, false);
    const y = shapeOf(m, loc, true);
    return .{ .x0 = x.lo, .x1 = x.hi, .y0 = y.lo, .y1 = y.hi };
}

/// Where object `id`'s object origin is, in its parent's frame.
pub fn originOf(m: *const Model, id: ObjectId) ?geom.Point {
    const loc = locate(m, id) orelse return null;
    const x = shapeOf(m, loc, false);
    const y = shapeOf(m, loc, true);
    return .{ .x = x.lo + x.f * (x.hi - x.lo), .y = y.lo + y.f * (y.hi - y.lo) };
}

/// Where a feature lies on its axis, in `parent`'s frame: of the object
/// `end` names, or (no object) of `parent` itself. Null when it has none
/// (an object that is gone, an unbounded space's edge).
pub fn featureAt(m: *const Model, parent: Parent, end: model.ConstraintEnd) ?f64 {
    if (end.object == .none) return parentFeature(m, parent, end.feature);
    const loc = locate(m, end.object) orelse return null;
    const sh = shapeOf(m, loc, end.feature.vertical());
    const size = sh.hi - sh.lo;
    const t = featureTerm(m, loc, end.feature, sh.f) orelse return null;
    return sh.lo + sh.f * size + t.g * size + t.c;
}

/// What constraint `c` measures as things are now, signed (its magnitude
/// the value it would keep, its sign the side): an offset between its
/// features, or a difference of sizes.
pub fn measure(m: *const Model, c: model.Constraint) ?f64 {
    const parent = parentOf(m, c.a.object) orelse return null;
    switch (c.kind) {
        .offset => return (featureInSpace(m, parent, c.a) orelse return null) - (featureInSpace(m, parent, c.b) orelse return null),
        .equal_size => {
            const v = c.a.feature.vertical();
            const sa = boxOf(m, c.a.object) orelse return null;
            const sb: geom.Box = if (c.b.object == .none) blk: {
                const lo = parentFeature(m, parent, if (v) .bottom else .left) orelse return null;
                const hi = parentFeature(m, parent, if (v) .top else .right) orelse return null;
                break :blk if (v) .{ .x0 = 0, .x1 = 0, .y0 = lo, .y1 = hi } else .{ .x0 = lo, .x1 = hi, .y0 = 0, .y1 = 0 };
            } else boxOf(m, c.b.object) orelse return null;
            return if (v) sa.height() - sb.height() else sa.width() - sb.width();
        },
    }
}

/// A feature as a multiple of an object's size away from its origin.
fn sizeCoeff(f: Feature, at: f64) f64 {
    return switch (f) {
        .left, .bottom => -at,
        .right, .top => 1 - at,
        .centre_x, .centre_y => 0.5 - at,
        .origin_x, .origin_y => 0,
        .baseline => unreachable,
    };
}

/// Where feature `f` of object `loc` lies: its origin, plus `g` times its
/// size, plus `c`. Null for a feature it lacks.
const Term = struct { g: f64, c: f64 = 0 };

fn featureTerm(m: *const Model, loc: Loc, f: Feature, at: f64) ?Term {
    if (f != .baseline) return .{ .g = sizeCoeff(f, at) };
    switch (loc.kind) {
        // A track of text, in rows: its first row's capitals centred in
        // the row (as the flow sets them), from its top.
        .region => {
            const r = m.regionsIn(loc.parent)[loc.index];
            if (r.major() != .row) return null;
            const sid = r.style orelse return null;
            if (m.styleIndex(sid) == null) return null;
            const cap = m.textStyle(sid).cap_height;
            // The first row is at the region's top.
            return .{ .g = 1 - at, .c = -(r.pitch + cap) / 2 };
        },
        else => return null,
    }
}

/// Where a feature lies on its axis in its workspace's coordinates (a
/// panel's frame offset added): of the object `end` names, or (no object)
/// of `parent`, the parent of the constraint's other end. Null as
/// `featureAt`.
pub fn featureInSpace(m: *const Model, parent: Parent, end: model.ConstraintEnd) ?f64 {
    const v = end.feature.vertical();
    const own = if (end.object == .none) parent else (locate(m, end.object) orelse return null).parent;
    const off = frameOffset(m, own);
    return (featureAt(m, own, end) orelse return null) + if (v) off.y else off.x;
}

/// Solves every constraint, moving and resizing objects to meet them;
/// appends what cannot be met to `issues` when given.
///
/// Constraints act on basic geometry (`graven_constraint`; the owner,
/// 2026-11-24): each end is a point, its feature's place in its
/// workspace's coordinates. On a constrained object (an end `a`) that
/// place is an affine form over the object's unknowns on the axis (its
/// origin and size), elsewhere where it is now. An offset is a distance
/// along x or y between two such points, never negative (its `side` says
/// which way it runs); equal sizes, an equal distance between two spans.
/// So the ends may be in different frames of one workspace: a column in a
/// panel kept to a construction line on the canvas.
///
/// What sits straight in a workspace (panels among it) is solved before
/// what is in the panels, so children follow a resized panel, and a panel
/// never moves for its children.
pub fn solve(m: *Model, gpa: Allocator, issues: ?*std.ArrayList(Issue)) Allocator.Error!void {
    if (m.constraints.items.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try a.alloc(bool, m.constraints.items.len);
    for (m.constraints.items, ok) |c, *good| good.* = try usable(m, gpa, issues, c);
    for ([_]bool{ true, false }) |spaces| try solvePass(m, gpa, a, issues, ok, spaces);
}

fn note(gpa: Allocator, issues: ?*std.ArrayList(Issue), id: ObjectId, kind: @FieldType(Issue, "kind")) Allocator.Error!void {
    if (issues) |list| try list.append(gpa, .{ .constraint = id, .kind = kind });
}

/// Whether constraint `c` can be solved for at all; why not, noted.
fn usable(m: *const Model, gpa: Allocator, issues: ?*std.ArrayList(Issue), c: model.Constraint) Allocator.Error!bool {
    const la = locate(m, c.a.object) orelse {
        try note(gpa, issues, c.id, .missing_object);
        return false;
    };
    if (c.a.feature.vertical() != c.b.feature.vertical()) {
        try note(gpa, issues, c.id, .mixed_axes);
        return false;
    }
    if (c.kind == .offset) {
        const fa = shapeOf(m, la, c.a.feature.vertical()).f;
        const lacks_a = featureTerm(m, la, c.a.feature, fa) == null;
        const lacks_b = if (c.b.object == .none) c.b.feature == .baseline else if (locate(m, c.b.object)) |lb| featureTerm(m, lb, c.b.feature, shapeOf(m, lb, c.b.feature.vertical()).f) == null else false;
        if (lacks_a or lacks_b) {
            try note(gpa, issues, c.id, .no_feature);
            return false;
        }
    }
    if (c.b.object != .none) {
        const lb = locate(m, c.b.object) orelse {
            try note(gpa, issues, c.id, .missing_object);
            return false;
        };
        if (spaceOf(m, la.parent) != spaceOf(m, lb.parent)) {
            try note(gpa, issues, c.id, .cross_parent);
            return false;
        }
    } else if (parentFeature(m, la.parent, if (c.kind == .offset) c.b.feature else if (c.b.feature.vertical()) .top else .right) == null) {
        try note(gpa, issues, c.id, .no_parent_edge);
        return false;
    }
    return true;
}

/// A constrained object: its origin and size on each axis as unknowns
/// (fixed on an axis it is not constrained on, and a size it cannot take).
const Obj = struct {
    id: ObjectId,
    loc: Loc,
    shape: [2]Shape,
    used: [2]bool = .{ false, false },
    o: [2]u32,
    s: [2]u32,
};

fn objIndex(list: []const Obj, id: ObjectId) ?usize {
    for (list, 0..) |o, i| if (o.id == id) return i;
    return null;
}

const ConstraintCtx = struct {
    st: gc.geometry.Store,
    cs: []const gc.geometry.Constraint,

    pub fn rows(x: ConstraintCtx, out: *gc.solve.Rows) !void {
        try x.st.rows(x.cs, out);
    }
};

/// Solves; whether everything driving holds.
fn run(gpa: Allocator, p: gc.solve.Problem, ctx: ConstraintCtx) Allocator.Error!bool {
    const r = gc.solve.solve(gpa, p, ctx) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return r.solved;
}

/// The point for constraint end `end`, on its axis (the other at 0), in
/// its workspace's coordinates; `parent` is the parent of the constraint's
/// constrained object, for an end without one.
fn endPoint(m: *const Model, a: Allocator, geo: *std.ArrayList(gc.geometry.Geometry), objs: []const Obj, parent: Parent, end: model.ConstraintEnd) Allocator.Error!gc.geometry.PointRef {
    const v = end.feature.vertical();
    var co: gc.geometry.Affine = .{};
    if (end.object == .none) {
        const off = frameOffset(m, parent);
        co.c = parentFeature(m, parent, end.feature).? + if (v) off.y else off.x;
    } else {
        const loc = locate(m, end.object).?;
        const off = frameOffset(m, loc.parent);
        const base = if (v) off.y else off.x;
        if (objIndex(objs, end.object)) |k| {
            const ax = @intFromBool(v);
            const t = featureTerm(m, loc, end.feature, objs[k].shape[ax].f).?;
            co = .{ .c = base + t.c, .vars = .{ objs[k].o[ax], objs[k].s[ax] }, .k = .{ 1, t.g } };
        } else co.c = base + featureAt(m, loc.parent, end).?;
    }
    try geo.append(a, .{ .kind = .{ .affine = if (v) .{ .x = .{}, .y = co } else .{ .x = co, .y = .{} } } });
    return .{ .geom = @intCast(geo.items.len - 1) };
}

/// The constraints whose constrained object sits straight in a workspace
/// (`spaces`), or in a panel, solved together on the library.
fn solvePass(m: *Model, gpa: Allocator, a: Allocator, issues: ?*std.ArrayList(Issue), ok: []const bool, spaces: bool) Allocator.Error!void {
    var cons: std.ArrayList(usize) = .empty;
    for (m.constraints.items, ok, 0..) |c, good, ci| {
        if (!good) continue;
        if ((locate(m, c.a.object).?.parent == .space) != spaces) continue;
        try cons.append(a, ci);
    }
    if (cons.items.len == 0) return;

    // What constraints are applied to (their `a` ends) may move; what they
    // only refer to stays where it is. Moving gives more readily than
    // resizing, so a constrained object moves rather than stretches unless
    // two of its edges are held apart.
    var objs: std.ArrayList(Obj) = .empty;
    var vars: std.ArrayList(f64) = .empty;
    var fixed: std.ArrayList(bool) = .empty;
    var give: std.ArrayList(f64) = .empty;
    for (cons.items) |ci| {
        const c = m.constraints.items[ci];
        const ax = @intFromBool(c.a.feature.vertical());
        const k = objIndex(objs.items, c.a.object) orelse blk: {
            const loc = locate(m, c.a.object).?;
            var o: Obj = .{ .id = c.a.object, .loc = loc, .shape = undefined, .o = undefined, .s = undefined };
            for (0..2) |axis| {
                const sh = shapeOf(m, loc, axis == 1);
                const size = sh.hi - sh.lo;
                o.shape[axis] = sh;
                o.o[axis] = @intCast(vars.items.len);
                try vars.append(a, sh.lo + sh.f * size);
                try give.append(a, 1);
                o.s[axis] = @intCast(vars.items.len);
                try vars.append(a, size);
                try give.append(a, 1e-3);
                try fixed.appendNTimes(a, true, 2);
            }
            try objs.append(a, o);
            break :blk objs.items.len - 1;
        };
        const o = &objs.items[k];
        if (!o.used[ax]) {
            o.used[ax] = true;
            fixed.items[o.o[ax]] = false;
            fixed.items[o.s[ax]] = !o.shape[ax].resizable;
        }
    }

    // Each constraint on points: features as points, an offset as a
    // distance along its axis, equal sizes as an equal distance.
    var geo: std.ArrayList(gc.geometry.Geometry) = .empty;
    var lc: std.ArrayList(gc.geometry.Constraint) = .empty;
    for (cons.items) |ci| {
        const c = m.constraints.items[ci];
        const v = c.a.feature.vertical();
        const parent = locate(m, c.a.object).?.parent;
        switch (c.kind) {
            .offset => {
                const pa = try endPoint(m, a, &geo, objs.items, parent, c.a);
                const pb = try endPoint(m, a, &geo, objs.items, parent, c.b);
                // (a − b)·side = value.
                try lc.append(a, .{ .kind = if (v)
                    .{ .distance_y = .{ .a = pb, .b = pa, .value = c.value, .side = c.side } }
                else
                    .{ .distance_x = .{ .a = pb, .b = pa, .value = c.value, .side = c.side } } });
            },
            .equal_size => {
                const lo: Feature = if (v) .bottom else .left;
                const hi: Feature = if (v) .top else .right;
                var spans: [2]gc.geometry.Span = undefined;
                for ([_]ObjectId{ c.a.object, c.b.object }, &spans) |id, *sp| {
                    const ends = [2]gc.geometry.PointRef{
                        try endPoint(m, a, &geo, objs.items, parent, .{ .object = id, .feature = lo }),
                        try endPoint(m, a, &geo, objs.items, parent, .{ .object = id, .feature = hi }),
                    };
                    sp.* = if (v) .{ .y = ends } else .{ .x = ends };
                }
                try lc.append(a, .{ .kind = .{ .equal_distance = .{ .a = spans[0], .b = spans[1], .value = c.value, .side = c.side } } });
            },
        }
    }

    const v0 = try a.dupe(f64, vars.items);
    const p: gc.solve.Problem = .{ .vars = vars.items, .fixed = fixed.items, .give = give.items };
    const ctx: ConstraintCtx = .{ .st = .{ .vars = vars.items, .fixed = fixed.items, .geometry = geo.items }, .cs = lc.items };
    if (!try run(gpa, p, ctx)) {
        // Not all can hold: in order, each that contradicts those before
        // it is left out and flagged; the rest are solved from the start.
        for (lc.items) |*k| k.driving = false;
        for (lc.items, cons.items) |*k, ci| {
            k.driving = true;
            @memcpy(vars.items, v0);
            if (!try run(gpa, p, ctx)) {
                k.driving = false;
                try note(gpa, issues, m.constraints.items[ci].id, .conflict);
            }
        }
        @memcpy(vars.items, v0);
        _ = try run(gpa, p, ctx);
    }

    for (objs.items) |o| for (0..2) |ax| {
        if (!o.used[ax]) continue;
        const s = vars.items[o.s[ax]];
        if (s < -1e-9) for (cons.items, lc.items) |ci, k| {
            const c = m.constraints.items[ci];
            if (k.driving and (c.a.object == o.id or c.b.object == o.id)) try note(gpa, issues, c.id, .inverted);
        };
        place(m, o.loc, ax == 1, vars.items[o.o[ax]], s);
    };
}

/// Puts object `id` at `box` (in its parent's frame): moved there, and
/// sized to it on the axes its kind can be resized on (line art
/// keeps its size, and moves by its lower edges). Whether it was found.
pub fn setBox(m: *Model, id: ObjectId, box: geom.Box) bool {
    const loc = locate(m, id) orelse return false;
    for ([_]bool{ false, true }) |vertical| {
        const sh = shapeOf(m, loc, vertical);
        const lo = if (vertical) box.y0 else box.x0;
        const s = if (sh.resizable) (if (vertical) box.height() else box.width()) else sh.hi - sh.lo;
        place(m, loc, vertical, lo + sh.f * s, s);
    }
    return true;
}

/// Which ways object `id` may move and be resized without breaking a
/// constraint: along each axis, and each of its edges (false on an axis
/// its kind cannot be resized on). Tried on a copy of the model: the
/// change is made and the constraints solved, and it is free where the
/// object stays where it was put.
pub const Freedom = struct {
    x: bool = false,
    y: bool = false,
    left: bool = false,
    right: bool = false,
    bottom: bool = false,
    top: bool = false,
};

pub fn freedom(gpa: Allocator, m: *const Model, id: ObjectId) !Freedom {
    const loc = locate(m, id) orelse return .{};
    const b = boxOf(m, id) orelse return .{};
    const rx = shapeOf(m, loc, false).resizable;
    const ry = shapeOf(m, loc, true).resizable;
    const d = 1.0;
    const tries = [_]struct { box: geom.Box, ok: bool }{
        .{ .box = .{ .x0 = b.x0 + d, .x1 = b.x1 + d, .y0 = b.y0, .y1 = b.y1 }, .ok = true },
        .{ .box = .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0 + d, .y1 = b.y1 + d }, .ok = true },
        .{ .box = .{ .x0 = b.x0 - d, .x1 = b.x1, .y0 = b.y0, .y1 = b.y1 }, .ok = rx },
        .{ .box = .{ .x0 = b.x0, .x1 = b.x1 + d, .y0 = b.y0, .y1 = b.y1 }, .ok = rx },
        .{ .box = .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0 - d, .y1 = b.y1 }, .ok = ry },
        .{ .box = .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0, .y1 = b.y1 + d }, .ok = ry },
    };
    var free: [6]bool = undefined;
    const bytes = if (m.constraints.items.len > 0) try native.encode(gpa, m) else &[_]u8{};
    defer if (bytes.len > 0) gpa.free(bytes);
    for (tries, &free) |t, *f| {
        f.* = t.ok;
        if (!t.ok or bytes.len == 0) continue;
        var copy = try native.decode(gpa, bytes);
        defer copy.deinit();
        _ = setBox(&copy, id, t.box);
        try solve(&copy, gpa, null);
        const got = boxOf(&copy, id) orelse continue;
        const tol = 1e-6;
        f.* = @abs(got.x0 - t.box.x0) < tol and @abs(got.x1 - t.box.x1) < tol and @abs(got.y0 - t.box.y0) < tol and @abs(got.y1 - t.box.y1) < tol;
    }
    return .{ .x = free[0], .y = free[1], .left = free[2], .right = free[3], .bottom = free[4], .top = free[5] };
}

/// What cannot be met, without moving anything: solves a copy.
pub fn check(m: *const Model, gpa: Allocator) ![]Issue {
    var issues: std.ArrayList(Issue) = .empty;
    errdefer issues.deinit(gpa);
    if (m.constraints.items.len == 0) return issues.toOwnedSlice(gpa);
    const bytes = try native.encode(gpa, m);
    defer gpa.free(bytes);
    var copy = try native.decode(gpa, bytes);
    defer copy.deinit();
    try solve(&copy, gpa, &issues);
    return issues.toOwnedSlice(gpa);
}

// Tests ---------------------------------------------------------------------------

const testing = std.testing;
const history = @import("history.zig");

fn artAt(m: *const Model, p: usize, i: usize) geom.Point {
    return m.panels.items[p].art.items[i].at;
}

test "a constraint moves what it constrains, exactly, and keeps it there" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    // Two points of line art (no shapes: each is its place) placed roughly.
    _ = try m.addArt(c, .{ .name = "A", .at = .{ .x = 10.3, .y = 20.7 }, .shapes = &.{} });
    _ = try m.addArt(c, .{ .name = "B", .at = .{ .x = 31.9, .y = 18.2 }, .shapes = &.{} });
    try h.reset(&m);
    const a_id = m.panels.items[c].art.items[0].id;
    const b_id = m.panels.items[c].art.items[1].id;

    // B exactly 25 mm right of A, and level with it: B moves, A stays.
    const dx = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = b_id, .feature = .origin_x }, .b = .{ .object = a_id, .feature = .origin_x }, .value = 25 }});
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = b_id, .feature = .origin_y }, .b = .{ .object = a_id, .feature = .origin_y } }});
    try testing.expectApproxEqAbs(@as(f64, 35.3), artAt(&m, c, 1).x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20.7), artAt(&m, c, 1).y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10.3), artAt(&m, c, 0).x, 1e-9);

    // A changed value moves B; moving A takes B along.
    try h.do(&m, .setConstraintValue, .{ dx, 40 });
    try testing.expectApproxEqAbs(@as(f64, 50.3), artAt(&m, c, 1).x, 1e-9);
    try h.do(&m, .moveArt, .{ c, 0, geom.Point{ .x = 0, .y = 5 } });
    try testing.expectApproxEqAbs(@as(f64, 40), artAt(&m, c, 1).x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), artAt(&m, c, 1).y, 1e-9);
    // Moving B by hand: its constrained axes hold.
    try h.do(&m, .moveArt, .{ c, 1, geom.Point{ .x = 70, .y = 70 } });
    try testing.expectApproxEqAbs(@as(f64, 40), artAt(&m, c, 1).x, 1e-9);

    // Undo takes the step back, as it was.
    _ = try h.undo(&m);
    try testing.expectApproxEqAbs(@as(f64, 40), artAt(&m, c, 1).x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), artAt(&m, c, 1).y, 1e-9);
}

test "sizes change about the origin, follow a resized parent, and conflicts are flagged" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    const c: model.Parent = .{ .space = try m.startCanvas(.mm) };
    const p = try m.placePanel(.{ .name = "P", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 100, .h = 60 });
    const style = try m.addStyle("Body", .{ .cap_height = 3 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "t", .origin = .{ .x = 9, .y = 52 }, .style = style, .count = 4, .length = 10, .pitch = 5 });
    _ = c;
    try h.reset(&m);
    const pid = m.panels.items[p].id;
    const rid = m.panels.items[p].regions.items[r].id;

    // The panel's origin at its centre: a width of 120 grows both ways.
    try h.do(&m, .setObjectOrigin, .{ pid, model.OriginPoint{ .x = .mid, .y = .mid } });
    const w = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = pid, .feature = .right }, .b = .{ .object = pid, .feature = .left }, .value = 120 }});
    const pb = m.panels.items[p].box();
    try testing.expectApproxEqAbs(@as(f64, -10), pb.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 110), pb.x1, 1e-9);

    // The track 10 mm in from the panel's left and right: placed and
    // sized exactly, and following the panel when it is resized.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .left }, .b = .{ .feature = .left }, .value = 10 }});
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .right }, .b = .{ .feature = .right }, .value = -10 }});
    var area = m.panels.items[p].regions.items[r].softArea();
    try testing.expectApproxEqAbs(@as(f64, 10), area.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 110), area.x1, 1e-9);
    try h.do(&m, .setConstraintValue, .{ w, 150 });
    area = m.panels.items[p].regions.items[r].softArea();
    try testing.expectApproxEqAbs(@as(f64, 140), area.x1, 1e-9);
    // Its top did not move: nothing held it, and it was not in the way.
    try testing.expectApproxEqAbs(@as(f64, 52), area.y1, 1e-9);

    // A third rule on the same edge, disagreeing: flagged, left out.
    const bad = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .left }, .b = .{ .feature = .left }, .value = 30 }});
    try testing.expectApproxEqAbs(@as(f64, 10), m.panels.items[p].regions.items[r].softArea().x0, 1e-9);
    const issues = try check(&m, gpa);
    defer gpa.free(issues);
    try testing.expectEqual(1, issues.len);
    try testing.expectEqual(bad, issues[0].constraint);
    try testing.expect(issues[0].kind == .conflict);

    // The canvas has no edges to refer to.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = pid, .feature = .top }, .b = .{ .feature = .top } }});
    const more = try check(&m, gpa);
    defer gpa.free(more);
    try testing.expectEqual(2, more.len);
    try testing.expect(more[0].kind == .no_parent_edge or more[1].kind == .no_parent_edge);
}

test "peers: equal sizes, and the reference stays" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const p1 = try m.placePanel(.{ .name = "A", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 50, .h = 30 });
    const p2 = try m.placePanel(.{ .name = "B", .space = m.spaces.items[0].id, .origin = .{ .x = 70, .y = 3 }, .w = 41, .h = 22 });
    try h.reset(&m);
    const a = m.panels.items[p1].id;
    const b = m.panels.items[p2].id;
    // B as wide and tall as A, its bottom on A's.
    _ = try h.do(&m, .addConstraint, .{.{ .kind = .equal_size, .a = .{ .object = b, .feature = .left }, .b = .{ .object = a, .feature = .left } }});
    _ = try h.do(&m, .addConstraint, .{.{ .kind = .equal_size, .a = .{ .object = b, .feature = .bottom }, .b = .{ .object = a, .feature = .bottom } }});
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = b, .feature = .bottom }, .b = .{ .object = a, .feature = .bottom } }});
    const pb = m.panels.items[p2];
    try testing.expectApproxEqAbs(@as(f64, 50), pb.w, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 30), pb.h, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0), pb.origin.y, 1e-6);
    // Its origin (bottom-left) stayed: it grew up and right.
    try testing.expectApproxEqAbs(@as(f64, 70), pb.origin.x, 1e-6);
    // A, the reference, is as it was.
    try testing.expectApproxEqAbs(@as(f64, 50), m.panels.items[p1].w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), m.panels.items[p1].origin.y, 1e-9);
}

test "side-by-side text columns share their first baseline" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.placePanel(.{ .name = "P", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 200, .h = 100 });
    const body = try m.addStyle("Body", .{ .cap_height = 3 });
    const big = try m.addStyle("Big", .{ .cap_height = 5 });
    const left = try m.addTracks(.{ .panel = p }, .{ .name = "left", .origin = .{ .x = 10, .y = 90 }, .style = body, .count = 5, .length = 10, .pitch = 6 });
    const right = try m.addTracks(.{ .panel = p }, .{ .name = "right", .origin = .{ .x = 110, .y = 83.7 }, .style = big, .count = 5, .length = 8, .pitch = 9 });
    try h.reset(&m);
    const pp = &m.panels.items[p];
    const lid = pp.regions.items[left].id;
    const rid = pp.regions.items[right].id;
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .baseline }, .b = .{ .object = lid, .feature = .baseline } }});
    const parent: Parent = .{ .panel = p };
    const bl = featureAt(&m, parent, .{ .object = lid, .feature = .baseline }).?;
    const br = featureAt(&m, parent, .{ .object = rid, .feature = .baseline }).?;
    try testing.expectApproxEqAbs(bl, br, 1e-9);
    // The left column's first baseline: its top less half its pitch and cap.
    try testing.expectApproxEqAbs(@as(f64, 85.5), bl, 1e-9);
    // A panel has no baseline.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = lid, .feature = .baseline }, .b = .{ .feature = .baseline } }});
    const issues = try check(&m, gpa);
    defer gpa.free(issues);
    try testing.expectEqual(1, issues.len);
    try testing.expect(issues[0].kind == .no_feature);
}

test "moving into a frame takes the constraint group; copying copies its constraints" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    var ids: [3]ObjectId = undefined;
    for ([_]geom.Point{ .{ .x = 10, .y = 10 }, .{ .x = 40, .y = 12 }, .{ .x = 80, .y = 30 } }, 0..) |at, k| {
        const pi = try m.placePanel(.{ .name = "x", .origin = at, .w = 5, .h = 5 });
        ids[k] = m.panels.items[pi].id;
    }
    const frame = try m.addFrame("Frame", null);
    try h.reset(&m);
    // B is kept 30 mm right of A; A is kept level with C.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = ids[1], .feature = .origin_x }, .b = .{ .object = ids[0], .feature = .origin_x }, .value = 30 }});
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = ids[0], .feature = .origin_y }, .b = .{ .object = ids[2], .feature = .origin_y } }});

    // A copy of A: B comes too (it keeps to A), with its constraint on the
    // copy; A's tie to C stays with the original.
    _ = try h.do(&m, .copyToSpace, .{ &[_]ObjectId{ids[0]}, frame });
    try testing.expectEqual(3, m.constraints.items.len);
    const copied = m.constraints.items[2];
    try testing.expect(copied.a.object != ids[1] and copied.b.object != ids[0]);
    try testing.expectEqual(@as(f64, 30), copied.value);
    try testing.expectEqual(frame, m.spaceOfId(copied.a.object).?);

    // Moving A: B goes with it; A's tie to C, left behind, is dropped.
    _ = try h.do(&m, .moveToSpace, .{ &[_]ObjectId{ids[0]}, frame });
    try testing.expectEqual(frame, m.spaceOfId(ids[0]).?);
    try testing.expectEqual(frame, m.spaceOfId(ids[1]).?);
    try testing.expectEqual(0, m.spaceOfId(ids[2]).?);
    var kept_b = false;
    for (m.constraints.items) |k| {
        try testing.expect(!(k.a.object == ids[0] and k.b.object == ids[2]));
        if (k.a.object == ids[1] and k.b.object == ids[0]) kept_b = true;
    }
    try testing.expect(kept_b);
    const issues = try check(&m, gpa);
    defer gpa.free(issues);
    try testing.expectEqual(0, issues.len);
    // Undo brings the dropped constraint back.
    _ = try h.undo(&m);
    try testing.expectEqual(3, m.constraints.items.len);
}

test "a column straight on the canvas keeps to a construction line there" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    const root: Parent = .{ .space = try m.startCanvas(.mm) };
    const body = try m.addStyle("Body", .{ .cap_height = 3 });
    const r = try m.addTracks(root, .{ .name = "Column1", .origin = .{ .x = 20, .y = 110 }, .style = body, .count = 12, .length = 20, .pitch = 6 });
    const gi = try m.addGuide(0, .{ .x = 0, .y = 150 }, 0);
    m.spaces.items[0].guides.items[gi].lock = .horizontal;
    const gid = m.spaces.items[0].guides.items[gi].id;
    const vi = try m.addGuide(0, .{ .x = 5, .y = 0 }, 90);
    m.spaces.items[0].guides.items[vi].lock = .vertical;
    const vid = m.spaces.items[0].guides.items[vi].id;
    try h.reset(&m);
    const rid = m.spaces.items[0].regions.items[r].id;
    // Its top 10 mm below the horizontal line, its left 7 mm right of the
    // vertical one.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .top }, .b = .{ .object = gid, .feature = .origin_y }, .value = -10 }});
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .left }, .b = .{ .object = vid, .feature = .origin_x }, .value = 7 }});
    const issues = try check(&m, gpa);
    defer gpa.free(issues);
    try testing.expectEqual(0, issues.len);
    const b = boxOf(&m, rid).?;
    try testing.expectApproxEqAbs(@as(f64, 140), b.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 12), b.x0, 1e-9);
}

test "a track's control point can be constrained, and the rows follow it" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.placePanel(.{ .name = "P", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 200, .h = 120 });
    const body = try m.addStyle("Body", .{ .cap_height = 3 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "poem", .origin = .{ .x = 20, .y = 110 }, .style = body, .count = 12, .length = 20, .pitch = 6 });
    try h.reset(&m);
    const cp = try h.do(&m, .addControlPoint, .{ .{ .panel = p }, r, 2.0, 4.0 });
    const rid = m.panels.items[p].regions.items[r].id;
    // The point kept 30 mm right of the track's left edge: it moves there,
    // and with it the path.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = cp, .feature = .origin_x }, .b = .{ .object = rid, .feature = .left }, .value = 30 }});
    const region = m.panels.items[p].regions.items[r];
    try testing.expectApproxEqAbs(@as(f64, 5), region.path.items[0].along, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), region.path.items[0].across, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), region.pathAt(4), 1e-9);
    // Moving the track takes the point's place along: it keeps to it.
    try h.do(&m, .moveControlPoint, .{ cp, 9.0, 4.0 });
    try testing.expectApproxEqAbs(@as(f64, 5), m.panels.items[p].regions.items[r].path.items[0].along, 1e-9);
}

test "objects move and resize only where their constraints leave them free" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.placePanel(.{ .name = "P", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 100, .h = 80 });
    const q = try m.placePanel(.{ .name = "Q", .space = m.spaces.items[0].id, .origin = .{ .x = 150, .y = 0 }, .w = 40, .h = 40 });
    const pid = m.panels.items[p].id;
    const qid = m.panels.items[q].id;
    try h.reset(&m);
    // Unconstrained: free every way.
    const f0 = try freedom(gpa, &m, qid);
    try testing.expect(f0.x and f0.y and f0.left and f0.right and f0.bottom and f0.top);
    // Q's left edge kept 50 mm right of P's right edge: Q cannot move
    // across, nor its left edge; its right edge still resizes, and it
    // moves freely up and down.
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = qid, .feature = .left }, .b = .{ .object = pid, .feature = .right }, .value = 50 }});
    const f1 = try freedom(gpa, &m, qid);
    try testing.expect(!f1.x and f1.y and !f1.left and f1.right and f1.bottom and f1.top);
    // Placing it across anyway: the constraint puts it back; up is kept.
    _ = try h.do(&m, .placeObjects, .{ &[_]ObjectId{qid}, &[_]geom.Box{.{ .x0 = 170, .x1 = 210, .y0 = 10, .y1 = 50 }} });
    const qb = boxOf(&m, qid).?;
    try testing.expectApproxEqAbs(@as(f64, 150), qb.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), qb.y0, 1e-9);
    // P is what Q keeps to: moving P is free, and Q follows.
    const fp = try freedom(gpa, &m, pid);
    try testing.expect(fp.x and fp.y);
    _ = try h.do(&m, .placeObjects, .{ &[_]ObjectId{pid}, &[_]geom.Box{.{ .x0 = 20, .x1 = 120, .y0 = 0, .y1 = 80 }} });
    try testing.expectApproxEqAbs(@as(f64, 170), boxOf(&m, qid).?.x0, 1e-9);
}

test "a dimension's place is kept, undone, and written with the file" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    _ = try m.addArt(c, .{ .name = "A", .at = .{ .x = 10, .y = 20 }, .shapes = &.{} });
    _ = try m.addArt(c, .{ .name = "B", .at = .{ .x = 30, .y = 20 }, .shapes = &.{} });
    try h.reset(&m);
    const a_id = m.panels.items[c].art.items[0].id;
    const b_id = m.panels.items[c].art.items[1].id;
    const k = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = b_id, .feature = .origin_x }, .b = .{ .object = a_id, .feature = .origin_x }, .value = 20 }});
    try h.do(&m, .setConstraintPlace, .{ k, .{ .across = 7.5, .along = 0.8 } });
    try testing.expectEqual(7.5, m.constraints.items[0].place.across);
    // Placing it moves nothing.
    try testing.expectApproxEqAbs(@as(f64, 30), artAt(&m, c, 1).x, 1e-9);
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(0.8, back.constraints.items[0].place.along);
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.constraints.items[0].place.across);
}

test "a column in a panel keeps to construction lines on the canvas; values are never negative" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.placePanel(.{ .name = "P", .space = m.spaces.items[0].id, .origin = .{ .x = 30, .y = 20 }, .w = 200, .h = 140 });
    const body = try m.addStyle("Body", .{ .cap_height = 3 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "Column1", .origin = .{ .x = 20, .y = 110 }, .style = body, .count = 12, .length = 20, .pitch = 6 });
    const gi = try m.addGuide(0, .{ .x = 0, .y = 150 }, 0);
    m.spaces.items[0].guides.items[gi].lock = .horizontal;
    const gid = m.spaces.items[0].guides.items[gi].id;
    const vi = try m.addGuide(0, .{ .x = 40, .y = 0 }, 90);
    m.spaces.items[0].guides.items[vi].lock = .vertical;
    const vid = m.spaces.items[0].guides.items[vi].id;
    try h.reset(&m);
    const rid = m.panels.items[p].regions.items[r].id;
    // Its top 10 mm below the horizontal line (given signed, kept as a
    // distance and a side), its left 7 mm right of the vertical one.
    const top = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .top }, .b = .{ .object = gid, .feature = .origin_y }, .value = -10 }});
    _ = try h.do(&m, .addConstraint, .{.{ .a = .{ .object = rid, .feature = .left }, .b = .{ .object = vid, .feature = .origin_x }, .value = 7 }});
    try testing.expectEqual(10, m.constraints.items[0].value);
    try testing.expectEqual(-1, m.constraints.items[0].side);
    const issues = try check(&m, gpa);
    defer gpa.free(issues);
    try testing.expectEqual(0, issues.len);
    // In the panel's frame: 140 − 20 up, 47 − 30 across.
    const b = boxOf(&m, rid).?;
    try testing.expectApproxEqAbs(@as(f64, 120), b.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 17), b.x0, 1e-9);
    // A negative value is refused; the side stays.
    try testing.expectError(error.BadConstraint, h.do(&m, .setConstraintValue, .{ top, -4 }));
    try h.do(&m, .setConstraintValue, .{ top, 4 });
    try testing.expectApproxEqAbs(@as(f64, 126), boxOf(&m, rid).?.y1, 1e-9);
    // An older file's signed value reads as a distance and a side.
    m.constraints.items[1].value = -7;
    m.constraints.items[1].side = 1;
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(7, back.constraints.items[1].value);
    try testing.expectEqual(-1, back.constraints.items[1].side);
}
