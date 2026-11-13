//! Parametric sketches: 2D geometry held by constraints, in the manner of
//! FreeCAD's Sketcher, solved together.
//!
//! A sketch's unknowns are plain numbers (`vars`): the coordinates of its
//! points, circles' radii, infinite lines' angle and offset, rays' angles.
//! Geometry refers to them; constraints are equations between them, each
//! one or two residuals that are zero when it holds. `solve` moves the
//! unknowns the least it can to make every residual zero (so what is left
//! free stays where it was drawn), and `analyse` reports what is left free
//! (degrees of freedom), whether the sketch is fully constrained, and which
//! constraints are redundant or conflict.
//!
//! Every sketch has three reference geometries to constrain against: its
//! origin point and its horizontal and vertical axes. They are fixed, never
//! output, and never removed. Infinite lines and rays are construction
//! geometry only. Coordinates are mm, angles radians, y up.
//!
//! A sketch knows nothing of what uses it (tiles, panels).

const std = @import("std");
const geom = @import("graven_geom");
pub const dual = @import("dual.zig");
pub const solver = @import("solve.zig");
pub const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Box = geom.Box;
const D = dual.D;
const V = dual.V;

pub const VarId = u32;
pub const GeomId = u32;
pub const ConstraintId = u32;

/// A point's two unknowns.
pub const Pt = struct { x: VarId, y: VarId };

pub const Geometry = struct {
    kind: union(enum) {
        point: Pt,
        segment: struct { a: Pt, b: Pt },
        circle: struct { c: Pt, r: VarId },
        /// Counter-clockwise from `a` to `b` about `c`; its radius is
        /// |a - c|, and an internal equation keeps |b - c| the same.
        arc: struct { c: Pt, a: Pt, b: Pt },
        /// Infinite: the points p with n·p = rho, n = (cos theta, sin theta).
        line: struct { theta: VarId, rho: VarId },
        /// From `o` in direction (cos angle, sin angle), without end.
        ray: struct { o: Pt, angle: VarId },
    },
    /// Construction geometry guides and is constrained like any other, but
    /// is never output. Infinite lines and rays are always construction.
    construction: bool = false,
    /// The sketch's origin and axes: fixed, never output or removed.
    reference: bool = false,
    /// Removed: kept in place so IDs hold, its unknowns fixed, ignored.
    removed: bool = false,
};

/// A point of a geometry: a point itself, a segment's or arc's start or
/// end, a circle's or arc's centre, a ray's origin.
pub const PointRef = struct {
    geom: GeomId,
    role: enum { point, start, end, centre, origin } = .point,
};

/// A straight thing, or two points whose join is meant.
pub const Linear = union(enum) {
    geom: GeomId,
    points: [2]PointRef,
};

pub const Constraint = struct {
    kind: union(enum) {
        coincident: [2]PointRef,
        horizontal: Linear,
        vertical: Linear,
        /// On a line, segment (or its line), ray (or its line), circle or arc
        /// (or its circle).
        point_on: struct { p: PointRef, on: GeomId },
        fixed: struct { p: PointRef, at: Point },
        distance: struct { a: PointRef, b: PointRef, value: f64 },
        /// b.x - a.x, and b.y - a.y.
        distance_x: struct { a: PointRef, b: PointRef, value: f64 },
        distance_y: struct { a: PointRef, b: PointRef, value: f64 },
        /// From a point to a straight geometry, on the side it was on when
        /// the constraint was made (`side`, set by `addConstraint`).
        line_distance: struct { p: PointRef, line: GeomId, value: f64, side: f64 = 1 },
        radius: struct { g: GeomId, value: f64 },
        /// From `a`'s direction to `b`'s, counter-clockwise.
        angle: struct { a: GeomId, b: GeomId, value: f64 },
        /// Two straight geometries.
        parallel: struct { a: GeomId, b: GeomId },
        perpendicular: struct { a: GeomId, b: GeomId },
        /// A straight geometry and a circle or arc, or two circles or arcs,
        /// touching: on the side, and (for two round ones) outside or
        /// inside each other, as they were when it was made (set by
        /// `addConstraint`).
        tangent: struct { a: GeomId, b: GeomId, side: f64 = 1, internal: bool = false },
        /// Two segments of one length, or two circles or arcs of one radius.
        equal: struct { a: GeomId, b: GeomId },
        /// `p` and `q` mirrored about a straight geometry (`line`), or
        /// about a point (`point`): one of them.
        symmetric: struct { p: PointRef, q: PointRef, line: ?GeomId = null, point: ?PointRef = null },
    },
    name: []const u8 = "",
    /// Driving: it sets the geometry. Reference (a dimension only): it
    /// reports what the geometry measures, and takes no part in solving.
    driving: bool = true,
    /// For a dimension: an expression of the sketch's parameters that sets
    /// its value (mm, or degrees for an angle) each time it is solved;
    /// empty for a plain value.
    expr: []const u8 = "",

    /// Whether it has a value (a dimension).
    pub fn isDimension(c: Constraint) bool {
        return switch (c.kind) {
            .distance, .distance_x, .distance_y, .line_distance, .radius, .angle => true,
            else => false,
        };
    }
};

