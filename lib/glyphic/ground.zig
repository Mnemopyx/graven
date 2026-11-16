//! The ground: where an expression stands and what it may use. Layout asks
//! it as it goes; the ground knows nothing of the objects on it.
//!
//! A ground is a cursor through the pieces of space a flow offers, in
//! order (a track's segments, then the next track of its thread). Each
//! piece gives its baseline as a path (a frame at every distance along
//! it: point, direction, normal, curvature), the stretches of it that are
//! open, the room above and below the baseline, the cap height of the text
//! it holds, and how it aligns.
//!
//! The making process's limits are not part of it: they belong to the
//! manufacture stage, which checks a design against them and reports what
//! does not fit. Layout sets what was designed.
//!
//! Rotation of objects relative to one another is glyphic's own, in its
//! flat expression space; the ground only maps that space onto its paths.
//! Layout composes the two: the ground's frame at an object's anchor, then
//! the object's own turns.
//!
//! Units are mm, in the frame of what holds the ground (a panel), y up.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Vec = struct {
    x: f64,
    y: f64,

    pub fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn scale(a: Vec, k: f64) Vec {
        return .{ .x = a.x * k, .y = a.y * k };
    }

    /// Turned a quarter anticlockwise: the left of a direction.
    pub fn left(a: Vec) Vec {
        return .{ .x = -a.y, .y = a.x };
    }
};

/// Where a baseline is, a distance along it.
pub const Frame = struct {
    point: Vec,
    /// The way the baseline runs (unit).
    along: Vec,
    /// Up from the baseline (unit): `along` turned a quarter anticlockwise.
    up: Vec,
    /// Signed: positive where the baseline turns toward `up` (left).
    curvature: f64,
};

/// A piece's baseline, from its start.
pub const Baseline = union(enum) {
    /// Straight, from `start` in direction `dir` (unit).
    line: struct { start: Vec, dir: Vec },
    /// A circular arc about `centre`, of `radius`, from `start` radians
    /// (anticlockwise from +x), turning left (anticlockwise) or right.
    arc: struct { centre: Vec, radius: f64, start: f64, turn: enum { left, right } },

    pub fn frame(b: Baseline, s: f64) Frame {
        switch (b) {
            .line => |l| return .{ .point = l.start.add(l.dir.scale(s)), .along = l.dir, .up = l.dir.left(), .curvature = 0 },
            .arc => |c| {
                const sign: f64 = if (c.turn == .left) 1 else -1;
                const th = c.start + sign * s / c.radius;
                const radial: Vec = .{ .x = @cos(th), .y = @sin(th) };
                const along = radial.left().scale(sign);
                return .{ .point = c.centre.add(radial.scale(c.radius)), .along = along, .up = along.left(), .curvature = sign / c.radius };
            },
        }
    }
};

/// A stretch along a piece, mm from its start.
pub const Span = struct { lo: f64, hi: f64 };

pub const Align = enum { start, centre, end, justify };

/// One piece of ground.
pub const Piece = struct {
    baseline: Baseline,
    /// How far the baseline runs, mm.
    length: f64,
    /// The stretches that are free, in order, within [0, length].
    open: []const Span,
    /// Room above the baseline (along its normal) and below it, mm.
    above: f64,
    below: f64,
    /// The cap height of the text it holds, mm (parameters given in cap
    /// heights become mm by it).
    cap: f64,
    alignment: Align = .start,
    /// A column: its content set a character at a time down its length,
    /// each upright (standing across the baseline, its up back along it)
    /// and centred on the baseline, rather than running along it.
    stacked: bool = false,

    pub fn frame(p: Piece, s: f64) Frame {
        return p.baseline.frame(s);
    }

    /// The first start at or after `from` where `size` fits in one open
    /// stretch; null when none is left.
    pub fn fit(p: Piece, from: f64, size: f64) ?f64 {
        for (p.open) |o| {
            const at = @max(from, o.lo);
            if (at + size <= o.hi + 1e-9) return at;
        }
        return null;
    }

    /// The total open length.
    pub fn openLength(p: Piece) f64 {
        var n: f64 = 0;
        for (p.open) |o| n += o.hi - o.lo;
        return n;
    }
};

/// The open stretches of [lo, hi] once `closed` (in any order, possibly
/// overlapping or reaching outside) are taken out; from `a`.
pub fn openSpans(a: Allocator, lo: f64, hi: f64, closed: []const Span) Allocator.Error![]Span {
    const sorted = try a.dupe(Span, closed);
    defer a.free(sorted);
    std.mem.sort(Span, sorted, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.lo < y.lo;
        }
    }.lt);
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(a);
    var at = lo;
    for (sorted) |c| {
        if (c.hi <= at) continue;
        if (c.lo >= hi) break;
        if (c.lo > at) try out.append(a, .{ .lo = at, .hi = @min(c.lo, hi) });
        at = @max(at, c.hi);
        if (at >= hi) break;
    }
    if (at < hi) try out.append(a, .{ .lo = at, .hi = hi });
    return out.toOwnedSlice(a);
}

