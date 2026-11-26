//! Dimensions as drawn, after drafting practice (ASME Y14.5, ISO 129):
//! a dimension line parallel to what it measures, ending in arrowheads at
//! extension lines that carry the measured features out to it. Driving
//! constraints and reference dimensions draw alike (a reference value in
//! parentheses is the caller's text).
//!
//! Where a dimension is drawn is its own (`Placement`): saved with it, so a
//! document reopens with each dimension where it was left (the owner,
//! 2026-11-24). `linear` turns the measured points and the placement into
//! the geometry to stroke, in the caller's units (mm); the sizes of
//! arrowheads, gaps and text (`Style`) are given in the same units, so a
//! caller drawing at a fixed size on screen divides its pixels by the zoom.

const std = @import("std");
const geom = @import("graven_geom");

const Point = geom.Point;

/// Where a dimension is drawn, relative to what it measures (so it moves
/// with it). Saved with the dimension.
pub const Placement = struct {
    /// How far the dimension line sits from the middle of the measured
    /// points, mm, along the measure's normal (`Measure.normal`). 0: through
    /// their middle (on the body, where the features are their own
    /// extension lines).
    offset: f64 = 0,
    /// Where the value sits along the line, mm from its middle (0: centred).
    text: f64 = 0,
    /// Arrows outside the extension lines, pointing in, as the user put
    /// them (they go outside by themselves when they do not fit).
    outside: bool = false,
    /// Not drawn.
    hidden: bool = false,
    /// A radius's or diameter's line: its direction from the centre,
    /// radians anticlockwise from +x (`radial`); null for its default (a
    /// circle's 45°, an arc's middle). For them `text` is the value's
    /// distance from the centre along it (0: its default place).
    angle: ?f64 = null,

    pub fn eql(a: Placement, b: Placement) bool {
        return a.offset == b.offset and a.text == b.text and a.outside == b.outside and a.hidden == b.hidden and std.meta.eql(a.angle, b.angle);
    }
};

/// What a linear dimension measures: the distance from `p0` to `p1` along
/// `dir` (a unit vector: the x axis for a horizontal distance, the line
/// between them for an aligned one). `normal` (a unit vector across `dir`)
/// is the side a positive offset moves the dimension line to.
pub const Measure = struct {
    p0: Point,
    p1: Point,
    dir: Point,
    normal: Point,
    /// A feature that is an edge rather than a point: how far it runs
    /// along `normal` (from, to; infinite for a line without end), its
    /// point then its middle. Its extension line starts at its end nearest
    /// the dimension line, and none is drawn when the line crosses it.
    extent: [2]?[2]f64 = .{ null, null },
};

/// Sizes, in the caller's units.
pub const Style = struct {
    /// The visible gap between a feature and its extension line's start.
    gap: f64,
    /// How far an extension line runs past the dimension line.
    overshoot: f64,
    /// An arrowhead's length and half its width (about 3:1).
    arrow: f64,
    arrow_half: f64,
    /// The value's width as drawn, and the room it wants on each side.
    text_width: f64,
    text_clear: f64,

    /// Screen sizes (pixels) at `ppm` pixels per unit: the drafting sizes
    /// Graven draws with.
    pub fn screen(ppm: f64, text_width_px: f64) Style {
        return .{
            .gap = 3 / ppm,
            .overshoot = 4 / ppm,
            .arrow = 8 / ppm,
            .arrow_half = 2.7 / ppm,
            .text_width = text_width_px / ppm,
            .text_clear = 4 / ppm,
        };
    }
};

pub const Arrow = struct {
    tip: Point,
    /// The two back corners.
    wings: [2]Point,
};

