//! One-dimensional spring chains: the positioning rule for every level, from
//! a subdivision's spare space and a row of tiles down to the elements in a
//! label.
//!
//! A chain runs from a start edge at 0 to an end edge at `span`:
//!
//!     edge  link 0  item 0  link 1  item 1  …  item n-1  link n  edge
//!
//! The solve minimises the sum of tension × (length − rest)² over finite
//! links. A rigid link holds its rest length. A slack link pulls nothing, so
//! a group of items pulled from neither side keeps its resting position, and
//! groups shove each other through their links' minimum lengths. A pinned
//! item stays where it is pinned and splits the chain in two.
//!
//! When the minimum lengths do not fit, finite links shrink below their
//! minimums (equal tensions share the overflow evenly) and the result reports
//! it. The solver never resizes items.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tension = union(enum) {
    /// Pulls nothing; the link only keeps its minimum length.
    slack,
    /// Stretches in inverse proportion to the tension, which must be > 0.
    finite: f64,
    /// Holds its rest length.
    rigid,
};

pub const Link = struct {
    tension: Tension = .slack,
    /// The length a finite link pulls toward, or a rigid link's length.
    rest: f64 = 0,
    /// The shortest the link may be: a contact or minimum gap.
    min: f64 = 0,

    pub fn finite(t: f64) Link {
        return .{ .tension = .{ .finite = t } };
    }

    pub fn rigid(length: f64) Link {
        return .{ .tension = .rigid, .rest = length, .min = length };
    }

    /// The shortest this link can be without overflow.
    fn least(l: Link) f64 {
        return switch (l.tension) {
            .rigid => @max(l.rest, l.min),
            else => l.min,
        };
    }

    /// Its length when nothing stretches or squeezes it.
    fn resting(l: Link) f64 {
        return switch (l.tension) {
            .slack => l.min,
            else => @max(l.rest, l.min),
        };
    }
};

pub const Item = struct {
    size: f64,
    /// Where the item's start rests when nothing pulls it, kept from the
    /// last solve or set by the user. Without one, an unpulled item goes to
    /// the start.
    rest_at: ?f64 = null,
    /// A fixed start position.
    pin: ?f64 = null,
};

pub const Issue = struct {
    kind: enum {
        /// The items and minimum lengths do not fit between the edges.
        overflow,
        /// They do not fit between a pin and an edge or another pin.
        pinned,
        /// Only rigid links lie between two fixed ends whose distance
        /// differs from their length; the run is laid out from its start.
        rigid,
    },
    /// The items involved, first..last inclusive; null for a run with none.
    first: ?usize,
    last: ?usize,
    /// How much too long (overflow, pinned) or how far off (rigid).
    amount: f64,
};

pub const Solution = struct {
    /// Each item's start position.
    at: []f64,
    /// Each link's length.
    lengths: []f64,
    issues: []Issue,
    /// The shortest span that fits everything at its minimum lengths, with
    /// pins where they are: the hard limit when the chain's parent shrinks.
    min_span: f64,

    pub fn deinit(s: *Solution, gpa: Allocator) void {
        gpa.free(s.at);
        gpa.free(s.lengths);
        gpa.free(s.issues);
        s.* = undefined;
    }
};

pub const Error = Allocator.Error || error{InvalidChain};

