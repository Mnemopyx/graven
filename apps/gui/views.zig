//! The views of a document: the window's central region split side by
//! side or stacked, as deep as wanted, each split holding views as tabs,
//! one of them its current one. A view is a canvas (the canvas or a
//! frame) or, later, a sheet or a flow; several may show one thing. The
//! last view clicked is the active one: the keys and the panes follow it.
//! One view may be maximized, filling the region alone.
//!
//! Fixed in size (no allocation), so it is copied, compared and written
//! with the document as it is. Window-free, so it is tested on its own.

const std = @import("std");

pub const max_views = 16;
pub const max_nodes = 2 * max_views - 1;

pub const Kind = enum {
    canvas,
    sheet,
    /// A manufacturing plan: its parts as made, its operations as layers.
    manufacture,
};

/// A view: what it shows, and where it looks (a canvas's centre, mm, and
/// zoom, px/mm; 0 until it has been shown).
pub const View = struct {
    kind: Kind = .canvas,
    /// A canvas: its space's ID; a sheet: the sheet's; a manufacturing
    /// view: its plan's.
    target: u32 = 0,
    cx: f64 = 0,
    cy: f64 = 0,
    ppm: f64 = 0,
    /// For a context with ordered pages (a document of frames as pages,
    /// to come): the page this view shows, from 0. Each view its own, so
    /// two windows can show two pages of one document.
    page: u32 = 0,
};

/// Side by side (`across`) or stacked (`down`).
pub const Dir = enum { across, down };

pub const Node = struct {
    used: bool = false,
    parent: u8 = none,
    /// A split: its direction, the first part's share, and its parts.
    split: bool = false,
    dir: Dir = .across,
    ratio: f32 = 0.5,
    first: u8 = none,
    second: u8 = none,
    /// A leaf: its views as tabs, in order, and which is current.
    tabs: [max_views]u8 = @splat(none),
    tab_count: u8 = 0,
    current: u8 = 0,

    pub fn tabList(n: *const Node) []const u8 {
        return n.tabs[0..n.tab_count];
    }
};

pub const none: u8 = 0xff;

