//! A stroke font: text as polylines, for dimensions and other annotations
//! drawn on the canvas. Every glyph is a few lines a pen would draw, so
//! text is turned through any angle, at any size, by transforming points,
//! and drawn as strokes each frame: nothing rasterised, nothing cached.
//!
//! The glyphs (strokefont_data.zig, from scripts/strokefont.py) are
//! Hershey's Roman Simplex for printable ASCII, with the symbols a
//! dimension needs drawn to match: ° ⌀ Ø ± × − ↔ ↕ ′ ″ · ∠. Anything else
//! is drawn as `?`. The Hershey fonts were originally created by Dr. A. V.
//! Hershey while working at the U. S. National Bureau of Standards.
//!
//! Text space: x along the line, y across it, the baseline at y = 0, the
//! cap height 1. `Place` maps it into the caller's space (canvas mm, y up;
//! or the screen, y down).

const std = @import("std");
const Point = @import("root.zig").Point;
const data = @import("strokefont_data.zig");

/// Hershey units: the cap line, the baseline, the cap height.
const cap_line = -12;
const base_line = 9;
const cap_units: f64 = base_line - cap_line;

/// The descender's depth and the x-height, in cap heights.
pub const descender: f64 = 7.0 / cap_units;
pub const x_height: f64 = 14.0 / cap_units;

/// Where and how text is drawn.
pub const Place = struct {
    /// The anchor's point, in the caller's space.
    at: Point,
    /// The cap height, in the caller's units.
    size: f64,
    /// The text's direction: radians from the space's +x toward its +y.
    angle: f64 = 0,
    /// Whether the space's y points down (the screen) rather than up (the
    /// canvas): the glyphs stand upright either way.
    y_down: bool = false,
    /// The anchor along the text: 0 its start, 0.5 its middle, 1 its end.
    align_x: f64 = 0,
    /// The anchor across it, in cap heights above the baseline: 0 the
    /// baseline, 0.5 the middle of the capitals, 1 the cap line.
    align_y: f64 = 0,

    /// The point at text-space `t` (cap heights; y up from the baseline),
    /// for text `len` cap heights long.
    fn map(p: Place, len: f64, t: Point) Point {
        const x = (t.x - p.align_x * len) * p.size;
        const y = (t.y - p.align_y) * p.size;
        const c = @cos(p.angle);
        const s = @sin(p.angle);
        // Up, across the text: turned a quarter from its direction, to
        // the side that is up in the space.
        const ux: f64, const uy: f64 = if (p.y_down) .{ s, -c } else .{ -s, c };
        return .{ .x = p.at.x + x * c + y * ux, .y = p.at.y + x * s + y * uy };
    }

    /// Text-space (cap heights, y up from the baseline, x from the start)
    /// of point `q` of the caller's space; the inverse of `map`.
    fn unmap(p: Place, len: f64, q: Point) Point {
        const c = @cos(p.angle);
        const s = @sin(p.angle);
        const ux: f64, const uy: f64 = if (p.y_down) .{ s, -c } else .{ -s, c };
        const dx = q.x - p.at.x;
        const dy = q.y - p.at.y;
        return .{ .x = (dx * c + dy * s) / p.size + p.align_x * len, .y = (dx * ux + dy * uy) / p.size + p.align_y };
    }
};

/// The glyph for codepoint `cp`: its encoded edges and points.
fn glyphOf(cp: u21) []const u8 {
    if (cp >= 0x20 and cp < 0x20 + data.ascii.len) return data.ascii[cp - 0x20];
    for (data.extra) |e| if (e.cp == cp) return e.g;
    return data.ascii['?' - 0x20];
}

fn unit(c: u8) f64 {
    return @floatFromInt(@as(i32, c) - 'R');
}

/// The codepoints of `text`; a byte that is not UTF-8 stands for itself.
const Codepoints = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *Codepoints) ?u21 {
        if (it.i >= it.s.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch 1;
        if (it.i + n <= it.s.len) if (std.unicode.utf8Decode(it.s[it.i .. it.i + n])) |cp| {
            it.i += n;
            return cp;
        } else |_| {};
        it.i += 1;
        return it.s[it.i - 1];
    }
};

/// How long `text` is, in cap heights.
pub fn width(text: []const u8) f64 {
    var w: f64 = 0;
    var it: Codepoints = .{ .s = text };
    while (it.next()) |cp| {
        const g = glyphOf(cp);
        w += unit(g[1]) - unit(g[0]);
    }
    return w / cap_units;
}

/// The longest polyline any glyph has.
pub const max_points = 64;

