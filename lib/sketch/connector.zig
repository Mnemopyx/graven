//! A connection (the owner, 2026-11-25): a logical object made of the
//! sketch's basic geometry and constraints, not a geometry of its own. It
//! joins an attachment point on a feature (a point on a side or curve, or
//! a side or curve itself) to an end point, by a path of construction
//! geometry it owns, of one of two kinds:
//!
//! - segments: out along the feature's normal (a side's perpendicular,
//!   away from the drawing's middle; a curve's radius), then on to the
//!   end (level, each a dimension long, for a caption's leader);
//! - dubins: the shortest route between the two directed ends with a
//!   bounded bend (`geom.dubins`), laid down as segments and arcs held
//!   tangent, the arcs at the bend radius, the end kept where it is from
//!   the start by two dimensions.
//!
//! Either is converted to the other in place (`convert`): the attachment
//! and end points stay, so whatever is held to them (a caption's text)
//! stays held. What a connection looks like (its stroke, its arrowheads)
//! is its user's: `style` is theirs to name.
//!
//! Its end direction is free (the owner, 2026-11-26): it arrives however
//! its geometry runs into the end, unless it is `level` (a caption's
//! leader, whose text reads along it), when its last piece is held level.

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const PointRef = root.PointRef;
const Error = root.Error;

pub const Kind = enum { segments, dubins };

/// What a connection starts from: a point on a side or curve, a side or
/// curve itself (its middle: a side's midpoint, an arc's middle, a
/// circle's upper right), or nowhere (a free point, leaving at an angle,
/// radians; the owner, 2026-11-25: "connection to/from nowhere is okay",
/// attached later by ordinary constraints, or never).
pub const From = union(enum) {
    point: PointRef,
    curve: GeomId,
    free: struct { at: Point, angle: f64 = 0 },
};

pub const Connector = struct {
    kind: Kind = .segments,
    from: From,
    /// Its attachment point (a point geometry held on `from`) and its end
    /// (a point geometry).
    start: GeomId,
    end: GeomId,
    /// The geometry its direction at the start is held to: the curve's
    /// radius through the start (parallel), or the side (perpendicular);
    /// none for a free start.
    normal: ?GeomId,
    round: bool,
    /// The path's geometry, start to end.
    path: std.ArrayList(GeomId) = .empty,
    /// It arrives running right (else left): which way a level end runs,
    /// and a new path's first jog.
    right: bool,
    /// Its last piece held level (a caption's leader); else it arrives
    /// in whatever direction its path runs into the end.
    level: bool = false,
    /// Its end is held by something else (another point it was made to
    /// reach): its path has no dimensions of its own fixing where the end
    /// is.
    held_end: bool = false,
    /// A Dubins path's bend radius and straight leads, mm.
    radius: f64 = 2,
    lead: f64 = 1,
    /// Its user's style for it (an ID of theirs; 0 for none).
    style: u32 = 0,
};

pub const AddError = Error || error{NotOnACurve};

/// The circle or arc point `p` is on, and its centre: one it is put on
/// (on object, or a curve's own end), else one it lies on.
pub fn curveOf(s: *const Sketch, p: PointRef) ?GeomId {
    const items = s.geometry.items;
    if (p.geom < items.len and (p.role == .start or p.role == .end) and items[p.geom].kind == .arc) return p.geom;
    for (s.constraints.items) |c| switch (c.kind) {
        .point_on => |po| if (std.meta.eql(po.p, p) and po.on < items.len and !items[po.on].removed) switch (items[po.on].kind) {
            .circle, .arc => return po.on,
            else => {},
        },
        else => {},
    };
    const at = s.point(p) catch return null;
    for (items, 0..) |g, gi| {
        if (g.removed) continue;
        const cr: PointRef = .{ .geom = @intCast(gi), .role = .centre };
        const r = switch (g.kind) {
            .circle => |ci| s.vars.items[ci.r],
            .arc => blk: {
                const c = s.point(cr) catch continue;
                const a = s.point(.{ .geom = @intCast(gi), .role = .start }) catch continue;
                break :blk std.math.hypot(a.x - c.x, a.y - c.y);
            },
            else => continue,
        };
        const c = s.point(cr) catch continue;
        if (@abs(std.math.hypot(at.x - c.x, at.y - c.y) - r) < 1e-6 * @max(1, r)) return @intCast(gi);
    }
    return null;
}

