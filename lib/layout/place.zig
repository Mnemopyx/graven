//! Solving a model into placed tiles and labels.
//!
//! A track's flow is poured through its segments (rows or columns) in
//! order: each item packs against the one before it through the gap set
//! before it; an item that does not fit moves to the next segment, and a
//! hard break ends its segment. A tile thicker than its segment reaches
//! into the segments after it and closes the stretch it covers there. Text and
//! equations (runs of markup) flow with the tiles, set on a baseline.
//! Labels are rendered by the engine through `Labels`, a cache keyed by
//! style, markup, box and anchor, so identical legends share one render.

const fonts = @import("fonts.zig");
const std = @import("std");
const font = @import("graven_font");
const rendering = @import("render.zig");
const glyphic = @import("graven_glyphic");
const legend = @import("legend.zig");
const model = @import("model.zig");
const art = @import("art.zig");

const Allocator = std.mem.Allocator;
const geom = @import("graven_geom");
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
    /// A spacer (a blank): no shapes, left out of output and the bounds.
    spacer: bool = false,
    /// What it is made as, when it is bound to a grid (see
    /// `model.Grid`); then `region` and `row` mean nothing. A hole's shapes
    /// are cut through the panel; a legend has none.
    grid: ?model.GridRole = null,
};

pub const PlacedLabel = struct {
    /// The run in a track's flow it sets, if it is one: then `tile` is
    /// null and `slot` is the item's index.
    run: ?struct {
        region: usize,
        /// The panel of the track holding the flow.
        panel: usize = 0,
        item: usize,
        /// The piece of the item's markup it sets (words between breaks,
        /// when a run breaks across segments): its start and length
        /// there. Its render keeps the run's source offsets.
        from: u32 = 0,
        len: u32 = 0,
    } = null,
    /// The tile whose track holds it; null for a run in a panel's track.
    tile: ?TileId,
    /// For a tile's text, the run of its track's flow it sets: the item's
    /// index there, and the piece's start and length in its source (as
    /// `run`'s `from` and `len`).
    tile_run: ?struct { item: usize, from: u32 = 0, len: u32 = 0 } = null,
    /// For a tile's text, the index of its track among its prototype's;
    /// for a run, the item's index.
    slot: usize,
    /// Its box, mm in the panel frame.
    box: Box,
    /// Where the label frame's origin sits in the panel frame; the render's
    /// geometry is relative to it.
    origin: Point,
    style: StyleId,
    /// Owned by the `Labels` cache, valid until it next changes.
    render: *const rendering.Render,
};

pub const Issue = struct {
    kind: enum {
        /// A segment's content runs past its end (past the last segment's,
        /// when the flow overflows), or meets a spanning tile.
        row_overflow,
        /// A tile's text does not fit its track.
        label_overflow,
        /// A label has characters no face covers.
        missing_glyph,
        /// A label asks for a weight, slant or math alphabet its style's
        /// font lacks: it is drawn in the regular face (or plain letters).
        variant_missing,
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
        /// A segment lies past the segments its track's space was drawn
        /// out for, across (`row` says which). Along, the path and the
        /// segment length bound the track, so no segment is past it.
        past_soft_area,
        /// A tile reaches back past its row's top into a segment the flow
        /// filled before: that content is not moved.
        tall_item,
        /// A tile's art cannot be stretched exactly (a curve crosses a cut);
        /// it is drawn plain.
        tile_art,
        /// A tile's prototype sketch cannot be solved for its size (or is
        /// not fully constrained there); the tile is drawn plain.
        tile_sketch,
        /// A track's direction or its content's rotation is not one of the
        /// axis cases placement sets yet (rows, columns): it is placed as
        /// the nearest of them.
        unsupported_direction,
    },
    tile: ?TileId = null,
    slot: ?usize = null,
    region: ?usize = null,
    row: ?usize = null,
    /// The item in a region's flow, for a run of markup.
    item: ?usize = null,
    /// How far too long, mm, for overflows.
    amount: f64 = 0,
    /// For a markup error, the first problem the parse found.
    syntax: ?rendering.Syntax = null,
};

/// A segment as placed: where its band lies.
pub const PlacedTrack = struct {
    /// The track whose flow it holds (the first of its thread, on panel
    /// `flow_panel`), and its index in that flow's segments.
    region: usize,
    track: usize,
    flow_panel: usize = 0,
    /// The track it lies in (on `panel`, the panel placed), and its index
    /// there: the same as `region` and `track` unless the track is
    /// threaded after another.
    panel: usize = 0,
    member: usize = 0,
    local: usize = 0,
    major: model.Major,
    /// The segment's band, mm in the panel frame: its length along, one
    /// pitch across.
    box: Box,
    /// Its origin on the track's path, u from the region's origin.
    origin: model.Segment = .{},
};

/// An item of a track's flow as placed: the segment it landed in, and
/// where it starts and ends along it, mm from the segment's start. A hard
/// break has no length; it sits where its segment's content ends.
pub const PlacedItem = struct {
    /// The track holding the flow (on panel `flow_panel`).
    region: usize,
    flow_panel: usize = 0,
    /// Its index in the region's flow.
    index: usize,
    segment: usize,
    span: [2]f64,
};

/// Line art as placed: its shapes moved into the panel frame.
pub const PlacedArt = struct {
    index: usize,
    box: Box,
    shapes: []const art.Shape,
    /// A hole cut through the panel: outlined, never filled.
    cutout: bool = false,
};

/// What a region's flow needs: the length, u, that would set its longest
/// paragraph (the items between hard breaks) in one segment.
pub const PlacedFlow = struct {
    /// The track holding the flow (on panel `flow_panel`): a thread's
    /// flow has one of these on each panel it runs through.
    region: usize,
    flow_panel: usize = 0,
    /// Laid out on a panel downstream, before where the flow enters it is
    /// known (see `Handoff`): nothing is placed in it yet.
    waiting: bool = false,
    natural: f64,
    /// How many segments the flow reached: kept origins past these are no
    /// longer needed (see `Model.trimSegments`).
    segments: usize = 0,
};

/// Where a thread's flow goes on into a panel downstream: the track it
/// enters (the first of its tracks there), the first piece of the flow
/// still to place (pieces as the pass cuts the flow), the number its next
/// segment takes, the paragraph style in force and whether the next line
/// starts the paragraph, and whether a wrap (not a break) ended the line
/// before. One panel's solve gives these for the next (`Placed.exits`).
pub const Handoff = struct {
    track: model.ObjectId,
    piece: usize,
    segment: usize,
    paragraph: ?model.ParaId,
    first_line: bool,
    soft: bool,
};

/// Where a word too long for its line was cut to wrap (no break
/// opportunity fitted): the end of that line, `along` mm into segment
/// `segment` of the flow of track `region` on panel `flow_panel`. Shown
/// while editing; not an issue.
pub const PlacedWrap = struct {
    region: usize,
    flow_panel: usize = 0,
    segment: usize,
    along: f64,
};

pub const Placed = struct {
    arena: std.heap.ArenaAllocator,
    /// Forced wraps in the panel's flows.
    wraps: []const PlacedWrap = &.{},
    /// Where the panel's threads go on into other panels.
    exits: []const Handoff = &.{},
    tiles: []const PlacedTile,
    tracks: []const PlacedTrack = &.{},
    items: []const PlacedItem = &.{},
    /// The panel's line art, in the panel frame.
    art: []const PlacedArt = &.{},
    flows: []const PlacedFlow = &.{},
    labels: []const PlacedLabel,
    issues: []const Issue,
    /// The union of the tiles' pitch boxes, line art, and the ink of
    /// labels outside tiles.
    bounds: Box,
    /// The panel's outline, in the panel frame, when it is more than a
    /// plain rectangle: its edge path (Make panel), or its rectangle when
    /// it has cutouts. Null for a plain rectangle and for a space's panel.
    edge: ?geom.Outline = null,
    /// The panel's body: its edge with its cutouts and hole tiles cut out
    /// exactly (a hole across the edge leaves a notch; overlapping holes
    /// cut their union). Null when it has no edge. Should the cut not join
    /// up, the edge and the cutters together, filled even-odd.
    body: ?geom.Outline = null,

    pub fn deinit(p: *Placed) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// Region `region`'s segment origins as placed, in order, into `out`.
    pub fn origins(p: *const Placed, region: usize, out: []model.Segment) []model.Segment {
        var n: usize = 0;
        for (p.tracks) |t| if (t.region == region and t.track < out.len) {
            out[t.track] = t.origin;
            n = @max(n, t.track + 1);
        };
        return out[0..n];
    }

    /// What moving segment `seg` of region `region` must not land on, into
    /// `out`: every other segment on the panel, except the ones after it
    /// that only continue the path (past the `kept` origins), which follow.
    pub fn obstacles(p: *const Placed, region: usize, seg: usize, kept: usize, out: []Box) []Box {
        var n: usize = 0;
        for (p.tracks) |t| {
            if (t.region == region and (t.track == seg or (t.track > seg and t.track >= kept))) continue;
            if (n == out.len) break;
            out[n] = t.box;
            n += 1;
        }
        return out[0..n];
    }

    pub fn findTile(p: *const Placed, id: TileId) ?*const PlacedTile {
        for (p.tiles) |*t| if (t.id == id) return t;
        return null;
    }
};

/// Whether a render asked for a weight, slant or alphabet it did not get.
fn lacksVariant(diagnostics: []const rendering.Diagnostic) bool {
    for (diagnostics) |d| switch (d.kind) {
        .no_italic, .no_bold, .no_alphabet => return true,
        else => {},
    };
    return false;
}

