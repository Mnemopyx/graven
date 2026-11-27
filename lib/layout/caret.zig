//! The text caret in a flow: the places it can stop, and the motions over
//! them.
//!
//! Every text action is an operator (move the caret, extend the
//! selection, delete) applied to a motion (a character, a word, a line, a
//! paragraph, the flow, a change of character style). The motions are
//! worked out here, once, over the flow's stops; the editor maps operator
//! and motion to keys, and the expression line can use the same motions.
//!
//! A stop is a place in the flow (an item, and a byte offset into the run
//! there) with where it shows (a panel, a segment of the track, a distance
//! along it). Stops come from a solve: each placed item's start and end,
//! each glyph's start, a run piece's end, an equation's anchor points, and
//! either side of each change of emphasis (just outside a bold group and
//! just inside its end, so the caret can be put in or out of it before
//! typing).

const std = @import("std");
const model = @import("model.zig");
const place = @import("place.zig");
const edit = @import("edit.zig");
const geom = @import("graven_geom");

const Allocator = std.mem.Allocator;
const Parent = model.Parent;
const Item = model.Item;
const FlowPos = model.FlowPos;

pub const Stop = struct {
    index: usize,
    offset: u32 = 0,
    parent: Parent,
    segment: usize = 0,
    /// Distance along the segment, mm.
    along: f64 = 0,
    /// At a change of character style (no glyph of its own: it shows where
    /// the stop beside it does).
    edge: bool = false,

    pub fn pos(s: Stop) FlowPos {
        return .{ .index = s.index, .offset = s.offset };
    }
};

pub fn before(x: Stop, y: Stop) bool {
    return x.index < y.index or (x.index == y.index and x.offset < y.offset);
}

/// The stop for flow position `p`: its own, else the last before it.
pub fn at(sts: []const Stop, p: FlowPos) ?usize {
    if (sts.len == 0) return null;
    var k: usize = 0;
    for (sts, 0..) |st, i| {
        if (st.index < p.index or (st.index == p.index and st.offset <= p.offset)) k = i else break;
    }
    return k;
}

/// Whether source byte `at` falls inside one of characters `cs`, past its
/// start (an accent on its letter).
fn insideChar(cs: []const edit.Char, byte: u32) bool {
    for (cs) |c| {
        if (c.start < byte and byte < c.end) return true;
        if (c.start >= byte) break;
    }
    return false;
}

/// The placed track of flow (`fp`, `fr`) in `pl` nearest point `p`.
fn trackHolding(pl: *const place.Placed, fp: Parent, fr: usize, p: geom.Point) ?place.PlacedTrack {
    var best: ?place.PlacedTrack = null;
    var best_d: f64 = std.math.inf(f64);
    for (pl.tracks) |t| {
        if (!t.flow_parent.eql(fp) or t.region != fr) continue;
        const b = t.box;
        const dy = if (p.y < b.y0) b.y0 - p.y else if (p.y > b.y1) p.y - b.y1 else 0;
        const dx = if (p.x < b.x0) b.x0 - p.x else if (p.x > b.x1) p.x - b.x1 else 0;
        const d = dx + dy;
        if (d < best_d) {
            best_d = d;
            best = t;
        }
    }
    return best;
}

