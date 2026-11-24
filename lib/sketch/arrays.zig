//! Arrays as sketch geometry: a pattern of cells made of plain points,
//! segments, circles and arcs, held by ordinary constraints, so every part
//! of it can be picked and constrained as any other geometry is.
//!
//! A polar array: a centre point; radial segments from it, one per border
//! between columns, each at a fixed angle to the next; rings (circles, or
//! arcs between the outermost radial segments when it does not go all the
//! way round) about the centre, equally spaced out from it; the radial
//! segments ending on the outer ring. What is left free: where the centre
//! is, how far the array is turned, and its outer radius.
//!
//! A rectangular array: vertical segments between its columns and
//! horizontal ones between its rows, ending on the outer ones, each set
//! equally spaced. Left free: its corner, width and height.
//!
//! Its geometry is construction (a guide for placing things in its cells,
//! never output).

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const PointRef = root.PointRef;
const Error = root.Error;

/// An array's geometry, by ID: enough to find its cells as solved.
pub const Refs = union(enum) {
    polar: struct {
        centre: GeomId,
        /// The first radial border (column 0's anticlockwise side) and the
        /// next (clockwise from it).
        first: GeomId,
        second: GeomId,
        /// The outer ring (a circle, or an arc).
        outer: GeomId,
    },
    rect: struct { left: GeomId, right: GeomId, top: GeomId, bottom: GeomId },
};

/// Its cells as solved: a polar array's centre, its first border's angle
/// (radians), the angle between borders (radians, clockwise) and its outer
/// radius; a rectangular array's box.
pub const Cells = union(enum) {
    polar: struct { c: Point, first: f64, step: f64, r: f64 },
    rect: geom.Box,
};

fn dir(t: f64) Point {
    return .{ .x = @cos(t), .y = @sin(t) };
}

fn at(c: Point, r: f64, t: f64) Point {
    return .{ .x = c.x + r * @cos(t), .y = c.y + r * @sin(t) };
}

/// Adds a polar array of `cols` columns round `c` and `rings` rings out to
/// radius `r`: its first border at angle `first` (radians), its columns
/// running clockwise over `sweep` (radians; 2π, or more, all the way
/// round).
pub fn addPolar(s: *Sketch, a: Allocator, c: Point, r: f64, first: f64, sweep_in: f64, cols: u32, rings: u32) Error!Refs {
    if (cols == 0 or rings == 0 or !(r > 0)) return error.WrongKind;
    const full = sweep_in >= 2 * std.math.pi - 1e-9;
    const sweep = if (full) 2 * std.math.pi else sweep_in;
    const step = sweep / @as(f64, @floatFromInt(cols));
    const n_lines: usize = if (full) cols else cols + 1;
    const m: usize = rings;
    const centre = try s.addPoint(a, c, true);
    const cref: PointRef = .{ .geom = centre };

    // Radial borders, from the centre, a fixed angle apart.
    var lines: std.ArrayList(GeomId) = .empty;
    defer lines.deinit(a);
    for (0..n_lines) |i| {
        const t = first - @as(f64, @floatFromInt(i)) * step;
        const l = try s.addSegment(a, c, at(c, r, t), true);
        try lines.append(a, l);
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = l, .role = .start }, cref } } });
        // The angle from each border to the one before it, anticlockwise.
        if (i > 0) _ = try s.addConstraint(a, .{ .kind = .{ .angle = .{ .a = l, .b = lines.items[i - 1], .value = step } } });
    }
    const l0 = lines.items[0];
    const l_last = lines.items[n_lines - 1];

    // Rings about the centre: circles, or arcs from the last border round
    // to the first (anticlockwise). Each ring's point on the first border
    // marks how far out it is; they are spaced equally.
    var marks: std.ArrayList(PointRef) = .empty;
    defer marks.deinit(a);
    var outer: GeomId = 0;
    for (1..m + 1) |k| {
        const rk = r * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(m));
        const ring = if (full)
            try s.addCircle(a, c, rk, true)
        else
            try s.addArc(a, c, at(c, rk, first - sweep), at(c, rk, first), true);
        _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = ring, .role = .centre }, cref } } });
        if (k == m) outer = ring;
        if (full) {
            if (k == m) {
                try marks.append(a, .{ .geom = l0, .role = .end });
            } else {
                const p = try s.addPoint(a, at(c, rk, first), true);
                _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = p }, .on = ring } } });
                _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = p }, .on = l0 } } });
                try marks.append(a, .{ .geom = p });
            }
        } else {
            // The arc's ends on the outermost borders (the outer arc's at
            // the borders' ends).
            if (k == m) {
                _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = ring, .role = .start }, .{ .geom = l_last, .role = .end } } } });
                _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = ring, .role = .end }, .{ .geom = l0, .role = .end } } } });
            } else {
                _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = ring, .role = .start }, .on = l_last } } });
                _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = ring, .role = .end }, .on = l0 } } });
            }
            try marks.append(a, .{ .geom = ring, .role = .end });
        }
    }
    // Every border ends on the outer ring (the outermost ones already do
    // when it is an arc).
    for (lines.items, 0..) |l, i| {
        if (!full and (i == 0 or i == n_lines - 1)) continue;
        _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = l, .role = .end }, .on = outer } } });
    }
    // Equally spaced rings: each gap as wide as the first (centre to the
    // first ring).
    for (1..marks.items.len) |k| {
        _ = try s.addConstraint(a, .{ .kind = .{ .equal_distance = .{
            .a = .{ .points = .{ cref, marks.items[0] } },
            .b = .{ .points = .{ marks.items[k - 1], marks.items[k] } },
        } } });
    }
    return .{ .polar = .{ .centre = centre, .first = l0, .second = lines.items[1 % n_lines], .outer = outer } };
}