/// A segment from the curve's centre to `p` already there (an array's
/// radial border ending on its ring), so no other is added.
pub fn radiusOf(s: *const Sketch, centre: PointRef, p: PointRef) ?GeomId {
    if (p.role != .end or p.geom >= s.geometry.items.len or s.geometry.items[p.geom].kind != .segment) return null;
    const start: PointRef = .{ .geom = p.geom, .role = .start };
    for (s.constraints.items) |c| switch (c.kind) {
        .coincident => |ps| if ((std.meta.eql(ps[0], start) and std.meta.eql(ps[1], centre)) or (std.meta.eql(ps[1], start) and std.meta.eql(ps[0], centre))) return p.geom,
        else => {},
    };
    // Or one whose start is where the centre is.
    const a = s.point(start) catch return null;
    const c = s.point(centre) catch return null;
    return if (std.math.hypot(a.x - c.x, a.y - c.y) < 1e-9) p.geom else null;
}

/// The side point `p` is on: a segment it ends, or one it is put on.
pub fn sideOf(s: *const Sketch, p: PointRef) ?GeomId {
    const items = s.geometry.items;
    if (p.geom < items.len and (p.role == .start or p.role == .end) and items[p.geom].kind == .segment) return p.geom;
    for (s.constraints.items) |c| switch (c.kind) {
        .point_on => |po| if (std.meta.eql(po.p, p) and po.on < items.len and !items[po.on].removed and items[po.on].kind == .segment) return po.on,
        else => {},
    };
    return null;
}

/// The middle of what is drawn (not construction): a side's normal
/// points away from it.
pub fn drawnMiddle(s: *const Sketch) ?Point {
    var b: ?geom.Box = null;
    for (s.geometry.items, 0..) |g, gi| {
        if (g.removed or g.reference or g.construction) continue;
        const roles: []const @FieldType(PointRef, "role") = switch (g.kind) {
            .segment => &.{ .start, .end },
            .circle, .arc => &.{.centre},
            .point => &.{.point},
            else => continue,
        };
        for (roles) |r| {
            const q = s.point(.{ .geom = @intCast(gi), .role = r }) catch continue;
            if (b) |*x| {
                x.x0 = @min(x.x0, q.x);
                x.y0 = @min(x.y0, q.y);
                x.x1 = @max(x.x1, q.x);
                x.y1 = @max(x.y1, q.y);
            } else b = .{ .x0 = q.x, .y0 = q.y, .x1 = q.x, .y1 = q.y };
        }
    }
    const x = b orelse return null;
    return .{ .x = (x.x0 + x.x1) / 2, .y = (x.y0 + x.y1) / 2 };
}


fn pref(g: GeomId) PointRef {
    return .{ .geom = g, .role = .point };
}

