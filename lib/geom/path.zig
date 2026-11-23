//! Polyline paths: rings (closed) and lines (open) of points, as a
//! curved outline is flattened to for measuring. A path answers the point
//! on it nearest a given point and how far that is, whether a point lies
//! inside its closed rings, and the area they enclose. The editor's Select
//! boundaries (B) measures the pointer against each object's path with it.

const std = @import("std");
const root = @import("root.zig");
const grow = @import("grow.zig");

const Point = root.Point;
const Box = root.Box;

/// One piece of a path: points, closed (a ring, the last point joined back
/// to the first) or open (a line).
pub const Ring = struct {
    pts: []const Point,
    closed: bool = true,
};

/// The nearest point of a path to a point, and how far it is.
pub const Nearest = struct {
    d: f64,
    at: Point,
};

pub const Path = struct {
    rings: []const Ring,

    /// A rectangle's outline, counter-clockwise from its lower left.
    pub fn box(a: std.mem.Allocator, b: Box) std.mem.Allocator.Error!Path {
        const pts = try a.alloc(Point, 4);
        pts[0] = .{ .x = b.x0, .y = b.y0 };
        pts[1] = .{ .x = b.x1, .y = b.y0 };
        pts[2] = .{ .x = b.x1, .y = b.y1 };
        pts[3] = .{ .x = b.x0, .y = b.y1 };
        const rings = try a.alloc(Ring, 1);
        rings[0] = .{ .pts = pts };
        return .{ .rings = rings };
    }

    /// One closed ring through `pts`.
    pub fn polygon(a: std.mem.Allocator, pts: []const Point) std.mem.Allocator.Error!Path {
        const rings = try a.alloc(Ring, 1);
        rings[0] = .{ .pts = pts };
        return .{ .rings = rings };
    }

    /// An open line from `p0` to `p1`.
    pub fn segment(a: std.mem.Allocator, p0: Point, p1: Point) std.mem.Allocator.Error!Path {
        const pts = try a.alloc(Point, 2);
        pts[0] = p0;
        pts[1] = p1;
        const rings = try a.alloc(Ring, 1);
        rings[0] = .{ .pts = pts, .closed = false };
        return .{ .rings = rings };
    }

    /// An outline's contours, flattened to within `tol` mm, each moved by
    /// `by`. Each is a ring: an outline is filled, so its contours close
    /// (a stretched cap's may end a hair from where it starts).
    pub fn outline(a: std.mem.Allocator, o: root.Outline, tol: f64, by: Point) std.mem.Allocator.Error!Path {
        var rings: std.ArrayList(Ring) = .empty;
        for (o.contours) |c| {
            const pts = try grow.flatten(a, c, tol);
            if (pts.len < 2) continue;
            for (pts) |*q| q.* = .{ .x = q.x + by.x, .y = q.y + by.y };
            try rings.append(a, .{ .pts = pts });
        }
        return .{ .rings = rings.items };
    }

    /// The nearest point of the path to `p`; null for an empty one.
    pub fn nearest(bd: Path, p: Point) ?Nearest {
        var best: ?Nearest = null;
        for (bd.rings) |r| {
            const n = r.pts.len;
            if (n == 0) continue;
            if (n == 1) {
                consider(&best, p, r.pts[0]);
                continue;
            }
            const edges = if (r.closed) n else n - 1;
            for (0..edges) |i| consider(&best, p, closestOnSegment(p, r.pts[i], r.pts[(i + 1) % n]));
        }
        return best;
    }

    /// Whether `p` lies within the path's closed rings (even-odd, so a
    /// hole's inside is outside).
    pub fn contains(bd: Path, p: Point) bool {
        var inside = false;
        for (bd.rings) |r| {
            if (!r.closed or r.pts.len < 3) continue;
            var j = r.pts.len - 1;
            for (r.pts, 0..) |pi, i| {
                const pj = r.pts[j];
                if ((pi.y > p.y) != (pj.y > p.y) and p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x) inside = !inside;
                j = i;
            }
        }
        return inside;
    }

    /// The area the closed rings enclose (outer rings less holes, taken as
    /// the absolute sum of their signed areas): to prefer the smaller of two
    /// objects at the same distance. Zero for a line.
    pub fn area(bd: Path) f64 {
        var s: f64 = 0;
        for (bd.rings) |r| {
            if (!r.closed or r.pts.len < 3) continue;
            var j = r.pts.len - 1;
            for (r.pts, 0..) |pi, i| {
                const pj = r.pts[j];
                s += (pj.x - pi.x) * (pj.y + pi.y);
                j = i;
            }
        }
        return @abs(s) / 2;
    }

    /// Whether it is one closed axis-aligned rectangle: drawn with the box
    /// halo (rounded outward corners) rather than the path halo.
    pub fn asBox(bd: Path) ?Box {
        if (bd.rings.len != 1 or !bd.rings[0].closed or bd.rings[0].pts.len != 4) return null;
        const q = bd.rings[0].pts;
        var b = Box.empty;
        for (q) |v| b = b.join(.{ .x0 = v.x, .y0 = v.y, .x1 = v.x, .y1 = v.y });
        for (0..4) |i| {
            const u = q[i];
            const v = q[(i + 1) % 4];
            if (u.x != v.x and u.y != v.y) return null;
        }
        return b;
    }
};

