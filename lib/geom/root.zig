//! Planar geometry: points, affine transforms, segments and contours.
//!
//! Units are whatever the caller works in: font units for glyph outlines,
//! mm once placed. Coordinates are f64; y points up.

const std = @import("std");

pub const spring = @import("spring.zig");
/// The nonzero region of overlapping polygons, as simple loops.
pub const fill = @import("fill.zig");
pub const boolean = @import("boolean.zig");
pub const earcut = @import("earcut.zig");
/// Outlines grown outward: a heavier weight.
pub const grow = @import("grow.zig");
pub const simplify = @import("simplify.zig");
/// Multi-channel signed distance fields: glyphs drawn at any size, grown.
pub const msdf = @import("msdf.zig");
/// A stroke font: text as polylines, turned and sized freely (annotations).
pub const strokefont = @import("strokefont.zig");
/// The shortest route between two directed ends, bending no more sharply
/// than a given radius (Dubins paths, with straight leads).
pub const dubins = @import("dubins.zig");

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
/// A rational quadratic Bézier: control points `p` with the middle one
/// weighted `w` (the ends weigh 1). With 0 < w < 1 it is an arc of an
/// ellipse, exactly; when its control polygon is isosceles it is an arc of
/// a circle, with w the cosine of half the angle it turns through (see
/// `arc`). An affine transform maps it to another conic of the same weight,
/// so arcs stay exact through any placement.
pub const Conic = struct {
    p: [3]Point,
    w: f64,

    pub fn at(c: Conic, t: f64) Point {
        const u = 1 - t;
        const b0 = u * u;
        const b1 = 2 * c.w * u * t;
        const b2 = t * t;
        const d = b0 + b1 + b2;
        return .{
            .x = (b0 * c.p[0].x + b1 * c.p[1].x + b2 * c.p[2].x) / d,
            .y = (b0 * c.p[0].y + b1 * c.p[1].y + b2 * c.p[2].y) / d,
        };
    }

    /// The area between the curve and its chord, as a share of the
    /// triangle of its control points: 2/3 for a parabola (w = 1). Exact,
    /// from the circular arc of the same weight (areas keep their ratios
    /// under affine maps).
    pub fn segmentRatio(w: f64) f64 {
        if (@abs(1 - w) < 1e-12) return 2.0 / 3.0;
        if (w < 1) {
            const s = @sqrt(1 - w * w);
            if (s < 1e-3) return w * (2.0 / 3.0 + s * s / 5);
            return w * (std.math.acos(w) - w * s) / (s * s * s);
        }
        const s = @sqrt(w * w - 1);
        if (s < 1e-3) return w * (2.0 / 3.0 - s * s / 5);
        return w * (w * s - std.math.acosh(w)) / (s * s * s);
    }

    /// Its ellipse (0 < w < 1): the centre and two conjugate semi-diameters,
    /// `a` to the curve's midpoint and `b` parallel to its chord, so the
    /// curve is centre + a cos φ + b sin φ for φ from -θ to θ, where
    /// cos θ = w (θ is `half`).
    pub fn ellipse(c: Conic) struct { centre: Point, a: Point, b: Point, half: f64 } {
        const m: Point = .{ .x = (c.p[0].x + c.p[2].x) / 2, .y = (c.p[0].y + c.p[2].y) / 2 };
        const k = c.w * c.w / (1 - c.w * c.w);
        const centre: Point = .{ .x = m.x + (m.x - c.p[1].x) * k, .y = m.y + (m.y - c.p[1].y) * k };
        const mid = c.at(0.5);
        const s = @sqrt(1 - c.w * c.w);
        return .{
            .centre = centre,
            .a = .{ .x = mid.x - centre.x, .y = mid.y - centre.y },
            .b = .{ .x = (c.p[2].x - c.p[0].x) / (2 * s), .y = (c.p[2].y - c.p[0].y) / (2 * s) },
            .half = std.math.acos(c.w),
        };
    }
};