/// Every place the caret can stop in the flow of track `fr` of `fp` (the
/// first of its thread), in order, from solve `solved` (one `Placed` per
/// parent, as `Model.parentAt` numbers them). Allocated from `a`.
pub fn stops(a: Allocator, m: *const model.Model, solved: []const place.Placed, fp: Parent, fr: usize) Allocator.Error![]Stop {
    var list: std.ArrayList(Stop) = .empty;
    if (!m.hasParent(fp) or fr >= m.regionsIn(fp).len) return &.{};
    const items = m.flowItems(fp, fr);
    var last: ?Stop = null;
    for (solved, 0..) |*pl, k| {
        const pi = m.parentAt(k);
        for (pl.items) |it| {
            if (!it.flow_parent.eql(fp) or it.region != fr or it.index >= items.len) continue;
            try list.append(a, .{ .index = it.index, .parent = pi, .segment = it.segment, .along = it.span[0] });
            var end: Stop = .{ .index = it.index + 1, .parent = pi, .segment = it.segment, .along = it.span[1] };
            // After a break or paragraph end the caret is at the next
            // line's start, even when nothing is set there yet (Enter at the
            // end of the text).
            if (items[it.index].breaks()) for (pl.tracks) |t| {
                if (t.flow_parent.eql(fp) and t.region == fr and t.track == it.segment + 1) {
                    end.segment = t.track;
                    end.along = 0;
                    break;
                }
            };
            if (last == null or !before(end, last.?)) last = end;
        }
        // The characters of the runs set here.
        for (pl.labels) |l| {
            const r = l.run orelse continue;
            if (!r.parent.eql(fp) or r.region != fr or r.item >= items.len or items[r.item].what != .run) continue;
            const run = items[r.item].what.run;
            const content = run.content;
            const t = trackHolding(pl, fp, fr, l.origin) orelse continue;
            const piece_end = r.from + r.len;
            const add = struct {
                fn f(lst: *std.ArrayList(Stop), al: Allocator, item: usize, off: u32, len: usize, parent: Parent, seg: usize, along: f64, edge: bool) Allocator.Error!void {
                    const s0: Stop = if (off >= len) .{ .index = item + 1, .parent = parent, .segment = seg, .along = along, .edge = edge } else .{ .index = item, .offset = off, .parent = parent, .segment = seg, .along = along, .edge = edge };
                    try lst.append(al, s0);
                }
            }.f;
            // Its characters (grapheme clusters: a letter and its accents
            // are one), for text: no stop inside one, and one at each
            // start, inside a ligature too.
            const cs: []const edit.Char = if (run.equation) &.{} else try edit.chars(a, content, false);
            for (l.render.items) |ri| switch (ri) {
                .glyph => |g| {
                    if (g.source < r.from or g.source >= piece_end) continue;
                    if (insideChar(cs, g.source)) continue;
                    try add(&list, a, r.item, g.source, content.len, pi, t.track, l.origin.x + g.transform.e - t.box.x0, false);
                },
                else => {},
            };
            for (cs) |ch| {
                if (ch.start < r.from or ch.start >= piece_end) continue;
                if (l.render.caret(ch.start)) |cr| try add(&list, a, r.item, ch.start, content.len, pi, t.track, l.origin.x + cr.x - t.box.x0, false);
            }
            if (l.render.caret(piece_end)) |cr| try add(&list, a, r.item, piece_end, content.len, pi, t.track, l.origin.x + cr.x - t.box.x0, false);
            if (run.equation) {
                // An equation's anchor points, where Tab puts the caret (an
                // empty slot has no glyph to stop at).
                for (try edit.slots(a, content)) |s| {
                    if (s < r.from or s >= piece_end) continue;
                    if (l.render.caret(s)) |cr| try add(&list, a, r.item, s, content.len, pi, t.track, l.origin.x + cr.x - t.box.x0, false);
                }
            } else for (try edit.emphasisEdges(a, content)) |s| {
                // Either side of a change of emphasis: shown where the next
                // stop is (set below).
                if (s < r.from or s >= piece_end) continue;
                const x = if (l.render.caret(s)) |cr| l.origin.x + cr.x - t.box.x0 else 0;
                try add(&list, a, r.item, s, content.len, pi, t.track, x, true);
            }
        }
    }
    if (last) |e| try list.append(a, e);
    if (list.items.len == 0) {
        // An empty flow: its first segment's start.
        for (solved, 0..) |pl, k| for (pl.tracks) |t| {
            if (t.flow_parent.eql(fp) and t.region == fr and t.track == 0) return a.dupe(Stop, &.{.{ .index = 0, .parent = m.parentAt(k) }});
        };
        return &.{};
    }
    std.mem.sort(Stop, list.items, {}, struct {
        fn lt(_: void, x: Stop, y: Stop) bool {
            if (x.index != y.index or x.offset != y.offset) return before(x, y);
            // At one place, a glyph's stop before an edge's.
            return !x.edge and y.edge;
        }
    }.lt);
    // One stop per place: the first found (a run's start in its first
    // piece; a glyph's over an edge's).
    var w: usize = 0;
    for (list.items) |st| {
        if (w > 0 and list.items[w - 1].index == st.index and list.items[w - 1].offset == st.offset) continue;
        list.items[w] = st;
        w += 1;
    }
    const out = list.items[0..w];
    // An edge shows where the next stop that is not one does, on its line
    // (else the one before).
    for (out, 0..) |*st, i| {
        if (!st.edge) continue;
        var j = i + 1;
        while (j < out.len and out[j].edge) j += 1;
        if (j < out.len and out[j].parent.eql(st.parent) and out[j].segment == st.segment) {
            st.along = out[j].along;
            continue;
        }
        var h = i;
        while (h > 0 and out[h - 1].edge) h -= 1;
        if (h > 0) {
            st.along = out[h - 1].along;
            st.segment = out[h - 1].segment;
            st.parent = out[h - 1].parent;
        }
    }
    return out;
}