/// Adds a rectangular array of `cols` × `rows` cells over box `b`.
pub fn addRect(s: *Sketch, a: Allocator, b: geom.Box, cols: u32, rows: u32) Error!Refs {
    if (cols == 0 or rows == 0 or !(b.x1 > b.x0 and b.y1 > b.y0)) return error.WrongKind;
    const w = b.x1 - b.x0;
    const h = b.y1 - b.y0;
    // Vertical borders, left to right; horizontal, top to bottom.
    var vs: std.ArrayList(GeomId) = .empty;
    defer vs.deinit(a);
    var hs: std.ArrayList(GeomId) = .empty;
    defer hs.deinit(a);
    for (0..cols + 1) |i| {
        const x = b.x0 + w * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(cols));
        const v = try s.addSegment(a, .{ .x = x, .y = b.y1 }, .{ .x = x, .y = b.y0 }, true);
        _ = try s.addConstraint(a, .{ .kind = .{ .vertical = .{ .geom = v } } });
        try vs.append(a, v);
    }
    for (0..rows + 1) |j| {
        const y = b.y1 - h * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(rows));
        const hz = try s.addSegment(a, .{ .x = b.x0, .y = y }, .{ .x = b.x1, .y = y }, true);
        _ = try s.addConstraint(a, .{ .kind = .{ .horizontal = .{ .geom = hz } } });
        try hs.append(a, hz);
    }
    const left = vs.items[0];
    const right = vs.items[cols];
    const top = hs.items[0];
    const bottom = hs.items[rows];
    // The outline's corners joined; inner borders end on the outer ones.
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = top, .role = .start }, .{ .geom = left, .role = .start } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = top, .role = .end }, .{ .geom = right, .role = .start } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = bottom, .role = .start }, .{ .geom = left, .role = .end } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = bottom, .role = .end }, .{ .geom = right, .role = .end } } } });
    for (vs.items[1..cols]) |v| {
        _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = v, .role = .start }, .on = top } } });
        _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = v, .role = .end }, .on = bottom } } });
    }
    for (hs.items[1..rows]) |hz| {
        _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = hz, .role = .start }, .on = left } } });
        _ = try s.addConstraint(a, .{ .kind = .{ .point_on = .{ .p = .{ .geom = hz, .role = .end }, .on = right } } });
    }
    // Equally spaced: each gap as wide as the first.
    for (2..cols + 1) |i| _ = try s.addConstraint(a, .{ .kind = .{ .equal_distance = .{
        .a = .{ .x = .{ .{ .geom = vs.items[0], .role = .start }, .{ .geom = vs.items[1], .role = .start } } },
        .b = .{ .x = .{ .{ .geom = vs.items[i - 1], .role = .start }, .{ .geom = vs.items[i], .role = .start } } },
    } } });
    for (2..rows + 1) |j| _ = try s.addConstraint(a, .{ .kind = .{ .equal_distance = .{
        .a = .{ .y = .{ .{ .geom = hs.items[0], .role = .start }, .{ .geom = hs.items[1], .role = .start } } },
        .b = .{ .y = .{ .{ .geom = hs.items[j - 1], .role = .start }, .{ .geom = hs.items[j], .role = .start } } },
    } } });
    return .{ .rect = .{ .left = left, .right = right, .top = top, .bottom = bottom } };
}