/// A dimension's geometry to stroke.
pub const Drawn = struct {
    /// Extension lines, from near each feature to just past the dimension
    /// line; null where the dimension line meets the feature itself.
    ext: [2]?[2]Point,
    /// The dimension line, end to end (past the arrows when they are
    /// outside).
    line: [2]Point,
    /// Where the dimension line meets each extension line.
    ends: [2]Point,
    /// None where the measured points coincide (an alignment).
    arrows: ?[2]Arrow,
    /// The middle of the value, on the line, and its reading direction
    /// (upright: rightwards, or upwards when vertical, y up).
    text_at: Point,
    text_dir: Point,
    outside: bool,
    /// The measured points coincide along `dir`.
    aligned: bool,
};

fn add(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

fn sub(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn mul(a: Point, k: f64) Point {
    return .{ .x = a.x * k, .y = a.y * k };
}

fn dot(a: Point, b: Point) f64 {
    return a.x * b.x + a.y * b.y;
}

fn arrowAt(tip: Point, pointing: Point, normal: Point, st: Style) Arrow {
    const back = sub(tip, mul(pointing, st.arrow));
    return .{ .tip = tip, .wings = .{ add(back, mul(normal, st.arrow_half)), sub(back, mul(normal, st.arrow_half)) } };
}

/// A linear dimension's drafting geometry.
pub fn linear(m: Measure, place: Placement, st: Style) Drawn {
    const mid = mul(add(m.p0, m.p1), 0.5);
    // The dimension line's place across, and where it meets each feature's
    // extension.
    const c = dot(mid, m.normal) + place.offset;
    const q0 = add(m.p0, mul(m.normal, c - dot(m.p0, m.normal)));
    const q1 = add(m.p1, mul(m.normal, c - dot(m.p1, m.normal)));
    // An edge's nearest end to the line: where its extension line starts.
    var feat: [2]Point = .{ m.p0, m.p1 };
    for (&feat, m.extent) |*p, e| if (e) |r| {
        const at = std.math.clamp(c, @min(r[0], r[1]), @max(r[0], r[1]));
        p.* = add(p.*, mul(m.normal, at - dot(p.*, m.normal)));
    };
    var ext: [2]?[2]Point = .{ null, null };
    for (feat, [_]Point{ q0, q1 }, 0..) |p, q, i| {
        const d = c - dot(p, m.normal);
        if (@abs(d) <= st.gap) continue;
        const s: f64 = if (d > 0) 1 else -1;
        ext[i] = .{ add(p, mul(m.normal, s * st.gap)), add(q, mul(m.normal, s * st.overshoot)) };
    }
    const along = dot(sub(q1, q0), m.dir);
    const span = @abs(along);
    // The way from end 0 to end 1.
    const u: Point = if (along >= 0) m.dir else mul(m.dir, -1);
    // Upright: rightwards, or upwards when vertical.
    const text_dir: Point = if (m.dir.x > 1e-12 or (@abs(m.dir.x) <= 1e-12 and m.dir.y > 0)) m.dir else mul(m.dir, -1);
    const centre = mul(add(q0, q1), 0.5);
    const aligned = span < 1e-9;
    if (aligned) return .{ .ext = ext, .line = .{ q0, q1 }, .ends = .{ q0, q1 }, .arrows = null, .text_at = add(centre, mul(text_dir, place.text)), .text_dir = text_dir, .outside = false, .aligned = true };
    const room_arrows = 2 * st.arrow + st.text_clear;
    const outside = place.outside or span < room_arrows;
    var text_at = add(centre, mul(text_dir, place.text));
    // A value that does not fit between the arrows, not placed by hand:
    // past end 1, clear of its arrow.
    if (place.text == 0 and span < room_arrows + st.text_width + 2 * st.text_clear) {
        const past = (if (outside) 2 * st.arrow else 0) + st.text_clear + st.text_width / 2;
        text_at = add(q1, mul(u, past));
    }
    if (outside) {
        const stub = 2 * st.arrow;
        return .{
            .ext = ext,
            .line = .{ sub(q0, mul(u, stub)), add(q1, mul(u, stub)) },
            .ends = .{ q0, q1 },
            .arrows = .{ arrowAt(q0, u, m.normal, st), arrowAt(q1, mul(u, -1), m.normal, st) },
            .text_at = text_at,
            .text_dir = text_dir,
            .outside = true,
            .aligned = false,
        };
    }
    return .{
        .ext = ext,
        .line = .{ q0, q1 },
        .ends = .{ q0, q1 },
        .arrows = .{ arrowAt(q0, mul(u, -1), m.normal, st), arrowAt(q1, u, m.normal, st) },
        .text_at = text_at,
        .text_dir = text_dir,
        .outside = false,
        .aligned = false,
    };
}

/// The placement that puts a dimension's line through `at` (a drag of the
/// line): its offset there, the rest kept.
pub fn offsetThrough(m: Measure, place: Placement, at: Point) Placement {
    var p = place;
    const mid = mul(add(m.p0, m.p1), 0.5);
    p.offset = dot(sub(at, mid), m.normal);
    return p;
}

/// The placement that puts a dimension's value at `at` along its line (a
/// drag of the value; the line follows across).
pub fn textAt(m: Measure, place: Placement, at: Point) Placement {
    var p = offsetThrough(m, place, at);
    const mid = mul(add(m.p0, m.p1), 0.5);
    const text_dir: Point = if (m.dir.x > 1e-12 or (@abs(m.dir.x) <= 1e-12 and m.dir.y > 0)) m.dir else mul(m.dir, -1);
    p.text = dot(sub(at, mid), text_dir);
    return p;
}

/// `place` kept within `reach` (mm) of what it measures, so a dimension
/// reads as belonging to its features (the owner, 2026-11-24): its line no
/// further than `reach` beyond the farther feature across, its value no
/// further than `reach` beyond either end along.
pub fn withinReach(m: Measure, place: Placement, reach: f64) Placement {
    var p = place;
    const mid = mul(add(m.p0, m.p1), 0.5);
    const n0 = dot(sub(m.p0, mid), m.normal);
    const n1 = dot(sub(m.p1, mid), m.normal);
    p.offset = std.math.clamp(p.offset, @min(n0, n1) - reach, @max(n0, n1) + reach);
    const half = @abs(dot(sub(m.p1, m.p0), m.dir)) / 2;
    p.text = std.math.clamp(p.text, -(half + reach), half + reach);
    return p;
}

/// What a radius or diameter measures: a circle (or an arc's circle).
pub const Round = struct {
    centre: Point,
    r: f64,
    /// Across the whole circle, through the centre (arrows at both ends);
    /// otherwise from the centre to the curve (one arrow).
    diameter: bool,
    /// The line's direction when its placement has none (radians).
    default_angle: f64,
    /// An arc's: where it starts and how far it sweeps anticlockwise
    /// (radians). A diameter whose far end misses the arc ends a little
    /// past the centre, with no arrow there (ISO 129-1).
    sweep: ?[2]f64 = null,

    /// Whether the curve passes the direction `a` (radians) from the centre.
    pub fn covers(m: Round, a: f64) bool {
        const sw = m.sweep orelse return true;
        const tau = 2 * std.math.pi;
        const d = @mod(a - sw[0], tau);
        return d <= sw[1] + 1e-9 or d >= tau - 1e-9;
    }
};

/// A radius's or diameter's geometry to stroke.
pub const RoundDrawn = struct {
    /// The dimension line, end to end: through the centre for a diameter,
    /// from it for a radius; past the curve as a leader under a value
    /// placed outside, and past the arrows when they are outside.
    line: [2]Point,
    /// Where the line meets the curve: end 1 on the line's direction,
    /// end 0 opposite (a diameter) or the centre (a radius).
    ends: [2]Point,
    /// An arrowhead on the curve at each end; a radius has none at the
    /// centre.
    arrows: [2]?Arrow,
    text_at: Point,
    text_dir: Point,
    /// The line's direction (unit), from the centre.
    dir: Point,
    outside: bool,
};

fn upright(u: Point) Point {
    return if (u.x > 1e-12 or (@abs(u.x) <= 1e-12 and u.y > 0)) u else mul(u, -1);
}

/// A radius or diameter after drafting practice (ISO 129-1): its line
/// through (or from) the centre at the placed angle, ending in arrowheads
/// on the curve; the value along it, upright, centred on the line when it
/// fits, else past the curve on the line carried out as a leader. Arrows
/// go outside, pointing in, when there is no room for them inside (or the
/// user put them there).
pub fn radial(m: Round, place: Placement, st: Style) RoundDrawn {
    const a = place.angle orelse m.default_angle;
    const u: Point = .{ .x = @cos(a), .y = @sin(a) };
    const r = @abs(m.r);
    const e1 = add(m.centre, mul(u, r));
    // A diameter across an arc that does not reach round to its other end:
    // one arrow, the line a little past the centre.
    const half = m.diameter and !m.covers(a + std.math.pi);
    const both = m.diameter and !half;
    const e0 = if (m.diameter) sub(m.centre, mul(u, r)) else m.centre;
    const span = if (both) 2 * r else r;
    const heads: f64 = if (both) 2 else 1;
    const room_arrows = heads * st.arrow + st.text_clear;
    const outside = place.outside or span < room_arrows;
    // Where the value sits, from the centre along u.
    var t = place.text;
    if (t == 0) {
        const fits = !outside and span >= room_arrows + st.text_width + 2 * st.text_clear;
        t = if (fits) (if (both) 0 else r / 2) else r + (if (outside) 2 * st.arrow else 0) + st.text_clear + st.text_width / 2;
    }
    const text_dir = upright(u);
    // The line runs on under a value placed past the curve, and past
    // outside arrows by a stub.
    var far = r;
    if (outside) far = r + 2 * st.arrow;
    if (t + st.text_width / 2 > far) far = t + st.text_width / 2;
    var near: f64 = if (both) -r else if (half) -@min(r / 2, 4 * st.arrow) else 0;
    if (both and outside) near = -r - 2 * st.arrow;
    if (both and t - st.text_width / 2 < near) near = t - st.text_width / 2;
    const nrm: Point = .{ .x = -u.y, .y = u.x };
    const arrows: [2]?Arrow = if (outside)
        .{ if (both) arrowAt(e0, u, nrm, st) else null, arrowAt(e1, mul(u, -1), nrm, st) }
    else
        .{ if (both) arrowAt(e0, mul(u, -1), nrm, st) else null, arrowAt(e1, u, nrm, st) };
    return .{
        .line = .{ add(m.centre, mul(u, near)), add(m.centre, mul(u, far)) },
        .ends = .{ e0, e1 },
        .arrows = arrows,
        .text_at = add(m.centre, mul(u, t)),
        .text_dir = text_dir,
        .dir = u,
        .outside = outside,
    };
}

/// The placement that puts a radius's or diameter's value at `at` (a drag
/// of it): the line turned to point there, the value that far out.
pub fn radialTextAt(m: Round, place: Placement, at: Point) Placement {
    var p = place;
    const v = sub(at, m.centre);
    const d = @sqrt(dot(v, v));
    if (d < 1e-9) return p;
    p.angle = std.math.atan2(v.y, v.x);
    p.text = d;
    return p;
}

/// `place` with a radius's or diameter's value no further than `reach`
/// (mm) beyond its curve.
pub fn radialWithinReach(m: Round, place: Placement, reach: f64) Placement {
    var p = place;
    p.text = @min(p.text, @abs(m.r) + reach);
    return p;
}

const testing = std.testing;

test "within reach: the line and the value kept near the features" {
    const m: Measure = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 40, .y = 10 }, .dir = .{ .x = 1, .y = 0 }, .normal = .{ .x = 0, .y = 1 } };
    // Mid (20, 5); features at -5 and +5 across, 20 each way along.
    const far = withinReach(m, .{ .offset = 100, .text = -100 }, 8);
    try testing.expectEqual(@as(f64, 13), far.offset);
    try testing.expectEqual(@as(f64, -28), far.text);
    const below = withinReach(m, .{ .offset = -100, .text = 3 }, 8);
    try testing.expectEqual(@as(f64, -13), below.offset);
    try testing.expectEqual(@as(f64, 3), below.text);
}

