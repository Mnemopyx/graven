//! Solving a model into placed tiles and labels.
//!
//! A track's flow is poured through its segments (rows or columns) in
//! order: each item packs against the one before it through the gap set
//! before it; an item that does not fit moves to the next segment, and a
//! hard break ends its segment. A tile spanning segments is pinned, in
//! every segment after its first, where its first one put it. Text and
//! equations (runs of markup) flow with the tiles, set on a baseline.
//! Labels are rendered by the engine through `Labels`, a cache keyed by
//! style, markup, box and anchor, so identical legends share one render.

const std = @import("std");
const engine = @import("graven_engine");
const model = @import("model.zig");
const art = @import("art.zig");

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
    /// The segment that placed it.
    row: usize,
    /// Its share of the pitch grid, its body and its labelling face, mm in
    /// the panel frame.
    pitch_box: Box,
    body: Box,
    face: Box,
    /// How it looks: its prototype's art stretched onto it, back to front,
    /// mm in the panel frame.
    shapes: []const art.Shape,
};

pub const PlacedLabel = struct {
    /// The run in a track's flow it sets, if it is one: then `tile` is
    /// null and `slot` is the item's index.
    run: ?struct { region: usize, item: usize } = null,
    /// The tile whose slot holds it; null for a label placed directly on
    /// the panel, or a run.
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
        /// A segment's content runs past its end (past the last segment's,
        /// when the flow overflows), or meets a spanning tile.
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
        /// A region's tracks reach past its panel's outline; `amount` says
        /// how far, mm.
        region_outside,
        /// A tile's art cannot be stretched exactly (a curve crosses a cut);
        /// it is drawn plain.
        tile_art,
    },
    tile: ?TileId = null,
    slot: ?usize = null,
    /// A label placed directly on the panel, by index.
    label: ?usize = null,
    region: ?usize = null,
    row: ?usize = null,
    /// The item in a region's flow, for a run of markup.
    item: ?usize = null,
    /// How far too long, mm, for overflows.
    amount: f64 = 0,
    /// For a markup error, the first problem the parse found.
    syntax: ?engine.markup.Diagnostic = null,
};

/// A segment as placed: where its band lies.
pub const PlacedTrack = struct {
    region: usize,
    /// The segment's index in its region.
    track: usize,
    major: model.Major,
    /// The segment's band, mm in the panel frame: its length along, one
    /// pitch across.
    box: Box,
};

/// An item of a track's flow as placed: the segment it landed in, and
/// where it starts and ends along it, mm from the segment's start. A hard
/// break has no length; it sits where its segment's content ends.
pub const PlacedItem = struct {
    region: usize,
    /// Its index in the region's flow.
    index: usize,
    segment: usize,
    span: [2]f64,
};

/// What a region's flow needs: the length, u, that would set its longest
/// paragraph (the items between hard breaks) in one segment.
pub const PlacedFlow = struct {
    region: usize,
    natural: f64,
};

