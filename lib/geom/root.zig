//! Planar geometry: points, affine transforms, segments and contours.
//!
//! Units are whatever the caller works in: font units for glyph outlines,
//! mm once placed. Coordinates are f64; y points up.

const std = @import("std");

pub const Point = struct {
    x: f64,
    y: f64,

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// The z component of the cross product a x b.
    pub fn cross(a: Point, b: Point) f64 {
        return a.x * b.y - a.y * b.x;
    }
};

/// x' = a*x + c*y + e, y' = b*x + d*y + f.
pub const Affine = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Affine = .{};

    pub fn scale(s: f64) Affine {
        return .{ .a = s, .d = s };
    }

    pub fn translate(x: f64, y: f64) Affine {
        return .{ .e = x, .f = y };
    }

    pub fn apply(m: Affine, p: Point) Point {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }

    /// `m` first, then `n`.
    pub fn then(m: Affine, n: Affine) Affine {
        return .{
            .a = n.a * m.a + n.c * m.b,
            .b = n.b * m.a + n.d * m.b,
            .c = n.a * m.c + n.c * m.d,
            .d = n.b * m.c + n.d * m.d,
            .e = n.a * m.e + n.c * m.f + n.e,
            .f = n.b * m.e + n.d * m.f + n.f,
        };
    }

    /// True when the transform reverses orientation (a mirror).
    pub fn mirrors(m: Affine) bool {
        return m.a * m.d - m.b * m.c < 0;
    }
};

/// An axis-aligned box. `empty` has no extent and unions as nothing.
pub const Box = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    pub const empty: Box = .{ .x0 = std.math.inf(f64), .y0 = std.math.inf(f64), .x1 = -std.math.inf(f64), .y1 = -std.math.inf(f64) };

    pub fn isEmpty(b: Box) bool {
        return b.x0 > b.x1 or b.y0 > b.y1;
    }

    pub fn addPoint(b: Box, p: Point) Box {
        return .{ .x0 = @min(b.x0, p.x), .y0 = @min(b.y0, p.y), .x1 = @max(b.x1, p.x), .y1 = @max(b.y1, p.y) };
    }

    pub fn join(a: Box, b: Box) Box {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    pub fn width(b: Box) f64 {
        return if (b.isEmpty()) 0 else b.x1 - b.x0;
    }

    pub fn height(b: Box) f64 {
        return if (b.isEmpty()) 0 else b.y1 - b.y0;
    }
};

/// One segment of a contour. Quadratics stay native; nothing is raised to a
/// cubic or flattened.
pub const Segment = union(enum) {
    line: [2]Point,
    quad: [3]Point,
    cubic: [4]Point,

    pub fn start(s: Segment) Point {
        return switch (s) {
            inline else => |p| p[0],
        };
    }

    pub fn end(s: Segment) Point {
        return switch (s) {
            inline else => |p| p[p.len - 1],
        };
    }

    pub fn transformed(s: Segment, m: Affine) Segment {
        return switch (s) {
            inline else => |p, tag| blk: {
                var q = p;
                for (&q) |*v| v.* = m.apply(v.*);
                break :blk @unionInit(Segment, @tagName(tag), q);
            },
        };
    }

    /// This segment's share of a closed contour's signed area (Green's
    /// theorem, closed form): positive for counter-clockwise travel.
    pub fn areaTerm(s: Segment) f64 {
        return switch (s) {
            .line => |p| p[0].cross(p[1]) / 2,
            .quad => |p| (p[0].cross(p[1]) + p[1].cross(p[2])) / 3 + p[0].cross(p[2]) / 6,
            .cubic => |p| (6 * p[0].cross(p[1]) + 3 * p[0].cross(p[2]) + p[0].cross(p[3]) +
                3 * p[1].cross(p[2]) + 3 * p[1].cross(p[3]) + 6 * p[2].cross(p[3])) / 20,
        };
    }

    /// The exact bounds of the curve (not of its control points).
    pub fn bounds(s: Segment) Box {
        var b = Box.empty.addPoint(s.start()).addPoint(s.end());
        switch (s) {
            .line => {},
            .quad => |p| {
                inline for (.{ "x", "y" }) |axis| {
                    const a = @field(p[0], axis);
                    const c = @field(p[1], axis);
                    const e = @field(p[2], axis);
                    const den = a - 2 * c + e;
                    if (den != 0) {
                        const t = (a - c) / den;
                        if (t > 0 and t < 1) b = b.addPoint(quadAt(p, t));
                    }
                }
            },
            .cubic => |p| {
                inline for (.{ "x", "y" }) |axis| {
                    // Roots of the derivative: qa*t^2 + qb*t + qc = 0.
                    const p0 = @field(p[0], axis);
                    const p1 = @field(p[1], axis);
                    const p2 = @field(p[2], axis);
                    const p3 = @field(p[3], axis);
                    const qa = -p0 + 3 * p1 - 3 * p2 + p3;
                    const qb = 2 * (p0 - 2 * p1 + p2);
                    const qc = p1 - p0;
                    var roots: [2]f64 = undefined;
                    var n: usize = 0;
                    if (qa == 0) {
                        if (qb != 0) {
                            roots[0] = -qc / qb;
                            n = 1;
                        }
                    } else {
                        const disc = qb * qb - 4 * qa * qc;
                        if (disc >= 0) {
                            const r = @sqrt(disc);
                            roots[0] = (-qb + r) / (2 * qa);
                            roots[1] = (-qb - r) / (2 * qa);
                            n = 2;
                        }
                    }
                    for (roots[0..n]) |t| {
                        if (t > 0 and t < 1) b = b.addPoint(cubicAt(p, t));
                    }
                }
            },
        }
        return b;
    }
};

