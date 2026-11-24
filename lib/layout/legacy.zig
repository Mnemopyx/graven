//! Replaying op logs written before workspaces held containers directly
//! (2026-11-24). Until then each workspace (the canvas, a frame) had a
//! panel of its own standing in for it, its `root`, holding its loose
//! objects; ops named panels by index, that panel among them, and Make
//! panel and Release panel worked on loose line art. Such a log is
//! replayed with those panels present (the checkpoint read as it was
//! written, `native.decodeKeepingRoots`), each op's panel indices taken as
//! they were, and the ops that no longer exist done as they were then.
//! Afterwards `Model.upgradeRoots` takes the panels away. Nothing here is
//! used by anything but `history.openFile`.

const std = @import("std");
const geom = @import("graven_geom");
const model = @import("model.zig");
const art_ = @import("art.zig");

const Model = model.Model;
const Panel = model.Panel;
const PanelArt = model.PanelArt;
const ObjectId = model.ObjectId;
const Error = Model.Error;

/// A workspace's own panel, as the canvas and frames were made with.
fn addRoot(m: *Model, space: usize) Error!void {
    const sp = &m.spaces.items[space];
    const id = m.newId();
    try m.panels.append(m.arena.allocator(), .{ .id = id, .name = sp.name, .space = sp.id, .w = 0, .h = 0, .margins = .all(0), .default_margins = false });
    sp.old_root = id;
}

fn isRoot(m: *const Model, panel: usize) bool {
    const id = m.panels.items[panel].id;
    for (m.spaces.items) |sp| if (sp.old_root == id) return true;
    return false;
}

pub fn startCanvas(m: *Model, units: model.Units) Error!usize {
    const s = try m.startCanvas(units);
    try addRoot(m, s);
    return s;
}

pub fn addFrame(m: *Model, name: []const u8, edge: ?geom.Box) Error!usize {
    const s = try m.addFrame(name, edge);
    try addRoot(m, s);
    return s;
}

/// Make panel as it was: loose line art `index` on workspace panel
/// `root`, a closed path, becomes the edge of a new panel there, and what
/// it encloses moves onto the panel.
pub fn makePanel(m: *Model, root: usize, index: usize) Error!usize {
    if (root >= m.panels.items.len or !isRoot(m, root)) return error.NoSuchItem;
    const rp = m.panels.items[root];
    if (index >= rp.art.items.len) return error.NoSuchItem;
    const edge_art = rp.art.items[index];
    const path = edge_art.closedPath() orelse return error.NoSuchItem;
    const b = edge_art.box();
    if (!(b.width() > 0 and b.height() > 0)) return error.BadSize;
    const at = edge_art.at;
    const inside = struct {
        fn f(o: geom.Outline, off: geom.Point, q: geom.Point) bool {
            return art_.contains(o, .{ .x = q.x - off.x, .y = q.y - off.y });
        }
        fn box(o: geom.Outline, off: geom.Point, bx: geom.Box) bool {
            if (bx.isEmpty()) return false;
            return f(o, off, .{ .x = bx.x0, .y = bx.y0 }) and f(o, off, .{ .x = bx.x1, .y = bx.y0 }) and
                f(o, off, .{ .x = bx.x0, .y = bx.y1 }) and f(o, off, .{ .x = bx.x1, .y = bx.y1 });
        }
    };
    var name_buf: [64]u8 = undefined;
    const name = m.nextPanelName(&name_buf, rp.space, "Panel");
    const origin: geom.Point = .{ .x = rp.origin.x + b.x0, .y = rp.origin.y + b.y0 };
    const d: geom.Point = .{ .x = rp.origin.x - origin.x, .y = rp.origin.y - origin.y };
    var p: Panel = .{
        .id = m.newId(),
        .name = try m.arena.allocator().dupe(u8, name),
        .default_name = true,
        .space = rp.space,
        .origin = origin,
        .w = b.width(),
        .h = b.height(),
    };
    var e = edge_art;
    e.at = .{ .x = at.x + d.x, .y = at.y + d.y };
    e.cutout = false;
    p.edge = e;
    const src = &m.panels.items[root];
    var i = src.regions.items.len;
    while (i > 0) {
        i -= 1;
        const r = src.regions.items[i];
        if (!inside.box(path, at, r.bounds())) continue;
        var moved = src.regions.orderedRemove(i);
        moved.origin = .{ .x = moved.origin.x + d.x, .y = moved.origin.y + d.y };
        try p.regions.insert(m.arena.allocator(), 0, moved);
    }
    i = src.art.items.len;
    while (i > 0) {
        i -= 1;
        if (i == index) continue;
        if (!inside.box(path, at, src.art.items[i].box())) continue;
        var moved = src.art.orderedRemove(i);
        moved.at = .{ .x = moved.at.x + d.x, .y = moved.at.y + d.y };
        try p.art.insert(m.arena.allocator(), 0, moved);
    }
    for (src.art.items, 0..) |x, k| if (x.id == edge_art.id) {
        _ = src.art.orderedRemove(k);
        break;
    };
    for (p.regions.items) |x| m.forget(x.id);
    for (p.art.items) |x| m.forget(x.id);
    m.replaceMember(edge_art.id, p.id);
    try m.panels.append(m.arena.allocator(), p);
    m.revision += 1;
    return m.panels.items.len - 1;
}

/// Release panel as it was: the panel goes, its edge becomes loose line
/// art on its workspace's own panel, its tracks and line art loose there.
pub fn releasePanel(m: *Model, panel: usize) Error!ObjectId {
    if (panel >= m.panels.items.len or isRoot(m, panel)) return error.NoSuchItem;
    const p = m.panels.items[panel];
    const space = m.spaceOf(panel);
    const root_before = m.panelIndex(m.spaces.items[space].old_root) orelse return error.NoSuchItem;
    const rp = m.panels.items[root_before];
    const d: geom.Point = .{ .x = p.origin.x - rp.origin.x, .y = p.origin.y - rp.origin.y };
    var e: PanelArt = p.edge orelse blk: {
        const prim: art_.Primitive = .{ .rect = .{ .w = p.w, .h = p.h } };
        break :blk .{
            .id = m.newId(),
            .name = try m.arena.allocator().dupe(u8, p.name),
            .at = .{ .x = 0, .y = 0 },
            .shapes = try art_.primitive(m.arena.allocator(), try m.arena.allocator().dupe(u8, p.name), prim, .{ .edge = .{ .r = 0x33, .g = 0x33, .b = 0x33 } }),
            .prim = prim,
            .wrap = .none,
        };
    };
    if (e.id == .none) e.id = m.newId();
    e.at = .{ .x = e.at.x + d.x, .y = e.at.y + d.y };
    const dst = &m.panels.items[root_before];
    if (p.sketch != .none) {
        try m.spaces.items[space].sketch_views.append(m.arena.allocator(), .{ .id = e.id, .sketch = p.sketch, .at = p.sketch_at, .layer = p.layer });
    } else try dst.art.append(m.arena.allocator(), e);
    for (p.regions.items) |r| {
        var x = r;
        x.origin = .{ .x = x.origin.x + d.x, .y = x.origin.y + d.y };
        try dst.regions.append(m.arena.allocator(), x);
    }
    for (p.art.items) |pa| {
        var x = pa;
        x.at = .{ .x = x.at.x + d.x, .y = x.at.y + d.y };
        try dst.art.append(m.arena.allocator(), x);
    }
    m.replaceMember(p.id, e.id);
    _ = m.panels.orderedRemove(panel);
    m.revision += 1;
    return e.id;
}
