//! Solving a model into placed tiles and labels.
//!
//! Rows are spring chains (geom.spring): each tile packs against the one
//! before it through the gap set before it, and a tile spanning rows is
//! pinned, in every row after its first, where its first row put it.
//! Labels are rendered by the engine through `Labels`, a cache keyed by
//! style, markup, box and anchor, so identical legends share one render.

const std = @import("std");
const engine = @import("graven_engine");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const geom = engine.geom;
const spring = geom.spring;
const Box = geom.Box;
const Point = geom.Point;
const Model = model.Model;
const TileId = model.TileId;
const StyleId = model.StyleId;

pub const PlacedTile = struct {
    id: TileId,
    region: usize,
    /// The row that placed it.
    row: usize,
    /// Its share of the pitch grid, its body and its labelling face, mm in
    /// the panel frame.
    pitch_box: Box,
    body: Box,
    face: Box,
};

pub const PlacedLabel = struct {
    /// The tile whose slot holds it; null for a label placed directly on
    /// the panel.
    tile: ?TileId,
    /// The slot's index on the tile, or the label's index on the panel.
    slot: usize,
    /// The slot's box, mm in the panel frame; for a panel label, its ink
    /// box there.
    box: Box,
    /// Where the label frame's origin sits in the panel frame; the render's
    /// geometry is relative to it.
    origin: Point,
    style: StyleId,
    /// Owned by the `Labels` cache, valid until it next changes.
    render: *const engine.Render,
};

pub const Issue = struct {
    kind: enum {
        /// A row is longer than its region, or meets a spanning tile.
        row_overflow,
        /// A label does not fit its slot.
        label_overflow,
        /// A label has characters no face covers.
        missing_glyph,
        /// A label's markup does not parse. It is stored as typed and drawn
        /// from a lenient parse, with placeholders and faint text; `syntax`
        /// says what and where.
        markup_error,
        /// A style cannot be used (its face has no cap height, say).
        style_error,
        /// A tile's size is not one its prototype allows.
        tile_size,
    },
    tile: ?TileId = null,
    slot: ?usize = null,
    /// A label placed directly on the panel, by index.
    label: ?usize = null,
    region: ?usize = null,
    row: ?usize = null,
    /// How far too long, mm, for overflows.
    amount: f64 = 0,
    /// For a markup error, the first problem the parse found.
    syntax: ?engine.markup.Diagnostic = null,
};

pub const Placed = struct {
    arena: std.heap.ArenaAllocator,
    tiles: []const PlacedTile,
    labels: []const PlacedLabel,
    issues: []const Issue,
    /// The union of the tiles' pitch boxes.
    bounds: Box,

    pub fn deinit(p: *Placed) void {
        p.arena.deinit();
        p.* = undefined;
    }

    pub fn findTile(p: *const Placed, id: TileId) ?*const PlacedTile {
        for (p.tiles) |*t| if (t.id == id) return t;
        return null;
    }
};