fn quadAt(p: [3]Point, t: f64) Point {
    const u = 1 - t;
    return .{
        .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x,
        .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y,
    };
}

fn cubicAt(p: [4]Point, t: f64) Point {
    const u = 1 - t;
    return .{
        .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
        .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
    };
}

/// A closed contour: each segment starts where the previous one ends, and
/// the last ends exactly on the first's start.
pub const Contour = struct {
    segments: []const Segment,

    pub fn signedArea(c: Contour) f64 {
        var a: f64 = 0;
        for (c.segments) |s| a += s.areaTerm();
        return a;
    }

    pub fn bounds(c: Contour) Box {
        var b = Box.empty;
        for (c.segments) |s| b = b.join(s.bounds());
        return b;
    }

    pub fn isClosed(c: Contour) bool {
        if (c.segments.len == 0) return false;
        for (c.segments[1..], 0..) |s, i| {
            if (!s.start().eql(c.segments[i].end())) return false;
        }
        return c.segments[c.segments.len - 1].end().eql(c.segments[0].start());
    }
};

/// A set of contours filled together under the nonzero rule: one glyph, rule
/// or drawn mark.
pub const Outline = struct {
    contours: []const Contour,

    pub const blank: Outline = .{ .contours = &.{} };

    /// The signed area under the nonzero rule, valid while contours do not
    /// overlap (holes wound opposite to their outer contour).
    pub fn signedArea(o: Outline) f64 {
        var a: f64 = 0;
        for (o.contours) |c| a += c.signedArea();
        return a;
    }

    pub fn bounds(o: Outline) Box {
        var b = Box.empty;
        for (o.contours) |c| b = b.join(c.bounds());
        return b;
    }

    /// A copy with every point transformed, allocated from `gpa`.
    pub fn transformed(o: Outline, gpa: std.mem.Allocator, m: Affine) !Outline {
        const contours = try gpa.alloc(Contour, o.contours.len);
        for (o.contours, contours) |src, *dst| {
            const segs = try gpa.alloc(Segment, src.segments.len);
            for (src.segments, segs) |s, *d| d.* = s.transformed(m);
            dst.* = .{ .segments = segs };
        }
        return .{ .contours = contours };
    }
};

const testing = std.testing;

fn pt(x: f64, y: f64) Point {
    return .{ .x = x, .y = y };
}

test "areas of lines, quadratics and cubics are exact" {
    // Unit square, counter-clockwise.
    const square = [_]Segment{
        .{ .line = .{ pt(0, 0), pt(1, 0) } },
        .{ .line = .{ pt(1, 0), pt(1, 1) } },
        .{ .line = .{ pt(1, 1), pt(0, 1) } },
        .{ .line = .{ pt(0, 1), pt(0, 0) } },
    };
    try testing.expectEqual(@as(f64, 1), (Contour{ .segments = &square }).signedArea());

    // Arch over a base of 600 with control 600 high: 2/3 * 600 * 300.
    const arch_q = [_]Segment{
        .{ .line = .{ pt(50, 0), pt(650, 0) } },
        .{ .quad = .{ pt(650, 0), pt(350, 600), pt(50, 0) } },
    };
    try testing.expectEqual(@as(f64, 120000), (Contour{ .segments = &arch_q }).signedArea());

    // The same arch raised to a cubic gives the same area.
    const arch_c = [_]Segment{
        .{ .line = .{ pt(50, 0), pt(650, 0) } },
        .{ .cubic = .{ pt(650, 0), pt(450, 400), pt(250, 400), pt(50, 0) } },
    };
    try testing.expectEqual(@as(f64, 120000), (Contour{ .segments = &arch_c }).signedArea());
}

test "curve bounds use the curve's extremes, not its control points" {
    const q: Segment = .{ .quad = .{ pt(650, 0), pt(350, 600), pt(50, 0) } };
    const b = q.bounds();
    try testing.expectEqual(@as(f64, 300), b.y1); // apex at half the control height
    try testing.expectEqual(@as(f64, 50), b.x0);
    try testing.expectEqual(@as(f64, 650), b.x1);

    const c: Segment = .{ .cubic = .{ pt(650, 0), pt(450, 400), pt(250, 400), pt(50, 0) } };
    try testing.expectApproxEqAbs(@as(f64, 300), c.bounds().y1, 1e-9);
}

test "affine composition applies left to right" {
    const m = Affine.scale(2).then(Affine.translate(10, 0));
    const p = m.apply(pt(1, 1));
    try testing.expectEqual(@as(f64, 12), p.x);
    try testing.expectEqual(@as(f64, 2), p.y);
    try testing.expect(!m.mirrors());
    try testing.expect((Affine{ .a = -1 }).mirrors());
}