/// Renders labels for one face table, caching each render.
pub const Labels = struct {
    gpa: Allocator,
    faces: []const *font.Face,
    /// The resolved fonts last given to `syncResolved`, which `sync` then
    /// keeps to; the caller resolves again when the model changes.
    resolved: ?*const fonts.Resolved = null,
    contexts: std.ArrayList(?Ctx) = .empty,
    /// The glyphic contexts the styles became, remade when one changes.
    g: ?glyphic.Engine = null,
    /// The style each of `contexts` is for, in the model's order.
    ids: std.ArrayList(StyleId) = .empty,
    cache: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,
    /// Prototype sketches solved for a tile's size and parameters: their
    /// closed profiles in the sketch's frame (null: it did not solve), by
    /// a hash of the copy's ID, the size and the parameters.
    sketches: std.AutoHashMapUnmanaged(u64, ?[]const geom.Contour) = .empty,
    sketch_arena: ?std.heap.ArenaAllocator = null,

    /// A style as last synced: a hash of all that sets its legends (size,
    /// rules, faces, its base's), and what glyphic made of it.
    const Ctx = struct { hash: u64, style: ?legend.Style };

    const Key = struct {
        style: StyleId,
        anchor: model.Align,
        /// The hard box relative to the anchor point; null for none.
        box: ?[4]f64,
        markup: []const u8,
        /// All math (an equation run), rather than a legend (text with
        /// math between dollars).
        math: bool = false,
        /// Each line's open span, where art over the label closes the rest
        /// (each line's open stretch); empty for none.
        spans: []const ?[2]f64 = &.{},
    };

    const Entry = struct {
        render: ?*rendering.Render,
    };

    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(std.mem.asBytes(&k.style));
            h.update(std.mem.asBytes(&k.anchor));
            h.update(std.mem.asBytes(&(k.box orelse [4]f64{ 0, 0, 0, 0 })));
            h.update(&.{@intFromBool(k.box != null)});
            h.update(k.markup);
            h.update(&.{@intFromBool(k.math)});
            for (k.spans) |sp| h.update(std.mem.asBytes(&(sp orelse [2]f64{ -1, -1 })));
            return h.final();
        }
        pub fn eql(_: KeyContext, x: Key, y: Key) bool {
            const boxes = if (x.box) |xb| (if (y.box) |yb| std.mem.eql(f64, &xb, &yb) else false) else y.box == null;
            if (x.spans.len != y.spans.len) return false;
            for (x.spans, y.spans) |p, q| {
                if ((p == null) != (q == null)) return false;
                if (p != null and !std.mem.eql(f64, &p.?, &q.?)) return false;
            }
            return x.style == y.style and x.anchor == y.anchor and x.math == y.math and boxes and std.mem.eql(u8, x.markup, y.markup);
        }
    };

    /// `faces` must outlive the cache.
    pub fn init(gpa: Allocator, faces: []const *font.Face) Labels {
        return .{ .gpa = gpa, .faces = faces };
    }

    /// A tile's shapes from its prototype's sketch: the sketch solved with
    /// its size parameters set to the pitch box's size (mm) and the tile's
    /// own parameters, its closed profiles placed at the pitch box's corner
    /// plus the offset, each drawn as an outline. Null when it does not
    /// solve to full constraint. Solutions are cached.
    pub fn sketchShapes(l: *Labels, a: Allocator, ps: model.PrototypeSketch, params: []const model.TileParam, box: Box) Allocator.Error!?[]const art.Shape {
        var h: std.hash.Wyhash = .init(1);
        h.update(std.mem.asBytes(&ps.id));
        h.update(std.mem.asBytes(&ps.version));
        h.update(std.mem.asBytes(&box.width()));
        h.update(std.mem.asBytes(&box.height()));
        for (params) |p| {
            h.update(p.name);
            h.update(std.mem.asBytes(&p.value));
        }
        const key = h.final();
        const contours = if (l.sketches.get(key)) |hit| hit else blk: {
            if (l.sketch_arena == null) l.sketch_arena = .init(l.gpa);
            const got = solveTileSketch(l.gpa, l.sketch_arena.?.allocator(), ps, params, box) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Anything else: it does not solve here.
                else => null,
            };
            try l.sketches.put(l.gpa, key, got);
            break :blk got;
        };
        const cs = contours orelse return null;
        const move = geom.Affine.translate(box.x0 + ps.offset.x, box.y0 + ps.offset.y);
        const shapes = try a.alloc(art.Shape, cs.len);
        for (cs, shapes) |c, *sh| {
            const one = try a.alloc(geom.Contour, 1);
            one[0] = c;
            sh.* = .{
                .name = "sketch",
                .outline = try (geom.Outline{ .contours = one }).transformed(a, move),
                .paint = .{ .edge = .hex("#1d1d1b"), .edge_width = 0.15 },
            };
        }
        return shapes;
    }

    fn solveTileSketch(gpa: Allocator, keep: Allocator, ps: model.PrototypeSketch, params: []const model.TileParam, box: Box) !?[]const geom.Contour {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var sk = try ps.sketch.clone(sa);
        var buf: [64]u8 = undefined;
        try sk.setParam(sa, ps.width_param, try std.fmt.bufPrint(&buf, "{d}", .{box.width()}));
        try sk.setParam(sa, ps.height_param, try std.fmt.bufPrint(&buf, "{d}", .{box.height()}));
        for (params) |p| for (sk.params.items) |sp| if (std.mem.eql(u8, sp.name, p.name)) {
            try sk.setParam(sa, p.name, try std.fmt.bufPrint(&buf, "{d}", .{p.value}));
        };
        // An expression with no value at this size would leave the value
        // from the size it was drawn at: it does not solve here.
        for (sk.constraints.items, 0..) |c, ci| {
            if (c.driving and sk.exprError(@intCast(ci)) != null) return null;
        }
        const res = try sk.solve(gpa);
        const an = try sk.analyse(gpa, sa);
        if (!res.solved or !an.fully_constrained) return null;
        const prof = try sk.profiles(sa);
        const out = try keep.alloc(geom.Contour, prof.contours.len);
        for (prof.contours, out) |c, *o| o.* = .{ .segments = try keep.dupe(geom.Segment, c.segments) };
        return out;
    }

    pub fn deinit(l: *Labels) void {
        l.sketches.deinit(l.gpa);
        if (l.sketch_arena) |*ar| ar.deinit();
        l.clear();
        l.cache.deinit(l.gpa);
        l.contexts.deinit(l.gpa);
        l.ids.deinit(l.gpa);
        if (l.g) |*g| g.deinit();
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
        l.gpa.free(k.spans);
        if (e.render) |r| {
            r.deinit();
            l.gpa.destroy(r);
        }
    }

    /// Brings the style contexts up to date with the model, dropping renders
    /// of any style that changed. Without resolved fonts (see
    /// `syncResolved`), every style is set in face 0.
    pub fn sync(l: *Labels, m: *const Model) Allocator.Error!void {
        const faces = if (l.resolved) |r| r.faces.items else l.faces;
        var changed = l.g == null;
        if (faces.ptr != l.faces.ptr or faces.len != l.faces.len) {
            l.faces = faces;
            for (l.contexts.items) |*c| c.* = null;
            l.clear();
            changed = true;
        }
        const n = m.styles.items.len;
        while (l.contexts.items.len < n) try l.contexts.append(l.gpa, null);
        while (l.ids.items.len < n) try l.ids.append(l.gpa, .none);
        for (m.styles.items, 0..) |st, i| {
            const cur = &l.contexts.items[i];
            // A style now in another style's place: its context is new.
            if (l.ids.items[i] != st.id) {
                if (l.ids.items[i] != .none) l.dropStyle(l.ids.items[i]);
                l.ids.items[i] = st.id;
                cur.* = null;
            }
            const h = l.styleHash(m, st.id, 0);
            if (cur.*) |c| if (c.hash == h) continue;
            cur.* = .{ .hash = h, .style = null };
            changed = true;
            l.dropStyle(st.id);
            // Renders cached under `.none` (the first style) too.
            if (i == 0) l.dropStyle(.none);
        }
        if (!changed or n == 0) return;
        // The glyphic contexts, made again for every style: renders keep
        // nothing of them, so those of unchanged styles stay.
        if (l.g) |*g| g.deinit();
        l.g = glyphic.Engine.init(l.gpa);
        const g = &l.g.?;
        var buf: [32]u8 = undefined;
        for (m.styles.items, 0..) |st, i| {
            // No faces at all: nothing can be set.
            if (l.faces.len == 0) break;
            const name = std.fmt.bufPrint(&buf, "style{d}", .{i}) catch unreachable;
            l.contexts.items[i].?.style = legend.contextOf(g, l.faces, st, l.roles(st.id), l.textFace(m, st.id), name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        // Bases, now every style has its context.
        for (m.styles.items, 0..) |st, i| {
            const own = l.contexts.items[i].?.style orelse continue;
            const bi = m.styleIndex(st.base) orelse continue;
            if (st.base == .none) continue;
            if (l.contexts.items[bi].?.style) |b| g.style(own.id).base = b.id;
        }
    }

    /// As `sync`, with the face table and the styles' faces that resolving
    /// the model's fonts gave (see `fonts.resolve`). A changed face table
    /// drops every render.
    pub fn syncResolved(l: *Labels, r: *const fonts.Resolved) Allocator.Error!void {
        l.resolved = r;
        l.faces = r.faces.items;
        for (l.contexts.items) |*c| c.* = null;
        l.clear();
        if (l.g) |*g| g.deinit();
        l.g = null;
    }

    fn roles(l: *const Labels, id: StyleId) []const fonts.RoleFace {
        return if (l.resolved) |r| r.of(id) else &.{};
    }

    /// The face style `id` sets text in: its own, else its base's, else
    /// face 0.
    fn textFace(l: *const Labels, m: *const Model, id: StyleId) *font.Face {
        var at = id;
        var n: usize = 0;
        while (at != .none and n <= m.styles.items.len) : (n += 1) {
            for (l.roles(at)) |rf| if (std.mem.eql(u8, rf.role, "text") and rf.face < l.faces.len) return l.faces[rf.face];
            at = if (m.styleIndex(at)) |i| m.styles.items[i].base else .none;
        }
        return l.faces[0];
    }

    /// A hash of all that sets style `id`'s legends, its base's included.
    fn styleHash(l: *const Labels, m: *const Model, id: StyleId, depth: usize) u64 {
        const i = m.styleIndex(id) orelse return 0;
        const st = m.styles.items[i];
        var h: std.hash.Wyhash = .init(0x5713);
        h.update(std.mem.asBytes(&st.cap_height));
        h.update(std.mem.asBytes(&(st.em_size orelse @as(f64, -1))));
        h.update(std.mem.asBytes(&(st.line_pitch orelse @as(f64, -1))));
        for (st.rules.items) |r| {
            h.update(&.{if (r.kind) |k| @as(u8, @intFromEnum(k)) else 255});
            h.update(std.mem.asBytes(&r.param));
            switch (r.value) {
                .number => |x| h.update(std.mem.asBytes(&x)),
                .choice => |c| h.update(&.{c}),
                .flag => |f| h.update(&.{@intFromBool(f)}),
                .name => |t| h.update(t),
            }
        }
        for (l.roles(id)) |rf| {
            h.update(rf.role);
            h.update(std.mem.asBytes(&rf.face));
        }
        if (st.base != .none and depth < 16) {
            const bh = l.styleHash(m, st.base, depth + 1);
            h.update(std.mem.asBytes(&bh));
        }
        return h.final();
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

    fn index(l: *const Labels, style: StyleId) ?usize {
        const i: usize = if (style == .none) 0 else for (l.ids.items, 0..) |id, k| {
            if (id == style) break k;
        } else return null;
        return if (i < l.contexts.items.len and l.contexts.items[i] != null) i else null;
    }

    /// Text style `style` as legends are set in it (`.none`: the first
    /// style); null when it cannot be used.
    pub fn context(l: *const Labels, style: StyleId) ?*const legend.Style {
        const i = l.index(style) orelse return null;
        if (l.contexts.items[i].?.style) |*st| return st;
        return null;
    }

    /// The render for a label, from the cache or made now; null when the
    /// style cannot be used.
    fn get(l: *Labels, k: Key) Allocator.Error!?*const rendering.Render {
        if (l.cache.get(k)) |e| return e.render;
        const st = l.context(k.style) orelse return null;
        const render: ?*rendering.Render = blk: {
            const r = legend.render(l.gpa, &l.g.?, l.faces, st.*, k.markup, if (k.math) .math else .legend) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk null,
            };
            const p = try l.gpa.create(rendering.Render);
            p.* = r;
            break :blk p;
        };
        var owned = k;
        owned.markup = try l.gpa.dupe(u8, k.markup);
        owned.spans = try l.gpa.dupe(?[2]f64, k.spans);
        try l.cache.put(l.gpa, owned, .{ .render = render });
        return render;
    }
};

pub const Error = Allocator.Error || spring.Error;

/// A tile placed so far that reaches past its segment's band.
const Tall = struct { box: Box, seg: usize };

/// Pieces of the flow pass for one track.
const Flow = struct {
    m: *const Model,
    region: *const model.TileRegion,
    rows: bool,
    length: f64,
    ri: usize,
    items: []const model.Item,
    segs_of: []const usize,
    spans: []const [2]f64,
    dropped: []const bool,
    dup: []const bool,
    keepouts: []const KeepOut = &.{},
    /// Which pieces are spaces between words (stretched when justified).
    stretch: []const bool = &.{},
    /// Each piece's further shift along, where a justified line stretches
    /// its spaces; set when the flow leaves its segment.
    extra: []f64 = &.{},
    /// The cap height of the track's style, as its font resolves it; 0
    /// for a track with no style.
    cap: f64 = 0,

    /// Where a row's text baseline sits (see `baselineIn`).
    fn baseline(f: Flow, band: Box) f64 {
        return baselineIn(band, f.cap);
    }

    /// Tile `id`'s pitch box at `start` mm along a segment with band
    /// `band`: from the band's top (a row) or start edge (a column), or, in
    /// a row, set on its baseline when its prototype has one.
    fn tileBox(f: Flow, id: TileId, band: Box, start: f64) Box {
        const t = f.m.tileConst(id);
        const proto = f.m.proto(t.prototype).*;
        const unit = proto.unitIn(f.region.pitch);
        const w = t.w * unit;
        const h = t.h * unit;
        if (!f.rows) {
            const y1 = band.y1 - start;
            return .{ .x0 = band.x0, .x1 = band.x0 + w, .y1 = y1, .y0 = y1 - h };
        }
        const x0 = band.x0 + start;
        if (proto.baseline) |b| {
            const y0 = f.baseline(band) - b * unit;
            return .{ .x0 = x0, .x1 = x0 + w, .y0 = y0, .y1 = y0 + h };
        }
        return .{ .x0 = x0, .x1 = x0 + w, .y1 = band.y1, .y0 = band.y1 - h };
    }

    /// The first start at or after `start` where `size` along misses every
    /// closed stretch.
    fn clear(closed: []const [2]f64, start: f64, size: f64) f64 {
        var at = start;
        var moved = true;
        while (moved) {
            moved = false;
            for (closed) |c| if (at < c[1] - 1e-9 and at + size > c[0] + 1e-9) {
                at = c[1];
                moved = true;
            };
        }
        return at;
    }

    /// Finishes segment `seg` (items `first` up to `stop`): sets its
    /// alignment shift (none where tiles from before close stretches of
    /// it, so its content stays clear of them), and records its tiles that
    /// reach past its band. One reaching back into the segments before is
    /// flagged: their content is not moved.
    fn leave(f: Flow, a: Allocator, path: *Path, shifts: *std.ArrayList(f64), tall: *std.ArrayList(Tall), issues: *std.ArrayList(Issue), seg: usize, first: usize, stop: usize, has_closed: bool, line: Line) Allocator.Error!void {
        // Where its content ends: its last piece but a space left at the
        // end by a wrap.
        var content_end: f64 = line.lo;
        for (first..stop) |k| {
            if (f.dropped[k] or f.dup[k] or f.segs_of[k] != seg) continue;
            if (k < f.stretch.len and f.stretch[k]) continue;
            content_end = @max(content_end, f.spans[k][1]);
        }
        const free = @max(0, line.hi - content_end);
        const alignment: model.ParagraphAlign = line.alignment orelse switch (path.regionOf(seg).alignment) {
            .start => .start,
            .centre => .centre,
            .end => .end,
        };
        const sh: f64 = if (has_closed) 0 else switch (alignment) {
            .start, .justify => 0,
            .centre => free / 2,
            .end => free,
        };
        try shifts.append(a, sh);
        // Justified, and ended by a wrap (not the paragraph's last line):
        // the spaces between its words share what is left.
        if (alignment == .justify and line.soft and !has_closed and free > 0 and f.extra.len > 0) {
            var n: usize = 0;
            for (first..stop) |k| {
                if (f.dropped[k] or f.segs_of[k] != seg or !f.stretch[k]) continue;
                if (f.spans[k][1] > content_end + 1e-9) continue;
                n += 1;
            }
            if (n > 0) {
                const each = free / @as(f64, @floatFromInt(n));
                var acc: f64 = 0;
                for (first..stop) |k| {
                    if (f.dropped[k] or f.segs_of[k] != seg) continue;
                    f.extra[k] = acc;
                    if (f.stretch[k] and f.spans[k][1] <= content_end + 1e-9) {
                        acc += each;
                        f.extra[k] = acc - each;
                    }
                }
            }
        }
        const band = path.boxes.items[seg];
        const tol = 1e-9;
        for (first..stop) |k| {
            if (f.dropped[k] or f.dup[k] or f.segs_of[k] != seg) continue;
            const id = f.items[k].tileOf() orelse continue;
            const b = f.tileBox(id, band, f.spans[k][0] + sh + (if (k < f.extra.len) f.extra[k] else 0));
            const beyond = if (f.rows) b.y0 < band.y0 - tol else b.x1 > band.x1 + tol;
            const behind = if (f.rows) b.y1 > band.y1 + tol else b.x0 < band.x0 - tol;
            if (beyond) try tall.append(a, .{ .box = b, .seg = seg });
            if (behind and seg > 0) try issues.append(a, .{ .kind = .tall_item, .tile = id, .region = f.ri, .row = seg });
        }
    }

    /// Starts segment `seg`: makes it, and works out the stretches of it
    /// that tiles from earlier segments close.
    fn enter(f: Flow, a: Allocator, path: *Path, seg: usize, tall: []const Tall, closed: *std.ArrayList([2]f64)) Allocator.Error!void {
        try path.ensure(a, seg);
        const band = path.boxes.items[seg];
        closed.clearRetainingCapacity();
        for (tall) |t| {
            if (t.seg >= seg or !model.overlaps(t.box, band)) continue;
            const c: [2]f64 = if (f.rows)
                .{ @max(t.box.x0, band.x0) - band.x0, @min(t.box.x1, band.x1) - band.x0 }
            else
                .{ band.y1 - @min(t.box.y1, band.y1), band.y1 - @max(t.box.y0, band.y0) };
            try closed.append(a, c);
        }
        for (f.keepouts) |k| try k.closes(a, f.rows, band, closed);
    }
};

/// Where a row's text baseline sits in a segment's band `band`: capitals
/// of cap height `cap` centred across it (the band's middle for 0). The
/// ground (ground.zig) puts v2's baselines where v1's are by it.
pub fn baselineIn(band: Box, cap: f64) f64 {
    return (band.y0 + band.y1 - cap) / 2;
}

/// How one segment's content is set: between `lo` and `hi` along it (its
/// paragraph's indents), aligned as its paragraph says (null: as its
/// track says), and whether a wrap ended it (so a justified one fills).
pub const Line = struct {
    lo: f64,
    hi: f64,
    alignment: ?model.ParagraphAlign = null,
    soft: bool = false,
};

/// Line art the tracks flow around: its bounds, and for ink its outline
/// flattened to polygons, mm in the panel frame.
pub const KeepOut = struct {
    box: Box,
    /// Empty to wrap by the bounds.
    polys: []const []const Point,
    clearance: f64,

    pub fn of(a: Allocator, pa: model.PanelArt) Allocator.Error!KeepOut {
        const b = pa.box();
        // A figure's placement with a wrap: its tracks flow round the wrap,
        // which holds the clearance already.
        if (pa.figure != .none and pa.wrap != .none) if (pa.border.fractions() != null) {
            const o = try pa.border.outline(a, b, pa.clearance);
            var polys: std.ArrayList([]const Point) = .empty;
            var wb: Box = .empty;
            for (o.contours) |c| {
                var pts: std.ArrayList(Point) = .empty;
                for (c.segments) |sg| {
                    if (pts.items.len == 0) try pts.append(a, sg.start());
                    const n: usize = if (sg == .line) 1 else 16;
                    for (1..n + 1) |i| try pts.append(a, pointOn(sg, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
                }
                for (pts.items) |q| wb = wb.join(.{ .x0 = q.x, .y0 = q.y, .x1 = q.x, .y1 = q.y });
                try polys.append(a, pts.items);
            }
            return .{ .box = wb, .polys = polys.items, .clearance = 0 };
        };
        if (pa.wrap != .ink) return .{ .box = b, .polys = &.{}, .clearance = pa.clearance };
        var polys: std.ArrayList([]const Point) = .empty;
        for (pa.shapes) |sh| for (sh.outline.contours) |c| {
            var pts: std.ArrayList(Point) = .empty;
            for (c.segments) |sg| {
                if (pts.items.len == 0) try pts.append(a, sg.start());
                const n: usize = switch (sg) {
                    .line => 1,
                    else => 16,
                };
                for (1..n + 1) |i| try pts.append(a, pointOn(sg, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
            }
            for (pts.items) |*q| q.* = .{ .x = q.x + pa.at.x, .y = q.y + pa.at.y };
            try polys.append(a, pts.items);
        };
        return .{ .box = b, .polys = polys.items, .clearance = pa.clearance };
    }

    /// The stretches it closes along a segment with band `band`, added to
    /// `out`: where its ink (or its box), grown by the clearance, crosses
    /// the band. Ink is measured on lines across the band, as contact
    /// profiles measure glyphs, so a gap in the art leaves an open span.
    pub fn closes(k: KeepOut, a: Allocator, rows: bool, band: Box, out: *std.ArrayList([2]f64)) Allocator.Error!void {
        const c = k.clearance;
        const grown: Box = .{ .x0 = k.box.x0 - c, .x1 = k.box.x1 + c, .y0 = k.box.y0 - c, .y1 = k.box.y1 + c };
        if (k.box.isEmpty() or !model.overlaps(grown, band)) return;
        // Spans along the band's length axis (x for rows, y for columns).
        var spans: std.ArrayList([2]f64) = .empty;
        if (k.polys.len == 0) {
            try spans.append(a, if (rows) .{ grown.x0, grown.x1 } else .{ grown.y0, grown.y1 });
        } else {
            const lo = (if (rows) band.y0 else band.x0) - c;
            const hi = (if (rows) band.y1 else band.x1) + c;
            const lines = 12;
            var cross: std.ArrayList(struct { at: f64, dir: i32 }) = .empty;
            for (0..lines + 1) |i| {
                const v = lo + (hi - lo) * @as(f64, @floatFromInt(i)) / lines;
                cross.clearRetainingCapacity();
                for (k.polys) |poly| for (poly, 0..) |p, j| {
                    const q = poly[(j + 1) % poly.len];
                    const pa = if (rows) p.y else p.x;
                    const qa = if (rows) q.y else q.x;
                    const pb = if (rows) p.x else p.y;
                    const qb = if (rows) q.x else q.y;
                    const up = pa <= v and v < qa;
                    const down = qa <= v and v < pa;
                    if (!up and !down) continue;
                    const t = (v - pa) / (qa - pa);
                    try cross.append(a, .{ .at = pb + (qb - pb) * t, .dir = if (up) 1 else -1 });
                };
                std.mem.sort(@TypeOf(cross.items[0]), cross.items, {}, struct {
                    fn lt(_: void, x: @TypeOf(cross.items[0]), y: @TypeOf(cross.items[0])) bool {
                        return x.at < y.at;
                    }
                }.lt);
                // Nonzero: inside wherever the winding is not zero.
                var wind: i32 = 0;
                var from: f64 = 0;
                for (cross.items) |x| {
                    const was = wind;
                    wind += x.dir;
                    if (was == 0 and wind != 0) from = x.at;
                    if (was != 0 and wind == 0) try spans.append(a, .{ from - c, x.at + c });
                }
            }
        }
        if (spans.items.len == 0) return;
        std.mem.sort([2]f64, spans.items, {}, struct {
            fn lt(_: void, x: [2]f64, y: [2]f64) bool {
                return x[0] < y[0];
            }
        }.lt);
        // Merged, clipped to the band, and measured along it from its start.
        const b0 = if (rows) band.x0 else band.y0;
        const b1 = if (rows) band.x1 else band.y1;
        var cur = spans.items[0];
        for (spans.items[1..]) |sp| {
            if (sp[0] <= cur[1]) {
                cur[1] = @max(cur[1], sp[1]);
                continue;
            }
            try addSpan(a, out, rows, band, cur, b0, b1);
            cur = sp;
        }
        try addSpan(a, out, rows, band, cur, b0, b1);
    }

    fn addSpan(a: Allocator, out: *std.ArrayList([2]f64), rows: bool, band: Box, sp: [2]f64, b0: f64, b1: f64) Allocator.Error!void {
        const lo = @max(sp[0], b0);
        const hi = @min(sp[1], b1);
        if (hi <= lo) return;
        try out.append(a, if (rows) .{ lo - band.x0, hi - band.x0 } else .{ band.y1 - hi, band.y1 - lo });
    }
};

/// Segment `seg`'s length along, mm: a whole segment's, wherever the path
/// puts it.
pub fn segLength(path: *const Path, rows: bool, seg: usize) f64 {
    const b = path.boxes.items[seg];
    return if (rows) b.width() else b.height();
}

/// The cap height of `region`'s style: as its context resolves it (a
/// style sized by its em gets its font's), else as the model gives it.
pub fn trackCap(m: *const Model, labels: *const Labels, region: model.TileRegion) f64 {
    const sid = region.style orelse return 0;
    if (labels.context(sid)) |ctx| return ctx.cap_height;
    return if (m.styleIndex(sid) != null) m.textStyle(sid).cap_height else 0;
}

/// The bounds and alignment of a segment of a paragraph in `style` (null:
/// none, the whole segment as its track sets it); `first` for its first
/// line. Indents larger than the segment leave it no room, not less.
pub fn lineIn(style: ?model.ParagraphStyle, first: bool, length: f64) Line {
    const st = style orelse return .{ .lo = 0, .hi = length };
    const lo = std.math.clamp(st.indent_start + (if (first) st.first else 0), 0, length);
    const hi = std.math.clamp(length - st.indent_end, lo, length);
    return .{ .lo = lo, .hi = hi, .alignment = st.alignment };
}

/// A piece of a run cut from its one-line render: the words between two
/// break opportunities, or (`space`) the space of one.
/// A piece of a run that breaks: the words (or part of a word) between two
/// cuts of its render, or the space at a break opportunity.
const Cut = struct {
    render: *const rendering.Render,
    from: ?rendering.Render.Cut = null,
    to: ?rendering.Render.Cut = null,
    /// The space of break opportunity `space`, alone.
    space: ?u32 = null,
    /// What ends it: a break between words, a soft hyphen (where a line
    /// break draws a hyphen), or a cut inside a word (taken only when the
    /// word does not fit a line, a forced wrap).
    /// `glyph`: between two characters of a column track's text, each
    /// set on its own down the column.
    end: enum { none, space, hyphen, forced, glyph } = .none,

    /// Its length along the line.
    fn size(c: Cut) f64 {
        if (c.space) |k| {
            const o = c.render.opportunities[k];
            return o.x1 - o.x0;
        }
        const x0 = if (c.from) |f| f.x1 else c.render.design.x0;
        const x1 = if (c.to) |t| t.x0 else c.render.design.x1;
        return x1 - x0;
    }
};

/// Whether flow piece `index` is the space between two words of a run.
fn isSpace(cuts: []const ?Cut, index: usize) bool {
    return if (cuts[index]) |c| c.space != null else false;
}

/// What a line broken at a soft hyphen ends with.
const hyphen_markup = "-";

/// The length of the hyphen a line broken at a soft hyphen ends with, in
/// style `style`.
fn hyphenSize(labels: anytype, style: model.StyleId) f64 {
    const r = (labels.get(.{ .style = style, .anchor = .start, .box = null, .markup = hyphen_markup }) catch return 0) orelse return 0;
    return r.design.x1 - r.design.x0;
}

/// Whether flow piece `index` ends in a cut of kind `end`.
fn endsIn(cuts: []const ?Cut, index: usize, end: @TypeOf(@as(Cut, undefined).end)) bool {
    return if (cuts[index]) |c| c.end == end else false;
}

/// The point at `t` on segment `s`.
fn pointOn(s: geom.Segment, t: f64) Point {
    return s.at(t);
}

/// How far down a column one piece of text reaches: a character, a cap
/// height and a half; a space between words, half a cap.
fn columnStep(labels: *Labels, style: StyleId, c: Cut) f64 {
    const cap = if (labels.context(style)) |st| st.cap_height else 2;
    return if (c.space != null) 0.5 * cap else 1.5 * cap;
}

/// The tracks of the placed tiles `tiles` with content in them, as
/// tracks in the panel frame: each its prototype track's box in the
/// tile's face, one line (a row) or one character (a column) thick, with
/// the tile's content. With them, the tile each is for and its index
/// among its prototype's tracks.
fn tileRegions(a: Allocator, m: *const Model, labels: *Labels, tiles: []const PlacedTile, out: *std.ArrayList(model.TileRegion), contents: *std.ArrayList([]const model.Item), owner: *std.ArrayList(TileId), which: *std.ArrayList(usize)) Allocator.Error!void {
    for (tiles) |pt| {
        // A hole shows nothing of its prototype's text.
        if (pt.spacer or pt.grid == .hole) continue;
        const proto = m.prototypeOf(pt.id);
        for (proto.tracks, 0..) |tt, k| {
            const f = m.tileFlow(pt.id, tt.id) orelse continue;
            if (f.items.items.len == 0) continue;
            const box = tt.place.inset.inset(pt.face);
            if (!(box.width() > 0 and box.height() > 0)) continue;
            const ctx = labels.context(tt.style);
            const cap = if (ctx) |c| c.cap_height else 2;
            const pitch: f64 = if (tt.major == .row) (if (ctx) |c| c.line_pitch else 1.4 * cap) else 1.5 * cap;
            const along = (if (tt.major == .row) box.width() else box.height()) / pitch;
            const across = (if (tt.major == .row) box.height() else box.width()) / pitch;
            try out.append(a, .{
                .id = f.id,
                .name = tt.name,
                .origin = .{ .x = box.x0, .y = box.y1 },
                .w = if (tt.major == .row) along else across,
                .h = if (tt.major == .row) across else along,
                .pitch = pitch,
                .direction = model.TileRegion.oriented(tt.major).direction,
                .rotation = model.TileRegion.oriented(tt.major).rotation,
                .stack = model.TileRegion.oriented(tt.major).stack,
                .style = tt.style,
                .alignment = tt.alignment,
            });
            try contents.append(a, f.items.items);
            try owner.append(a, pt.id);
            try which.append(a, k);
        }
    }
}

/// The most segments one track's flow may reach.
const max_segments = 4096;

/// A track's segments as its flow reaches them, each one step on across
/// from the one before and where the track's path is along, skipping on
/// past places already taken (by earlier segments here, or `avoid`).
pub const Path = struct {
    /// The panel's tracks, and the thread's, in order: the flow goes on
    /// into the next once one is full across.
    regions: []const model.TileRegion,
    thread: []const usize,
    /// Each segment's place in the thread.
    member: std.ArrayList(usize) = .empty,
    /// Whether the thread goes on past these tracks, on another panel.
    more: bool = false,
    avoid: []const PlacedTrack,
    origins: std.ArrayList(model.Segment) = .empty,
    boxes: std.ArrayList(Box) = .empty,
    reach: std.ArrayList(f64) = .empty,
    /// Further space, mm, before the next segment made (a paragraph's
    /// space before and after, or its lines' gap).
    lead: f64 = 0,

    pub fn ensure(p: *Path, a: Allocator, k: usize) Allocator.Error!void {
        while (p.origins.items.len <= k) {
            const n = p.origins.items.len;
            var at: usize = if (n == 0) 0 else p.member.items[n - 1];
            var r = &p.regions[p.thread[at]];
            // One thickness (and the gap, and any paragraph spacing) on
            // across from the one before; along, wherever the path is
            // there. Past a place already taken, on across.
            var across: f64 = if (n == 0) 0 else p.origins.items[n - 1].across + 1 + r.gap + p.lead / r.pitch;
            // Full across: on into the next track of the thread, at its
            // start (a paragraph's spacing does not carry over).
            if (n > 0 and across + 1 > r.crossLength() + 1e-9 and at + 1 < p.thread.len) {
                at += 1;
                r = &p.regions[p.thread[at]];
                across = 0;
            }
            const first_here = n == 0 or at != p.member.items[n - 1];
            var o: model.Segment = .{ .along = r.pathAt(across), .across = across };
            if (!first_here) {
                var tries: usize = 0;
                while (tries < 400 and p.blocked(r.boxAt(o))) : (tries += 1) {
                    across += 0.25;
                    o = .{ .along = r.pathAt(across), .across = across };
                }
            }
            try p.origins.append(a, o);
            try p.boxes.append(a, r.boxAt(o));
            try p.reach.append(a, 0);
            try p.member.append(a, at);
        }
        p.lead = 0;
    }

    /// Whether segment `n` (the next) would take the flow past the last of
    /// these tracks, while the thread goes on elsewhere.
    pub fn leaves(p: *const Path, n: usize) bool {
        if (!p.more or n == 0 or n < p.origins.items.len) return false;
        const at = p.member.items[n - 1];
        if (at + 1 < p.thread.len) return false;
        const r = &p.regions[p.thread[at]];
        const across = p.origins.items[n - 1].across + 1 + r.gap + p.lead / r.pitch;
        return across + 1 > r.crossLength() + 1e-9;
    }

    /// The track segment `seg` lies in.
    pub fn regionOf(p: *const Path, seg: usize) *const model.TileRegion {
        return &p.regions[p.thread[p.member.items[seg]]];
    }

    fn blocked(p: *const Path, b: Box) bool {
        for (p.avoid) |t| if (model.overlaps(b, t.box)) return true;
        for (p.boxes.items) |o| if (model.overlaps(b, o)) return true;
        return false;
    }
};

/// Places every tile and label of one panel.
/// See `Placed.body`.
fn panelBody(a: Allocator, edge: geom.Outline, arts: []const PlacedArt, tiles: []const PlacedTile) Allocator.Error!geom.Outline {
    var cutters: std.ArrayList(geom.Outline) = .empty;
    for (arts) |pa| if (pa.cutout) for (pa.shapes) |sh| try cutters.append(a, sh.outline);
    for (tiles) |t| if (t.grid == .hole) for (t.shapes) |sh| try cutters.append(a, sh.outline);
    if (cutters.items.len == 0) return edge;
    return geom.boolean.cut(a, edge, cutters.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unjoined => {
            var all: std.ArrayList(geom.Contour) = .empty;
            try all.appendSlice(a, edge.contours);
            for (cutters.items) |c| try all.appendSlice(a, c.contours);
            return .{ .contours = all.items };
        },
    };
}

pub fn solve(gpa: Allocator, m: *const Model, panel: usize, labels: *Labels) Error!Placed {
    return solveWith(gpa, m, panel, labels, &.{});
}

/// Places every tile and label of one panel, given where threads from
/// other panels enter it (`entries`; see `Handoff`). A thread entering
/// with no entry given is left waiting (`PlacedFlow.waiting`).
pub fn solveWith(gpa: Allocator, m: *const Model, panel: usize, labels: *Labels, entries: []const Handoff) Error!Placed {
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
    var exits: std.ArrayList(Handoff) = .empty;
    var placed_labels: std.ArrayList(PlacedLabel) = .empty;
    var wraps: std.ArrayList(PlacedWrap) = .empty;
    const outline: Box = .{ .x0 = 0, .y0 = 0, .x1 = m.panels.items[panel].w, .y1 = m.panels.items[panel].h };
    // Line art on the panel: drawn over the tracks, and what wraps is
    // something their flow goes around.
    var keepouts: std.ArrayList(KeepOut) = .empty;
    var label_keepouts: std.ArrayList(KeepOut) = .empty;
    var placed_art: std.ArrayList(PlacedArt) = .empty;
    for (m.panels.items[panel].art.items, 0..) |pa, ai| {
        try placed_art.append(a, .{ .index = ai, .box = pa.box(), .shapes = try art.dupeShapes(a, pa.shapes, pa.at), .cutout = pa.cutout });
        bounds = bounds.join(pa.box());
        if (pa.wrap == .none) continue;
        const k = try KeepOut.of(a, pa);
        try label_keepouts.append(a, k);
        if (pa.wrap_tracks) try keepouts.append(a, k);
    }
    // Grids' instances: tiles at their points.
    for (m.panels.items[panel].grids.items, 0..) |g, gi| for (g.instances.items, 0..) |inst, ii| {
        const box = m.instanceBox(panel, gi, ii) orelse continue;
        const st = g.stamps.items[m.stampIndex(panel, gi, inst.stamp).?];
        const t = m.tileConst(inst.tile);
        const proto = m.proto(t.prototype);
        const body = proto.body_inset.inset(box);
        const unit = proto.unitIn(box.height());
        const shapes: []const art.Shape = switch (st.role) {
            .legend => &.{},
            else => blk: {
                // The stamp's sketch, live: solved for the instance's box,
                // centred on it, with the stamp's parameters and then the
                // tile's.
                const stamp_sketch: ?model.PrototypeSketch = if (st.sketch != .none) if (m.sketchIndex(st.sketch)) |ski| s: {
                    const item = m.sketches.items[ski];
                    break :s .{ .id = item.id, .from = item.id, .sketch = item.sketch, .width_param = "w", .height_param = "h", .offset = .{ .x = box.width() / 2, .y = box.height() / 2 }, .version = item.version };
                } else null else null;
                const params: []const model.TileParam = if (stamp_sketch != null and st.params.len > 0) p: {
                    const both = try a.alloc(model.TileParam, st.params.len + t.params.items.len);
                    @memcpy(both[0..st.params.len], st.params);
                    @memcpy(both[st.params.len..], t.params.items);
                    break :p both;
                } else t.params.items;
                const from_sketch: ?[]const art.Shape = if (stamp_sketch orelse proto.sketch) |ps| s: {
                    const got = try labels.sketchShapes(a, ps, params, box);
                    if (got == null) try issues.append(a, .{ .kind = .tile_sketch, .tile = inst.tile });
                    break :s got;
                } else null;
                const all = if (from_sketch) |fs| fs else if (proto.art) |pa| art.stretch(a, pa, unit, box) catch |err| switch (err) {
                    error.CurveCrossesCut => s: {
                        try issues.append(a, .{ .kind = .tile_art, .tile = inst.tile });
                        break :s try art.plainShapes(a, proto.*, unit, box);
                    },
                    else => |e| return e,
                } else try art.plainShapes(a, proto.*, unit, box);
                if (st.role == .part) break :blk all;
                // A hole is cut by its prototype's outline: the largest of
                // its shapes.
                var best: ?art.Shape = null;
                var best_area: f64 = -1;
                for (all) |sh| {
                    const b = sh.outline.bounds();
                    const area = b.width() * b.height();
                    if (area > best_area) {
                        best_area = area;
                        best = sh;
                    }
                }
                const one = try a.alloc(art.Shape, if (best != null) 1 else 0);
                if (best) |b| one[0] = b;
                break :blk one;
            },
        };
        try tiles.append(a, .{ .id = inst.tile, .region = 0, .row = 0, .pitch_box = box, .body = body, .face = proto.face_inset.inset(body), .shapes = shapes, .grid = st.role });
        if (st.role != .legend) bounds = bounds.join(box);
    };

    // Tracks: the panel's own, then (once the tiles are placed) the
    // tracks of each tile on it, laid out by the same pass. A tile's track
    // is its own, in its face; what its pass gives other than labels (its
    // segments, items, flows) is not the panel's, and its issues are the
    // tile's.
    var synth: std.ArrayList(model.TileRegion) = .empty;
    var synth_items: std.ArrayList([]const model.Item) = .empty;
    var synth_owner: std.ArrayList(TileId) = .empty;
    var synth_which: std.ArrayList(usize) = .empty;
    var junk_tracks: std.ArrayList(PlacedTrack) = .empty;
    var junk_items: std.ArrayList(PlacedItem) = .empty;
    var junk_flows: std.ArrayList(PlacedFlow) = .empty;
    var junk_exits: std.ArrayList(Handoff) = .empty;
    var junk_wraps: std.ArrayList(PlacedWrap) = .empty;
    var junk_issues: std.ArrayList(Issue) = .empty;
    for (0..2) |pass| {
    const own = pass == 0;
    if (!own) try tileRegions(a, m, labels, tiles.items, &synth, &synth_items, &synth_owner, &synth_which);
    const regs: []const model.TileRegion = if (own) m.panels.items[panel].regions.items else synth.items;
    for (regs, 0..) |region, ri| {
        const out_tracks = if (own) &tracks else &junk_tracks;
        const out_placed_items = if (own) &placed_items else &junk_items;
        const out_flows = if (own) &flows else &junk_flows;
        const out_exits = if (own) &exits else &junk_exits;
        const out_wraps = if (own) &wraps else &junk_wraps;
        const out_issues = if (own) &issues else &junk_issues;
        // A thread is laid out a leg at a time: the run of its tracks on
        // one panel. A track threaded after another here is in its leg.
        const before = if (own) m.threadBefore(panel, ri) else null;
        if (before) |b| if (b.panel == panel) continue;
        const head: model.TrackRef = if (own) m.threadHead(panel, ri) else .{ .panel = panel, .region = ri };
        var all_buf: [256]model.TrackRef = undefined;
        const thread_all = if (own) m.thread(head, &all_buf) else all_buf[0..0];
        var thread_buf: [256]usize = undefined;
        var leg_n: usize = 0;
        var at_k: usize = 0;
        while (at_k < thread_all.len and !(thread_all[at_k].panel == panel and thread_all[at_k].region == ri)) at_k += 1;
        while (at_k < thread_all.len and thread_all[at_k].panel == panel and leg_n < thread_buf.len) : (at_k += 1) {
            thread_buf[leg_n] = thread_all[at_k].region;
            leg_n += 1;
        }
        if (leg_n == 0) {
            thread_buf[0] = ri;
            leg_n = 1;
        }
        const thread = thread_buf[0..leg_n];
        // The thread's next track, on another panel, if it goes on.
        const more: ?model.TrackRef = if (at_k < thread_all.len) thread_all[at_k] else null;
        // The flow is the thread's first track's; where it enters this
        // leg is the start, or what the panel before handed on.
        const flow_r = if (own) &m.panels.items[head.panel].regions.items[head.region] else &regs[ri];
        // Its content and first paragraph's style: the flow's (a tile's
        // face track: the tile's content there).
        const flow_items: []const model.Item = if (own) m.flowItems(head.panel, head.region) else synth_items.items[ri];
        const flow_para: ?model.ParaId = if (own) (if (m.trackFlow(head.panel, head.region)) |fl| fl.paragraph else null) else null;
        const fri = head.region;
        const fpi = head.panel;
        const entry: ?Handoff = if (before == null) Handoff{ .track = region.id, .piece = 0, .segment = 0, .paragraph = flow_para, .first_line = true, .soft = false } else for (entries) |e| {
            if (e.track == region.id) break e;
        } else null;
        // Rows run right and stack down; columns run down and set to the
        // right. An item's size along is its width in a row and its height
        // in a column.
        const rows = region.major() == .row;
        const length = region.segmentLength() * region.pitch;
        const tol = 1e-9;
        // The flow as the pass sees it. A run in a row is set once on one
        // line, then cut where it may break (between words, see
        // `rendering.Render.opportunities`): a piece per word or stretch of
        // words, with a space piece between (dropped where a wrap leaves it
        // at a segment's start). A formula has no breaks and stays whole.
        // Each piece remembers its item, and its source bytes there.
        var pieces: std.ArrayList(model.Item) = .empty;
        var cuts: std.ArrayList(?Cut) = .empty;
        var item_of: std.ArrayList(usize) = .empty;
        var src_off: std.ArrayList(u32) = .empty;
        var src_len: std.ArrayList(u32) = .empty;
        for (flow_items, 0..) |item, mi| {
            const whole = struct {
                fn add(al: Allocator, ps: *std.ArrayList(model.Item), cs: *std.ArrayList(?Cut), io: *std.ArrayList(usize), so: *std.ArrayList(u32), sl: *std.ArrayList(u32), it: model.Item, index: usize) Allocator.Error!void {
                    try ps.append(al, it);
                    try cs.append(al, null);
                    try io.append(al, index);
                    try so.append(al, 0);
                    try sl.append(al, if (it.what == .run) @intCast(it.what.run.content.len) else 0);
                }
            }.add;
            const run = switch (item.what) {
                .run => |run| run,
                else => null,
            };
            if (run == null or run.?.content.len == 0 or labels.context(run.?.style) == null) {
                try whole(a, &pieces, &cuts, &item_of, &src_off, &src_len, item, mi);
                continue;
            }
            const full = (try labels.get(.{ .style = run.?.style, .anchor = .start, .box = null, .markup = run.?.content, .math = run.?.equation })) orelse {
                try whole(a, &pieces, &cuts, &item_of, &src_off, &src_len, item, mi);
                continue;
            };
            // Its cuts: each break opportunity (a space, \allowbreak, or a
            // soft hyphen) and, inside words, between glyphs (taken only
            // for a word longer than its line). The pieces between them
            // inside a word are bound, so the word breaks as one.
            const Bound = struct { cut: rendering.Render.Cut, end: @TypeOf(@as(Cut, undefined).end), opp: ?u32 };
            var cut_at: std.ArrayList(Bound) = .empty;
            for (full.opportunities, 0..) |o, k| try cut_at.append(a, .{ .cut = .at(full, @intCast(k)), .end = if (o.hyphen) .hyphen else .space, .opp = @intCast(k) });
            // In a column, text is set a character at a time, upright:
            // a cut between each two, any of them a place to go on.
            for (try full.forcedCuts(a)) |c| try cut_at.append(a, .{ .cut = c, .end = if (rows) .forced else .glyph, .opp = null });
            if (cut_at.items.len == 0) {
                try whole(a, &pieces, &cuts, &item_of, &src_off, &src_len, item, mi);
                continue;
            }
            std.mem.sort(Bound, cut_at.items, {}, struct {
                fn lt(_: void, x: Bound, y: Bound) bool {
                    return x.cut.src0 < y.cut.src0;
                }
            }.lt);
            const content_len: u32 = @intCast(run.?.content.len);
            var prev: ?rendering.Render.Cut = null;
            for (0..cut_at.items.len + 1) |k| {
                const next: ?Bound = if (k < cut_at.items.len) cut_at.items[k] else null;
                const from: u32 = if (prev) |p_| p_.src1 else 0;
                const to: u32 = if (next) |n_| n_.cut.src0 else content_len;
                const bound_on = if (next) |n_| n_.end == .forced else false;
                try pieces.append(a, .{ .gap = if (k == 0) item.gap else 0, .bind = bound_on, .what = .{ .run = run.? } });
                try cuts.append(a, .{ .render = full, .from = prev, .to = if (next) |n_| n_.cut else null, .end = if (next) |n_| n_.end else .none });
                try item_of.append(a, mi);
                try src_off.append(a, from);
                try src_len.append(a, @max(to, from) - from);
                if (next) |n_| if (n_.end == .space) {
                    const o = full.opportunities[n_.opp.?];
                    try pieces.append(a, .{ .what = .{ .run = run.? } });
                    try cuts.append(a, .{ .render = full, .space = n_.opp.?, .end = .space });
                    try item_of.append(a, mi);
                    try src_off.append(a, o.start);
                    try src_len.append(a, o.end - o.start);
                };
                prev = if (next) |n_| n_.cut else null;
            }
            // The item's own binding holds after its last piece.
            pieces.items[pieces.items.len - 1].bind = item.bind;
        }
        const items = pieces.items;

        // First, every item's size along, and for a run its render.
        const sizes = try a.alloc(f64, items.len);
        const renders = try a.alloc(?*const rendering.Render, items.len);
        for (items, sizes, renders, 0..) |item, *size, *rr, index| {
            rr.* = null;
            size.* = switch (item.what) {
                // In its prototype's unit, so a key keeps its size in a
                // track of another pitch.
                .tile => |id| blk: {
                    const t = m.tileConst(id);
                    const unit = m.proto(t.prototype).unitIn(flow_r.pitch);
                    break :blk (if (rows) t.w else t.h) * unit;
                },
                .run => |run| blk: {
                    if (cuts.items[index]) |c| break :blk if (rows) c.size() else columnStep(labels, run.style, c);
                    if (run.content.len == 0) break :blk 0.5 * region.pitch;
                    _ = labels.context(run.style) orelse {
                        try out_issues.append(a, .{ .kind = .style_error, .region = ri, .item = item_of.items[index] });
                        break :blk 0.5 * region.pitch;
                    };
                    const render = (try labels.get(.{ .style = run.style, .anchor = .start, .box = null, .markup = run.content, .math = run.equation })) orelse break :blk 0.5 * region.pitch;
                    rr.* = render;
                    const d = render.design;
                    break :blk if (d.isEmpty()) 0 else if (rows) d.x1 - d.x0 else d.y1 - d.y0;
                },
                .hard_break, .paragraph => 0,
            };
        }

        // Then the flow: each item's segment and span. A group (items
        // bound to the next, see `Model.bound`) breaks as one: when it does
        // not fit, the whole of it moves on. A tile thicker than its segment
        // reaches into the segments that follow, closing the stretch it
        // covers there, so their content flows around it.
        const segs_of = try a.alloc(usize, items.len);
        const spans = try a.alloc([2]f64, items.len);
        const dropped = try a.alloc(bool, items.len);
        @memset(dropped, false);
        // A tile listed again is placed once, at its first entry.
        const dup = try a.alloc(bool, items.len);
        @memset(dup, false);
        var seen: std.AutoHashMapUnmanaged(TileId, void) = .empty;
        // The segments, made as the flow reaches them: their origins along
        // the path, their bands, and how far each one's content reaches.
        // The paragraph being set.
        const seg0: usize = if (entry) |e| e.segment else 0;
        var style_id: ?model.ParaId = if (entry) |e| e.paragraph else null;
        var style: ?model.ParagraphStyle = if (style_id) |id| (if (m.paraStyle(id)) |ps| ps.* else null) else null;
        var path: Path = .{ .regions = regs, .thread = thread, .avoid = if (own) tracks.items else &.{}, .more = more != null };
        // The pieces this leg places: from where the flow enters, to where
        // it leaves for the next panel (or its end). Waiting, none.
        const leg_lo: usize = if (entry) |e| @min(e.piece, items.len) else items.len;
        var leg_hi: usize = items.len;
        var exited = false;
        var drop_first = if (entry) |e| e.soft else false;
        // Set while a word longer than its line is cut to fit (a forced
        // wrap): up to its last piece.
        var forcing: ?usize = null;
        try path.ensure(a, 0);
        // Each segment's alignment shift, set when the flow leaves it.
        var shifts: std.ArrayList(f64) = .empty;
        // Tiles placed so far that reach past their segment's band, with
        // the segment that placed them; and the stretches they close in
        // the segment being filled.
        var tall: std.ArrayList(Tall) = .empty;
        var closed: std.ArrayList([2]f64) = .empty;
        var first_in_seg: usize = leg_lo;
        var seg: usize = 0;
        var in_seg: usize = 0;
        var para: f64 = 0;
        var natural: f64 = 0;
        const stretch = try a.alloc(bool, items.len);
        for (stretch, 0..) |*st, k| st.* = isSpace(cuts.items, k);
        const extra = try a.alloc(f64, items.len);
        @memset(extra, 0);
        const flow: Flow = .{ .m = m, .region = flow_r, .rows = rows, .length = length, .ri = ri, .items = items, .segs_of = segs_of, .spans = spans, .dropped = dropped, .dup = dup, .keepouts = if (own) keepouts.items else label_keepouts.items, .stretch = stretch, .extra = extra, .cap = trackCap(m, labels, region) };
        // The bounds of the segment being filled: its first line takes the
        // first-line indent. The first segment too: line art may close stretches of it.
        try flow.enter(a, &path, 0, tall.items, &closed);
        var line: Line = lineIn(style, if (entry) |e| e.first_line else true, segLength(&path, rows, 0));
        var pos: f64 = line.lo;
        for (items[leg_lo..], leg_lo..) |item, index| {
            // Entering after a wrap upstream: what a wrap drops at a
            // line's start is dropped here too.
            if (drop_first) {
                drop_first = false;
                const drops = if (item.tileOf()) |id| m.proto(m.tileConst(id).prototype).at_soft_break == .drop else isSpace(cuts.items, index);
                if (drops) {
                    segs_of[index] = seg;
                    spans[index] = .{ pos, pos };
                    dropped[index] = true;
                    continue;
                }
            }
            if (item.breaks()) {
                segs_of[index] = seg;
                spans[index] = .{ pos, pos };
                natural = @max(natural, para);
                para = 0;
                if (seg + 1 < max_segments) {
                    try flow.leave(a, &path, &shifts, &tall, out_issues, seg, first_in_seg, index, closed.items.len > 0, line);
                    seg += 1;
                    first_in_seg = index + 1;
                    // A line break: the paragraph's next line. A separator:
                    // the next paragraph, after both paragraphs' spacing.
                    var first_line = false;
                    if (item.what == .paragraph) {
                        const next: ?model.ParagraphStyle = if (item.what.paragraph) |id| (if (m.paraStyle(id)) |ps| ps.* else null) else null;
                        path.lead = (if (style) |st| st.space_after else 0) + (if (next) |st| st.space_before else 0);
                        style = next;
                        style_id = item.what.paragraph;
                        first_line = true;
                    } else path.lead = if (style) |st| st.line_gap else 0;
                    // Past this leg's last track: the rest goes on into
                    // the thread's next panel.
                    if (path.leaves(seg)) {
                        try out_exits.append(a, .{ .track = m.panels.items[more.?.panel].regions.items[more.?.region].id, .piece = index + 1, .segment = seg0 + seg, .paragraph = style_id, .first_line = first_line, .soft = false });
                        leg_hi = index + 1;
                        exited = true;
                        break;
                    }
                    try flow.enter(a, &path, seg, tall.items, &closed);
                    line = lineIn(style, first_line, segLength(&path, rows, seg));
                    pos = line.lo;
                    in_seg = 0;
                }
                continue;
            }
            if (item.tileOf()) |id| {
                if (seen.contains(id)) {
                    dup[index] = true;
                    segs_of[index] = seg;
                    spans[index] = .{ pos, pos };
                    continue;
                }
                try seen.put(a, id, {});
            }
            const gap = item.gap * region.pitch;
            const size = sizes[index];
            // Inside a group (bound to the item before), no break.
            const in_group = index > 0 and m.bound(items, index - 1);
            var start = Flow.clear(closed.items, pos + gap, size);
            para += gap + size;
            // What must fit here: this item, or its whole group.
            var need = size;
            var group_end = index;
            if (!in_group) {
                while (group_end + 1 < items.len and m.bound(items, group_end)) : (group_end += 1) need += items[group_end + 1].gap * region.pitch + sizes[group_end + 1];
                // Ending at a soft hyphen: unless the rest of the word fits
                // too, the line would end here, with a hyphen.
                if (endsIn(cuts.items, group_end, .hyphen)) {
                    var rest = need;
                    var k = group_end;
                    while (k + 1 < items.len and item_of.items[k + 1] == item_of.items[k] and (endsIn(cuts.items, k, .hyphen) or endsIn(cuts.items, k, .forced))) : (k += 1) rest += sizes[k + 1];
                    if (start + rest > line.hi + tol) need += hyphenSize(labels, items[index].what.run.style);
                }
            }
            if (forcing) |f| if (index > f) {
                forcing = null;
            };
            // Cutting a word to fit: a piece of it that does not fit goes
            // on to the next line.
            const forced_break = forcing != null and in_group and start + size > line.hi + tol and in_seg > 0;
            // It does not fit: on to the next segment, made as needed, if
            // this one holds something already.
            if (((!in_group and start + need > line.hi + tol and in_seg > 0) or forced_break) and seg + 1 < max_segments) {
                line.soft = true;
                try flow.leave(a, &path, &shifts, &tall, out_issues, seg, first_in_seg, index, closed.items.len > 0, line);
                seg += 1;
                first_in_seg = index;
                path.lead = if (style) |st| st.line_gap else 0;
                if (path.leaves(seg)) {
                    try out_exits.append(a, .{ .track = m.panels.items[more.?.panel].regions.items[more.?.region].id, .piece = index, .segment = seg0 + seg, .paragraph = style_id, .first_line = false, .soft = true });
                    leg_hi = index;
                    exited = true;
                    break;
                }
                try flow.enter(a, &path, seg, tall.items, &closed);
                line = lineIn(style, false, segLength(&path, rows, seg));
                pos = line.lo;
                in_seg = 0;
                start = Flow.clear(closed.items, pos + gap, size);
                // Landing at the start after a soft break, a tile whose
                // prototype says so, or a space between words, is dropped.
                const drops = if (item.tileOf()) |id| m.proto(m.tileConst(id).prototype).at_soft_break == .drop else isSpace(cuts.items, index);
                if (drops) {
                    para -= gap + size;
                    segs_of[index] = seg;
                    spans[index] = .{ pos, pos };
                    dropped[index] = true;
                    continue;
                }
            }
            // A word that does not fit even a line of its own is cut
            // between its glyphs, where it must.
            if (!in_group and forcing == null and in_seg == 0 and start + need > line.hi + tol and endsIn(cuts.items, index, .forced)) forcing = group_end;
            const end = start + size;
            pos = @max(pos, end);
            in_seg += 1;
            path.reach.items[seg] = @max(path.reach.items[seg], end);
            segs_of[index] = seg;
            spans[index] = .{ start, end };
        }
        if (!exited) try flow.leave(a, &path, &shifts, &tall, out_issues, seg, first_in_seg, items.len, closed.items.len > 0, line);

        // Last, each item where it landed. The pieces of a word that were
        // not wrapped between are set as one.
        var chain: ?usize = null;
        for (items[leg_lo..leg_hi], leg_lo..) |item, index| {
            const sg = segs_of[index];
            if (endsIn(cuts.items, index, .forced) and !dropped[index] and index + 1 < leg_hi and segs_of[index + 1] == sg and !dropped[index + 1]) {
                if (chain == null) chain = index;
                continue;
            }
            const first = chain orelse index;
            chain = null;
            const sh = if (dropped[index] or dup[index]) 0 else shifts.items[sg] + extra[index];
            const start = spans[first][0] + (if (first == index) sh else shifts.items[sg] + extra[first]);
            const end = spans[index][1] + sh;
            try out_placed_items.append(a, .{ .region = fri, .flow_panel = fpi, .index = item_of.items[index], .segment = seg0 + sg, .span = .{ start, end } });
            if (dropped[index] or dup[index]) continue;
            const band = path.boxes.items[sg];
            // A line ending inside a word: at a soft hyphen, a hyphen is
            // drawn; at a cut, the wrap is recorded.
            const line_ends = (index + 1 < leg_hi and segs_of[index + 1] != sg) or (index + 1 == leg_hi and exited);
            if (line_ends and endsIn(cuts.items, index, .forced)) try out_wraps.append(a, .{ .region = fri, .flow_panel = fpi, .segment = seg0 + sg, .along = end });
            if (line_ends and endsIn(cuts.items, index, .hyphen)) if (try labels.get(.{ .style = item.what.run.style, .anchor = .start, .box = null, .markup = hyphen_markup })) |hr| {
                const cap = labels.context(item.what.run.style).?.cap_height;
                const hd = hr.design;
                try placed_labels.append(a, .{
                    .tile = if (own) null else synth_owner.items[ri],
                    .slot = if (own) item_of.items[index] else synth_which.items[ri],
                    .box = .{ .x0 = band.x0 + end, .x1 = band.x0 + end + (hd.x1 - hd.x0), .y0 = band.y0, .y1 = band.y1 },
                    .origin = .{ .x = band.x0 + end - hd.x0, .y = (band.y0 + band.y1 - cap) / 2 },
                    .style = item.what.run.style,
                    .render = hr,
                });
            };
            switch (item.what) {
                .tile => |pid| {
                    const t = m.tileConst(pid);
                    const unit = m.proto(t.prototype).unitIn(region.pitch);
                    const pitch_box = flow.tileBox(pid, band, start);
                    const proto = m.proto(t.prototype);
                    const body = proto.body_inset.inset(pitch_box);
                    // A spacer is drawn by nothing and bounds nothing.
                    if (proto.spacer) {
                        try tiles.append(a, .{ .id = pid, .region = ri, .row = sg, .pitch_box = pitch_box, .body = pitch_box, .face = pitch_box, .shapes = &.{}, .spacer = true });
                        continue;
                    }
                    const from_sketch: ?[]const art.Shape = if (proto.sketch) |ps| blk: {
                        const got = try labels.sketchShapes(a, ps, m.tileConst(pid).params.items, pitch_box);
                        if (got == null) try out_issues.append(a, .{ .kind = .tile_sketch, .tile = pid, .region = ri, .row = sg });
                        break :blk got;
                    } else null;
                    const shapes = if (from_sketch) |fs| fs else if (proto.art) |pa| art.stretch(a, pa, unit, pitch_box) catch |err| switch (err) {
                        error.CurveCrossesCut => blk: {
                            try out_issues.append(a, .{ .kind = .tile_art, .tile = pid, .region = ri, .row = sg });
                            break :blk try art.plainShapes(a, proto.*, unit, pitch_box);
                        },
                        else => |e| return e,
                    } else try art.plainShapes(a, proto.*, unit, pitch_box);
                    try tiles.append(a, .{
                        .id = pid,
                        .region = ri,
                        .row = sg,
                        .pitch_box = pitch_box,
                        .body = body,
                        .face = proto.face_inset.inset(body),
                        .shapes = shapes,
                    });
                    if (!proto.allows(t.w, t.h)) try out_issues.append(a, .{ .kind = .tile_size, .tile = pid, .region = ri, .row = sg });
                    bounds = bounds.join(pitch_box);
                },
                .run => |run| {
                    const render = if (cuts.items[index]) |c| blk: {
                        const piece = try a.create(rendering.Render);
                        if (c.space) |k| {
                            // A space is drawn only where a decoration
                            // runs under it.
                            piece.* = try c.render.spacePiece(a, k);
                            const drawn = for (piece.items) |it| {
                                if (it == .path) break true;
                            } else false;
                            if (!drawn) continue;
                        } else piece.* = try c.render.between(a, cuts.items[first].?.from, c.to);
                        break :blk piece;
                    } else renders[index] orelse continue;
                    if (render.syntax.len > 0) try out_issues.append(a, .{ .kind = .markup_error, .region = ri, .row = sg, .item = item_of.items[index], .syntax = render.syntax[0] });
                    const d = render.design;
                    const cap = labels.context(run.style).?.cap_height;
                    // On a baseline that centres its capitals across a
                    // row; centred across a column, one line below another.
                    // In a column, a character's capitals sit a quarter cap
                    // below where its step starts.
                    const origin: Point = if (rows)
                        .{ .x = band.x0 + start - d.x0, .y = (band.y0 + band.y1 - cap) / 2 }
                    else if (cuts.items[index] != null)
                        .{ .x = (band.x0 + band.x1 - (d.x1 - d.x0)) / 2 - d.x0, .y = band.y1 - start - 1.25 * cap }
                    else
                        .{ .x = (band.x0 + band.x1 - (d.x1 - d.x0)) / 2 - d.x0, .y = band.y1 - start - d.y1 };
                    const box: Box = if (rows)
                        .{ .x0 = band.x0 + start, .x1 = band.x0 + end, .y0 = band.y0, .y1 = band.y1 }
                    else
                        .{ .x0 = band.x0, .x1 = band.x1, .y1 = band.y1 - start, .y0 = band.y1 - end };
                    try placed_labels.append(a, .{
                        .run = if (own) .{ .region = fri, .panel = fpi, .item = item_of.items[index], .from = src_off.items[first], .len = src_off.items[index] + src_len.items[index] - src_off.items[first] } else null,
                        .tile_run = if (own) null else .{ .item = item_of.items[index], .from = src_off.items[first], .len = src_off.items[index] + src_len.items[index] - src_off.items[first] },
                        .tile = if (own) null else synth_owner.items[ri],
                        .slot = if (own) item_of.items[index] else synth_which.items[ri],
                        .box = box,
                        .origin = origin,
                        .style = run.style,
                        .render = render,
                    });
                    for (render.diagnostics) |dg| if (dg.kind == .missing_glyph) {
                        try out_issues.append(a, .{ .kind = .missing_glyph, .region = ri, .row = sg, .item = item_of.items[index] });
                        break;
                    };
                    if (lacksVariant(render.diagnostics)) try out_issues.append(a, .{ .kind = .variant_missing, .region = ri, .row = sg, .item = item_of.items[index] });
                },
                .hard_break, .paragraph => {},
            }
        }
        natural = @max(natural, para);
        try out_flows.append(a, .{ .region = fri, .flow_panel = fpi, .natural = natural / region.pitch, .segments = seg0 + path.origins.items.len, .waiting = entry == null });
        for (path.reach.items, 0..) |r_, t| {
            const len_t = segLength(&path, rows, t);
            if (r_ > len_t + tol) try out_issues.append(a, .{ .kind = .row_overflow, .region = ri, .row = t, .amount = r_ - len_t });
        }
        // Its segments: past the soft area each is flagged; past the panel,
        // the region is (to be fitted, or the panel resized).
        var all: Box = .empty;
        var local: usize = 0;
        for (path.origins.items, path.boxes.items, 0..) |o, b, t| {
            if (t > 0 and path.member.items[t] != path.member.items[t - 1]) local = 0;
            const member = thread[path.member.items[t]];
            const soft = path.regionOf(t).softArea();
            try out_tracks.append(a, .{ .region = fri, .track = seg0 + t, .flow_panel = fpi, .panel = panel, .member = member, .local = local, .major = region.major(), .box = b, .origin = o });
            local += 1;
            all = all.join(b);
            // Along, the path and the segment length are the boundary: a
            // segment is always within it. Across, past the segments the
            // space was drawn out for is flagged.
            const past = if (rows) b.y0 < soft.y0 - tol or b.y1 > soft.y1 + tol else b.x0 < soft.x0 - tol or b.x1 > soft.x1 + tol;
            if (past) try out_issues.append(a, .{ .kind = .past_soft_area, .region = ri, .row = t });
        }
        // The canvas has no outline to keep to.
        const past = @max(@max(outline.x0 - all.x0, all.x1 - outline.x1), @max(outline.y0 - all.y0, all.y1 - outline.y1));
        if (past > 1e-9 and !m.panels.items[panel].unbounded) try out_issues.append(a, .{ .kind = .region_outside, .region = ri, .amount = past });
        for (thread) |member| if (!regs[member].supported())
            try out_issues.append(a, .{ .kind = .unsupported_direction, .region = member });
    }
    }
    // A tile track's problems are its tile's.
    for (junk_issues.items) |i| {
        const r = i.region orelse continue;
        if (r >= synth_owner.items.len) continue;
        const kind: @TypeOf(i.kind) = switch (i.kind) {
            .row_overflow, .past_soft_area, .region_outside => .label_overflow,
            .missing_glyph, .markup_error, .style_error, .variant_missing => i.kind,
            else => continue,
        };
        try issues.append(a, .{ .kind = kind, .tile = synth_owner.items[r], .slot = synth_which.items[r], .syntax = i.syntax });
    }



    // Runs of text in tracks reach past the tiles' boxes: the bounds hold
    // their ink too, so a canvas with only text still has extents.
    for (placed_labels.items) |l| {
        if (l.tile != null) continue;
        const ink = l.render.ink;
        if (ink.isEmpty()) continue;
        bounds = bounds.join(.{ .x0 = l.origin.x + ink.x0, .y0 = l.origin.y + ink.y0, .x1 = l.origin.x + ink.x1, .y1 = l.origin.y + ink.y1 });
    }

    const this = m.panels.items[panel];
    const has_cutout = for (this.art.items) |pa| {
        if (pa.cutout) break true;
    } else for (tiles.items) |t| {
        if (t.grid == .hole) break true;
    } else false;
    var edge: ?geom.Outline = null;
    if (this.edge) |e| {
        const shapes = try art.dupeShapes(a, e.shapes, e.at);
        if (shapes.len > 0) edge = shapes[0].outline;
    } else if (has_cutout and !this.unbounded) {
        const shapes = try art.primitive(a, "edge", .{ .rect = .{ .w = this.w, .h = this.h } }, .{});
        edge = shapes[0].outline;
    }
    if (edge) |e| bounds = bounds.join(e.bounds());
    const body: ?geom.Outline = if (edge) |e| try panelBody(a, e, placed_art.items, tiles.items) else null;

    return .{
        .arena = arena,
        .exits = try exits.toOwnedSlice(a),
        .wraps = try wraps.toOwnedSlice(a),
        .edge = edge,
        .body = body,
        .tiles = try tiles.toOwnedSlice(a),
        .tracks = try tracks.toOwnedSlice(a),
        .items = try placed_items.toOwnedSlice(a),
        .art = try placed_art.toOwnedSlice(a),
        .flows = try flows.toOwnedSlice(a),
        .labels = try placed_labels.toOwnedSlice(a),
        .issues = try issues.toOwnedSlice(a),
        .bounds = bounds,
    };
}

/// Whether two sets of handoffs are the same (in any order).
pub fn sameHandoffs(x: []const Handoff, y: []const Handoff) bool {
    if (x.len != y.len) return false;
    for (x) |h| {
        const found = for (y) |k| {
            if (std.meta.eql(h, k)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// The panels a thread crosses into or out of: the only ones whose
/// solving changes where threads enter other panels.
fn threadPanels(gpa: Allocator, m: *const Model) Allocator.Error![]usize {
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(gpa);
    for (m.panels.items, 0..) |p, pi| for (p.regions.items, 0..) |_, ri| {
        const n = m.threadAfter(pi, ri) orelse continue;
        if (n.panel == pi) continue;
        for ([_]usize{ pi, n.panel }) |x| if (std.mem.indexOfScalar(usize, list.items, x) == null) try list.append(gpa, x);
    };
    std.mem.sort(usize, list.items, {}, std.sort.asc(usize));
    return list.toOwnedSlice(gpa);
}

/// Where every thread enters each panel it runs on into, worked out by
/// solving the panels threads cross, each with the handoffs the others
/// gave last time, until those stop changing. `start` is a first guess
/// (the last known handoffs, say); the result is the caller's.
pub fn handoffs(gpa: Allocator, m: *const Model, labels: *Labels, start: []const Handoff) Error![]Handoff {
    const panels = try threadPanels(gpa, m);
    defer gpa.free(panels);
    var entries: std.ArrayList(Handoff) = .empty;
    errdefer entries.deinit(gpa);
    try entries.appendSlice(gpa, start);
    if (panels.len == 0) {
        entries.clearRetainingCapacity();
        return entries.toOwnedSlice(gpa);
    }
    // Each pass carries a thread at least one panel further.
    var pass: usize = 0;
    while (pass < m.panels.items.len + 2) : (pass += 1) {
        var next: std.ArrayList(Handoff) = .empty;
        defer next.deinit(gpa);
        for (panels) |pi| {
            var placed = try solveWith(gpa, m, pi, labels, entries.items);
            defer placed.deinit();
            try next.appendSlice(gpa, placed.exits);
        }
        if (sameHandoffs(next.items, entries.items)) break;
        entries.clearRetainingCapacity();
        try entries.appendSlice(gpa, next.items);
    }
    return entries.toOwnedSlice(gpa);
}

/// Every panel placed, threads followed across panels (see `handoffs`).
/// The caller deinits each and frees the slice.
pub fn solveAll(gpa: Allocator, m: *const Model, labels: *Labels) Error![]Placed {
    const entries = try handoffs(gpa, m, labels, &.{});
    defer gpa.free(entries);
    var out: std.ArrayList(Placed) = .empty;
    errdefer {
        for (out.items) |*p| p.deinit();
        out.deinit(gpa);
    }
    for (0..m.panels.items.len) |pi| try out.append(gpa, try solveWith(gpa, m, pi, labels, entries));
    return out.toOwnedSlice(gpa);
}

/// Rounds a cache-key length to 1 nm, so the same box reached by different
/// sums of positions is one key.
fn snap(v: f64) f64 {
    return @round(v * 1e6) / 1e6;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const testdata = @import("graven_testdata");

test "segments pack by gaps, a hard break starts the next, and a tall tile closes its stretch of the next" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const r = try m.addRegion(p, .{ .name = "pad", .origin = .{ .x = 10, .y = 90 }, .w = 5, .h = 2, .pitch = 10 });
    const one = try m.addTile(.{ .designator = "1" });
    const two = try m.addTile(.{ .designator = "2" });
    const tall = try m.addTile(.{ .designator = "T", .h = 2 });
    const wide = try m.addTile(.{ .designator = "0", .w = 2 });
    try m.place(p, r, null, .{ .what = .{ .tile = one } });
    try m.place(p, r, null, .{ .gap = 0.5, .what = .{ .tile = two } });
    try m.place(p, r, null, .{ .what = .{ .tile = tall } });
    try m.place(p, r, null, .{ .what = .hard_break });
    try m.place(p, r, null, .{ .what = .{ .tile = wide } });
    // The tall key, listed once, closes 25..35 mm of the second row: this
    // key, which would land at 20..30, goes on past it.
    const three = try m.addTile(.{ .designator = "3" });
    try m.place(p, r, null, .{ .what = .{ .tile = three } });

    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(5, s.tiles.len);
    try testing.expectEqual(25, s.findTile(two).?.pitch_box.x0);
    try testing.expectEqual(35, s.findTile(tall).?.pitch_box.x0);
    try testing.expectEqual(70, s.findTile(tall).?.pitch_box.y0);
    try testing.expectEqual(80, s.findTile(wide).?.pitch_box.y1);
    try testing.expectEqual(45, s.findTile(three).?.pitch_box.x0);
    try testing.expectEqual(80, s.findTile(three).?.pitch_box.y1);
    try testing.expectEqual(0, s.issues.len);
}

test "a row too long wraps on into a new one, past the soft area, flagged" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 100 }, .w = 2, .h = 1, .pitch = 10 });
    for ([_][]const u8{ "A", "B", "C" }) |d| try m.place(p, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = d }) } });
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(1, s.issues.len);
    try testing.expectEqual(.past_soft_area, s.issues[0].kind);
    try testing.expectEqual(1, s.issues[0].row.?);
    try testing.expectEqual(1, s.items[2].segment);
}

test "legends render once per identical text and sit on their track's line" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};

    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 3, .h = 1, .pitch = 19.05 });
    const key = try m.addPrototype(.{ .name = "key", .body_inset = .all(0.5), .face_inset = .all(2), .tracks = &.{.{ .name = "top", .style = style, .place = .{ .inset = .all(1) } }} });
    for ([_][]const u8{ "K1", "K2" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setTrackText(t, "top", "H");
        try m.place(p, r, null, .{ .what = .{ .tile = t } });
    }
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(2, s.labels.len);
    try testing.expectEqual(s.labels[0].render, s.labels[1].render);
    try testing.expectEqual(1, labels.cache.count());
    // On the track's first line, from its start: capitals centred across
    // the line.
    const l = s.labels[0];
    try testing.expectApproxEqAbs((l.box.y0 + l.box.y1 - 3) / 2, l.origin.y, 1e-9);
    try testing.expect(l.origin.x + l.render.ink.x0 >= l.box.x0 - 1e-9);

    // A style change drops its renders.
    try m.setCapHeight(style, 2.5);
    var s2 = try solve(gpa, &m, p, &labels);
    defer s2.deinit();
    try testing.expectEqual(1, labels.cache.count());
    try testing.expectApproxEqAbs((s2.labels[0].box.y0 + s2.labels[0].box.y1 - 2.5) / 2, s2.labels[0].origin.y, 1e-9);
}

