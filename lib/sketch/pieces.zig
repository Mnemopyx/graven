//! Pieces of a sketch's curves (the owner, 2026-11-26): the part of a
//! segment, line, ray, circle or arc between two of its cuts, which are
//! its own ends, the points lying on it, and where other curves cross it.
//! A piece is chosen by where it is (`pieceAt`), or as one of the pieces
//! around an area (`loopAround`), a connected path closing it.
//!
//! What is chosen (`Found`) names its cuts as they are now: a point, or
//! a crossing with another curve. When a tool is applied to it (ink, a
//! fill), `attach` makes it lasting (`Piece`): a crossing becomes a point
//! held on both curves by constraints, and a point lying on the curve by
//! chance is held on it, so the piece follows the sketch as it changes.
//! A `Piece` names only geometry and points; what it covers is worked out
//! from them each time (`appendSegments`).

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const Geometry = root.Geometry;
const PointRef = root.PointRef;
const Part = root.Part;
const PolarGrid = root.geometry.PolarGrid;
const last = root.geometry.last;

/// How near counts as on, mm.
pub const eps = 1e-6;

/// Part of curve `geom` from point `from` to point `to` (both lying on
/// it): along a straight one, either way; round a circle, counter-clockwise
/// from `from`. Without ends, the whole curve.
pub const Piece = struct {
    geom: GeomId,
    /// Which of its curves (a macro's: indexed, `geometry.Part`).
    part: Part = .{},
    from: ?PointRef = null,
    to: ?PointRef = null,

    pub fn whole(p: Piece) bool {
        return p.from == null or p.to == null;
    }

    pub fn eql(a: Piece, b: Piece) bool {
        return std.meta.eql(a, b);
    }
};

/// Where a piece ends, as chosen: a point (a curve's own end, or a point
/// lying on it), or where another curve crosses it, near `at`.
pub const Cut = union(enum) {
    point: PointRef,
    cross: struct { other: GeomId, other_part: Part = .{}, at: Point },
};

/// A piece as chosen: its curve, and its cuts in the curve's direction
/// (counter-clockwise round a circle or arc); whole when it has none.
pub const Found = struct {
    geom: GeomId,
    part: Part = .{},
    from: ?Cut = null,
    to: ?Cut = null,

    pub fn whole(f: Found) bool {
        return f.from == null or f.to == null;
    }
};

/// A curve as a carrier with a parameter: straight (from `p` along unit
/// `d`, between `t0` and `t1`, either maybe infinite) or round (about
/// `c`, radius `r`, angles from `a0` counter-clockwise, up to `sweep`;
/// a full turn for a circle).
const Carrier = union(enum) {
    straight: struct { p: Point, d: Point, t0: f64, t1: f64 },
    round: struct { c: Point, r: f64, a0: f64, sweep: f64, closed: bool },

    fn at(k: Carrier, t: f64) Point {
        return switch (k) {
            .straight => |s| .{ .x = s.p.x + s.d.x * t, .y = s.p.y + s.d.y * t },
            .round => |r| .{ .x = r.c.x + r.r * @cos(r.a0 + t), .y = r.c.y + r.r * @sin(r.a0 + t) },
        };
    }

    /// The parameter of the point on it nearest `q` (its carrier's, not
    /// held to its range; round: in [0, 2π)).
    fn param(k: Carrier, q: Point) f64 {
        return switch (k) {
            .straight => |s| (q.x - s.p.x) * s.d.x + (q.y - s.p.y) * s.d.y,
            .round => |r| wrap(std.math.atan2(q.y - r.c.y, q.x - r.c.x) - r.a0),
        };
    }

    /// The direction of travel at `t` (increasing t).
    fn tangent(k: Carrier, t: f64) Point {
        return switch (k) {
            .straight => |s| s.d,
            .round => |r| .{ .x = -@sin(r.a0 + t), .y = @cos(r.a0 + t) },
        };
    }

    /// Whether parameter `t` is within its range (`tol` mm).
    fn within(k: Carrier, t: f64, tol: f64) bool {
        return switch (k) {
            .straight => |s| t >= s.t0 - tol and t <= s.t1 + tol,
            .round => |r| r.closed or t <= r.sweep + tol / r.r or t >= 2 * std.math.pi - tol / r.r,
        };
    }

    /// How far `q` is from the carrier (the whole line or circle).
    fn off(k: Carrier, q: Point) f64 {
        return switch (k) {
            .straight => |s| @abs((q.x - s.p.x) * s.d.y - (q.y - s.p.y) * s.d.x),
            .round => |r| @abs(std.math.hypot(q.x - r.c.x, q.y - r.c.y) - r.r),
        };
    }

    fn closed(k: Carrier) bool {
        return k == .round and k.round.closed;
    }

    /// The point of it (within its range) nearest `q`.
    fn nearest(k: Carrier, q: Point) Point {
        switch (k) {
            .straight => |st| return k.at(std.math.clamp(k.param(q), st.t0, st.t1)),
            .round => |r| {
                const t = k.param(q);
                if (r.closed or t <= r.sweep) return k.at(t);
                // Past its end: the nearer end.
                const e0 = k.at(0);
                const e1 = k.at(r.sweep);
                return if (std.math.hypot(e0.x - q.x, e0.y - q.y) < std.math.hypot(e1.x - q.x, e1.y - q.y)) e0 else e1;
            },
        }
    }
};

fn wrap(t: f64) f64 {
    const tau = 2 * std.math.pi;
    var x = @mod(t, tau);
    if (x < 0) x += tau;
    if (x >= tau) x -= tau;
    return x;
}

fn val(s: *const Sketch, p: root.Pt) Point {
    return .{ .x = s.vars.items[p.x], .y = s.vars.items[p.y] };
}

