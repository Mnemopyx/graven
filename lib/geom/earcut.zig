//! Polygon triangulation by ear clipping, with holes: the earcut algorithm
//! (after Mapbox's earcut, ISC licence), with its z-order index for large
//! polygons. It uses only the polygon's own vertices, so a mesh built from
//! its triangles and walls along the same contours closes without cracks,
//! and it gives about one triangle per vertex.
//!
//! Vertices that lie exactly on the line through their neighbours may be
//! left unused: callers that need every vertex used drop such vertices
//! first (see `dropCollinear`).

const std = @import("std");
const Point = @import("root.zig").Point;
const Allocator = std.mem.Allocator;

const Node = struct {
    /// The vertex's index in the caller's points.
    i: u32,
    x: f64,
    y: f64,
    prev: *Node = undefined,
    next: *Node = undefined,
    z: u32 = 0,
    prev_z: ?*Node = null,
    next_z: ?*Node = null,
    steiner: bool = false,
};

const Ctx = struct {
    a: Allocator,
    out: Allocator,
    tris: *std.ArrayList([3]u32),
    min_x: f64 = 0,
    min_y: f64 = 0,
    inv_size: f64 = 0,

    fn emit(ctx: *Ctx, p: *const Node, q: *const Node, r: *const Node) Allocator.Error!void {
        try ctx.tris.append(ctx.out, .{ p.i, q.i, r.i });
    }
};

/// Triangles covering the polygon `outer` less `holes` (each a closed
/// ring, any direction, not crossing one another), as indices into the
/// rings' points taken in order: `outer` first, then each hole's.
/// Allocated from `a`.
pub fn triangulate(a: Allocator, outer: []const Point, holes: []const []const Point) Allocator.Error![]const [3]u32 {
    var tris: std.ArrayList([3]u32) = .empty;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var ctx: Ctx = .{ .a = arena.allocator(), .out = a, .tris = &tris };
    var outer_node = (try linkedList(&ctx, outer, 0, true)) orelse return tris.toOwnedSlice(a);
    if (outer_node.next == outer_node.prev) return tris.toOwnedSlice(a);
    var total: usize = outer.len;
    if (holes.len > 0) {
        var queue: std.ArrayList(*Node) = .empty;
        var base: u32 = @intCast(outer.len);
        for (holes) |h| {
            if (try linkedList(&ctx, h, base, false)) |list| {
                if (list == list.next) list.steiner = true;
                try queue.append(ctx.a, leftmost(list));
            }
            base += @intCast(h.len);
            total += h.len;
        }
        std.mem.sort(*Node, queue.items, {}, struct {
            fn lt(_: void, p: *Node, q: *Node) bool {
                return p.x < q.x;
            }
        }.lt);
        for (queue.items) |h| outer_node = try eliminateHole(&ctx, h, outer_node);
    }
    if (total > 80) {
        var x0 = outer[0].x;
        var y0 = outer[0].y;
        var x1 = x0;
        var y1 = y0;
        for (outer) |p| {
            x0 = @min(x0, p.x);
            y0 = @min(y0, p.y);
            x1 = @max(x1, p.x);
            y1 = @max(y1, p.y);
        }
        ctx.min_x = x0;
        ctx.min_y = y0;
        const size = @max(x1 - x0, y1 - y0);
        ctx.inv_size = if (size != 0) 32767 / size else 0;
    }
    try earcutLinked(&ctx, outer_node, 0);
    return tris.toOwnedSlice(a);
}