test "a run being typed is stored as typed, flagged, and still drawn" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 10, .y = 40 }, .style = style, .count = 1, .length = 10, .pitch = 5 });
    try m.insertRun(p, r, 0, .{ .style = style, .content = "$H^" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqualStrings("$H^", m.flowItems(p, r)[0].what.run.content);
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
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 3, .h = 1, .pitch = 19.05 });
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{.{ .name = "top", .style = style }} });
    const t = try m.addTile(.{ .designator = "K1", .prototype = key });
    try m.setTrackText(t, "top", "HQ");
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
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 4, .h = 1, .pitch = 19.05 });
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
    try testing.expectError(error.NoSuchPrototype, m.setTilePrototype(m.findTile("K1").?, @enumFromInt(9999)));
}

test "changing a prototype's track moves every tile's text in it" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .cap_height = 3 });
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 4, .h = 1, .pitch = 19.05 });
    const key = try m.addPrototype(.{ .name = "key", .face_inset = .all(2), .tracks = &.{.{ .name = "top", .style = style, .place = .{ .inset = .all(1) } }} });
    for ([_][]const u8{ "K1", "K2", "K3" }) |d| {
        const t = try m.addTile(.{ .designator = d, .prototype = key });
        try m.setTrackText(t, "top", "H");
        try m.place(p, r, null, .{ .what = .{ .tile = t } });
    }
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var before = try solve(gpa, &m, p, &labels);
    defer before.deinit();
    var moved = m.proto(key).tracks[0];
    moved.place.inset = .{ .left = 3, .right = 1, .top = 1, .bottom = 1 };
    try m.setPrototypeTrack(key, moved.id, moved);
    var after = try solve(gpa, &m, p, &labels);
    defer after.deinit();
    try testing.expectEqual(3, after.labels.len);
    for (before.labels, after.labels) |b, a| try testing.expectApproxEqAbs(@as(f64, 2), a.box.x0 - b.box.x0, 1e-9);
}