/// Curve `g` as a carrier; null for a point or what is not a curve.
fn carrier(s: *const Sketch, g: Geometry) ?Carrier {
    const inf = std.math.inf(f64);
    switch (g.kind) {
        .segment => |sg| {
            const a = val(s, sg.a);
            const b = val(s, sg.b);
            const len = std.math.hypot(b.x - a.x, b.y - a.y);
            if (!(len > eps)) return null;
            return .{ .straight = .{ .p = a, .d = .{ .x = (b.x - a.x) / len, .y = (b.y - a.y) / len }, .t0 = 0, .t1 = len } };
        },
        .line => |ln| {
            const th = s.vars.items[ln.theta];
            const rho = s.vars.items[ln.rho];
            return .{ .straight = .{ .p = .{ .x = rho * @cos(th), .y = rho * @sin(th) }, .d = .{ .x = -@sin(th), .y = @cos(th) }, .t0 = -inf, .t1 = inf } };
        },
        .ray => |ry| {
            const ang = s.vars.items[ry.angle];
            return .{ .straight = .{ .p = val(s, ry.o), .d = .{ .x = @cos(ang), .y = @sin(ang) }, .t0 = 0, .t1 = inf } };
        },
        .circle => |c| {
            const r = s.vars.items[c.r];
            if (!(r > eps)) return null;
            return .{ .round = .{ .c = val(s, c.c), .r = r, .a0 = 0, .sweep = 2 * std.math.pi, .closed = true } };
        },
        .arc => |ar| {
            const c = val(s, ar.c);
            const p0 = val(s, ar.a);
            const p1 = val(s, ar.b);
            const r = std.math.hypot(p0.x - c.x, p0.y - c.y);
            if (!(r > eps)) return null;
            const a0 = std.math.atan2(p0.y - c.y, p0.x - c.x);
            var sweep = wrap(std.math.atan2(p1.y - c.y, p1.x - c.x) - a0);
            if (sweep <= 0) sweep = 2 * std.math.pi;
            return .{ .round = .{ .c = c, .r = r, .a0 = a0, .sweep = sweep, .closed = false } };
        },
        // A macro's sections are not pieces yet (they have no IDs of
        // their own to choose).
        .point, .affine, .polar_grid, .tessellation => return null,
    }
}

/// A curve of the sketch: a geometry, or one of a macro's curves by its
/// index (a polar grid's ring or border).
pub const Curve = struct { geom: GeomId, part: Part = .{} };

/// Curve `c` as a carrier; null when it is none (now).
fn curveCarrier(s: *const Sketch, c: Curve) ?Carrier {
    if (c.geom >= s.geometry.items.len) return null;
    const g = s.geometry.items[c.geom];
    if (g.removed or g.reference) return null;
    if (c.part.isWhole()) return if (isCurve(g)) carrier(s, g) else null;
    return switch (g.kind) {
        .polar_grid => |pg| gridCarrier(s, pg, c.part),
        else => null,
    };
}

/// A polar grid's ring (round, across its sweep, counter-clockwise from
/// its smaller angle) or border (straight, outwards from its smaller
/// radius).
fn gridCarrier(s: *const Sketch, pg: PolarGrid, part: Part) ?Carrier {
    const v = s.vars.items;
    const c = val(s, pg.c);
    switch (part.role) {
        .whole => return null,
        .ring => {
            const j = PolarGrid.index(part.k, pg.rings) orelse return null;
            const r = @abs(pg.radius(v, j));
            if (!(r > eps)) return null;
            if (pg.full(v)) return .{ .round = .{ .c = c, .r = r, .a0 = 0, .sweep = 2 * std.math.pi, .closed = true } };
            const sw = pg.sweep(v);
            if (!(@abs(sw) > 1e-12)) return null;
            return .{ .round = .{ .c = c, .r = r, .a0 = if (sw > 0) v[pg.t[0]] else v[pg.t[0]] + sw, .sweep = @abs(sw), .closed = false } };
        },
        .border => {
            const i = PolarGrid.index(part.k, pg.cols) orelse return null;
            const t = pg.angle(v, i);
            const d: Point = .{ .x = @cos(t), .y = @sin(t) };
            // A dial's tick runs in to its own inner ring.
            const r1 = pg.radius(v, pg.innerRing(i));
            const lo = @min(v[pg.r[0]], r1);
            const hi = @max(v[pg.r[0]], r1);
            if (!(hi - lo > eps)) return null;
            return .{ .straight = .{ .p = .{ .x = c.x + d.x * lo, .y = c.y + d.y * lo }, .d = d, .t0 = 0, .t1 = hi - lo } };
        },
    }
}

/// Index `i` of a run of `n`, the last as `last` (it stays the last).
fn runIndex(i: usize, n: u32) u32 {
    return if (i == n) last else @intCast(i);
}

/// Every curve of the sketch whose pieces can be chosen: its curves, and
/// each polar grid's rings and borders (one border where a full turn
/// closes). Allocated from `a`.
pub fn curves(s: *const Sketch, a: Allocator) Allocator.Error![]Curve {
    var out: std.ArrayList(Curve) = .empty;
    for (s.geometry.items, 0..) |g, gi| {
        const id: GeomId = @intCast(gi);
        if (isCurve(g)) {
            try out.append(a, .{ .geom = id });
            continue;
        }
        if (g.removed or g.reference) continue;
        switch (g.kind) {
            .polar_grid => |pg| {
                for (0..pg.rings + 1) |j| {
                    // A dial's labels' ring is where they sit, not a curve.
                    if (pg.dial != null and j == pg.rings) continue;
                    const c: Curve = .{ .geom = id, .part = .{ .role = .ring, .k = runIndex(j, pg.rings) } };
                    if (curveCarrier(s, c) != null) try out.append(a, c);
                }
                const nb: usize = if (pg.full(s.vars.items)) pg.cols else pg.cols + 1;
                for (0..nb) |i| {
                    const c: Curve = .{ .geom = id, .part = .{ .role = .border, .k = runIndex(i, pg.cols) } };
                    if (curveCarrier(s, c) != null) try out.append(a, c);
                }
            },
            else => {},
        }
    }
    return out.items;
}

