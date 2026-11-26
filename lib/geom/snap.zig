//! Snapping (decided 2026-11-26, the owner: drags snap to other objects'
//! edges and centres, to construction lines and to the grid, with guides
//! drawn while dragging; one mechanism for canvas layouts and sketches).
//!
//! A `Snapper` holds targets: lines across one axis (an edge or a centre
//! of another object, a horizontal or vertical construction line), lines
//! at any angle and points (sketch points, line crossings), and a grid
//! step. A drag asks it to move a set of features (a box's edges and
//! centre, a resized edge, a dragged point) by the least shift that puts
//! one of them on a target within a tolerance; failing that, on the grid.
//! What it snapped to comes back as guides for the editor to draw.
//!
//! Nothing here knows about containers or sketches: callers add boxes,
//! lines and points in one coordinate frame (the space's mm), and the
//! tolerance in that frame (pixels over the zoom).

const std = @import("std");
const geom = @import("root.zig");

/// What a target is, for drawing its guide (and choosing among equals:
/// an edge before a centre).
pub const Kind = enum { edge, centre, line, point, alignment, grid };

/// A line across one axis: `at` on that axis, from `lo` to `hi` along the
/// other (infinite for construction lines and the grid).
pub const Target = struct {
    at: f64,
    lo: f64 = -std.math.inf(f64),
    hi: f64 = std.math.inf(f64),
    kind: Kind,
};

/// A line at any angle, through `at` along unit `dir`.
pub const Line = struct { at: geom.Point, dir: geom.Point };

/// What a snap found along one axis: the shift, the feature that moved
/// onto the target, and the guide to draw (a line across that axis at
/// `at`, from `lo` to `hi` along the other).
pub const Hit = struct {
    shift: f64,
    feature: usize,
    guide: Target,
};

/// What a snap found for a point snapped to a line at an angle or to a
/// point: drawn as that line, or as a mark at the point.
pub const Extra = union(enum) {
    none,
    line: Line,
    point: geom.Point,
};

/// The result of snapping a box or a point: the shift along each axis
/// and the guides that justify it.
pub const Result = struct {
    dx: f64 = 0,
    dy: f64 = 0,
    x: ?Target = null,
    y: ?Target = null,
    extra: Extra = .none,
};

