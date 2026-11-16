//! Setting an expression on its ground: the top row's objects laid out,
//! broken into lines at the break candidates (breaks.zig) so each fits an
//! open stretch of a piece, each line aligned there, and every item moved
//! from expression space onto the piece's baseline path through the
//! ground's frame at its place along it. On a curved path each glyph (and
//! each rule) stands on the path where it falls, turned to its direction;
//! the turns objects have of their own came first, in expression space.
//!
//! Also here: the exact outlines of what was set (glyphs grown by their
//! weight, rules as polygons), mm in the ground's frame.

const std = @import("std");
const geom = @import("graven_geom");
const ex = @import("expr.zig");
const cascade = @import("cascade.zig");
const ground_mod = @import("ground.zig");
const layout = @import("layout.zig");
const breaks = @import("breaks.zig");
const faces_mod = @import("faces.zig");
const param = @import("param.zig");

const Allocator = std.mem.Allocator;
const Affine = geom.Affine;
const Point = geom.Point;
const Id = ex.Id;
const Item = layout.Item;
const Laid = layout.Laid;
const Resolver = cascade.Resolver;

pub const Line = struct {
    /// The piece it is set on.
    piece: usize,
    /// The top row's objects it holds: [first, end).
    first: usize,
    end: usize,
    /// Where it starts along the piece, and its width, mm.
    at: f64,
    width: f64,
};

pub const Set = struct {
    /// Every glyph and rule, in the ground's frame.
    items: []const Item,
    lines: []const Line,
    /// Some line did not fit where it was put (no break left it room, or
    /// the ground ran out).
    overflow: bool,
    missing: []const layout.Missing,
};

pub const Options = struct {
    editing: bool = false,
};

/// Sets the expression `r` resolves on `g`, its faces `faces`; from `a`
/// (an arena suits).
pub fn set(a: Allocator, r: *const Resolver, faces: faces_mod.FaceSet, g: ground_mod.Ground, opts: Options) !Set {
    const e = r.e;
    const top = e.node(e.root).items.items;
    var lay: layout.Layout = .{ .a = a, .r = r, .faces = faces, .editing = opts.editing };
    const first = g.piece(0, 0) orelse return .{ .items = &.{}, .lines = &.{}, .overflow = top.len > 0, .missing = &.{} };
    const cap = first.cap;

    // Each top object laid out alone, and the space before it.
    const laid = try a.alloc(Laid, top.len);
    const before = try a.alloc(f64, top.len);
    const script = r.context(e.root).script_level > 0;
    for (top, laid, before, 0..) |id, *l, *b, k| {
        l.* = try lay.lay(id, cap);
        b.* = if (k == 0) 0 else lay.space(id, laid[k - 1].class, l.class, script) * cap;
    }
    const cands = try breaks.candidates(a, r);

    // Lines after the first may line up under the first relation: where
    // what follows it starts (see `continuation`).
    const cont = param.as(param.Continuation, r.get(e.root, .continuation));
    var under_relation: ?f64 = null;
    var indent: f64 = 0;

    var items: std.ArrayList(Item) = .empty;
    var lines: std.ArrayList(Line) = .empty;
    var overflow = false;
    var start: usize = 0;
    var pi: usize = 0;
    while (start < top.len) : (pi += 1) {
        const piece = g.piece(pi, 0) orelse {
            overflow = true;
            break;
        };
        // Of the ends that fit (at a break, or the expression's end; a
        // forced break ends the line there), the one whose cost and the
        // room it leaves empty add up least: a relation's break may win
        // over an operator's further on.
        var end: ?usize = null;
        var at: f64 = 0;
        var best: f64 = std.math.inf(f64);
        // A continuation's indent, unless nothing fits after it.
        var lead: f64 = if (start > 0) indent else 0;
        var ends: std.ArrayList(usize) = .empty;
        for (cands) |c| if (c.index > start) {
            try ends.append(a, c.index);
            if (c.forced) break;
        };
        const forced_stop = for (cands) |c| {
            if (c.index > start and c.forced) break true;
        } else false;
        if (!forced_stop) try ends.append(a, top.len);
        if (lead > 0 and piece.fit(lead, width(laid, before, start, ends.items[0])) == null) lead = 0;
        for (ends.items) |en| {
            const w = width(laid, before, start, en);
            const x = piece.fit(lead, w) orelse break;
            const room = @max(piece.openLength() - lead, 1e-9);
            const unused = std.math.clamp(1 - w / room, 0, 1);
            const cost: f64 = if (en == top.len) 0 else for (cands) |c| {
                if (c.index == en) break c.cost;
            } else 0;
            const score = cost + 1000 * unused * unused;
            if (score <= best) {
                best = score;
                end = en;
                at = x;
            }
        }
        const en = end orelse blk: {
            // Nothing fits: the shortest line, flagged.
            overflow = true;
            at = if (piece.open.len > 0) piece.open[0].lo else 0;
            break :blk ends.items[0];
        };
        const w = width(laid, before, start, en);
        // Aligned in the open stretch it starts in.
        const span_hi = for (piece.open) |o| {
            if (at >= o.lo - 1e-9 and at <= o.hi + 1e-9) break o.hi;
        } else piece.length;
        const free = @max(0, span_hi - at - w);
        const shift: f64 = if (start > 0 and cont != .own) 0 else switch (piece.alignment) {
            .start, .justify => 0,
            .centre => free / 2,
            .end => free,
        };
        try lines.append(a, .{ .piece = pi, .first = start, .end = en, .at = at + shift, .width = w });
        // Onto the path.
        var x = at + shift;
        for (start..en) |k| {
            if (k > start) x += before[k];
            for (laid[k].items.items) |it| try items.append(a, onPath(piece, it, x));
            x += laid[k].width;
            // The first line's first relation: what follows starts here.
            if (start == 0 and under_relation == null and e.node(top[k]).kind == .relation and k + 1 < top.len) {
                under_relation = x + before[k + 1] - (at + shift);
            }
        }
        if (start == 0) indent = switch (cont) {
            .own => 0,
            .indent => 2 * cap,
            .relation => under_relation orelse 2 * cap,
        };
        start = en;
    }
    return .{ .items = items.items, .lines = lines.items, .overflow = overflow, .missing = lay.missing.items };
}