/// Renders labels for one face table, caching each render.
pub const Labels = struct {
    gpa: Allocator,
    faces: []const *engine.Face,
    contexts: std.ArrayList(?Ctx) = .empty,
    cache: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,

    const Ctx = struct { spec: engine.style.Spec, ctx: ?engine.style.Context };

    const Key = struct {
        style: StyleId,
        anchor: model.Align,
        /// The hard box relative to the anchor point; null for none.
        box: ?[4]f64,
        markup: []const u8,
    };

    const Entry = struct {
        render: ?*engine.Render,
    };

    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(std.mem.asBytes(&k.style));
            h.update(std.mem.asBytes(&k.anchor));
            h.update(std.mem.asBytes(&(k.box orelse [4]f64{ 0, 0, 0, 0 })));
            h.update(&.{@intFromBool(k.box != null)});
            h.update(k.markup);
            return h.final();
        }
        pub fn eql(_: KeyContext, x: Key, y: Key) bool {
            const boxes = if (x.box) |xb| (if (y.box) |yb| std.mem.eql(f64, &xb, &yb) else false) else y.box == null;
            return x.style == y.style and x.anchor == y.anchor and boxes and std.mem.eql(u8, x.markup, y.markup);
        }
    };

    /// `faces` must outlive the cache.
    pub fn init(gpa: Allocator, faces: []const *engine.Face) Labels {
        return .{ .gpa = gpa, .faces = faces };
    }

    pub fn deinit(l: *Labels) void {
        l.clear();
        l.cache.deinit(l.gpa);
        l.contexts.deinit(l.gpa);
        l.* = undefined;
    }

    /// Drops every cached render.
    pub fn clear(l: *Labels) void {
        var it = l.cache.iterator();
        while (it.next()) |e| l.free(e.key_ptr.*, e.value_ptr.*);
        l.cache.clearRetainingCapacity();
    }

    fn free(l: *Labels, k: Key, e: Entry) void {
        l.gpa.free(k.markup);
        if (e.render) |r| {
            r.deinit();
            l.gpa.destroy(r);
        }
    }

    /// Brings the style contexts up to date with the model, dropping renders
    /// of any style whose spec changed.
    pub fn sync(l: *Labels, m: *const Model) Allocator.Error!void {
        while (l.contexts.items.len < m.styles.items.len) try l.contexts.append(l.gpa, null);
        for (m.styles.items, 0..) |s, i| {
            const cur = &l.contexts.items[i];
            if (cur.*) |c| if (std.mem.eql(u8, std.mem.asBytes(&c.spec), std.mem.asBytes(&s.spec))) continue;
            const usable = s.spec.upright < l.faces.len and
                (s.spec.italic orelse 0) < l.faces.len and
                for (s.spec.fallbacks) |f| {
                    if (f >= l.faces.len) break false;
                } else true;
            const ctx = if (usable) engine.style.Context.init(l.faces, s.spec) catch null else null;
            cur.* = .{ .spec = s.spec, .ctx = ctx };
            l.dropStyle(@intCast(i));
        }
    }

    fn dropStyle(l: *Labels, style: StyleId) void {
        var it = l.cache.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.style != style) continue;
            const k = e.key_ptr.*;
            const v = e.value_ptr.*;
            l.cache.removeByPtr(e.key_ptr);
            l.free(k, v);
            it = l.cache.iterator();
        }
    }

    pub fn context(l: *const Labels, style: StyleId) ?*const engine.style.Context {
        if (style >= l.contexts.items.len) return null;
        if (l.contexts.items[style]) |*c| if (c.ctx) |*ctx| return ctx;
        return null;
    }

    /// The render for a label, from the cache or made now; null when the
    /// markup does not parse or the style cannot be used.
    fn get(l: *Labels, k: Key) Allocator.Error!?*const engine.Render {
        if (l.cache.get(k)) |e| return e.render;
        const ctx = l.context(k.style) orelse return null;
        const anchor: engine.Anchor = switch (k.anchor) {
            .start => .start,
            .centre => .centre,
            .end => .end,
        };
        var syntax: engine.markup.Diagnostic = undefined;
        const render: ?*engine.Render = blk: {
            // Always the lenient parse: markup being typed still draws, and
            // its problems come back in the render's `syntax`.
            const r = engine.renderLabel(l.gpa, ctx, k.markup, .{
                .anchor = anchor,
                .hard_box = if (k.box) |b| .{ .x0 = b[0], .y0 = b[1], .x1 = b[2], .y1 = b[3] } else null,
                .preview = true,
            }, &syntax) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk null,
            };
            const p = try l.gpa.create(engine.Render);
            p.* = r;
            break :blk p;
        };
        var owned = k;
        owned.markup = try l.gpa.dupe(u8, k.markup);
        try l.cache.put(l.gpa, owned, .{ .render = render });
        return render;
    }
};

pub const Error = Allocator.Error || spring.Error;

