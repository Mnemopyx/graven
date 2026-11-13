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
const geom = @import("graven_engine").geom;
const model = @import("model.zig");
const native = @import("native.zig");

const Allocator = std.mem.Allocator;
const Model = model.Model;
const ObjectId = model.ObjectId;
const Feature = model.Feature;

pub const Issue = struct {
    constraint: ObjectId,
    kind: enum {
        /// An end names an object that is not there (removed, say).
        missing_object,
        /// Its ends' objects are in different parents.
        cross_parent,
        /// It refers to its parent's edges, and the parent has none (an
        /// unbounded canvas or frame).
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
const Kind = enum { panel, region, art, image, control_point };
/// What an object sits in: a space (panels, images) or a panel (tracks,
/// line art), whose frame its position is in.
pub const Parent = union(enum) { space: usize, panel: usize };

const Loc = struct {
    kind: Kind,
    parent: Parent,
    /// Panel index (panels, and things in panels), or space index (images).
    holder: usize,
    index: usize = 0,
    /// A control point's index in its track's path.
    sub: usize = 0,
};

fn locate(m: *const Model, id: ObjectId) ?Loc {
    if (id == .none) return null;
    for (m.panels.items, 0..) |p, pi| {
        if (p.id == id) return if (p.unbounded) null else .{ .kind = .panel, .parent = .{ .space = p.space }, .holder = pi };
        for (p.regions.items, 0..) |r, k| {
            if (r.id == id) return .{ .kind = .region, .parent = .{ .panel = pi }, .holder = pi, .index = k };
            for (r.path.items, 0..) |cp, j| if (cp.id == id) return .{ .kind = .control_point, .parent = .{ .panel = pi }, .holder = pi, .index = k, .sub = j };
        }
        for (p.art.items, 0..) |x, k| if (x.id == id) return .{ .kind = .art, .parent = .{ .panel = pi }, .holder = pi, .index = k };
    }
    for (m.spaces.items, 0..) |s, si| for (s.images.items, 0..) |im, k| if (im.id == id) return .{ .kind = .image, .parent = .{ .space = si }, .holder = si, .index = k };
    return null;
}

fn parentEql(a: Parent, b: Parent) bool {
    return switch (a) {
        .space => |s| b == .space and b.space == s,
        .panel => |p| b == .panel and b.panel == p,
    };
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
    const p = &m.panels.items[loc.holder];
    return switch (loc.kind) {
        .panel => pick(p.box(), p.holds, vertical, true),
        .region => blk: {
            const r = p.regions.items[loc.index];
            break :blk pick(r.softArea(), r.holds, vertical, true);
        },
        .art => blk: {
            const x = p.art.items[loc.index];
            var b = x.box();
            if (b.isEmpty()) b = .{ .x0 = x.at.x, .y0 = x.at.y, .x1 = x.at.x, .y1 = x.at.y };
            break :blk pick(b, x.holds, vertical, false);
        },
        .image => blk: {
            const im = m.spaces.items[loc.holder].images.items[loc.index];
            break :blk pick(im.box(), im.holds, vertical, true);
        },
        .control_point => blk: {
            const at = controlPointAt(p.regions.items[loc.index], loc.sub);
            const v = if (vertical) at.y else at.x;
            break :blk .{ .lo = v, .hi = v, .f = 0, .resizable = false };
        },
    };
}

/// Where a track's control point is in its panel's frame: at the start of
/// a row, half a row in (as the editor draws the path).
pub fn controlPointAt(r: model.TileRegion, k: usize) geom.Point {
    const cp = r.path.items[k];
    return if (r.major == .row)
        .{ .x = r.origin.x + cp.along * r.pitch, .y = r.origin.y - (cp.across + 0.5) * r.pitch }
    else
        .{ .x = r.origin.x + (cp.across + 0.5) * r.pitch, .y = r.origin.y - cp.along * r.pitch };
}

/// Moves object `loc` on one axis so its origin is at `o` and its size
/// `s`.
fn place(m: *Model, loc: Loc, vertical: bool, o: f64, s: f64) void {
    const sh = shapeOf(m, loc, vertical);
    const lo = o - sh.f * s;
    const p = &m.panels.items[loc.holder];
    switch (loc.kind) {
        .panel => if (vertical) {
            p.origin.y = lo;
            p.h = s;
        } else {
            p.origin.x = lo;
            p.w = s;
        },
        .region => {
            const r = &p.regions.items[loc.index];
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
        },
        .control_point => {
            const r = &p.regions.items[loc.index];
            const cp = &r.path.items[loc.sub];
            // Back from the panel frame to u along and across.
            if (r.major == .row) {
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
    }
}

/// A feature of a parent, in the frame its children are placed in; null
/// for an edge of an unbounded space.
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
            if (p.unbounded) {
                bound = space_bound(m, p.space);
            } else {
                bound = .{ .x0 = 0, .y0 = 0, .x1 = p.w, .y1 = p.h };
                holds = p.holds;
            }
        },
    }
    if (f == .origin_x or f == .origin_y) {
        const b = bound orelse return 0;
        // A space's origin is its coordinates' origin; a panel's is its
        // object origin, in its own frame.
        if (parent == .space or m.panels.items[parent.panel].unbounded) return 0;
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
        .panel => |pi| m.panels.items[pi].space,
    };
}

/// Where a parent's frame sits in its space: a panel's origin corner (0
/// for a space, and for a space's unbounded panel).
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

/// What constraint `c` measures as things are now (the value it would
/// keep): an offset between its features, or a difference of sizes.
pub fn measure(m: *const Model, c: model.Constraint) ?f64 {
    const parent = parentOf(m, c.a.object) orelse return null;
    switch (c.kind) {
        .offset => return (featureAt(m, parent, c.a) orelse return null) - (featureAt(m, parent, c.b) orelse return null),
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
            const r = m.panels.items[loc.holder].regions.items[loc.index];
            if (r.major != .row) return null;
            const sid = r.style orelse return null;
            if (m.styleIndex(sid) == null) return null;
            const cap = m.textStyle(sid).spec.cap_height;
            // The first row is at the region's top.
            return .{ .g = 1 - at, .c = -(r.pitch + cap) / 2 };
        },
        else => return null,
    }
}

