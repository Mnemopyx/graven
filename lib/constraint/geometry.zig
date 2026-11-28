//! Constraints on basic geometry (decided 2026-11-24, the owner: they act
//! on points, edges, intersections and distances, never on whatever
//! containers use them): points, segments, circles, arcs, infinite lines and
//! rays over plain unknowns, and the constraints between them, each one or
//! two residuals that are zero when it holds. Sketches keep their geometry
//! here; a document's containers hand theirs (corners as points, edges as
//! segments) the same way.

const std = @import("std");
const geom = @import("graven_geom");
const dual = @import("dual.zig");
const solve = @import("solve.zig");
const dimension = @import("dimension.zig");

const Point = geom.Point;
const D = dual.D;
const V = dual.V;

pub const Error = error{ NoSuchGeometry, NoSuchPoint, WrongKind };

pub const VarId = u32;
pub const GeomId = u32;
pub const ConstraintId = u32;
/// A group (`group.zig`); `no_group`: in none.
pub const GroupId = u32;
pub const no_group: GroupId = std.math.maxInt(u32);

/// A point's two unknowns.
pub const Pt = struct { x: VarId, y: VarId };

/// A coordinate that is a constant plus multiples of unknowns (at most
/// two): where an edge of a box lies, its origin less a fraction of its
/// size; a coordinate no unknown moves is its constant alone.
pub const Affine = struct {
    c: f64 = 0,
    vars: [2]VarId = .{ 0, 0 },
    k: [2]f64 = .{ 0, 0 },

    pub fn at(a: Affine, vars: []const f64) f64 {
        return a.c + a.k[0] * vars[a.vars[0]] + a.k[1] * vars[a.vars[1]];
    }
};

pub const Geometry = struct {
    kind: union(enum) {
        point: Pt,
        /// A point placed by unknowns that are not its own: each
        /// coordinate an `Affine` of them (a corner or edge of a box whose
        /// unknowns are its origin and size). Referred to as `.point`.
        affine: struct { x: Affine, y: Affine },
        segment: struct { a: Pt, b: Pt },
        circle: struct { c: Pt, r: VarId },
        /// Counter-clockwise from `a` to `b` about `c`; its radius is
        /// |a - c|, and an internal equation keeps |b - c| the same.
        arc: struct { c: Pt, a: Pt, b: Pt },
        /// Infinite: the points p with n·p = rho, n = (cos theta, sin theta).
        line: struct { theta: VarId, rho: VarId },
        /// From `o` in direction (cos angle, sin angle), without end.
        ray: struct { o: Pt, angle: VarId },
        /// A macro (see `PolarGrid`): its driving geometry as unknowns,
        /// its counts as properties.
        polar_grid: PolarGrid,
        /// A macro (see `Tessellation`): an area filled with tiles.
        tessellation: Tessellation,
    },
    /// Construction geometry guides and is constrained like any other, but
    /// is never output. Infinite lines and rays are always construction.
    construction: bool = false,
    /// The sketch's origin and axes: fixed, never output or removed.
    reference: bool = false,
    /// Removed: kept in place so IDs hold, its unknowns fixed, ignored.
    removed: bool = false,
    /// Construction geometry that is output all the same while this
    /// parameter's value is not 0 (empty: never). Whatever uses the sketch
    /// sets the parameter: a homing bump drawn as construction, made
    /// physical on the keys that ask for it.
    physical_when: []const u8 = "",
    /// The innermost group holding it (`group.zig`), or none.
    group: GroupId = no_group,
};

/// A point of a geometry: a point itself, a segment's or arc's start or
/// end, a circle's or arc's centre, a ray's origin; a macro's bind point
/// (`node`: a polar grid's `i`th angle, `j`th radius, either `last` for
/// the last, which stays the last whatever its count).
pub const PointRef = struct {
    geom: GeomId,
    role: enum { point, start, end, centre, origin, node } = .point,
    i: u32 = 0,
    j: u32 = 0,
};

/// A bind point's index meaning the last, whatever the count.
pub const last: u32 = std.math.maxInt(u32);

/// Which curve of a geometry is meant (the owner, 2026-11-28: indexed
/// curve references): the geometry itself (`whole`), or one of a macro's
/// curves by its index, as a bind point is: a polar grid's `k`th ring (an
/// arc or circle at its `k`th radius, across its sweep) or `k`th border (a
/// radial line at its `k`th angle, from its first radius to its second);
/// `last` for the last, which stays the last.
pub const Part = struct {
    role: enum { whole, ring, border } = .whole,
    k: u32 = 0,

    pub fn isWhole(p: Part) bool {
        return p.role == .whole;
    }
};