/// Adds a connection from `from`, of kind `kind`: for segments, `out`
/// along the normal, then `across` (mm); a Dubins path ends where those
/// would. `level`: its end held level (a caption's leader). Returns its
/// index in `s.connectors`.
pub fn add(s: *Sketch, a: Allocator, from: From, kind: Kind, out: f64, across: f64, level: bool) AddError!usize {
    if (from == .free) return addFree(s, a, from.free.at, from.free.angle, kind, out, across, level);
    // A point on nothing: a free start held on it.
    if (from == .point and curveOf(s, from.point) == null and sideOf(s, from.point) == null) {
        const ci = try addFree(s, a, try s.point(from.point), std.math.pi / 4.0, kind, out, across, level);
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ pref(s.connectors.items[ci].start), from.point } } });
        s.connectors.items[ci].from = from;
        return ci;
    }
    const items = s.geometry.items;
    const on: GeomId, const round: bool = switch (from) {
        .free => unreachable,
        .point => |p| if (curveOf(s, p)) |c| .{ c, true } else if (sideOf(s, p)) |g| .{ g, false } else return error.NotOnACurve,
        .curve => |g| blk: {
            if (g >= items.len or items[g].removed or items[g].reference) return error.NotOnACurve;
            break :blk switch (items[g].kind) {
                .segment => .{ g, false },
                .circle, .arc => .{ g, true },
                else => return error.NotOnACurve,
            };
        },
    };
    var at: Point = undefined;
    var u: Point = undefined;
    const centre: PointRef = .{ .geom = on, .role = .centre };
    if (round) {
        const c = try s.point(centre);
        at = switch (from) {
            .point => |p| try s.point(p),
            .curve => blk: {
                var th: f64 = std.math.pi / 4.0;
                var r: f64 = undefined;
                switch (items[on].kind) {
                    .circle => |ci| r = s.vars.items[ci.r],
                    else => {
                        const pa = try s.point(.{ .geom = on, .role = .start });
                        const pb = try s.point(.{ .geom = on, .role = .end });
                        const ta = std.math.atan2(pa.y - c.y, pa.x - c.x);
                        var tb = std.math.atan2(pb.y - c.y, pb.x - c.x);
                        if (tb <= ta) tb += 2 * std.math.pi;
                        th = (ta + tb) / 2;
                        r = std.math.hypot(pa.x - c.x, pa.y - c.y);
                    },
                }
                break :blk .{ .x = c.x + r * @cos(th), .y = c.y + r * @sin(th) };
            },
            .free => unreachable,
        };
        const n = std.math.hypot(at.x - c.x, at.y - c.y);
        if (!(n > 1e-9)) return error.NotOnACurve;
        u = .{ .x = (at.x - c.x) / n, .y = (at.y - c.y) / n };
    } else {
        const pa = try s.point(.{ .geom = on, .role = .start });
        const pb = try s.point(.{ .geom = on, .role = .end });
        at = switch (from) {
            .point => |p| try s.point(p),
            .curve => .{ .x = (pa.x + pb.x) / 2, .y = (pa.y + pb.y) / 2 },
            .free => unreachable,
        };
        const n = std.math.hypot(pb.x - pa.x, pb.y - pa.y);
        if (!(n > 1e-9)) return error.NotOnACurve;
        u = .{ .x = -(pb.y - pa.y) / n, .y = (pb.x - pa.x) / n };
        const mid = drawnMiddle(s) orelse at;
        const away = (at.x - mid.x) * u.x + (at.y - mid.y) * u.y;
        if (away < -1e-9 or (@abs(away) <= 1e-9 and u.y < 0)) u = .{ .x = -u.x, .y = -u.y };
    }
    // Straight up or down: to the right.
    const right = u.x >= -1e-9;
    const bend: Point = .{ .x = at.x + u.x * out, .y = at.y + u.y * out };
    const tip: Point = .{ .x = bend.x + (if (right) across else -across), .y = bend.y };

    // The attachment point, held on the feature.
    const start = try s.addPoint(a, at, true);
    switch (from) {
        .point => |p| _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ pref(start), p } } }),
        .curve => {
            _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = pref(start), .on = on } } });
            if (!round) {
                const sa: PointRef = .{ .geom = on, .role = .start };
                const pa = try s.point(sa);
                _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = sa, .b = pref(start), .value = std.math.hypot(at.x - pa.x, at.y - pa.y) } } });
            }
        },
        .free => unreachable,
    }
    var normal = on;
    if (round) {
        const p_on: PointRef = switch (from) {
            .point => |p| p,
            .curve, .free => pref(start),
        };
        const c = try s.point(centre);
        normal = radiusOf(s, centre, p_on) orelse blk: {
            const r = try s.addSegment(a, c, at, true);
            _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = r, .role = .start }, centre } } });
            _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = r, .role = .end }, p_on } } });
            break :blk r;
        };
        if (from == .curve) {
            // Where it is round the curve: the radius's angle from the
            // vertical axis.
            const th = s.vars.items[s.geometry.items[root.v_axis].kind.line.theta];
            const da: Point = .{ .x = -@sin(th), .y = @cos(th) };
            _ = try s.addConstraint(a, .{ .kind = .{ .angle = .{ .a = root.v_axis, .b = normal, .value = std.math.atan2(da.x * u.y - da.y * u.x, da.x * u.x + da.y * u.y) } } });
        }
    }
    const end = try s.addPoint(a, tip, true);
    try s.connectors.append(a, .{ .kind = .segments, .from = from, .start = start, .end = end, .normal = normal, .round = round, .right = right, .level = level });
    const ci = s.connectors.items.len - 1;
    try buildSegments(s, a, ci, out, across);
    if (kind == .dubins) try convert(s, a, ci, .dubins);
    return ci;
}