fn consider(best: *?Nearest, p: Point, q: Point) void {
    const d = std.math.hypot(q.x - p.x, q.y - p.y);
    if (best.* == null or d < best.*.?.d) best.* = .{ .d = d, .at = q };
}

/// The point of segment `a`–`b` nearest `p`.
pub fn closestOnSegment(p: Point, a: Point, b: Point) Point {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (!(len2 > 0)) return a;
    const t = std.math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1);
    return .{ .x = a.x + t * dx, .y = a.y + t * dy };
}

test "a box's path: nearest point, inside, area" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bd = try Path.box(arena.allocator(), .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 4 });
    const n = bd.nearest(.{ .x = 5, .y = 3 }).?;
    try std.testing.expectApproxEqAbs(1, n.d, 1e-12);
    try std.testing.expectApproxEqAbs(4, n.at.y, 1e-12);
    try std.testing.expect(bd.contains(.{ .x = 5, .y = 3 }));
    try std.testing.expect(!bd.contains(.{ .x = 11, .y = 3 }));
    try std.testing.expectApproxEqAbs(40, bd.area(), 1e-12);
    try std.testing.expect(bd.asBox() != null);
}

test "a track of three rows: its lowest edge is as near as its top" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Down one edge and back up the other, as `trackOutline` gives it.
    const pts = [_]Point{ .{ .x = 0, .y = 18 }, .{ .x = 0, .y = 12 }, .{ .x = 0, .y = 6 }, .{ .x = 0, .y = 0 }, .{ .x = 60, .y = 0 }, .{ .x = 60, .y = 6 }, .{ .x = 60, .y = 12 }, .{ .x = 60, .y = 18 } };
    const bd = try Path.polygon(arena.allocator(), &pts);
    try std.testing.expectApproxEqAbs(0.5, bd.nearest(.{ .x = 30, .y = -0.5 }).?.d, 1e-12);
    try std.testing.expectApproxEqAbs(0.5, bd.nearest(.{ .x = 30, .y = 18.5 }).?.d, 1e-12);
    try std.testing.expect(bd.contains(.{ .x = 30, .y = 3 }));
    try std.testing.expectApproxEqAbs(60 * 18, bd.area(), 1e-9);
    try std.testing.expect(bd.asBox() == null);
}

test "a line has no inside and no area" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bd = try Path.segment(arena.allocator(), .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 });
    try std.testing.expect(!bd.contains(.{ .x = 5, .y = 0 }));
    try std.testing.expectEqual(0, bd.area());
    try std.testing.expectApproxEqAbs(2, bd.nearest(.{ .x = 12, .y = 0 }).?.d, 1e-12);
}