pub const Placed = struct {
    arena: std.heap.ArenaAllocator,
    tiles: []const PlacedTile,
    tracks: []const PlacedTrack = &.{},
    items: []const PlacedItem = &.{},
    flows: []const PlacedFlow = &.{},
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
    var tracks: std.ArrayList(PlacedTrack) = .empty;
    var issues: std.ArrayList(Issue) = .empty;
    var bounds: Box = .empty;

    var placed_items: std.ArrayList(PlacedItem) = .empty;
    var flows: std.ArrayList(PlacedFlow) = .empty;
    var placed_labels: std.ArrayList(PlacedLabel) = .empty;
    const outline: Box = .{ .x0 = 0, .y0 = 0, .x1 = m.panels.items[panel].w, .y1 = m.panels.items[panel].h };
    for (m.panels.items[panel].regions.items, 0..) |region, ri| {
        const segs = region.segments.items;
        // A region's segments may run or be moved past its panel's edge, to
        // be fitted later: flagged, not refused.
        {
            var b: Box = if (segs.len == 0) .{
                .x0 = region.origin.x,
                .x1 = region.origin.x + region.w * region.pitch,
                .y1 = region.origin.y,
                .y0 = region.origin.y - region.h * region.pitch,
            } else .empty;
            for (0..segs.len) |t| b = b.join(region.segmentBox(t));
            const past = @max(@max(outline.x0 - b.x0, b.x1 - outline.x1), @max(outline.y0 - b.y0, b.y1 - outline.y1));
            if (past > 1e-9) try issues.append(a, .{ .kind = .region_outside, .region = ri, .amount = past });
        }
        for (0..segs.len) |t| try tracks.append(a, .{ .region = ri, .track = t, .major = region.major, .box = region.segmentBox(t) });
        if (segs.len == 0) continue;

        // Rows run right and stack down; columns run down and set to the
        // right. An item's size along is its width in a row and its height
        // in a column.
        const rows = region.major == .row;
        const length = region.segmentLength() * region.pitch;
        const tol = 1e-9;
        // Where each tile placed so far starts, along its segment.
        var placed_at: std.AutoHashMapUnmanaged(TileId, f64) = .empty;
        // How far each segment's content reaches, mm.
        const reach = try a.alloc(f64, segs.len);
        @memset(reach, 0);
        var seg: usize = 0;
        var pos: f64 = 0;
        var in_seg: usize = 0;
        var para: f64 = 0;
        var natural: f64 = 0;
        for (region.items.items, 0..) |item, index| {
            if (item.what == .hard_break) {
                try placed_items.append(a, .{ .region = ri, .index = index, .segment = seg, .span = .{ pos, pos } });
                natural = @max(natural, para);
                para = 0;
                // Past the last segment the flow runs on along it, flagged.
                if (seg + 1 < segs.len) {
                    seg += 1;
                    pos = 0;
                    in_seg = 0;
                }
                continue;
            }
            const gap = item.gap * region.pitch;
            // The item's size along, and for a run its render.
            var run_render: ?*const engine.Render = null;
            const size: f64 = switch (item.what) {
                .tile => |id| blk: {
                    const t = m.tileConst(id);
                    break :blk (if (rows) t.w else t.h) * region.pitch;
                },
                .blank => |len| len * region.pitch,
                .run => |run| blk: {
                    if (run.content.len == 0) break :blk 0.5 * region.pitch;
                    if (labels.context(run.style) == null) {
                        try issues.append(a, .{ .kind = .style_error, .region = ri, .row = seg, .item = index });
                        break :blk 0.5 * region.pitch;
                    }
                    const render = (try labels.get(.{ .style = run.style, .anchor = .start, .box = null, .markup = run.content })) orelse break :blk 0.5 * region.pitch;
                    run_render = render;
                    const d = render.design;
                    break :blk if (d.isEmpty()) 0 else if (rows) d.x1 - d.x0 else d.y1 - d.y0;
                },
                .hard_break => unreachable,
            };
            const pin = if (item.tileOf()) |id| placed_at.get(id) else null;
            var start: f64 = undefined;
            if (pin) |at| {
                // The later entries of a spanning tile keep its room.
                if (pos > at + tol) try issues.append(a, .{ .kind = .row_overflow, .region = ri, .row = seg, .amount = pos - at });
                start = at;
                para = @max(para, at) + size;
            } else {
                start = pos + gap;
                para += gap + size;
                // It does not fit: on to the next segment, if there is one
                // and this one holds something already.
                if (start + size > length + tol and in_seg > 0 and seg + 1 < segs.len) {
                    seg += 1;
                    pos = 0;
                    in_seg = 0;
                    start = gap;
                }
            }
            const end = start + size;
            pos = @max(pos, end);
            in_seg += 1;
            reach[seg] = @max(reach[seg], end);
            try placed_items.append(a, .{ .region = ri, .index = index, .segment = seg, .span = .{ start, end } });

            const band = region.segmentBox(seg);
            switch (item.what) {
                .tile => |pid| {
                    if (pin != null) continue;
                    try placed_at.put(a, pid, start);
                    const t = m.tileConst(pid);
                    const w = t.w * region.pitch;
                    const h = t.h * region.pitch;
                    const x0 = if (rows) band.x0 + start else band.x0;
                    const y1 = if (rows) band.y1 else band.y1 - start;
                    const pitch_box: Box = .{ .x0 = x0, .x1 = x0 + w, .y1 = y1, .y0 = y1 - h };
                    const proto = &m.prototypes.items[t.prototype];
                    const body = proto.body_inset.inset(pitch_box);
                    const shapes = if (proto.art) |pa| art.stretch(a, pa, region.pitch, pitch_box) catch |err| switch (err) {
                        error.CurveCrossesCut => blk: {
                            try issues.append(a, .{ .kind = .tile_art, .tile = pid, .region = ri, .row = seg });
                            break :blk try art.plainShapes(a, proto.*, region.pitch, pitch_box);
                        },
                        else => |e| return e,
                    } else try art.plainShapes(a, proto.*, region.pitch, pitch_box);
                    try tiles.append(a, .{
                        .id = pid,
                        .region = ri,
                        .row = seg,
                        .pitch_box = pitch_box,
                        .body = body,
                        .face = proto.face_inset.inset(body),
                        .shapes = shapes,
                    });
                    if (!proto.allows(t.w, t.h)) try issues.append(a, .{ .kind = .tile_size, .tile = pid, .region = ri, .row = seg });
                    bounds = bounds.join(pitch_box);
                },
                .run => |run| {
                    const render = run_render orelse continue;
                    if (render.syntax.len > 0) try issues.append(a, .{ .kind = .markup_error, .region = ri, .row = seg, .item = index, .syntax = render.syntax[0] });
                    const d = render.design;
                    const cap = labels.context(run.style).?.spec.cap_height;
                    // On a baseline that centres its capitals across a
                    // row; centred across a column, one line below another.
                    const origin: Point = if (rows)
                        .{ .x = band.x0 + start - d.x0, .y = (band.y0 + band.y1 - cap) / 2 }
                    else
                        .{ .x = (band.x0 + band.x1 - (d.x1 - d.x0)) / 2 - d.x0, .y = band.y1 - start - d.y1 };
                    const box: Box = if (rows)
                        .{ .x0 = band.x0 + start, .x1 = band.x0 + end, .y0 = band.y0, .y1 = band.y1 }
                    else
                        .{ .x0 = band.x0, .x1 = band.x1, .y1 = band.y1 - start, .y0 = band.y1 - end };
                    try placed_labels.append(a, .{
                        .run = .{ .region = ri, .item = index },
                        .tile = null,
                        .slot = index,
                        .box = box,
                        .origin = origin,
                        .style = run.style,
                        .render = render,
                    });
                    for (render.diagnostics) |dg| if (dg.kind == .missing_glyph) {
                        try issues.append(a, .{ .kind = .missing_glyph, .region = ri, .row = seg, .item = index });
                        break;
                    };
                },
                else => {},
            }
        }
        natural = @max(natural, para);
        try flows.append(a, .{ .region = ri, .natural = natural / region.pitch });
        for (reach, 0..) |r_, t| if (r_ > length + tol) {
            try issues.append(a, .{ .kind = .row_overflow, .region = ri, .row = t, .amount = r_ - length });
        };
    }

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
        .tracks = try tracks.toOwnedSlice(a),
        .items = try placed_items.toOwnedSlice(a),
        .flows = try flows.toOwnedSlice(a),
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

test "segments pack by gaps, a hard break starts the next, and a spanning tile is pinned in its later ones" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const r = try m.addRegion(p, .{ .name = "pad", .origin = .{ .x = 10, .y = 90 }, .w = 4, .h = 2, .pitch = 10 });
    _ = try m.addSegment(p, r, 0);
    _ = try m.addSegment(p, r, 0);
    const one = try m.addTile(.{ .designator = "1" });
    const two = try m.addTile(.{ .designator = "2" });
    const tall = try m.addTile(.{ .designator = "T", .h = 2 });
    const wide = try m.addTile(.{ .designator = "0", .w = 2 });
    try m.place(p, r, null, .{ .what = .{ .tile = one } });
    try m.place(p, r, null, .{ .gap = 0.5, .what = .{ .tile = two } });
    try m.place(p, r, null, .{ .what = .{ .tile = tall } });
    try m.place(p, r, null, .{ .what = .hard_break });
    try m.place(p, r, null, .{ .what = .{ .tile = wide } });
    try m.place(p, r, null, .{ .what = .{ .tile = tall } });

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
    _ = try m.addSegment(p, r, 0);
    for ([_][]const u8{ "A", "B", "C" }) |d| try m.place(p, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = d }) } });
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
    _ = try m.addSegment(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .body_inset = .all(0.5), .face_inset = .all(2), .slots = &.{.{ .name = "top", .style = style, .place = .{ .inset = .all(1) } }} });
    for ([_][]const u8{ "K1", "K2" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setContent(t, "top", "H");
        try m.place(p, r, null, .{ .what = .{ .tile = t } });
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
    _ = try m.addSegment(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .slots = &.{.{ .name = "top", .style = style }} });
    const t = try m.addTile(.{ .designator = "K1", .prototype = key });
    try m.setContent(t, "top", "HQ");
    try m.place(p, r, null, .{ .what = .{ .tile = t } });
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
    _ = try m.addSegment(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .body_inset = .all(0.5), .face_inset = .all(2) });
    const flat = try m.addPrototype(.{ .name = "flat" });
    for ([_][]const u8{ "K1", "K2", "K3" }) |d| try m.place(p, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = d, .prototype = key }) } });
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
    _ = try m.addSegment(p, r, 0);
    const top: model.SlotPrototype = .{ .name = "top", .style = style, .place = .{ .inset = .all(1) } };
    const key = try m.addPrototype(.{ .name = "key", .face_inset = .all(2), .slots = &.{top} });
    for ([_][]const u8{ "K1", "K2", "K3" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setContent(t, "top", "H");
        try m.place(p, r, null, .{ .what = .{ .tile = t } });
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

test "tiles are drawn from their prototype's art, stretched; bad art is drawn plain and flagged" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 120, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 5, .h = 1, .pitch = 19.05 });
    _ = try m.addSegment(p, r, 0);

    // A calculator key: a dark body, a lighter top, and a gold band across
    // its front, from the same drawing code as any other art.
    var calc_art = try art.keycap(sa, .{
        .pitch = 19.05,
        .body_inset = .all(1),
        .face_inset = .{ .left = 1.5, .right = 1.5, .top = 1.5, .bottom = 5 },
        .body = .{ .solid = .hex("#2b2b2b") },
        .edge = null,
        .face = .{ .solid = .hex("#3c3c3c") },
    });
    const band = try art.roundedRect(sa, .{ .x0 = 1, .y0 = 1, .x1 = 18.05, .y1 = 5 }, 0.5);
    const layers = try sa.alloc(art.Layer, 3);
    @memcpy(layers[0..2], calc_art.layers);
    layers[2] = .{ .name = "gold", .outline = band, .paint = .{ .fill = .{ .solid = .hex("#c8a24a") } } };
    calc_art.layers = layers;

    const calc = try m.addPrototype(.{ .name = "calculator key", .art = calc_art });
    const plain = try m.addPrototype(.{ .name = "plain", .body_inset = .all(0.5), .face_inset = .all(2) });
    // Art whose corner arcs reach across a cut placed off centre cannot
    // stretch exactly.
    const blob = try m.addPrototype(.{ .name = "blob", .art = .{ .pitch = 19.05, .cut = .{ .x = 6, .y = 6 }, .layers = &.{.{
        .name = "dot",
        .outline = try art.roundedRect(sa, .{ .x0 = 0, .y0 = 0, .x1 = 19.05, .y1 = 19.05 }, 9.525),
        .paint = .{ .fill = .{ .solid = .hex("#ff0000") } },
    }} } });
    try m.place(p, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = "C", .prototype = calc, .w = 2 }) } });
    try m.place(p, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = "P", .prototype = plain }) } });
    try m.place(p, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = "B", .prototype = blob }) } });

    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();

    // The calculator key: three layers, the gold band stretched across its
    // 2u width with its rounded ends kept.
    const c = s.tiles[0];
    try testing.expectEqual(3, c.shapes.len);
    try testing.expectEqualStrings("gold", c.shapes[2].name);
    try testing.expectEqual(art.Color.hex("#c8a24a"), c.shapes[2].paint.fill.solid);
    const gold = c.shapes[2].outline.bounds();
    try testing.expectApproxEqAbs(c.pitch_box.width() - 2, gold.width(), 1e-9);
    // The plain key: its body and face, flat, from its insets.
    const pl = s.tiles[1];
    try testing.expectEqual(2, pl.shapes.len);
    try testing.expectApproxEqAbs(pl.body.width(), pl.shapes[0].outline.bounds().width(), 1e-9);
    // The blob: drawn plain, and flagged.
    try testing.expectEqualStrings("body", s.tiles[2].shapes[0].name);
    var flagged = false;
    for (s.issues) |i| flagged = flagged or i.kind == .tile_art;
    try testing.expect(flagged);
}