/// A polar grid, a macro object (the owner, 2026-11-27): held by its
/// driving geometry alone, a centre `c`, two radii `r` and two angles `t`
/// (radians), and by its counts, which are properties, not geometry. Its
/// sections run from angle `t[0]` to `t[1]` (`cols` of them; all the way
/// round when they are a turn apart) and from radius `r[0]` to `r[1]`
/// (`rings`); neither pair has an order, and a radius may be 0 (an inner
/// one over 0 leaves room, a switch stem's say). Changing a count moves no
/// unknown: only how many sections are drawn, and which bind points there
/// are, change. Its bind points (`PointRef.node`) are where its radial
/// borders meet its rings: computed from its unknowns, so the solver sees
/// them as it sees any point.
pub const PolarGrid = struct {
    c: Pt,
    r: [2]VarId,
    t: [2]VarId,
    cols: u32 = 1,
    rings: u32 = 1,

    /// Index `k` of a run of `n`, `last` read as `n`; null when past it.
    pub fn index(k: u32, n: u32) ?u32 {
        if (k == last) return n;
        return if (k <= n) k else null;
    }

    /// Whether it has bind point (i, j).
    pub fn has(g: PolarGrid, i: u32, j: u32) bool {
        return index(i, g.cols) != null and index(j, g.rings) != null;
    }

    /// Its whole sweep (radians, signed: from t[0] to t[1]).
    pub fn sweep(g: PolarGrid, vars: []const f64) f64 {
        return vars[g.t[1]] - vars[g.t[0]];
    }

    /// Whether it goes all the way round (its last border its first).
    pub fn full(g: PolarGrid, vars: []const f64) bool {
        return @abs(@abs(g.sweep(vars)) - 2 * std.math.pi) < 1e-9;
    }

    /// Its `i`th border's angle, `j`th ring's radius (indices in range).
    pub fn angle(g: PolarGrid, vars: []const f64, i: u32) f64 {
        const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(g.cols, 1)));
        return vars[g.t[0]] + (vars[g.t[1]] - vars[g.t[0]]) * f;
    }

    pub fn radius(g: PolarGrid, vars: []const f64, j: u32) f64 {
        const f = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(@max(g.rings, 1)));
        return vars[g.r[0]] + (vars[g.r[1]] - vars[g.r[0]]) * f;
    }

    /// Where bind point (i, j) is now.
    pub fn node(g: PolarGrid, vars: []const f64, i: u32, j: u32) Error!Point {
        const ii = index(i, g.cols) orelse return error.NoSuchPoint;
        const jj = index(j, g.rings) orelse return error.NoSuchPoint;
        const r = g.radius(vars, jj);
        const t = g.angle(vars, ii);
        return .{ .x = vars[g.c.x] + r * @cos(t), .y = vars[g.c.y] + r * @sin(t) };
    }

    /// Whether it has curve `p` (a ring or border within its counts; a
    /// ring at radius 0 is no curve, but is kept as an index).
    pub fn hasPart(g: PolarGrid, p: Part) bool {
        return switch (p.role) {
            .whole => false,
            .ring => index(p.k, g.rings) != null,
            .border => index(p.k, g.cols) != null,
        };
    }

    /// Its unknowns.
    pub fn unknowns(g: PolarGrid) [6]VarId {
        return .{ g.c.x, g.c.y, g.r[0], g.r[1], g.t[0], g.t[1] };
    }
};

/// A tessellation, a macro object (the owner, 2026-11-28): an area of
/// the sketch filled with tiles sharing their vertices (`geom.tessellate`).
/// Held by its driving values alone: a tile's centre `c` (the pattern's
/// offset, dragged or constrained like any point), the spacing of tile
/// centres, the pattern's turn and the margin kept clear inside the area,
/// all unknowns; its tile's sides and whether only whole tiles are kept
/// are properties. The area is a closed path of the sketch's own curves
/// (`outline`: its index in `Sketch.tilings`), followed as they change.
/// Its tiles are never stored: they are worked out from these.
pub const Tessellation = struct {
    c: Pt,
    spacing: VarId,
    angle: VarId,
    margin: VarId,
    /// 3, 4 or 6.
    sides: u32 = 6,
    /// Whole tiles only (else those crossing the edge are cut to it).
    whole: bool = false,
    outline: u32 = 0,

    pub fn unknowns(t: Tessellation) [5]VarId {
        return .{ t.c.x, t.c.y, t.spacing, t.angle, t.margin };
    }
};