/// Solves the chain. `links` has one more entry than `items`.
pub fn solve(gpa: Allocator, span: f64, items: []const Item, links: []const Link) Error!Solution {
    if (links.len != items.len + 1) return error.InvalidChain;
    if (!std.math.isFinite(span)) return error.InvalidChain;
    for (items) |it| if (!(it.size >= 0) or !std.math.isFinite(it.size)) return error.InvalidChain;
    for (links) |l| {
        if (!(l.min >= 0) or !std.math.isFinite(l.min) or !std.math.isFinite(l.rest)) return error.InvalidChain;
        if (l.tension == .finite and !(l.tension.finite > 0 and std.math.isFinite(l.tension.finite))) return error.InvalidChain;
    }

    var s: Solver = .{ .gpa = gpa, .items = items, .links = links };
    errdefer s.issues.deinit(gpa);
    const at = try gpa.alloc(f64, items.len);
    errdefer gpa.free(at);
    const lengths = try gpa.alloc(f64, links.len);
    errdefer gpa.free(lengths);
    s.at = at;
    s.len = lengths;

    // Pins split the chain into runs between fixed ends.
    var start: f64 = 0;
    var first: usize = 0;
    var bounded_by_pin = false;
    for (items, 0..) |it, k| {
        const p = it.pin orelse continue;
        at[k] = p;
        try s.run(first, k, start, p, true);
        start = p + it.size;
        first = k + 1;
        bounded_by_pin = true;
    }
    try s.run(first, items.len, start, span, bounded_by_pin);

    return .{
        .at = at,
        .lengths = lengths,
        .issues = try s.issues.toOwnedSlice(gpa),
        .min_span = minSpan(items, links),
    };
}

fn minSpan(items: []const Item, links: []const Link) f64 {
    // From the start, or from the last pin before the end.
    var from: f64 = 0;
    var total: f64 = links[0].least();
    for (items, 0..) |it, k| {
        if (it.pin) |p| {
            from = @max(from + total, p);
            total = 0;
        }
        total += it.size + links[k + 1].least();
    }
    return from + total;
}