const test_style: Style = .{ .gap = 1, .overshoot = 2, .arrow = 3, .arrow_half = 1, .text_width = 10, .text_clear = 1 };

test "a dimension on the body: no extension lines, arrows inside" {
    // 0 to 40 along x, both at y 0.
    const m: Measure = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 40, .y = 0 }, .dir = .{ .x = 1, .y = 0 }, .normal = .{ .x = 0, .y = 1 } };
    const d = linear(m, .{}, test_style);
    try testing.expect(d.ext[0] == null and d.ext[1] == null);
    try testing.expect(!d.outside);
    const a = d.arrows.?;
    try testing.expectEqual(@as(f64, 0), a[0].tip.x);
    try testing.expectEqual(@as(f64, 3), a[0].wings[0].x);
    try testing.expectEqual(@as(f64, 37), a[1].wings[0].x);
    try testing.expectEqual(@as(f64, 20), d.text_at.x);
}

test "moved off the body: extension lines from a gap to past the line" {
    // Points at heights 0 and 10; the line 25 above their middle (5): at 30.
    const m: Measure = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 40, .y = 10 }, .dir = .{ .x = 1, .y = 0 }, .normal = .{ .x = 0, .y = 1 } };
    const d = linear(m, .{ .offset = 25 }, test_style);
    try testing.expectEqual(@as(f64, 30), d.line[0].y);
    const e0 = d.ext[0].?;
    try testing.expectEqual(@as(f64, 1), e0[0].y);
    try testing.expectEqual(@as(f64, 32), e0[1].y);
    try testing.expectEqual(@as(f64, 11), d.ext[1].?[0].y);
    // Dragging the line to 50 sets the offset that puts it there.
    const p = offsetThrough(m, .{ .offset = 25 }, .{ .x = 7, .y = 50 });
    try testing.expectEqual(@as(f64, 45), p.offset);
    // Below them instead: the extension lines run down.
    const below = linear(m, .{ .offset = -20 }, test_style);
    try testing.expectEqual(@as(f64, -1), below.ext[0].?[0].y);
    try testing.expectEqual(@as(f64, -17), below.ext[0].?[1].y);
}