test "columns run down from the region's top and set to the right" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 100);
    const key = try m.addPrototype(.{ .name = "key", .heights = &.{ 1, 2 } });
    const r = try m.addTracks(p, .{ .name = "col", .origin = .{ .x = 10, .y = 90 }, .major = .column, .prototype = key, .count = 2, .length = 3, .pitch = 10 });
    for (0..6) |i| _ = try m.insertTile(p, r, i, key, 1);
    // The first tile twice as tall: the rest move down, the third into the
    // second column, which then overflows.
    const first = m.panels.items[p].regions.items[r].items.items[0].tileOf().?;
    try m.setTileSize(first, 1, 2);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // Column 1: tiles at 90..70 and 70..60.
    try testing.expectApproxEqAbs(@as(f64, 90), s.tiles[0].pitch_box.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 70), s.tiles[0].pitch_box.y0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 70), s.tiles[1].pitch_box.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), s.tiles[1].pitch_box.x0, 1e-9);
    // Column 2 sits to the right, from the top, starting with the third.
    try testing.expectApproxEqAbs(@as(f64, 20), s.tiles[2].pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90), s.tiles[2].pitch_box.y1, 1e-9);
    try testing.expectEqual(1, s.items[2].segment);
    var overflow = false;
    for (s.issues) |i| overflow = overflow or i.kind == .row_overflow;
    try testing.expect(overflow);
}