test "a tile's text wraps around art placed over its track" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .cap_height = 8 });
    const p = try m.addPanel("board", 100, 100);
    const key = try m.addPrototype(.{ .name = "key", .unit = 40, .tracks = &.{.{ .name = "top", .style = style, .place = .{ .inset = .all(1) } }} });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 10, .y = 90 }, .prototype = key, .count = 1, .length = 1, .pitch = 40 });
    const t = try m.insertTile(p, r, 0, key, 1);
    // "HH HH" is about 20 mm of ink: one line on the 38 mm face.
    try m.setTrackText(t, "top", "HH HH");
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    {
        // One line: both words on it.
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectApproxEqAbs(s.labels[0].origin.y, s.labels[s.labels.len - 1].origin.y, 1e-9);
    }
    // A disc over the face's right half, which the track lies under (so
    // the key stays), leaves about 17 mm open on the left: the legend
    // wraps there, each line in the open span.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const disc = try art.ellipse(arena.allocator(), "disc", 20, 40, .{});
    _ = try m.addArt(p, .{ .name = "disc", .at = .{ .x = 30, .y = 50 }, .shapes = disc, .clearance = 1, .wrap_tracks = false });
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // Two lines now, every word's ink left of the disc.
    var lowest: f64 = s.labels[0].origin.y;
    for (s.labels) |l| {
        if (l.render.ink.isEmpty()) continue;
        try testing.expect(l.origin.x + l.render.ink.x1 <= 30 + 1e-6);
        lowest = @min(lowest, l.origin.y);
    }
    try testing.expect(lowest < s.labels[0].origin.y - 1);
}