pub const Layout = struct {
    views: [max_views]View = @splat(.{}),
    open: [max_views]bool = @splat(false),
    nodes: [max_nodes]Node = @splat(.{}),
    root: u8 = 0,
    /// The view the keys and panes follow.
    active: u8 = 0,
    /// The view filling the region alone, if one does.
    maximized: u8 = none,

    /// A layout of one view, `first`.
    pub fn init(first: View) Layout {
        var l: Layout = .{};
        l.views[0] = first;
        l.open[0] = true;
        l.nodes[0] = .{ .used = true };
        l.nodes[0].tabs[0] = 0;
        l.nodes[0].tab_count = 1;
        return l;
    }

    /// Whether it is sound: its views open in exactly one leaf each, its
    /// tree well formed, its active view open. A layout read from a file
    /// is used only if it is.
    pub fn valid(l: *const Layout) bool {
        if (l.root >= max_nodes or !l.nodes[l.root].used) return false;
        if (l.active >= max_views or !l.open[l.active]) return false;
        if (l.maximized != none and (l.maximized >= max_views or !l.open[l.maximized])) return false;
        var seen: [max_views]u8 = @splat(0);
        var visited: [max_nodes]bool = @splat(false);
        if (!l.check(l.root, none, &seen, &visited, 0)) return false;
        for (0..max_views) |v| if ((seen[v] == 1) != l.open[v]) return false;
        return true;
    }

    fn check(l: *const Layout, n: u8, parent: u8, seen: *[max_views]u8, visited: *[max_nodes]bool, depth: usize) bool {
        if (n >= max_nodes or !l.nodes[n].used or visited[n] or depth > max_nodes) return false;
        visited[n] = true;
        const node = &l.nodes[n];
        if (node.parent != parent) return false;
        if (node.split) return l.check(node.first, n, seen, visited, depth + 1) and l.check(node.second, n, seen, visited, depth + 1);
        if (node.tab_count == 0 or node.tab_count > max_views or node.current >= node.tab_count) return false;
        for (node.tabList()) |v| {
            if (v >= max_views) return false;
            seen[v] += 1;
        }
        return true;
    }

    /// The leaf holding view `v`.
    pub fn leafOf(l: *const Layout, v: u8) ?u8 {
        for (&l.nodes, 0..) |*n, i| if (n.used and !n.split and std.mem.indexOfScalar(u8, n.tabList(), v) != null) return @intCast(i);
        return null;
    }

    /// The view a leaf shows.
    pub fn currentOf(l: *const Layout, leaf: u8) u8 {
        const n = &l.nodes[leaf];
        return n.tabs[n.current];
    }

    fn newView(l: *Layout, v: View) ?u8 {
        for (0..max_views) |i| if (!l.open[i]) {
            l.views[i] = v;
            l.open[i] = true;
            return @intCast(i);
        };
        return null;
    }

    fn newNode(l: *Layout) ?u8 {
        for (&l.nodes, 0..) |*n, i| if (!n.used) {
            n.* = .{ .used = true };
            return @intCast(i);
        };
        return null;
    }

    /// Makes view `v` its leaf's current one, and the active view.
    pub fn select(l: *Layout, v: u8) void {
        const leaf = l.leafOf(v) orelse return;
        const n = &l.nodes[leaf];
        n.current = @intCast(std.mem.indexOfScalar(u8, n.tabList(), v).?);
        l.active = v;
        // Another view chosen while one fills the region: it fills it.
        if (l.maximized != none and l.maximized != v) l.maximized = v;
    }

    /// Opens `view` as a new tab in the leaf of view `beside`, current and
    /// active. Returns it, or null when no more views fit.
    pub fn addTab(l: *Layout, beside: u8, view: View) ?u8 {
        const leaf = l.leafOf(beside) orelse return null;
        if (l.nodes[leaf].tab_count >= max_views) return null;
        const v = l.newView(view) orelse return null;
        const n = &l.nodes[leaf];
        n.tabs[n.tab_count] = v;
        n.tab_count += 1;
        l.select(v);
        return v;
    }

    /// Splits the leaf of view `v` in two, `dir`: what it held stays in the
    /// first part, the second shows `view` alone, active. Returns the new
    /// view, or null when no more fit.
    pub fn split(l: *Layout, v: u8, dir: Dir, view: View) ?u8 {
        const leaf = l.leafOf(v) orelse return null;
        // Room for its two parts (every split needs two).
        var free: usize = 0;
        for (l.nodes) |n| {
            if (!n.used) free += 1;
        }
        if (free < 2) return null;
        const nv = l.newView(view) orelse return null;
        return l.splitLeaf(leaf, dir, nv, false);
    }

    /// Closes view `v`. A leaf left empty goes, its split's other part
    /// taking the split's place. The last view stays open: false then.
    pub fn close(l: *Layout, v: u8) bool {
        var count: usize = 0;
        for (l.open) |o| {
            if (o) count += 1;
        }
        if (count <= 1 or v >= max_views or !l.open[v]) return false;
        const leaf = l.leafOf(v) orelse return false;
        const n = &l.nodes[leaf];
        l.takeOut(leaf, v);
        l.open[v] = false;
        if (l.maximized == v) l.maximized = none;
        if (n.tab_count == 0) l.prune(leaf);
        if (l.active == v) {
            // The view now current where it was, or any open one.
            l.active = for (0..max_views) |i| {
                if (l.open[i]) break @intCast(i);
            } else 0;
            if (l.leafOf(l.active)) |lf| l.active = l.currentOf(lf);
            const shown = if (n.tab_count > 0) l.currentOf(leaf) else none;
            if (shown != none) l.active = shown;
        }
        return true;
    }

    /// Takes view `v` out of leaf `leaf`'s tabs, its current tab kept
    /// where it can be (open still).
    fn takeOut(l: *Layout, leaf: u8, v: u8) void {
        const n = &l.nodes[leaf];
        const k = std.mem.indexOfScalar(u8, n.tabList(), v) orelse return;
        const cur = n.tabs[n.current];
        std.mem.copyForwards(u8, n.tabs[k .. n.tab_count - 1], n.tabs[k + 1 .. n.tab_count]);
        n.tab_count -= 1;
        n.tabs[n.tab_count] = none;
        n.current = if (cur != v) @intCast(std.mem.indexOfScalar(u8, n.tabList(), cur).?) else if (n.current >= n.tab_count and n.current > 0) n.current - 1 else n.current;
    }

    /// Leaf `leaf`, left empty, goes: the other part of its split takes
    /// the split's place.
    fn prune(l: *Layout, leaf: u8) void {
        const p = l.nodes[leaf].parent;
        if (p == none) return;
        const other = if (l.nodes[p].first == leaf) l.nodes[p].second else l.nodes[p].first;
        const grand = l.nodes[p].parent;
        l.nodes[p] = l.nodes[other];
        l.nodes[p].parent = grand;
        if (l.nodes[p].split) {
            l.nodes[l.nodes[p].first].parent = p;
            l.nodes[l.nodes[p].second].parent = p;
        }
        l.nodes[leaf] = .{};
        l.nodes[other] = .{};
    }

    /// Takes view `v` from its window (a window left empty goes) and
    /// puts it among the tabs of the window showing view `dest`: before
    /// tab `before` (in that window), or last when `before` is `none`.
    /// Current and active. The same window: the tab moved along. False
    /// when nothing moves.
    pub fn moveTab(l: *Layout, v: u8, dest: u8, before: u8) bool {
        if (v >= max_views or !l.open[v] or before == v) return false;
        const src = l.leafOf(v) orelse return false;
        const dl0 = l.leafOf(dest) orelse return false;
        if (before != none and l.leafOf(before) != dl0) return false;
        if (src == dl0 and before == none and l.nodes[src].tabs[l.nodes[src].tab_count - 1] == v) {
            l.select(v);
            return false;
        }
        l.takeOut(src, v);
        if (src != dl0 and l.nodes[src].tab_count == 0) l.prune(src);
        // The destination found again: pruning may have moved it.
        const dl = if (src == dl0) src else l.leafOf(dest).?;
        const n = &l.nodes[dl];
        const at = if (before == none) n.tab_count else std.mem.indexOfScalar(u8, n.tabList(), before).?;
        std.mem.copyBackwards(u8, n.tabs[at + 1 .. n.tab_count + 1], n.tabs[at..n.tab_count]);
        n.tabs[at] = v;
        n.tab_count += 1;
        if (l.maximized != none) l.maximized = none;
        l.select(v);
        return true;
    }

    /// Takes view `v` from its window (a window left empty goes) and
    /// splits the window showing view `at` in two, `dir`: `v` alone in its
    /// first part when `first`, else its second. Active. False when
    /// nothing moves (`v` alone in that window already).
    pub fn moveToSplit(l: *Layout, v: u8, at: u8, dir: Dir, first: bool) bool {
        if (v >= max_views or !l.open[v]) return false;
        const src = l.leafOf(v) orelse return false;
        const al = l.leafOf(at) orelse return false;
        if (src == al and l.nodes[src].tab_count == 1) return false;
        // Its own window: found again by another of its tabs.
        const at_other = if (at == v) l.tabAlong(v, 1) else at;
        l.takeOut(src, v);
        if (l.nodes[src].tab_count == 0) l.prune(src);
        const leaf = l.leafOf(at_other).?;
        _ = l.splitLeaf(leaf, dir, v, first) orelse return false;
        return true;
    }

    /// Splits leaf `leaf` in two, `dir`: what it held in one part, view
    /// `v` (open, in no leaf) alone in the other, the first when `first`.
    /// `v` active; null when no nodes are left.
    fn splitLeaf(l: *Layout, leaf: u8, dir: Dir, v: u8, first: bool) ?u8 {
        const a = l.newNode() orelse return null;
        const b = l.newNode() orelse {
            l.nodes[a] = .{};
            return null;
        };
        // One part takes the leaf's tabs; the leaf becomes the split.
        l.nodes[a] = l.nodes[leaf];
        l.nodes[a].parent = leaf;
        l.nodes[b].parent = leaf;
        l.nodes[b].tabs[0] = v;
        l.nodes[b].tab_count = 1;
        const parent = l.nodes[leaf].parent;
        l.nodes[leaf] = .{ .used = true, .parent = parent, .split = true, .dir = dir, .first = if (first) b else a, .second = if (first) a else b };
        l.maximized = none;
        l.select(v);
        return v;
    }

    /// The windows (leaves) in order: left to right, top to bottom.
    pub fn leaves(l: *const Layout, out: []u8) []u8 {
        var n: usize = 0;
        l.leavesUnder(l.root, out, &n, 0);
        return out[0..n];
    }

    fn leavesUnder(l: *const Layout, node: u8, out: []u8, n: *usize, depth: usize) void {
        if (node >= max_nodes or depth > max_nodes) return;
        const nd = &l.nodes[node];
        if (!nd.split) {
            if (n.* < out.len) out[n.*] = node;
            n.* += 1;
            return;
        }
        l.leavesUnder(nd.first, out, n, depth + 1);
        l.leavesUnder(nd.second, out, n, depth + 1);
    }

    /// The tab `by` along from view `v` in its window (wrapping round).
    pub fn tabAlong(l: *const Layout, v: u8, by: i32) u8 {
        const leaf = l.leafOf(v) orelse return v;
        const tl = l.nodes[leaf].tabList();
        const k: i32 = @intCast(std.mem.indexOfScalar(u8, tl, v).?);
        const len: i32 = @intCast(tl.len);
        return tl[@intCast(@mod(k + by, len))];
    }

    /// Moves view `v` to the window after its own (`back`: before), last
    /// among its tabs. With one window, it is split: `v` beside the rest.
    pub fn moveToNextWindow(l: *Layout, v: u8, back: bool) bool {
        const src = l.leafOf(v) orelse return false;
        var buf: [max_nodes]u8 = undefined;
        const ls = l.leaves(&buf);
        if (ls.len < 2) return l.moveToSplit(v, v, .across, back);
        const k = std.mem.indexOfScalar(u8, ls, src).?;
        const to = ls[if (back) (k + ls.len - 1) % ls.len else (k + 1) % ls.len];
        return l.moveTab(v, l.currentOf(to), none);
    }

    /// The split holding view `v`'s window, if it is in one.
    pub fn splitOf(l: *const Layout, v: u8) ?u8 {
        const leaf = l.leafOf(v) orelse return null;
        const p = l.nodes[leaf].parent;
        return if (p != none and l.nodes[p].split) p else null;
    }

    /// Split `n`'s parts change places, each keeping its size.
    pub fn swap(l: *Layout, n: u8) void {
        if (!l.nodes[n].split) return;
        const nd = &l.nodes[n];
        std.mem.swap(u8, &nd.first, &nd.second);
        nd.ratio = 1 - nd.ratio;
    }

    /// Split `n`'s parts the same size.
    pub fn evenOut(l: *Layout, n: u8) void {
        if (l.nodes[n].split) l.nodes[n].ratio = 0.5;
    }

    /// Split `n` side by side becomes stacked, and back.
    pub fn turn(l: *Layout, n: u8) void {
        if (l.nodes[n].split) l.nodes[n].dir = if (l.nodes[n].dir == .across) .down else .across;
    }

    /// Moves view `v` to where view `at` is among the same window's tabs
    /// (`at` moving one along); nothing when they are in different windows.
    pub fn placeTab(l: *Layout, v: u8, at: u8) void {
        const leaf = l.leafOf(v) orelse return;
        if (l.leafOf(at) != leaf or v == at) return;
        const n = &l.nodes[leaf];
        const from = std.mem.indexOfScalar(u8, n.tabList(), v).?;
        const to = std.mem.indexOfScalar(u8, n.tabList(), at).?;
        const cur = n.tabs[n.current];
        if (from > to) {
            std.mem.copyBackwards(u8, n.tabs[to + 1 .. from + 1], n.tabs[to..from]);
        } else {
            std.mem.copyForwards(u8, n.tabs[from..to], n.tabs[from + 1 .. to + 1]);
        }
        n.tabs[to] = v;
        n.current = @intCast(std.mem.indexOfScalar(u8, n.tabList(), cur).?);
    }

    /// Fills the region with view `v` alone, or, when it already does,
    /// shows the splits again.
    pub fn toggleMaximize(l: *Layout, v: u8) void {
        if (l.maximized == v) {
            l.maximized = none;
            return;
        }
        l.select(v);
        l.maximized = v;
    }

    /// The open views showing `kind` `target`, into `out`.
    pub fn viewsOf(l: *const Layout, kind: Kind, target: u32, out: []u8) []u8 {
        var n: usize = 0;
        for (0..max_views) |i| if (l.open[i] and l.views[i].kind == kind and l.views[i].target == target and n < out.len) {
            out[n] = @intCast(i);
            n += 1;
        };
        return out[0..n];
    }
};

