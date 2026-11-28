//! Tessellations in a sketch (the owner, 2026-11-28): a macro object
//! filling a closed path of the sketch's curves with tiles that share
//! their vertices (`geom.tessellate`). Its geometry
//! (`geometry.Tessellation`) holds the driving values; the path it fills
//! is kept here (`Outline`, in `Sketch.tilings`) as the pieces of curves
//! round it, so it follows them as the sketch changes. The tiles are
//! worked out each time from both, and kept in a small cache, since a
//! sketch is drawn and measured often between changes.

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");
const pieces = @import("pieces.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const Tessellation = root.geometry.Tessellation;
const tess = geom.tessellate;

/// The area a tessellation fills: the pieces of the closed path round it.
pub const Outline = struct {
    pieces: std.ArrayList(pieces.Piece) = .empty,
};

/// The sides allowed (`geom.tessellate.tilingFor`).
pub fn validSides(n: u32) bool {
    return tess.tilingFor(n) != null;
}

/// Adds a tessellation geometry filling the closed path `outline` (its
/// pieces, made lasting: `pieces.attach`), one tile centred at `c`, tiles
/// of `sides` `spacing` apart. Construction geometry: its edges are
/// output when inked, as any construction is.
pub fn add(s: *Sketch, a: Allocator, outline: []const pieces.Piece, c: Point, sides: u32, spacing: f64, whole: bool) root.Error!GeomId {
    if (!validSides(sides) or !(spacing > 0) or outline.len == 0) return error.WrongKind;
    var o: Outline = .{};
    try o.pieces.appendSlice(a, outline);
    try s.tilings.append(a, o);
    const t: Tessellation = .{
        .c = try s.pt(a, c, false),
        .spacing = try s.newVar(a, spacing, false),
        .angle = try s.newVar(a, 0, false),
        .margin = try s.newVar(a, 0, false),
        .sides = sides,
        .whole = whole,
        .outline = @intCast(s.tilings.items.len - 1),
    };
    return s.add(a, .{ .kind = .{ .tessellation = t }, .construction = true });
}

/// The area tessellation `t` fills now, as closed contours (null when its
/// path no longer closes: a curve of it removed, say).
pub fn area(s: *const Sketch, a: Allocator, t: Tessellation) Allocator.Error!?geom.Outline {
    if (t.outline >= s.tilings.items.len) return null;
    var segs: std.ArrayList(geom.Segment) = .empty;
    for (s.tilings.items[t.outline].pieces.items) |p| try pieces.appendSegments(s, a, p, &segs);
    if (segs.items.len == 0) return null;
    const ch = try Sketch.chain(a, segs.items);
    if (ch.contours.len == 0 or ch.open > 0) return null;
    return .{ .contours = ch.contours };
}

/// Its options for `geom.tessellate`, from the sketch's values.
pub fn options(s: *const Sketch, t: Tessellation) tess.Options {
    const v = s.vars.items;
    return .{ .sides = t.sides, .spacing = v[t.spacing], .angle = v[t.angle], .origin = s.val(t.c), .margin = @max(0, v[t.margin]), .whole = t.whole };
}

/// Its tiles in full (edges, rim, places; cells when `cells`), from `a`.
pub fn tiles(s: *const Sketch, a: Allocator, t: Tessellation, cells: bool) (Allocator.Error || tess.Error)!tess.Result {
    const ar = (try area(s, a, t)) orelse return .{};
    var o = options(s, t);
    o.cells = cells;
    return tess.tessellate(a, ar, o);
}

// The cache: a few recent results by what made them (the area's segments
// and the options), so drawing a sketch many times does not tile it
// again each time.
const Entry = struct { key: u64, segs: []geom.Segment };
/// A spin lock (the cache is touched briefly, rarely from two threads).
const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(l: *Lock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};
var cache_lock: Lock = .{};
var cache: [16]?Entry = @splat(null);
var cache_next: usize = 0;

fn hashOf(ar: geom.Outline, o: tess.Options) u64 {
    var h = std.hash.Wyhash.init(0x7e55);
    for (ar.contours) |c| h.update(std.mem.sliceAsBytes(c.segments));
    h.update(std.mem.asBytes(&o));
    return h.final();
}

/// Its edges (and rim) as drawn: what `Sketch.appendSegments` gives for it.
pub fn appendEdges(s: *const Sketch, a: Allocator, t: Tessellation, out: *std.ArrayList(geom.Segment)) Allocator.Error!void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const ar = (try area(s, sa, t)) orelse return;
    const o = options(s, t);
    if (tess.tilingFor(o.sides) == null or !(o.spacing > 0)) return;
    const key = hashOf(ar, o);
    {
        cache_lock.lock();
        defer cache_lock.unlock();
        for (cache) |e| if (e) |x| if (x.key == key) return out.appendSlice(a, x.segs);
    }
    const r = tess.tessellate(sa, ar, o) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    var all: std.ArrayList(geom.Segment) = .empty;
    try all.appendSlice(sa, r.edges);
    for (r.rim) |c| try all.appendSlice(sa, c.segments);
    try out.appendSlice(a, all.items);
    cache_lock.lock();
    defer cache_lock.unlock();
    const keep = std.heap.page_allocator.dupe(geom.Segment, all.items) catch return;
    if (cache[cache_next]) |old| std.heap.page_allocator.free(old.segs);
    cache[cache_next] = .{ .key = key, .segs = keep };
    cache_next = (cache_next + 1) % cache.len;
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

test "a tessellation in a sketch: fills a square of segments, follows it, its values drive it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    const sq = [4]GeomId{
        try s.addSegment(a, .{ .x = 0, .y = 0 }, .{ .x = 30, .y = 0 }, false),
        try s.addSegment(a, .{ .x = 30, .y = 0 }, .{ .x = 30, .y = 30 }, false),
        try s.addSegment(a, .{ .x = 30, .y = 30 }, .{ .x = 0, .y = 30 }, false),
        try s.addSegment(a, .{ .x = 0, .y = 30 }, .{ .x = 0, .y = 0 }, false),
    };
    var ps: [4]pieces.Piece = undefined;
    for (sq, &ps) |g, *p| p.* = .{ .geom = g };
    const g = try add(&s, a, &ps, .{ .x = 5, .y = 5 }, 4, 10, false);
    var segs: std.ArrayList(geom.Segment) = .empty;
    try s.appendSegments(a, s.geometry.items[g], &segs);
    try testing.expectEqual(@as(usize, 24), segs.items.len);
    // Its centre is a point the solver moves (half a tile over: cut ones).
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = g, .role = .centre }, .{ .geom = root.origin } } } });
    _ = try s.solve(a);
    const r = try tiles(&s, a, s.geometry.items[g].kind.tessellation, false);
    try testing.expectEqual(@as(usize, 16), r.tiles);
    try testing.expectEqual(@as(usize, 4), r.whole);
    // A clone holds its own outline.
    var c = try s.clone(a);
    try testing.expectEqual(@as(usize, 1), c.tilings.items.len);
    c.tilings.items[0].pieces.items[0].geom = 99;
    try testing.expectEqual(sq[0], s.tilings.items[0].pieces.items[0].geom);
}