test "blanks take their length in a track, and every item's span is reported" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 1, .length = 4, .pitch = 10 });
    for (0..4) |i| _ = try m.insertTile(p, r, i, key, 1);
    try m.insertBlank(p, r, 1, 0.5);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(1, s.tracks.len);
    try testing.expectEqual(5, s.items.len);
    try testing.expectApproxEqAbs(@as(f64, 10), s.items[1].span[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 15), s.items[1].span[1], 1e-9);
    // The second tile starts after the blank.
    try testing.expectApproxEqAbs(@as(f64, 15), s.tiles[1].pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90), s.tracks[0].box.y0, 1e-9);
}

test "a track moves as a whole, either way; others stay; it may not overlap one" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 10, .y = 100 }, .prototype = key, .count = 3, .length = 4, .pitch = 10 });
    // Two tiles a row, each row ended by a hard break.
    for (0..3) |t| {
        for (0..2) |_| _ = try m.insertTile(p, r, m.panels.items[p].regions.items[r].items.items.len, key, 1);
        if (t < 2) try m.insertBreak(p, r, m.panels.items[p].regions.items[r].items.items.len);
    }
    // Row 3 down 0.5 u, then row 2 down 0.25 u and 0.5 u left: rows 1 and
    // 3 stay where they were.
    try m.moveSegment(p, r, 2, 0, 0.5);
    try m.moveSegment(p, r, 1, -0.5, 0.25);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // Row 1 as drawn; row 2's band and tiles 5 mm left and 2.5 mm down.
    try testing.expectApproxEqAbs(@as(f64, 10), s.tiles[0].pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), s.tiles[2].pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 87.5), s.tiles[2].pitch_box.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), s.tracks[1].box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 75), s.tiles[4].pitch_box.y1, 1e-9);
    // Up 0.25 u it touches row 1 again; any further would overlap it.
    try m.moveSegment(p, r, 1, 0, -0.25);
    try testing.expectError(error.NoRoom, m.moveSegment(p, r, 1, 0, -0.25));
    // Past the panel's left edge: allowed, and flagged.
    try m.moveSegment(p, r, 1, -1, 0);
    var t = try solve(gpa, &m, p, &labels);
    defer t.deinit();
    var outside = false;
    for (t.issues) |i| outside = outside or i.kind == .region_outside;
    try testing.expect(outside);
}