test "a run of text breaks between its words; a space a wrap leaves at a row's start is dropped" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 4 });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 3, .length = 3, .pitch = 10 });
    // Three words in one run; 30 mm rows hold two.
    try m.insertRun(p, r, 0, .{ .style = body, .content = "HOD ADD HOD" });
    // An equation stays whole, spaces and all.
    try m.insertRun(p, r, 1, .{ .style = body, .content = "A = \\frac{H}{D}", .equation = true });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // Five pieces of item 0 (three words, two spaces), one of item 1.
    var words: usize = 0;
    for (s.labels) |l| if (l.run) |run| {
        if (run.item == 0) words += 1;
    };
    try testing.expectEqual(3, words);
    var pieces: [8]PlacedItem = undefined;
    var n: usize = 0;
    for (s.items) |it| if (it.index == 0) {
        pieces[n] = it;
        n += 1;
    };
    try testing.expectEqual(5, n);
    // Words one space apart, the space a third of an em.
    try testing.expect(pieces[1].span[1] - pieces[1].span[0] > 0);
    try testing.expectApproxEqAbs(pieces[0].span[1], pieces[1].span[0], 1e-9);
    try testing.expectApproxEqAbs(pieces[1].span[1], pieces[2].span[0], 1e-9);
    // The third word wraps; the space before it, landing at the start of
    // the second row, is dropped (no length), so the word starts the row.
    try testing.expectEqual(0, pieces[2].segment);
    try testing.expectEqual(1, pieces[4].segment);
    try testing.expectApproxEqAbs(@as(f64, 0), pieces[4].span[0], 1e-9);
    // The word labels know where in the run's markup they start.
    for (s.labels) |l| if (l.run) |run| if (run.item == 0 and run.from == 8) {
        try testing.expectEqual(3, run.len);
    };
}