/// A connection from nowhere: its start a free point at `at`, leaving at
/// `angle` (radians), its end where `out` then `across` would take it.
fn addFree(s: *Sketch, a: Allocator, at: Point, angle: f64, kind: Kind, out: f64, across: f64, level: bool) Error!usize {
    const u: Point = .{ .x = @cos(angle), .y = @sin(angle) };
    const right = u.x >= -1e-9;
    const bend: Point = .{ .x = at.x + u.x * out, .y = at.y + u.y * out };
    const tip: Point = .{ .x = bend.x + (if (right) across else -across), .y = bend.y };
    const start = try s.addPoint(a, at, true);
    const end = try s.addPoint(a, tip, true);
    try s.connectors.append(a, .{ .kind = .segments, .from = .{ .free = .{ .at = at, .angle = angle } }, .start = start, .end = end, .normal = null, .round = false, .right = right, .level = level });
    const ci = s.connectors.items.len - 1;
    try buildSegments(s, a, ci, out, across);
    if (kind == .dubins) try convert(s, a, ci, .dubins);
    return ci;
}

/// Ends connection `ci` at point `p` (held coincident): its path then
/// reaches `p` wherever it goes, with no dimensions of its own fixing its
/// end. A joined-segments path becomes a Dubins path, which can reach a
/// point anywhere.
pub fn reach(s: *Sketch, a: Allocator, ci: usize, p: PointRef) Error!void {
    const c = s.connectors.items[ci];
    const to = try s.point(p);
    const at = try s.point(pref(c.start));
    s.connectors.items[ci].right = to.x >= at.x;
    s.connectors.items[ci].held_end = true;
    const ep = s.geometry.items[c.end].kind.point;
    s.vars.items[ep.x] = to.x;
    s.vars.items[ep.y] = to.y;
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ pref(c.end), p } } });
    s.connectors.items[ci].kind = .segments;
    // A free end arrives heading the way the point lies from the start.
    try rebuildArriving(s, a, ci, .dubins, if (c.level) null else std.math.atan2(to.y - at.y, to.x - at.x));
}

/// Holds straight geometry `g`'s direction to the connection's normal
/// (none for a free start).
fn holdNormal(s: *Sketch, a: Allocator, c: Connector, g: GeomId) Error!void {
    const n = c.normal orelse return;
    _ = try s.addConstraint(a, .{ .kind = if (c.round) .{ .parallel = .{ .a = g, .b = n } } else .{ .perpendicular = .{ .a = g, .b = n } } });
}

/// Segments: out along the normal, then on to the end. Level, the jog is
/// `across` long and held level; else `out` is the bend's distance from
/// the start along the normal and the second segment runs to the end
/// wherever it is.
fn buildSegments(s: *Sketch, a: Allocator, ci: usize, out: f64, across: f64) Error!void {
    const c = s.connectors.items[ci];
    const at = try s.point(pref(c.start));
    const tip = try s.point(pref(c.end));
    // As a new path is made: out, then `across` level to the end.
    return buildSegmentsAt(s, a, ci, at, .{ .x = tip.x + (if (c.right) -across else across), .y = tip.y }, tip, out, across);
}

/// Segments out from the start along `u`, `out` long, then straight to
/// the end (a free end's path made again).
fn buildSegmentsAlong(s: *Sketch, a: Allocator, ci: usize, u: Point, out: f64) Error!void {
    const c = s.connectors.items[ci];
    const at = try s.point(pref(c.start));
    const tip = try s.point(pref(c.end));
    const bend: Point = .{ .x = at.x + u.x * out, .y = at.y + u.y * out };
    return buildSegmentsAt(s, a, ci, at, bend, tip, out, @abs(tip.x - bend.x));
}