const testing = std.testing;

test "one view; split across and down; close collapses the split" {
    var l = Layout.init(.{ .target = 1 });
    try testing.expect(l.valid());
    const b = l.split(0, .across, .{ .target = 2 }).?;
    try testing.expectEqual(b, l.active);
    try testing.expect(l.nodes[l.root].split);
    const c = l.split(b, .down, .{ .target = 3 }).?;
    try testing.expect(l.valid());
    // Three leaves: the first part, and the second split in two.
    var leaves: usize = 0;
    for (l.nodes) |n| {
        if (n.used and !n.split) leaves += 1;
    }
    try testing.expectEqual(3, leaves);
    try testing.expect(l.close(c));
    try testing.expect(l.valid());
    try testing.expect(l.close(b));
    try testing.expect(l.valid());
    // Back to one leaf at the root; the last view stays.
    try testing.expect(!l.nodes[l.root].split);
    try testing.expect(!l.close(0));
}

test "tabs: added current and active; closing one shows its neighbour" {
    var l = Layout.init(.{ .target = 1 });
    const b = l.addTab(0, .{ .target = 2 }).?;
    const c = l.addTab(0, .{ .target = 3 }).?;
    try testing.expectEqual(c, l.currentOf(l.leafOf(0).?));
    l.select(b);
    try testing.expectEqual(b, l.active);
    try testing.expect(l.close(b));
    try testing.expect(l.valid());
    try testing.expectEqual(l.currentOf(l.leafOf(0).?), l.active);
    var buf: [4]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{c}, l.viewsOf(.canvas, 3, &buf));
}