const Solver = struct {
    gpa: Allocator,
    items: []const Item,
    links: []const Link,
    at: []f64 = &.{},
    len: []f64 = &.{},
    issues: std.ArrayList(Issue) = .empty,

    /// Lays out items first..end-1 and links first..end between fixed ends
    /// a and b. `pinned` says whether either end is a pin.
    fn run(s: *Solver, first: usize, end: usize, a: f64, b: f64, pinned: bool) Allocator.Error!void {
        const links = s.links[first .. end + 1];
        const len = s.len[first .. end + 1];
        var sizes: f64 = 0;
        for (s.items[first..end]) |it| sizes += it.size;
        const room = b - a - sizes;

        var least: f64 = 0;
        var resting: f64 = 0;
        var any_slack = false;
        var any_finite = false;
        for (links) |l| {
            least += l.least();
            resting += l.resting();
            switch (l.tension) {
                .slack => any_slack = true,
                .finite => any_finite = true,
                .rigid => {},
            }
        }
        const span_items: [2]?usize = if (end > first) .{ first, end - 1 } else .{ null, null };

        if (least > room) {
            // Overflow: everything but finite links at its least, finite
            // links share the rest (below their minimums) by tension.
            for (links, len) |l, *out| out.* = l.least();
            if (any_finite) try s.fill(links, len, room, false);
            try s.issues.append(s.gpa, .{
                .kind = if (pinned) .pinned else .overflow,
                .first = span_items[0],
                .last = span_items[1],
                .amount = least - room,
            });
            s.place(first, end, a);
            return;
        }

        if (!any_slack) {
            for (links, len) |l, *out| out.* = l.least();
            if (any_finite) {
                try s.fill(links, len, room, true);
            } else if (@abs(room - least) > tolerance(b - a)) {
                try s.issues.append(s.gpa, .{ .kind = .rigid, .first = span_items[0], .last = span_items[1], .amount = room - least });
            }
            s.place(first, end, a);
            return;
        }

        if (resting > room) {
            // Slack links close to their minimums; finite links squeeze.
            for (links, len) |l, *out| out.* = l.least();
            try s.fill(links, len, room, true);
            s.place(first, end, a);
            return;
        }

        try s.float(first, end, a, b);
    }

    /// Sets finite links' lengths so all links in `links` sum to `room`:
    /// length = rest + μ / tension, floored at the minimum when `floors`.
    /// Other links keep the lengths already in `len`.
    fn fill(s: *Solver, links: []const Link, len: []f64, room: f64, floors: bool) Allocator.Error!void {
        var fixed: f64 = 0;
        var n: usize = 0;
        for (links, len) |l, x| {
            if (l.tension == .finite) n += 1 else fixed += x;
        }
        const target = room - fixed;

        // Breakpoints μ = (min − rest) × tension, below which a link sits at
        // its minimum. Activate them in order until μ falls in range.
        const order = try s.gpa.alloc(usize, n);
        defer s.gpa.free(order);
        var i: usize = 0;
        for (links, 0..) |l, j| if (l.tension == .finite) {
            order[i] = j;
            i += 1;
        };
        const Ctx = struct {
            links: []const Link,
            fn mu(c: @This(), j: usize) f64 {
                const l = c.links[j];
                return (l.min - l.rest) * l.tension.finite;
            }
            fn less(c: @This(), x: usize, y: usize) bool {
                const mx = c.mu(x);
                const my = c.mu(y);
                return if (mx != my) mx < my else x < y;
            }
        };
        const ctx: Ctx = .{ .links = links };
        std.mem.sort(usize, order, ctx, Ctx.less);

        var mu: f64 = undefined;
        if (!floors) {
            var rest: f64 = 0;
            var compliance: f64 = 0;
            for (order) |j| {
                rest += links[j].rest;
                compliance += 1 / links[j].tension.finite;
            }
            mu = (target - rest) / compliance;
        } else {
            // Links before k are active (stretching); the rest sit at min.
            var clamped: f64 = 0;
            for (order) |j| clamped += links[j].min;
            var rest: f64 = 0;
            var compliance: f64 = 0;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const j = order[k];
                clamped -= links[j].min;
                rest += links[j].rest;
                compliance += 1 / links[j].tension.finite;
                mu = (target - clamped - rest) / compliance;
                if (k + 1 == n or mu <= ctx.mu(order[k + 1])) break;
            }
        }
        for (links, len) |l, *x| if (l.tension == .finite) {
            const stretched = l.rest + mu / l.tension.finite;
            x.* = if (floors) @max(l.min, stretched) else stretched;
        };
    }

    /// Lays out items first..end-1 from `a` with the link lengths in s.len.
    fn place(s: *Solver, first: usize, end: usize, a: f64) void {
        var x = a + s.len[first];
        for (first..end) |k| {
            s.at[k] = x;
            x += s.items[k].size + s.len[k + 1];
        }
    }

    /// The run fits with every link at rest and has slack links: finite and
    /// rigid links rest, and the groups between slack links settle at their
    /// resting positions, shoving each other and stopping at the ends.
    fn float(s: *Solver, first: usize, end: usize, a: f64, b: f64) Allocator.Error!void {
        const links = s.links;
        for (first..end + 1) |j| s.len[j] = links[j].resting();

        // Groups are runs of items joined by non-slack links. A group joined
        // to an end by a non-slack link is attached to it.
        const Group = struct { first: usize, end: usize, length: f64 };
        var groups: std.ArrayList(Group) = .empty;
        defer groups.deinit(s.gpa);
        var k = first;
        while (k < end) {
            var g: Group = .{ .first = k, .end = k, .length = 0 };
            while (true) {
                g.length += s.items[g.end].size;
                g.end += 1;
                if (g.end == end or links[g.end].tension == .slack) break;
                g.length += s.len[g.end];
            }
            try groups.append(s.gpa, g);
            k = g.end;
        }

        // Items joined to the start are laid out from it, and items joined
        // to the end back from it.
        var lo = a;
        var floating: []Group = groups.items;
        if (links[first].tension != .slack) {
            if (floating.len == 0) {
                // No items: the run is a single link, which cannot be slack.
                unreachable;
            }
            const g = floating[0];
            var x = a + s.len[first];
            for (g.first..g.end) |i| {
                s.at[i] = x;
                x += s.items[i].size + (if (i + 1 < g.end) s.len[i + 1] else 0);
            }
            lo = x;
            floating = floating[1..];
        }
        var hi = b;
        if (links[end].tension != .slack and floating.len > 0) {
            const g = floating[floating.len - 1];
            var x = b - s.len[end];
            var i = g.end;
            while (i > g.first) {
                i -= 1;
                x -= s.items[i].size;
                s.at[i] = x;
                if (i > g.first) x -= s.len[i];
            }
            hi = x;
            floating = floating[0 .. floating.len - 1];
        }
        if (floating.len == 0) {
            s.lengthsFromPositions(first, end, a, b);
            return;
        }

        // Each floating group's start x_g must satisfy x_{g+1} ≥ x_g + its
        // length + the slack minimum between. With y_g = x_g − c_g, where
        // c_g accumulates those, the y must not decrease and lie in
        // [lo', hi']: an isotonic regression of the resting positions,
        // clipped to the bounds.
        const n = floating.len;
        const c = try s.gpa.alloc(f64, n);
        defer s.gpa.free(c);
        const y = try s.gpa.alloc(f64, n);
        defer s.gpa.free(y);
        const lo_y = lo + links[floating[0].first].min;
        c[0] = 0;
        for (1..n) |g| c[g] = c[g - 1] + floating[g - 1].length + links[floating[g].first].min;
        const last = floating[n - 1];
        const hi_y = hi - links[last.end].min - last.length - c[n - 1];
        for (floating, 0..) |g, gi| {
            y[gi] = lo_y;
            for (g.first..g.end) |i| if (s.items[i].rest_at) |r| {
                y[gi] = r - s.offsetInGroup(g.first, i) - c[gi];
                break;
            };
        }
        try isotonic(s.gpa, y);
        for (floating, 0..) |g, gi| {
            var x = std.math.clamp(y[gi], lo_y, @max(lo_y, hi_y)) + c[gi];
            for (g.first..g.end) |i| {
                s.at[i] = x;
                x += s.items[i].size + (if (i + 1 < g.end) s.len[i + 1] else 0);
            }
        }
        s.lengthsFromPositions(first, end, a, b);
    }

    fn offsetInGroup(s: *const Solver, group_first: usize, i: usize) f64 {
        var x: f64 = 0;
        for (group_first..i) |k| x += s.items[k].size + s.len[k + 1];
        return x;
    }

    fn lengthsFromPositions(s: *Solver, first: usize, end: usize, a: f64, b: f64) void {
        var prev = a;
        for (first..end) |k| {
            s.len[k] = s.at[k] - prev;
            prev = s.at[k] + s.items[k].size;
        }
        s.len[end] = b - prev;
    }
};