fn buildSegmentsAt(s: *Sketch, a: Allocator, ci: usize, at: Point, bend: Point, tip: Point, out: f64, across: f64) Error!void {
    const c = s.connectors.items[ci];
    const l1 = try s.addSegment(a, at, bend, true);
    const l2 = try s.addSegment(a, bend, tip, true);
    const l1a: PointRef = .{ .geom = l1, .role = .start };
    const l1b: PointRef = .{ .geom = l1, .role = .end };
    const l2a: PointRef = .{ .geom = l2, .role = .start };
    const l2b: PointRef = .{ .geom = l2, .role = .end };
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ l1a, pref(c.start) } } });
    try holdNormal(s, a, c, l1);
    if (!c.held_end) _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = l1a, .b = l1b, .value = out } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ l2a, l1b } } });
    if (c.level) {
        _ = try s.addConstraint(a, .{ .kind = .{ .horizontal = .{ .geom = l2 } } });
        if (!c.held_end) _ = try s.addConstraint(a, .{ .kind = .{ .distance_x = .{ .a = l2a, .b = l2b, .value = across, .side = if (c.right) 1 else -1 } } });
    }
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ l2b, pref(c.end) } } });
    // A free end kept where it is from the start, as a Dubins path's.
    if (!c.level and !c.held_end) try holdEnd(s, a, c, at, tip);
    var path = &s.connectors.items[ci].path;
    path.clearRetainingCapacity();
    try path.append(a, l1);
    try path.append(a, l2);
}

/// The direction (unit) the connection leaves its start in now.
fn leaving(s: *const Sketch, c: Connector) Error!Point {
    const at = try s.point(pref(c.start));
    if (c.round) if (c.normal) |nm| {
        const g = s.geometry.items[nm];
        const o = try s.point(if (g.kind == .segment) .{ .geom = nm, .role = .start } else .{ .geom = nm, .role = .centre });
        const n = std.math.hypot(at.x - o.x, at.y - o.y);
        if (n > 1e-9) return .{ .x = (at.x - o.x) / n, .y = (at.y - o.y) / n };
    };
    // Along its first piece, out from the start.
    if (c.path.items.len > 0) {
        const g = c.path.items[0];
        const p0 = try s.point(.{ .geom = g, .role = .start });
        const p1 = try s.point(.{ .geom = g, .role = .end });
        const far = if (std.math.hypot(p0.x - at.x, p0.y - at.y) < std.math.hypot(p1.x - at.x, p1.y - at.y)) p1 else p0;
        const n = std.math.hypot(far.x - at.x, far.y - at.y);
        if (n > 1e-9) return .{ .x = (far.x - at.x) / n, .y = (far.y - at.y) / n };
    }
    return .{ .x = 1, .y = 0 };
}

/// The end kept where it is from the start, by two dimensions.
fn holdEnd(s: *Sketch, a: Allocator, c: Connector, at: Point, tip: Point) Error!void {
    _ = try s.addConstraint(a, .{ .kind = .{ .distance_x = .{ .a = pref(c.start), .b = pref(c.end), .value = @abs(tip.x - at.x) } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .distance_y = .{ .a = pref(c.start), .b = pref(c.end), .value = @abs(tip.y - at.y) } } });
}

/// The level direction (radians) a level end arrives in.
fn levelAngle(c: Connector) f64 {
    return if (c.right) 0 else std.math.pi;
}