/// `ring` without repeated points (the closing one too) and without
/// vertices exactly on the line through their neighbours, as earcut would
/// drop them.
pub fn dropCollinear(a: Allocator, ring: []const Point) Allocator.Error![]const Point {
    var pts: std.ArrayList(Point) = .empty;
    for (ring) |p| {
        if (pts.items.len > 0 and pts.items[pts.items.len - 1].eql(p)) continue;
        try pts.append(a, p);
    }
    while (pts.items.len > 1 and pts.items[0].eql(pts.items[pts.items.len - 1])) pts.items.len -= 1;
    var changed = true;
    while (changed and pts.items.len >= 3) {
        changed = false;
        var i: usize = 0;
        while (i < pts.items.len and pts.items.len >= 3) {
            const n = pts.items.len;
            const p = pts.items[(i + n - 1) % n];
            const q = pts.items[i];
            const r = pts.items[(i + 1) % n];
            if (areaOf(p.x, p.y, q.x, q.y, r.x, r.y) == 0) {
                _ = pts.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
    }
    return pts.items;
}

fn linkedList(ctx: *Ctx, ring: []const Point, base: u32, clockwise: bool) Allocator.Error!?*Node {
    if (ring.len == 0) return null;
    var sum: f64 = 0;
    var j = ring.len - 1;
    for (ring, 0..) |p, i| {
        sum += (ring[j].x - p.x) * (p.y + ring[j].y);
        j = i;
    }
    var last: ?*Node = null;
    if (clockwise == (sum > 0)) {
        for (ring, 0..) |p, i| last = try insertNode(ctx, base + @as(u32, @intCast(i)), p, last);
    } else {
        var i = ring.len;
        while (i > 0) {
            i -= 1;
            last = try insertNode(ctx, base + @as(u32, @intCast(i)), ring[i], last);
        }
    }
    if (last) |l| if (equals(l, l.next)) {
        removeNode(l);
        last = l.next;
    };
    return last;
}

/// Drops repeated and collinear points from `start` round to `end`.
fn filterPoints(start_in: ?*Node, end_in: ?*Node) ?*Node {
    const start = start_in orelse return null;
    var end = end_in orelse start;
    var p = start;
    while (true) {
        var again = false;
        if (!p.steiner and (equals(p, p.next) or area(p.prev, p, p.next) == 0)) {
            removeNode(p);
            p = p.prev;
            end = p;
            if (p == p.next) break;
            again = true;
        } else p = p.next;
        if (!again and p == end) break;
    }
    return end;
}

fn earcutLinked(ctx: *Ctx, ear_in: ?*Node, pass: u2) Allocator.Error!void {
    var ear = ear_in orelse return;
    if (pass == 0 and ctx.inv_size != 0) indexCurve(ctx, ear);
    var stop = ear;
    while (ear.prev != ear.next) {
        const prev = ear.prev;
        const next = ear.next;
        if (if (ctx.inv_size != 0) isEarHashed(ctx, ear) else isEar(ear)) {
            try ctx.emit(prev, ear, next);
            removeNode(ear);
            ear = next.next;
            stop = next.next;
            continue;
        }
        ear = next;
        if (ear == stop) {
            switch (pass) {
                // Try again with repeats and collinear points gone; then
                // with local self-crossings cured; then by splitting.
                0 => try earcutLinked(ctx, filterPoints(ear, null), 1),
                1 => {
                    const cured = try cureLocalIntersections(ctx, filterPoints(ear, null).?);
                    try earcutLinked(ctx, cured, 2);
                },
                else => try splitEarcut(ctx, ear),
            }
            break;
        }
    }
}

fn isEar(ear: *Node) bool {
    const a = ear.prev;
    const b = ear;
    const c = ear.next;
    if (area(a, b, c) >= 0) return false;
    const x0 = @min(a.x, b.x, c.x);
    const y0 = @min(a.y, b.y, c.y);
    const x1 = @max(a.x, b.x, c.x);
    const y1 = @max(a.y, b.y, c.y);
    var p = c.next;
    while (p != a) {
        if (p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 and
            pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y) and area(p.prev, p, p.next) >= 0) return false;
        p = p.next;
    }
    return true;
}

fn isEarHashed(ctx: *Ctx, ear: *Node) bool {
    const a = ear.prev;
    const b = ear;
    const c = ear.next;
    if (area(a, b, c) >= 0) return false;
    const x0 = @min(a.x, b.x, c.x);
    const y0 = @min(a.y, b.y, c.y);
    const x1 = @max(a.x, b.x, c.x);
    const y1 = @max(a.y, b.y, c.y);
    const min_z = zOrder(ctx, x0, y0);
    const max_z = zOrder(ctx, x1, y1);
    const blocks = struct {
        fn f(q: *Node, aa: *Node, bb: *Node, cc: *Node, bx0: f64, by0: f64, bx1: f64, by1: f64) bool {
            return q != aa and q != cc and q.x >= bx0 and q.x <= bx1 and q.y >= by0 and q.y <= by1 and
                pointInTriangle(aa.x, aa.y, bb.x, bb.y, cc.x, cc.y, q.x, q.y) and area(q.prev, q, q.next) >= 0;
        }
    }.f;
    var p = ear.prev_z;
    var n = ear.next_z;
    while (p != null and p.?.z >= min_z and n != null and n.?.z <= max_z) {
        if (blocks(p.?, a, b, c, x0, y0, x1, y1)) return false;
        p = p.?.prev_z;
        if (blocks(n.?, a, b, c, x0, y0, x1, y1)) return false;
        n = n.?.next_z;
    }
    while (p != null and p.?.z >= min_z) {
        if (blocks(p.?, a, b, c, x0, y0, x1, y1)) return false;
        p = p.?.prev_z;
    }
    while (n != null and n.?.z <= max_z) {
        if (blocks(n.?, a, b, c, x0, y0, x1, y1)) return false;
        n = n.?.next_z;
    }
    return true;
}

fn cureLocalIntersections(ctx: *Ctx, start_in: *Node) Allocator.Error!?*Node {
    var start = start_in;
    var p = start;
    while (true) {
        const a = p.prev;
        const b = p.next.next;
        if (!equals(a, b) and intersects(a, p, p.next, b) and locallyInside(a, b) and locallyInside(b, a)) {
            try ctx.emit(a, p, b);
            removeNode(p);
            removeNode(p.next);
            p = b;
            start = b;
        }
        p = p.next;
        if (p == start) break;
    }
    return filterPoints(p, null);
}

fn splitEarcut(ctx: *Ctx, start: *Node) Allocator.Error!void {
    var a = start;
    while (true) {
        var b = a.next.next;
        while (b != a.prev) {
            if (a.i != b.i and isValidDiagonal(a, b)) {
                var c = try splitPolygon(ctx, a, b);
                const a2 = filterPoints(a, a.next);
                c = filterPoints(c, c.next).?;
                try earcutLinked(ctx, a2, 0);
                try earcutLinked(ctx, c, 0);
                return;
            }
            b = b.next;
        }
        a = a.next;
        if (a == start) break;
    }
}

/// Joins a hole to the outer ring by a bridge to a vertex it can see.
fn eliminateHole(ctx: *Ctx, hole: *Node, outer: *Node) Allocator.Error!*Node {
    const bridge = findHoleBridge(hole, outer) orelse return outer;
    const reverse = try splitPolygon(ctx, bridge, hole);
    _ = filterPoints(reverse, reverse.next);
    return filterPoints(bridge, bridge.next).?;
}

fn findHoleBridge(hole: *Node, outer: *Node) ?*Node {
    var p = outer;
    const hx = hole.x;
    const hy = hole.y;
    var qx = -std.math.inf(f64);
    var m: ?*Node = null;
    while (true) {
        if (hy <= p.y and hy >= p.next.y and p.next.y != p.y) {
            const x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y);
            if (x <= hx and x > qx) {
                qx = x;
                m = if (p.x < p.next.x) p else p.next;
                if (x == hx) return m;
            }
        }
        p = p.next;
        if (p == outer) break;
    }
    var best = m orelse return null;
    const stop = best;
    const mx = best.x;
    const my = best.y;
    var tan_min = std.math.inf(f64);
    p = best;
    while (true) {
        if (hx >= p.x and p.x >= mx and hx != p.x and
            pointInTriangle(if (hy < my) hx else qx, hy, mx, my, if (hy < my) qx else hx, hy, p.x, p.y))
        {
            const tan = @abs(hy - p.y) / (hx - p.x);
            if (locallyInside(p, hole) and (tan < tan_min or (tan == tan_min and (p.x > best.x or (p.x == best.x and sectorContainsSector(best, p)))))) {
                best = p;
                tan_min = tan;
            }
        }
        p = p.next;
        if (p == stop) break;
    }
    return best;
}

