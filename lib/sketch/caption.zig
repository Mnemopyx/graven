//! A caption's leader, as sketch geometry: from a point on a side or a
//! curve (a segment, a circle or an arc), a short segment out along the
//! normal there (a side's perpendicular, away from the drawing's middle;
//! a curve's radius, outward), then one turned the shorter way to
//! horizontal (the normal leaning right, it runs right; else left),
//! ending at the point a caption's text is held to. Both are construction
//! (a figure over the sketch inks them), held by ordinary constraints:
//! the first's start on the side or curve (on its point, or kept where
//! it is along it by a dimension: from a side's start, or an angle about
//! a curve's centre) and perpendicular to the side or parallel to the
//! radius through it; the second's start on the first's end and
//! horizontal; each a dimension long. So they follow the side or curve
//! when it moves, turns or grows, and their lengths can be changed.

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const PointRef = root.PointRef;
const Error = root.Error;

pub const Leader = struct {
    /// Out along the normal, then across.
    radial: GeomId,
    across: GeomId,
    /// Where the caption is held: the second segment's end.
    end: PointRef,
    /// It runs right (the caption's left edge on `end`), else left.
    right: bool,
};

/// The circle or arc point `p` is on, and its centre: one it is put on
/// (on object, or a curve's own end), else one it lies on.
fn curveOf(s: *const Sketch, p: PointRef) ?GeomId {
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
fn radiusOf(s: *const Sketch, centre: PointRef, p: PointRef) ?GeomId {
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

pub const AddError = Error || error{NotOnACurve};

/// What a leader starts from: a point on a side or curve, or a side or
/// curve itself (its middle: a side's midpoint, an arc's middle, a
/// circle's upper right).
pub const From = union(enum) { point: PointRef, curve: GeomId };

/// The side point `p` is on: a segment it ends, or one it is put on.
fn sideOf(s: *const Sketch, p: PointRef) ?GeomId {
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
fn drawnMiddle(s: *const Sketch) ?Point {
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

/// Adds a caption's leader at point `p` (on a side, a circle or an arc):
/// `out` along the normal, then `across` (mm).
pub fn addLeader(s: *Sketch, a: Allocator, p: PointRef, out: f64, across: f64) AddError!Leader {
    return addLeaderFrom(s, a, .{ .point = p }, out, across);
}

/// Adds a caption's leader from `from`: `out` along the normal, then
/// `across` (mm).
pub fn addLeaderFrom(s: *Sketch, a: Allocator, from: From, out: f64, across: f64) AddError!Leader {
    const items = s.geometry.items;
    // What it starts on, and whether that is round.
    const on: GeomId, const round: bool = switch (from) {
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
    // Where it starts, and the normal there.
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
        };
        const n = std.math.hypot(pb.x - pa.x, pb.y - pa.y);
        if (!(n > 1e-9)) return error.NotOnACurve;
        // The left normal, turned to point away from the drawing's middle
        // (straight up, when the side runs through it).
        u = .{ .x = -(pb.y - pa.y) / n, .y = (pb.x - pa.x) / n };
        const mid = drawnMiddle(s) orelse at;
        const away = (at.x - mid.x) * u.x + (at.y - mid.y) * u.y;
        if (away < -1e-9 or (@abs(away) <= 1e-9 and u.y < 0)) u = .{ .x = -u.x, .y = -u.y };
    }
    // Straight up or down: to the right.
    const right = u.x >= -1e-9;
    const bend: Point = .{ .x = at.x + u.x * out, .y = at.y + u.y * out };
    const tip: Point = .{ .x = bend.x + (if (right) across else -across), .y = bend.y };

    const l1 = try s.addSegment(a, at, bend, true);
    const l2 = try s.addSegment(a, bend, tip, true);
    const l1a: PointRef = .{ .geom = l1, .role = .start };
    const l1b: PointRef = .{ .geom = l1, .role = .end };
    const l2a: PointRef = .{ .geom = l2, .role = .start };
    const l2b: PointRef = .{ .geom = l2, .role = .end };
    // Its start: on the point, else on the side or curve, kept where it
    // is along it.
    switch (from) {
        .point => |p| _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ l1a, p } } }),
        .curve => {
            _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = l1a, .on = on } } });
            if (!round) {
                const sa: PointRef = .{ .geom = on, .role = .start };
                const pa = try s.point(sa);
                _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = sa, .b = l1a, .value = std.math.hypot(at.x - pa.x, at.y - pa.y) } } });
            }
        },
    }
    if (round) {
        // The radius to keep the first segment parallel to.
        const p_on: PointRef = switch (from) {
            .point => |p| p,
            .curve => l1a,
        };
        const c = try s.point(centre);
        const radius = radiusOf(s, centre, p_on) orelse blk: {
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
            const cr = da.x * u.y - da.y * u.x;
            const dt = da.x * u.x + da.y * u.y;
            _ = try s.addConstraint(a, .{ .kind = .{ .angle = .{ .a = root.v_axis, .b = radius, .value = std.math.atan2(cr, dt) } } });
        }
        _ = try s.addConstraint(a, .{ .kind = .{ .parallel = .{ .a = l1, .b = radius } } });
    } else {
        _ = try s.addConstraint(a, .{ .kind = .{ .perpendicular = .{ .a = l1, .b = on } } });
    }
    _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = l1a, .b = l1b, .value = out } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ l2a, l1b } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .horizontal = .{ .geom = l2 } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .distance_x = .{ .a = l2a, .b = l2b, .value = across, .side = if (right) 1 else -1 } } });
    return .{ .radial = l1, .across = l2, .end = l2b, .right = right };
}