/// A Dubins path from the start, leaving along `u`, into the end heading
/// `arrive` (radians).
fn buildDubins(s: *Sketch, a: Allocator, ci: usize, u: Point, arrive: f64) Error!void {
    const c = s.connectors.items[ci];
    const at = try s.point(pref(c.start));
    const tip = try s.point(pref(c.end));
    const rt = geom.dubins.route(
        .{ .at = at, .angle = std.math.atan2(u.y, u.x), .lead = c.lead },
        .{ .at = tip, .angle = arrive, .lead = c.lead },
        c.radius,
    );
    var path: std.ArrayList(GeomId) = .empty;
    // Each piece's geometry, and its ends in path order.
    var prev: ?struct { g: GeomId, end: PointRef, arc: bool } = null;
    var first = true;
    for (rt.items(), 0..) |pc, k| {
        if (pc.length() < 1e-6 and !(k == 0 or k + 1 == rt.n)) continue;
        var g: GeomId = undefined;
        var p_start: PointRef = undefined;
        var p_end: PointRef = undefined;
        var is_arc = false;
        switch (pc) {
            .line => |l| {
                g = try s.addSegment(a, l.a, l.b, true);
                p_start = .{ .geom = g, .role = .start };
                p_end = .{ .geom = g, .role = .end };
            },
            .arc => |ar| {
                const q0 = pc.at(0);
                const q1 = pc.at(1);
                is_arc = true;
                if (ar.sweep >= 0) {
                    g = try s.addArc(a, ar.c, q0, q1, true);
                    p_start = .{ .geom = g, .role = .start };
                    p_end = .{ .geom = g, .role = .end };
                } else {
                    g = try s.addArc(a, ar.c, q1, q0, true);
                    p_start = .{ .geom = g, .role = .end };
                    p_end = .{ .geom = g, .role = .start };
                }
                _ = try s.addConstraint(a, .{ .kind = .{ .radius = .{ .g = g, .value = ar.r } } });
            },
        }
        if (first) {
            _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ p_start, pref(c.start) } } });
            if (!is_arc) {
                try holdNormal(s, a, c, g);
                _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = p_start, .b = p_end, .value = pc.length() } } });
            }
            first = false;
        } else if (prev) |pv| {
            _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ pv.end, p_start } } });
            if (pv.arc or is_arc) {
                _ = try s.addConstraint(a, .{ .kind = .{ .tangent = .{ .a = pv.g, .b = g } } });
            } else {
                _ = try s.addConstraint(a, .{ .kind = .{ .parallel = .{ .a = pv.g, .b = g } } });
            }
        }
        prev = .{ .g = g, .end = p_end, .arc = is_arc };
        try path.append(a, g);
    }
    const last = prev orelse return;
    if (!last.arc) {
        if (c.level) _ = try s.addConstraint(a, .{ .kind = .{ .horizontal = .{ .geom = last.g } } });
        if (path.items.len > 1) _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = .{ .geom = last.g, .role = .start }, .b = last.end, .value = c.lead } } });
    }
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ last.end, pref(c.end) } } });
    // The end kept where it is from the start (unless held otherwise).
    if (c.held_end) {
        s.connectors.items[ci].path = path;
        return;
    }
    try holdEnd(s, a, c, at, tip);
    s.connectors.items[ci].path = path;
}

/// Makes connection `ci` of kind `kind`: its path's geometry (and the
/// constraints on it) replaced; its start and end stay where they are.
pub fn convert(s: *Sketch, a: Allocator, ci: usize, kind: Kind) Error!void {
    const c = s.connectors.items[ci];
    if (c.kind == kind and c.path.items.len > 0) return;
    try rebuild(s, a, ci, kind);
}

/// Holds connection `ci`'s end level, or frees its direction; its path
/// made again between its ends where they are.
pub fn setLevel(s: *Sketch, a: Allocator, ci: usize, level: bool) Error!void {
    if (s.connectors.items[ci].level == level) return;
    s.connectors.items[ci].level = level;
    if (level) s.connectors.items[ci].right = blk: {
        const at = try s.point(pref(s.connectors.items[ci].start));
        const tip = try s.point(pref(s.connectors.items[ci].end));
        break :blk tip.x >= at.x;
    };
    try rebuild(s, a, ci, s.connectors.items[ci].kind);
}

/// Sets connection `ci`'s bend radius and leads (a Dubins path's), its
/// path rebuilt in them.
pub fn setShape(s: *Sketch, a: Allocator, ci: usize, radius: f64, lead: f64) (Error || error{BadValue})!void {
    if (!(radius > 0) or !(lead >= 0) or !std.math.isFinite(radius) or !std.math.isFinite(lead)) return error.BadValue;
    s.connectors.items[ci].radius = radius;
    s.connectors.items[ci].lead = lead;
    if (s.connectors.items[ci].kind == .dubins) try rebuild(s, a, ci, .dubins);
}

/// Connection `ci`'s path made again, of kind `kind`, between its ends
/// where they are.
fn rebuild(s: *Sketch, a: Allocator, ci: usize, kind: Kind) Error!void {
    return rebuildArriving(s, a, ci, kind, null);
}