/// Places every tile and label of one panel.
pub fn solve(gpa: Allocator, m: *const Model, panel: usize, labels: *Labels) Error!Placed {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    try labels.sync(m);

    var tiles: std.ArrayList(PlacedTile) = .empty;
    var issues: std.ArrayList(Issue) = .empty;
    var bounds: Box = .empty;

    for (m.panels.items[panel].regions.items, 0..) |region, ri| {
        // Where each tile placed so far starts, along its region's rows.
        var placed_at: std.AutoHashMapUnmanaged(TileId, f64) = .empty;
        var items: std.ArrayList(spring.Item) = .empty;
        var links: std.ArrayList(spring.Link) = .empty;
        var top = region.origin.y;
        for (region.rows.items, 0..) |row, rowi| {
            top -= row.gap * region.pitch;
            items.clearRetainingCapacity();
            links.clearRetainingCapacity();
            for (row.places.items) |p| {
                const t = m.tileConst(p.tile);
                const pin = placed_at.get(p.tile);
                try links.append(a, .{ .min = if (pin == null) p.gap * region.pitch else 0 });
                try items.append(a, .{ .size = t.w * region.pitch, .pin = pin });
            }
            try links.append(a, .{});
            var chain = try spring.solve(gpa, region.w * region.pitch, items.items, links.items);
            defer chain.deinit(gpa);
            for (chain.issues) |ci| try issues.append(a, .{ .kind = .row_overflow, .region = ri, .row = rowi, .amount = ci.amount });

            for (row.places.items, chain.at) |p, x| {
                if (placed_at.contains(p.tile)) continue;
                try placed_at.put(a, p.tile, x);
                const t = m.tileConst(p.tile);
                const pitch_box: Box = .{
                    .x0 = region.origin.x + x,
                    .x1 = region.origin.x + x + t.w * region.pitch,
                    .y1 = top,
                    .y0 = top - t.h * region.pitch,
                };
                const proto = &m.prototypes.items[t.prototype];
                const body = proto.body_inset.inset(pitch_box);
                try tiles.append(a, .{
                    .id = p.tile,
                    .region = ri,
                    .row = rowi,
                    .pitch_box = pitch_box,
                    .body = body,
                    .face = proto.face_inset.inset(body),
                });
                if (!proto.allows(t.w, t.h)) try issues.append(a, .{ .kind = .tile_size, .tile = p.tile, .region = ri, .row = rowi });
                bounds = bounds.join(pitch_box);
            }
            top -= region.pitch;
        }
    }

    var placed_labels: std.ArrayList(PlacedLabel) = .empty;
    for (tiles.items) |pt| {
        for (0..m.slotCount(pt.id)) |si| {
            const slot = m.slot(pt.id, si);
            if (slot.content.len == 0) continue;
            const ctx = labels.context(slot.style) orelse {
                try issues.append(a, .{ .kind = .style_error, .tile = pt.id, .slot = si });
                continue;
            };
            const box = slot.place.inset.inset(pt.face);
            const cap = ctx.spec.cap_height;
            const at: Point = .{
                .x = switch (slot.place.h) {
                    .start => box.x0,
                    .centre => (box.x0 + box.x1) / 2,
                    .end => box.x1,
                },
                .y = switch (slot.place.v) {
                    .start => box.y1 - cap,
                    .centre => (box.y0 + box.y1 - cap) / 2,
                    .end => box.y0,
                },
            };
            const render = (try labels.get(.{
                .style = slot.style,
                .anchor = slot.place.h,
                .box = .{ snap(box.x0 - at.x), snap(box.y0 - at.y), snap(box.x1 - at.x), snap(box.y1 - at.y) },
                .markup = slot.content,
            })) orelse {
                try issues.append(a, .{ .kind = .markup_error, .tile = pt.id, .slot = si });
                continue;
            };
            if (render.syntax.len > 0) try issues.append(a, .{ .kind = .markup_error, .tile = pt.id, .slot = si, .syntax = render.syntax[0] });
            const shift = render.anchor_at orelse Point{ .x = 0, .y = 0 };
            try placed_labels.append(a, .{
                .tile = pt.id,
                .slot = si,
                .box = box,
                .origin = .{ .x = at.x + shift.x, .y = at.y + shift.y },
                .style = slot.style,
                .render = render,
            });
            var overflow = false;
            var missing = false;
            for (render.diagnostics) |d| switch (d.kind) {
                .overflow => overflow = true,
                .missing_glyph => missing = true,
                else => {},
            };
            if (overflow) try issues.append(a, .{ .kind = .label_overflow, .tile = pt.id, .slot = si });
            if (missing) try issues.append(a, .{ .kind = .missing_glyph, .tile = pt.id, .slot = si });
        }
    }

    // Labels placed directly on the panel: one line from their anchor.
    for (m.panels.items[panel].labels.items, 0..) |pl, li| {
        if (pl.content.len == 0) continue;
        if (labels.context(pl.style) == null) {
            try issues.append(a, .{ .kind = .style_error, .label = li });
            continue;
        }
        const render = (try labels.get(.{ .style = pl.style, .anchor = pl.alignment, .box = null, .markup = pl.content })) orelse {
            try issues.append(a, .{ .kind = .markup_error, .label = li });
            continue;
        };
        if (render.syntax.len > 0) try issues.append(a, .{ .kind = .markup_error, .label = li, .syntax = render.syntax[0] });
        const ink = render.ink;
        try placed_labels.append(a, .{
            .tile = null,
            .slot = li,
            .box = if (ink.isEmpty()) .{ .x0 = pl.at.x, .y0 = pl.at.y, .x1 = pl.at.x, .y1 = pl.at.y } else .{ .x0 = pl.at.x + ink.x0, .y0 = pl.at.y + ink.y0, .x1 = pl.at.x + ink.x1, .y1 = pl.at.y + ink.y1 },
            .origin = pl.at,
            .style = pl.style,
            .render = render,
        });
        for (render.diagnostics) |d| if (d.kind == .missing_glyph) {
            try issues.append(a, .{ .kind = .missing_glyph, .label = li });
            break;
        };
    }

    return .{
        .arena = arena,
        .tiles = try tiles.toOwnedSlice(a),
        .labels = try placed_labels.toOwnedSlice(a),
        .issues = try issues.toOwnedSlice(a),
        .bounds = bounds,
    };
}

