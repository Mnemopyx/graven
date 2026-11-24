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

    pub fn eql(a: Placement, b: Placement) bool {
        return a.offset == b.offset and a.text == b.text and a.outside == b.outside and a.hidden == b.hidden;
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
    var ext: [2]?[2]Point = .{ null, null };
    for ([_]Point{ m.p0, m.p1 }, [_]Point{ q0, q1 }, 0..) |p, q, i| {
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

const testing = std.testing;

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