/// An arc of the circle about `centre` of radius `r`, from angle `from`
/// turning through `sweep` (radians, counter-clockwise when positive), as
/// exact conics, each turning through at most a quarter turn: up to four,
/// written to `out`. A full turn is four.
pub fn arc(centre: Point, r: f64, from: f64, sweep: f64, out: *[4]Segment) []Segment {
    const turn = @min(@abs(sweep), 2 * std.math.pi);
    const n: usize = @max(1, @min(4, @as(usize, @intFromFloat(@ceil(turn / (std.math.pi / 2.0) - 1e-9)))));
    const step = std.math.sign(sweep) * turn / @as(f64, @floatFromInt(n));
    const half = step / 2;
    const w = @cos(half);
    for (0..n) |k| {
        const a0 = from + step * @as(f64, @floatFromInt(k));
        const a1 = a0 + step;
        const am = a0 + half;
        const p0: Point = .{ .x = centre.x + r * @cos(a0), .y = centre.y + r * @sin(a0) };
        const p2: Point = .{ .x = centre.x + r * @cos(a1), .y = centre.y + r * @sin(a1) };
        // The tangents' meeting point, out along the middle direction.
        const d = r / w;
        const p1: Point = .{ .x = centre.x + d * @cos(am), .y = centre.y + d * @sin(am) };
        out[k] = .{ .conic = .{ .p = .{ p0, p1, p2 }, .w = w } };
    }
    return out[0..n];
}