/// The bind points along curve `c` of a macro (where its curves meet),
/// into `out`.
fn nodesOn(s: *const Sketch, a: Allocator, c: Curve, out: *std.ArrayList(PointRef)) Allocator.Error!void {
    const pg = switch (s.geometry.items[c.geom].kind) {
        .polar_grid => |x| x,
        else => return,
    };
    switch (c.part.role) {
        .whole => {},
        .ring => for (0..pg.cols + 1) |i| try out.append(a, .{ .geom = c.geom, .role = .node, .i = runIndex(i, pg.cols), .j = c.part.k }),
        .border => for (0..pg.rings + 1) |j| {
            // A dial's tick: the rings it reaches (from its outer one in
            // to its own inner end).
            if (pg.dial != null) {
                const v = s.vars.items;
                const i = PolarGrid.index(c.part.k, pg.cols) orelse return;
                const r0 = v[pg.r[0]];
                const r1 = pg.radius(v, pg.innerRing(i));
                const rj = pg.radius(v, @intCast(j));
                if (j == pg.rings or rj < @min(r0, r1) - eps or rj > @max(r0, r1) + eps) continue;
            }
            try out.append(a, .{ .geom = c.geom, .role = .node, .i = c.part.k, .j = runIndex(j, pg.rings) });
        },
    }
}

/// A curve near a place: where on it, and how far.
pub const Near = struct { curve: Curve, at: Point, d: f64 };

/// The curve of macro `g` nearest `q`, and how far (none: not a macro).
pub fn nearestPart(s: *const Sketch, a: Allocator, g: GeomId, q: Point) Allocator.Error!?Near {
    if (g >= s.geometry.items.len or s.geometry.items[g].kind != .polar_grid) return null;
    var best: ?Near = null;
    for (try curves(s, a)) |c| {
        if (c.geom != g) continue;
        const k = curveCarrier(s, c) orelse continue;
        const at = k.nearest(q);
        const d = std.math.hypot(at.x - q.x, at.y - q.y);
        if (best == null or d < best.?.d) best = .{ .curve = c, .at = at, .d = d };
    }
    return best;
}

/// Whether `g` is a curve whose pieces can be chosen.
fn isCurve(g: Geometry) bool {
    if (g.removed or g.reference) return false;
    return switch (g.kind) {
        .segment, .line, .ray, .circle, .arc => true,
        else => false,
    };
}

/// Where two carriers meet (within both ranges), at most two points.
fn meet(a: Carrier, b: Carrier, out: *[2]Point) usize {
    var cand: [2]Point = undefined;
    var n: usize = 0;
    switch (a) {
        .straight => |sa| switch (b) {
            .straight => |sb| {
                const den = sa.d.x * sb.d.y - sa.d.y * sb.d.x;
                if (@abs(den) < 1e-12) return 0;
                const t = ((sb.p.x - sa.p.x) * sb.d.y - (sb.p.y - sa.p.y) * sb.d.x) / den;
                cand[0] = a.at(t);
                n = 1;
            },
            .round => |rb| n = lineCircle(sa.p, sa.d, rb.c, rb.r, &cand),
        },
        .round => |ra| switch (b) {
            .straight => |sb| n = lineCircle(sb.p, sb.d, ra.c, ra.r, &cand),
            .round => |rb| {
                const dx = rb.c.x - ra.c.x;
                const dy = rb.c.y - ra.c.y;
                const d = std.math.hypot(dx, dy);
                if (d < eps or d > ra.r + rb.r + eps or d < @abs(ra.r - rb.r) - eps) return 0;
                const x = (d * d + ra.r * ra.r - rb.r * rb.r) / (2 * d);
                const h2 = ra.r * ra.r - x * x;
                const h = if (h2 > 0) @sqrt(h2) else 0;
                const mx = ra.c.x + dx * x / d;
                const my = ra.c.y + dy * x / d;
                cand[0] = .{ .x = mx - dy * h / d, .y = my + dx * h / d };
                n = 1;
                if (h > eps) {
                    cand[1] = .{ .x = mx + dy * h / d, .y = my - dx * h / d };
                    n = 2;
                }
            },
        },
    }
    var k: usize = 0;
    for (cand[0..n]) |p| {
        if (!a.within(a.param(p), eps) or !b.within(b.param(p), eps)) continue;
        out[k] = p;
        k += 1;
    }
    return k;
}

fn lineCircle(p: Point, d: Point, c: Point, r: f64, out: *[2]Point) usize {
    // |p + t d - c| = r, d a unit vector.
    const fx = p.x - c.x;
    const fy = p.y - c.y;
    const b = fx * d.x + fy * d.y;
    const cc = fx * fx + fy * fy - r * r;
    const disc = b * b - cc;
    if (disc < -eps * r) return 0;
    const sq = if (disc > 0) @sqrt(disc) else 0;
    out[0] = .{ .x = p.x + d.x * (-b - sq), .y = p.y + d.y * (-b - sq) };
    if (sq * sq < eps * eps) return 1;
    out[1] = .{ .x = p.x + d.x * (-b + sq), .y = p.y + d.y * (-b + sq) };
    return 2;
}

/// A cut on a curve: where, its parameter, and what it is.
pub const CutAt = struct { t: f64, at: Point, cut: Cut };

