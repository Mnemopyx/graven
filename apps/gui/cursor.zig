//! Scintillation, the interface's sign for a point standing in for the
//! pointer, as an animated cursor image: the system's compositor plays it,
//! so Graven draws nothing while it runs.
//!
//! The pointer cannot be moved onto the point (Wayland does not allow
//! it), but the cursor's image can be anything, with its hotspot (the
//! pointer's exact place) anywhere in it: so the image holds the spark
//! drawn where the point is, off from the hotspot by the point's offset
//! from the pointer, and (while only hovering) a small arrow at the
//! hotspot for the pointer itself.
//!
//! The animation: eight short rays round the point, turning, in two
//! colours that trade places, pulsing, round a ring and a fine cross on the
//! exact point. Its rates are chosen so it loops seamlessly in `loop_s`;
//! the drawn version (where a cursor cannot be made) uses the same ones.
//!
//! Window-free: frames are drawn into RGBA buffers here and handed to SDL
//! by the GUI.

const std = @import("std");

/// The loop: this many frames, each this long.
pub const frames = 20;
pub const frame_ms = 40;
pub const loop_s: f32 = @as(f32, frames * frame_ms) / 1000;

/// The rays turn this fast (rad/s): a ray's place repeats every eighth of
/// a turn, two of them in a loop.
pub const turn_rate: f32 = 2 * (2 * std.math.pi / 8.0) / loop_s;
/// The glow pulses this often (Hz): two pulses a loop.
pub const glow_hz: f32 = 2 / loop_s;
/// The colours trade places this often (per second): four times a loop.
pub const swap_rate: f32 = 4 / loop_s;
pub const rays = 8;

/// The rays' angle offset at time `t` (s).
pub fn angle(t: f32) f32 {
    return t * turn_rate;
}

/// How bright the rays are at time `t`, 0.1 to 1.
pub fn glow(t: f32) f32 {
    return 0.55 + 0.45 * @sin(t * 2 * std.math.pi * glow_hz);
}

/// Whether ray `i` takes the first colour at time `t`.
pub fn firstColour(i: usize, t: f32) bool {
    const k: usize = @intFromFloat(@floor(t * swap_rate));
    return (i + k) % 2 == 0;
}

/// A colour, 0 to 1 each, straight (not premultiplied) alpha.
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 = 1 };

pub const Spec = struct {
    /// The point, from the pointer (logical pixels, y down).
    dx: f32,
    dy: f32,
    /// The spark's radius, logical pixels.
    radius: f32 = 8,
    /// Device pixels per logical one: the image is drawn at this scale.
    scale: f32 = 1,
    /// A small arrow at the hotspot, for the pointer itself.
    arrow: bool,
    a: Color,
    b: Color,
    ink: Color,
    paper: Color,
};

/// The image's size and its hotspot, device pixels.
pub const Size = struct { w: u32, h: u32, hot_x: u32, hot_y: u32 };

/// The largest image a cursor may be, device pixels, on a side.
pub const max_side: u32 = 256;

/// How big the image for `s` is and where its hotspot is; null when it
/// would be too big to be a cursor (the point too far from the pointer).
pub fn size(s: Spec) ?Size {
    const reach = s.radius * 1.7;
    const margin: f32 = 2;
    // The box round the hotspot (and its arrow) and the spark.
    const arrow_w: f32 = if (s.arrow) 12 else 2;
    const arrow_h: f32 = if (s.arrow) 18 else 2;
    const x0 = @min(-2, s.dx - reach) - margin;
    const y0 = @min(-2, s.dy - reach) - margin;
    const x1 = @max(arrow_w, s.dx + reach) + margin;
    const y1 = @max(arrow_h, s.dy + reach) + margin;
    const w: u32 = @intFromFloat(@ceil((x1 - x0) * s.scale));
    const h: u32 = @intFromFloat(@ceil((y1 - y0) * s.scale));
    if (w > max_side or h > max_side) return null;
    return .{ .w = w, .h = h, .hot_x = @intFromFloat(@round(-x0 * s.scale)), .hot_y = @intFromFloat(@round(-y0 * s.scale)) };
}