test "a region past its panel is flagged, and fitting it to its tiles can bring it back" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 60, 30);
    const key = try m.addPrototype(.{ .name = "key", .widths = &.{ 1, 1.5 } });
    // 8 u at 10 mm runs 20 mm past the 60 mm panel.
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 30 }, .prototype = key, .count = 2, .length = 8, .pitch = 10 });
    _ = try m.insertTile(p, r, 0, key, 1.5);
    _ = try m.insertTile(p, r, 1, key, 1);
    try m.insertBreak(p, r, 2);
    _ = try m.insertTile(p, r, 3, key, 1);
    try m.insertBlank(p, r, 4, 0.5);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        var past: f64 = 0;
        for (s.issues) |i| if (i.kind == .region_outside) {
            past = i.amount;
        };
        try testing.expectApproxEqAbs(@as(f64, 20), past, 1e-9);
        // The longest paragraph needs 2.5 u: the region shrinks to that.
        try testing.expectEqual(1, s.flows.len);
        try testing.expectApproxEqAbs(@as(f64, 2.5), s.flows[0].natural, 1e-9);
        try m.setSegmentLength(p, r, s.flows[0].natural);
    }
    try testing.expectApproxEqAbs(@as(f64, 2.5), m.panels.items[p].regions.items[r].w, 1e-9);
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    for (s.issues) |i| try testing.expect(i.kind != .region_outside);
}