pub const Snapper = struct {
    /// Lines x = const (vertical), and y = const (horizontal).
    xs: std.ArrayList(Target) = .empty,
    ys: std.ArrayList(Target) = .empty,
    lines: std.ArrayList(Line) = .empty,
    points: std.ArrayList(geom.Point) = .empty,
    /// The grid's step, or null for no grid snapping.
    grid: ?f64 = null,

    pub fn deinit(s: *Snapper, a: std.mem.Allocator) void {
        s.xs.deinit(a);
        s.ys.deinit(a);
        s.lines.deinit(a);
        s.points.deinit(a);
    }

    /// A box's edges and centre lines, each spanning the box.
    pub fn addBox(s: *Snapper, a: std.mem.Allocator, b: geom.Box) !void {
        if (b.isEmpty()) return;
        const cx = (b.x0 + b.x1) / 2;
        const cy = (b.y0 + b.y1) / 2;
        try s.xs.appendSlice(a, &.{
            .{ .at = b.x0, .lo = b.y0, .hi = b.y1, .kind = .edge },
            .{ .at = b.x1, .lo = b.y0, .hi = b.y1, .kind = .edge },
            .{ .at = cx, .lo = b.y0, .hi = b.y1, .kind = .centre },
        });
        try s.ys.appendSlice(a, &.{
            .{ .at = b.y0, .lo = b.x0, .hi = b.x1, .kind = .edge },
            .{ .at = b.y1, .lo = b.x0, .hi = b.x1, .kind = .edge },
            .{ .at = cy, .lo = b.x0, .hi = b.x1, .kind = .centre },
        });
    }

    /// An infinite line: across an axis when it runs along the other,
    /// else a line at an angle (points snap onto it).
    pub fn addLine(s: *Snapper, a: std.mem.Allocator, at: geom.Point, dir: geom.Point) !void {
        const eps = 1e-9;
        if (@abs(dir.x) < eps) {
            try s.xs.append(a, .{ .at = at.x, .kind = .line });
        } else if (@abs(dir.y) < eps) {
            try s.ys.append(a, .{ .at = at.y, .kind = .line });
        } else {
            const n = @sqrt(dir.x * dir.x + dir.y * dir.y);
            try s.lines.append(a, .{ .at = at, .dir = .{ .x = dir.x / n, .y = dir.y / n } });
        }
    }

    pub fn addPoint(s: *Snapper, a: std.mem.Allocator, p: geom.Point) !void {
        try s.points.append(a, p);
    }

    /// A point, and the lines across each axis through it (what is dragged
    /// lines up with it: its guide runs from the point).
    pub fn addAligned(s: *Snapper, a: std.mem.Allocator, p: geom.Point) !void {
        try s.points.append(a, p);
        try s.xs.append(a, .{ .at = p.x, .lo = p.y, .hi = p.y, .kind = .alignment });
        try s.ys.append(a, .{ .at = p.y, .lo = p.x, .hi = p.x, .kind = .alignment });
    }

    /// Every crossing of the lines added so far (infinite ones and those
    /// at an angle) added as a point.
    pub fn addCrossings(s: *Snapper, a: std.mem.Allocator) !void {
        var all: std.ArrayList(Line) = .empty;
        defer all.deinit(a);
        for (s.xs.items) |t| if (t.kind == .line) try all.append(a, .{ .at = .{ .x = t.at, .y = 0 }, .dir = .{ .x = 0, .y = 1 } });
        for (s.ys.items) |t| if (t.kind == .line) try all.append(a, .{ .at = .{ .x = 0, .y = t.at }, .dir = .{ .x = 1, .y = 0 } });
        try all.appendSlice(a, s.lines.items);
        for (all.items, 0..) |l, i| for (all.items[i + 1 ..]) |m| {
            if (crossing(l, m)) |p| try s.points.append(a, p);
        };
    }

    /// The least shift along an axis (`vertical`: y) that puts one of
    /// `features` on a target, within `tol`. Edges win over centres at
    /// equal distance. `span` is the moved thing's extent along the other
    /// axis, for the guide to reach it.
    pub fn axis(s: *const Snapper, vertical: bool, features: []const f64, span: [2]f64, tol: f64) ?Hit {
        const list = if (vertical) s.ys.items else s.xs.items;
        var best: ?Hit = null;
        var best_d = tol;
        for (list) |t| for (features, 0..) |f, fi| {
            const d = t.at - f;
            const ad = @abs(d);
            if (ad > tol) continue;
            const better = if (best) |b|
                ad < best_d - 1e-9 or (ad <= best_d + 1e-9 and rank(t.kind) < rank(b.guide.kind))
            else
                true;
            if (!better) continue;
            best_d = ad;
            var g = t;
            if (std.math.isFinite(g.lo)) {
                g.lo = @min(g.lo, span[0]);
                g.hi = @max(g.hi, span[1]);
            }
            best = .{ .shift = d, .feature = fi, .guide = g };
        };
        return best;
    }

    /// Feature `f` on the grid: the shift and a guide across the axis.
    pub fn gridAxis(s: *const Snapper, f: f64) ?Hit {
        const st = s.grid orelse return null;
        if (!(st > 0) or !std.math.isFinite(st)) return null;
        const on = @round(f / st) * st;
        return .{ .shift = on - f, .feature = 0, .guide = .{ .at = on, .kind = .grid } };
    }

    /// Along one axis: a target within `tol`, else feature `grid_ref` on
    /// the grid, else nothing.
    pub fn axisOrGrid(s: *const Snapper, vertical: bool, features: []const f64, grid_ref: usize, span: [2]f64, tol: f64) ?Hit {
        if (s.axis(vertical, features, span, tol)) |h| return h;
        if (grid_ref >= features.len) return null;
        var h = s.gridAxis(features[grid_ref]) orelse return null;
        h.feature = grid_ref;
        return h;
    }

    /// A box moved by (dx, dy): its edges and centres snapped along each
    /// axis, `grid_ref` (0 left/bottom, 1 centre, 2 right/top) going to the
    /// grid where nothing is near.
    pub fn moveBox(s: *const Snapper, b: geom.Box, dx: f64, dy: f64, grid_x: usize, grid_y: usize, tol: f64) Result {
        const m: geom.Box = .{ .x0 = b.x0 + dx, .x1 = b.x1 + dx, .y0 = b.y0 + dy, .y1 = b.y1 + dy };
        var r: Result = .{ .dx = dx, .dy = dy };
        if (s.axisOrGrid(false, &.{ m.x0, (m.x0 + m.x1) / 2, m.x1 }, grid_x, .{ m.y0, m.y1 }, tol)) |h| {
            r.dx += h.shift;
            r.x = h.guide;
        }
        if (s.axisOrGrid(true, &.{ m.y0, (m.y0 + m.y1) / 2, m.y1 }, grid_y, .{ m.x0, m.x1 }, tol)) |h| {
            r.dy += h.shift;
            r.y = h.guide;
        }
        // The guides reach the box where it lands.
        if (r.x) |*g| if (std.math.isFinite(g.lo)) {
            g.lo = @min(g.lo, m.y0 + (r.dy - dy));
            g.hi = @max(g.hi, m.y1 + (r.dy - dy));
        };
        if (r.y) |*g| if (std.math.isFinite(g.lo)) {
            g.lo = @min(g.lo, m.x0 + (r.dx - dx));
            g.hi = @max(g.hi, m.x1 + (r.dx - dx));
        };
        return r;
    }

    /// Point `p` snapped, along the axes it is free on: onto a point
    /// target first (both axes), else each axis onto a line across it,
    /// else onto a line at an angle, else each axis on the grid.
    pub fn point(s: *const Snapper, p: geom.Point, free_x: bool, free_y: bool, tol: f64) Result {
        var r: Result = .{};
        if (free_x and free_y) {
            var best_d = tol;
            var best: ?geom.Point = null;
            for (s.points.items) |q| {
                const d = @sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
                if (d <= best_d) {
                    best_d = d;
                    best = q;
                }
            }
            if (best) |q| return .{ .dx = q.x - p.x, .dy = q.y - p.y, .extra = .{ .point = q } };
        }
        const hx = if (free_x) s.axis(false, &.{p.x}, .{ p.y, p.y }, tol) else null;
        const hy = if (free_y) s.axis(true, &.{p.y}, .{ p.x, p.x }, tol) else null;
        if (hx) |h| {
            r.dx = h.shift;
            r.x = h.guide;
        }
        if (hy) |h| {
            r.dy = h.shift;
            r.y = h.guide;
        }
        if (hx == null and hy == null and free_x and free_y) {
            var best_d = tol;
            for (s.lines.items) |l| {
                const t = (p.x - l.at.x) * l.dir.x + (p.y - l.at.y) * l.dir.y;
                const q: geom.Point = .{ .x = l.at.x + t * l.dir.x, .y = l.at.y + t * l.dir.y };
                const d = @sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
                if (d <= best_d) {
                    best_d = d;
                    r = .{ .dx = q.x - p.x, .dy = q.y - p.y, .extra = .{ .line = l } };
                }
            }
            if (r.extra != .none) return r;
        }
        if (free_x and hx == null) if (s.gridAxis(p.x)) |h| {
            r.dx = h.shift;
            r.x = h.guide;
        };
        if (free_y and hy == null) if (s.gridAxis(p.y)) |h| {
            r.dy = h.shift;
            r.y = h.guide;
        };
        return r;
    }
};