/// A distance that can be held equal to another: between two points (straight,
/// or along x or y), or from a point to a straight geometry. Never
/// negative, whatever the order of its ends.
pub const Span = union(enum) {
    points: [2]PointRef,
    x: [2]PointRef,
    y: [2]PointRef,
    to_line: struct { p: PointRef, line: GeomId },
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
        point_on: struct { p: PointRef, on: GeomId, part: Part = .{} },
        fixed: struct { p: PointRef, at: Point },
        distance: struct { a: PointRef, b: PointRef, value: f64 },
        /// How far apart two points are across (along x), and up (along
        /// y). A distance is never negative and has no start or end (the
        /// owner, 2026-11-24): which of the two lies to the right (or
        /// above) is kept as it was when the constraint was made (`side`,
        /// set by `Sketch.addConstraint`), not by the value's sign.
        distance_x: struct { a: PointRef, b: PointRef, value: f64, side: f64 = 1 },
        distance_y: struct { a: PointRef, b: PointRef, value: f64, side: f64 = 1 },
        /// From a point to a straight geometry, on the side it was on when
        /// the constraint was made (`side`, set by `addConstraint`).
        line_distance: struct { p: PointRef, line: GeomId, value: f64, side: f64 = 1 },
        radius: struct { g: GeomId, value: f64 },
        /// A circle's or arc's diameter: twice its radius.
        diameter: struct { g: GeomId, value: f64 },
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
        /// Two angles equal: from `a`'s direction to `b`'s, as from `c`'s
        /// to `d`'s (straight geometries; a polygon's corners). No value:
        /// what they come to follows from the rest (a closed polygon's
        /// interior angles sum to (n - 2)·180°).
        equal_angle: struct { a: GeomId, b: GeomId, c: GeomId, d: GeomId },
        /// Two distances equal (a gutter as wide as another), or (`value`
        /// not 0) one longer than the other by `value`: `a` the longer
        /// when `side` is 1, `b` when it is -1 (never a negative value).
        /// Each a span between two points, along x or y or straight, or
        /// from a point to a straight geometry.
        equal_distance: struct { a: Span, b: Span, value: f64 = 0, side: f64 = 1 },
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
    /// Where its dimension is drawn (a dimension only): saved with it, so
    /// it reopens where it was left.
    place: dimension.Placement = .{},
    /// The innermost group holding all the geometry it names
    /// (`group.zig`), or none: kept there by the group code.
    group: GroupId = no_group,

    /// Whether it has a value (a dimension).
    pub fn isDimension(c: Constraint) bool {
        return switch (c.kind) {
            .distance, .distance_x, .distance_y, .line_distance, .radius, .diameter, .angle => true,
            else => false,
        };
    }
};


/// Geometry over unknowns, as a solve sees it: the values, which are fixed,
/// and the geometry referring to them.
pub const Store = struct {
    vars: []const f64,
    fixed: []const bool,
    geometry: []const Geometry,

    /// The unknowns of point `r`.
    pub fn pointOf(s: Store, r: PointRef) Error!Pt {
        if (r.geom >= s.geometry.len or s.geometry[r.geom].removed) return error.NoSuchGeometry;
        return switch (s.geometry[r.geom].kind) {
            .point => |p| if (r.role == .point) p else error.NoSuchPoint,
            // No unknowns of its own: see `point` and `Local.ref`.
            .affine => error.NoSuchPoint,
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
            // Its bind points have no unknowns of their own: see `point`.
            .polar_grid => |pg| if (r.role == .centre) pg.c else error.NoSuchPoint,
            .tessellation => |t| if (r.role == .centre) t.c else error.NoSuchPoint,
        };
    }

    /// Where point `r` is now.
    pub fn point(s: Store, r: PointRef) Error!Point {
        if (r.geom < s.geometry.len and !s.geometry[r.geom].removed) switch (s.geometry[r.geom].kind) {
            .affine => |af| return if (r.role == .point) .{ .x = af.x.at(s.vars), .y = af.y.at(s.vars) } else error.NoSuchPoint,
            .polar_grid => |pg| if (r.role == .node) return pg.node(s.vars, r.i, r.j),
            else => {},
        };
        const p = try s.pointOf(r);
        return .{ .x = s.vars[p.x], .y = s.vars[p.y] };
    }

    /// Whether `c` names a bind point its macro no longer has (its count
    /// was lowered): it is kept, flagged, and left out of solving.
    pub fn abandoned(s: Store, c: Constraint) bool {
        var buf: [4]Ref = undefined;
        for (refs(c, &buf)) |r| switch (r) {
            .point => |p| if (p.role == .node) {
                if (p.geom >= s.geometry.len or s.geometry[p.geom].removed) return true;
                switch (s.geometry[p.geom].kind) {
                    .polar_grid => |pg| if (!pg.has(p.i, p.j)) return true,
                    else => return true,
                }
            },
            .geom => {},
        };
        // A curve of a macro its counts no longer have.
        if (c.kind == .point_on and !c.kind.point_on.part.isWhole()) {
            const po = c.kind.point_on;
            if (po.on >= s.geometry.len or s.geometry[po.on].removed) return true;
            switch (s.geometry[po.on].kind) {
                .polar_grid => |pg| if (!pg.hasPart(po.part)) return true,
                else => return true,
            }
        }
        return false;
    }

    /// The rows a solve takes (`solve.Rows`): each arc's own equation
    /// (internal), then each driving constraint's residuals, owned by its
    /// index in `constraints`.
    pub fn rows(s: Store, constraints: []const Constraint, out: *solve.Rows) !void {
        for (s.geometry, 0..) |g, gi| if (!g.removed) switch (g.kind) {
            .arc => |ar| {
                var l: Local = .{ .s = s };
                const d = l.arcResidual(ar);
                try out.add(.{ .kind = solve.Owner.internal, .index = @intCast(gi) }, d, l.used());
            },
            else => {},
        };
        for (constraints, 0..) |c, ci| {
            // A reference dimension only reports; one on a bind point a
            // count took away holds nothing until it is back (a problem
            // to fix: `abandoned`).
            if (!c.driving or s.abandoned(c)) continue;
            var l: Local = .{ .s = s };
            var res: [2]D = undefined;
            const k = try l.residuals(c, &res);
            for (res[0..k]) |d| try out.add(.{ .index = @intCast(ci) }, d, l.used());
        }
    }
};

