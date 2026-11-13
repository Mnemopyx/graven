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
    },
    name: []const u8 = "",
};

pub const Error = Allocator.Error || error{ NoSuchGeometry, NoSuchPoint, WrongKind, NotConstruction };

pub const origin: GeomId = 0;
pub const h_axis: GeomId = 1;
pub const v_axis: GeomId = 2;

pub const Sketch = struct {
    gpa: Allocator,
    vars: std.ArrayList(f64) = .empty,
    /// Per var: fixed (the reference geometry's), not an unknown.
    fixed: std.ArrayList(bool) = .empty,
    geometry: std.ArrayList(Geometry) = .empty,
    constraints: std.ArrayList(Constraint) = .empty,

    pub fn init(gpa: Allocator) Error!Sketch {
        var s: Sketch = .{ .gpa = gpa };
        errdefer s.deinit();
        const o = try s.pt(.{ .x = 0, .y = 0 }, true);
        try s.geometry.append(gpa, .{ .kind = .{ .point = o }, .construction = true, .reference = true });
        try s.geometry.append(gpa, .{ .kind = .{ .line = .{ .theta = try s.newVar(std.math.pi / 2.0, true), .rho = try s.newVar(0, true) } }, .construction = true, .reference = true });
        try s.geometry.append(gpa, .{ .kind = .{ .line = .{ .theta = try s.newVar(0, true), .rho = try s.newVar(0, true) } }, .construction = true, .reference = true });
        return s;
    }

    pub fn deinit(s: *Sketch) void {
        s.vars.deinit(s.gpa);
        s.fixed.deinit(s.gpa);
        s.geometry.deinit(s.gpa);
        s.constraints.deinit(s.gpa);
    }

    fn newVar(s: *Sketch, v: f64, fixed: bool) Allocator.Error!VarId {
        try s.vars.append(s.gpa, v);
        try s.fixed.append(s.gpa, fixed);
        return @intCast(s.vars.items.len - 1);
    }

    fn pt(s: *Sketch, p: Point, fixed: bool) Allocator.Error!Pt {
        return .{ .x = try s.newVar(p.x, fixed), .y = try s.newVar(p.y, fixed) };
    }

    fn add(s: *Sketch, g: Geometry) Allocator.Error!GeomId {
        try s.geometry.append(s.gpa, g);
        return @intCast(s.geometry.items.len - 1);
    }

    pub fn addPoint(s: *Sketch, at: Point, construction: bool) Error!GeomId {
        return s.add(.{ .kind = .{ .point = try s.pt(at, false) }, .construction = construction });
    }

    pub fn addSegment(s: *Sketch, a: Point, b: Point, construction: bool) Error!GeomId {
        return s.add(.{ .kind = .{ .segment = .{ .a = try s.pt(a, false), .b = try s.pt(b, false) } }, .construction = construction });
    }

    pub fn addCircle(s: *Sketch, c: Point, r: f64, construction: bool) Error!GeomId {
        return s.add(.{ .kind = .{ .circle = .{ .c = try s.pt(c, false), .r = try s.newVar(r, false) } }, .construction = construction });
    }

    /// An arc about `c`, counter-clockwise from `a` to the point at `b`'s
    /// angle on the circle through `a`.
    pub fn addArc(s: *Sketch, c: Point, a: Point, b: Point, construction: bool) Error!GeomId {
        const r = @sqrt((a.x - c.x) * (a.x - c.x) + (a.y - c.y) * (a.y - c.y));
        const t = std.math.atan2(b.y - c.y, b.x - c.x);
        const end: Point = .{ .x = c.x + r * @cos(t), .y = c.y + r * @sin(t) };
        return s.add(.{ .kind = .{ .arc = .{ .c = try s.pt(c, false), .a = try s.pt(a, false), .b = try s.pt(end, false) } }, .construction = construction });
    }

    /// An infinite line through `through` at `angle` to the horizontal:
    /// construction, always.
    pub fn addLine(s: *Sketch, through: Point, angle: f64) Error!GeomId {
        const theta = angle + std.math.pi / 2.0;
        const rho = @cos(theta) * through.x + @sin(theta) * through.y;
        return s.add(.{ .kind = .{ .line = .{ .theta = try s.newVar(theta, false), .rho = try s.newVar(rho, false) } }, .construction = true });
    }

    /// A ray from `o` at `angle`: construction, always.
    pub fn addRay(s: *Sketch, o: Point, angle: f64) Error!GeomId {
        return s.add(.{ .kind = .{ .ray = .{ .o = try s.pt(o, false), .angle = try s.newVar(angle, false) } }, .construction = true });
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
        if (g >= s.geometry.items.len) return error.NoSuchGeometry;
        return &s.geometry.items[g];
    }

    /// The unknowns of point `r`.
    pub fn pointOf(s: *const Sketch, r: PointRef) Error!Pt {
        if (r.geom >= s.geometry.items.len) return error.NoSuchGeometry;
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
    pub fn addConstraint(s: *Sketch, c_in: Constraint) Error!ConstraintId {
        var c = c_in;
        try s.check(c);
        switch (c.kind) {
            .line_distance => |*ld| {
                var local: Local = .{ .s = s };
                const d = try local.signedDistance(ld.p, ld.line);
                ld.side = if (d.v < 0) -1 else 1;
            },
            else => {},
        }
        try s.constraints.append(s.gpa, c);
        return @intCast(s.constraints.items.len - 1);
    }

    pub fn removeConstraint(s: *Sketch, id: ConstraintId) void {
        _ = s.constraints.orderedRemove(id);
    }

    fn check(s: *Sketch, c: Constraint) Error!void {
        // Evaluating it checks every reference and kind.
        var local: Local = .{ .s = s };
        var out: [2]D = undefined;
        _ = try local.residuals(c, &out);
    }

    /// Solves the sketch in place (see `solver.solve`).
    pub fn solve(s: *Sketch) Error!solver.Result {
        return solver.solve(s);
    }

    /// What is left free, and what is redundant or conflicts (see
    /// `solver.analyse`), allocated from `a`.
    pub fn analyse(s: *Sketch, a: Allocator) Error!solver.Analysis {
        return solver.analyse(s, a);
    }

    /// The geometry that is output: every geometry that is neither
    /// construction nor reference, as exact segments (arcs and circles as
    /// conics), allocated from `a`. Points draw nothing.
    pub fn physical(s: *const Sketch, a: Allocator) Allocator.Error![]geom.Segment {
        var out: std.ArrayList(geom.Segment) = .empty;
        for (s.geometry.items) |g| {
            if (g.construction or g.reference) continue;
            try s.appendSegments(a, g, &out);
        }
        return out.items;
    }

    fn val(s: *const Sketch, p: Pt) Point {
        return .{ .x = s.vars.items[p.x], .y = s.vars.items[p.y] };
    }

    fn appendSegments(s: *const Sketch, a: Allocator, g: Geometry, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
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
            if (g.reference) continue;
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
                if (g.reference) continue;
                switch (g.kind) {
                    .ray => |r| b = b.addPoint(s.val(r.o)),
                    .line => |h| {
                        const th = s.vars.items[h.theta];
                        if (@abs(@cos(th)) > tol) continue; // not horizontal
                        const y = s.vars.items[h.rho] / @sin(th);
                        for (s.geometry.items) |g2| {
                            if (g2.reference or g2.kind != .line) continue;
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
        if (g >= l.s.geometry.items.len) return error.NoSuchGeometry;
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
    _ = @import("tests.zig");
}