test "a run with markup breaks between words, inside a bold group too, keeping its faces" {
    const gpa = testing.allocator;
    const regular = try font.Face.init(gpa, testdata.truetype, 0);
    defer regular.deinit();
    const bold = try font.Face.init(gpa, testdata.cff, 0);
    defer bold.deinit();
    const faces = [_]*font.Face{ regular, bold };
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 4 });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 3, .length = 3, .pitch = 10 });
    const src = "HOD \\textbf{ADD HOD} HOD";
    try m.insertRun(p, r, 0, .{ .style = body, .content = src });
    // Its fonts as resolving them would give: the bold face second.
    var resolved: fonts.Resolved = .{ .gpa = gpa };
    defer resolved.deinit();
    try resolved.faces.appendSlice(gpa, &faces);
    try resolved.roles.append(gpa, .{ .role = "bold", .face = 1 });
    try resolved.styles.append(gpa, .{ .id = body, .faces = resolved.roles.items });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    try labels.syncResolved(&resolved);
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // Four word pieces: HOD, ADD (bold), HOD (bold), HOD.
    var words: [4]PlacedLabel = undefined;
    var n: usize = 0;
    for (s.labels) |l| if (l.run != null) {
        words[n] = l;
        n += 1;
    };
    try testing.expectEqual(4, n);
    try testing.expectEqual(@as(?rendering.FaceId, 0), words[0].render.elements[0].face);
    try testing.expectEqual(@as(?rendering.FaceId, 1), words[1].render.elements[0].face);
    try testing.expectEqual(@as(?rendering.FaceId, 1), words[2].render.elements[0].face);
    try testing.expectEqual(@as(?rendering.FaceId, 0), words[3].render.elements[0].face);
    // Each knows its source, up to the next break: the second bold word
    // with the group's closing brace.
    try testing.expectEqualStrings("HOD}", src[words[2].run.?.from..][0..words[2].run.?.len]);
    // 30 mm rows hold two words: the group breaks across rows.
    var segs: [4]usize = undefined;
    var k: usize = 0;
    for (s.labels) |l| if (l.run != null) {
        // Which row: rows stack down from y 100, 10 mm each.
        segs[k] = @intFromFloat(@floor((100 - l.box.y1 + 1e-6) / 10));
        k += 1;
    };
    try testing.expectEqual(segs[0], segs[1]);
    try testing.expect(segs[2] > segs[1]);
    // A piece starts where the row starts after a wrap, its ink near x 0.
    try testing.expect(words[2].box.x0 < 1e-6);
    try testing.expect(words[2].render.ink.x0 >= -1e-9);
}