test "maximize one view and back; a split ends it" {
    var l = Layout.init(.{});
    const b = l.split(0, .across, .{}).?;
    l.toggleMaximize(0);
    try testing.expectEqual(0, l.maximized);
    try testing.expectEqual(0, l.active);
    l.select(b);
    try testing.expectEqual(b, l.maximized);
    l.toggleMaximize(b);
    try testing.expectEqual(none, l.maximized);
    l.toggleMaximize(b);
    _ = l.split(b, .down, .{}).?;
    try testing.expectEqual(none, l.maximized);
}

test "a layout read back is checked before use" {
    var l = Layout.init(.{});
    _ = l.split(0, .across, .{}).?;
    try testing.expect(l.valid());
    var bad = l;
    bad.open[5] = true;
    try testing.expect(!bad.valid());
    bad = l;
    bad.nodes[bad.root].first = bad.nodes[bad.root].second;
    try testing.expect(!bad.valid());
    bad = l;
    bad.active = 9;
    try testing.expect(!bad.valid());
}

test "a tab moved to another's place" {
    var l = Layout.init(.{});
    const b = l.addTab(0, .{ .kind = .sheet, .target = 1 }).?;
    const c = l.addTab(0, .{ .kind = .sheet, .target = 2 }).?;
    const leaf = l.leafOf(0).?;
    l.placeTab(c, 0);
    try std.testing.expectEqualSlices(u8, &.{ c, 0, b }, l.nodes[leaf].tabList());
    try std.testing.expectEqual(c, l.currentOf(leaf));
    l.placeTab(c, b);
    try std.testing.expectEqualSlices(u8, &.{ 0, b, c }, l.nodes[leaf].tabList());
    try std.testing.expectEqual(c, l.currentOf(leaf));
}