/// Rounds a cache-key length to 1 nm, so the same box reached by different
/// sums of positions is one key.
fn snap(v: f64) f64 {
    return @round(v * 1e6) / 1e6;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const testdata = @import("graven_testdata");

test "rows pack by gaps and a spanning tile is pinned in its later rows" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const r = try m.addRegion(p, .{ .name = "pad", .origin = .{ .x = 10, .y = 90 }, .w = 4, .h = 2, .pitch = 10 });
    _ = try m.addRow(p, r, 0);
    _ = try m.addRow(p, r, 0);
    const one = try m.addTile(.{ .designator = "1" });
    const two = try m.addTile(.{ .designator = "2" });
    const tall = try m.addTile(.{ .designator = "T", .h = 2 });
    const wide = try m.addTile(.{ .designator = "0", .w = 2 });
    try m.place(p, r, 0, null, .{ .tile = one });
    try m.place(p, r, 0, null, .{ .tile = two, .gap = 0.5 });
    try m.place(p, r, 0, null, .{ .tile = tall });
    try m.place(p, r, 1, null, .{ .tile = wide });
    try m.place(p, r, 1, null, .{ .tile = tall });

    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(4, s.tiles.len);
    try testing.expectEqual(25, s.findTile(two).?.pitch_box.x0);
    try testing.expectEqual(35, s.findTile(tall).?.pitch_box.x0);
    try testing.expectEqual(70, s.findTile(tall).?.pitch_box.y0);
    try testing.expectEqual(80, s.findTile(wide).?.pitch_box.y1);
    try testing.expectEqual(0, s.issues.len);
}

test "a row too long for its region is reported" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 100 }, .w = 2, .h = 1, .pitch = 10 });
    _ = try m.addRow(p, r, 0);
    for ([_][]const u8{ "A", "B", "C" }) |d| try m.place(p, r, 0, null, .{ .tile = try m.addTile(.{ .designator = d }) });
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(1, s.issues.len);
    try testing.expectEqual(.row_overflow, s.issues[0].kind);
    try testing.expectEqual(10, s.issues[0].amount);
}

test "labels render once per identical legend and sit in their slots" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};

    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 3, .h = 1, .pitch = 19.05 });
    _ = try m.addRow(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .body_inset = .all(0.5), .face_inset = .all(2), .slots = &.{.{ .name = "top", .style = style, .place = .{ .inset = .all(1) } }} });
    for ([_][]const u8{ "K1", "K2" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setContent(t, "top", "H");
        try m.place(p, r, 0, null, .{ .tile = t });
    }
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(2, s.labels.len);
    try testing.expectEqual(s.labels[0].render, s.labels[1].render);
    try testing.expectEqual(1, labels.cache.count());
    // Top-left: baseline one cap height below the slot's top.
    const l = s.labels[0];
    try testing.expectApproxEqAbs(l.box.y1 - 3, l.origin.y, 1e-12);
    try testing.expect(l.origin.x + l.render.ink.x0 >= l.box.x0 - 1e-12);

    // A style change drops its renders.
    m.setStyle(style, .{ .upright = 0, .cap_height = 2.5 });
    var s2 = try solve(gpa, &m, p, &labels);
    defer s2.deinit();
    try testing.expectEqual(1, labels.cache.count());
    try testing.expectApproxEqAbs(s2.labels[0].box.y1 - 2.5, s2.labels[0].origin.y, 1e-12);
}

