//! Tile art: how a tile prototype's tiles look, drawn once for a 1u × 1u
//! cell and stretched to any size.
//!
//! The art is layers of exact outlines (lines, quadratics, cubics), each
//! with a paint. A vertical and a horizontal cut line divide the cell into
//! four corner patterns. A tile w × h u keeps each corner pattern as drawn,
//! moved to its corner, and bridges between them: wherever an outline
//! crosses a cut, a straight bridge is inserted along the stretch, so the
//! top and bottom edges grow horizontally, the sides vertically and the
//! centre both ways. Corner radii and shading keep their shape at any size,
//! and the result is still exact geometry. A line may cross a cut at any
//! angle (its two halves move apart and the bridge joins them); a curve may
//! not, since it could not be split exactly.
//!
//! Gradients are placed by fractions of the tile's pitch box, so they
//! stretch with the tile. Both the GUI and SVG output draw tiles from the
//! shapes `stretch` returns, so the two cannot drift apart.

const std = @import("std");
const engine = @import("graven_engine");
const model = @import("model.zig");

const geom = engine.geom;
const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Box = geom.Box;
const Segment = geom.Segment;

/// sRGB, with straight (not premultiplied) alpha.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// From "#rrggbb".
    pub fn hex(comptime s: []const u8) Color {
        const v: u24 = comptime blk: {
            if (s.len != 7 or s[0] != '#') @compileError("expected #rrggbb");
            break :blk std.fmt.parseInt(u24, s[1..], 16) catch @compileError("expected #rrggbb");
        };
        return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
    }

    /// The colour `t` of the way from `a` to `b`, t in 0..1.
    pub fn mix(a: Color, b: Color, t: f64) Color {
        const k = std.math.clamp(t, 0, 1);
        const f = struct {
            fn ch(x: u8, y: u8, u: f64) u8 {
                return @intFromFloat(@round(@as(f64, @floatFromInt(x)) * (1 - u) + @as(f64, @floatFromInt(y)) * u));
            }
        }.ch;
        return .{ .r = f(a.r, b.r, k), .g = f(a.g, b.g, k), .b = f(a.b, b.b, k), .a = f(a.a, b.a, k) };
    }
};

pub const Linear = struct {
    /// In art, fractions of the tile's pitch box (0, 0 at its bottom left,
    /// 1, 1 at its top right); in a stretched shape, mm in the panel frame.
    from: Point,
    to: Point,
    start: Color,
    end: Color,

    /// The colour at `p`, in the frame the end points are in.
    pub fn at(l: Linear, p: Point) Color {
        const dx = l.to.x - l.from.x;
        const dy = l.to.y - l.from.y;
        const d2 = dx * dx + dy * dy;
        if (d2 == 0) return l.start;
        return l.start.mix(l.end, ((p.x - l.from.x) * dx + (p.y - l.from.y) * dy) / d2);
    }
};

pub const Fill = union(enum) {
    none,
    solid: Color,
    linear: Linear,

    /// The colour at `p` (for a gradient, in the frame its end points are in).
    pub fn at(f: Fill, p: Point) ?Color {
        return switch (f) {
            .none => null,
            .solid => |c| c,
            .linear => |l| l.at(p),
        };
    }
};

pub const Paint = struct {
    fill: Fill = .none,
    /// The outline drawn over the fill, if any, and its width, mm.
    edge: ?Color = null,
    edge_width: f64 = 0.15,
};

pub const Layer = struct {
    name: []const u8,
    /// Closed contours in the cell's frame: mm, y up, origin at the cell's
    /// bottom-left corner.
    outline: geom.Outline,
    paint: Paint,
};

pub const Art = struct {
    /// The cell is 1u × 1u at this pitch, mm. On a region of another pitch
    /// the art is scaled to fit first.
    pitch: f64,
    /// Where the cut lines are, in the cell: x of the vertical one, y of the
    /// horizontal one.
    cut: Point,
    /// Back to front.
    layers: []const Layer,
};

/// A layer stretched onto a tile: mm in the panel frame, its gradient's end
/// points resolved to the panel frame too.
pub const Shape = struct {
    name: []const u8,
    outline: geom.Outline,
    paint: Paint,
};

pub const Error = Allocator.Error || error{CurveCrossesCut};