/// Replaces `y` by its least-squares non-decreasing fit (pool adjacent
/// violators, equal weights).
fn isotonic(gpa: Allocator, y: []f64) Allocator.Error!void {
    const Block = struct { sum: f64, count: usize };
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(gpa);
    for (y) |v| {
        try blocks.append(gpa, .{ .sum = v, .count = 1 });
        while (blocks.items.len >= 2) {
            const top = blocks.items[blocks.items.len - 1];
            const below = &blocks.items[blocks.items.len - 2];
            if (below.sum / @as(f64, @floatFromInt(below.count)) <= top.sum / @as(f64, @floatFromInt(top.count))) break;
            below.sum += top.sum;
            below.count += top.count;
            blocks.items.len -= 1;
        }
    }
    var i: usize = 0;
    for (blocks.items) |blk| {
        const mean = blk.sum / @as(f64, @floatFromInt(blk.count));
        for (0..blk.count) |_| {
            y[i] = mean;
            i += 1;
        }
    }
}

fn tolerance(span: f64) f64 {
    return 1e-9 * @max(1, @abs(span));
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

fn expectNear(expected: f64, actual: f64) !void {
    try testing.expectApproxEqAbs(expected, actual, 1e-12);
}

test "equal tension centres an item; unequal tension stretches inversely" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 10, &.{.{ .size = 2 }}, &.{ .finite(1), .finite(1) });
    defer s.deinit(gpa);
    try expectNear(4, s.at[0]);
    try testing.expectEqual(0, s.issues.len);

    // Tension 1 before, 3 after: the softer link before takes 3/4 of 8.
    var t = try solve(gpa, 10, &.{.{ .size = 2 }}, &.{ .finite(1), .finite(3) });
    defer t.deinit(gpa);
    try expectNear(6, t.at[0]);
}