pub const Motion = enum {
    char_prev,
    char_next,
    word_prev,
    word_next,
    line_start,
    line_end,
    line_up,
    line_down,
    paragraph_prev,
    paragraph_next,
    /// This paragraph's start and end (Home and End pressed again).
    paragraph_start,
    paragraph_end,
    flow_start,
    flow_end,
    style_prev,
    style_next,

    /// Its action name's last part: `char-prev`.
    pub fn name(mo: Motion) []const u8 {
        return switch (mo) {
            inline else => |t| comptime blk: {
                var buf: [@tagName(t).len]u8 = undefined;
                for (@tagName(t), 0..) |ch, i| buf[i] = if (ch == '_') '-' else ch;
                const final = buf;
                break :blk &final;
            },
        };
    }
};

/// What a stop sits before: a character of text (its first byte), or
/// null before an item that is not text and at the end.
fn charAt(items: []const Item, st: Stop) ?u8 {
    if (st.index >= items.len or items[st.index].what != .run) return null;
    const run = items[st.index].what.run;
    if (run.equation) return '$';
    return if (st.offset < run.content.len) run.content[st.offset] else null;
}

/// The character before stop `j`, past the edges between.
fn charBefore(sts: []const Stop, items: []const Item, j: usize) ?u8 {
    var k = j;
    while (k > 0) {
        k -= 1;
        if (!sts[k].edge) return charAt(items, sts[k]);
    }
    return null;
}

/// Whether a word starts at stop `j` (never at an edge).
fn wordStart(sts: []const Stop, items: []const Item, j: usize) bool {
    return !sts[j].edge and isWordChar(charAt(items, sts[j])) and !isWordChar(charBefore(sts, items, j));
}

/// Letters, digits and anything not ASCII are word characters; an
/// equation counts as one.
fn isWordChar(ch: ?u8) bool {
    const c = ch orelse return false;
    return std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '\\' or c == '$';
}

/// Whether stop `k` starts a paragraph: the flow's start, or just after a
/// paragraph's end.
fn paragraphStart(sts: []const Stop, items: []const Item, k: usize) bool {
    if (k == 0) return true;
    const st = sts[k];
    return st.offset == 0 and st.index > 0 and st.index - 1 < items.len and items[st.index - 1].what == .paragraph and !sts[k - 1].edge;
}

/// Whether stop `k` ends a paragraph: just before a paragraph's end, or
/// the flow's end.
fn paragraphEnd(sts: []const Stop, items: []const Item, k: usize) bool {
    if (k + 1 >= sts.len) return true;
    const st = sts[k];
    return st.offset == 0 and st.index < items.len and items[st.index].what == .paragraph;
}