/// A named parameter: an expression (often a plain number) other
/// expressions may use by name.
pub const Param = struct {
    name: []const u8,
    expr: []const u8,
};

pub const Error = Allocator.Error || error{ NoSuchGeometry, NoSuchPoint, WrongKind, NotConstruction, NoSuchConstraint, BadName, NoSuchParameter };

pub const origin: GeomId = 0;
pub const h_axis: GeomId = 1;
pub const v_axis: GeomId = 2;

/// A sketch's data, unmanaged: whoever holds it passes the allocator its
/// lists live in (`a`), and scratch space for solving (`gpa`).
pub const Sketch = struct {
    vars: std.ArrayList(f64) = .empty,
    /// Per var: fixed (the reference geometry's), not an unknown.
    fixed: std.ArrayList(bool) = .empty,
    geometry: std.ArrayList(Geometry) = .empty,
    constraints: std.ArrayList(Constraint) = .empty,
    params: std.ArrayList(Param) = .empty,

    pub fn init(a: Allocator) Error!Sketch {
        var s: Sketch = .{};
        errdefer s.deinit(a);
        const o = try s.pt(a, .{ .x = 0, .y = 0 }, true);
        try s.geometry.append(a, .{ .kind = .{ .point = o }, .construction = true, .reference = true });
        try s.geometry.append(a, .{ .kind = .{ .line = .{ .theta = try s.newVar(a, std.math.pi / 2.0, true), .rho = try s.newVar(a, 0, true) } }, .construction = true, .reference = true });
        try s.geometry.append(a, .{ .kind = .{ .line = .{ .theta = try s.newVar(a, 0, true), .rho = try s.newVar(a, 0, true) } }, .construction = true, .reference = true });
        return s;
    }

    pub fn deinit(s: *Sketch, a: Allocator) void {
        s.vars.deinit(a);
        s.fixed.deinit(a);
        s.geometry.deinit(a);
        s.constraints.deinit(a);
        s.params.deinit(a);
    }

    /// A copy in `a`, sharing nothing with this one (constraint names
    /// included).
    pub fn clone(s: *const Sketch, a: Allocator) Allocator.Error!Sketch {
        var c: Sketch = .{};
        try c.vars.appendSlice(a, s.vars.items);
        try c.fixed.appendSlice(a, s.fixed.items);
        try c.geometry.appendSlice(a, s.geometry.items);
        try c.constraints.appendSlice(a, s.constraints.items);
        for (c.constraints.items) |*k| {
            k.name = try a.dupe(u8, k.name);
            k.expr = try a.dupe(u8, k.expr);
        }
        for (s.params.items) |p| try c.params.append(a, .{ .name = try a.dupe(u8, p.name), .expr = try a.dupe(u8, p.expr) });
        return c;
    }

    fn newVar(s: *Sketch, a: Allocator, v: f64, fixed: bool) Allocator.Error!VarId {
        try s.vars.append(a, v);
        try s.fixed.append(a, fixed);
        return @intCast(s.vars.items.len - 1);
    }

    fn pt(s: *Sketch, a: Allocator, p: Point, fixed: bool) Allocator.Error!Pt {
        return .{ .x = try s.newVar(a, p.x, fixed), .y = try s.newVar(a, p.y, fixed) };
    }

    fn add(s: *Sketch, a: Allocator, g: Geometry) Allocator.Error!GeomId {
        try s.geometry.append(a, g);
        return @intCast(s.geometry.items.len - 1);
    }

    pub fn addPoint(s: *Sketch, a: Allocator, at: Point, construction: bool) Error!GeomId {
        return s.add(a, .{ .kind = .{ .point = try s.pt(a, at, false) }, .construction = construction });
    }

    pub fn addSegment(s: *Sketch, a: Allocator, p0: Point, p1: Point, construction: bool) Error!GeomId {
        return s.add(a, .{ .kind = .{ .segment = .{ .a = try s.pt(a, p0, false), .b = try s.pt(a, p1, false) } }, .construction = construction });
    }

    pub fn addCircle(s: *Sketch, a: Allocator, c: Point, r: f64, construction: bool) Error!GeomId {
        return s.add(a, .{ .kind = .{ .circle = .{ .c = try s.pt(a, c, false), .r = try s.newVar(a, r, false) } }, .construction = construction });
    }

    /// An arc about `c`, counter-clockwise from `p0` to the point at `p1`'s
    /// angle on the circle through `p0`.
    pub fn addArc(s: *Sketch, a: Allocator, c: Point, p0: Point, p1: Point, construction: bool) Error!GeomId {
        const r = @sqrt((p0.x - c.x) * (p0.x - c.x) + (p0.y - c.y) * (p0.y - c.y));
        const t = std.math.atan2(p1.y - c.y, p1.x - c.x);
        const end: Point = .{ .x = c.x + r * @cos(t), .y = c.y + r * @sin(t) };
        return s.add(a, .{ .kind = .{ .arc = .{ .c = try s.pt(a, c, false), .a = try s.pt(a, p0, false), .b = try s.pt(a, end, false) } }, .construction = construction });
    }

    /// An infinite line through `through` at `angle` to the horizontal:
    /// construction, always.
    pub fn addLine(s: *Sketch, a: Allocator, through: Point, angle: f64) Error!GeomId {
        const theta = angle + std.math.pi / 2.0;
        const rho = @cos(theta) * through.x + @sin(theta) * through.y;
        return s.add(a, .{ .kind = .{ .line = .{ .theta = try s.newVar(a, theta, false), .rho = try s.newVar(a, rho, false) } }, .construction = true });
    }

    /// A ray from `o` at `angle`: construction, always.
    pub fn addRay(s: *Sketch, a: Allocator, o: Point, angle: f64) Error!GeomId {
        return s.add(a, .{ .kind = .{ .ray = .{ .o = try s.pt(a, o, false), .angle = try s.newVar(a, angle, false) } }, .construction = true });
    }

    /// Removes geometry `g` and every constraint on it. Its ID stays
    /// taken; its unknowns are fixed, so they count for nothing.
    pub fn removeGeometry(s: *Sketch, g: GeomId) Error!void {
        const geo = try s.get(g);
        if (geo.reference) return error.WrongKind;
        geo.removed = true;
        var buf: [6]VarId = undefined;
        for (s.varsOf(geo.*, &buf)) |v| s.fixed.items[v] = true;
        var i: usize = s.constraints.items.len;
        while (i > 0) {
            i -= 1;
            if (refersTo(s.constraints.items[i], g)) _ = s.constraints.orderedRemove(i);
        }
    }

    /// The unknowns of a geometry, in `buf`.
    pub fn varsOf(_: *const Sketch, g: Geometry, buf: *[6]VarId) []VarId {
        const list: []const VarId = switch (g.kind) {
            .point => |p| &.{ p.x, p.y },
            .segment => |sg| &.{ sg.a.x, sg.a.y, sg.b.x, sg.b.y },
            .circle => |c| &.{ c.c.x, c.c.y, c.r },
            .arc => |ar| &.{ ar.c.x, ar.c.y, ar.a.x, ar.a.y, ar.b.x, ar.b.y },
            .line => |ln| &.{ ln.theta, ln.rho },
            .ray => |ry| &.{ ry.o.x, ry.o.y, ry.angle },
        };
        @memcpy(buf[0..list.len], list);
        return buf[0..list.len];
    }

    /// Moves point `r` towards `to` as far as its constraints let it: the
    /// sketch is solved with the point held at `to`, then without, so it
    /// settles back onto what its constraints allow, the least way.
    pub fn drag(s: *Sketch, a: Allocator, gpa: Allocator, r: PointRef, to: Point) Error!solver.Result {
        _ = try s.pointOf(r);
        try s.constraints.append(a, .{ .kind = .{ .fixed = .{ .p = r, .at = to } } });
        _ = try solver.solve(s, gpa);
        _ = s.constraints.pop();
        return s.solve(gpa);
    }

    /// Sets geometry `g` to construction or not (infinite lines and rays
    /// stay construction).
    pub fn setConstruction(s: *Sketch, g: GeomId, on: bool) Error!void {
        const geo = try s.get(g);
        if (geo.reference) return error.WrongKind;
        if (!on and (geo.kind == .line or geo.kind == .ray)) return error.NotConstruction;
        geo.construction = on;
    }

    fn get(s: *Sketch, g: GeomId) Error!*Geometry {
        if (g >= s.geometry.items.len or s.geometry.items[g].removed) return error.NoSuchGeometry;
        return &s.geometry.items[g];
    }

    /// The unknowns of point `r`.
    pub fn pointOf(s: *const Sketch, r: PointRef) Error!Pt {
        if (r.geom >= s.geometry.items.len or s.geometry.items[r.geom].removed) return error.NoSuchGeometry;
        return switch (s.geometry.items[r.geom].kind) {
            .point => |p| if (r.role == .point) p else error.NoSuchPoint,
            .segment => |sg| switch (r.role) {
                .start => sg.a,
                .end => sg.b,
                else => error.NoSuchPoint,
            },
            .circle => |c| if (r.role == .centre) c.c else error.NoSuchPoint,
            .arc => |a| switch (r.role) {
                .start => a.a,
                .end => a.b,
                .centre => a.c,
                else => error.NoSuchPoint,
            },
            .ray => |ry| if (r.role == .origin) ry.o else error.NoSuchPoint,
            .line => error.NoSuchPoint,
        };
    }

    /// Where point `r` is now.
    pub fn point(s: *const Sketch, r: PointRef) Error!Point {
        const p = try s.pointOf(r);
        return .{ .x = s.vars.items[p.x], .y = s.vars.items[p.y] };
    }

    /// Adds a constraint, checking what it refers to. A distance to a line
    /// keeps to the side the point is on now.
    pub fn addConstraint(s: *Sketch, a: Allocator, c_in: Constraint) Error!ConstraintId {
        var c = c_in;
        try s.check(c);
        switch (c.kind) {
            .line_distance => |*ld| {
                var local: Local = .{ .s = s };
                const d = try local.signedDistance(ld.p, ld.line);
                ld.side = if (d.v < 0) -1 else 1;
            },
            .tangent => |*t| {
                var local: Local = .{ .s = s };
                // The straight one first.
                if (local.isRound(t.a) and !local.isRound(t.b)) std.mem.swap(GeomId, &t.a, &t.b);
                if (local.isRound(t.a)) {
                    const ca = try local.round(t.a);
                    const cb = try local.round(t.b);
                    const d = ca.c.sub(cb.c).len().v;
                    t.internal = d < @max(ca.r.v, cb.r.v);
                    t.side = if (ca.r.v >= cb.r.v) 1 else -1;
                } else {
                    const d = try local.signedDistance(.{ .geom = t.b, .role = .centre }, t.a);
                    t.side = if (d.v < 0) -1 else 1;
                }
            },
            else => {},
        }
        try s.constraints.append(a, c);
        return @intCast(s.constraints.items.len - 1);
    }

    pub fn removeConstraint(s: *Sketch, id: ConstraintId) Error!void {
        if (id >= s.constraints.items.len) return error.NoSuchConstraint;
        _ = s.constraints.orderedRemove(id);
    }

    /// Sets a dimension's value (distance, radius, angle).
    pub fn setValue(s: *Sketch, id: ConstraintId, value: f64) Error!void {
        if (id >= s.constraints.items.len) return error.NoSuchConstraint;
        switch (s.constraints.items[id].kind) {
            inline .distance, .distance_x, .distance_y, .line_distance, .radius, .angle => |*d| d.value = value,
            else => return error.WrongKind,
        }
    }

    /// Makes a dimension driving or reference.
    pub fn setDriving(s: *Sketch, id: ConstraintId, on: bool) Error!void {
        if (id >= s.constraints.items.len) return error.NoSuchConstraint;
        const c = &s.constraints.items[id];
        if (!c.isDimension()) return error.WrongKind;
        c.driving = on;
    }

    /// Sets a dimension's expression (empty for a plain value), copied into
    /// `a`. An expression that does not evaluate is kept, and leaves the
    /// value as it was (see `exprError`).
    pub fn setExpr(s: *Sketch, a: Allocator, id: ConstraintId, text: []const u8) Error!void {
        if (id >= s.constraints.items.len) return error.NoSuchConstraint;
        const c = &s.constraints.items[id];
        if (!c.isDimension()) return error.WrongKind;
        c.expr = try a.dupe(u8, std.mem.trim(u8, text, " "));
    }

    /// Adds parameter `name`, or changes its expression.
    pub fn setParam(s: *Sketch, a: Allocator, name: []const u8, text: []const u8) Error!void {
        if (!expr.validName(name)) return error.BadName;
        const t = try a.dupe(u8, std.mem.trim(u8, text, " "));
        for (s.params.items) |*p| if (std.mem.eql(u8, p.name, name)) {
            p.expr = t;
            return;
        };
        try s.params.append(a, .{ .name = try a.dupe(u8, name), .expr = t });
    }

    pub fn removeParam(s: *Sketch, name: []const u8) Error!void {
        for (s.params.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
            _ = s.params.orderedRemove(i);
            return;
        };
        return error.NoSuchParameter;
    }

    fn lookup(ctx: *const anyopaque, name: []const u8, depth: u8) expr.Error!?f64 {
        const s: *const Sketch = @ptrCast(@alignCast(ctx));
        if (depth > 32) return error.Cycle;
        for (s.params.items) |p| if (std.mem.eql(u8, p.name, name)) {
            return try expr.eval(p.expr, .{ .ctx = s, .get = lookup, .depth = depth + 1 });
        };
        return null;
    }

    /// The value of expression `text` with this sketch's parameters.
    pub fn evalExpr(s: *const Sketch, text: []const u8) expr.Error!f64 {
        return expr.eval(text, .{ .ctx = s, .get = lookup });
    }

    /// A parameter's value.
    pub fn paramValue(s: *const Sketch, name: []const u8) expr.Error!f64 {
        return (try lookup(s, name, 0)) orelse error.UnknownName;
    }

    /// What is wrong with constraint `id`'s expression, if it has one.
    pub fn exprError(s: *const Sketch, id: ConstraintId) ?expr.Error {
        const c = s.constraints.items[id];
        if (c.expr.len == 0) return null;
        _ = s.evalExpr(c.expr) catch |e| return e;
        return null;
    }

    /// Sets each driving dimension with an expression to its value (angles
    /// from degrees).
    pub fn applyExpressions(s: *Sketch) void {
        for (s.constraints.items) |*c| {
            if (c.expr.len == 0 or !c.driving) continue;
            const v = s.evalExpr(c.expr) catch continue;
            switch (c.kind) {
                .angle => |*an| an.value = v * std.math.pi / 180,
                inline .distance, .distance_x, .distance_y, .line_distance, .radius => |*d| d.value = v,
                else => {},
            }
        }
    }

    /// What a dimension measures now (mm, or radians for an angle), whatever
    /// its value says.
    pub fn measure(s: *const Sketch, c: Constraint) ?f64 {
        var l: Local = .{ .s = s };
        var zero = c;
        switch (zero.kind) {
            .angle => |an| {
                const da = l.direction(an.a) catch return null;
                const db = l.direction(an.b) catch return null;
                return std.math.atan2(da.cross(db).v, da.dot(db).v);
            },
            inline .distance, .distance_x, .distance_y, .line_distance, .radius => |*d| d.value = 0,
            else => return null,
        }
        var out: [2]D = undefined;
        _ = l.residuals(zero, &out) catch return null;
        return out[0].v;
    }

    /// Sets each reference dimension's value to what it measures.
    pub fn updateReferences(s: *Sketch) void {
        for (s.constraints.items) |*c| {
            if (c.driving) continue;
            const v = s.measure(c.*) orelse continue;
            switch (c.kind) {
                inline .distance, .distance_x, .distance_y, .line_distance, .radius, .angle => |*d| d.value = v,
                else => {},
            }
        }
    }

    fn check(s: *Sketch, c: Constraint) Error!void {
        // Evaluating it checks every reference and kind.
        var local: Local = .{ .s = s };
        var out: [2]D = undefined;
        _ = try local.residuals(c, &out);
    }

    /// Solves the sketch in place (see `solver.solve`), with scratch
    /// space from `gpa`.
    pub fn solve(s: *Sketch, gpa: Allocator) Error!solver.Result {
        s.applyExpressions();
        const res = try solver.solve(s, gpa);
        s.updateReferences();
        return res;
    }

    /// What is left free, and what is redundant or conflicts (see
    /// `solver.analyse`), allocated from `out`.
    pub fn analyse(s: *Sketch, gpa: Allocator, out: Allocator) Error!solver.Analysis {
        return solver.analyse(s, gpa, out);
    }

    /// The geometry that is output: every geometry that is neither
    /// construction nor reference, as exact segments (arcs and circles as
    /// conics), allocated from `a`. Points draw nothing.
    pub fn physical(s: *const Sketch, a: Allocator) Allocator.Error![]geom.Segment {
        var out: std.ArrayList(geom.Segment) = .empty;
        for (s.geometry.items) |g| {
            if (g.construction or g.reference or g.removed) continue;
            try s.appendSegments(a, g, &out);
        }
        return out.items;
    }

    fn val(s: *const Sketch, p: Pt) Point {
        return .{ .x = s.vars.items[p.x], .y = s.vars.items[p.y] };
    }

    pub fn appendSegments(s: *const Sketch, a: Allocator, g: Geometry, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
        var buf: [4]geom.Segment = undefined;
        switch (g.kind) {
            .segment => |sg| try out.append(a, .{ .line = .{ s.val(sg.a), s.val(sg.b) } }),
            .circle => |c| try out.appendSlice(a, geom.arc(s.val(c.c), s.vars.items[c.r], 0, 2 * std.math.pi, &buf)),
            .arc => |ar| {
                const c = s.val(ar.c);
                const p0 = s.val(ar.a);
                const p1 = s.val(ar.b);
                const a0 = std.math.atan2(p0.y - c.y, p0.x - c.x);
                var sweep = std.math.atan2(p1.y - c.y, p1.x - c.x) - a0;
                if (sweep <= 0) sweep += 2 * std.math.pi;
                const r = @sqrt((p0.x - c.x) * (p0.x - c.x) + (p0.y - c.y) * (p0.y - c.y));
                const segs = geom.arc(c, r, a0, sweep, &buf);
                // Its ends exactly on its end points.
                segs[0].conic.p[0] = p0;
                segs[segs.len - 1].conic.p[2] = p1;
                try out.appendSlice(a, segs);
            },
            .point, .line, .ray => {},
        }
    }

    /// The sketch's box: the bounds of its bounded geometry, construction
    /// included (infinite lines and rays do not count). With only infinite
    /// geometry, the box takes in every ray's origin and every place where
    /// a horizontal and a vertical line cross, at least `min_size` mm each
    /// way. Null for a sketch with no geometry of its own.
    pub fn box(s: *const Sketch, a: Allocator) Allocator.Error!?Box {
        const min_size = 10.0;
        var b = Box.empty;
        var any = false;
        for (s.geometry.items) |g| {
            if (g.reference or g.removed) continue;
            any = true;
            switch (g.kind) {
                .point => |p| b = b.addPoint(s.val(p)),
                .line, .ray => {},
                else => {
                    var out: std.ArrayList(geom.Segment) = .empty;
                    defer out.deinit(a);
                    try s.appendSegments(a, g, &out);
                    for (out.items) |seg| b = b.join(seg.bounds());
                },
            }
        }
        if (!any) return null;
        if (b.isEmpty()) {
            const tol = 1e-12;
            for (s.geometry.items) |g| {
                if (g.reference or g.removed) continue;
                switch (g.kind) {
                    .ray => |r| b = b.addPoint(s.val(r.o)),
                    .line => |h| {
                        const th = s.vars.items[h.theta];
                        if (@abs(@cos(th)) > tol) continue; // not horizontal
                        const y = s.vars.items[h.rho] / @sin(th);
                        for (s.geometry.items) |g2| {
                            if (g2.reference or g2.removed or g2.kind != .line) continue;
                            const t2 = s.vars.items[g2.kind.line.theta];
                            if (@abs(@sin(t2)) > tol) continue; // not vertical
                            b = b.addPoint(.{ .x = s.vars.items[g2.kind.line.rho] / @cos(t2), .y = y });
                        }
                    },
                    else => {},
                }
            }
            if (b.isEmpty()) b = b.addPoint(.{ .x = 0, .y = 0 });
        }
        if (b.width() < min_size) {
            const m = (b.x0 + b.x1) / 2;
            b.x0 = @min(b.x0, m - min_size / 2);
            b.x1 = @max(b.x1, m + min_size / 2);
        }
        if (b.height() < min_size) {
            const m = (b.y0 + b.y1) / 2;
            b.y0 = @min(b.y0, m - min_size / 2);
            b.y1 = @max(b.y1, m + min_size / 2);
        }
        return b;
    }
};