test "a finite link pulls an item to its rest length against a slack one" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 10, &.{.{ .size = 2 }}, &.{ .{ .tension = .{ .finite = 1 }, .rest = 1.5 }, .{} });
    defer s.deinit(gpa);
    try expectNear(1.5, s.at[0]);
    try expectNear(6.5, s.lengths[1]);
}

test "an unpulled item keeps its resting position, clipped to the edges" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 10, &.{.{ .size = 2, .rest_at = 3 }}, &.{ .{}, .{} });
    defer s.deinit(gpa);
    try expectNear(3, s.at[0]);

    var t = try solve(gpa, 10, &.{.{ .size = 2, .rest_at = 9 }}, &.{ .{}, .{ .min = 0.5 } });
    defer t.deinit(gpa);
    try expectNear(7.5, t.at[0]);

    var u = try solve(gpa, 10, &.{.{ .size = 2 }}, &.{ .{ .min = 1 }, .{} });
    defer u.deinit(gpa);
    try expectNear(1, u.at[0]);
}

test "groups shove each other through minimum gaps" {
    const gpa = testing.allocator;
    // Both want to start at 4; 1 apart they settle symmetrically about it.
    var s = try solve(gpa, 20, &.{
        .{ .size = 2, .rest_at = 4 },
        .{ .size = 2, .rest_at = 4 },
    }, &.{ .{}, .{ .min = 1 }, .{} });
    defer s.deinit(gpa);
    try expectNear(2.5, s.at[0]);
    try expectNear(5.5, s.at[1]);

    // Against the start edge, the second is pushed along instead.
    var t = try solve(gpa, 20, &.{
        .{ .size = 2, .rest_at = 0 },
        .{ .size = 2, .rest_at = 0 },
    }, &.{ .{}, .{ .min = 1 }, .{} });
    defer t.deinit(gpa);
    try expectNear(0, t.at[0]);
    try expectNear(3, t.at[1]);
}

test "rigid links move items as one group" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 20, &.{
        .{ .size = 2, .rest_at = 5 },
        .{ .size = 3 },
    }, &.{ .{}, .rigid(1), .{} });
    defer s.deinit(gpa);
    try expectNear(5, s.at[0]);
    try expectNear(8, s.at[1]);
}

test "a pitched row: rigid gaps inside, equal tension to the edges" {
    const gpa = testing.allocator;
    // Three 19.05 mm tiles with 0.95 mm gaps, centred in 70 mm.
    var s = try solve(gpa, 70, &.{ .{ .size = 18.1 }, .{ .size = 18.1 }, .{ .size = 18.1 } }, &.{ .finite(1), .rigid(0.95), .rigid(0.95), .finite(1) });
    defer s.deinit(gpa);
    const width: f64 = 3 * 18.1 + 2 * 0.95;
    try expectNear((70.0 - width) / 2.0, s.at[0]);
    try expectNear(s.at[0] + 18.1 + 0.95, s.at[1]);
}

test "minimum lengths floor finite links before the rest stretch" {
    const gpa = testing.allocator;
    // Rest 0 and equal tension would make each gap 1; the middle needs 2.
    var s = try solve(gpa, 7, &.{ .{ .size = 2 }, .{ .size = 2 } }, &.{ .finite(1), .{ .tension = .{ .finite = 1 }, .min = 2 }, .finite(1) });
    defer s.deinit(gpa);
    try expectNear(0.5, s.lengths[0]);
    try expectNear(2, s.lengths[1]);
    try expectNear(0.5, s.lengths[2]);
}

test "overflow shares evenly by tension and is reported" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 4, &.{.{ .size = 6 }}, &.{ .finite(1), .finite(1) });
    defer s.deinit(gpa);
    try expectNear(-1, s.at[0]);
    try testing.expectEqual(1, s.issues.len);
    try testing.expectEqual(.overflow, s.issues[0].kind);
    try expectNear(2, s.issues[0].amount);
    try expectNear(6, s.min_span);
}