/// Something a constraint names: a point of a geometry, or a geometry as a
/// whole (a curve, a line).
pub const Ref = union(enum) {
    point: PointRef,
    geom: GeomId,
};

/// The primitives constraint `c` names, in its own order (at most 4), into
/// `buf`: what Properties lists for it.
pub fn refs(c: Constraint, buf: *[4]Ref) []const Ref {
    var n: usize = 0;
    const add = struct {
        fn f(b: *[4]Ref, k: *usize, r: Ref) void {
            if (k.* < b.len) {
                b[k.*] = r;
                k.* += 1;
            }
        }
    }.f;
    switch (c.kind) {
        .coincident => |ps| {
            add(buf, &n, .{ .point = ps[0] });
            add(buf, &n, .{ .point = ps[1] });
        },
        .horizontal, .vertical => |l| switch (l) {
            .geom => |g| add(buf, &n, .{ .geom = g }),
            .points => |ps| {
                add(buf, &n, .{ .point = ps[0] });
                add(buf, &n, .{ .point = ps[1] });
            },
        },
        .point_on => |po| {
            add(buf, &n, .{ .point = po.p });
            add(buf, &n, .{ .geom = po.on });
        },
        .fixed => |f| add(buf, &n, .{ .point = f.p }),
        inline .distance, .distance_x, .distance_y => |d| {
            add(buf, &n, .{ .point = d.a });
            add(buf, &n, .{ .point = d.b });
        },
        .line_distance => |d| {
            add(buf, &n, .{ .point = d.p });
            add(buf, &n, .{ .geom = d.line });
        },
        inline .radius, .diameter => |r| add(buf, &n, .{ .geom = r.g }),
        inline .angle, .parallel, .perpendicular, .tangent, .equal => |an| {
            add(buf, &n, .{ .geom = an.a });
            add(buf, &n, .{ .geom = an.b });
        },
        .equal_angle => |e| for ([_]GeomId{ e.a, e.b, e.c, e.d }) |g| add(buf, &n, .{ .geom = g }),
        .equal_distance => |e| for ([2]Span{ e.a, e.b }) |sp| switch (sp) {
            .points, .x, .y => |ps| {
                add(buf, &n, .{ .point = ps[0] });
                add(buf, &n, .{ .point = ps[1] });
            },
            .to_line => |t| {
                add(buf, &n, .{ .point = t.p });
                add(buf, &n, .{ .geom = t.line });
            },
        },
        .symmetric => |sy| {
            add(buf, &n, .{ .point = sy.p });
            add(buf, &n, .{ .point = sy.q });
            if (sy.line) |l| add(buf, &n, .{ .geom = l });
            if (sy.point) |q| add(buf, &n, .{ .point = q });
        },
    }
    return buf[0..n];
}