test "too tight: arrows outside pointing in, the value past them" {
    const m: Measure = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 5 }, .dir = .{ .x = 0, .y = 1 }, .normal = .{ .x = -1, .y = 0 } };
    const d = linear(m, .{}, test_style);
    try testing.expect(d.outside);
    const a = d.arrows.?;
    // The arrow at end 0 points up (in), its back below it.
    try testing.expectEqual(@as(f64, -3), a[0].wings[0].y);
    try testing.expectEqual(@as(f64, -6), d.line[0].y);
    try testing.expectEqual(@as(f64, 11), d.line[1].y);
    // Upright: reads upwards; the value past end 1.
    try testing.expectEqual(@as(f64, 1), d.text_dir.y);
    try testing.expectEqual(@as(f64, 5 + 6 + 1 + 5), d.text_at.y);
}

test "edges: the extension line from the nearer end, none where the line crosses" {
    // Two vertical edges, x 0 (y 0 to 20) and x 40 (y 5 to 15); the line
    // at y 30: from each top. At y 10: across both, no extension lines.
    const m: Measure = .{ .p0 = .{ .x = 0, .y = 10 }, .p1 = .{ .x = 40, .y = 10 }, .dir = .{ .x = 1, .y = 0 }, .normal = .{ .x = 0, .y = 1 }, .extent = .{ .{ 0, 20 }, .{ 5, 15 } } };
    const d = linear(m, .{ .offset = 20 }, test_style);
    try testing.expectEqual(@as(f64, 21), d.ext[0].?[0].y);
    try testing.expectEqual(@as(f64, 16), d.ext[1].?[0].y);
    const on = linear(m, .{}, test_style);
    try testing.expect(on.ext[0] == null and on.ext[1] == null);
    // An infinite line: never one.
    var inf = m;
    inf.extent[1] = .{ -std.math.inf(f64), std.math.inf(f64) };
    try testing.expect(linear(inf, .{ .offset = 50 }, test_style).ext[1] == null);
}

