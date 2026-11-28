//! Tessellation (the owner, 2026-11-28): an area filled with tiles that
//! share their vertices, as many as fit: equilateral triangles, squares or
//! regular hexagons, `spacing` apart centre to centre, turned by `angle`,
//! one tile centred at `origin` (the pattern's offset). The area is an
//! outline (even-odd) brought in by a `margin`; tiles crossing its edge are
//! cut to it, or left out (`whole`).
//!
//! A tiling is a lattice (two steps, `u` and `v`) and the tiles at each of
//! its points (`Tiling`): one square, one hexagon, two triangles (up and
//! down). Other tilings are only other tables.
//!
//! What comes out is lines, each edge once however many tiles share it
//! (a cutter or a pen goes over it once): `edges`; with a margin, the
//! line the margin makes where tiles are cut (`rim`); and, when asked,
//! each tile's own area (`cells`, cut exactly to the area).
//!
//! The area is flattened to within `tol` first (arcs as fine polylines),
//! so where an edge is cut by a curve it ends within `tol` of it.

const std = @import("std");
const root = @import("root.zig");
const grow = @import("grow.zig");
const boolean = @import("boolean.zig");

const Allocator = std.mem.Allocator;
const Point = root.Point;
const Segment = root.Segment;
const Contour = root.Contour;
const Outline = root.Outline;
const Box = root.Box;

pub const Error = Allocator.Error || error{
    /// Not 3, 4 or 6 sides, or a spacing that is not more than 0.
    BadTiling,
};

pub const Options = struct {
    /// Sides of the tile: 3, 4 or 6.
    sides: u32 = 6,
    /// Centre to centre of tiles side by side, in the outline's units.
    spacing: f64 = 10,
    /// The pattern's turn, radians anticlockwise.
    angle: f64 = 0,
    /// A tile's centre: the pattern's offset.
    origin: Point = .{ .x = 0, .y = 0 },
    /// Kept clear inside the outline.
    margin: f64 = 0,
    /// Whole tiles only; else tiles crossing the edge are cut to it.
    whole: bool = false,
    /// Flattening tolerance for curves in the outline.
    tol: f64 = 0.002,
    /// Each tile's area too (`Result.cells`).
    cells: bool = false,
    /// At most this many tiles (a fine spacing over a large area).
    max_tiles: usize = 40_000,
};

pub const Result = struct {
    /// Every edge once: straight lines.
    edges: []Segment = &.{},
    /// With a margin and cut tiles: the margin's line, closing them.
    rim: []Contour = &.{},
    /// Each tile's area (with `Options.cells`).
    cells: []Outline = &.{},
    /// Where each tile kept is: what a tile with content of its own (a
    /// game tile, a figure) is placed by, one in each cell.
    places: []Place = &.{},
    /// Tiles kept (whole and cut).
    tiles: usize = 0,
    /// Whole tiles among them.
    whole: usize = 0,
    /// Stopped at `max_tiles`.
    capped: bool = false,
};

/// A tile of the pattern, placed: lattice point (i, j), its tile `k`
/// there (a triangle tiling's up or down one), its centre and turn
/// (a down triangle's turn is the pattern's plus half a turn), and
/// whether it is whole.
pub const Place = struct {
    i: i64,
    j: i64,
    k: u8,
    centre: Point,
    angle: f64,
    whole: bool,
};

/// A lattice and the tiles at each of its points, for a spacing of 1:
/// vertices relative to the lattice point, anticlockwise.
pub const Tiling = struct {
    u: Point,
    v: Point,
    tiles: []const []const Point,
};

const r3 = @sqrt(3.0);

const square_tile = [_]Point{ .{ .x = -0.5, .y = -0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 } };
// Pointy at top and bottom: neighbours along u, flat sides facing them.
const hex_tile = blk: {
    var p: [6]Point = undefined;
    for (0..6) |k| {
        const t = (30.0 + 60.0 * @as(f64, @floatFromInt(k))) * std.math.pi / 180.0;
        p[k] = .{ .x = @cos(t) / r3, .y = @sin(t) / r3 };
    }
    break :blk p;
};
// Side √3 (centres of an up and a down triangle sharing a side are 1
// apart); the lattice point is the up triangle's centre.
const tri_up = [_]Point{ .{ .x = -r3 / 2.0, .y = -0.5 }, .{ .x = r3 / 2.0, .y = -0.5 }, .{ .x = 0, .y = 1 } };
const tri_down = [_]Point{ .{ .x = r3 / 2.0, .y = -0.5 }, .{ .x = r3, .y = 1 }, .{ .x = 0, .y = 1 } };