fn sectorContainsSector(m: *Node, p: *Node) bool {
    return area(m.prev, m, p.prev) < 0 and area(p.next, m, m.next) < 0;
}

fn indexCurve(ctx: *Ctx, start: *Node) void {
    var p = start;
    while (true) {
        if (p.z == 0) p.z = zOrder(ctx, p.x, p.y);
        p.prev_z = p.prev;
        p.next_z = p.next;
        p = p.next;
        if (p == start) break;
    }
    p.prev_z.?.next_z = null;
    p.prev_z = null;
    _ = sortLinked(p);
}

/// Merge sort of the z list (Simon Tatham's).
fn sortLinked(list_in: *Node) *Node {
    var list: ?*Node = list_in;
    var in_size: usize = 1;
    while (true) {
        var p = list;
        list = null;
        var tail: ?*Node = null;
        var merges: usize = 0;
        while (p) |pp| {
            _ = pp;
            merges += 1;
            var q = p;
            var p_size: usize = 0;
            for (0..in_size) |_| {
                p_size += 1;
                q = q.?.next_z;
                if (q == null) break;
            }
            var q_size = in_size;
            while (p_size > 0 or (q_size > 0 and q != null)) {
                var e: *Node = undefined;
                if (p_size != 0 and (q_size == 0 or q == null or p.?.z <= q.?.z)) {
                    e = p.?;
                    p = p.?.next_z;
                    p_size -= 1;
                } else {
                    e = q.?;
                    q = q.?.next_z;
                    q_size -= 1;
                }
                if (tail) |t| t.next_z = e else list = e;
                e.prev_z = tail;
                tail = e;
            }
            p = q;
        }
        tail.?.next_z = null;
        in_size *= 2;
        if (merges <= 1) break;
    }
    return list.?;
}