test "a diameter: through the centre, arrows on the circle pointing out" {
    const m: Round = .{ .centre = .{ .x = 0, .y = 0 }, .r = 20, .diameter = true, .default_angle = 0 };
    const d = radial(m, .{}, test_style);
    try testing.expect(!d.outside);
    try testing.expectEqual(@as(f64, -20), d.ends[0].x);
    try testing.expectEqual(@as(f64, 20), d.ends[1].x);
    // Arrow at end 1 points out (+x): its wings behind the tip.
    try testing.expectEqual(@as(f64, 17), d.arrows[1].?.wings[0].x);
    try testing.expectEqual(@as(f64, -17), d.arrows[0].?.wings[0].x);
    // The value centred on the line.
    try testing.expectEqual(@as(f64, 0), d.text_at.x);
    try testing.expectEqual(@as(f64, -20), d.line[0].x);
    try testing.expectEqual(@as(f64, 20), d.line[1].x);
}

test "a small diameter: arrows outside pointing in, the value past them" {
    const m: Round = .{ .centre = .{ .x = 0, .y = 0 }, .r = 2, .diameter = true, .default_angle = 0 };
    const d = radial(m, .{}, test_style);
    try testing.expect(d.outside);
    // At end 1 (x 2) pointing in: wings beyond it.
    try testing.expectEqual(@as(f64, 5), d.arrows[1].?.wings[0].x);
    try testing.expectEqual(@as(f64, -5), d.arrows[0].?.wings[0].x);
    try testing.expectEqual(@as(f64, 2 + 6 + 1 + 5), d.text_at.x);
    // The line runs under the value.
    try testing.expectEqual(@as(f64, 2 + 6 + 1 + 10), d.line[1].x);
}