/// A ground: pieces on request.
pub const Ground = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Piece `k`, made if it is not yet, `lead` mm further on across
        /// than the one before it when made (a paragraph's spacing);
        /// pieces already made come back as they were. Null when there
        /// are no more here (a thread may go on elsewhere: see `more`).
        piece: *const fn (ctx: *anyopaque, k: usize, lead: f64) ?Piece,
        /// Whether the flow goes on past the last piece, into ground
        /// beyond this one (a thread's next panel).
        more: *const fn (ctx: *anyopaque) bool,
    };

    pub fn piece(g: Ground, k: usize, lead: f64) ?Piece {
        return g.vtable.piece(g.ctx, k, lead);
    }

    pub fn more(g: Ground) bool {
        return g.vtable.more(g.ctx);
    }
};

// Synthetic grounds ------------------------------------------------------------------
//
// For tests, and for setting an expression where no document is: the
// shapes real tracks will have.

/// Straight rows stacked downward, `pitch` apart, each `length` long, the
/// first's baseline starting at `origin`; `closed[k]` closes stretches of
/// row k.
pub const Rows = struct {
    a: Allocator,
    origin: Vec,
    length: f64,
    pitch: f64,
    count: usize,
    cap: f64,
    closed: []const []const Span = &.{},
    alignment: Align = .start,
    made: std.ArrayList(Piece) = .empty,
    leads: f64 = 0,

    pub fn deinit(r: *Rows) void {
        for (r.made.items) |p| r.a.free(p.open);
        r.made.deinit(r.a);
    }

    pub fn ground(r: *Rows) Ground {
        return .{ .ctx = r, .vtable = &.{ .piece = piece, .more = none } };
    }

    fn none(_: *anyopaque) bool {
        return false;
    }

    fn piece(ctx: *anyopaque, k: usize, lead: f64) ?Piece {
        const r: *Rows = @ptrCast(@alignCast(ctx));
        while (r.made.items.len <= k) {
            const n = r.made.items.len;
            if (n >= r.count) return null;
            if (n > 0) r.leads += lead;
            const closed: []const Span = if (n < r.closed.len) r.closed[n] else &.{};
            const open = openSpans(r.a, 0, r.length, closed) catch return null;
            const y = r.origin.y - @as(f64, @floatFromInt(n)) * r.pitch - r.leads;
            r.made.append(r.a, .{
                .baseline = .{ .line = .{ .start = .{ .x = r.origin.x, .y = y }, .dir = .{ .x = 1, .y = 0 } } },
                .length = r.length,
                .open = open,
                .above = r.pitch - (r.pitch - r.cap) / 2,
                .below = (r.pitch - r.cap) / 2,
                .cap = r.cap,
                .alignment = r.alignment,
            }) catch {
                r.a.free(open);
                return null;
            };
        }
        return r.made.items[k];
    }
};

/// Columns side by side, `pitch` apart, each `length` long, the first's
/// centre line starting at `origin` (its top) and running down: stacked
/// pieces.
pub const Columns = struct {
    origin: Vec,
    length: f64,
    pitch: f64,
    count: usize,
    cap: f64,
    whole: [32][1]Span = undefined,

    pub fn ground(c: *Columns) Ground {
        return .{ .ctx = c, .vtable = &.{ .piece = piece, .more = none } };
    }

    fn none(_: *anyopaque) bool {
        return false;
    }

    fn piece(ctx: *anyopaque, k: usize, _: f64) ?Piece {
        const c: *Columns = @ptrCast(@alignCast(ctx));
        if (k >= c.count or k >= c.whole.len) return null;
        c.whole[k] = .{.{ .lo = 0, .hi = c.length }};
        return .{
            .baseline = .{ .line = .{ .start = .{ .x = c.origin.x + @as(f64, @floatFromInt(k)) * c.pitch, .y = c.origin.y }, .dir = .{ .x = 0, .y = -1 } } },
            .length = c.length,
            .open = &c.whole[k],
            .above = c.pitch / 2,
            .below = c.pitch / 2,
            .cap = c.cap,
            .stacked = true,
        };
    }
};

/// Concentric arcs about `centre`, as on a dial: the first at `radius`,
/// each next `pitch` further in, running from `start` radians through
/// `sweep` radians, clockwise (reading round the top of a dial) or not.
pub const Dial = struct {
    centre: Vec,
    radius: f64,
    start: f64,
    sweep: f64,
    pitch: f64,
    count: usize,
    cap: f64,
    clockwise: bool = true,
    /// Each arc's one open stretch (its whole length); up to 32 arcs.
    whole: [32][1]Span = undefined,

    pub fn ground(d: *Dial) Ground {
        return .{ .ctx = d, .vtable = &.{ .piece = piece, .more = none } };
    }

    fn none(_: *anyopaque) bool {
        return false;
    }

    fn piece(ctx: *anyopaque, k: usize, _: f64) ?Piece {
        const d: *Dial = @ptrCast(@alignCast(ctx));
        if (k >= d.count or k >= d.whole.len) return null;
        const r = d.radius - @as(f64, @floatFromInt(k)) * d.pitch;
        if (!(r > 0)) return null;
        const length = r * d.sweep;
        d.whole[k] = .{.{ .lo = 0, .hi = length }};
        return .{
            .baseline = .{ .arc = .{ .centre = d.centre, .radius = r, .start = d.start, .turn = if (d.clockwise) .right else .left } },
            .length = length,
            .open = &d.whole[k],
            .above = d.pitch / 2 + d.cap / 2,
            .below = d.pitch / 2 - d.cap / 2,
            .cap = d.cap,
        };
    }
};

