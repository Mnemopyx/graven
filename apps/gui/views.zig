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

pub const Kind = enum { canvas, sheet };

/// A view: what it shows, and where it looks (a canvas's centre, mm, and
/// zoom, px/mm; 0 until it has been shown).
pub const View = struct {
    kind: Kind = .canvas,
    /// A canvas: its space's ID; a sheet: the sheet's.
    target: u32 = 0,
    cx: f64 = 0,
    cy: f64 = 0,
    ppm: f64 = 0,
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
        const a = l.newNode() orelse return null;
        const b = l.newNode() orelse {
            l.nodes[a] = .{};
            return null;
        };
        const nv = l.newView(view) orelse {
            l.nodes[a] = .{};
            l.nodes[b] = .{};
            return null;
        };
        // The first part takes the leaf's tabs; the leaf becomes the split.
        l.nodes[a] = l.nodes[leaf];
        l.nodes[a].parent = leaf;
        l.nodes[b].parent = leaf;
        l.nodes[b].tabs[0] = nv;
        l.nodes[b].tab_count = 1;
        const parent = l.nodes[leaf].parent;
        l.nodes[leaf] = .{ .used = true, .parent = parent, .split = true, .dir = dir, .first = a, .second = b };
        l.maximized = none;
        l.select(nv);
        return nv;
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
        const k = std.mem.indexOfScalar(u8, n.tabList(), v).?;
        std.mem.copyForwards(u8, n.tabs[k .. n.tab_count - 1], n.tabs[k + 1 .. n.tab_count]);
        n.tab_count -= 1;
        n.tabs[n.tab_count] = none;
        if (n.current >= n.tab_count and n.current > 0) n.current -= 1;
        l.open[v] = false;
        if (l.maximized == v) l.maximized = none;
        if (n.tab_count == 0) {
            // The other part of its split takes the split's place.
            const p = n.parent;
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