/// The width of top objects [from, to) set together (the space before the
/// first dropped: a line starts there).
fn width(laid: []const Laid, before: []const f64, from: usize, to: usize) f64 {
    var w: f64 = 0;
    for (from..to) |k| w += laid[k].width + (if (k > from) before[k] else 0);
    return w;
}

/// The frame at distance `s` along a piece, as a transform from a local
/// space whose origin is that point (x along, y up).
fn frameAt(piece: ground_mod.Piece, s: f64) Affine {
    const f = piece.frame(s);
    return .{ .a = f.along.x, .b = f.along.y, .c = f.up.x, .d = f.up.y, .e = f.point.x, .f = f.point.y };
}

/// An item set `x` mm along the piece: moved onto the path at its own
/// place (a glyph's origin, a rule's middle), standing on the path there.
fn onPath(piece: ground_mod.Piece, it: Item, x: f64) Item {
    const anchor: f64 = switch (it) {
        .glyph => |g| g.m.e,
        .rule => |r| (r.corners[0].x + r.corners[2].x) / 2,
        .hole => |h| (h.corners[0].x + h.corners[2].x) / 2,
    };
    const m = Affine.translate(-anchor, 0).then(frameAt(piece, x + anchor));
    return switch (it) {
        .glyph => |g| .{ .glyph = .{ .face = g.face, .gid = g.gid, .m = g.m.then(m), .grow = g.grow, .object = g.object } },
        .rule => |r| .{ .rule = .{ .corners = .{ m.apply(r.corners[0]), m.apply(r.corners[1]), m.apply(r.corners[2]), m.apply(r.corners[3]) }, .object = r.object } },
        .hole => |h| .{ .hole = .{ .corners = .{ m.apply(h.corners[0]), m.apply(h.corners[1]), m.apply(h.corners[2]), m.apply(h.corners[3]) }, .object = h.object } },
    };
}

/// One exact outline per item (holes left out): a glyph's outline through
/// its transform, grown by its weight within `tol`; a rule as its polygon.
pub fn outlines(a: Allocator, items: []const Item, tol: f64) ![]geom.Outline {
    var out: std.ArrayList(geom.Outline) = .empty;
    for (items) |it| switch (it) {
        .glyph => |g| {
            const o = try g.face.outline(g.gid);
            if (o.contours.len == 0) continue;
            const t = try o.transformed(a, g.m);
            try out.append(a, if (g.grow > 0) try geom.grow.grow(a, t, g.grow, tol) else t);
        },
        .rule => |r| {
            const segs = try a.alloc(geom.Segment, 4);
            for (segs, 0..) |*s, k| s.* = .{ .line = .{ r.corners[k], r.corners[(k + 1) % 4] } };
            const cs = try a.alloc(geom.Contour, 1);
            cs[0] = .{ .segments = segs };
            try out.append(a, .{ .contours = cs });
        },
        .hole => {},
    };
    return out.items;
}