test "text, tiles and equations share one flow, set on one baseline" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("text", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 200, 50);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "mixed", .origin = .{ .x = 0, .y = 50 }, .prototype = key, .count = 2, .length = 15, .pitch = 10 });
    // A tile, a word, an equation, a tile; a hard break; a word. (The
    // test font has only a few letters.)
    _ = try m.insertTile(p, r, 0, key, 1);
    try m.insertRun(p, r, 1, .{ .style = style, .content = "HOD" });
    try m.place(p, r, null, .{ .gap = 0.5, .what = .{ .run = .{ .style = style, .content = "A = \\frac{H}{D}" } } });
    _ = try m.insertTile(p, r, 3, key, 1);
    try m.insertBreak(p, r, 4);
    try m.insertRun(p, r, 5, .{ .style = style, .content = "ADD" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(0, s.issues.len);
    try testing.expectEqual(6, s.items.len);
    // Each item starts where the one before ends, after its gap.
    try testing.expectApproxEqAbs(@as(f64, 10), s.items[1].span[0], 1e-9);
    try testing.expect(s.items[1].span[1] > s.items[1].span[0]);
    try testing.expectApproxEqAbs(s.items[1].span[1] + 5, s.items[2].span[0], 1e-9);
    try testing.expectApproxEqAbs(s.items[2].span[1], s.items[3].span[0], 1e-9);
    try testing.expectApproxEqAbs(s.items[3].span[0], s.findTile(m.findTile("T2").?).?.pitch_box.x0, 1e-9);
    // The break ends the first row; the last word starts the second.
    try testing.expectEqual(0, s.items[4].segment);
    try testing.expectEqual(1, s.items[5].segment);
    try testing.expectApproxEqAbs(@as(f64, 0), s.items[5].span[0], 1e-9);
    // The runs are labels of their own, on the same baseline in a row.
    var runs: usize = 0;
    var baseline: ?f64 = null;
    for (s.labels) |l| if (l.run) |run| {
        runs += 1;
        try testing.expectEqual(r, run.region);
        if (s.items[run.item].segment == 0) {
            if (baseline) |b| try testing.expectApproxEqAbs(b, l.origin.y, 1e-9) else baseline = l.origin.y;
        }
    };
    try testing.expectEqual(3, runs);
    // Centred: the capitals sit midway across the 10 mm row.
    try testing.expectApproxEqAbs(@as(f64, 50 - 5 - 1.5), baseline.?, 1e-9);
}

test "an item that does not fit moves to the next segment, and the flow after it follows" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key", .widths = &.{ 1, 2 } });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 3, .length = 3, .pitch = 10 });
    // Two rows of three, a hard break between them.
    for (0..3) |i| _ = try m.insertTile(p, r, i, key, 1);
    try m.insertBreak(p, r, 3);
    for (4..7) |i| _ = try m.insertTile(p, r, i, key, 1);
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    {
        var s = try solve(testing.allocator, &m, p, &labels);
        defer s.deinit();
        try testing.expectEqual(0, s.issues.len);
        try testing.expectEqual(1, s.items[4].segment);
    }
    // A 2 u key early in the first row: its third key goes on to the
    // second row, whose break then sends the second paragraph to the third.
    _ = try m.insertTile(p, r, 1, key, 2);
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(0, s.issues.len);
    const segs = [_]usize{ 0, 0, 1, 1, 1, 2, 2, 2 };
    for (s.items, segs) |it, want| try testing.expectEqual(want, it.segment);
    // One more paragraph than segments: the last runs past the end, flagged.
    try m.insertBreak(p, r, 8);
    _ = try m.insertTile(p, r, 9, key, 1);
    var t = try solve(testing.allocator, &m, p, &labels);
    defer t.deinit();
    try testing.expectEqual(1, t.issues.len);
    try testing.expectEqual(.row_overflow, t.issues[0].kind);
    try testing.expectEqual(2, t.issues[0].row.?);
}