/// The cells of the array `refs` names, as the sketch now has them.
pub fn cells(s: *const Sketch, refs: Refs) Error!Cells {
    switch (refs) {
        .polar => |p| {
            const c = try s.point(.{ .geom = p.centre });
            const e0 = try s.point(.{ .geom = p.first, .role = .end });
            const e1 = try s.point(.{ .geom = p.second, .role = .end });
            const t0 = std.math.atan2(e0.y - c.y, e0.x - c.x);
            const t1 = std.math.atan2(e1.y - c.y, e1.x - c.x);
            // Clockwise from the first to the second, in (0, 2π].
            var step = t0 - t1;
            while (step <= 1e-12) step += 2 * std.math.pi;
            while (step > 2 * std.math.pi) step -= 2 * std.math.pi;
            const r = @sqrt((e0.x - c.x) * (e0.x - c.x) + (e0.y - c.y) * (e0.y - c.y));
            return .{ .polar = .{ .c = c, .first = t0, .step = step, .r = r } };
        },
        .rect => |q| {
            const tl = try s.point(.{ .geom = q.left, .role = .start });
            const br = try s.point(.{ .geom = q.right, .role = .end });
            return .{ .rect = .{ .x0 = @min(tl.x, br.x), .x1 = @max(tl.x, br.x), .y0 = @min(tl.y, br.y), .y1 = @max(tl.y, br.y) } };
        },
    }
}

test "a polar array holds together as it is turned and sized" {
    const a = std.testing.allocator;
    var s = try Sketch.init(a);
    defer s.deinit(a);
    const refs = try addPolar(&s, a, .{ .x = 10, .y = 5 }, 20, std.math.pi / 2.0 + std.math.pi / 8.0, 2 * std.math.pi, 8, 2);
    _ = try s.solve(a);
    var cl = try cells(&s, refs);
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, cl.polar.step, 1e-6);
    try std.testing.expectApproxEqAbs(20, cl.polar.r, 1e-6);
    // The centre and the outer radius held (as the owner described: lock
    // the centre, fix the radius): a border's end dragged round turns it.
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = refs.polar.centre }, .at = .{ .x = 10, .y = 5 } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .radius = .{ .g = refs.polar.outer, .value = 20 } } });
    const t0 = std.math.pi / 2.0 + std.math.pi / 8.0;
    _ = try s.drag(a, a, .{ .geom = refs.polar.first, .role = .end }, at(.{ .x = 10, .y = 5 }, 20, t0 - 0.3));
    cl = try cells(&s, refs);
    try std.testing.expectApproxEqAbs(t0 - 0.3, cl.polar.first, 1e-4);
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, cl.polar.step, 1e-6);
    try std.testing.expectApproxEqAbs(20, cl.polar.r, 1e-6);
    try std.testing.expectApproxEqAbs(10, cl.polar.c.x, 1e-6);
}

test "a part polar array and a rectangular one" {
    const a = std.testing.allocator;
    var s = try Sketch.init(a);
    defer s.deinit(a);
    const p = try addPolar(&s, a, .{ .x = 0, .y = 0 }, 10, std.math.pi / 2.0, std.math.pi, 4, 3);
    const q = try addRect(&s, a, .{ .x0 = 20, .y0 = 0, .x1 = 50, .y1 = 20 }, 3, 2);
    const res = try s.solve(a);
    _ = res;
    const cp = try cells(&s, p);
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, cp.polar.step, 1e-6);
    const cq = try cells(&s, q);
    try std.testing.expectApproxEqAbs(30, cq.rect.x1 - cq.rect.x0, 1e-6);
    // A middle border dragged: the spacing stays equal, so the outline
    // grows or the drag is refused; the cells stay equal either way.
    _ = try s.drag(a, a, .{ .geom = q.rect.right, .role = .start }, .{ .x = 56, .y = 20 });
    const cq2 = try cells(&s, q);
    try std.testing.expect(cq2.rect.x1 > 50);
}