/// As `rebuild`, a free end arriving heading `arrive` (radians; null: as
/// it does now).
fn rebuildArriving(s: *Sketch, a: Allocator, ci: usize, kind: Kind, arrive: ?f64) Error!void {
    const c = s.connectors.items[ci];
    const u = try leaving(s, c);
    const into = if (c.level) levelAngle(c) else arrive orelse try arriving(s, a, ci);
    const at = try s.point(pref(c.start));
    const tip = try s.point(pref(c.end));
    for (c.path.items) |g| try s.removeGeometry(g);
    // A Dubins path's hold on the end, between the two points.
    var i: usize = s.constraints.items.len;
    while (i > 0) {
        i -= 1;
        switch (s.constraints.items[i].kind) {
            inline .distance_x, .distance_y => |d| if ((d.a.geom == c.start and d.b.geom == c.end) or (d.a.geom == c.end and d.b.geom == c.start)) {
                s.dropConstraint(@intCast(i));
            },
            else => {},
        }
    }
    s.connectors.items[ci].path = .empty;
    s.connectors.items[ci].kind = kind;
    switch (kind) {
        .segments => if (c.level) {
            // Out along the normal to the end's level, then across.
            const out = if (@abs(u.y) > 0.2) @max(0.5, (tip.y - at.y) / u.y) else 3;
            const bend: Point = .{ .x = at.x + u.x * out, .y = at.y + u.y * out };
            try buildSegments(s, a, ci, out, @max(0.5, @abs(tip.x - bend.x)));
        } else {
            // Out along the normal (no further than the end lies that
            // way, up to 3 mm), then straight to the end.
            const ahead = (tip.x - at.x) * u.x + (tip.y - at.y) * u.y;
            try buildSegmentsAlong(s, a, ci, u, std.math.clamp(ahead / 2, 0.5, 3));
        },
        .dubins => try buildDubins(s, a, ci, u, into),
    }
}

/// The connection's path as exact segments (lines and conics), start to
/// end (each piece turned to run that way), and its directions at its two
/// ends (radians), as its geometry runs: leaving the start, and arriving
/// at the end.
pub fn segments(s: *const Sketch, a: Allocator, ci: usize, out: *std.ArrayList(geom.Segment)) Error!struct { leave: f64, arrive: f64 } {
    const c = s.connectors.items[ci];
    const first = out.items.len;
    var at = try s.point(pref(c.start));
    for (c.path.items) |g| {
        if (g >= s.geometry.items.len or s.geometry.items[g].removed) continue;
        const k = out.items.len;
        try s.appendSegments(a, s.geometry.items[g], out);
        const piece = out.items[k..];
        if (piece.len == 0) continue;
        // Its pieces in path order: turned when it ends nearer `at`.
        const p0 = piece[0].start();
        const p1 = piece[piece.len - 1].end();
        if (std.math.hypot(p1.x - at.x, p1.y - at.y) < std.math.hypot(p0.x - at.x, p0.y - at.y)) {
            std.mem.reverse(geom.Segment, piece);
            for (piece) |*sg| sg.* = sg.reversed();
        }
        at = piece[piece.len - 1].end();
    }
    const path = out.items[first..];
    if (path.len == 0) {
        const u = try leaving(s, c);
        return .{ .leave = std.math.atan2(u.y, u.x), .arrive = levelAngle(c) };
    }
    return .{ .leave = geom.trim.leaving(path[0]), .arrive = geom.trim.arriving(path[path.len - 1]) };
}

/// The direction (radians) connection `ci` arrives at its end in now.
fn arriving(s: *const Sketch, a: Allocator, ci: usize) Error!f64 {
    var segs: std.ArrayList(geom.Segment) = .empty;
    defer segs.deinit(a);
    return (try segments(s, a, ci, &segs)).arrive;
}

test "a connection from nowhere, made to reach a point: a Dubins path to it that follows it" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const k = try add(&s, a, .{ .free = .{ .at = .{ .x = 0, .y = 0 }, .angle = std.math.pi / 2.0 } }, .segments, 3, 4, false);
    _ = try s.solve(testing.allocator);
    try testing.expect(s.connectors.items[k].normal == null);
    const e = try s.point(pref(s.connectors.items[k].end));
    try testing.expectApproxEqAbs(4, e.x, 1e-6);
    try testing.expectApproxEqAbs(3, e.y, 1e-6);
    // Made to reach a point: a Dubins path to it.
    const q = try s.addPoint(a, .{ .x = 20, .y = 8 }, false);
    try reach(&s, a, k, pref(q));
    _ = try s.solve(testing.allocator);
    try testing.expectEqual(.dubins, s.connectors.items[k].kind);
    const e2 = try s.point(pref(s.connectors.items[k].end));
    try testing.expectApproxEqAbs(20, e2.x, 1e-6);
    try testing.expectApproxEqAbs(8, e2.y, 1e-6);
    // A wider bend, the path rebuilt in it, still reaching the point.
    try setShape(&s, a, k, 3, 1);
    _ = try s.solve(testing.allocator);
    const e3 = try s.point(pref(s.connectors.items[k].end));
    try testing.expectApproxEqAbs(20, e3.x, 1e-6);
}