test "a radius: one arrow, the value halfway; dragged, the line turns" {
    const m: Round = .{ .centre = .{ .x = 10, .y = 0 }, .r = 20, .diameter = false, .default_angle = 0 };
    const d = radial(m, .{}, test_style);
    try testing.expect(d.arrows[0] == null);
    try testing.expectEqual(@as(f64, 10), d.line[0].x);
    try testing.expectEqual(@as(f64, 20), d.text_at.x);
    // The value dragged up past the curve: the line points up, carried out
    // under it.
    const p = radialTextAt(m, .{}, .{ .x = 10, .y = 30 });
    try testing.expectApproxEqAbs(std.math.pi / 2.0, p.angle.?, 1e-12);
    try testing.expectEqual(@as(f64, 30), p.text);
    const up = radial(m, p, test_style);
    try testing.expectApproxEqAbs(@as(f64, 35), up.line[1].y, 1e-12);
    try testing.expectEqual(@as(f64, 25), radialWithinReach(m, p, 5).text);
}

test "an arc's diameter: one arrow, past the centre, when the far side has no arc" {
    // The upper half of a circle of radius 20.
    const m: Round = .{ .centre = .{ .x = 0, .y = 0 }, .r = 20, .diameter = true, .default_angle = std.math.pi / 2.0, .sweep = .{ 0, std.math.pi } };
    const d = radial(m, .{}, test_style);
    try testing.expect(d.arrows[0] == null and d.arrows[1] != null);
    try testing.expectApproxEqAbs(@as(f64, -10), d.line[0].y, 1e-12);
    // Turned to lie along its ends: both on the arc, both arrows.
    const across = radial(m, .{ .angle = 0 }, test_style);
    try testing.expect(across.arrows[0] != null);
}