/// Draws frame `k` of the loop for `s` into `out` (RGBA, 8 bits each,
/// straight alpha, `sz.w` × `sz.h`).
pub fn frame(s: Spec, sz: Size, k: usize, out: []u8) void {
    @memset(out, 0);
    const t = @as(f32, @floatFromInt(k)) * frame_ms / 1000;
    const sc = s.scale;
    const hx: f32 = @floatFromInt(sz.hot_x);
    const hy: f32 = @floatFromInt(sz.hot_y);
    // On pixel centres, so the cross's lines are crisp.
    const cx = hx + 0.5 + @round(s.dx * sc);
    const cy = hy + 0.5 + @round(s.dy * sc);
    const r = s.radius * sc;
    var c: Canvas = .{ .w = sz.w, .h = sz.h, .px = out };
    // The pointer's own arrow, under the spark.
    if (s.arrow) {
        const pts = [_][2]f32{ .{ 0, 0 }, .{ 0, 16 }, .{ 4, 12.5 }, .{ 7, 18 }, .{ 9.5, 17 }, .{ 6.8, 11.5 }, .{ 11.5, 11.5 } };
        var poly: [pts.len][2]f32 = undefined;
        for (pts, &poly) |p, *q| q.* = .{ hx + p[0] * sc, hy + p[1] * sc };
        c.polygon(&poly, s.ink);
        c.polyline(&poly, true, 1.2 * sc, s.paper);
    }
    const g = glow(t);
    for (0..rays) |i| {
        const ang = @as(f32, @floatFromInt(i)) * 2 * std.math.pi / rays + angle(t);
        const co = @cos(ang);
        const si = @sin(ang);
        var col = if (firstColour(i, t)) s.a else s.b;
        col.a *= g;
        c.segment(cx + co * r * 0.75, cy + si * r * 0.75, cx + co * r * 1.55, cy + si * r * 1.55, 2 * sc, col);
    }
    c.ring(cx, cy, r * 0.55, 1.5 * sc, s.a);
    const l = r * 0.4;
    c.segment(cx - l, cy, cx + l, cy, 1 * sc, s.ink);
    c.segment(cx, cy - l, cx, cy + l, 1 * sc, s.ink);
}

/// An RGBA buffer, drawn into with antialiased strokes (4 × 4 samples a
/// pixel), each laid over what is there.
const Canvas = struct {
    w: u32,
    h: u32,
    px: []u8,

    fn over(c: *Canvas, x: u32, y: u32, col: Color, cover: f32) void {
        const a = col.a * cover;
        if (a <= 0) return;
        const i = (y * c.w + x) * 4;
        const da = @as(f32, @floatFromInt(c.px[i + 3])) / 255;
        const oa = a + da * (1 - a);
        if (oa <= 0) return;
        const mix = struct {
            fn f(src: f32, dst: u8, sa: f32, dsta: f32, outa: f32) u8 {
                const d = @as(f32, @floatFromInt(dst)) / 255;
                return @intFromFloat(@round(std.math.clamp((src * sa + d * dsta * (1 - sa)) / outa, 0, 1) * 255));
            }
        }.f;
        c.px[i] = mix(col.r, c.px[i], a, da, oa);
        c.px[i + 1] = mix(col.g, c.px[i + 1], a, da, oa);
        c.px[i + 2] = mix(col.b, c.px[i + 2], a, da, oa);
        c.px[i + 3] = @intFromFloat(@round(oa * 255));
    }

    /// Covers what `inside(x, y)` holds within box x0..x1, y0..y1.
    fn fill(c: *Canvas, x0f: f32, y0f: f32, x1f: f32, y1f: f32, col: Color, ctx: anytype, comptime inside: fn (@TypeOf(ctx), f32, f32) bool) void {
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(x0f), 0, @as(f32, @floatFromInt(c.w))));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(y0f), 0, @as(f32, @floatFromInt(c.h))));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(x1f), 0, @as(f32, @floatFromInt(c.w))));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y1f), 0, @as(f32, @floatFromInt(c.h))));
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                var n: u32 = 0;
                for (0..4) |sy| for (0..4) |sx| {
                    const fx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4;
                    const fy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4;
                    if (inside(ctx, fx, fy)) n += 1;
                };
                if (n > 0) c.over(x, y, col, @as(f32, @floatFromInt(n)) / 16);
            }
        }
    }

    fn segment(c: *Canvas, ax: f32, ay: f32, bx: f32, by: f32, width: f32, col: Color) void {
        const Seg = struct {
            ax: f32,
            ay: f32,
            bx: f32,
            by: f32,
            hw: f32,
            fn in(s: @This(), x: f32, y: f32) bool {
                const vx = s.bx - s.ax;
                const vy = s.by - s.ay;
                const len2 = vx * vx + vy * vy;
                const t = if (len2 > 0) std.math.clamp(((x - s.ax) * vx + (y - s.ay) * vy) / len2, 0, 1) else 0;
                const px = s.ax + t * vx - x;
                const py = s.ay + t * vy - y;
                return px * px + py * py <= s.hw * s.hw;
            }
        };
        const hw = width / 2;
        c.fill(@min(ax, bx) - hw, @min(ay, by) - hw, @max(ax, bx) + hw, @max(ay, by) + hw, col, Seg{ .ax = ax, .ay = ay, .bx = bx, .by = by, .hw = hw }, Seg.in);
    }

    fn ring(c: *Canvas, cx: f32, cy: f32, r: f32, width: f32, col: Color) void {
        const Ring = struct {
            cx: f32,
            cy: f32,
            r: f32,
            hw: f32,
            fn in(s: @This(), x: f32, y: f32) bool {
                const d = @sqrt((x - s.cx) * (x - s.cx) + (y - s.cy) * (y - s.cy));
                return @abs(d - s.r) <= s.hw;
            }
        };
        const e = r + width;
        c.fill(cx - e, cy - e, cx + e, cy + e, col, Ring{ .cx = cx, .cy = cy, .r = r, .hw = width / 2 }, Ring.in);
    }

    fn polygon(c: *Canvas, pts: []const [2]f32, col: Color) void {
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        for (pts) |p| {
            x0 = @min(x0, p[0]);
            y0 = @min(y0, p[1]);
            x1 = @max(x1, p[0]);
            y1 = @max(y1, p[1]);
        }
        const Poly = struct {
            pts: []const [2]f32,
            fn in(s: @This(), x: f32, y: f32) bool {
                var inside = false;
                var j = s.pts.len - 1;
                for (s.pts, 0..) |p, i| {
                    const q = s.pts[j];
                    if ((p[1] > y) != (q[1] > y) and x < (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0]) inside = !inside;
                    j = i;
                }
                return inside;
            }
        };
        c.fill(x0, y0, x1, y1, col, Poly{ .pts = pts }, Poly.in);
    }

    fn polyline(c: *Canvas, pts: []const [2]f32, closed: bool, width: f32, col: Color) void {
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| c.segment(a[0], a[1], b[0], b[1], width, col);
        if (closed) c.segment(pts[pts.len - 1][0], pts[pts.len - 1][1], pts[0][0], pts[0][1], width, col);
    }
};