pub const squares: Tiling = .{ .u = .{ .x = 1, .y = 0 }, .v = .{ .x = 0, .y = 1 }, .tiles = &.{&square_tile} };
pub const hexagons: Tiling = .{ .u = .{ .x = 1, .y = 0 }, .v = .{ .x = 0.5, .y = r3 / 2.0 }, .tiles = &.{&hex_tile} };
pub const triangles: Tiling = .{ .u = .{ .x = r3, .y = 0 }, .v = .{ .x = r3 / 2.0, .y = 1.5 }, .tiles = &.{ &tri_up, &tri_down } };

/// The tiling of tiles of `sides`.
pub fn tilingFor(sides: u32) ?Tiling {
    return switch (sides) {
        3 => triangles,
        4 => squares,
        6 => hexagons,
        else => null,
    };
}

/// The tiling's tile at lattice point (i, j), number `k`, placed: into
/// `buf`, anticlockwise.
fn placeTile(t: Tiling, o: Options, i: i64, j: i64, k: usize, buf: []Point) []Point {
    const c = @cos(o.angle) * o.spacing;
    const s = @sin(o.angle) * o.spacing;
    const fi: f64 = @floatFromInt(i);
    const fj: f64 = @floatFromInt(j);
    const lx = fi * t.u.x + fj * t.v.x;
    const ly = fi * t.u.y + fj * t.v.y;
    const proto = t.tiles[k];
    for (proto, 0..) |p, n| {
        const x = lx + p.x;
        const y = ly + p.y;
        buf[n] = .{ .x = o.origin.x + c * x - s * y, .y = o.origin.y + s * x + c * y };
    }
    return buf[0..proto.len];
}

/// The area as flat polygons, its segments binned for quick lookup.
const Area = struct {
    polys: []const []const Point,
    segs: []const [2]Point,
    box: Box,
    bin: f64,
    nx: usize,
    ny: usize,
    /// Per bin, the segments its box meets.
    bins: []std.ArrayList(u32),

    fn init(a: Allocator, polys: []const []const Point, bin_hint: f64) Allocator.Error!Area {
        var segs: std.ArrayList([2]Point) = .empty;
        var box: Box = .empty;
        for (polys) |p| for (p, 0..) |q, i| {
            try segs.append(a, .{ q, p[(i + 1) % p.len] });
            box = box.addPoint(q);
        };
        const span = @max(box.width(), box.height());
        const bin = @max(bin_hint, span / 256.0, 1e-9);
        const nx: usize = @as(usize, @intFromFloat(@floor(box.width() / bin))) + 1;
        const ny: usize = @as(usize, @intFromFloat(@floor(box.height() / bin))) + 1;
        const bins = try a.alloc(std.ArrayList(u32), nx * ny);
        for (bins) |*b| b.* = .empty;
        var ar: Area = .{ .polys = polys, .segs = segs.items, .box = box, .bin = bin, .nx = nx, .ny = ny, .bins = bins };
        for (ar.segs, 0..) |sg, si| {
            const r = ar.range(.{ .x0 = @min(sg[0].x, sg[1].x), .y0 = @min(sg[0].y, sg[1].y), .x1 = @max(sg[0].x, sg[1].x), .y1 = @max(sg[0].y, sg[1].y) });
            var y = r[2];
            while (y <= r[3]) : (y += 1) {
                var x = r[0];
                while (x <= r[1]) : (x += 1) try bins[y * nx + x].append(a, @intCast(si));
            }
        }
        return ar;
    }

    fn col(ar: Area, x: f64) usize {
        const f = @floor((x - ar.box.x0) / ar.bin);
        return @intFromFloat(std.math.clamp(f, 0, @as(f64, @floatFromInt(ar.nx - 1))));
    }

    fn row(ar: Area, y: f64) usize {
        const f = @floor((y - ar.box.y0) / ar.bin);
        return @intFromFloat(std.math.clamp(f, 0, @as(f64, @floatFromInt(ar.ny - 1))));
    }

    /// Bins (x0, x1, y0, y1) that box `b` meets.
    fn range(ar: Area, b: Box) [4]usize {
        return .{ ar.col(b.x0), ar.col(b.x1), ar.row(b.y0), ar.row(b.y1) };
    }

    fn overlaps(ar: Area, b: Box) bool {
        return !(b.x1 < ar.box.x0 or b.x0 > ar.box.x1 or b.y1 < ar.box.y0 or b.y0 > ar.box.y1);
    }

    /// Whether `p` is inside (even-odd): crossings to its right, each
    /// segment counted in the one bin of its row holding the crossing.
    fn inside(ar: Area, p: Point) bool {
        if (p.x < ar.box.x0 or p.x > ar.box.x1 or p.y < ar.box.y0 or p.y > ar.box.y1) return false;
        const r = ar.row(p.y);
        var in = false;
        var cx = ar.col(p.x);
        while (cx < ar.nx) : (cx += 1) {
            const bx0 = ar.box.x0 + @as(f64, @floatFromInt(cx)) * ar.bin;
            const last = cx == ar.nx - 1;
            for (ar.bins[r * ar.nx + cx].items) |si| {
                const sg = ar.segs[si];
                if ((sg[0].y > p.y) == (sg[1].y > p.y)) continue;
                const x = sg[0].x + (p.y - sg[0].y) * (sg[1].x - sg[0].x) / (sg[1].y - sg[0].y);
                if (x <= p.x) continue;
                // Counted once: in the bin it falls in (first and last
                // bins take what lies beyond them).
                const c = ar.col(x);
                if (c != cx and !(last and c >= cx)) continue;
                _ = bx0;
                in = !in;
            }
        }
        return in;
    }

    /// Calls `f(ctx, si)` for each segment near box `b` (a segment may
    /// come more than once).
    fn near(ar: Area, b: Box, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32) void) void {
        if (!ar.overlaps(b)) return;
        const r = ar.range(b);
        var y = r[2];
        while (y <= r[3]) : (y += 1) {
            var x = r[0];
            while (x <= r[1]) : (x += 1) for (ar.bins[y * ar.nx + x].items) |si| f(ctx, si);
        }
    }
};

