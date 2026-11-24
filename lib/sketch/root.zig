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
pub const constraint = @import("graven_constraint");
pub const dual = constraint.dual;
pub const solver = @import("solve.zig");
pub const expr = constraint.expr;
/// Arrays (polar and rectangular) as plain geometry and constraints.
pub const arrays = @import("arrays.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Box = geom.Box;
const D = dual.D;
const V = dual.V;

pub const geometry = constraint.geometry;
pub const VarId = geometry.VarId;
pub const GeomId = geometry.GeomId;
pub const ConstraintId = geometry.ConstraintId;
pub const Pt = geometry.Pt;
pub const Geometry = geometry.Geometry;
pub const PointRef = geometry.PointRef;
pub const Span = geometry.Span;
pub const Linear = geometry.Linear;
pub const Constraint = geometry.Constraint;
pub const Local = geometry.Local;
pub const refersTo = geometry.refersTo;
pub const Ref = geometry.Ref;
pub const refs = geometry.refs;

/// A named parameter: an expression (often a plain number) other
/// expressions may use by name.
pub const Param = struct {
    name: []const u8,
    expr: []const u8,
};

pub const Error = Allocator.Error || error{ NoSuchGeometry, NoSuchPoint, WrongKind, NotConstruction, NoSuchConstraint, BadName, NoSuchParameter, Negative };

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
        for (c.geometry.items) |*g| g.physical_when = try a.dupe(u8, g.physical_when);
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
            // Placed by others' unknowns (a document's boxes), never a
            // sketch's own.
            .affine => &.{},
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
    /// Makes construction geometry `g` output while parameter `param` is
    /// not 0 (empty: never). Not for infinite lines and rays.
    pub fn setPhysicalWhen(s: *Sketch, a: Allocator, g: GeomId, param: []const u8) Error!void {
        const geo = try s.get(g);
        if (geo.reference or geo.kind == .line or geo.kind == .ray) return error.WrongKind;
        if (param.len > 0 and !expr.validName(param)) return error.BadName;
        geo.physical_when = try a.dupe(u8, param);
    }

    /// Whether geometry `g` is output: neither construction (unless its
    /// parameter switches it on) nor reference, nor removed.
    pub fn isOutput(s: *const Sketch, g: Geometry) bool {
        if (g.reference or g.removed or g.kind == .line or g.kind == .ray) return false;
        if (!g.construction) return true;
        if (g.physical_when.len == 0) return false;
        const v = s.paramValue(g.physical_when) catch return false;
        return v != 0;
    }

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

    /// The sketch as a solve sees it.
    pub fn store(s: *const Sketch) geometry.Store {
        return .{ .vars = s.vars.items, .fixed = s.fixed.items, .geometry = s.geometry.items };
    }

    /// The unknowns of point `r`.
    pub fn pointOf(s: *const Sketch, r: PointRef) Error!Pt {
        return s.store().pointOf(r);
    }

    /// Where point `r` is now.
    pub fn point(s: *const Sketch, r: PointRef) Error!Point {
        return s.store().point(r);
    }

    /// Adds a constraint, checking what it refers to. A distance to a line
    /// keeps to the side the point is on now.
    pub fn addConstraint(s: *Sketch, a: Allocator, c_in: Constraint) Error!ConstraintId {
        var c = c_in;
        try s.check(c);
        switch (c.kind) {
            // No distance is negative (the owner, 2026-11-24): the side
            // the points lie on is kept as they are now.
            inline .distance_x, .distance_y => |*d, k| {
                const pa = try s.point(d.a);
                const pb = try s.point(d.b);
                const run = if (k == .distance_x) pb.x - pa.x else pb.y - pa.y;
                d.side = if (run < 0) -1 else 1;
                d.value = @abs(d.value);
            },
            inline .distance, .radius => |*d| d.value = @abs(d.value),
            .line_distance => |*ld| {
                ld.value = @abs(ld.value);
                var local: Local = .{ .s = s.store() };
                const d = try local.signedDistance(ld.p, ld.line);
                ld.side = if (d.v < 0) -1 else 1;
            },
            .tangent => |*t| {
                var local: Local = .{ .s = s.store() };
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
    /// Sets a dimension's value: a distance or radius is never negative.
    pub fn setValue(s: *Sketch, id: ConstraintId, value: f64) Error!void {
        if (id >= s.constraints.items.len) return error.NoSuchConstraint;
        if (value < 0 and s.constraints.items[id].kind != .angle) return error.Negative;
        switch (s.constraints.items[id].kind) {
            inline .distance, .distance_x, .distance_y, .line_distance, .radius, .angle => |*d| d.value = value,
            else => return error.WrongKind,
        }
    }

    /// Where a dimension is drawn (placement only: nothing moves).
    pub fn setPlace(s: *Sketch, id: ConstraintId, place: constraint.dimension.Placement) Error!void {
        if (id >= s.constraints.items.len) return error.NoSuchConstraint;
        s.constraints.items[id].place = place;
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
        const v = s.evalExpr(c.expr) catch |e| return e;
        // A distance or radius that comes out negative is out of its
        // domain: no distance is negative.
        if (v < 0 and c.kind != .angle) return error.Domain;
        return null;
    }

    /// An older sketch's signed horizontal and vertical distances (a
    /// negative value, or an expression that comes out negative, before
    /// 2026-11-24) as distances that are never negative, their side kept.
    pub fn upgradeSigns(s: *Sketch, a: Allocator) Allocator.Error!void {
        for (s.constraints.items) |*c| switch (c.kind) {
            inline .distance_x, .distance_y => |*d| {
                const neg_expr = c.expr.len > 0 and if (s.evalExpr(c.expr)) |v| v < 0 else |_| false;
                if (!neg_expr and d.value >= 0) continue;
                d.value = @abs(d.value);
                d.side = -d.side;
                if (neg_expr) {
                    // "-w / 2" as "w / 2"; otherwise its negation.
                    const want = -(s.evalExpr(c.expr) catch unreachable);
                    const stripped = std.mem.trimStart(u8, c.expr, " ");
                    const rest = std.mem.trimStart(u8, stripped[1..], " ");
                    if (stripped[0] == '-' and rest.len > 0 and if (s.evalExpr(rest)) |v| @abs(v - want) < 1e-9 else |_| false) {
                        c.expr = try a.dupe(u8, rest);
                    } else c.expr = try std.fmt.allocPrint(a, "-({s})", .{c.expr});
                }
            },
            else => {},
        };
    }

    /// Sets each driving dimension with an expression to its value (angles
    /// from degrees).
    pub fn applyExpressions(s: *Sketch) void {
        for (s.constraints.items) |*c| {
            if (c.expr.len == 0 or !c.driving) continue;
            const v = s.evalExpr(c.expr) catch continue;
            if (v < 0 and c.kind != .angle) continue;
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
        var l: Local = .{ .s = s.store() };
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
                .angle => |*d| d.value = v,
                inline .distance, .distance_x, .distance_y, .line_distance, .radius => |*d| d.value = @abs(v),
                else => {},
            }
        }
    }

    fn check(s: *Sketch, c: Constraint) Error!void {
        // Evaluating it checks every reference and kind.
        var local: Local = .{ .s = s.store() };
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
            if (!s.isOutput(g)) continue;
            try s.appendSegments(a, g, &out);
        }
        return out.items;
    }

    /// The output geometry joined end to end into closed contours (pieces
    /// turned round as they need to be), and how many pieces were left that
    /// close no contour. Allocated from `a`.
    pub fn profiles(s: *const Sketch, a: Allocator) Allocator.Error!struct { contours: []geom.Contour, open: usize } {
        const segs = try s.physical(a);
        const used = try a.alloc(bool, segs.len);
        @memset(used, false);
        const near = struct {
            fn f(p: Point, q: Point) bool {
                return @abs(p.x - q.x) < 1e-9 and @abs(p.y - q.y) < 1e-9;
            }
        }.f;
        var contours: std.ArrayList(geom.Contour) = .empty;
        var open: usize = 0;
        for (segs, 0..) |first, i| {
            if (used[i]) continue;
            used[i] = true;
            var chain: std.ArrayList(geom.Segment) = .empty;
            try chain.append(a, first);
            var closed = near(first.end(), first.start());
            while (!closed) {
                const end = chain.items[chain.items.len - 1].end();
                const next = for (segs, 0..) |sg, k| {
                    if (used[k]) continue;
                    if (near(sg.start(), end)) break .{ k, sg };
                    if (near(sg.end(), end)) break .{ k, sg.reversed() };
                } else null;
                const nx = next orelse break;
                used[nx[0]] = true;
                try chain.append(a, nx[1]);
                closed = near(nx[1].end(), chain.items[0].start());
            }
            if (!closed) {
                open += chain.items.len;
                continue;
            }
            // Exactly closed: each piece starts where the last ended.
            for (chain.items[1..], 1..) |*sg, k| setStart(sg, chain.items[k - 1].end());
            setEnd(&chain.items[chain.items.len - 1], chain.items[0].start());
            try contours.append(a, .{ .segments = chain.items });
        }
        return .{ .contours = contours.items, .open = open };
    }

    fn setStart(sg: *geom.Segment, p: Point) void {
        switch (sg.*) {
            .conic => |*c| c.p[0] = p,
            inline else => |*q| q[0] = p,
        }
    }

    fn setEnd(sg: *geom.Segment, p: Point) void {
        switch (sg.*) {
            .conic => |*c| c.p[2] = p,
            inline else => |*q| q[q.len - 1] = p,
        }
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
            .point, .affine, .line, .ray => {},
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
                .affine, .line, .ray => {},
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


test {
    _ = dual;
    _ = solver;
    _ = expr;
    _ = @import("tests.zig");
    _ = arrays;
}