const testing = std.testing;

const blue: Color = .{ .r = 0.12, .g = 0.44, .b = 0.88 };
const orange: Color = .{ .r = 0.95, .g = 0.27, .b = 0 };
const black: Color = .{ .r = 0.1, .g = 0.1, .b = 0.1 };
const white: Color = .{ .r = 1, .g = 1, .b = 1 };

test "the loop is seamless: the last frame leads back to the first" {
    // Every rate completes whole cycles in a loop.
    try testing.expectApproxEqAbs(@as(f32, 2), glow_hz * loop_s, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 4), swap_rate * loop_s, 1e-4);
    const ray_period = 2 * std.math.pi / @as(f32, rays);
    try testing.expectApproxEqAbs(@as(f32, 2), turn_rate * loop_s / ray_period, 1e-4);
}

test "the image holds the hotspot and the spark, the spark centred on the offset" {
    const spec: Spec = .{ .dx = 30, .dy = -20, .arrow = false, .a = blue, .b = orange, .ink = black, .paper = white };
    const sz = size(spec).?;
    try testing.expect(sz.hot_x < sz.w and sz.hot_y < sz.h);
    const buf = try testing.allocator.alloc(u8, sz.w * sz.h * 4);
    defer testing.allocator.free(buf);
    frame(spec, sz, 0, buf);
    // The cross's centre is opaque ink, at hotspot + offset.
    const x = sz.hot_x + 30;
    const y = sz.hot_y - 20;
    try testing.expect(buf[(y * sz.w + x) * 4 + 3] > 200);
    // Without the arrow, the hotspot itself is clear.
    try testing.expectEqual(0, buf[(sz.hot_y * sz.w + sz.hot_x) * 4 + 3]);
}

test "with the arrow, the hotspot is the arrow's tip; too far a point makes no cursor" {
    const spec: Spec = .{ .dx = 25, .dy = 25, .arrow = true, .a = blue, .b = orange, .ink = black, .paper = white, .scale = 2 };
    const sz = size(spec).?;
    const buf = try testing.allocator.alloc(u8, sz.w * sz.h * 4);
    defer testing.allocator.free(buf);
    frame(spec, sz, 3, buf);
    try testing.expect(buf[((sz.hot_y + 4) * sz.w + sz.hot_x + 1) * 4 + 3] > 0);
    var far = spec;
    far.dx = 400;
    try testing.expect(size(far) == null);
}