/// The art's layers stretched onto a tile whose pitch box is `box` in a
/// region of pitch `pitch`.
pub fn stretch(a: Allocator, art: Art, pitch: f64, box: Box) Error![]const Shape {
    const s = pitch / art.pitch;
    const cut: Point = .{ .x = art.cut.x * s, .y = art.cut.y * s };
    const grow: Point = .{ .x = box.width() - pitch, .y = box.height() - pitch };
    const shapes = try a.alloc(Shape, art.layers.len);
    for (art.layers, shapes) |layer, *out| {
        const contours = try a.alloc(geom.Contour, layer.outline.contours.len);
        for (layer.outline.contours, contours) |c, *oc| {
            oc.* = .{ .segments = try stretchContour(a, c.segments, s, cut, grow, .{ .x = box.x0, .y = box.y0 }) };
        }
        var paint = layer.paint;
        if (paint.fill == .linear) {
            const l = paint.fill.linear;
            paint.fill.linear.from = .{ .x = box.x0 + l.from.x * box.width(), .y = box.y0 + l.from.y * box.height() };
            paint.fill.linear.to = .{ .x = box.x0 + l.to.x * box.width(), .y = box.y0 + l.to.y * box.height() };
        }
        out.* = .{ .name = layer.name, .outline = .{ .contours = contours }, .paint = paint };
    }
    return shapes;
}

/// Whether any curve in the art crosses a cut line, which `stretch` cannot
/// do exactly.
pub fn check(art: Art) Error!void {
    for (art.layers) |layer| for (layer.outline.contours) |c| for (c.segments) |seg| {
        if (seg != .line and crosses(seg.bounds(), art.cut)) return error.CurveCrossesCut;
    };
}

fn crosses(b: Box, cut: Point) bool {
    return (b.x0 < cut.x and b.x1 > cut.x) or (b.y0 < cut.y and b.y1 > cut.y);
}

fn stretchContour(a: Allocator, segs: []const Segment, s: f64, cut: Point, grow: Point, origin: Point) Error![]const Segment {
    var out: std.ArrayList(Segment) = .empty;
    const scale = geom.Affine.scale(s);
    for (segs) |seg0| {
        const seg = seg0.transformed(scale);
        switch (seg) {
            .line => |p| {
                // Split where it crosses a cut, each piece moved with its side.
                var ts: [3]f64 = .{ 0, 0, 0 };
                var n: usize = 0;
                if ((p[0].x - cut.x) * (p[1].x - cut.x) < 0) {
                    ts[n] = (cut.x - p[0].x) / (p[1].x - p[0].x);
                    n += 1;
                }
                if ((p[0].y - cut.y) * (p[1].y - cut.y) < 0) {
                    ts[n] = (cut.y - p[0].y) / (p[1].y - p[0].y);
                    n += 1;
                }
                std.mem.sort(f64, ts[0..n], {}, std.sort.asc(f64));
                ts[n] = 1;
                var t0: f64 = 0;
                for (ts[0 .. n + 1]) |t1| {
                    const q0 = lerp(p[0], p[1], t0);
                    const q1 = lerp(p[0], p[1], t1);
                    if (t1 > t0) try append(a, &out, .{ .line = .{ q0, q1 } }, cut, grow, origin);
                    t0 = t1;
                }
            },
            else => {
                if (crosses(seg.bounds(), cut)) return error.CurveCrossesCut;
                try append(a, &out, seg, cut, grow, origin);
            },
        }
    }
    // Close over the cut too.
    if (out.items.len > 0) {
        const first = out.items[0].start();
        const last = out.items[out.items.len - 1].end();
        if (!near(first, last)) try out.append(a, .{ .line = .{ last, first } });
    }
    return out.items;
}

/// Appends `seg` (on one side of each cut) moved with its side, bridged from
/// the previous piece if the move opened a gap.
fn append(a: Allocator, out: *std.ArrayList(Segment), seg: Segment, cut: Point, grow: Point, origin: Point) Allocator.Error!void {
    const b = seg.bounds();
    const mid: Point = .{ .x = (b.x0 + b.x1) / 2, .y = (b.y0 + b.y1) / 2 };
    const move = geom.Affine.translate(
        origin.x + (if (mid.x > cut.x) grow.x else 0),
        origin.y + (if (mid.y > cut.y) grow.y else 0),
    );
    const moved = seg.transformed(move);
    if (out.items.len > 0) {
        const prev = out.items[out.items.len - 1].end();
        if (!near(prev, moved.start())) try out.append(a, .{ .line = .{ prev, moved.start() } });
    }
    try out.append(a, moved);
}

