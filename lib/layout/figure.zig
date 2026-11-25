//! Figures: line art kept in the document as a prototype, its ink only
//! (no boundary: a figure's placements carry those). A figure is paths,
//! back to front; each path is subpaths of exact segments (lines,
//! quadratics, cubics, conics), open or closed, with an optional fill and
//! an optional stroke (a pen: colour, width, caps, joins). What it makes,
//! its ink, is computed from them (`ink`): the fill's region, and the
//! stroke's outline (`geom.stroke`) over it. A figure's ink, not its
//! paths, is what is drawn, measured and made.
//!
//! Figures come from SVG files (`svg.zig`), mm, y up, their origin the
//! drawing's bottom left.

const std = @import("std");
const geom = @import("graven_geom");
const art = @import("art.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Box = geom.Box;
const Segment = geom.Segment;

/// A run of segments, each starting where the one before ends; closed when
/// its end joins its start (a fill closes an open one with a line).
pub const Subpath = struct {
    segments: []const Segment,
    closed: bool = false,
};

pub const FillRule = enum { nonzero, evenodd };

pub const Stroke = struct {
    color: art.Color,
    /// mm.
    width: f64,
    cap: geom.stroke.Cap = .butt,
    join: geom.stroke.Join = .miter,
    miter_limit: f64 = 4,
};

pub const Path = struct {
    subpaths: []const Subpath,
    fill: ?art.Color = null,
    fill_rule: FillRule = .nonzero,
    stroke: ?Stroke = null,
};

/// What fills an area: solid, or a hatch of parallel lines.
pub const Pattern = union(enum) {
    solid,
    hatch: Hatch,

    pub const Hatch = struct {
        /// Degrees, anticlockwise from the x axis.
        angle: f64 = 45,
        /// mm, line to line (centres).
        spacing: f64 = 1,
        /// mm, each line's width.
        width: f64 = 0.15,
    };
};

/// An area of a sketch filled in a fill style: inside the closed path
/// its geometry `geoms` makes; with `enclosed` off, the closed paths of
/// the sketch's other geometry inside it are left out (holes).
pub const Fill = struct {
    geoms: []const u32,
    /// Its fill style (`Model.fill_styles`).
    style: @import("model.zig").ObjectId,
    enclosed: bool = false,
};

/// A sketch's geometry inked: drawn as a stroke in a stroke style.
pub const Ink = struct {
    /// The geometry, in the figure's sketch.
    geom: u32,
    /// Its stroke style (`Model.stroke_styles`).
    style: @import("model.zig").ObjectId,
};

pub const Figure = struct {
    id: @import("model.zig").ObjectId = .none,
    name: []const u8,
    /// True while the name is one the app gave it (Figure 1).
    default_name: bool = false,
    /// Back to front.
    paths: []const Path,
    /// The file it was imported from, if any (its name only).
    source: []const u8 = "",
    /// A figure drawn over a sketch: the sketch (its `SketchItem` ID),
    /// whose geometry its `inks` stroke. Its `paths` are made from them
    /// (`Model.syncSketchFigures`), in the sketch's own frame, and follow
    /// the sketch; it is drawn where the sketch's views are.
    sketch: @import("model.zig").ObjectId = .none,
    inks: []const Ink = &.{},
    /// Areas of the sketch filled (drawn under its ink).
    fills: []const Fill = &.{},
    /// While its sketch has a draft pending: its paths as the draft would
    /// make them, for the sketch editor (not saved; `paths` are what its
    /// uses see until the draft is accepted).
    draft: []const Path = &.{},

    /// Its paths' bounds, strokes' widths included (a pen's reach, not
    /// its caps' or miters' exact extent).
    pub fn bounds(f: Figure) Box {
        var b: Box = .empty;
        for (f.paths) |p| {
            var pb: Box = .empty;
            for (p.subpaths) |sp| for (sp.segments) |s| {
                pb = pb.join(s.bounds());
            };
            if (pb.isEmpty()) continue;
            if (p.stroke) |st| {
                const h = st.width / 2;
                pb = .{ .x0 = pb.x0 - h, .y0 = pb.y0 - h, .x1 = pb.x1 + h, .y1 = pb.y1 + h };
            }
            b = b.join(pb);
        }
        return b;
    }
};

/// A figure's ink, back to front: for each path, its fill's region, then
/// its stroke's outline, each a shape painted solid in its colour. Curves
/// in strokes are flattened to `tol` mm first; fills keep their curves.
pub fn ink(a: Allocator, f: Figure, tol: f64) Allocator.Error![]const art.Shape {
    var out: std.ArrayList(art.Shape) = .empty;
    for (f.paths) |p| {
        if (p.fill) |c| {
            var contours: std.ArrayList(geom.Contour) = .empty;
            for (p.subpaths) |sp| {
                if (sp.segments.len == 0) continue;
                const s0 = sp.segments[0].start();
                const e = sp.segments[sp.segments.len - 1].end();
                if (s0.eql(e)) {
                    try contours.append(a, .{ .segments = sp.segments });
                } else {
                    const segs = try a.alloc(Segment, sp.segments.len + 1);
                    @memcpy(segs[0..sp.segments.len], sp.segments);
                    segs[sp.segments.len] = .{ .line = .{ e, s0 } };
                    try contours.append(a, .{ .segments = segs });
                }
            }
            var o: geom.Outline = .{ .contours = contours.items };
            if (p.fill_rule == .evenodd and contours.items.len > 1) {
                // Even-odd made explicit, so a nonzero fill draws it.
                const R = struct {
                    fn inside(_: *const anyopaque, in: []const bool) bool {
                        return in[0];
                    }
                };
                o = geom.boolean.combine(a, &.{o}, .{ .ctx = undefined, .inside = R.inside }) catch o;
            }
            if (o.contours.len > 0) try out.append(a, .{ .name = "fill", .outline = o, .paint = .{ .fill = .{ .solid = c } } });
        }
        if (p.stroke) |st| {
            var lines: std.ArrayList(geom.stroke.Polyline) = .empty;
            for (p.subpaths) |sp| {
                if (sp.segments.len == 0) continue;
                try lines.append(a, .{ .pts = try flatten(a, sp.segments, tol), .closed = sp.closed });
            }
            const o = try geom.stroke.stroke(a, lines.items, .{ .width = st.width, .cap = st.cap, .join = st.join, .miter_limit = st.miter_limit }, tol);
            if (o.contours.len > 0) try out.append(a, .{ .name = "stroke", .outline = o, .paint = .{ .fill = .{ .solid = st.color } } });
        }
    }
    return out.items;
}

/// A run of segments as points within `tol` of it, its start included.
pub fn flatten(a: Allocator, segs: []const Segment, tol: f64) Allocator.Error![]const Point {
    var pts: std.ArrayList(Point) = .empty;
    if (segs.len == 0) return pts.items;
    try pts.append(a, segs[0].start());
    for (segs) |seg| {
        const ps = seg.points();
        var dev: f64 = 0;
        for (ps[1 .. ps.len - 1]) |q| dev = @max(dev, distToLine(q, ps[0], ps[ps.len - 1]));
        const n: usize = if (seg == .line) 1 else @max(1, @min(512, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol) * 1.5)))));
        for (1..n + 1) |i| try pts.append(a, seg.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
    }
    return pts.items;
}