// Tests ---------------------------------------------------------------------------

const testing = std.testing;

fn near(want: f64, got: f64) !void {
    try testing.expectApproxEqAbs(want, got, 1e-9);
}

test "a straight baseline: frames along it, up to its left" {
    const b: Baseline = .{ .line = .{ .start = .{ .x = 10, .y = 5 }, .dir = .{ .x = 0, .y = -1 } } };
    const f = b.frame(3);
    try near(10, f.point.x);
    try near(2, f.point.y);
    // Running down the page (a column), up is to the right.
    try near(1, f.up.x);
    try near(0, f.curvature);
}

test "an arc: clockwise round the top of a dial, up points out, curvature negative" {
    // Radius 20 about the origin, from the top (π/2), clockwise.
    const b: Baseline = .{ .arc = .{ .centre = .{ .x = 0, .y = 0 }, .radius = 20, .start = std.math.pi / 2.0, .turn = .right } };
    const f0 = b.frame(0);
    try near(0, f0.point.x);
    try near(20, f0.point.y);
    try near(1, f0.along.x); // reading left to right at the top
    try near(1, f0.up.y); // up is outward
    try near(-1.0 / 20.0, f0.curvature);
    // A quarter turn on: at the right, running down, up still outward.
    const f1 = b.frame(20 * std.math.pi / 2.0);
    try near(20, f1.point.x);
    try near(0, f1.point.y);
    try near(-1, f1.along.y);
    try near(1, f1.up.x);
    // Anticlockwise round the bottom: up points in, curvature positive.
    const c: Baseline = .{ .arc = .{ .centre = .{ .x = 0, .y = 0 }, .radius = 20, .start = -std.math.pi / 2.0, .turn = .left } };
    const g = c.frame(0);
    try near(1, g.along.x);
    try near(1, g.up.y);
    try near(1.0 / 20.0, g.curvature);
}

test "open spans: what closed stretches leave of a piece" {
    const a = testing.allocator;
    const o = try openSpans(a, 0, 50, &.{ .{ .lo = 30, .hi = 35 }, .{ .lo = -5, .hi = 4 }, .{ .lo = 32, .hi = 40 }, .{ .lo = 60, .hi = 70 } });
    defer a.free(o);
    try testing.expectEqual(@as(usize, 2), o.len);
    try near(4, o[0].lo);
    try near(30, o[0].hi);
    try near(40, o[1].lo);
    try near(50, o[1].hi);
    const all = try openSpans(a, 0, 10, &.{.{ .lo = -1, .hi = 11 }});
    defer a.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);
}

test "rows: a cursor of pieces, made on request, a lead pushing the next one on" {
    var r: Rows = .{ .a = testing.allocator, .origin = .{ .x = 0, .y = 100 }, .length = 50, .pitch = 6, .count = 3, .cap = 3, .closed = &.{ &.{}, &.{.{ .lo = 20, .hi = 28 }} } };
    defer r.deinit();
    const g = r.ground();
    const p0 = g.piece(0, 0).?;
    try near(100, p0.frame(0).point.y);
    try near(4.5, p0.above);
    try near(1.5, p0.below);
    // The second row, 2 mm of paragraph spacing further down; asked again,
    // the same (the lead counts only when it is made).
    const p1 = g.piece(1, 2).?;
    try near(92, p1.frame(0).point.y);
    try near(92, g.piece(1, 9).?.frame(0).point.y);
    // Its open stretches, and where 10 mm fits from 15 mm on: past the closed one.
    try testing.expectEqual(@as(usize, 2), p1.open.len);
    try near(28, p1.fit(15, 10).?);
    try near(42, p1.openLength());
    try testing.expectEqual(null, p1.fit(45, 10));
    try testing.expect(g.piece(3, 0) == null);
    try testing.expect(!g.more());
}

test "a dial: concentric arcs, each shorter in" {
    var d: Dial = .{ .centre = .{ .x = 0, .y = 0 }, .radius = 30, .start = std.math.pi * 0.75, .sweep = std.math.pi / 2.0, .pitch = 5, .count = 2, .cap = 2.5 };
    const g = d.ground();
    const p0 = g.piece(0, 0).?;
    const p1 = g.piece(1, 0).?;
    try near(30 * std.math.pi / 2.0, p0.length);
    try near(25 * std.math.pi / 2.0, p1.length);
    // Midway along the outer arc it is at the top, reading left to right.
    const f = p0.frame(p0.length / 2);
    try near(0, f.point.x);
    try near(30, f.point.y);
    try near(1, f.along.x);
    try testing.expect(g.piece(2, 0) == null);
    // Each keeps its own open stretch.
    try near(p0.length, p0.open[0].hi);
}