/// Solves every constraint, moving and resizing objects to meet them;
/// appends what cannot be met to `issues` when given. Spaces' panels are
/// solved before what is in the panels, so children follow a resized
/// panel.
pub fn solve(m: *Model, gpa: Allocator, issues: ?*std.ArrayList(Issue)) Allocator.Error!void {
    if (m.constraints.items.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Each constraint's parent, or why it has none.
    const parents = try a.alloc(?Parent, m.constraints.items.len);
    for (m.constraints.items, parents) |c, *par| {
        par.* = null;
        const la = locate(m, c.a.object) orelse {
            try note(gpa, issues, c.id, .missing_object);
            continue;
        };
        if (c.a.feature.vertical() != c.b.feature.vertical()) {
            try note(gpa, issues, c.id, .mixed_axes);
            continue;
        }
        if (c.kind == .offset) {
            const fa = shapeOf(m, la, c.a.feature.vertical()).f;
            const lacks_a = featureTerm(m, la, c.a.feature, fa) == null;
            const lacks_b = if (c.b.object == .none) c.b.feature == .baseline else if (locate(m, c.b.object)) |lb| featureTerm(m, lb, c.b.feature, shapeOf(m, lb, c.b.feature.vertical()).f) == null else false;
            if (lacks_a or lacks_b) {
                try note(gpa, issues, c.id, .no_feature);
                continue;
            }
        }
        if (c.b.object != .none) {
            const lb = locate(m, c.b.object) orelse {
                try note(gpa, issues, c.id, .missing_object);
                continue;
            };
            if (!parentEql(la.parent, lb.parent)) {
                try note(gpa, issues, c.id, .cross_parent);
                continue;
            }
        } else if (parentFeature(m, la.parent, if (c.kind == .offset) c.b.feature else if (c.b.feature.vertical()) .top else .right) == null) {
            try note(gpa, issues, c.id, .no_parent_edge);
            continue;
        }
        par.* = la.parent;
    }

    // Spaces first, then panels.
    for ([_]bool{ true, false }) |spaces| {
        var done: std.ArrayList(Parent) = .empty;
        for (parents) |par| {
            const p = par orelse continue;
            if ((p == .space) != spaces) continue;
            const seen = for (done.items) |d| {
                if (parentEql(d, p)) break true;
            } else false;
            if (seen) continue;
            try done.append(a, p);
            for ([_]bool{ false, true }) |vertical| try solveAxis(m, gpa, a, issues, parents, p, vertical);
        }
    }
}

fn note(gpa: Allocator, issues: ?*std.ArrayList(Issue), id: ObjectId, kind: @FieldType(Issue, "kind")) Allocator.Error!void {
    if (issues) |list| try list.append(gpa, .{ .constraint = id, .kind = kind });
}

/// The constraints of one parent on one axis.
fn solveAxis(m: *Model, gpa: Allocator, a: Allocator, issues: ?*std.ArrayList(Issue), parents: []const ?Parent, parent: Parent, vertical: bool) Allocator.Error!void {
    // The objects involved, each with its origin and size as unknowns
    // (a size only when the object may be resized).
    const Obj = struct { id: ObjectId, loc: Loc, shape: Shape, o_var: usize, s_var: ?usize };
    var objs: std.ArrayList(Obj) = .empty;
    var nvars: usize = 0;
    var rows_c: std.ArrayList(usize) = .empty;
    // What constraints are applied to (their `a` ends) may move; what they
    // only refer to stays, so it is no unknown at all.
    var driven: std.ArrayList(ObjectId) = .empty;
    for (m.constraints.items, parents, 0..) |c, par, ci| {
        const p = par orelse continue;
        if (!parentEql(p, parent) or c.a.feature.vertical() != vertical) continue;
        try rows_c.append(a, ci);
        try driven.append(a, c.a.object);
    }
    for (rows_c.items) |ci| {
        const c = m.constraints.items[ci];
        for ([_]model.ConstraintEnd{ c.a, c.b }) |end| {
            if (end.object == .none) continue;
            if (std.mem.indexOfScalar(ObjectId, driven.items, end.object) == null) continue;
            const known = for (objs.items) |o| {
                if (o.id == end.object) break true;
            } else false;
            if (!known) {
                const loc = locate(m, end.object).?;
                const sh = shapeOf(m, loc, vertical);
                const o_var = nvars;
                nvars += 1;
                const s_var: ?usize = if (sh.resizable) v: {
                    nvars += 1;
                    break :v nvars - 1;
                } else null;
                try objs.append(a, .{ .id = end.object, .loc = loc, .shape = sh, .o_var = o_var, .s_var = s_var });
            }
        }
    }
    if (rows_c.items.len == 0) return;

    // Where things are now, and how freely each unknown may give.
    const v0 = try a.alloc(f64, nvars);
    const weight = try a.alloc(f64, nvars);
    for (objs.items) |o| {
        const s0 = o.shape.hi - o.shape.lo;
        v0[o.o_var] = o.shape.lo + o.shape.f * s0;
        weight[o.o_var] = 1;
        if (o.s_var) |sv| {
            v0[sv] = s0;
            // Resizing gives less than moving.
            weight[sv] = 1e3;
        }
    }
    const objIndex = struct {
        fn f(list: []const Obj, id: ObjectId) ?usize {
            for (list, 0..) |o, i| if (o.id == id) return i;
            return null;
        }
    }.f;

    // One row per constraint: coefficients over the unknowns, and what
    // they must come to.
    const Row = struct { coef: []f64, rhs: f64, ci: usize };
    var rows: std.ArrayList(Row) = .empty;
    for (rows_c.items) |ci| {
        const c = m.constraints.items[ci];
        const coef = try a.alloc(f64, nvars);
        @memset(coef, 0);
        var rhs = c.value;
        for ([_]model.ConstraintEnd{ c.a, c.b }, [_]f64{ 1, -1 }) |end, sign| {
            if (end.object == .none) {
                // The parent: a constant, its feature or its size.
                switch (c.kind) {
                    .offset => rhs -= sign * parentFeature(m, parent, end.feature).?,
                    .equal_size => {
                        const lo = parentFeature(m, parent, if (vertical) .bottom else .left) orelse 0;
                        const hi = parentFeature(m, parent, if (vertical) .top else .right) orelse 0;
                        rhs -= sign * (hi - lo);
                    },
                }
                continue;
            }
            const o = objs.items[objIndex(objs.items, end.object) orelse {
                // A reference: its feature, or size, as it is.
                const rloc = locate(m, end.object).?;
                const sh = shapeOf(m, rloc, vertical);
                const size = sh.hi - sh.lo;
                const at = sh.lo + sh.f * size;
                rhs -= sign * switch (c.kind) {
                    .offset => blk: {
                        const t = featureTerm(m, rloc, end.feature, sh.f).?;
                        break :blk at + t.g * size + t.c;
                    },
                    .equal_size => size,
                };
                continue;
            }];
            const s0 = o.shape.hi - o.shape.lo;
            switch (c.kind) {
                .offset => {
                    coef[o.o_var] += sign;
                    const t = featureTerm(m, o.loc, end.feature, o.shape.f).?;
                    if (o.s_var) |sv| coef[sv] += sign * t.g else rhs -= sign * t.g * s0;
                    rhs -= sign * t.c;
                },
                .equal_size => if (o.s_var) |sv| {
                    coef[sv] += sign;
                } else {
                    rhs -= sign * s0;
                },
            }
        }
        try rows.append(a, .{ .coef = coef, .rhs = rhs, .ci = ci });
    }

    // Keep the rows that add something; flag those that contradict the
    // ones before them (and drop those that only repeat them).
    var basis: std.ArrayList(struct { coef: []f64, rhs: f64, pivot: usize }) = .empty;
    var kept: std.ArrayList(Row) = .empty;
    for (rows.items) |row| {
        const r = try a.dupe(f64, row.coef);
        var rhs = row.rhs;
        for (basis.items) |b| {
            const k = r[b.pivot] / b.coef[b.pivot];
            if (k == 0) continue;
            for (r, b.coef) |*x, y| x.* -= k * y;
            rhs -= k * b.rhs;
        }
        var pivot: usize = 0;
        var best: f64 = 0;
        for (r, 0..) |x, i| if (@abs(x) > best) {
            best = @abs(x);
            pivot = i;
        };
        if (best < 1e-9) {
            if (@abs(rhs) > 1e-6) try note(gpa, issues, m.constraints.items[row.ci].id, .conflict);
            continue;
        }
        try basis.append(a, .{ .coef = r, .rhs = rhs, .pivot = pivot });
        try kept.append(a, row);
    }
    const n = kept.items.len;
    if (n == 0) return;

    // The least weighted change meeting them all: v = v0 + W⁻¹Aᵀλ, where
    // (A W⁻¹ Aᵀ) λ = b − A v0.
    const mat = try a.alloc(f64, n * n);
    const lam = try a.alloc(f64, n);
    for (kept.items, 0..) |ri, i| {
        var av0: f64 = 0;
        for (ri.coef, v0) |c, v| av0 += c * v;
        lam[i] = ri.rhs - av0;
        for (kept.items, 0..) |rj, j| {
            var sum: f64 = 0;
            for (ri.coef, rj.coef, weight) |x, y, w| sum += x * y / w;
            mat[i * n + j] = sum;
        }
    }
    if (!gaussSolve(mat, lam, n)) return;
    const v = try a.dupe(f64, v0);
    for (kept.items, lam) |row, l| for (row.coef, 0..) |c, k| {
        v[k] += c * l / weight[k];
    };

    for (objs.items) |o| {
        const s = if (o.s_var) |sv| v[sv] else o.shape.hi - o.shape.lo;
        if (s < -1e-9) {
            for (kept.items) |row| {
                const c = m.constraints.items[row.ci];
                if (c.a.object == o.id or c.b.object == o.id) try note(gpa, issues, c.id, .inverted);
            }
        }
        place(m, o.loc, vertical, v[o.o_var], s);
    }
}

/// Solves `mat` x = `rhs` in place (x in `rhs`), with partial pivoting.
/// False when singular.
fn gaussSolve(mat: []f64, rhs: []f64, n: usize) bool {
    for (0..n) |col| {
        var piv = col;
        for (col + 1..n) |r| if (@abs(mat[r * n + col]) > @abs(mat[piv * n + col])) {
            piv = r;
        };
        if (@abs(mat[piv * n + col]) < 1e-15) return false;
        if (piv != col) {
            for (0..n) |k| std.mem.swap(f64, &mat[col * n + k], &mat[piv * n + k]);
            std.mem.swap(f64, &rhs[col], &rhs[piv]);
        }
        for (col + 1..n) |r| {
            const f = mat[r * n + col] / mat[col * n + col];
            if (f == 0) continue;
            for (col..n) |k| mat[r * n + k] -= f * mat[col * n + k];
            rhs[r] -= f * rhs[col];
        }
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var sum = rhs[i];
        for (i + 1..n) |k| sum -= mat[i * n + k] * rhs[k];
        rhs[i] = sum / mat[i * n + i];
    }
    return true;
}

/// What cannot be met, without moving anything: solves a copy.
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
    const c = try m.startCanvas(.mm);
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
    const c = try m.startCanvas(.mm);
    const p = try m.placePanel(.{ .name = "P", .space = 0, .origin = .{ .x = 0, .y = 0 }, .w = 100, .h = 60 });
    const style = try m.addStyle("Body", .{ .upright = 0, .cap_height = 3 });
    const r = try m.addTracks(p, .{ .name = "t", .origin = .{ .x = 9, .y = 52 }, .style = style, .count = 4, .length = 10, .pitch = 5 });
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
    const p1 = try m.placePanel(.{ .name = "A", .space = 0, .origin = .{ .x = 0, .y = 0 }, .w = 50, .h = 30 });
    const p2 = try m.placePanel(.{ .name = "B", .space = 0, .origin = .{ .x = 70, .y = 3 }, .w = 41, .h = 22 });
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
    const p = try m.placePanel(.{ .name = "P", .space = 0, .origin = .{ .x = 0, .y = 0 }, .w = 200, .h = 100 });
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 3 });
    const big = try m.addStyle("Big", .{ .upright = 0, .cap_height = 5 });
    const left = try m.addTracks(p, .{ .name = "left", .origin = .{ .x = 10, .y = 90 }, .style = body, .count = 5, .length = 10, .pitch = 6 });
    const right = try m.addTracks(p, .{ .name = "right", .origin = .{ .x = 110, .y = 83.7 }, .style = big, .count = 5, .length = 8, .pitch = 9 });
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
    const c = try m.startCanvas(.mm);
    for ([_]geom.Point{ .{ .x = 10, .y = 10 }, .{ .x = 40, .y = 12 }, .{ .x = 80, .y = 30 } }) |at| _ = try m.addArt(c, .{ .name = "x", .at = at, .shapes = &.{} });
    const frame = try m.addFrame("Frame", null);
    try h.reset(&m);
    const ids = [3]ObjectId{ m.panels.items[c].art.items[0].id, m.panels.items[c].art.items[1].id, m.panels.items[c].art.items[2].id };
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

test "a track's control point can be constrained, and the rows follow it" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.placePanel(.{ .name = "P", .space = 0, .origin = .{ .x = 0, .y = 0 }, .w = 200, .h = 120 });
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 3 });
    const r = try m.addTracks(p, .{ .name = "poem", .origin = .{ .x = 20, .y = 110 }, .style = body, .count = 12, .length = 20, .pitch = 6 });
    try h.reset(&m);
    const cp = try h.do(&m, .addControlPoint, .{ p, r, 2.0, 4.0 });
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
    const p = try m.placePanel(.{ .name = "P", .space = 0, .origin = .{ .x = 0, .y = 0 }, .w = 100, .h = 80 });
    const q = try m.placePanel(.{ .name = "Q", .space = 0, .origin = .{ .x = 150, .y = 0 }, .w = 40, .h = 40 });
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