fn rank(k: Kind) u8 {
    return switch (k) {
        .point => 0,
        .edge => 1,
        .line => 2,
        .alignment => 3,
        .centre => 4,
        .grid => 5,
    };
}

/// Where two lines cross, or null for parallel ones.
pub fn crossing(l: Line, m: Line) ?geom.Point {
    const den = l.dir.x * m.dir.y - l.dir.y * m.dir.x;
    if (@abs(den) < 1e-12) return null;
    const t = ((m.at.x - l.at.x) * m.dir.y - (m.at.y - l.at.y) * m.dir.x) / den;
    return .{ .x = l.at.x + t * l.dir.x, .y = l.at.y + t * l.dir.y };
}

const testing = std.testing;

test "snap: a box's nearest edge or centre goes to another's, else the grid" {
    const a = testing.allocator;
    var s: Snapper = .{ .grid = 5 };
    defer s.deinit(a);
    try s.addBox(a, .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 });
    // Its left edge 0.3 from the other's right edge.
    const r = s.moveBox(.{ .x0 = 10.3, .y0 = 21, .x1 = 20.3, .y1 = 31 }, 0, 0, 0, 0, 1);
    try testing.expectApproxEqAbs(@as(f64, -0.3), r.dx, 1e-12);
    try testing.expectEqual(Kind.edge, r.x.?.kind);
    try testing.expectApproxEqAbs(@as(f64, 0), r.x.?.lo, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 31), r.x.?.hi, 1e-12);
    // Nothing near along y: its bottom on the grid.
    try testing.expectApproxEqAbs(@as(f64, -1), r.dy, 1e-12);
    try testing.expectEqual(Kind.grid, r.y.?.kind);
}

test "snap: a point onto a crossing, then onto a line at an angle" {
    const a = testing.allocator;
    var s: Snapper = .{};
    defer s.deinit(a);
    try s.addLine(a, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 });
    try s.addLine(a, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 1 });
    try s.addCrossings(a);
    const r = s.point(.{ .x = 4.2, .y = 3.9 }, true, true, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 4), 4.2 + r.dx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), 3.9 + r.dy, 1e-12);
    const q = s.point(.{ .x = 10.2, .y = 9.9 }, true, true, 0.5);
    try testing.expect(q.extra == .line);
    try testing.expectApproxEqAbs(10.2 + q.dx, 9.9 + q.dy, 1e-12);
}