fn lerp(p: Point, q: Point, t: f64) Point {
    return .{ .x = p.x + (q.x - p.x) * t, .y = p.y + (q.y - p.y) * t };
}

fn near(p: Point, q: Point) bool {
    return @abs(p.x - q.x) < 1e-9 and @abs(p.y - q.y) < 1e-9;
}

/// A rectangle with rounded corners, counter-clockwise (y up); each corner
/// a cubic quarter circle. `r` is clamped to half the shorter side.
pub fn roundedRect(a: Allocator, b: Box, r_in: f64) Allocator.Error!geom.Outline {
    const r = @max(0, @min(r_in, @min(b.width(), b.height()) / 2));
    const k = r * 0.5522847498;
    const segs = try a.alloc(Segment, 8);
    const P = Point;
    segs[0] = .{ .line = .{ P{ .x = b.x0 + r, .y = b.y0 }, P{ .x = b.x1 - r, .y = b.y0 } } };
    segs[1] = .{ .cubic = .{ P{ .x = b.x1 - r, .y = b.y0 }, P{ .x = b.x1 - r + k, .y = b.y0 }, P{ .x = b.x1, .y = b.y0 + r - k }, P{ .x = b.x1, .y = b.y0 + r } } };
    segs[2] = .{ .line = .{ P{ .x = b.x1, .y = b.y0 + r }, P{ .x = b.x1, .y = b.y1 - r } } };
    segs[3] = .{ .cubic = .{ P{ .x = b.x1, .y = b.y1 - r }, P{ .x = b.x1, .y = b.y1 - r + k }, P{ .x = b.x1 - r + k, .y = b.y1 }, P{ .x = b.x1 - r, .y = b.y1 } } };
    segs[4] = .{ .line = .{ P{ .x = b.x1 - r, .y = b.y1 }, P{ .x = b.x0 + r, .y = b.y1 } } };
    segs[5] = .{ .cubic = .{ P{ .x = b.x0 + r, .y = b.y1 }, P{ .x = b.x0 + r - k, .y = b.y1 }, P{ .x = b.x0, .y = b.y1 - r + k }, P{ .x = b.x0, .y = b.y1 - r } } };
    segs[6] = .{ .line = .{ P{ .x = b.x0, .y = b.y1 - r }, P{ .x = b.x0, .y = b.y0 + r } } };
    segs[7] = .{ .cubic = .{ P{ .x = b.x0, .y = b.y0 + r }, P{ .x = b.x0, .y = b.y0 + r - k }, P{ .x = b.x0 + r - k, .y = b.y0 }, P{ .x = b.x0 + r, .y = b.y0 } } };
    const contours = try a.alloc(geom.Contour, 1);
    contours[0] = .{ .segments = segs };
    return .{ .contours = contours };
}

pub const KeycapOptions = struct {
    /// The cell, mm.
    pitch: f64,
    body_inset: model.Sides,
    face_inset: model.Sides,
    radius: f64 = 1,
    body: Fill,
    edge: ?Color,
    face: Fill,
};

/// A 1u × 1u keycap: a body and a face on it, as rounded rectangles placed
/// by the insets, cut through the middle of the cell.
pub fn keycap(a: Allocator, o: KeycapOptions) Allocator.Error!Art {
    const cell: Box = .{ .x0 = 0, .y0 = 0, .x1 = o.pitch, .y1 = o.pitch };
    const body = o.body_inset.inset(cell);
    const layers = try a.alloc(Layer, 2);
    layers[0] = .{ .name = "body", .outline = try roundedRect(a, body, o.radius), .paint = .{ .fill = o.body, .edge = o.edge } };
    layers[1] = .{ .name = "face", .outline = try roundedRect(a, o.face_inset.inset(body), o.radius), .paint = .{ .fill = o.face } };
    return .{ .pitch = o.pitch, .cut = .{ .x = o.pitch / 2, .y = o.pitch / 2 }, .layers = layers };
}

/// The look of a prototype without art of its own, or whose art cannot be
/// stretched: flat body and face drawn from its insets.
pub fn plainShapes(a: Allocator, proto: model.TilePrototype, pitch: f64, box: Box) Allocator.Error![]const Shape {
    return stretch(a, try plain(a, proto, pitch), pitch, box) catch |err| switch (err) {
        // Only a face too small for its corners; draw nothing rather than fail.
        error.CurveCrossesCut => &.{},
        else => |e| e,
    };
}