pub const Segment = union(enum) {
    line: [2]Point,
    quad: [3]Point,
    cubic: [4]Point,
    conic: Conic,

    pub fn start(s: Segment) Point {
        return switch (s) {
            .conic => |c| c.p[0],
            inline else => |p| p[0],
        };
    }

    pub fn end(s: Segment) Point {
        return switch (s) {
            .conic => |c| c.p[2],
            inline else => |p| p[p.len - 1],
        };
    }

    /// The point at parameter `t` (0 at its start, 1 at its end).
    pub fn at(s: Segment, t: f64) Point {
        const u = 1 - t;
        return switch (s) {
            .line => |p| .{ .x = u * p[0].x + t * p[1].x, .y = u * p[0].y + t * p[1].y },
            .quad => |p| quadAt(p, t),
            .cubic => |p| cubicAt(p, t),
            .conic => |c| c.at(t),
        };
    }

    /// Its control points (for a conic, without the weight).
    pub fn points(s: *const Segment) []const Point {
        return switch (s.*) {
            .conic => |*c| &c.p,
            inline else => |*p| p,
        };
    }

    /// The same curve, travelled the other way.
    pub fn reversed(s: Segment) Segment {
        return switch (s) {
            .line => |p| .{ .line = .{ p[1], p[0] } },
            .quad => |p| .{ .quad = .{ p[2], p[1], p[0] } },
            .cubic => |p| .{ .cubic = .{ p[3], p[2], p[1], p[0] } },
            .conic => |c| .{ .conic = .{ .p = .{ c.p[2], c.p[1], c.p[0] }, .w = c.w } },
        };
    }

    pub fn transformed(s: Segment, m: Affine) Segment {
        return switch (s) {
            .conic => |c| .{ .conic = .{ .p = .{ m.apply(c.p[0]), m.apply(c.p[1]), m.apply(c.p[2]) }, .w = c.w } },
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
            // The chord's share, and the area between curve and chord: a
            // fixed share of the control triangle's (signed).
            .conic => |c| blk: {
                const p = c.p;
                const tri = (p[0].cross(p[1]) + p[1].cross(p[2]) + p[2].cross(p[0])) / 2;
                break :blk p[0].cross(p[2]) / 2 + Conic.segmentRatio(c.w) * tri;
            },
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
            .conic => |c| {
                inline for (.{ "x", "y" }) |axis| {
                    // x(t) = N(t) / D(t); its extremes are where
                    // N'D - ND' = 0, a quadratic (the cubic terms cancel).
                    const a = @field(c.p[0], axis);
                    const m = @field(c.p[1], axis);
                    const e = @field(c.p[2], axis);
                    const n0 = a;
                    const n1 = -2 * a + 2 * c.w * m;
                    const n2 = a - 2 * c.w * m + e;
                    const d0: f64 = 1;
                    const d1 = -2 + 2 * c.w;
                    const d2 = 2 - 2 * c.w;
                    const qa = n2 * d1 - n1 * d2;
                    const qb = 2 * (n2 * d0 - n0 * d2);
                    const qc = n1 * d0 - n0 * d1;
                    var roots: [2]f64 = undefined;
                    var n: usize = 0;
                    if (@abs(qa) < 1e-15 * (@abs(qb) + @abs(qc) + 1e-300)) {
                        if (qb != 0) {
                            roots[0] = -qc / qb;
                            n = 1;
                        }
                    } else {
                        const disc = qb * qb - 4 * qa * qc;
                        if (disc >= 0) {
                            const rt = @sqrt(disc);
                            roots[0] = (-qb + rt) / (2 * qa);
                            roots[1] = (-qb - rt) / (2 * qa);
                            n = 2;
                        }
                    }
                    for (roots[0..n]) |t| {
                        if (t > 0 and t < 1) b = b.addPoint(c.at(t));
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

test "arcs are exact conics: a circle's area and bounds, kept through a transform" {
    var buf: [4]Segment = undefined;
    const circle = arc(pt(3, -2), 5, 0, 2 * std.math.pi, &buf);
    try testing.expectEqual(@as(usize, 4), circle.len);
    const c: Contour = .{ .segments = circle };
    try testing.expect(c.isClosed() or @abs(circle[3].end().x - circle[0].start().x) < 1e-12);
    try testing.expectApproxEqAbs(std.math.pi * 25, c.signedArea(), 1e-9);
    const b = c.bounds();
    try testing.expectApproxEqAbs(@as(f64, -2), b.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8), b.x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), b.y1, 1e-9);
    // Every point on it is on the circle, not near it.
    for (circle) |s| for (0..11) |k| {
        const q = s.at(@as(f64, @floatFromInt(k)) / 10);
        try testing.expectApproxEqAbs(@as(f64, 5), @sqrt((q.x - 3) * (q.x - 3) + (q.y + 2) * (q.y + 2)), 1e-12);
    };
    // Stretched to an ellipse, its area scales with the map.
    const m: Affine = .{ .a = 2, .d = 0.5, .b = 0, .c = 0 };
    var area: f64 = 0;
    for (circle) |s| area += s.transformed(m).areaTerm();
    try testing.expectApproxEqAbs(std.math.pi * 25, area, 1e-9);
    // A half circle turned clockwise: two pieces, negative area.
    var half_buf: [4]Segment = undefined;
    const half = arc(pt(0, 0), 1, std.math.pi, -std.math.pi, &half_buf);
    try testing.expectEqual(@as(usize, 2), half.len);
    var ha: f64 = 0;
    for (half) |s| ha += s.areaTerm();
    ha += (Segment{ .line = .{ half[1].end(), half[0].start() } }).areaTerm();
    try testing.expectApproxEqAbs(-std.math.pi / 2.0, ha, 1e-12);
    // The ellipse of a quarter: its centre and radii.
    const e = circle[0].conic.ellipse();
    try testing.expectApproxEqAbs(@as(f64, 3), e.centre.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -2), e.centre.y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), @sqrt(e.a.x * e.a.x + e.a.y * e.a.y), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), @sqrt(e.b.x * e.b.x + e.b.y * e.b.y), 1e-12);
}

test "affine composition applies left to right" {
    const m = Affine.scale(2).then(Affine.translate(10, 0));
    const p = m.apply(pt(1, 1));
    try testing.expectEqual(@as(f64, 12), p.x);
    try testing.expectEqual(@as(f64, 2), p.y);
    try testing.expect(!m.mirrors());
    try testing.expect((Affine{ .a = -1 }).mirrors());
}

test {
    _ = spring;
    _ = fill;
    _ = boolean;
    _ = earcut;
    _ = grow;
    _ = simplify;
    _ = msdf;
    _ = strokefont;
}