test "paragraphs: indents, a justified paragraph, a centred one, and space between them" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 200);
    const body = try m.addStyle("Body", .{ .cap_height = 4 });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 200 }, .style = body, .count = 12, .length = 6, .pitch = 10 });
    const just = try m.addParagraphStyle(.{ .name = "Body", .alignment = .justify, .indent_start = 4, .first = 6, .indent_end = 2, .space_after = 5 });
    const centred = try m.addParagraphStyle(.{ .name = "Centred", .alignment = .centre, .space_before = 3, .line_gap = 2 });
    try m.setParagraphAt(p, r, 0, just);
    try m.insertRun(p, r, 0, .{ .style = body, .content = "HOD ADD HOD ADD HOD ADD HOD" });
    try m.insertParagraph(p, r, 1, centred);
    try m.insertRun(p, r, 2, .{ .style = body, .content = "HOD ADD HOD ADD HOD ADD" });
    try testing.expectEqual(just, m.paragraphStyleAt(p, r, 0));
    try testing.expectEqual(centred, m.paragraphStyleAt(p, r, 2));

    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(0, s.issues.len);
    // Per segment: where its words start and end along it.
    var lo: [8]f64 = @splat(std.math.inf(f64));
    var hi: [8]f64 = @splat(-std.math.inf(f64));
    var seg_item: [8]usize = undefined;
    for (s.labels) |l| {
        const run = l.run orelse continue;
        const mid = (l.box.y0 + l.box.y1) / 2;
        const t = for (s.tracks, 0..) |tr, k| {
            if (mid > tr.box.y0 and mid < tr.box.y1) break k;
        } else unreachable;
        lo[t] = @min(lo[t], l.box.x0);
        hi[t] = @max(hi[t], l.box.x1);
        seg_item[t] = run.item;
    }
    var nsegs: usize = 0;
    while (nsegs < 8 and lo[nsegs] < std.math.inf(f64)) nsegs += 1;
    try testing.expect(nsegs >= 4);
    // The first line: indented 4 + 6, justified out to 60 - 2.
    try testing.expectApproxEqAbs(@as(f64, 10), lo[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 58), hi[0], 1e-6);
    // The next lines of the paragraph: from 4.
    try testing.expectApproxEqAbs(@as(f64, 4), lo[1], 1e-9);
    // The paragraph's last line is not stretched; the centred paragraph's
    // lines are centred in the whole segment.
    var last: usize = 0;
    while (seg_item[last + 1] == 0) last += 1;
    try testing.expect(hi[last] < 58 - 1);
    const c = last + 1;
    try testing.expectApproxEqAbs(@as(f64, 30), (lo[c] + hi[c]) / 2, 1e-6);
    // Between the paragraphs, 5 + 3 mm more than a line; within the
    // centred one, its 2 mm line gap.
    const step_in = s.tracks[1].origin.across - s.tracks[0].origin.across;
    const step_between = s.tracks[c].origin.across - s.tracks[last].origin.across;
    try testing.expectApproxEqAbs(step_in + 0.8, step_between, 1e-9);
    if (c + 1 < s.tracks.len) {
        const step_centred = s.tracks[c + 1].origin.across - s.tracks[c].origin.across;
        try testing.expectApproxEqAbs(step_in + 0.2, step_centred, 1e-9);
    }
}

test "text on a canvas, with no sheet or panel, solves and exports" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    const style = try m.addStyle("Label", .{ .cap_height = 3 });
    // A track far from the origin, below and left of it: the canvas has
    // no edge.
    const r = try m.addTracks(c, .{ .name = "text", .origin = .{ .x = -40, .y = -20 }, .style = style, .count = 1, .length = 20, .pitch = 5 });
    try m.insertRun(c, r, 0, .{ .style = style, .content = "HOD" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, c, &labels);
    defer s.deinit();
    try testing.expectEqual(0, s.issues.len);
    try testing.expectEqual(1, s.labels.len);
    try testing.expect(!s.bounds.isEmpty());
    try testing.expect(s.bounds.x0 >= -40 - 1e-9 and s.bounds.y0 < -21);
    const intrusions = try @import("drc.zig").marginIntrusions(gpa, &m, &.{s});
    defer gpa.free(intrusions);
    try testing.expectEqual(0, intrusions.len);
    const svg = try @import("output.zig").panelSvg(gpa, &s, &faces, .{});
    defer gpa.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}