/// Whether constraint `c` refers to geometry `g`.
pub fn refersTo(c: Constraint, g: GeomId) bool {
    const lin = struct {
        fn f(l: Linear, gg: GeomId) bool {
            return switch (l) {
                .geom => |x| x == gg,
                .points => |ps| ps[0].geom == gg or ps[1].geom == gg,
            };
        }
    }.f;
    return switch (c.kind) {
        .coincident => |ps| ps[0].geom == g or ps[1].geom == g,
        .horizontal, .vertical => |l| lin(l, g),
        .point_on => |po| po.p.geom == g or po.on == g,
        .fixed => |f| f.p.geom == g,
        inline .distance, .distance_x, .distance_y => |d| d.a.geom == g or d.b.geom == g,
        .line_distance => |d| d.p.geom == g or d.line == g,
        .radius => |r| r.g == g,
        inline .angle, .parallel, .perpendicular, .tangent, .equal => |an| an.a == g or an.b == g,
        .symmetric => |sy| sy.p.geom == g or sy.q.geom == g or (sy.line != null and sy.line.? == g) or (sy.point != null and sy.point.?.geom == g),
    };
}

/// One constraint's residuals as duals over its own unknowns (at most
/// `dual.n` of them), for its exact Jacobian row.
pub const Local = struct {
    s: *const Sketch,
    ids: [dual.n]VarId = undefined,
    count: usize = 0,

    /// Var `id` as a dual: seeded when it is an unknown, constant when fixed.
    fn get(l: *Local, id: VarId) D {
        const v = l.s.vars.items[id];
        if (l.s.fixed.items[id]) return D.c(v);
        for (l.ids[0..l.count], 0..) |x, i| if (x == id) return D.seed(v, i);
        std.debug.assert(l.count < dual.n);
        l.ids[l.count] = id;
        l.count += 1;
        return D.seed(v, l.count - 1);
    }

    fn p(l: *Local, q: Pt) V {
        return .{ .x = l.get(q.x), .y = l.get(q.y) };
    }

    fn ref(l: *Local, r: PointRef) Error!V {
        return l.p(try l.s.pointOf(r));
    }

    fn geo(l: *Local, g: GeomId) Error!Geometry {
        if (g >= l.s.geometry.items.len or l.s.geometry.items[g].removed) return error.NoSuchGeometry;
        return l.s.geometry.items[g];
    }

    /// The unit direction of a straight geometry.
    fn direction(l: *Local, g: GeomId) Error!V {
        return switch ((try l.geo(g)).kind) {
            .segment => |sg| l.p(sg.b).sub(l.p(sg.a)).unit(),
            .line => |ln| blk: {
                const th = l.get(ln.theta);
                break :blk .{ .x = th.sin().scale(-1), .y = th.cos() };
            },
            .ray => |r| blk: {
                const an = l.get(r.angle);
                break :blk .{ .x = an.cos(), .y = an.sin() };
            },
            else => error.WrongKind,
        };
    }

    /// The signed distance from point `r` to straight geometry `g`,
    /// positive to its left.
    fn signedDistance(l: *Local, r: PointRef, g: GeomId) Error!D {
        const q = try l.ref(r);
        return switch ((try l.geo(g)).kind) {
            .segment => |sg| blk: {
                const a = l.p(sg.a);
                const d = l.p(sg.b).sub(a);
                break :blk d.cross(q.sub(a)).div(d.len());
            },
            .line => |ln| blk: {
                const th = l.get(ln.theta);
                // n·q - rho, with n to the line direction's right: negate.
                break :blk th.cos().mul(q.x).add(th.sin().mul(q.y)).sub(l.get(ln.rho)).scale(-1);
            },
            .ray => |ry| blk: {
                const an = l.get(ry.angle);
                const d: V = .{ .x = an.cos(), .y = an.sin() };
                break :blk d.cross(q.sub(l.p(ry.o)));
            },
            else => error.WrongKind,
        };
    }

    fn isRound(l: *Local, g: GeomId) bool {
        const geo_ = l.geo(g) catch return false;
        return geo_.kind == .circle or geo_.kind == .arc;
    }

    /// A circle's or arc's centre and radius.
    fn round(l: *Local, g: GeomId) Error!struct { c: V, r: D } {
        return switch ((try l.geo(g)).kind) {
            .circle => |ci| .{ .c = l.p(ci.c), .r = l.get(ci.r) },
            .arc => |ar| blk: {
                const c = l.p(ar.c);
                break :blk .{ .c = c, .r = l.p(ar.a).sub(c).len() };
            },
            else => error.WrongKind,
        };
    }

    fn segLength(l: *Local, g: GeomId) Error!D {
        return switch ((try l.geo(g)).kind) {
            .segment => |sg| l.p(sg.b).sub(l.p(sg.a)).len(),
            else => error.WrongKind,
        };
    }

    fn horizontalOrVertical(l: *Local, lin: Linear, vertical: bool) Error!D {
        switch (lin) {
            .points => |ps| {
                const a = try l.ref(ps[0]);
                const b = try l.ref(ps[1]);
                return if (vertical) b.x.sub(a.x) else b.y.sub(a.y);
            },
            .geom => |g| return switch ((try l.geo(g)).kind) {
                .segment => |sg| if (vertical) l.get(sg.b.x).sub(l.get(sg.a.x)) else l.get(sg.b.y).sub(l.get(sg.a.y)),
                // A horizontal line's normal is vertical: cos theta = 0.
                .line => |ln| if (vertical) l.get(ln.theta).sin() else l.get(ln.theta).cos(),
                .ray => |r| if (vertical) l.get(r.angle).cos() else l.get(r.angle).sin(),
                else => error.WrongKind,
            },
        }
    }

    /// The constraint's residuals into `out`; how many (1 or 2).
    pub fn residuals(l: *Local, c: Constraint, out: *[2]D) Error!usize {
        switch (c.kind) {
            .coincident => |ps| {
                const a = try l.ref(ps[0]);
                const b = try l.ref(ps[1]);
                out[0] = b.x.sub(a.x);
                out[1] = b.y.sub(a.y);
                return 2;
            },
            .horizontal => |lin| out[0] = try l.horizontalOrVertical(lin, false),
            .vertical => |lin| out[0] = try l.horizontalOrVertical(lin, true),
            .point_on => |po| {
                const g = try l.geo(po.on);
                out[0] = switch (g.kind) {
                    .segment, .line, .ray => try l.signedDistance(po.p, po.on),
                    .circle => |ci| (try l.ref(po.p)).sub(l.p(ci.c)).len().sub(l.get(ci.r)),
                    .arc => |ar| blk: {
                        const cc = l.p(ar.c);
                        break :blk (try l.ref(po.p)).sub(cc).len().sub(l.p(ar.a).sub(cc).len());
                    },
                    .point => return error.WrongKind,
                };
            },
            .fixed => |f| {
                const q = try l.ref(f.p);
                out[0] = q.x.sub(D.c(f.at.x));
                out[1] = q.y.sub(D.c(f.at.y));
                return 2;
            },
            .distance => |d| out[0] = (try l.ref(d.b)).sub(try l.ref(d.a)).len().sub(D.c(d.value)),
            .distance_x => |d| out[0] = (try l.ref(d.b)).x.sub((try l.ref(d.a)).x).sub(D.c(d.value)),
            .distance_y => |d| out[0] = (try l.ref(d.b)).y.sub((try l.ref(d.a)).y).sub(D.c(d.value)),
            .line_distance => |d| out[0] = (try l.signedDistance(d.p, d.line)).scale(d.side).sub(D.c(d.value)),
            .radius => |r| out[0] = switch ((try l.geo(r.g)).kind) {
                .circle => |ci| l.get(ci.r).sub(D.c(r.value)),
                .arc => |ar| l.p(ar.a).sub(l.p(ar.c)).len().sub(D.c(r.value)),
                else => return error.WrongKind,
            },
            .angle => |an| {
                // sin(phi - value), phi the angle from a to b.
                const da = try l.direction(an.a);
                const db = try l.direction(an.b);
                out[0] = da.cross(db).scale(@cos(an.value)).sub(da.dot(db).scale(@sin(an.value)));
            },
            .parallel => |pa| out[0] = (try l.direction(pa.a)).cross(try l.direction(pa.b)),
            .perpendicular => |pa| out[0] = (try l.direction(pa.a)).dot(try l.direction(pa.b)),
            .tangent => |t| {
                if (l.isRound(t.a) and l.isRound(t.b)) {
                    // Two round ones: centres apart by the radii's sum, or
                    // (one inside the other) their difference.
                    const ca = try l.round(t.a);
                    const cb = try l.round(t.b);
                    const d = ca.c.sub(cb.c).len();
                    out[0] = if (t.internal) d.sub(ca.r.sub(cb.r).scale(t.side)) else d.sub(ca.r.add(cb.r));
                } else {
                    // The centre as far from the line as the radius (in
                    // either order: `addConstraint` puts the line first).
                    const line, const rnd = if (l.isRound(t.a)) .{ t.b, t.a } else .{ t.a, t.b };
                    const cb = try l.round(rnd);
                    out[0] = (try l.signedDistance(.{ .geom = rnd, .role = .centre }, line)).scale(t.side).sub(cb.r);
                }
            },
            .equal => |e| {
                if (l.isRound(e.a) and l.isRound(e.b)) {
                    out[0] = (try l.round(e.a)).r.sub((try l.round(e.b)).r);
                } else out[0] = (try l.segLength(e.a)).sub(try l.segLength(e.b));
            },
            .symmetric => |sy| {
                const pp = try l.ref(sy.p);
                const q = try l.ref(sy.q);
                if (sy.line) |ln| {
                    // The midpoint on the line, and the join across it.
                    const d = try l.direction(ln);
                    const mid: V = .{ .x = pp.x.add(q.x).scale(0.5), .y = pp.y.add(q.y).scale(0.5) };
                    const o: V = switch ((try l.geo(ln)).kind) {
                        .segment => |sg| l.p(sg.a),
                        .ray => |ry| l.p(ry.o),
                        .line => |li| blk: {
                            const th = l.get(li.theta);
                            const rho = l.get(li.rho);
                            break :blk .{ .x = th.cos().mul(rho), .y = th.sin().mul(rho) };
                        },
                        else => return error.WrongKind,
                    };
                    out[0] = d.cross(mid.sub(o));
                    out[1] = d.dot(q.sub(pp));
                    return 2;
                }
                const m = try l.ref(sy.point orelse return error.WrongKind);
                out[0] = pp.x.add(q.x).sub(m.x.scale(2));
                out[1] = pp.y.add(q.y).sub(m.y.scale(2));
                return 2;
            },
        }
        return 1;
    }

    /// An arc's own equation: its end on its circle.
    pub fn arcResidual(l: *Local, ar: @FieldType(@FieldType(Geometry, "kind"), "arc")) D {
        const cc = l.p(ar.c);
        return l.p(ar.b).sub(cc).len().sub(l.p(ar.a).sub(cc).len());
    }
};

test {
    _ = dual;
    _ = solver;
    _ = expr;
    _ = @import("tests.zig");
}