/// Where motion `mo` takes the caret at stop `i` of `sts` (from `stops`,
/// over `items`, the flow's): the stop it lands on. `column` is the
/// distance along remembered for moving up and down (null: the stop's
/// own).
pub fn motion(sts: []const Stop, items: []const Item, i: usize, mo: Motion, column: ?f64) usize {
    if (sts.len == 0) return 0;
    const here = sts[i];
    var j = i;
    const sameLine = struct {
        fn f(x: Stop, y: Stop) bool {
            return x.parent.eql(y.parent) and x.segment == y.segment;
        }
    }.f;
    switch (mo) {
        .char_prev => j = i -| 1,
        .char_next => j = @min(i + 1, sts.len - 1),
        .word_prev => {
            // Back to the start of a word; a paragraph's start stops it.
            j = i -| 1;
            while (j > 0 and (sts[j].edge or (sameLine(sts[j], here) and sts[j].along == here.along and here.edge))) j -= 1;
            while (j > 0 and !paragraphStart(sts, items, j) and !wordStart(sts, items, j)) j -= 1;
        },
        .word_next => {
            // On to the next word's start; a paragraph's end stops it. From
            // an edge, the glyph's stop at the same place is passed too.
            j = @min(i + 1, sts.len - 1);
            while (j + 1 < sts.len and (sts[j].edge or (here.edge and sameLine(sts[j], here) and sts[j].along == here.along))) j += 1;
            while (j + 1 < sts.len and !paragraphEnd(sts, items, j) and !wordStart(sts, items, j)) j += 1;
        },
        .line_start => while (j > 0 and sameLine(sts[j - 1], here)) {
            j -= 1;
        },
        .line_end => while (j + 1 < sts.len and sameLine(sts[j + 1], here)) {
            j += 1;
        },
        .paragraph_start => while (j > 0 and !paragraphStart(sts, items, j)) {
            j -= 1;
        },
        .paragraph_end => while (j + 1 < sts.len and !paragraphEnd(sts, items, j)) {
            j += 1;
        },
        .paragraph_prev => {
            // This paragraph's start, or the one before when already there.
            if (j > 0 and paragraphStart(sts, items, j)) j -= 1;
            while (j > 0 and !paragraphStart(sts, items, j)) j -= 1;
        },
        .paragraph_next => {
            // The next paragraph's start, or the flow's end in the last.
            j = @min(i + 1, sts.len - 1);
            while (j + 1 < sts.len and !paragraphStart(sts, items, j)) j += 1;
        },
        .flow_start => j = 0,
        .flow_end => j = sts.len - 1,
        .style_prev => {
            j = i -| 1;
            while (j > 0 and !sts[j].edge) j -= 1;
        },
        .style_next => {
            j = @min(i + 1, sts.len - 1);
            while (j + 1 < sts.len and !sts[j].edge) j += 1;
        },
        .line_up, .line_down => {
            // The nearest stop to the column on the line before or after
            // (lines in flow order: a thread's next panel follows).
            const down = mo == .line_down;
            const col = column orelse here.along;
            // The first stop of the line before or after.
            var k = i;
            if (down) {
                while (k + 1 < sts.len and sameLine(sts[k + 1], here)) k += 1;
                k += 1;
            } else {
                while (k > 0 and sameLine(sts[k - 1], here)) k -= 1;
                k = if (k > 0) k - 1 else sts.len;
            }
            if (k >= sts.len) {
                // On the last line, Down goes to its end; on the first, Up
                // to its start.
                return motion(sts, items, i, if (down) .line_end else .line_start, null);
            }
            const line = sts[k];
            var best = k;
            for (sts, 0..) |st, n| {
                if (!sameLine(st, line)) continue;
                if (@abs(st.along - col) < @abs(sts[best].along - col)) best = n;
            }
            j = best;
        },
    }
    return j;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "motions over stops: words, lines, paragraphs, style edges" {
    const p: Parent = .{ .panel = 0 };
    // "ab cd¶ef" in two lines: run 0 "ab \textbf{cd}", ¶, run 2 "ef".
    const items = [_]Item{
        .{ .what = .{ .run = .{ .content = "ab \\textbf{cd}" } } },
        .{ .what = .{ .paragraph = null } },
        .{ .what = .{ .run = .{ .content = "ef" } } },
    };
    const sts = [_]Stop{
        .{ .index = 0, .offset = 0, .parent = p, .along = 0 },
        .{ .index = 0, .offset = 1, .parent = p, .along = 1 },
        .{ .index = 0, .offset = 2, .parent = p, .along = 2 },
        .{ .index = 0, .offset = 3, .parent = p, .along = 3, .edge = true },
        .{ .index = 0, .offset = 11, .parent = p, .along = 3 },
        .{ .index = 0, .offset = 12, .parent = p, .along = 4 },
        .{ .index = 0, .offset = 13, .parent = p, .along = 5, .edge = true },
        .{ .index = 1, .parent = p, .along = 5 },
        .{ .index = 2, .parent = p, .segment = 1, .along = 0 },
        .{ .index = 2, .offset = 1, .parent = p, .segment = 1, .along = 1 },
        .{ .index = 3, .parent = p, .segment = 1, .along = 2 },
    };
    // Words: from "a" on to "cd" (past the edge), and back.
    try testing.expectEqual(4, motion(&sts, &items, 0, .word_next, null));
    try testing.expectEqual(0, motion(&sts, &items, 4, .word_prev, null));
    // From an edge, the word after it (not the glyph at the same place).
    try testing.expectEqual(7, motion(&sts, &items, 3, .word_next, null));
    // A word motion stops at the paragraph's end.
    try testing.expectEqual(7, motion(&sts, &items, 4, .word_next, null));
    // Style edges.
    try testing.expectEqual(3, motion(&sts, &items, 0, .style_next, null));
    try testing.expectEqual(6, motion(&sts, &items, 3, .style_next, null));
    // Lines and paragraphs.
    try testing.expectEqual(7, motion(&sts, &items, 2, .line_end, null));
    try testing.expectEqual(9, motion(&sts, &items, 1, .line_down, null));
    try testing.expectEqual(1, motion(&sts, &items, 9, .line_up, null));
    try testing.expectEqual(8, motion(&sts, &items, 2, .paragraph_next, null));
    try testing.expectEqual(8, motion(&sts, &items, 9, .paragraph_prev, null));
    try testing.expectEqual(0, motion(&sts, &items, 8, .paragraph_prev, null));
    try testing.expectEqual(7, motion(&sts, &items, 1, .paragraph_end, null));
    try testing.expectEqual(10, motion(&sts, &items, 0, .flow_end, null));
    try testing.expectEqualStrings("paragraph-prev", Motion.paragraph_prev.name());
}