test "a leader from a polar array's ring follows it when it turns" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const refs = try root.arrays.addPolar(&s, a, .{ .x = 0, .y = 0 }, 10, std.math.pi / 2.0, 2 * std.math.pi, 8, 1);
    const pr = refs.polar;
    // The end of the border at 45° (anticlockwise from up: 135°, left).
    const p: PointRef = .{ .geom = pr.second, .role = .end };
    const at = try s.point(p);
    const lead = try addLeader(&s, a, p, 3, 4);
    _ = try s.solve(testing.allocator);
    const e = try s.point(lead.end);
    try testing.expectEqual(at.x >= 0, lead.right);
    const r = std.math.hypot(at.x, at.y);
    const bend = try s.point(.{ .geom = lead.radial, .role = .end });
    try testing.expectApproxEqAbs(r + 3, std.math.hypot(bend.x, bend.y), 1e-6);
    try testing.expectApproxEqAbs(bend.y, e.y, 1e-6);
    try testing.expectApproxEqAbs(4, @abs(e.x - bend.x), 1e-6);
}

test "a leader from a side runs out square to it, away from the drawing, and follows it" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    // A square's right side, from (10, -10) up to (10, 10), and its left.
    const right_side = try s.addSegment(a, .{ .x = 10, .y = -10 }, .{ .x = 10, .y = 10 }, false);
    _ = try s.addSegment(a, .{ .x = -10, .y = 10 }, .{ .x = -10, .y = -10 }, false);
    const lead = try addLeaderFrom(&s, a, .{ .curve = right_side }, 3, 4);
    _ = try s.solve(testing.allocator);
    try testing.expect(lead.right);
    const st = try s.point(.{ .geom = lead.radial, .role = .start });
    const bend = try s.point(.{ .geom = lead.radial, .role = .end });
    const e = try s.point(lead.end);
    try testing.expectApproxEqAbs(10, st.x, 1e-6);
    try testing.expectApproxEqAbs(0, st.y, 1e-6);
    try testing.expectApproxEqAbs(13, bend.x, 1e-6);
    try testing.expectApproxEqAbs(17, e.x, 1e-6);
    try testing.expectApproxEqAbs(0, e.y, 1e-6);
    // The side turned a little: the leader stays square to it.
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = right_side, .role = .start }, .at = .{ .x = 10, .y = -10 } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = right_side, .role = .end }, .at = .{ .x = 12, .y = 10 } } } });
    _ = try s.solve(testing.allocator);
    const st2 = try s.point(.{ .geom = lead.radial, .role = .start });
    const bend2 = try s.point(.{ .geom = lead.radial, .role = .end });
    const e2 = try s.point(lead.end);
    try testing.expectApproxEqAbs(0, (bend2.x - st2.x) * 2 + (bend2.y - st2.y) * 20, 1e-6);
    try testing.expectApproxEqAbs(bend2.y, e2.y, 1e-6);
}

test "a leader from a circle starts at its upper right and stays there as it grows" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const ci = try s.addCircle(a, .{ .x = 0, .y = 0 }, 10, false);
    const lead = try addLeaderFrom(&s, a, .{ .curve = ci }, 3, 4);
    _ = try s.solve(testing.allocator);
    const st = try s.point(.{ .geom = lead.radial, .role = .start });
    try testing.expectApproxEqAbs(10.0 / std.math.sqrt2, st.x, 1e-6);
    try testing.expectApproxEqAbs(10.0 / std.math.sqrt2, st.y, 1e-6);
    _ = try s.addConstraint(a, .{ .kind = .{ .radius = .{ .g = ci, .value = 20 } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = ci, .role = .centre }, .at = .{ .x = 0, .y = 0 } } } });
    _ = try s.solve(testing.allocator);
    const st2 = try s.point(.{ .geom = lead.radial, .role = .start });
    try testing.expectApproxEqAbs(20.0 / std.math.sqrt2, st2.x, 1e-6);
    try testing.expectApproxEqAbs(20.0 / std.math.sqrt2, st2.y, 1e-6);
}