/// Puts `map(g)` for every geometry `c` names (`map` returns null for
/// geometry that has no counterpart: then `c` is left part-changed and
/// false is returned).
pub fn mapGeoms(c: *Constraint, ctx: anytype, comptime map: fn (@TypeOf(ctx), GeomId) ?GeomId) bool {
    const M = struct {
        fn g(x: *GeomId, cx: @TypeOf(ctx)) bool {
            x.* = map(cx, x.*) orelse return false;
            return true;
        }
        fn p(x: *PointRef, cx: @TypeOf(ctx)) bool {
            return g(&x.geom, cx);
        }
        fn lin(l: *Linear, cx: @TypeOf(ctx)) bool {
            return switch (l.*) {
                .geom => |*x| g(x, cx),
                .points => |*ps| p(&ps[0], cx) and p(&ps[1], cx),
            };
        }
        fn span(sp: *Span, cx: @TypeOf(ctx)) bool {
            return switch (sp.*) {
                inline .points, .x, .y => |*ps| p(&ps[0], cx) and p(&ps[1], cx),
                .to_line => |*t| p(&t.p, cx) and g(&t.line, cx),
            };
        }
    };
    return switch (c.kind) {
        .coincident => |*ps| M.p(&ps[0], ctx) and M.p(&ps[1], ctx),
        .horizontal, .vertical => |*l| M.lin(l, ctx),
        .point_on => |*po| M.p(&po.p, ctx) and M.g(&po.on, ctx),
        .fixed => |*f| M.p(&f.p, ctx),
        inline .distance, .distance_x, .distance_y => |*d| M.p(&d.a, ctx) and M.p(&d.b, ctx),
        .line_distance => |*d| M.p(&d.p, ctx) and M.g(&d.line, ctx),
        inline .radius, .diameter => |*r| M.g(&r.g, ctx),
        inline .angle, .parallel, .perpendicular, .tangent, .equal => |*an| M.g(&an.a, ctx) and M.g(&an.b, ctx),
        .equal_angle => |*e| M.g(&e.a, ctx) and M.g(&e.b, ctx) and M.g(&e.c, ctx) and M.g(&e.d, ctx),
        .equal_distance => |*e| M.span(&e.a, ctx) and M.span(&e.b, ctx),
        .symmetric => |*sy| M.p(&sy.p, ctx) and M.p(&sy.q, ctx) and
            (if (sy.line) |*l| M.g(l, ctx) else true) and
            (if (sy.point) |*q| M.p(q, ctx) else true),
    };
}

/// Every point constraint `c` names, by pointer (at most 8), into `buf`:
/// for rewriting them in place (a macro's bind points renumbered).
pub fn pointRefs(c: *Constraint, buf: *[8]*PointRef) []*PointRef {
    var n: usize = 0;
    const P = struct {
        fn add(b: *[8]*PointRef, k: *usize, r: *PointRef) void {
            if (k.* < b.len) {
                b[k.*] = r;
                k.* += 1;
            }
        }
        fn lin(b: *[8]*PointRef, k: *usize, l: *Linear) void {
            switch (l.*) {
                .geom => {},
                .points => |*ps| {
                    add(b, k, &ps[0]);
                    add(b, k, &ps[1]);
                },
            }
        }
        fn span(b: *[8]*PointRef, k: *usize, sp: *Span) void {
            switch (sp.*) {
                inline .points, .x, .y => |*ps| {
                    add(b, k, &ps[0]);
                    add(b, k, &ps[1]);
                },
                .to_line => |*t| add(b, k, &t.p),
            }
        }
    };
    switch (c.kind) {
        .coincident => |*ps| {
            P.add(buf, &n, &ps[0]);
            P.add(buf, &n, &ps[1]);
        },
        .horizontal, .vertical => |*l| P.lin(buf, &n, l),
        .point_on => |*po| P.add(buf, &n, &po.p),
        .fixed => |*f| P.add(buf, &n, &f.p),
        inline .distance, .distance_x, .distance_y => |*d| {
            P.add(buf, &n, &d.a);
            P.add(buf, &n, &d.b);
        },
        .line_distance => |*d| P.add(buf, &n, &d.p),
        .radius, .diameter, .angle, .parallel, .perpendicular, .tangent, .equal, .equal_angle => {},
        .equal_distance => |*e| {
            P.span(buf, &n, &e.a);
            P.span(buf, &n, &e.b);
        },
        .symmetric => |*sy| {
            P.add(buf, &n, &sy.p);
            P.add(buf, &n, &sy.q);
            if (sy.point) |*q| P.add(buf, &n, q);
        },
    }
    return buf[0..n];
}

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
        inline .radius, .diameter => |r| r.g == g,
        inline .angle, .parallel, .perpendicular, .tangent, .equal => |an| an.a == g or an.b == g,
        .equal_angle => |e| e.a == g or e.b == g or e.c == g or e.d == g,
        .equal_distance => |e| spanRefers(e.a, g) or spanRefers(e.b, g),
        .symmetric => |sy| sy.p.geom == g or sy.q.geom == g or (sy.line != null and sy.line.? == g) or (sy.point != null and sy.point.?.geom == g),
    };
}