test "pins fix items; too little room beside a pin is reported" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 20, &.{
        .{ .size = 2 },
        .{ .size = 2, .pin = 10 },
        .{ .size = 2 },
    }, &.{ .finite(1), .finite(1), .finite(1), .finite(1) });
    defer s.deinit(gpa);
    try expectNear(4, s.at[0]);
    try expectNear(10, s.at[1]);
    try expectNear(15, s.at[2]);

    var t = try solve(gpa, 20, &.{
        .{ .size = 3 },
        .{ .size = 2, .pin = 2 },
    }, &.{ .{ .min = 0.5 }, .finite(1), .finite(1) });
    defer t.deinit(gpa);
    try testing.expectEqual(.pinned, t.issues[0].kind);
    try expectNear(1.5, t.issues[0].amount);
    try testing.expectEqual(2, t.at[1]);
}

test "rigid links between fixed ends that do not match are reported" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 10, &.{.{ .size = 2 }}, &.{ .rigid(1), .rigid(1) });
    defer s.deinit(gpa);
    try testing.expectEqual(.rigid, s.issues[0].kind);
    try expectNear(6, s.issues[0].amount);
    try expectNear(1, s.at[0]);
}

test "minimum span counts pins" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 100, &.{
        .{ .size = 2 },
        .{ .size = 2, .pin = 30 },
        .{ .size = 2 },
    }, &.{ .{ .min = 1 }, .{ .min = 1 }, .{ .min = 1 }, .{ .min = 1 } });
    defer s.deinit(gpa);
    try expectNear(36, s.min_span);
}

test "an empty chain is one link" {
    const gpa = testing.allocator;
    var s = try solve(gpa, 5, &.{}, &.{.finite(1)});
    defer s.deinit(gpa);
    try expectNear(5, s.lengths[0]);
    try testing.expectError(error.InvalidChain, solve(gpa, 5, &.{}, &.{ .{}, .{} }));
}

test "random chains close exactly and keep their minimums" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(15);
    const r = prng.random();
    var items: [6]Item = undefined;
    var links: [7]Link = undefined;
    for (0..2000) |_| {
        const n = r.uintLessThan(usize, 7);
        for (items[0..n]) |*it| it.* = .{
            .size = r.float(f64) * 5,
            .rest_at = if (r.boolean()) r.float(f64) * 30 else null,
        };
        for (links[0 .. n + 1]) |*l| {
            const min = if (r.boolean()) r.float(f64) else 0;
            l.* = switch (r.uintLessThan(u8, 3)) {
                0 => .{ .min = min },
                1 => .{ .tension = .{ .finite = 0.5 + r.float(f64) * 3 }, .rest = r.float(f64) * 2, .min = min },
                else => .rigid(r.float(f64) * 2),
            };
        }
        const span = r.float(f64) * 30;
        var s = try solve(gpa, span, items[0..n], links[0 .. n + 1]);
        defer s.deinit(gpa);
        var total: f64 = 0;
        for (items[0..n]) |it| total += it.size;
        for (s.lengths) |l| total += l;
        // Every chain closes, except one whose overflow or rigid mismatch
        // has no finite link to absorb it.
        var any_finite = false;
        for (links[0 .. n + 1]) |l| any_finite = any_finite or l.tension == .finite;
        if (s.issues.len == 0 or any_finite) try testing.expectApproxEqAbs(span, total, 1e-9);
        var x: f64 = 0;
        for (items[0..n], 0..) |it, k| {
            x += s.lengths[k];
            try testing.expectApproxEqAbs(x, s.at[k], 1e-9);
            x += it.size;
        }
        if (s.issues.len == 0) {
            for (links[0 .. n + 1], s.lengths) |l, got| {
                try testing.expect(got >= l.least() - 1e-9);
                if (l.tension == .rigid) try testing.expectApproxEqAbs(l.rest, got, 1e-9);
            }
        }
    }
}