/// The points of a geometry that a curve can be cut at: a point, a
/// segment's or arc's ends, a ray's origin (not centres).
fn endsOf(g: Geometry, id: GeomId, buf: *[2]PointRef) []PointRef {
    switch (g.kind) {
        .point => {
            buf[0] = .{ .geom = id, .role = .point };
            return buf[0..1];
        },
        .segment, .arc => {
            buf[0] = .{ .geom = id, .role = .start };
            buf[1] = .{ .geom = id, .role = .end };
            return buf[0..2];
        },
        .ray => {
            buf[0] = .{ .geom = id, .role = .origin };
            return buf[0..1];
        },
        else => return buf[0..0],
    }
}

/// Curve `g`'s cuts, in order along it: its own ends, the points on it,
/// the crossings of other curves (one cut where several meet, a point
/// before a crossing). Allocated from `a`.
pub fn cutsOn(s: *const Sketch, a: Allocator, g: GeomId) Allocator.Error![]CutAt {
    return cutsOnCurve(s, a, .{ .geom = g });
}

/// As `cutsOn`, for any curve (a macro's ring or border: its bind points
/// are its own cuts).
pub fn cutsOnCurve(s: *const Sketch, a: Allocator, cv: Curve) Allocator.Error![]CutAt {
    const g = cv.geom;
    if (g >= s.geometry.items.len) return &.{};
    const geo = s.geometry.items[g];
    const k = curveCarrier(s, cv) orelse return &.{};
    var list: std.ArrayList(CutAt) = .empty;
    // Its own ends first, so they win at the same place.
    var buf: [2]PointRef = undefined;
    var own: std.ArrayList(PointRef) = .empty;
    if (cv.part.isWhole()) try own.appendSlice(a, endsOf(geo, g, &buf)) else try nodesOn(s, a, cv, &own);
    for (own.items) |r| {
        const p = s.point(r) catch continue;
        var t = k.param(p);
        // An open round one's start read as a turn round.
        if (k == .round and !k.round.closed and t > k.round.sweep and k.off(p) < eps and std.math.hypot(p.x - k.at(0).x, p.y - k.at(0).y) < eps) t = 0;
        try list.append(a, .{ .t = t, .at = p, .cut = .{ .point = r } });
    }
    if (geo.kind == .arc and cv.part.isWhole() and list.items.len == 2) {
        list.items[0].t = 0;
        list.items[1].t = k.round.sweep;
    }
    for (s.geometry.items, 0..) |o, oi| {
        if (oi == g or o.removed or o.reference) continue;
        for (endsOf(o, @intCast(oi), &buf)) |r| {
            const p = s.point(r) catch continue;
            if (k.off(p) > eps) continue;
            const t = k.param(p);
            if (!k.within(t, eps)) continue;
            try list.append(a, .{ .t = t, .at = p, .cut = .{ .point = r } });
        }
    }
    for (try curves(s, a)) |o| {
        // A macro's own curves meet at its bind points, cuts already.
        if (o.geom == g) continue;
        const ko = curveCarrier(s, o) orelse continue;
        var pts: [2]Point = undefined;
        for (pts[0..meet(k, ko, &pts)]) |p| try list.append(a, .{ .t = k.param(p), .at = p, .cut = .{ .cross = .{ .other = o.geom, .other_part = o.part, .at = p } } });
    }
    // In order along it, then one cut per place (the first: an end, a
    // point, before a crossing).
    const items = list.items;
    var order = try a.alloc(usize, items.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, @as([]const CutAt, items), struct {
        fn lt(it: []const CutAt, x: usize, y: usize) bool {
            if (it[x].t != it[y].t) return it[x].t < it[y].t;
            return x < y;
        }
    }.lt);
    var out: std.ArrayList(CutAt) = .empty;
    for (order) |i| {
        const c = items[i];
        var dup = false;
        for (out.items) |*o| if (std.math.hypot(o.at.x - c.at.x, o.at.y - c.at.y) < eps) {
            dup = true;
            // A point wins over a crossing, whichever came first along it.
            if (o.cut == .cross and c.cut == .point) o.cut = c.cut;
        };
        if (!dup) try out.append(a, c);
    }
    _ = &order;
    return out.items;
}

pub const Error = Allocator.Error || error{ NotACurve, Unbounded };

/// The piece of curve `g` at `q` (near it): between the cuts either side.
/// Whole when the curve has no cut inside it (a circle with fewer than
/// two). `error.Unbounded` for the endless part of a line or ray. On a
/// macro, of its curve nearest `q`.
pub fn pieceAt(s: *const Sketch, a: Allocator, g: GeomId, q: Point) Error!Found {
    if (g < s.geometry.items.len and s.geometry.items[g].kind == .polar_grid) {
        const n = (try nearestPart(s, a, g, q)) orelse return error.NotACurve;
        return pieceOn(s, a, n.curve, q);
    }
    if (g >= s.geometry.items.len or !isCurve(s.geometry.items[g])) return error.NotACurve;
    return pieceOn(s, a, .{ .geom = g }, q);
}