/// A length whatever the order of its ends.
fn absD(d: D) D {
    return if (d.v < 0) d.scale(-1) else d;
}

fn spanRefers(sp: Span, g: GeomId) bool {
    return switch (sp) {
        .points, .x, .y => |ps| ps[0].geom == g or ps[1].geom == g,
        .to_line => |t| t.p.geom == g or t.line == g,
    };
}

/// One constraint's residuals as duals over its own unknowns (at most
/// `dual.n` of them), for its exact Jacobian row.
pub const Local = struct {
    s: Store,
    ids: [dual.n]VarId = undefined,
    count: usize = 0,

    /// Var `id` as a dual: seeded when it is an unknown, constant when fixed.
    pub fn get(l: *Local, id: VarId) D {
        const v = l.s.vars[id];
        if (l.s.fixed[id]) return D.c(v);
        for (l.ids[0..l.count], 0..) |x, i| if (x == id) return D.seed(v, i);
        std.debug.assert(l.count < dual.n);
        l.ids[l.count] = id;
        l.count += 1;
        return D.seed(v, l.count - 1);
    }

    /// The vars this row's duals are over.
    pub fn used(l: *const Local) []const VarId {
        return l.ids[0..l.count];
    }

    pub fn p(l: *Local, q: Pt) V {
        return .{ .x = l.get(q.x), .y = l.get(q.y) };
    }

    pub fn ref(l: *Local, r: PointRef) Error!V {
        if (r.geom < l.s.geometry.len and !l.s.geometry[r.geom].removed) switch (l.s.geometry[r.geom].kind) {
            .affine => |af| return if (r.role == .point) .{ .x = l.coord(af.x), .y = l.coord(af.y) } else error.NoSuchPoint,
            .polar_grid => |pg| if (r.role == .node) {
                // c + r_j (cos t_i, sin t_i), each interpolated between
                // the grid's two.
                const ii = PolarGrid.index(r.i, pg.cols) orelse return error.NoSuchPoint;
                const jj = PolarGrid.index(r.j, pg.rings) orelse return error.NoSuchPoint;
                const fi = @as(f64, @floatFromInt(ii)) / @as(f64, @floatFromInt(@max(pg.cols, 1)));
                const fj = @as(f64, @floatFromInt(jj)) / @as(f64, @floatFromInt(@max(pg.rings, 1)));
                const r0 = l.get(pg.r[0]);
                const t0 = l.get(pg.t[0]);
                const rad = r0.add(l.get(pg.r[1]).sub(r0).scale(fj));
                const t = t0.add(l.get(pg.t[1]).sub(t0).scale(fi));
                const c = l.p(pg.c);
                return .{ .x = c.x.add(rad.mul(t.cos())), .y = c.y.add(rad.mul(t.sin())) };
            },
            else => {},
        };
        return l.p(try l.s.pointOf(r));
    }

    /// How far point `r` is off curve `part` of macro `g`: a ring's
    /// radius from it, or its distance across a border's line.
    fn onPart(l: *Local, r: PointRef, g: Geometry, part: Part) Error!D {
        const pg = switch (g.kind) {
            .polar_grid => |x| x,
            else => return error.WrongKind,
        };
        const q = (try l.ref(r)).sub(l.p(pg.c));
        switch (part.role) {
            .whole => return error.WrongKind,
            .ring => {
                const jj = PolarGrid.index(part.k, pg.rings) orelse return error.NoSuchGeometry;
                const fj = @as(f64, @floatFromInt(jj)) / @as(f64, @floatFromInt(@max(pg.rings, 1)));
                const r0 = l.get(pg.r[0]);
                return q.len().sub(r0.add(l.get(pg.r[1]).sub(r0).scale(fj)));
            },
            .border => {
                const ii = PolarGrid.index(part.k, pg.cols) orelse return error.NoSuchGeometry;
                const fi = @as(f64, @floatFromInt(ii)) / @as(f64, @floatFromInt(@max(pg.cols, 1)));
                const t0 = l.get(pg.t[0]);
                const t = t0.add(l.get(pg.t[1]).sub(t0).scale(fi));
                // Across the border's direction (cos t, sin t).
                return q.x.mul(t.sin()).sub(q.y.mul(t.cos()));
            },
        }
    }

    /// An affine coordinate as a dual over its unknowns.
    pub fn coord(l: *Local, a: Affine) D {
        var d = D.c(a.c);
        for (a.vars, a.k) |v, k| if (k != 0) {
            d = d.add(l.get(v).scale(k));
        };
        return d;
    }

    pub fn geo(l: *Local, g: GeomId) Error!Geometry {
        if (g >= l.s.geometry.len or l.s.geometry[g].removed) return error.NoSuchGeometry;
        return l.s.geometry[g];
    }

    /// The unit direction of a straight geometry.
    pub fn direction(l: *Local, g: GeomId) Error!V {
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
    pub fn signedDistance(l: *Local, r: PointRef, g: GeomId) Error!D {
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

    pub fn isRound(l: *Local, g: GeomId) bool {
        const geo_ = l.geo(g) catch return false;
        return geo_.kind == .circle or geo_.kind == .arc;
    }

    /// A circle's or arc's centre and radius.
    pub fn round(l: *Local, g: GeomId) Error!struct { c: V, r: D } {
        return switch ((try l.geo(g)).kind) {
            .circle => |ci| .{ .c = l.p(ci.c), .r = l.get(ci.r) },
            .arc => |ar| blk: {
                const c = l.p(ar.c);
                break :blk .{ .c = c, .r = l.p(ar.a).sub(c).len() };
            },
            else => error.WrongKind,
        };
    }

    pub fn segLength(l: *Local, g: GeomId) Error!D {
        return switch ((try l.geo(g)).kind) {
            .segment => |sg| l.p(sg.b).sub(l.p(sg.a)).len(),
            else => error.WrongKind,
        };
    }

    pub fn horizontalOrVertical(l: *Local, lin: Linear, vertical: bool) Error!D {
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

    /// A span's length (a point's distance from a line: unsigned).
    pub fn span(l: *Local, sp: Span) Error!D {
        return switch (sp) {
            .points => |ps| (try l.ref(ps[1])).sub(try l.ref(ps[0])).len(),
            .x => |ps| absD((try l.ref(ps[1])).x.sub((try l.ref(ps[0])).x)),
            .y => |ps| absD((try l.ref(ps[1])).y.sub((try l.ref(ps[0])).y)),
            .to_line => |t| absD(try l.signedDistance(t.p, t.line)),
        };
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
                if (!po.part.isWhole()) {
                    out[0] = try l.onPart(po.p, g, po.part);
                    return 1;
                }
                out[0] = switch (g.kind) {
                    .segment, .line, .ray => try l.signedDistance(po.p, po.on),
                    .circle => |ci| (try l.ref(po.p)).sub(l.p(ci.c)).len().sub(l.get(ci.r)),
                    .arc => |ar| blk: {
                        const cc = l.p(ar.c);
                        break :blk (try l.ref(po.p)).sub(cc).len().sub(l.p(ar.a).sub(cc).len());
                    },
                    .point, .affine, .polar_grid, .tessellation => return error.WrongKind,
                };
            },
            .fixed => |f| {
                const q = try l.ref(f.p);
                out[0] = q.x.sub(D.c(f.at.x));
                out[1] = q.y.sub(D.c(f.at.y));
                return 2;
            },
            .distance => |d| out[0] = (try l.ref(d.b)).sub(try l.ref(d.a)).len().sub(D.c(d.value)),
            .distance_x => |d| out[0] = (try l.ref(d.b)).x.sub((try l.ref(d.a)).x).scale(d.side).sub(D.c(d.value)),
            .distance_y => |d| out[0] = (try l.ref(d.b)).y.sub((try l.ref(d.a)).y).scale(d.side).sub(D.c(d.value)),
            .line_distance => |d| out[0] = (try l.signedDistance(d.p, d.line)).scale(d.side).sub(D.c(d.value)),
            .radius => |r| out[0] = switch ((try l.geo(r.g)).kind) {
                .circle => |ci| l.get(ci.r).sub(D.c(r.value)),
                .arc => |ar| l.p(ar.a).sub(l.p(ar.c)).len().sub(D.c(r.value)),
                else => return error.WrongKind,
            },
            .diameter => |r| out[0] = switch ((try l.geo(r.g)).kind) {
                .circle => |ci| l.get(ci.r).scale(2).sub(D.c(r.value)),
                .arc => |ar| l.p(ar.a).sub(l.p(ar.c)).len().scale(2).sub(D.c(r.value)),
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
            .equal_distance => |e| out[0] = (try l.span(e.a)).sub(try l.span(e.b)).scale(e.side).sub(D.c(e.value)),
            .equal_angle => |e| {
                // sin(phi1 - phi2), each phi from its first direction to
                // its second (unit directions).
                const da = try l.direction(e.a);
                const db = try l.direction(e.b);
                const dc = try l.direction(e.c);
                const dd = try l.direction(e.d);
                out[0] = da.cross(db).mul(dc.dot(dd)).sub(da.dot(db).mul(dc.cross(dd)));
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

const testing = std.testing;

test "two gutters held equal: a distance between edges, and an equal distance" {
    // Four points along x: edges of three columns, say. A gap of 5 between
    // the first two; the gap between the last two held equal to it.
    var vars = [_]f64{ 0, 0, 5, 0, 20, 0, 22, 0 };
    const fixed = [_]bool{ true, true, false, true, true, true, false, true };
    const geo = [_]Geometry{
        .{ .kind = .{ .point = .{ .x = 0, .y = 1 } } },
        .{ .kind = .{ .point = .{ .x = 2, .y = 3 } } },
        .{ .kind = .{ .point = .{ .x = 4, .y = 5 } } },
        .{ .kind = .{ .point = .{ .x = 6, .y = 7 } } },
    };
    const pts = [_]PointRef{ .{ .geom = 0 }, .{ .geom = 1 }, .{ .geom = 2 }, .{ .geom = 3 } };
    const cons = [_]Constraint{
        .{ .kind = .{ .distance_x = .{ .a = pts[0], .b = pts[1], .value = 6 } } },
        .{ .kind = .{ .equal_distance = .{ .a = .{ .x = .{ pts[0], pts[1] } }, .b = .{ .x = .{ pts[2], pts[3] } } } } },
    };
    const Ctx = struct {
        st: Store,
        cs: []const Constraint,
        pub fn rows(c: @This(), out: *solve.Rows) !void {
            try c.st.rows(c.cs, out);
        }
    };
    const res = try solve.solve(testing.allocator, .{ .vars = &vars, .fixed = &fixed }, Ctx{ .st = .{ .vars = &vars, .fixed = &fixed, .geometry = &geo }, .cs = &cons });
    try testing.expect(res.solved);
    try testing.expectApproxEqAbs(@as(f64, 6), vars[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 26), vars[6], 1e-9);
}

test "boxes by their origin and size: edges as affine points, sizes giving less" {
    // Box A at 0, 10 wide (fixed); box B's origin at its left (var 0) and
    // its width (var 1), 20 at 4 wide. Its left kept 5 right of A's right,
    // and its width equal to A's: it moves, then grows.
    var vars = [_]f64{ 20, 4 };
    const fixed = [_]bool{ false, false };
    const give = [_]f64{ 1, 1e-3 };
    const geo = [_]Geometry{
        .{ .kind = .{ .affine = .{ .x = .{ .c = 0 }, .y = .{} } } },
        .{ .kind = .{ .affine = .{ .x = .{ .c = 10 }, .y = .{} } } },
        .{ .kind = .{ .affine = .{ .x = .{ .vars = .{ 0, 1 }, .k = .{ 1, 0 } }, .y = .{} } } },
        .{ .kind = .{ .affine = .{ .x = .{ .vars = .{ 0, 1 }, .k = .{ 1, 1 } }, .y = .{} } } },
    };
    const pt = [_]PointRef{ .{ .geom = 0 }, .{ .geom = 1 }, .{ .geom = 2 }, .{ .geom = 3 } };
    const cons = [_]Constraint{
        .{ .kind = .{ .distance_x = .{ .a = pt[1], .b = pt[2], .value = 5 } } },
        .{ .kind = .{ .equal_distance = .{ .a = .{ .x = .{ pt[2], pt[3] } }, .b = .{ .x = .{ pt[0], pt[1] } } } } },
    };
    const Ctx = struct {
        st: Store,
        cs: []const Constraint,
        pub fn rows(c: @This(), out: *solve.Rows) !void {
            try c.st.rows(c.cs, out);
        }
    };
    const st: Store = .{ .vars = &vars, .fixed = &fixed, .geometry = &geo };
    const res = try solve.solve(testing.allocator, .{ .vars = &vars, .fixed = &fixed, .give = &give }, Ctx{ .st = st, .cs = &cons });
    try testing.expect(res.solved);
    try testing.expectApproxEqAbs(@as(f64, 15), vars[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), vars[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 25), (try st.point(pt[3])).x, 1e-9);
}