/// The flat art `plainShapes` stretches.
pub fn plain(a: Allocator, proto: model.TilePrototype, pitch: f64) Allocator.Error!Art {
    return keycap(a, .{
        .pitch = pitch,
        .body_inset = proto.body_inset,
        .face_inset = proto.face_inset,
        .body = .{ .solid = .hex("#e4e2dc") },
        .edge = .hex("#9a978f"),
        .face = .{ .solid = .hex("#f6f5f1") },
    });
}

/// A deep copy, allocated from `a`.
pub fn dupe(a: Allocator, art: Art) Allocator.Error!Art {
    const layers = try a.alloc(Layer, art.layers.len);
    for (art.layers, layers) |l, *out| {
        const contours = try a.alloc(geom.Contour, l.outline.contours.len);
        for (l.outline.contours, contours) |c, *oc| oc.* = .{ .segments = try a.dupe(Segment, c.segments) };
        out.* = .{ .name = try a.dupe(u8, l.name), .outline = .{ .contours = contours }, .paint = l.paint };
    }
    return .{ .pitch = art.pitch, .cut = art.cut, .layers = layers };
}

const testing = std.testing;

test "stretching keeps the corners and bridges across the cuts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const art = try keycap(a, .{
        .pitch = 19.05,
        .body_inset = .all(0.5),
        .face_inset = .all(3),
        .radius = 1,
        .body = .{ .linear = .{ .from = .{ .x = 0.5, .y = 1 }, .to = .{ .x = 0.5, .y = 0 }, .start = .hex("#ffffff"), .end = .hex("#000000") } },
        .edge = null,
        .face = .{ .solid = .hex("#eeeeee") },
    });
    try check(art);

    // At 1u it is the art as drawn, moved to the tile.
    const one = try stretch(a, art, 19.05, .{ .x0 = 100, .y0 = 50, .x1 = 119.05, .y1 = 69.05 });
    const b1 = one[0].outline.bounds();
    try testing.expectApproxEqAbs(@as(f64, 100.5), b1.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 18.05), b1.width(), 1e-9);

    // At 2.25u × 2u the body grows by the extra pitch both ways; its area
    // grows by exactly the bridged bands, so the corners kept their shape.
    const box: Box = .{ .x0 = 0, .y0 = 0, .x1 = 2.25 * 19.05, .y1 = 2 * 19.05 };
    const big = try stretch(a, art, 19.05, box);
    const body = big[0].outline;
    const bb = body.bounds();
    try testing.expectApproxEqAbs(box.width() - 1, bb.width(), 1e-9);
    try testing.expectApproxEqAbs(box.height() - 1, bb.height(), 1e-9);
    const extra_w = box.width() - 19.05;
    const extra_h = box.height() - 19.05;
    const area1 = art.layers[0].outline.signedArea();
    const expected = area1 + extra_w * 18.05 + extra_h * 18.05 + extra_w * extra_h;
    try testing.expectApproxEqAbs(expected, body.signedArea(), 1e-9);
    // The gradient runs top to bottom of the tile, wherever it is.
    try testing.expectApproxEqAbs(box.y1, big[0].paint.fill.linear.from.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), big[0].paint.fill.linear.to.y, 1e-9);
}

test "a curve across a cut cannot be stretched exactly and is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A circle-ish cap: its quarter arcs reach the middle of the cell.
    const outline = try roundedRect(a, .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }, 5);
    const layers = [_]Layer{.{ .name = "dot", .outline = outline, .paint = .{} }};
    const art: Art = .{ .pitch = 10, .cut = .{ .x = 4, .y = 4 }, .layers = &layers };
    try testing.expectError(error.CurveCrossesCut, check(art));
    try testing.expectError(error.CurveCrossesCut, stretch(a, art, 10, .{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 10 }));
}

test "a gradient's colour runs from start to end" {
    const l: Linear = .{ .from = .{ .x = 0, .y = 10 }, .to = .{ .x = 0, .y = 0 }, .start = .hex("#ffffff"), .end = .hex("#000000") };
    try testing.expectEqual(Color.hex("#ffffff"), l.at(.{ .x = 3, .y = 10 }));
    try testing.expectEqual(@as(u8, 128), l.at(.{ .x = 3, .y = 5 }).r);
    try testing.expectEqual(Color.hex("#000000"), l.at(.{ .x = 3, .y = -2 }));
}