/// Calls `emit(ctx, points)` for each stroke of `text` as placed by `p`.
/// The points are only valid during the call.
pub fn strokes(text: []const u8, p: Place, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const Point) void) void {
    const w = width(text);
    var pen: f64 = 0; // Hershey units from the start
    var buf: [max_points]Point = undefined;
    var it: Codepoints = .{ .s = text };
    while (it.next()) |cp| {
        const g = glyphOf(cp);
        const left = unit(g[0]);
        var n: usize = 0;
        var k: usize = 2;
        while (k + 1 < g.len) : (k += 2) {
            if (g[k] == ' ' and g[k + 1] == 'R') {
                if (n > 1) emit(ctx, buf[0..n]);
                n = 0;
                continue;
            }
            if (n == buf.len) continue;
            const t: Point = .{ .x = (pen + unit(g[k]) - left) / cap_units, .y = (base_line - unit(g[k + 1])) / cap_units };
            buf[n] = p.map(w, t);
            n += 1;
        }
        if (n > 1) emit(ctx, buf[0..n]);
        pen += unit(g[1]) - left;
    }
}

/// Whether `q` (the caller's space) falls on `text` as placed by `p`: in
/// its box from the descender to the cap line, grown by `margin` (the
/// caller's units) all round.
pub fn hit(text: []const u8, p: Place, q: Point, margin: f64) bool {
    const w = width(text);
    const t = p.unmap(w, q);
    const m = margin / p.size;
    return t.x >= -m and t.x <= w + m and t.y >= -descender - m and t.y <= 1 + m;
}

/// The four corners of `text`'s box (descender to cap line) as placed.
pub fn box(text: []const u8, p: Place) [4]Point {
    const w = width(text);
    return .{
        p.map(w, .{ .x = 0, .y = -descender }), p.map(w, .{ .x = w, .y = -descender }),
        p.map(w, .{ .x = w, .y = 1 }),          p.map(w, .{ .x = 0, .y = 1 }),
    };
}

const testing = std.testing;

const Collect = struct {
    n: usize = 0,
    lo: Point = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) },
    hi: Point = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) },

    fn add(c: *Collect, pts: []const Point) void {
        c.n += 1;
        for (pts) |q| {
            c.lo = .{ .x = @min(c.lo.x, q.x), .y = @min(c.lo.y, q.y) };
            c.hi = .{ .x = @max(c.hi.x, q.x), .y = @max(c.hi.y, q.y) };
        }
    }
};

test "digits are tabular, the capitals one cap high" {
    try testing.expectApproxEqAbs(20.0 / 21.0, width("0"), 1e-12);
    try testing.expectApproxEqAbs(width("1") * 4, width("8.25") + width("0") - width("."), 1e-12);
    var c: Collect = .{};
    strokes("H", .{ .at = .{ .x = 0, .y = 0 }, .size = 10 }, &c, Collect.add);
    try testing.expectEqual(3, c.n);
    try testing.expectApproxEqAbs(0, c.lo.y, 1e-9);
    try testing.expectApproxEqAbs(10, c.hi.y, 1e-9);
}

test "turned a quarter, text runs up; on the screen, glyphs stay upright" {
    var c: Collect = .{};
    strokes("11", .{ .at = .{ .x = 0, .y = 0 }, .size = 10, .angle = std.math.pi / 2.0 }, &c, Collect.add);
    // Running up +y, the glyphs stand toward -x.
    try testing.expect(c.hi.y > 10 and c.lo.y >= -1e-9);
    try testing.expect(c.lo.x < -5 and c.hi.x <= 1e-9);
    var d: Collect = .{};
    strokes("H", .{ .at = .{ .x = 0, .y = 0 }, .size = 10, .y_down = true }, &d, Collect.add);
    try testing.expectApproxEqAbs(-10, d.lo.y, 1e-9);
    try testing.expectApproxEqAbs(0, d.hi.y, 1e-9);
}

test "anchors, hits and the symbols" {
    const p: Place = .{ .at = .{ .x = 5, .y = 5 }, .size = 2, .angle = 0.7, .align_x = 0.5, .align_y = 0.5 };
    // The anchor is in the middle of the box, so it is a hit; far off is not.
    try testing.expect(hit("⌀12.5", p, p.at, 0));
    try testing.expect(!hit("⌀12.5", p, .{ .x = 50, .y = 5 }, 0.1));
    // A known symbol is not the stand-in.
    try testing.expect(!std.mem.eql(u8, glyphOf(0x2300), glyphOf('?')));
    try testing.expectEqualStrings(glyphOf('?'), glyphOf(0x1F600));
    // A stray byte draws as a stand-in, without upsetting what follows.
    try testing.expectApproxEqAbs(width("?1"), width("\xff1"), 1e-12);
}