/// The piece of curve `cv` at `q`.
pub fn pieceOn(s: *const Sketch, a: Allocator, cv: Curve, q: Point) Error!Found {
    const g = cv.geom;
    const k = curveCarrier(s, cv) orelse return error.NotACurve;
    const cuts = try cutsOnCurve(s, a, cv);
    const t = k.param(q);
    if (k.closed()) {
        if (cuts.len < 2) return .{ .geom = g, .part = cv.part };
        // The last cut at or before t, round.
        var i: usize = cuts.len - 1;
        for (cuts, 0..) |c, ci| {
            if (c.t <= t) i = ci;
        }
        const j = (i + 1) % cuts.len;
        return .{ .geom = g, .part = cv.part, .from = cuts[i].cut, .to = cuts[j].cut };
    }
    var lo: ?usize = null;
    var hi: ?usize = null;
    for (cuts, 0..) |c, ci| {
        if (c.t <= t) lo = ci;
        if (c.t > t and hi == null) hi = ci;
    }
    const l = lo orelse return error.Unbounded;
    const h = hi orelse return error.Unbounded;
    // A bounded curve cut nowhere inside: the whole of it.
    if (bounded(s, cv) and l == 0 and h == cuts.len - 1) return .{ .geom = g, .part = cv.part };
    return .{ .geom = g, .part = cv.part, .from = cuts[l].cut, .to = cuts[h].cut };
}

/// Whether curve `cv` has two ends (a segment, an arc, a macro's ring
/// short of a turn or border).
fn bounded(s: *const Sketch, cv: Curve) bool {
    if (!cv.part.isWhole()) return true;
    const kind = s.geometry.items[cv.geom].kind;
    return kind == .segment or kind == .arc;
}

/// Where cut `c` is now.
pub fn cutPoint(s: *const Sketch, c: Cut) ?Point {
    return switch (c) {
        .point => |r| s.point(r) catch null,
        .cross => |x| x.at,
    };
}

/// The segments `f` covers, as chosen (for showing it).
pub fn foundSegments(s: *const Sketch, a: Allocator, f: Found, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
    if (f.geom >= s.geometry.items.len) return;
    const cv: Curve = .{ .geom = f.geom, .part = f.part };
    if (f.whole()) return wholeSegments(s, a, cv, out);
    const p0 = cutPoint(s, f.from.?) orelse return;
    const p1 = cutPoint(s, f.to.?) orelse return;
    const k = curveCarrier(s, cv) orelse return;
    try between(a, k, p0, p1, out);
}

/// The segments of the whole of curve `cv` (none for a line or ray).
fn wholeSegments(s: *const Sketch, a: Allocator, cv: Curve, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
    const g = s.geometry.items[cv.geom];
    if (cv.part.isWhole()) {
        if (g.kind == .line or g.kind == .ray) return;
        return s.appendSegments(a, g, out);
    }
    const k = curveCarrier(s, cv) orelse return;
    if (k.closed()) {
        const r = k.round;
        var buf: [4]geom.Segment = undefined;
        return out.appendSlice(a, geom.arc(r.c, r.r, r.a0, r.sweep, &buf));
    }
    // A macro's ring or border, end to end: its ends exactly its bind
    // points, so it chains with pieces ending there.
    const pg = g.kind.polar_grid;
    const v = s.vars.items;
    const ends: [2]PointRef = switch (cv.part.role) {
        .ring => .{ .{ .geom = cv.geom, .role = .node, .i = 0, .j = cv.part.k }, .{ .geom = cv.geom, .role = .node, .i = last, .j = cv.part.k } },
        else => blk: {
            // A dial's tick ends at its own inner ring.
            const inner: u32 = if (pg.dial != null) pg.innerRing(PolarGrid.index(cv.part.k, pg.cols) orelse 0) else last;
            break :blk .{ .{ .geom = cv.geom, .role = .node, .i = cv.part.k, .j = 0 }, .{ .geom = cv.geom, .role = .node, .i = cv.part.k, .j = inner } };
        },
    };
    // In the carrier's own direction (from its smaller angle or radius).
    const inner_r = if (cv.part.role == .border and pg.dial != null) pg.radius(v, pg.innerRing(PolarGrid.index(cv.part.k, pg.cols) orelse 0)) else v[pg.r[1]];
    const flip = if (cv.part.role == .ring) pg.sweep(v) < 0 else inner_r < v[pg.r[0]];
    const p0 = s.point(if (flip) ends[1] else ends[0]) catch return;
    const p1 = s.point(if (flip) ends[0] else ends[1]) catch return;
    try between(a, k, p0, p1, out);
}

/// The segments of carrier `k` from `p0` to `p1` (both on it): counter-
/// clockwise round a circle or arc (a full turn when they are one place).
fn between(a: Allocator, k: Carrier, p0: Point, p1: Point, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
    switch (k) {
        .straight => try out.append(a, .{ .line = .{ p0, p1 } }),
        .round => |r| {
            const t0 = k.param(p0);
            var sweep = wrap(k.param(p1) - t0);
            if (sweep < 1e-12) sweep = 2 * std.math.pi;
            var buf: [4]geom.Segment = undefined;
            const segs = geom.arc(r.c, r.r, r.a0 + t0, sweep, &buf);
            const first = out.items.len;
            try out.appendSlice(a, segs);
            // Ends exactly at the points, so pieces chain.
            Sketch.setStart(&out.items[first], p0);
            Sketch.setEnd(&out.items[out.items.len - 1], p1);
        },
    }
}

/// The segments piece `p` covers now (none when its curve or points are
/// gone, or it is the endless part of a line or ray).
pub fn appendSegments(s: *const Sketch, a: Allocator, p: Piece, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
    if (p.geom >= s.geometry.items.len) return;
    const g = s.geometry.items[p.geom];
    if (g.removed) return;
    const cv: Curve = .{ .geom = p.geom, .part = p.part };
    if (p.whole()) return wholeSegments(s, a, cv, out);
    if (p.from.?.geom >= s.geometry.items.len or s.geometry.items[p.from.?.geom].removed) return;
    if (p.to.?.geom >= s.geometry.items.len or s.geometry.items[p.to.?.geom].removed) return;
    const p0 = s.point(p.from.?) catch return;
    const p1 = s.point(p.to.?) catch return;
    const k = curveCarrier(s, cv) orelse return;
    try between(a, k, p0, p1, out);
}