fn zOrder(ctx: *Ctx, xf: f64, yf: f64) u32 {
    var x: u32 = @intFromFloat(@max(0, (xf - ctx.min_x) * ctx.inv_size));
    var y: u32 = @intFromFloat(@max(0, (yf - ctx.min_y) * ctx.inv_size));
    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;
    y = (y | (y << 8)) & 0x00FF00FF;
    y = (y | (y << 4)) & 0x0F0F0F0F;
    y = (y | (y << 2)) & 0x33333333;
    y = (y | (y << 1)) & 0x55555555;
    return x | (y << 1);
}

fn leftmost(start: *Node) *Node {
    var p = start;
    var best = start;
    while (true) {
        if (p.x < best.x or (p.x == best.x and p.y < best.y)) best = p;
        p = p.next;
        if (p == start) break;
    }
    return best;
}

fn pointInTriangle(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, px: f64, py: f64) bool {
    return (cx - px) * (ay - py) >= (ax - px) * (cy - py) and
        (ax - px) * (by - py) >= (bx - px) * (ay - py) and
        (bx - px) * (cy - py) >= (cx - px) * (by - py);
}

fn isValidDiagonal(a: *Node, b: *Node) bool {
    return a.next.i != b.i and a.prev.i != b.i and !intersectsPolygon(a, b) and
        ((locallyInside(a, b) and locallyInside(b, a) and middleInside(a, b) and
        (area(a.prev, a, b.prev) != 0 or area(a, b.prev, b) != 0)) or
        (equals(a, b) and area(a.prev, a, a.next) > 0 and area(b.prev, b, b.next) > 0));
}

fn area(p: *const Node, q: *const Node, r: *const Node) f64 {
    return areaOf(p.x, p.y, q.x, q.y, r.x, r.y);
}

fn areaOf(px: f64, py: f64, qx: f64, qy: f64, rx: f64, ry: f64) f64 {
    return (qy - py) * (rx - qx) - (qx - px) * (ry - qy);
}

fn equals(p: *const Node, q: *const Node) bool {
    return p.x == q.x and p.y == q.y;
}

fn sign(v: f64) i2 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

fn onSegment(p: *const Node, q: *const Node, r: *const Node) bool {
    return q.x <= @max(p.x, r.x) and q.x >= @min(p.x, r.x) and q.y <= @max(p.y, r.y) and q.y >= @min(p.y, r.y);
}

fn intersects(p1: *const Node, q1: *const Node, p2: *const Node, q2: *const Node) bool {
    const o1 = sign(area(p1, q1, p2));
    const o2 = sign(area(p1, q1, q2));
    const o3 = sign(area(p2, q2, p1));
    const o4 = sign(area(p2, q2, q1));
    if (o1 != o2 and o3 != o4) return true;
    if (o1 == 0 and onSegment(p1, p2, q1)) return true;
    if (o2 == 0 and onSegment(p1, q2, q1)) return true;
    if (o3 == 0 and onSegment(p2, p1, q2)) return true;
    if (o4 == 0 and onSegment(p2, q1, q2)) return true;
    return false;
}

fn intersectsPolygon(a: *Node, b: *Node) bool {
    var p = a;
    while (true) {
        if (p.i != a.i and p.next.i != a.i and p.i != b.i and p.next.i != b.i and intersects(p, p.next, a, b)) return true;
        p = p.next;
        if (p == a) break;
    }
    return false;
}

fn locallyInside(a: *const Node, b: *const Node) bool {
    return if (area(a.prev, a, a.next) < 0)
        area(a, b, a.next) >= 0 and area(a, a.prev, b) >= 0
    else
        area(a, b, a.prev) < 0 or area(a, a.next, b) < 0;
}