fn polyBox(p: []const Point) Box {
    var b: Box = .empty;
    for (p) |q| b = b.addPoint(q);
    return b;
}

fn cross(o: Point, a: Point, b: Point) f64 {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

/// Where segment p0-p1 crosses q0-q1, as a parameter along p (strictly
/// inside both, by `eps` of their lengths); null if not.
fn crossAt(p0: Point, p1: Point, q0: Point, q1: Point, eps: f64) ?f64 {
    const rx = p1.x - p0.x;
    const ry = p1.y - p0.y;
    const sx = q1.x - q0.x;
    const sy = q1.y - q0.y;
    const d = rx * sy - ry * sx;
    if (@abs(d) < 1e-300) return null;
    const t = ((q0.x - p0.x) * sy - (q0.y - p0.y) * sx) / d;
    const u = ((q0.x - p0.x) * ry - (q0.y - p0.y) * rx) / d;
    if (t <= eps or t >= 1 - eps or u <= eps or u >= 1 - eps) return null;
    return t;
}

/// How a tile lies on the area.
const Lies = enum { outside, whole, cut };

fn classify(ar: *const Area, tile: []const Point) Lies {
    const b = polyBox(tile);
    if (!ar.overlaps(b)) return .outside;
    const C = struct {
        ar: *const Area,
        tile: []const Point,
        hit: bool = false,
        fn f(c: *@This(), si: u32) void {
            if (c.hit) return;
            const sg = c.ar.segs[si];
            // A vertex of the area inside the tile (strictly).
            var all = true;
            const n = c.tile.len;
            const scale = @max(@abs(c.tile[1].x - c.tile[0].x), @abs(c.tile[1].y - c.tile[0].y));
            const e = 1e-9 * @max(scale * scale, 1e-30);
            for (0..n) |k| if (cross(c.tile[k], c.tile[(k + 1) % n], sg[0]) <= e) {
                all = false;
                break;
            };
            if (all) {
                c.hit = true;
                return;
            }
            for (0..n) |k| if (crossAt(c.tile[k], c.tile[(k + 1) % n], sg[0], sg[1], 1e-9) != null) {
                c.hit = true;
                return;
            };
        }
    };
    var c: C = .{ .ar = ar, .tile = tile };
    ar.near(b, &c, C.f);
    if (c.hit) return .cut;
    // No crossing: the area's edge may still run along the tile's edges
    // or through its corners (a pattern lined up with it). Its centre and
    // a point just inside each corner say which side each part is on.
    var m: Point = .{ .x = 0, .y = 0 };
    for (tile) |p| {
        m.x += p.x;
        m.y += p.y;
    }
    const nf: f64 = @floatFromInt(tile.len);
    m = .{ .x = m.x / nf, .y = m.y / nf };
    var in: usize = @intFromBool(ar.inside(m));
    for (tile) |p| {
        if (ar.inside(lerp(p, m, 1e-6))) in += 1;
    }
    return if (in == tile.len + 1) .whole else if (in == 0) .outside else .cut;
}

/// The polygons of `o`, flattened, each with the area on its left.
fn flatAreas(a: Allocator, o: Outline, tol: f64) Allocator.Error![][]Point {
    var polys: std.ArrayList([]Point) = .empty;
    for (o.contours) |c| {
        const p = try grow.flatten(a, c, tol);
        if (p.len >= 3) try polys.append(a, p);
    }
    // Depth: how many others hold it; even ones anticlockwise.
    for (polys.items, 0..) |p, i| {
        var depth: usize = 0;
        for (polys.items, 0..) |q, k| if (k != i and insidePoly(q, p[0])) {
            depth += 1;
        };
        const ccw = signedArea(p) > 0;
        if (ccw != (depth % 2 == 0)) std.mem.reverse(Point, p);
    }
    return polys.items;
}

fn insidePoly(p: []const Point, q: Point) bool {
    var in = false;
    for (p, 0..) |a, i| {
        const b = p[(i + 1) % p.len];
        if ((a.y > q.y) != (b.y > q.y)) {
            const x = a.x + (q.y - a.y) * (b.x - a.x) / (b.y - a.y);
            if (x > q.x) in = !in;
        }
    }
    return in;
}

fn signedArea(p: []const Point) f64 {
    var s: f64 = 0;
    for (p, 0..) |a, i| {
        const b = p[(i + 1) % p.len];
        s += a.x * b.y - b.x * a.y;
    }
    return s / 2;
}

/// The area `polys` (each with it on its left) brought in by `d`: the
/// holes of its complement (in a box round it) grown by `d`.
fn inset(a: Allocator, polys: []const []Point, d: f64, tol: f64) Allocator.Error![][]Point {
    var box: Box = .empty;
    for (polys) |p| box = box.join(polyBox(p));
    const g = @max(box.width(), box.height()) + 4 * d + 1;
    var cs: std.ArrayList(Contour) = .empty;
    const frame = [_]Point{ .{ .x = box.x0 - g, .y = box.y0 - g }, .{ .x = box.x1 + g, .y = box.y0 - g }, .{ .x = box.x1 + g, .y = box.y1 + g }, .{ .x = box.x0 - g, .y = box.y1 + g } };
    try cs.append(a, .{ .segments = try lines(a, &frame, false) });
    for (polys) |p| try cs.append(a, .{ .segments = try lines(a, p, true) });
    const grown = try grow.grow(a, .{ .contours = cs.items }, d, tol);
    var out: std.ArrayList([]Point) = .empty;
    for (grown.contours) |c| {
        var pts = try a.alloc(Point, c.segments.len);
        for (c.segments, 0..) |sg, i| pts[i] = sg.start();
        // The frame's own loop, grown: not part of the area.
        const b = polyBox(pts);
        if (b.x0 < box.x0 - g / 2) continue;
        if (pts.len < 3) continue;
        // Reversed: the complement's holes face the other way.
        std.mem.reverse(Point, pts);
        try out.append(a, pts);
    }
    return out.items;
}

/// A closed polygon as line segments (reversed: backwards).
fn lines(a: Allocator, p: []const Point, reversed: bool) Allocator.Error![]Segment {
    const n = p.len;
    const segs = try a.alloc(Segment, n);
    for (0..n) |i| {
        segs[i] = if (reversed)
            .{ .line = .{ p[(n - i) % n], p[(2 * n - i - 1) % n] } }
        else
            .{ .line = .{ p[i], p[(i + 1) % n] } };
    }
    return segs;
}

/// An edge's key: its ends rounded, smaller first, so tiles sharing it
/// find it once.
const Key = struct { a: [2]i64, b: [2]i64 };

fn keyOf(p: Point, q: Point, unit: f64) Key {
    const P = struct {
        fn r(x: Point, u: f64) [2]i64 {
            return .{ @intFromFloat(@round(x.x / u)), @intFromFloat(@round(x.y / u)) };
        }
    };
    const kp = P.r(p, unit);
    const kq = P.r(q, unit);
    const first = kp[0] < kq[0] or (kp[0] == kq[0] and kp[1] <= kq[1]);
    return if (first) .{ .a = kp, .b = kq } else .{ .a = kq, .b = kp };
}

/// Fills `outline` (even-odd) with tiles (see the file's comment).
/// Allocated from `a` (an arena suits).
pub fn tessellate(a: Allocator, outline: Outline, o: Options) Error!Result {
    const t = tilingFor(o.sides) orelse return error.BadTiling;
    if (!(o.spacing > 0) or !std.math.isFinite(o.spacing)) return error.BadTiling;
    var polys = try flatAreas(a, outline, o.tol);
    if (polys.len == 0) return .{};
    if (o.margin > 0) polys = try inset(a, polys, o.margin, o.tol);
    if (polys.len == 0) return .{};
    var ar = try Area.init(a, polys, o.spacing);

    // Lattice points to try: the area's box in lattice steps, padded.
    const c = @cos(o.angle) * o.spacing;
    const s = @sin(o.angle) * o.spacing;
    const U: Point = .{ .x = c * t.u.x - s * t.u.y, .y = s * t.u.x + c * t.u.y };
    const V: Point = .{ .x = c * t.v.x - s * t.v.y, .y = s * t.v.x + c * t.v.y };
    const det = U.x * V.y - U.y * V.x;
    var lo = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
    var hi = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
    const corners = [_]Point{ .{ .x = ar.box.x0, .y = ar.box.y0 }, .{ .x = ar.box.x1, .y = ar.box.y0 }, .{ .x = ar.box.x1, .y = ar.box.y1 }, .{ .x = ar.box.x0, .y = ar.box.y1 } };
    for (corners) |q| {
        const dx = q.x - o.origin.x;
        const dy = q.y - o.origin.y;
        const i = (dx * V.y - dy * V.x) / det;
        const j = (U.x * dy - U.y * dx) / det;
        lo = .{ @min(lo[0], i), @min(lo[1], j) };
        hi = .{ @max(hi[0], i), @max(hi[1], j) };
    }
    const ia: i64 = @intFromFloat(@floor(lo[0]) - 2);
    const ib: i64 = @intFromFloat(@ceil(hi[0]) + 2);
    const ja: i64 = @intFromFloat(@floor(lo[1]) - 2);
    const jb: i64 = @intFromFloat(@ceil(hi[1]) + 2);

    var res: Result = .{};
    // Edges by key: whether some tile holding it is cut (so it is cut too).
    var seen: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    var edges: std.ArrayList(struct { p: Point, q: Point, cut: bool }) = .empty;
    var cells: std.ArrayList(Outline) = .empty;
    var places: std.ArrayList(Place) = .empty;
    const unit = o.spacing * 1e-7;
    var buf: [8]Point = undefined;
    var j = ja;
    outer: while (j <= jb) : (j += 1) {
        var i = ia;
        while (i <= ib) : (i += 1) {
            for (0..t.tiles.len) |k| {
                const tile = placeTile(t, o, i, j, k, &buf);
                const lies = classify(&ar, tile);
                if (lies == .outside or (lies == .cut and o.whole)) continue;
                if (res.tiles >= o.max_tiles) {
                    res.capped = true;
                    break :outer;
                }
                res.tiles += 1;
                if (lies == .whole) res.whole += 1;
                var m: Point = .{ .x = 0, .y = 0 };
                for (tile) |p| {
                    m.x += p.x;
                    m.y += p.y;
                }
                const nf: f64 = @floatFromInt(tile.len);
                try places.append(a, .{ .i = i, .j = j, .k = @intCast(k), .centre = .{ .x = m.x / nf, .y = m.y / nf }, .angle = o.angle + @as(f64, if (k == 1) std.math.pi else 0), .whole = lies == .whole });
                for (tile, 0..) |p, n| {
                    const q = tile[(n + 1) % tile.len];
                    const gop = try seen.getOrPut(a, keyOf(p, q, unit));
                    if (!gop.found_existing) {
                        gop.value_ptr.* = @intCast(edges.items.len);
                        try edges.append(a, .{ .p = p, .q = q, .cut = lies == .cut });
                    } else if (lies == .cut) edges.items[gop.value_ptr.*].cut = true;
                }
                if (o.cells) {
                    const cs = try a.alloc(Contour, 1);
                    cs[0] = .{ .segments = try lines(a, try a.dupe(Point, tile), false) };
                    const cell: Outline = .{ .contours = cs };
                    if (lies == .whole) {
                        try cells.append(a, cell);
                    } else {
                        const cut = boolean.clip(a, &.{cell}, try areaOutline(a, polys)) catch continue;
                        try cells.appendSlice(a, cut);
                    }
                }
            }
        }
    }

    // Edges of cut tiles cut to the area: split where the area's edge
    // crosses them, the parts whose middles are inside kept.
    var out: std.ArrayList(Segment) = .empty;
    var ts: std.ArrayList(f64) = .empty;
    for (edges.items) |e| {
        if (!e.cut) {
            try out.append(a, .{ .line = .{ e.p, e.q } });
            continue;
        }
        ts.clearRetainingCapacity();
        try ts.append(a, 0);
        try ts.append(a, 1);
        const C = struct {
            ar: *const Area,
            p: Point,
            q: Point,
            ts: *std.ArrayList(f64),
            al: Allocator,
            failed: bool = false,
            fn f(cx: *@This(), si: u32) void {
                const sg = cx.ar.segs[si];
                if (crossAt(cx.p, cx.q, sg[0], sg[1], -1e-12)) |tt| cx.ts.append(cx.al, std.math.clamp(tt, 0, 1)) catch {
                    cx.failed = true;
                };
            }
        };
        var cx: C = .{ .ar = &ar, .p = e.p, .q = e.q, .ts = &ts, .al = a };
        ar.near(polyBox(&.{ e.p, e.q }), &cx, C.f);
        if (cx.failed) return error.OutOfMemory;
        std.mem.sort(f64, ts.items, {}, std.sort.asc(f64));
        var run_from: ?f64 = null;
        for (ts.items[0 .. ts.items.len - 1], ts.items[1..]) |ta, tb| {
            if (tb - ta < 1e-12) continue;
            const tm = (ta + tb) / 2;
            const in = ar.inside(lerp(e.p, e.q, tm));
            if (in) {
                if (run_from == null) run_from = ta;
            } else if (run_from) |rf| {
                try out.append(a, .{ .line = .{ lerp(e.p, e.q, rf), lerp(e.p, e.q, ta) } });
                run_from = null;
            }
        }
        if (run_from) |rf| try out.append(a, .{ .line = .{ lerp(e.p, e.q, rf), e.q } });
    }
    res.edges = out.items;
    res.cells = cells.items;
    res.places = places.items;
    if (o.margin > 0 and !o.whole and res.tiles > res.whole) {
        const rim = try a.alloc(Contour, polys.len);
        for (polys, rim) |p, *r| r.* = .{ .segments = try lines(a, p, false) };
        res.rim = rim;
    }
    return res;
}

fn areaOutline(a: Allocator, polys: []const []Point) Allocator.Error!Outline {
    const cs = try a.alloc(Contour, polys.len);
    for (polys, cs) |p, *c| c.* = .{ .segments = try lines(a, p, false) };
    return .{ .contours = cs };
}

fn lerp(p: Point, q: Point, t: f64) Point {
    return .{ .x = p.x + (q.x - p.x) * t, .y = p.y + (q.y - p.y) * t };
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn rect(a: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) !Outline {
    const p = [_]Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
    const cs = try a.alloc(Contour, 1);
    cs[0] = .{ .segments = try lines(a, &p, false) };
    return .{ .contours = cs };
}

fn totalLength(segs: []const Segment) f64 {
    var l: f64 = 0;
    for (segs) |sg| l += std.math.hypot(sg.line[1].x - sg.line[0].x, sg.line[1].y - sg.line[0].y);
    return l;
}

test "squares in a square: edges shared once, cut or whole only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sq = try rect(a, 0, 0, 30, 30);
    // Tiles 10 apart, one centred at (5, 5): exactly 3 × 3, all whole.
    const r = try tessellate(a, sq, .{ .sides = 4, .spacing = 10, .origin = .{ .x = 5, .y = 5 } });
    try testing.expectEqual(@as(usize, 9), r.tiles);
    try testing.expectEqual(@as(usize, 9), r.whole);
    // 4 lines of 3 edges each way: 24 edges, each once.
    try testing.expectEqual(@as(usize, 24), r.edges.len);
    try testing.expectEqual(@as(usize, 9), r.places.len);
    try testing.expectApproxEqAbs(5, r.places[0].centre.x, 1e-9);
    try testing.expectApproxEqAbs(240, totalLength(r.edges), 1e-9);
    // Offset by half a tile: 2 × 2 whole, 16 tiles in all when cut.
    const w = try tessellate(a, sq, .{ .sides = 4, .spacing = 10, .origin = .{ .x = 0, .y = 0 }, .whole = true });
    try testing.expectEqual(@as(usize, 4), w.tiles);
    const cut = try tessellate(a, sq, .{ .sides = 4, .spacing = 10, .origin = .{ .x = 0, .y = 0 }, .cells = true });
    try testing.expectEqual(@as(usize, 16), cut.tiles);
    // Inside lines only: x = 5, 15, 25 and y the same, 30 long each.
    try testing.expectApproxEqAbs(180, totalLength(cut.edges), 1e-6);
    var area: f64 = 0;
    for (cut.cells) |cl| for (cl.contours) |cc| for (cc.segments) |sg| {
        area += sg.areaTerm();
    };
    try testing.expectApproxEqAbs(900, @abs(area), 1e-6);
}

test "hexagons and triangles: neighbours a spacing apart, a margin kept clear" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try rect(a, -50, -50, 50, 50);
    for ([_]u32{ 3, 6 }) |n| {
        const r = try tessellate(a, big, .{ .sides = n, .spacing = 7, .angle = 0.3, .origin = .{ .x = 1, .y = 2 }, .margin = 5 });
        try testing.expect(r.tiles > 50);
        try testing.expect(r.rim.len == 1);
        // Nothing inside the margin.
        for (r.edges) |sg| for (sg.line) |p| {
            try testing.expect(@abs(p.x) <= 45 + 1e-6 and @abs(p.y) <= 45 + 1e-6);
        };
        // Every whole tile's edge has the tiling's side.
        const side: f64 = if (n == 3) 7.0 * r3 else 7.0 / r3;
        var full: usize = 0;
        for (r.edges) |sg| {
            const l = std.math.hypot(sg.line[1].x - sg.line[0].x, sg.line[1].y - sg.line[0].y);
            try testing.expect(l <= side + 1e-9);
            if (@abs(l - side) < 1e-9) full += 1;
        }
        try testing.expect(full > r.edges.len / 2);
    }
    try testing.expectError(error.BadTiling, tessellate(a, big, .{ .sides = 5 }));
    // Lined up so the edge runs through tiles' corners: nothing past it.
    const lined = try rect(a, -62, -15, -27, 15);
    const r = try tessellate(a, lined, .{ .sides = 6, .spacing = 6, .origin = .{ .x = -50, .y = 0 } });
    for (r.edges) |sg| for (sg.line) |p| try testing.expect(p.x >= -62 - 1e-9);
}

test "a ring: tiles kept out of its hole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf1: [4]Segment = undefined;
    var buf2: [4]Segment = undefined;
    const cs = try a.alloc(Contour, 2);
    cs[0] = .{ .segments = try a.dupe(Segment, root.arc(.{ .x = 0, .y = 0 }, 30, 0, 2 * std.math.pi, &buf1)) };
    cs[1] = .{ .segments = try a.dupe(Segment, root.arc(.{ .x = 0, .y = 0 }, 10, 0, 2 * std.math.pi, &buf2)) };
    const r = try tessellate(a, .{ .contours = cs }, .{ .sides = 6, .spacing = 4 });
    try testing.expect(r.tiles > 100);
    for (r.edges) |sg| {
        const m = lerp(sg.line[0], sg.line[1], 0.5);
        const d = std.math.hypot(m.x, m.y);
        try testing.expect(d >= 10 - 0.01 and d <= 30 + 0.01);
    }
}