test "a connection's path converted to a Dubins path and back keeps its ends" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const ci_g = try s.addCircle(a, .{ .x = 0, .y = 0 }, 10, false);
    const k = try add(&s, a, .{ .curve = ci_g }, .segments, 3, 6, false);
    _ = try s.solve(testing.allocator);
    const e0 = try s.point(pref(s.connectors.items[k].end));
    try convert(&s, a, k, .dubins);
    _ = try s.solve(testing.allocator);
    const e1 = try s.point(pref(s.connectors.items[k].end));
    try testing.expectApproxEqAbs(e0.x, e1.x, 1e-6);
    try testing.expectApproxEqAbs(e0.y, e1.y, 1e-6);
    try testing.expect(s.connectors.items[k].path.items.len >= 2);
    // Its pieces join end to end, from the start to the end.
    var segs: std.ArrayList(geom.Segment) = .empty;
    _ = try segments(&s, a, k, &segs);
    try testing.expect(segs.items.len >= 2);
    // The circle grows: the path follows, still ending level.
    _ = try s.addConstraint(a, .{ .kind = .{ .radius = .{ .g = ci_g, .value = 12 } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = ci_g, .role = .centre }, .at = .{ .x = 0, .y = 0 } } } });
    _ = try s.solve(testing.allocator);
    const st = try s.point(pref(s.connectors.items[k].start));
    try testing.expectApproxEqAbs(12, std.math.hypot(st.x, st.y), 1e-5);
    try convert(&s, a, k, .segments);
    _ = try s.solve(testing.allocator);
    const e2 = try s.point(pref(s.connectors.items[k].end));
    try testing.expectApproxEqAbs(e1.y + (st.y - 10.0 / std.math.sqrt2), e2.y, 0.5);
    try testing.expectEqual(2, s.connectors.items[k].path.items.len);
}

test "a connection made to reach a point arrives as its path runs; a level one's stays level" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |level| {
        var s = try Sketch.init(a);
        const circle = try s.addCircle(a, .{ .x = 0, .y = 0 }, 10, false);
        _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = circle, .role = .centre }, .at = .{ .x = 0, .y = 0 } } } });
        _ = try s.addConstraint(a, .{ .kind = .{ .radius = .{ .g = circle, .value = 10 } } });
        const k = try add(&s, a, .{ .curve = circle }, .segments, 3, 6, level);
        _ = try s.solve(testing.allocator);
        const e = try s.point(pref(s.connectors.items[k].end));
        const to: Point = .{ .x = e.x + 4, .y = e.y + 12 };
        const q = try s.addPoint(a, to, false);
        _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = pref(q), .at = to } } });
        try reach(&s, a, k, pref(q));
        _ = try s.solve(testing.allocator);
        // The point moves on: the path follows.
        for (s.constraints.items) |*c| switch (c.kind) {
            .fixed => |*f| if (std.meta.eql(f.p, pref(q))) {
                f.at = .{ .x = to.x + 3, .y = to.y + 2 };
            },
            else => {},
        };
        _ = try s.solve(testing.allocator);
        for ([_]Kind{ .dubins, .segments }) |kind| {
            try convert(&s, a, k, kind);
            _ = try s.solve(testing.allocator);
            var segs: std.ArrayList(geom.Segment) = .empty;
            const d = try segments(&s, a, k, &segs);
            // Its pieces join, start to end, ending on the point.
            for (segs.items[1..], segs.items[0 .. segs.items.len - 1]) |b, p| {
                try testing.expectApproxEqAbs(p.end().x, b.start().x, 1e-6);
                try testing.expectApproxEqAbs(p.end().y, b.start().y, 1e-6);
            }
            const last = segs.items[segs.items.len - 1].end();
            try testing.expectApproxEqAbs(to.x + 3, last.x, 1e-6);
            try testing.expectApproxEqAbs(to.y + 2, last.y, 1e-6);
            // Level: running right or left; else as it runs.
            if (level) {
                try testing.expectApproxEqAbs(0, @sin(d.arrive), 1e-6);
            } else {
                try testing.expect(@abs(@sin(d.arrive)) > 0.05);
            }
        }
    }
}