test "a panel made from a rounded rectangle exports its outline with the cutouts as holes" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const prim: art.Primitive = .{ .rounded = .{ .w = 80, .h = 50, .r = 5 } };
    const outline = try m.addArt(c, .{ .name = "Outline", .at = .{ .x = 0, .y = 0 }, .shapes = try art.primitive(a, "Outline", prim, .{ .edge = .{ .r = 0, .g = 0, .b = 0 } }), .prim = prim });
    for ([_]f64{ 8, 66 }) |x| {
        const hole: art.Primitive = .{ .circle = 6 };
        const ai = try m.addArt(c, .{ .name = "Hole", .at = .{ .x = x, .y = 22 }, .shapes = try art.primitive(a, "Hole", hole, .{}), .prim = hole });
        try m.setArtCutout(c, ai, true);
    }
    const style = try m.addStyle("Label", .{ .cap_height = 3 });
    const r = try m.addTracks(c, .{ .name = "text", .origin = .{ .x = 30, .y = 30 }, .style = style, .count = 1, .length = 6, .pitch = 5 });
    try m.insertRun(c, r, 0, .{ .style = style, .content = "HOD" });
    const p = try m.makePanel(c, outline);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expect(s.edge != null);
    try testing.expectEqual(1, s.labels.len);
    const svg = try @import("output.zig").panelSvg(gpa, &s, &faces, .{});
    defer gpa.free(svg);
    // One even-odd body path: the outline and two holes (three contours).
    const at = std.mem.indexOf(u8, svg, "fill-rule=\"evenodd\"") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, svg, at, "/>").?;
    try testing.expectEqual(3, std.mem.count(u8, svg[at..end], "Z"));
}

test "a word longer than its line is cut to wrap, and the wrap recorded, not flagged" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 4 });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    try labels.sync(&m);
    const word = "HODDAHODDAHODDA";
    const w = blk: {
        const rr = (try labels.get(.{ .style = body, .anchor = .start, .box = null, .markup = word })).?;
        break :blk rr.design.x1 - rr.design.x0;
    };
    // Rows a little over a third of the word long: it takes three, after
    // a short word that fits the first.
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 6, .length = w * 0.4 / 10, .pitch = 10 });
    try m.insertRun(p, r, 0, .{ .style = body, .content = "H " ++ word });
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    for (s.issues) |i| try testing.expect(i.kind != .row_overflow);
    // The short word stays alone on the first row; the long one goes on to
    // the second, and is cut there and on the third.
    try testing.expectEqual(2, s.wraps.len);
    try testing.expectEqual(1, s.wraps[0].segment);
    try testing.expectEqual(2, s.wraps[1].segment);
    // Its pieces cover it once, each within its row.
    var covered: u32 = 0;
    for (s.labels) |l| if (l.run) |run| if (run.from >= 2) {
        covered += run.len;
        try testing.expect(l.render.design.x1 - l.render.design.x0 <= w * 0.4 + 1e-6);
    };
    try testing.expectEqual(@as(u32, word.len), covered);
}

test "a line breaks at a soft hyphen, with a hyphen drawn, only when the word does not fit" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 4 });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    try labels.sync(&m);
    const half = (try labels.get(.{ .style = body, .anchor = .start, .box = null, .markup = "HODDA" })).?.design;
    const w = half.x1 - half.x0;
    // Rows that hold "HODDA-" but not the whole word.
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 3, .length = w * 1.5 / 10, .pitch = 10 });
    try m.insertRun(p, r, 0, .{ .style = body, .content = "HODDA\\-HODDA" });
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        var runs: usize = 0;
        var hyphens: usize = 0;
        for (s.labels) |l| {
            if (l.run != null) runs += 1 else hyphens += 1;
        }
        try testing.expectEqual(2, runs);
        try testing.expectEqual(1, hyphens);
        try testing.expectEqual(0, s.wraps.len);
        for (s.issues) |i| try testing.expect(i.kind != .row_overflow);
    }
    // Rows long enough for the whole word: no break, no hyphen.
    m.panels.items[p].regions.items[r].w = w * 3 / 10;
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    for (s.labels) |l| try testing.expect(l.run != null);
    var segs: [2]usize = .{ 9, 9 };
    var n: usize = 0;
    for (s.items) |it| {
        if (n < 2) segs[n] = it.segment;
        n += 1;
    }
    try testing.expectEqual(segs[0], segs[1]);
}

test "tiles drawn from a prototype's sketch, solved for each size; a size that does not solve is flagged" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    // A body 0.5 mm in from the pitch box on every side, from w and h; a
    // homing bump, construction until a tile asks for it; and a slot that
    // needs a tile wider than 25 mm.
    const si = try m.addSketch(0, "Key", .{ .x = 0, .y = 0 });
    const sk = &m.sketches.items[si].sketch;
    const al = m.arena.allocator();
    const P = struct { fn f(x: f64, y: f64) geom.Point { return .{ .x = x, .y = y }; } }.f;
    try sk.setParam(al, "w", "19.05");
    try sk.setParam(al, "h", "19.05");
    try sk.setParam(al, "homing", "0");
    const b = try sk.addSegment(al, P(0.5, 0.5), P(18.5, 0.5), false);
    const rt = try sk.addSegment(al, P(18.5, 0.5), P(18.5, 18.5), false);
    const t = try sk.addSegment(al, P(18.5, 18.5), P(0.5, 18.5), false);
    const l = try sk.addSegment(al, P(0.5, 18.5), P(0.5, 0.5), false);
    const segs = [_]u32{ b, rt, t, l };
    for (0..4) |i| _ = try sk.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = segs[i], .role = .end }, .{ .geom = segs[(i + 1) % 4], .role = .start } } } });
    _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = b } } });
    _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = t } } });
    _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .geom = l } } });
    _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .geom = rt } } });
    _ = try sk.addConstraint(al, .{ .kind = .{ .fixed = .{ .p = .{ .geom = b, .role = .start }, .at = P(0.5, 0.5) } } });
    const dw = try sk.addConstraint(al, .{ .kind = .{ .distance_x = .{ .a = .{ .geom = b, .role = .start }, .b = .{ .geom = b, .role = .end }, .value = 18 } } });
    const dh = try sk.addConstraint(al, .{ .kind = .{ .distance_y = .{ .a = .{ .geom = rt, .role = .start }, .b = .{ .geom = rt, .role = .end }, .value = 18 } } });
    try sk.setExpr(al, dw, "w - 1");
    try sk.setExpr(al, dh, "h - 1");
    const bump = try sk.addCircle(al, P(9.5, 5), 1, true);
    _ = try sk.addConstraint(al, .{ .kind = .{ .fixed = .{ .p = .{ .geom = bump, .role = .centre }, .at = P(9.5, 5) } } });
    _ = try sk.addConstraint(al, .{ .kind = .{ .radius = .{ .g = bump, .value = 1 } } });
    try sk.setPhysicalWhen(al, bump, "homing");
    _ = try sk.solve(gpa);
    const key = try m.addPrototype(.{ .name = "key", .unit = 19.05 });
    // Not the parameters it has: refused.
    try testing.expectError(error.NoSuchParameter, m.applySketch(key, si, "width", "h", .{ .x = 0, .y = 0 }));
    try m.applySketch(key, si, "w", "h", .{ .x = 0, .y = 0 });
    const r = try m.addTracks(c, .{ .name = "row", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 1, .length = 6, .pitch = 19.05 });
    _ = try m.insertTile(c, r, 0, key, 1);
    _ = try m.insertTile(c, r, 1, key, 2);
    const third = try m.insertTile(c, r, 2, key, 1);
    try m.setTileParam(third, "homing", 1);
    // The original changes; the prototype's copy does not.
    try sk.setParam(al, "w", "50");
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, c, &labels);
    defer s.deinit();
    try testing.expectEqual(3, s.tiles.len);
    // 1u: one profile, 18.05 wide; 2u: 37.1 wide; the third has its bump.
    try testing.expectEqual(1, s.tiles[0].shapes.len);
    try testing.expectApproxEqAbs(19.05 - 1, s.tiles[0].shapes[0].outline.bounds().width(), 1e-9);
    try testing.expectApproxEqAbs(s.tiles[0].pitch_box.x0 + 0.5, s.tiles[0].shapes[0].outline.bounds().x0, 1e-9);
    try testing.expectApproxEqAbs(38.1 - 1, s.tiles[1].shapes[0].outline.bounds().width(), 1e-9);
    try testing.expectEqual(2, s.tiles[2].shapes.len);
    for (s.issues) |i| try testing.expect(i.kind != .tile_sketch);
    // A size it cannot take: the body's width must be at least 25 mm.
    const psk = &m.proto(key).sketch.?.sketch;
    try psk.setExpr(m.arena.allocator(), dw, "sqrt(w - 25)");
    m.proto(key).sketch.?.id = m.newId();
    var s2 = try solve(gpa, &m, c, &labels);
    defer s2.deinit();
    var flagged: usize = 0;
    for (s2.issues) |i| if (i.kind == .tile_sketch) {
        flagged += 1;
    };
    try testing.expectEqual(2, flagged);
}

test "a tile's tracks: a row wraps between words in the face; a column sets letters upright, one below another" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .cap_height = 2 });
    const p = try m.addPanel("board", 100, 60);
    const r = try m.addRegion(p, .{ .name = "row", .origin = .{ .x = 0, .y = 60 }, .w = 3, .h = 2, .pitch = 19.05 });
    // A tall key: a row track across its top, a column track below it.
    const key = try m.addPrototype(.{ .name = "key", .unit = 19.05, .face_inset = .all(1), .tracks = &.{
        .{ .name = "words", .style = style, .place = .{ .inset = .{ .bottom = 30 } } },
        .{ .name = "down", .style = style, .major = .column, .alignment = .start, .place = .{ .inset = .{ .top = 8 } } },
    } });
    const t = try m.addTile(.{ .designator = "K1", .prototype = key, .h = 2 });
    try m.place(p, r, null, .{ .what = .{ .tile = t } });
    try m.setTileTrackText(t, m.tileTrackNamed(t, "words").?, "one two three four five");
    try m.setTileTrackText(t, m.tileTrackNamed(t, "down").?, "ENTER");
    try testing.expect(m.tileTrackNamed(t, "side") == null);

    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    const tb = s.findTile(t).?.face;
    var words: usize = 0;
    var letters: std.ArrayList(PlacedLabel) = .empty;
    defer letters.deinit(gpa);
    for (s.labels) |l| {
        if (l.tile == null or l.tile.? != t) continue;
        // Every piece is set inside the tile's face; `slot` names the track.
        try testing.expect(l.origin.x >= tb.x0 - 1e-6 and l.origin.x <= tb.x1);
        if (l.slot == 0) words += 1 else try letters.append(gpa, l);
    }
    // The words wrapped onto more than one line: several pieces.
    try testing.expect(words > 1);
    // Five letters, one below another, each about centred across.
    try testing.expectEqual(@as(usize, 5), letters.items.len);
    for (letters.items[1..], 0..) |l, k| try testing.expect(l.origin.y < letters.items[k].origin.y);
    // The panel's own tracks know nothing of the tile's.
    for (s.tracks) |tr| try testing.expectEqual(@as(usize, 0), tr.region);
    for (s.issues) |i| try testing.expect(i.kind != .row_overflow);
}

test "a grid stamp drawn from a ready-made sketch: each hole is the sketch solved for its box, live" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const plate = try m.placePanel(.{ .name = "Plate", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 60, .h = 30 });
    const key = try m.addPrototype(.{ .name = "Key" });
    const rr = try m.addShapeSketch(.rounded_rectangle);
    const g = try m.addGrid(plate, .{ .x = 10, .y = 15 }, .{ .cols = 3, .rows = 1, .pitch_x = 15, .pitch_y = 12 });
    _ = try m.addStamp(plate, g, .{ .name = "Holes", .prototype = key, .role = .hole, .w = 9.5, .h = 8.5, .sketch = m.sketches.items[rr].id, .params = &.{.{ .name = "r", .value = 2 }} });
    _ = try m.fillGrid(plate, g, 0);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    {
        var placed = try solve(gpa, &m, plate, &labels);
        defer placed.deinit();
        try testing.expectEqual(@as(usize, 0), placed.issues.len);
        var holes: usize = 0;
        for (placed.tiles) |t| {
            if (t.grid != .hole) continue;
            holes += 1;
            try testing.expectEqual(@as(usize, 1), t.shapes.len);
            const b = t.shapes[0].outline.bounds();
            try testing.expectApproxEqAbs(t.pitch_box.width(), b.width(), 1e-6);
            try testing.expectApproxEqAbs(t.pitch_box.height(), b.height(), 1e-6);
            try testing.expectApproxEqAbs((t.pitch_box.x0 + t.pitch_box.x1) / 2, (b.x0 + b.x1) / 2, 1e-6);
            // Rounded: no corner of the box is on the outline.
            const segs = t.shapes[0].outline.contours[0].segments;
            var arcs: usize = 0;
            for (segs) |sg| if (sg != .line) {
                arcs += 1;
            };
            try testing.expectEqual(@as(usize, 4), arcs);
        }
        try testing.expectEqual(@as(usize, 3), holes);
    }
    // Live: an edit to the sketch reaches every hole. With the stamp's own
    // radius gone, the sketch's is used; a bigger one shortens the sides.
    m.panels.items[plate].grids.items[g].stamps.items[0].params = &.{};
    var lens: [2]f64 = undefined;
    for ([_][]const u8{ "1", "3" }, &lens) |r, *len| {
        _ = try m.editSketch(rr, .{ .param = .{ .name = "r", .expr = r } });
        var placed = try solve(gpa, &m, plate, &labels);
        defer placed.deinit();
        try testing.expectEqual(@as(usize, 0), placed.issues.len);
        var longest: f64 = 0;
        for (placed.tiles[0].shapes[0].outline.contours[0].segments) |sg| if (sg == .line) {
            longest = @max(longest, @abs(sg.line[1].x - sg.line[0].x) + @abs(sg.line[1].y - sg.line[0].y));
        };
        len.* = longest;
    }
    try testing.expectApproxEqAbs(@as(f64, 4), lens[0] - lens[1], 1e-6);
}
