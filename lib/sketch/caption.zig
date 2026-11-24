//! A caption's leader, as sketch geometry: from a point on a circle or an
//! arc, a short segment on out along the radius, then one turned the
//! shorter way to horizontal (right of the centre it runs right, left of
//! it left), ending at the point a caption's text is held to. Both are
//! construction (a figure over the sketch inks them), held by ordinary
//! constraints: the first's start on the
//! point and parallel to the radius through it, the second's start on the
//! first's end and horizontal, each a dimension long, so they follow the
//! curve when it turns or grows and their lengths can be changed.

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
    /// Out along the radius, then across.
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

/// Adds a caption's leader at point `p` (on a circle or an arc): `out`
/// along the radius, then `across` (mm).
pub fn addLeader(s: *Sketch, a: Allocator, p: PointRef, out: f64, across: f64) AddError!Leader {
    const curve = curveOf(s, p) orelse return error.NotOnACurve;
    const centre: PointRef = .{ .geom = curve, .role = .centre };
    const at = try s.point(p);
    const c = try s.point(centre);
    const n = std.math.hypot(at.x - c.x, at.y - c.y);
    if (!(n > 1e-9)) return error.NotOnACurve;
    const u: Point = .{ .x = (at.x - c.x) / n, .y = (at.y - c.y) / n };
    // Straight up or down: to the right.
    const right = u.x >= -1e-9;
    const bend: Point = .{ .x = at.x + u.x * out, .y = at.y + u.y * out };
    const tip: Point = .{ .x = bend.x + (if (right) across else -across), .y = bend.y };

    // The radius to keep the first segment parallel to.
    const radius = radiusOf(s, centre, p) orelse blk: {
        const r = try s.addSegment(a, c, at, true);
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = r, .role = .start }, centre } } });
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = r, .role = .end }, p } } });
        break :blk r;
    };
    const l1 = try s.addSegment(a, at, bend, true);
    const l2 = try s.addSegment(a, bend, tip, true);
    const l1a: PointRef = .{ .geom = l1, .role = .start };
    const l1b: PointRef = .{ .geom = l1, .role = .end };
    const l2a: PointRef = .{ .geom = l2, .role = .start };
    const l2b: PointRef = .{ .geom = l2, .role = .end };
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ l1a, p } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .parallel = .{ .a = l1, .b = radius } } });
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