/// Whether point `r` is held on curve `c`: its own point, or a
/// constraint holds it there.
fn heldOn(s: *const Sketch, r: PointRef, c: Curve) bool {
    if (r.geom == c.geom) {
        if (c.part.isWhole()) return true;
        // A macro's bind point on its own ring or border.
        if (r.role == .node) switch (s.geometry.items[c.geom].kind) {
            .polar_grid => |pg| switch (c.part.role) {
                .ring => if (PolarGrid.index(r.j, pg.rings) == PolarGrid.index(c.part.k, pg.rings)) return true,
                .border => if (PolarGrid.index(r.i, pg.cols) == PolarGrid.index(c.part.k, pg.cols)) return true,
                .whole => {},
            },
            else => {},
        };
    }
    for (s.constraints.items) |k| switch (k.kind) {
        .point_on => |po| if (po.on == c.geom and std.meta.eql(po.part, c.part) and std.meta.eql(po.p, r)) return true,
        else => {},
    };
    return false;
}

/// A point (of kind point) at `at` held on both `g` and `other`, if one is.
fn crossingPoint(s: *const Sketch, g: Curve, other: Curve, at: Point) ?PointRef {
    for (s.geometry.items, 0..) |o, oi| {
        if (o.removed or o.kind != .point) continue;
        const r: PointRef = .{ .geom = @intCast(oi), .role = .point };
        const p = s.point(r) catch continue;
        if (std.math.hypot(p.x - at.x, p.y - at.y) > eps) continue;
        if (heldOn(s, r, g) and heldOn(s, r, other)) return r;
    }
    return null;
}

/// Cut `c` of curve `g` as a point held on it: a crossing becomes a
/// construction point held on both curves (one already there is used); a
/// point lying on the curve is held on it. With `make` off, nothing is
/// added: null when it would have to be.
fn attachCut(s: *Sketch, a: Allocator, g: Curve, c: Cut, make: bool) root.Error!?PointRef {
    switch (c) {
        .point => |r| {
            if (heldOn(s, r, g)) return r;
            if (!make) return null;
            _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = r, .on = g.geom, .part = g.part } } });
            return r;
        },
        .cross => |x| return attachCrossing(s, a, .{ .a = g.geom, .a_part = g.part, .b = x.other, .b_part = x.other_part, .at = x.at }, make),
    }
}

/// Where two curves cross: a place a constraint can name (the owner,
/// 2026-11-26), made a point when it does (`attachCrossing`).
pub const Crossing = struct { a: GeomId, a_part: Part = .{}, b: GeomId, b_part: Part = .{}, at: Point };

/// Crossing `x` as a point: a construction point held on both curves by
/// point-on constraints (one already there is used). With `make` off,
/// null when there is none yet.
pub fn attachCrossing(s: *Sketch, a: Allocator, x: Crossing, make: bool) root.Error!?PointRef {
    const ca: Curve = .{ .geom = x.a, .part = x.a_part };
    const cb: Curve = .{ .geom = x.b, .part = x.b_part };
    if (crossingPoint(s, ca, cb, x.at)) |r| return r;
    if (!make) return null;
    const id = try s.addPoint(a, x.at, true);
    const r: PointRef = .{ .geom = id, .role = .point };
    _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = r, .on = x.a, .part = x.a_part } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = r, .on = x.b, .part = x.b_part } } });
    return r;
}

/// The crossings of the sketch's curves within `radius` of `q`, nearest
/// first, at most `out.len`; places where a point already is (a curve's
/// end, a point on a curve) are left out: that point is the target.
pub fn crossingsNear(s: *const Sketch, q: Point, radius: f64, out: []Crossing) usize {
    var n: usize = 0;
    var dist: [64]f64 = undefined;
    const items = s.geometry.items;
    for (items, 0..) |ga, ia| {
        if (!isCurve(ga)) continue;
        const ka = carrier(s, ga) orelse continue;
        if (ka.off(q) > radius) continue;
        for (items[ia + 1 ..], ia + 1..) |gb, ib| {
            if (!isCurve(gb)) continue;
            const kb = carrier(s, gb) orelse continue;
            if (kb.off(q) > radius) continue;
            var pts: [2]Point = undefined;
            for (pts[0..meet(ka, kb, &pts)]) |p| {
                const d = std.math.hypot(p.x - q.x, p.y - q.y);
                if (d > radius) continue;
                if (pointAt(s, p)) continue;
                if (n >= out.len or n >= dist.len) {
                    if (n == 0 or d >= dist[n - 1]) continue;
                    n -= 1;
                }
                var k = n;
                while (k > 0 and dist[k - 1] > d) : (k -= 1) {
                    out[k] = out[k - 1];
                    dist[k] = dist[k - 1];
                }
                out[k] = .{ .a = @intCast(ia), .b = @intCast(ib), .at = p };
                dist[k] = d;
                n += 1;
            }
        }
    }
    return n;
}

/// Whether some point (a point, an end, an origin) is at `p`.
fn pointAt(s: *const Sketch, p: Point) bool {
    var buf: [2]PointRef = undefined;
    for (s.geometry.items, 0..) |g, gi| {
        if (g.removed) continue;
        for (endsOf(g, @intCast(gi), &buf)) |r| {
            const q = s.point(r) catch continue;
            if (std.math.hypot(p.x - q.x, p.y - q.y) < eps) return true;
        }
    }
    return false;
}