fn distToLine(p: Point, a: Point, b: Point) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const l = @sqrt(dx * dx + dy * dy);
    if (l == 0) return @sqrt((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y));
    return @abs((p.x - a.x) * dy - (p.y - a.y) * dx) / l;
}

/// Its ink's bounds (what a placement's box boundary holds).
pub fn inkBounds(shapes: []const art.Shape) Box {
    var b: Box = .empty;
    for (shapes) |s| b = b.join(s.outline.bounds());
    return b;
}

test "a stroked open line's ink is its stroke; a filled one closes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]Segment{ .{ .line = .{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } } }, .{ .line = .{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } } } };
    const f: Figure = .{ .name = "L", .paths = &.{.{
        .subpaths = &.{.{ .segments = &segs }},
        .fill = art.Color.hex("#cccccc"),
        .stroke = .{ .color = art.Color.hex("#000000"), .width = 2, .cap = .square },
    }} };
    const shapes = try ink(a, f, 1e-3);
    try std.testing.expectEqual(2, shapes.len);
    // The fill: the triangle the line closes.
    try std.testing.expectApproxEqAbs(50, @abs(shapes[0].outline.signedArea()), 1e-9);
    const b = inkBounds(shapes);
    try std.testing.expectApproxEqAbs(-1, b.x0, 1e-9);
    try std.testing.expectApproxEqAbs(11, b.y1, 1e-9);
}