fn middleInside(a: *Node, b: *Node) bool {
    var p = a;
    var inside = false;
    const px = (a.x + b.x) / 2;
    const py = (a.y + b.y) / 2;
    while (true) {
        if (((p.y > py) != (p.next.y > py)) and p.next.y != p.y and (px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x)) inside = !inside;
        p = p.next;
        if (p == a) break;
    }
    return inside;
}

/// Links a to b with a bridge, splitting the ring in two: a's side keeps
/// a and b, the returned node starts the other side (copies of b and a).
fn splitPolygon(ctx: *Ctx, a: *Node, b: *Node) Allocator.Error!*Node {
    const a2 = try ctx.a.create(Node);
    const b2 = try ctx.a.create(Node);
    return link(a, b, a2, b2);
}

fn link(a: *Node, b: *Node, a2: *Node, b2: *Node) *Node {
    a2.* = .{ .i = a.i, .x = a.x, .y = a.y };
    b2.* = .{ .i = b.i, .x = b.x, .y = b.y };
    const an = a.next;
    const bp = b.prev;
    a.next = b;
    b.prev = a;
    a2.next = an;
    an.prev = a2;
    b2.next = a2;
    a2.prev = b2;
    bp.next = b2;
    b2.prev = bp;
    return b2;
}

fn insertNode(ctx: *Ctx, i: u32, p: Point, last: ?*Node) Allocator.Error!*Node {
    const n = try ctx.a.create(Node);
    n.* = .{ .i = i, .x = p.x, .y = p.y };
    if (last) |l| {
        n.next = l.next;
        n.prev = l;
        l.next.prev = n;
        l.next = n;
    } else {
        n.prev = n;
        n.next = n;
    }
    return n;
}

fn removeNode(p: *Node) void {
    p.next.prev = p.prev;
    p.prev.next = p.next;
    if (p.prev_z) |pz| pz.next_z = p.next_z;
    if (p.next_z) |nz| nz.prev_z = p.prev_z;
}

const testing = std.testing;

fn triArea(pts: []const Point, t: [3]u32) f64 {
    const a = pts[t[0]];
    const b = pts[t[1]];
    const c = pts[t[2]];
    return @abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2;
}

test "a square with a square hole: n + 2h - 2 triangles covering its area" {
    const outer = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const hole = [_]Point{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 7 }, .{ .x = 7, .y = 7 }, .{ .x = 7, .y = 3 } };
    const tris = try triangulate(testing.allocator, &outer, &.{&hole});
    defer testing.allocator.free(tris);
    try testing.expectEqual(@as(usize, 8), tris.len);
    const all = outer ++ hole;
    var sum: f64 = 0;
    for (tris) |t| sum += triArea(&all, t);
    try testing.expectApproxEqAbs(@as(f64, 84), sum, 1e-9);
}

test "many holes (the z-order index in use) and a concave outline" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A comb: 20 teeth, concave.
    var outer: std.ArrayList(Point) = .empty;
    try outer.append(a, .{ .x = 0, .y = 0 });
    try outer.append(a, .{ .x = 200, .y = 0 });
    var k: usize = 20;
    while (k > 0) {
        k -= 1;
        const x: f64 = @floatFromInt(k * 10);
        try outer.append(a, .{ .x = x + 10, .y = 60 });
        try outer.append(a, .{ .x = x + 5, .y = 60 });
        try outer.append(a, .{ .x = x + 5, .y = 40 });
        try outer.append(a, .{ .x = x, .y = 40 });
    }
    // 40 small diamond holes in the body.
    var holes: std.ArrayList([]const Point) = .empty;
    var all: std.ArrayList(Point) = .empty;
    try all.appendSlice(a, outer.items);
    var hole_area: f64 = 0;
    for (0..40) |i| {
        const cx: f64 = 2.5 + @as(f64, @floatFromInt(i)) * 5;
        const h = try a.dupe(Point, &.{ .{ .x = cx, .y = 18 }, .{ .x = cx + 1, .y = 20 }, .{ .x = cx, .y = 22 }, .{ .x = cx - 1, .y = 20 } });
        try holes.append(a, h);
        try all.appendSlice(a, h);
        hole_area += 4;
    }
    const tris = try triangulate(a, outer.items, holes.items);
    try testing.expectEqual(all.items.len + 2 * 40 - 2, tris.len);
    var sum: f64 = 0;
    for (tris) |t| sum += triArea(all.items, t);
    // Body 200 x 40, teeth 20 x (5 x 20), less the holes.
    try testing.expectApproxEqAbs(200 * 40 + 20 * 100 - hole_area, sum, 1e-6);
}