/// `f` made lasting: its cuts points held on its curve (see `attachCut`).
/// With `make` off, the piece only if nothing needs adding.
pub fn attach(s: *Sketch, a: Allocator, f: Found, make: bool) root.Error!?Piece {
    if (f.whole()) return .{ .geom = f.geom, .part = f.part };
    const cv: Curve = .{ .geom = f.geom, .part = f.part };
    const from = (try attachCut(s, a, cv, f.from.?, make)) orelse return null;
    const to = (try attachCut(s, a, cv, f.to.?, make)) orelse return null;
    return .{ .geom = f.geom, .part = f.part, .from = from, .to = to };
}

/// Every piece of the sketch's curves between their cuts, bounded ones
/// only (as found now).
const Edge = struct {
    f: Found,
    p0: Point,
    p1: Point,
    /// Directions leaving each end along it: at `p0` forward, at `p1`
    /// backward.
    d0: Point,
    d1: Point,
    n0: usize,
    n1: usize,
    k: Carrier,
    t0: f64,
    t1: f64,
};

fn edges(s: *const Sketch, a: Allocator, nodes: *std.ArrayList(Point)) Allocator.Error![]Edge {
    var out: std.ArrayList(Edge) = .empty;
    const node = struct {
        fn f(al: Allocator, ns: *std.ArrayList(Point), p: Point) Allocator.Error!usize {
            for (ns.items, 0..) |q, i| if (std.math.hypot(p.x - q.x, p.y - q.y) < eps) return i;
            try ns.append(al, p);
            return ns.items.len - 1;
        }
    }.f;
    for (try curves(s, a)) |cv| {
        const k = curveCarrier(s, cv) orelse continue;
        const id = cv.geom;
        const cuts = try cutsOnCurve(s, a, cv);
        if (k.closed() and cuts.len < 2) {
            // A circle cut once or not at all: a loop of its own.
            const t0: f64 = if (cuts.len == 1) cuts[0].t else 0;
            const p = k.at(t0);
            const n = try node(a, nodes, p);
            try out.append(a, .{ .f = .{ .geom = id, .part = cv.part }, .p0 = p, .p1 = p, .d0 = k.tangent(t0), .d1 = neg(k.tangent(t0)), .n0 = n, .n1 = n, .k = k, .t0 = t0, .t1 = t0 + 2 * std.math.pi });
            continue;
        }
        const count = if (k.closed()) cuts.len else cuts.len -| 1;
        for (0..count) |i| {
            const c0 = cuts[i];
            const c1 = cuts[(i + 1) % cuts.len];
            var t1 = c1.t;
            if (k.closed() and t1 <= c0.t) t1 += 2 * std.math.pi;
            const whole_seg = bounded(s, cv) and cuts.len == 2;
            try out.append(a, .{
                .f = if (whole_seg) .{ .geom = id, .part = cv.part } else .{ .geom = id, .part = cv.part, .from = c0.cut, .to = c1.cut },
                .p0 = c0.at,
                .p1 = c1.at,
                .d0 = k.tangent(c0.t),
                .d1 = neg(k.tangent(t1)),
                .n0 = try node(a, nodes, c0.at),
                .n1 = try node(a, nodes, c1.at),
                .k = k,
                .t0 = c0.t,
                .t1 = t1,
            });
        }
    }
    return out.items;
}

fn neg(p: Point) Point {
    return .{ .x = -p.x, .y = -p.y };
}

/// The pieces of the smallest closed path of the sketch's curves round
/// `q`: a connected path, end to end, to fill. Null when nothing closes
/// round it.
pub fn loopAround(s: *const Sketch, a: Allocator, q: Point) Allocator.Error!?[]Found {
    var nodes: std.ArrayList(Point) = .empty;
    const es = try edges(s, a, &nodes);
    if (es.len == 0) return null;
    // A ray from q (not along an axis, so it seldom grazes a corner): the
    // first piece it crosses, travelled with q on its left.
    const rd: Point = .{ .x = @cos(0.1234567), .y = @sin(0.1234567) };
    const far = 1e7;
    const ray: Carrier = .{ .straight = .{ .p = q, .d = rd, .t0 = 0, .t1 = far } };
    var best: ?struct { e: usize, fwd: bool, s: f64 } = null;
    for (es, 0..) |e, ei| {
        var pts: [2]Point = undefined;
        // Against the edge's carrier limited to its own range.
        const n = meet(ray, e.k, &pts);
        for (pts[0..n]) |p| {
            var t = e.k.param(p);
            if (e.k == .round and t < e.t0 - 1e-12) t += 2 * std.math.pi;
            if (t < e.t0 - 1e-12 or t > e.t1 + 1e-12) continue;
            const sd = ray.param(p);
            if (sd <= eps) continue;
            if (best != null and best.?.s <= sd) continue;
            const tg = e.k.tangent(t);
            best = .{ .e = ei, .fwd = rd.x * tg.y - rd.y * tg.x > 0, .s = sd };
        }
    }
    const start = best orelse return null;
    // Round the face: at each node, the leaving piece turning most left.
    var path: std.ArrayList(struct { e: usize, fwd: bool }) = .empty;
    var cur_e = start.e;
    var cur_f = start.fwd;
    var steps: usize = 0;
    while (steps < 4 * es.len + 4) : (steps += 1) {
        try path.append(a, .{ .e = cur_e, .fwd = cur_f });
        const e = es[cur_e];
        const v = if (cur_f) e.n1 else e.n0;
        // Arriving direction, reversed: the way back along it.
        const back = if (cur_f) e.d1 else e.d0;
        var pick: ?struct { e: usize, fwd: bool, ang: f64 } = null;
        for (es, 0..) |o, oi| {
            for ([_]bool{ true, false }) |fw| {
                const from = if (fw) o.n0 else o.n1;
                if (from != v) continue;
                const dout = if (fw) o.d0 else o.d1;
                const ccw = std.math.atan2(back.x * dout.y - back.y * dout.x, back.x * dout.x + back.y * dout.y);
                var cw = wrap(-ccw);
                const same = oi == cur_e and fw != cur_f;
                if (same or cw < 1e-9) cw = 2 * std.math.pi;
                if (pick == null or cw < pick.?.ang) pick = .{ .e = oi, .fwd = fw, .ang = cw };
            }
        }
        const nx = pick orelse break;
        cur_e = nx.e;
        cur_f = nx.fwd;
        if (cur_e == start.e and cur_f == start.fwd) break;
    } else return null;
    if (!(cur_e == start.e and cur_f == start.fwd)) return null;
    // Pieces travelled both ways (spurs) are not part of the boundary.
    var out: std.ArrayList(Found) = .empty;
    var area: f64 = 0;
    for (path.items) |h| {
        var twice = false;
        for (path.items) |o| if (o.e == h.e and o.fwd != h.fwd) {
            twice = true;
        };
        if (twice) continue;
        const e = es[h.e];
        // Its signed area (shoelace over a few steps along it).
        const n: usize = if (e.k == .round) 32 else 1;
        for (0..n) |i| {
            const ta = e.t0 + (e.t1 - e.t0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const tb = e.t0 + (e.t1 - e.t0) * @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n));
            const pa = e.k.at(ta);
            const pb = e.k.at(tb);
            area += (pa.x * pb.y - pb.x * pa.y) * (if (h.fwd) @as(f64, 1) else -1) / 2;
        }
        var dup = false;
        for (out.items) |o| if (std.meta.eql(o, e.f)) {
            dup = true;
        };
        if (!dup) try out.append(a, e.f);
    }
    // Travelled clockwise: the outside of everything, not an area round q.
    if (!(area > 0) or out.items.len == 0) return null;
    return out.items;
}