test "a split's parts swapped, evened out, turned" {
    var l = Layout.init(.{});
    const b = l.split(0, .across, .{ .kind = .sheet, .target = 1 }).?;
    const n = l.splitOf(b).?;
    try std.testing.expectEqual(n, l.splitOf(0).?);
    l.nodes[n].ratio = 0.3;
    const first = l.nodes[n].first;
    l.swap(n);
    try std.testing.expectEqual(first, l.nodes[n].second);
    try std.testing.expectApproxEqAbs(0.7, l.nodes[n].ratio, 1e-6);
    try std.testing.expect(l.valid());
    l.evenOut(n);
    try std.testing.expectEqual(0.5, l.nodes[n].ratio);
    l.turn(n);
    try std.testing.expectEqual(.down, l.nodes[n].dir);
    try std.testing.expect(l.splitOf(0) != null and Layout.init(.{}).splitOf(0) == null);
}

test "a tab dragged to another window, and a window left empty goes" {
    var l = Layout.init(.{ .target = 1 });
    const b = l.addTab(0, .{ .target = 2 }).?;
    const c = l.split(b, .across, .{ .target = 3 }).?;
    // b to c's window, before c.
    try testing.expect(l.moveTab(b, c, c));
    try testing.expect(l.valid());
    try testing.expectEqualSlices(u8, &.{ b, c }, l.nodes[l.leafOf(c).?].tabList());
    try testing.expectEqual(b, l.active);
    // 0 too: its window empties and goes, the split with it.
    try testing.expect(l.moveTab(0, c, none));
    try testing.expect(l.valid());
    try testing.expect(!l.nodes[l.root].split);
    try testing.expectEqualSlices(u8, &.{ b, c, 0 }, l.nodes[l.root].tabList());
    // Within one window: moved along.
    try testing.expect(l.moveTab(0, b, b));
    try testing.expectEqualSlices(u8, &.{ 0, b, c }, l.nodes[l.root].tabList());
}