test "a panel label sits on its anchor, aligned as asked" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    _ = try m.addLabel(p, .{ .at = .{ .x = 50, .y = 20 }, .alignment = .centre, .style = style, .content = "HH" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(1, s.labels.len);
    const l = s.labels[0];
    try testing.expect(l.tile == null);
    // Centred: the ink straddles the anchor; on the baseline: it rises from it.
    try testing.expectApproxEqAbs(50, (l.box.x0 + l.box.x1) / 2, 0.5);
    try testing.expectApproxEqAbs(20, l.box.y0, 1e-9);
    try testing.expectApproxEqAbs(23, l.box.y1, 1e-9);
}

test "a label being typed is stored as typed, flagged, and still drawn" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    _ = try m.addLabel(p, .{ .at = .{ .x = 10, .y = 10 }, .style = style, .content = "H^" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqualStrings("H^", m.panels.items[p].labels.items[0].content);
    try testing.expectEqual(1, s.labels.len);
    try testing.expectEqual(1, s.issues.len);
    try testing.expectEqual(.markup_error, s.issues[0].kind);
    try testing.expectEqual(.missing_argument, s.issues[0].syntax.?.kind);
    // The H and a placeholder for the superscript still to come.
    var placeholders: usize = 0;
    for (s.labels[0].render.items) |item| switch (item) {
        .path => |pth| if (pth.role == .placeholder) {
            placeholders += 1;
        },
        else => {},
    };
    try testing.expectEqual(1, placeholders);
}

test "a legend with characters no face covers is reported on its tile" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 3, .h = 1, .pitch = 19.05 });
    _ = try m.addRow(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .slots = &.{.{ .name = "top", .style = style }} });
    const t = try m.addTile(.{ .designator = "K1", .prototype = key });
    try m.setContent(t, "top", "HQ");
    try m.place(p, r, 0, null, .{ .tile = t });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(1, s.issues.len);
    try testing.expectEqual(.missing_glyph, s.issues[0].kind);
    try testing.expectEqual(t, s.issues[0].tile.?);
}

test "changing a prototype changes every tile made from it" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 4, .h = 1, .pitch = 19.05 });
    _ = try m.addRow(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .body_inset = .all(0.5), .face_inset = .all(2) });
    const flat = try m.addPrototype(.{ .name = "flat" });
    for ([_][]const u8{ "K1", "K2", "K3" }) |d| try m.place(p, r, 0, null, .{ .tile = try m.addTile(.{ .designator = d, .prototype = key }) });
    try m.setTilePrototype(m.findTile("K3").?, flat);

    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var before = try solve(gpa, &m, p, &labels);
    defer before.deinit();
    try testing.expectApproxEqAbs(@as(f64, 2.5), before.tiles[0].face.x0 - before.tiles[0].pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), before.tiles[2].face.x0 - before.tiles[2].pitch_box.x0, 1e-9);

    // A wider face inset on the prototype: K1 and K2 follow, K3 does not.
    try m.setPrototype(key, .{ .name = "key", .body_inset = .all(0.5), .face_inset = .all(3) });
    var after = try solve(gpa, &m, p, &labels);
    defer after.deinit();
    for (after.tiles[0..2]) |t| try testing.expectApproxEqAbs(@as(f64, 3.5), t.face.x0 - t.pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), after.tiles[2].face.x0 - after.tiles[2].pitch_box.x0, 1e-9);
    try testing.expectError(error.NoSuchPrototype, m.setTilePrototype(m.findTile("K1").?, 9));
}

test "changing a prototype's slot moves every legend in it, but not a tile's own" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 4, .h = 1, .pitch = 19.05 });
    _ = try m.addRow(p, r, 0);
    const top: model.SlotPrototype = .{ .name = "top", .style = style, .place = .{ .inset = .all(1) } };
    const key = try m.addPrototype(.{ .name = "key", .face_inset = .all(2), .slots = &.{top} });
    for ([_][]const u8{ "K1", "K2", "K3" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setContent(t, "top", "H");
        try m.place(p, r, 0, null, .{ .tile = t });
    }
    try m.setSlotPlace(m.findTile("K3").?, "top", .{ .inset = .all(1) });

    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var before = try solve(gpa, &m, p, &labels);
    defer before.deinit();
    var moved = top;
    moved.place.inset = .{ .left = 3, .right = 1, .top = 1, .bottom = 1 };
    try m.setPrototype(key, .{ .name = "key", .face_inset = .all(2), .slots = &.{moved} });
    var after = try solve(gpa, &m, p, &labels);
    defer after.deinit();
    try testing.expectEqual(3, after.labels.len);
    for (before.labels, after.labels, 0..) |b, a, i| {
        const dx = a.box.x0 - b.box.x0;
        try testing.expectApproxEqAbs(@as(f64, if (i < 2) 2 else 0), dx, 1e-9);
    }
}