test "pieces: a segment cut by a crossing, attached, and a square's inside" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    // A square of four segments, a diagonal line across it.
    const sq = [4]GeomId{
        try s.addSegment(a, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, false),
        try s.addSegment(a, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, false),
        try s.addSegment(a, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 }, false),
        try s.addSegment(a, .{ .x = 0, .y = 10 }, .{ .x = 0, .y = 0 }, false),
    };
    const cut = try s.addSegment(a, .{ .x = 5, .y = -5 }, .{ .x = 5, .y = 15 }, true);
    // The bottom side, right of the crossing at x = 5.
    const f = try pieceAt(&s, a, sq[0], .{ .x = 8, .y = 0.01 });
    try testing.expect(!f.whole());
    try testing.expect(f.from.? == .cross);
    try testing.expectEqual(cut, f.from.?.cross.other);
    const n = s.geometry.items.len;
    const p = (try attach(&s, a, f, true)).?;
    try testing.expectEqual(n + 1, s.geometry.items.len);
    var segs: std.ArrayList(geom.Segment) = .empty;
    try appendSegments(&s, a, p, &segs);
    try testing.expectEqual(1, segs.items.len);
    try testing.expectApproxEqAbs(5, segs.items[0].start().x, 1e-9);
    try testing.expectApproxEqAbs(10, segs.items[0].end().x, 1e-9);
    // Attached again: the same point.
    const again = (try attach(&s, a, try pieceAt(&s, a, sq[0], .{ .x = 8, .y = 0 }), true)).?;
    try testing.expect(again.eql(p));
    // The right half of the square, round (7, 5): four pieces.
    const loop = (try loopAround(&s, a, .{ .x = 7, .y = 5 })).?;
    try testing.expectEqual(4, loop.len);
    // Outside everything: none.
    try testing.expect((try loopAround(&s, a, .{ .x = 30, .y = 5 })) == null);
}

test "pieces: two circles' lens" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const c1 = try s.addCircle(a, .{ .x = 0, .y = 0 }, 5, false);
    const c2 = try s.addCircle(a, .{ .x = 6, .y = 0 }, 5, false);
    const loop = (try loopAround(&s, a, .{ .x = 3, .y = 0 })).?;
    try testing.expectEqual(2, loop.len);
    var segs: std.ArrayList(geom.Segment) = .empty;
    for (loop) |f| try foundSegments(&s, a, f, &segs);
    const ch = try Sketch.chain(a, segs.items);
    try testing.expectEqual(1, ch.contours.len);
    try testing.expectEqual(0, ch.open);
    _ = c1;
    _ = c2;
    // Inside one circle only: the crescent, also two pieces.
    const left = (try loopAround(&s, a, .{ .x = -3, .y = 0 })).?;
    try testing.expectEqual(2, left.len);
}

test "pieces: a crossing as a constraint target" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    _ = try s.addSegment(a, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, false);
    _ = try s.addSegment(a, .{ .x = 0, .y = 10 }, .{ .x = 10, .y = 0 }, false);
    var xs: [4]Crossing = undefined;
    const n = crossingsNear(&s, .{ .x = 5.2, .y = 5.1 }, 1, &xs);
    try testing.expectEqual(1, n);
    try testing.expectApproxEqAbs(5, xs[0].at.x, 1e-9);
    const r = (try attachCrossing(&s, a, xs[0], true)).?;
    // The point is there now: no longer offered as a crossing, and found again.
    try testing.expectEqual(0, crossingsNear(&s, .{ .x = 5.2, .y = 5.1 }, 1, &xs));
    try testing.expectEqual(r, (try attachCrossing(&s, a, .{ .a = 3, .b = 4, .at = .{ .x = 5, .y = 5 } }, false)).?);
    // Dragging an end: the point stays on both.
    _ = try s.drag(a, testing.allocator, .{ .geom = 3, .role = .end }, .{ .x = 10, .y = 14 });
    const p = try s.point(r);
    try testing.expect(std.math.hypot(p.x - 5, p.y - 5) > 0.1);
}