test "a tab dragged to a window's edge splits it" {
    var l = Layout.init(.{ .target = 1 });
    const b = l.addTab(0, .{ .target = 2 }).?;
    // Its own window, alone: nothing.
    const c = l.split(b, .across, .{ .target = 3 }).?;
    try testing.expect(!l.moveToSplit(c, c, .down, true));
    // b above c: c's window stacked, b first.
    try testing.expect(l.moveToSplit(b, c, .down, true));
    try testing.expect(l.valid());
    const p = l.splitOf(b).?;
    try testing.expectEqual(.down, l.nodes[p].dir);
    try testing.expectEqual(l.leafOf(b).?, l.nodes[p].first);
    try testing.expectEqual(p, l.splitOf(c).?);
    // c to the left of 0, its window going: three views, two splits.
    try testing.expect(l.moveToSplit(c, 0, .across, true));
    try testing.expect(l.valid());
    try testing.expectEqual(c, l.active);
}

test "tabs by key: along their window, and to the next window" {
    var l = Layout.init(.{});
    const b = l.addTab(0, .{ .target = 2 }).?;
    try testing.expectEqual(0, l.tabAlong(b, 1));
    try testing.expectEqual(0, l.tabAlong(b, -1));
    // One window: b split off beside it.
    try testing.expect(l.moveToNextWindow(b, false));
    try testing.expect(l.valid());
    var buf: [max_nodes]u8 = undefined;
    try testing.expectEqual(2, l.leaves(&buf).len);
    try testing.expectEqual(l.leafOf(b).?, l.leaves(&buf)[1]);
    // Back again: its window goes.
    try testing.expect(l.moveToNextWindow(b, true));
    try testing.expect(l.valid());
    try testing.expectEqual(1, l.leaves(&buf).len);
}
