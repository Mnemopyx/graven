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
    /// A spacer (a blank): no shapes, left out of output and the bounds.
    spacer: bool = false,
};

pub const PlacedLabel = struct {
    /// The run in a track's flow it sets, if it is one: then `tile` is
    /// null and `slot` is the item's index.
    run: ?struct {
        region: usize,
        item: usize,
        /// The piece of the item's markup it sets (words between breaks,
        /// when a run breaks across segments): its start and length
        /// there. Its render keeps the run's source offsets.
        from: u32 = 0,
        len: u32 = 0,
    } = null,
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
        /// A segment lies past its track's soft area (`row` says which).
        past_soft_area,
        /// A tile reaches back past its row's top into a segment the flow
        /// filled before: that content is not moved.
        tall_item,
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
    /// Its origin on the track's path, u from the region's origin.
    origin: model.Segment = .{},
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
    region: usize,
    natural: f64,
    /// How many segments the flow reached: kept origins past these are no
    /// longer needed (see `Model.trimSegments`).
    segments: usize = 0,
};

pub const Placed = struct {
    arena: std.heap.ArenaAllocator,
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

/// Whether two specs set text alike: their fields, and their members'
/// fields and coverage, compared by value (a spec's slices are rebuilt by
/// each resolve).
/// Whether a render asked for a weight, slant or alphabet it did not get.
fn lacksVariant(diagnostics: []const engine.render.Diagnostic) bool {
    for (diagnostics) |d| switch (d.kind) {
        .no_italic, .no_bold, .no_alphabet => return true,
        else => {},
    };
    return false;
}

fn specEql(a: engine.style.Spec, b: engine.style.Spec) bool {
    var x = a;
    var y = b;
    x.members = &.{};
    y.members = &.{};
    if (!std.mem.eql(u8, std.mem.asBytes(&x), std.mem.asBytes(&y))) return false;
    if (a.members.len != b.members.len) return false;
    for (a.members, b.members) |p, q| {
        var pp = p;
        var qq = q;
        pp.coverage = .fallback;
        qq.coverage = .fallback;
        if (!std.mem.eql(u8, std.mem.asBytes(&pp), std.mem.asBytes(&qq))) return false;
        switch (p.coverage) {
            .fallback => if (q.coverage != .fallback) return false,
            .ranges => |rs| {
                if (q.coverage != .ranges) return false;
                const ts = q.coverage.ranges;
                if (rs.len != ts.len) return false;
                for (rs, ts) |u, v| if (u.first != v.first or u.last != v.last) return false;
            },
        }
    }
    return true;
}

/// Renders labels for one face table, caching each render.
pub const Labels = struct {
    gpa: Allocator,
    faces: []const *engine.Face,
    /// The resolved fonts last given to `syncResolved`, which `sync` then
    /// keeps to; the caller resolves again when the model changes.
    resolved: ?*const fonts.Resolved = null,
    contexts: std.ArrayList(?Ctx) = .empty,
    cache: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,

    const Ctx = struct { spec: engine.style.Spec, ctx: ?engine.style.Context };

    const Key = struct {
        style: StyleId,
        anchor: model.Align,
        /// The hard box relative to the anchor point; null for none.
        box: ?[4]f64,
        markup: []const u8,
        /// Each line's open span, where art over the label closes the rest
        /// (see `engine.label.Options.line_spans`); empty for none.
        spans: []const ?[2]f64 = &.{},
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
        l.gpa.free(k.spans);
        if (e.render) |r| {
            r.deinit();
            l.gpa.destroy(r);
        }
    }

    /// Brings the style contexts up to date with the model, dropping renders
    /// of any style whose spec changed. For a model whose styles name
    /// faces directly (no composed fonts); see `syncResolved`.
    pub fn sync(l: *Labels, m: *const Model) Allocator.Error!void {
        if (l.resolved) |r| return l.syncSpecs(r.faces.items, r.specs.items);
        const specs = try l.gpa.alloc(engine.style.Spec, m.styles.items.len);
        defer l.gpa.free(specs);
        for (m.styles.items, specs) |st, *sp| sp.* = st.spec;
        try l.syncSpecs(l.faces, specs);
    }

    /// As `sync`, with the face table and specs that resolving the model's
    /// composed fonts gave (see `fonts.resolve`). A changed face table
    /// drops every render.
    pub fn syncResolved(l: *Labels, r: *const fonts.Resolved) Allocator.Error!void {
        l.resolved = r;
        try l.syncSpecs(r.faces.items, r.specs.items);
    }

    fn syncSpecs(l: *Labels, faces: []const *engine.Face, specs: []const engine.style.Spec) Allocator.Error!void {
        if (faces.ptr != l.faces.ptr or faces.len != l.faces.len) {
            l.faces = faces;
            for (l.contexts.items) |*c| c.* = null;
            l.clear();
        }
        while (l.contexts.items.len < specs.len) try l.contexts.append(l.gpa, null);
        for (specs, 0..) |spec, i| {
            const cur = &l.contexts.items[i];
            if (cur.*) |c| if (specEql(c.spec, spec)) continue;
            const n = l.faces.len;
            const inTable = struct {
                fn f(v: engine.style.Variants, len: usize) bool {
                    return v.upright < len and (v.italic orelse 0) < len and (v.bold orelse 0) < len and (v.bold_italic orelse 0) < len;
                }
            }.f;
            const main: engine.style.Variants = .{ .upright = spec.upright, .italic = spec.italic, .bold = spec.bold, .bold_italic = spec.bold_italic };
            const usable = inTable(main, n) and for (spec.members) |mb| {
                if (!inTable(mb.variants(), n)) break false;
            } else true;
            const ctx = if (usable) engine.style.Context.init(l.faces, spec) catch null else null;
            cur.* = .{ .spec = spec, .ctx = ctx };
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
                .line_spans = k.spans,
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

    /// Where a row's text baseline sits: its style's capitals centred
    /// across the band, or the band's middle for a track with no style.
    fn baseline(f: Flow, band: Box) f64 {
        var cap: f64 = 0;
        if (f.region.style) |sid| if (sid < f.m.styles.items.len) {
            cap = f.m.styles.items[sid].spec.cap_height;
        };
        return (band.y0 + band.y1 - cap) / 2;
    }

    /// Tile `id`'s pitch box at `start` mm along a segment with band
    /// `band`: from the band's top (a row) or start edge (a column), or, in
    /// a row, set on its baseline when its prototype has one.
    fn tileBox(f: Flow, id: TileId, band: Box, start: f64) Box {
        const t = f.m.tileConst(id);
        const proto = f.m.prototypes.items[t.prototype];
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
    fn leave(f: Flow, a: Allocator, path: *Path, shifts: *std.ArrayList(f64), tall: *std.ArrayList(Tall), issues: *std.ArrayList(Issue), seg: usize, first: usize, stop: usize, has_closed: bool) Allocator.Error!void {
        const free = @max(0, f.length - path.reach.items[seg]);
        const sh: f64 = if (has_closed) 0 else switch (f.region.alignment) {
            .start => 0,
            .centre => free / 2,
            .end => free,
        };
        try shifts.append(a, sh);
        const band = path.boxes.items[seg];
        const tol = 1e-9;
        for (first..stop) |k| {
            if (f.dropped[k] or f.dup[k] or f.segs_of[k] != seg) continue;
            const id = f.items[k].tileOf() orelse continue;
            const b = f.tileBox(id, band, f.spans[k][0] + sh);
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

/// Line art the tracks flow around: its bounds, and for ink its outline
/// flattened to polygons, mm in the panel frame.
const KeepOut = struct {
    box: Box,
    /// Empty to wrap by the bounds.
    polys: []const []const Point,
    clearance: f64,

    fn of(a: Allocator, pa: model.PanelArt) Allocator.Error!KeepOut {
        const b = pa.box();
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
    fn closes(k: KeepOut, a: Allocator, rows: bool, band: Box, out: *std.ArrayList([2]f64)) Allocator.Error!void {
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

/// For a label set from anchor point `at` in hard box `box` (panel frame),
/// each line's open span where line art closes stretches of it, in the
/// label frame: the widest one left (a zero-width one if none is, so the
/// line overflows and says so). Empty when no art reaches the box. Lines
/// are taken one pitch apart down from the first baseline, before the
/// block is fitted in its box.
fn lineSpans(a: Allocator, keepouts: []const KeepOut, box: Box, at: Point, cap: f64, pitch: f64) Allocator.Error![]const ?[2]f64 {
    var any = false;
    for (keepouts) |k| {
        const c = k.clearance;
        if (model.overlaps(.{ .x0 = k.box.x0 - c, .x1 = k.box.x1 + c, .y0 = k.box.y0 - c, .y1 = k.box.y1 + c }, box)) any = true;
    }
    if (!any or !(pitch > 0)) return &.{};
    var spans: std.ArrayList(?[2]f64) = .empty;
    var closed: std.ArrayList([2]f64) = .empty;
    const lead = (pitch - cap) / 2;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const base = at.y - @as(f64, @floatFromInt(i)) * pitch;
        const band: Box = .{ .x0 = box.x0, .x1 = box.x1, .y0 = base - lead, .y1 = base + cap + lead };
        if (band.y1 < box.y0) break;
        closed.clearRetainingCapacity();
        for (keepouts) |k| try k.closes(a, true, band, &closed);
        if (closed.items.len == 0) {
            try spans.append(a, null);
            continue;
        }
        std.mem.sort([2]f64, closed.items, {}, struct {
            fn lt(_: void, x: [2]f64, y: [2]f64) bool {
                return x[0] < y[0];
            }
        }.lt);
        // The widest open span between the closed stretches.
        var best: [2]f64 = .{ 0, 0 };
        var from: f64 = 0;
        for (closed.items) |cl| {
            if (cl[0] - from > best[1] - best[0]) best = .{ from, cl[0] };
            from = @max(from, cl[1]);
        }
        if (box.width() - from > best[1] - best[0]) best = .{ from, box.width() };
        try spans.append(a, .{ box.x0 + best[0] - at.x, box.x0 + best[1] - at.x });
    }
    return spans.items;
}

/// A piece of a run cut from its one-line render: the words between two
/// break opportunities, or (`space`) the space of one.
const Cut = struct {
    render: *const engine.Render,
    after: ?u32,
    before: ?u32,
    space: bool = false,

    /// Its length along the line.
    fn size(c: Cut) f64 {
        const ops = c.render.opportunities;
        if (c.space) return ops[c.before.?].x1 - ops[c.before.?].x0;
        const x0 = if (c.after) |k| ops[k].x1 else c.render.design.x0;
        const x1 = if (c.before) |k| ops[k].x0 else c.render.design.x1;
        return x1 - x0;
    }
};

/// Whether flow piece `index` is the space between two words of a run.
fn isSpace(cuts: []const ?Cut, index: usize) bool {
    return if (cuts[index]) |c| c.space else false;
}

/// The point at `t` on segment `s`.
fn pointOn(s: geom.Segment, t: f64) Point {
    const u = 1 - t;
    return switch (s) {
        .line => |p| .{ .x = u * p[0].x + t * p[1].x, .y = u * p[0].y + t * p[1].y },
        .quad => |p| .{
            .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x,
            .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y,
        },
        .cubic => |p| .{
            .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
            .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
        },
    };
}

/// The most segments one track's flow may reach.
const max_segments = 4096;

/// A track's segments as its flow reaches them: kept origins first, then
/// the path's continuation, each new origin skipping on along the path past
/// places already taken (by earlier segments here, or `avoid`).
const Path = struct {
    region: *const model.TileRegion,
    avoid: []const PlacedTrack,
    origins: std.ArrayList(model.Segment) = .empty,
    boxes: std.ArrayList(Box) = .empty,
    reach: std.ArrayList(f64) = .empty,

    fn ensure(p: *Path, a: Allocator, k: usize) Allocator.Error!void {
        const kept = p.region.segments.items;
        while (p.origins.items.len <= k) {
            const n = p.origins.items.len;
            var o: model.Segment = .{};
            if (n < kept.len) {
                o = kept[n];
            } else if (n > 0) {
                const last = p.origins.items[n - 1];
                const prev = if (n >= 2) p.origins.items[n - 2] else null;
                const dir = model.pathDirection(prev, last);
                o = last.step(dir, 1 + p.region.gap);
                var tries: usize = 0;
                while (tries < 400 and p.blocked(p.region.boxAt(o))) : (tries += 1) o = o.step(dir, 0.25);
            }
            try p.origins.append(a, o);
            try p.boxes.append(a, p.region.boxAt(o));
            try p.reach.append(a, 0);
        }
    }

    fn blocked(p: *const Path, b: Box) bool {
        for (p.avoid) |t| if (model.overlaps(b, t.box)) return true;
        for (p.boxes.items) |o| if (model.overlaps(b, o)) return true;
        return false;
    }
};

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
    for (m.panels.items[panel].regions.items, 0..) |region, ri| {
        // Rows run right and stack down; columns run down and set to the
        // right. An item's size along is its width in a row and its height
        // in a column.
        const rows = region.major == .row;
        const length = region.segmentLength() * region.pitch;
        const tol = 1e-9;
        // The flow as the pass sees it. A run in a row is set once on one
        // line, then cut where it may break (between words, see
        // `engine.Render.opportunities`): a piece per word or stretch of
        // words, with a space piece between (dropped where a wrap leaves it
        // at a segment's start). A formula has no breaks and stays whole.
        // Each piece remembers its item, and its source bytes there.
        var pieces: std.ArrayList(model.Item) = .empty;
        var cuts: std.ArrayList(?Cut) = .empty;
        var item_of: std.ArrayList(usize) = .empty;
        var src_off: std.ArrayList(u32) = .empty;
        var src_len: std.ArrayList(u32) = .empty;
        for (region.items.items, 0..) |item, mi| {
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
            if (run == null or run.?.content.len == 0 or !rows or labels.context(run.?.style) == null) {
                try whole(a, &pieces, &cuts, &item_of, &src_off, &src_len, item, mi);
                continue;
            }
            const full = (try labels.get(.{ .style = run.?.style, .anchor = .start, .box = null, .markup = run.?.content })) orelse {
                try whole(a, &pieces, &cuts, &item_of, &src_off, &src_len, item, mi);
                continue;
            };
            // Breaks at \- would need a hyphen drawn: not taken yet.
            var breaks: std.ArrayList(u32) = .empty;
            for (full.opportunities, 0..) |o, k| if (!o.hyphen) try breaks.append(a, @intCast(k));
            if (breaks.items.len == 0) {
                try whole(a, &pieces, &cuts, &item_of, &src_off, &src_len, item, mi);
                continue;
            }
            const content_len: u32 = @intCast(run.?.content.len);
            var prev: ?u32 = null;
            for (0..breaks.items.len + 1) |k| {
                const next: ?u32 = if (k < breaks.items.len) breaks.items[k] else null;
                const from: u32 = if (prev) |p_| full.opportunities[p_].end else 0;
                const to: u32 = if (next) |n_| full.opportunities[n_].start else content_len;
                try pieces.append(a, .{ .gap = if (k == 0) item.gap else 0, .what = .{ .run = run.? } });
                try cuts.append(a, .{ .render = full, .after = prev, .before = next });
                try item_of.append(a, mi);
                try src_off.append(a, from);
                try src_len.append(a, to - from);
                if (next) |n_| {
                    const o = full.opportunities[n_];
                    try pieces.append(a, .{ .what = .{ .run = run.? } });
                    try cuts.append(a, .{ .render = full, .after = n_, .before = n_, .space = true });
                    try item_of.append(a, mi);
                    try src_off.append(a, o.start);
                    try src_len.append(a, o.end - o.start);
                }
                prev = next;
            }
            // The item's own binding holds after its last piece.
            pieces.items[pieces.items.len - 1].bind = item.bind;
        }
        const items = pieces.items;

        // First, every item's size along, and for a run its render.
        const sizes = try a.alloc(f64, items.len);
        const renders = try a.alloc(?*const engine.Render, items.len);
        for (items, sizes, renders, 0..) |item, *size, *rr, index| {
            rr.* = null;
            size.* = switch (item.what) {
                // In its prototype's unit, so a key keeps its size in a
                // track of another pitch.
                .tile => |id| blk: {
                    const t = m.tileConst(id);
                    const unit = m.prototypes.items[t.prototype].unitIn(region.pitch);
                    break :blk (if (rows) t.w else t.h) * unit;
                },
                .run => |run| blk: {
                    if (cuts.items[index]) |c| break :blk c.size();
                    if (run.content.len == 0) break :blk 0.5 * region.pitch;
                    _ = labels.context(run.style) orelse {
                        try issues.append(a, .{ .kind = .style_error, .region = ri, .item = item_of.items[index] });
                        break :blk 0.5 * region.pitch;
                    };
                    const render = (try labels.get(.{ .style = run.style, .anchor = .start, .box = null, .markup = run.content })) orelse break :blk 0.5 * region.pitch;
                    rr.* = render;
                    const d = render.design;
                    break :blk if (d.isEmpty()) 0 else if (rows) d.x1 - d.x0 else d.y1 - d.y0;
                },
                .hard_break => 0,
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
        var path: Path = .{ .region = &region, .avoid = tracks.items };
        try path.ensure(a, 0);
        // Each segment's alignment shift, set when the flow leaves it.
        var shifts: std.ArrayList(f64) = .empty;
        // Tiles placed so far that reach past their segment's band, with
        // the segment that placed them; and the stretches they close in
        // the segment being filled.
        var tall: std.ArrayList(Tall) = .empty;
        var closed: std.ArrayList([2]f64) = .empty;
        var first_in_seg: usize = 0;
        var seg: usize = 0;
        var pos: f64 = 0;
        var in_seg: usize = 0;
        var para: f64 = 0;
        var natural: f64 = 0;
        const flow: Flow = .{ .m = m, .region = &region, .rows = rows, .length = length, .ri = ri, .items = items, .segs_of = segs_of, .spans = spans, .dropped = dropped, .dup = dup, .keepouts = keepouts.items };
        // The first segment too: line art may close stretches of it.
        try flow.enter(a, &path, 0, tall.items, &closed);
        for (items, 0..) |item, index| {
            if (item.what == .hard_break) {
                segs_of[index] = seg;
                spans[index] = .{ pos, pos };
                natural = @max(natural, para);
                para = 0;
                if (seg + 1 < max_segments) {
                    try flow.leave(a, &path, &shifts, &tall, &issues, seg, first_in_seg, index, closed.items.len > 0);
                    seg += 1;
                    first_in_seg = index + 1;
                    try flow.enter(a, &path, seg, tall.items, &closed);
                    pos = 0;
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
            if (!in_group) {
                var k = index;
                while (k + 1 < items.len and m.bound(items, k)) : (k += 1) need += items[k + 1].gap * region.pitch + sizes[k + 1];
            }
            // It does not fit: on to the next segment, made as needed, if
            // this one holds something already.
            if (!in_group and start + need > length + tol and in_seg > 0 and seg + 1 < max_segments) {
                try flow.leave(a, &path, &shifts, &tall, &issues, seg, first_in_seg, index, closed.items.len > 0);
                seg += 1;
                first_in_seg = index;
                try flow.enter(a, &path, seg, tall.items, &closed);
                pos = 0;
                in_seg = 0;
                start = Flow.clear(closed.items, gap, size);
                // Landing at the start after a soft break, a tile whose
                // prototype says so, or a space between words, is dropped.
                const drops = if (item.tileOf()) |id| m.prototypes.items[m.tileConst(id).prototype].at_soft_break == .drop else isSpace(cuts.items, index);
                if (drops) {
                    para -= gap + size;
                    segs_of[index] = seg;
                    spans[index] = .{ 0, 0 };
                    dropped[index] = true;
                    continue;
                }
            }
            const end = start + size;
            pos = @max(pos, end);
            in_seg += 1;
            path.reach.items[seg] = @max(path.reach.items[seg], end);
            segs_of[index] = seg;
            spans[index] = .{ start, end };
        }
        try flow.leave(a, &path, &shifts, &tall, &issues, seg, first_in_seg, items.len, closed.items.len > 0);

        // Last, each item where it landed.
        for (items, 0..) |item, index| {
            const sg = segs_of[index];
            const sh = if (dropped[index] or dup[index]) 0 else shifts.items[sg];
            const start = spans[index][0] + sh;
            const end = spans[index][1] + sh;
            try placed_items.append(a, .{ .region = ri, .index = item_of.items[index], .segment = sg, .span = .{ start, end } });
            if (dropped[index] or dup[index]) continue;
            const band = path.boxes.items[sg];
            switch (item.what) {
                .tile => |pid| {
                    const t = m.tileConst(pid);
                    const unit = m.prototypes.items[t.prototype].unitIn(region.pitch);
                    const pitch_box = flow.tileBox(pid, band, start);
                    const proto = &m.prototypes.items[t.prototype];
                    const body = proto.body_inset.inset(pitch_box);
                    // A spacer is drawn by nothing and bounds nothing.
                    if (proto.spacer) {
                        try tiles.append(a, .{ .id = pid, .region = ri, .row = sg, .pitch_box = pitch_box, .body = pitch_box, .face = pitch_box, .shapes = &.{}, .spacer = true });
                        continue;
                    }
                    const shapes = if (proto.art) |pa| art.stretch(a, pa, unit, pitch_box) catch |err| switch (err) {
                        error.CurveCrossesCut => blk: {
                            try issues.append(a, .{ .kind = .tile_art, .tile = pid, .region = ri, .row = sg });
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
                    if (!proto.allows(t.w, t.h)) try issues.append(a, .{ .kind = .tile_size, .tile = pid, .region = ri, .row = sg });
                    bounds = bounds.join(pitch_box);
                },
                .run => |run| {
                    const render = if (cuts.items[index]) |c| blk: {
                        if (c.space) continue;
                        const piece = try a.create(engine.Render);
                        piece.* = try c.render.piece(a, c.after, c.before);
                        break :blk piece;
                    } else renders[index] orelse continue;
                    if (render.syntax.len > 0) try issues.append(a, .{ .kind = .markup_error, .region = ri, .row = sg, .item = item_of.items[index], .syntax = render.syntax[0] });
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
                        .run = .{ .region = ri, .item = item_of.items[index], .from = src_off.items[index], .len = src_len.items[index] },
                        .tile = null,
                        .slot = item_of.items[index],
                        .box = box,
                        .origin = origin,
                        .style = run.style,
                        .render = render,
                    });
                    for (render.diagnostics) |dg| if (dg.kind == .missing_glyph) {
                        try issues.append(a, .{ .kind = .missing_glyph, .region = ri, .row = sg, .item = item_of.items[index] });
                        break;
                    };
                    if (lacksVariant(render.diagnostics)) try issues.append(a, .{ .kind = .variant_missing, .region = ri, .row = sg, .item = item_of.items[index] });
                },
                .hard_break => {},
            }
        }
        natural = @max(natural, para);
        try flows.append(a, .{ .region = ri, .natural = natural / region.pitch, .segments = path.origins.items.len });
        for (path.reach.items, 0..) |r_, t| if (r_ > length + tol) {
            try issues.append(a, .{ .kind = .row_overflow, .region = ri, .row = t, .amount = r_ - length });
        };
        // Its segments: past the soft area each is flagged; past the panel,
        // the region is (to be fitted, or the panel resized).
        const soft = region.softArea();
        var all: Box = .empty;
        for (path.origins.items, path.boxes.items, 0..) |o, b, t| {
            try tracks.append(a, .{ .region = ri, .track = t, .major = region.major, .box = b, .origin = o });
            all = all.join(b);
            if (!model.within(b, soft)) try issues.append(a, .{ .kind = .past_soft_area, .region = ri, .row = t });
        }
        // The canvas has no outline to keep to.
        const past = @max(@max(outline.x0 - all.x0, all.x1 - outline.x1), @max(outline.y0 - all.y0, all.y1 - outline.y1));
        if (past > 1e-9 and !m.panels.items[panel].unbounded) try issues.append(a, .{ .kind = .region_outside, .region = ri, .amount = past });
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
            // Art over the slot closes stretches of its lines: each line is
            // given the widest span left open.
            const spans = try lineSpans(a, label_keepouts.items, box, at, cap, ctx.linePitch() catch 0);
            const render = (try labels.get(.{
                .style = slot.style,
                .anchor = slot.place.h,
                .box = .{ snap(box.x0 - at.x), snap(box.y0 - at.y), snap(box.x1 - at.x), snap(box.y1 - at.y) },
                .markup = slot.content,
                .spans = spans,
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
            if (lacksVariant(render.diagnostics)) try issues.append(a, .{ .kind = .variant_missing, .tile = pt.id, .slot = si });
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
        if (lacksVariant(render.diagnostics)) try issues.append(a, .{ .kind = .variant_missing, .label = li });
    }

    // Labels not inside a tile (on the panel, or runs in a track) reach
    // past the tiles' boxes: the bounds hold their ink too, so a canvas
    // with only a label still has extents.
    for (placed_labels.items) |l| {
        if (l.tile != null) continue;
        const ink = l.render.ink;
        if (ink.isEmpty()) continue;
        bounds = bounds.join(.{ .x0 = l.origin.x + ink.x0, .y0 = l.origin.y + ink.y0, .x1 = l.origin.x + ink.x1, .y1 = l.origin.y + ink.y1 });
    }

    const this = m.panels.items[panel];
    const has_cutout = for (this.art.items) |pa| {
        if (pa.cutout) break true;
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

    return .{
        .arena = arena,
        .edge = edge,
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
    _ = try m.addSegment(p, r, 0);
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
    // The sixth goes on to a third column, past the soft area.
    try testing.expectEqual(2, s.items[5].segment);
    var flagged = false;
    for (s.issues) |i| flagged = flagged or i.kind == .past_soft_area;
    try testing.expect(flagged);
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
    _ = try m.insertBlank(p, r, 1, 0.5);
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // 4.5 u in a 4 u row: the last key wraps on to a second row.
    try testing.expectEqual(2, s.tracks.len);
    try testing.expectEqual(5, s.items.len);
    try testing.expectApproxEqAbs(@as(f64, 10), s.items[1].span[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 15), s.items[1].span[1], 1e-9);
    // The blank is a spacer tile; the second key starts after it.
    try testing.expect(s.tiles[1].spacer);
    try testing.expectEqual(0, s.tiles[1].shapes.len);
    try testing.expectApproxEqAbs(@as(f64, 15), s.tiles[2].pitch_box.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90), s.tracks[0].box.y0, 1e-9);
}

/// Moves segment `seg` of region `r` as the GUI does: with the origins
/// and the other bands from a fresh solve.
fn moveIn(m: *Model, labels: *Labels, p: usize, r: usize, seg: usize, along: f64, across: f64) !void {
    var s = try solve(testing.allocator, m, p, labels);
    defer s.deinit();
    var obuf: [64]model.Segment = undefined;
    var abuf: [64]Box = undefined;
    const kept = m.panels.items[p].regions.items[r].segments.items.len;
    try m.moveSegment(p, r, seg, s.origins(r, &obuf), along, across, s.obstacles(r, seg, kept, &abuf));
}

test "segments follow a path: moving one bends it, the next ones follow, and none may overlap" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 10, .y = 100 }, .prototype = key, .count = 4, .length = 4, .pitch = 10 });
    // Two tiles a row, each row ended by a hard break: three rows, made as
    // the flow reaches them, straight down.
    for (0..3) |t| {
        for (0..2) |_| _ = try m.insertTile(p, r, m.panels.items[p].regions.items[r].items.items.len, key, 1);
        if (t < 2) _ = try m.insertBreak(p, r, m.panels.items[p].regions.items[r].items.items.len);
    }
    try testing.expectEqual(1, m.panels.items[p].regions.items[r].segments.items.len);
    var labels: Labels = .init(gpa, &.{});
    defer labels.deinit();
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectEqual(3, s.tracks.len);
        try testing.expectApproxEqAbs(@as(f64, 80), s.tracks[2].box.y1, 1e-9);
        try testing.expectEqual(3, s.flows[0].segments);
    }
    // Row 2 down 0.5 u: the path bends there, and row 3 follows it.
    try moveIn(&m, &labels, p, r, 1, 0, 0.5);
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectApproxEqAbs(@as(f64, 85), s.tracks[1].box.y1, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 75), s.tracks[2].box.y1, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 75), s.tiles[4].pitch_box.y1, 1e-9);
        try testing.expectEqual(0, s.issues.len);
    }
    // Row 3 0.5 u right: the path's last piece now leans right, so a
    // fourth row goes on that way, one row thickness along it.
    try moveIn(&m, &labels, p, r, 2, 0.5, 0);
    _ = try m.insertBreak(p, r, m.panels.items[p].regions.items[r].items.items.len);
    _ = try m.insertTile(p, r, m.panels.items[p].regions.items[r].items.items.len, key, 1);
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectEqual(4, s.tracks.len);
        // On the path's continuation: at least one thickness along it, and
        // on past where it would overlap row 3 (a slant packs closer).
        const d = model.pathDirection(s.tracks[1].origin, s.tracks[2].origin);
        const o3 = s.tracks[2].origin;
        const o4 = s.tracks[3].origin;
        const t = (o4.along - o3.along) / d[0];
        try testing.expect(t >= 1);
        try testing.expectApproxEqAbs(o3.across + d[1] * t, o4.across, 1e-9);
        try testing.expect(!model.overlaps(s.tracks[2].box, s.tracks[3].box));
    }
    // Onto row 1: refused.
    try testing.expectError(error.NoRoom, moveIn(&m, &labels, p, r, 1, 0, -1));
    // Content removed from the end: the segments it no longer reaches are
    // not drawn, but those moved by hand keep their places.
    const items = &m.panels.items[p].regions.items[r].items;
    const removed = try gpa.dupe(model.Item, items.items[2..]);
    defer gpa.free(removed);
    while (items.items.len > 2) try m.removeAt(p, r, items.items.len - 1);
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectEqual(1, s.tracks.len);
        m.trimSegments(p, r, s.flows[0].segments);
    }
    // Rows 2 and 3 were moved: kept, with row 1 before them.
    const kept = m.panels.items[p].regions.items[r].segments.items;
    try testing.expectEqual(3, kept.len);
    try testing.expect(kept[2].moved);
    // Content back: row 3 is where it was moved to.
    for (removed) |it| try m.place(p, r, null, it);
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expectApproxEqAbs(kept[2].along, s.tracks[2].origin.along, 1e-9);
    try testing.expectApproxEqAbs(kept[2].across, s.tracks[2].origin.across, 1e-9);
    // Unmoved segments past the end go.
    m.trimSegments(p, r, 1);
    try testing.expectEqual(3, m.panels.items[p].regions.items[r].segments.items.len);
}

test "segments past the soft area are flagged, and past the panel the region is" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 50, 25);
    const key = try m.addPrototype(.{ .name = "key" });
    // A soft area two rows thick; a third paragraph comes past it, and
    // past the panel's bottom.
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 25 }, .prototype = key, .count = 2, .length = 2, .pitch = 10 });
    for (0..3) |t| {
        _ = try m.insertTile(p, r, m.panels.items[p].regions.items[r].items.items.len, key, 1);
        if (t < 2) _ = try m.insertBreak(p, r, m.panels.items[p].regions.items[r].items.items.len);
    }
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    var soft: ?usize = null;
    var outside = false;
    for (s.issues) |i| {
        if (i.kind == .past_soft_area) soft = i.row;
        if (i.kind == .region_outside) outside = true;
    }
    try testing.expectEqual(2, soft.?);
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
    _ = try m.insertBreak(p, r, 2);
    _ = try m.insertTile(p, r, 3, key, 1);
    _ = try m.insertBlank(p, r, 4, 0.5);
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
    _ = try m.insertBreak(p, r, 4);
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
    _ = try m.insertBreak(p, r, 3);
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
    // One more paragraph than the soft area holds: a fourth row, flagged.
    _ = try m.insertBreak(p, r, 8);
    _ = try m.insertTile(p, r, 9, key, 1);
    var t = try solve(testing.allocator, &m, p, &labels);
    defer t.deinit();
    try testing.expectEqual(1, t.issues.len);
    try testing.expectEqual(.past_soft_area, t.issues[0].kind);
    try testing.expectEqual(3, t.issues[0].row.?);
}

test "a tile keeps its prototype's unit in a track of another pitch" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 3 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 19.05, .expand = .{ .horizontal = true } });
    // Rows one 5 mm line thick: a 1.5 u key is still 28.575 mm wide, and
    // the next item starts after it, past a 0.25 u gap in the track's unit.
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 2, .length = 40, .pitch = 5 });
    const t = try m.insertTile(p, r, 0, key, 1.5);
    _ = try m.insertBlank(p, r, 1, 1);
    m.panels.items[p].regions.items[r].items.items[1].gap = 0.25;
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    const box = s.findTile(t).?.pitch_box;
    try testing.expectApproxEqAbs(@as(f64, 28.575), box.width(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 19.05), box.height(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 28.575 + 1.25), s.items[1].span[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 28.575 + 1.25 + 5), s.items[1].span[1], 1e-9);
}

test "one track holds keycaps, another prototype's keys and blanks, all as tiles; a dropped space" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key", .unit = 10, .expand = .{ .horizontal = true } });
    const pad = try m.addPrototype(.{ .name = "pad", .unit = 10, .body_inset = .all(1) });
    // A space between words: dropped when it lands at a row's start.
    const space = try m.addPrototype(.{ .name = "space", .spacer = true, .at_soft_break = .drop, .expand = .{ .horizontal = true } });
    const r = try m.addTracks(p, .{ .name = "mixed", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 2, .length = 4, .pitch = 10 });
    _ = try m.insertTile(p, r, 0, key, 1.5);
    _ = try m.insertBlank(p, r, 1, 0.5);
    _ = try m.insertTile(p, r, 2, pad, 1);
    // Fills the first row to 4 u: the space lands at the second's start.
    _ = try m.insertTile(p, r, 3, key, 1);
    _ = try m.insertTile(p, r, 4, space, 1);
    _ = try m.insertTile(p, r, 5, pad, 1);
    // A blank after a soft break is kept, unlike the space.
    _ = try m.insertTile(p, r, 6, key, 2.5);
    _ = try m.insertBlank(p, r, 7, 0.5);
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectEqual(0, s.issues.len);
    // Every item is a tile: keys, pads, a blank and a space.
    for (m.panels.items[p].regions.items[r].items.items) |it| try testing.expect(it.tileOf() != null);
    try testing.expectApproxEqAbs(@as(f64, 15), s.items[1].span[0], 1e-9);
    try testing.expectEqual(1, s.items[4].segment);
    try testing.expectApproxEqAbs(@as(f64, 0), s.items[4].span[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), s.items[5].span[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), s.items[6].span[0], 1e-9);
    // Three keys, two pads and two blanks placed; the dropped space (T4)
    // is not.
    try testing.expectEqual(7, s.tiles.len);
    try testing.expectEqual(null, s.findTile(m.findTile("T4").?));
}

/// Appends a 1 u key made from `key` to region `r`'s flow.
fn appendKey(m: *Model, p: usize, r: usize, key: model.PrototypeId) !TileId {
    return m.insertTile(p, r, m.panels.items[p].regions.items[r].items.items.len, key, 1);
}

test "a group breaks as one: the arrow cluster stays together across a reflow" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 2, .length = 6, .pitch = 10 });
    for (0..4) |_| _ = try appendKey(&m, p, r, key);
    // Left, Down, Right: bound into one group.
    for (0..3) |_| _ = try appendKey(&m, p, r, key);
    try m.setBind(p, r, 4, true);
    try m.setBind(p, r, 5, true);
    try testing.expectError(error.NoSuchItem, m.setBind(p, r, 6, true));
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    {
        // 7 u in 6 u rows: unbound, only Right would wrap; bound, the three go.
        var s = try solve(testing.allocator, &m, p, &labels);
        defer s.deinit();
        for (s.items[0..4]) |it| try testing.expectEqual(0, it.segment);
        for (s.items[4..7]) |it| try testing.expectEqual(1, it.segment);
        try testing.expectApproxEqAbs(@as(f64, 0), s.items[4].span[0], 1e-9);
    }
    // Two more keys at the start: the first row fills, and the cluster
    // still moves as one.
    _ = try m.insertTile(p, r, 0, key, 1);
    _ = try m.insertTile(p, r, 0, key, 1);
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    for (s.items[0..6]) |it| try testing.expectEqual(0, it.segment);
    for (s.items[6..9]) |it| try testing.expectEqual(1, it.segment);
    // Parted again, Left fits nowhere better: it wraps alone with the rest.
    try m.setBind(p, r, 6, false);
    var t = try solve(testing.allocator, &m, p, &labels);
    defer t.deinit();
    try testing.expectEqual(1, t.items[6].segment);
    try testing.expectEqual(0, t.issues.len);
}

test "a centred track centres every segment; an end-aligned one sets it back from the end" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 2, .length = 6, .pitch = 10 });
    for (0..2) |_| _ = try appendKey(&m, p, r, key);
    _ = try m.insertBreak(p, r, 2);
    for (0..4) |_| _ = try appendKey(&m, p, r, key);
    try m.setTrackFlow(p, r, .centre, 0, 0);
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    {
        var s = try solve(testing.allocator, &m, p, &labels);
        defer s.deinit();
        try testing.expectApproxEqAbs(@as(f64, 20), s.tiles[0].pitch_box.x0, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 10), s.tiles[2].pitch_box.x0, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 20), s.items[0].span[0], 1e-9);
    }
    try m.setTrackFlow(p, r, .end, 0, 0);
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    try testing.expectApproxEqAbs(@as(f64, 60), s.tiles[1].pitch_box.x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 60), s.tiles[5].pitch_box.x1, 1e-9);
    try testing.expectError(error.BadSize, m.setTrackFlow(p, r, .start, -1, 0));
}

test "with an indent, each hard break brings a blank, so new paragraphs start indented" {
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 2, .length = 6, .pitch = 10 });
    try m.setTrackFlow(p, r, .start, 0.5, 0);
    _ = try appendKey(&m, p, r, key);
    const items = &m.panels.items[p].regions.items[r].items;
    try testing.expectEqual(2, try m.insertBreak(p, r, items.items.len));
    _ = try appendKey(&m, p, r, key);
    var labels: Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var s = try solve(testing.allocator, &m, p, &labels);
    defer s.deinit();
    // The blank is an ordinary item, a spacer of the indent's length.
    try testing.expect(m.prototypes.items[m.tileConst(items.items[2].tileOf().?).prototype].spacer);
    try testing.expectApproxEqAbs(@as(f64, 5), s.items[3].span[0], 1e-9);
    try testing.expectEqual(1, s.items[3].segment);
}

test "a drop cap sits on its word's baseline, binds to the word, and pushes the next row's content aside" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 4 });
    // A letter tile 1 u wide and 2 u (rows) tall, its baseline 1.5 u up:
    // set on the first row's baseline, its lower part reaches into the
    // second row.
    const cap = try m.addPrototype(.{ .name = "initial", .letter = true, .baseline = 1.5, .expand = .{ .vertical = true } });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 3, .length = 4, .pitch = 10 });
    // "H" + "ADD", then words that wrap into the next row.
    const initial = try m.insertTile(p, r, 0, cap, 1);
    try m.setTileSize(initial, 1, 2);
    try m.insertRun(p, r, 1, .{ .style = body, .content = "ADD" });
    for (0..3) |_| try m.insertRun(p, r, m.panels.items[p].regions.items[r].items.items.len, .{ .style = body, .content = "HOD" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    // Bound to its word, it never stands alone at a row's end.
    try testing.expect(m.bound(m.panels.items[p].regions.items[r].items.items, 0));
    try testing.expect(!m.bound(m.panels.items[p].regions.items[r].items.items, 1));
    const box = s.findTile(initial).?.pitch_box;
    // The row's baseline: its 4 mm capitals centred in 90..100, at 93.
    try testing.expectApproxEqAbs(@as(f64, 93 - 15), box.y0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 93 + 5), box.y1, 1e-9);
    // In the second row, content starts after the cap's 10 mm.
    var second: ?f64 = null;
    for (s.items) |it| if (it.segment == 1) {
        second = it.span[0];
        break;
    };
    try testing.expectApproxEqAbs(@as(f64, 10), second.?, 1e-9);
    for (s.issues) |i| try testing.expect(i.kind != .tall_item);
}

test "line art over half a track: its tiles flow around the art's outline, and reflow when it moves" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 120);
    const key = try m.addPrototype(.{ .name = "key" });
    // Four 10 mm rows, 100 mm long, from y = 100 down to 60.
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 0, .y = 100 }, .prototype = key, .count = 4, .length = 10, .pitch = 10 });
    for (0..24) |_| _ = try appendKey(&m, p, r, key);
    // A 40 mm circle centred at (50, 80), over the middle of all four rows.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const disc = try art.ellipse(arena.allocator(), "disc", 40, 40, .{ .fill = .{ .solid = .{ .r = 0, .g = 0, .b = 0 } } });
    const ai = try m.addArt(p, .{ .name = "disc", .at = .{ .x = 30, .y = 60 }, .shapes = disc, .clearance = 1 });
    var labels: Labels = .init(gpa, &.{});
    defer labels.deinit();

    // No key's pitch box comes within the circle (plus most of the
    // clearance; the outline is flattened and sampled).
    const clearOf = struct {
        fn f(s: *const Placed, cx: f64, cy: f64, rr: f64) !void {
            for (s.tiles) |t| {
                const b = t.pitch_box;
                const nx = std.math.clamp(cx, b.x0, b.x1);
                const ny = std.math.clamp(cy, b.y0, b.y1);
                try testing.expect(@sqrt((nx - cx) * (nx - cx) + (ny - cy) * (ny - cy)) >= rr);
            }
        }
    }.f;
    var ink_start: f64 = 0;
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try clearOf(&s, 50, 80, 20.5);
        try testing.expectEqual(1, s.art.len);
        // Row 1: three keys, then the rest after the circle.
        try testing.expectApproxEqAbs(@as(f64, 20), s.tiles[2].pitch_box.x0, 1e-9);
        ink_start = s.tiles[3].pitch_box.x0;
        try testing.expect(ink_start > 60 and ink_start < 70);
    }
    // By its bounds instead: the whole box, grown, is closed, 29..71 mm,
    // so even the third key (20..30) goes on past it.
    try m.setArtWrap(p, ai, .bounds, 1);
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectApproxEqAbs(@as(f64, 71), s.tiles[2].pitch_box.x0, 1e-9);
        try testing.expect(s.tiles[3].pitch_box.x0 > ink_start);
    }
    // Not wrapping: the keys run straight under it.
    try m.setArtWrap(p, ai, .none, 1);
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectApproxEqAbs(@as(f64, 30), s.tiles[3].pitch_box.x0, 1e-9);
    }
    // Moved right by ink again: the flow follows it.
    try m.setArtWrap(p, ai, .ink, 1);
    try m.moveArt(p, ai, .{ .x = 50, .y = 60 });
    var s = try solve(gpa, &m, p, &labels);
    defer s.deinit();
    try clearOf(&s, 70, 80, 20.5);
    try testing.expectApproxEqAbs(@as(f64, 40), s.tiles[4].pitch_box.x0, 1e-9);
    try testing.expectError(error.BadSize, m.setArtWrap(p, ai, .ink, -1));
}

test "a label wraps around art placed over its box" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("legend", .{ .upright = 0, .cap_height = 8 });
    const p = try m.addPanel("board", 100, 100);
    const key = try m.addPrototype(.{ .name = "key", .unit = 40, .slots = &.{.{ .name = "top", .style = style, .place = .{ .inset = .all(1) } }} });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 10, .y = 90 }, .prototype = key, .count = 1, .length = 1, .pitch = 40 });
    const t = try m.insertTile(p, r, 0, key, 1);
    // "HH HH" is about 20 mm of ink: one line on the 38 mm face.
    try m.setContent(t, "top", "HH HH");
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    {
        var s = try solve(gpa, &m, p, &labels);
        defer s.deinit();
        try testing.expectEqual(@as(u16, 1), s.labels[0].render.lines);
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
    const l = s.labels[0];
    try testing.expectEqual(@as(u16, 2), l.render.lines);
    // Its ink stays left of the disc.
    try testing.expect(l.origin.x + l.render.ink.x1 <= 30 + 1e-6);
}

test "a run of text breaks between its words; a space a wrap leaves at a row's start is dropped" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 4 });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 3, .length = 3, .pitch = 10 });
    // Three words in one run; 30 mm rows hold two.
    try m.insertRun(p, r, 0, .{ .style = body, .content = "HOD ADD HOD" });
    // An equation stays whole, spaces and all.
    try m.insertRun(p, r, 1, .{ .style = body, .content = "A = \\frac{H}{D}" });
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
    const regular = try engine.Face.init(gpa, testdata.truetype, 0);
    defer regular.deinit();
    const bold = try engine.Face.init(gpa, testdata.cff, 0);
    defer bold.deinit();
    const faces = [_]*engine.Face{ regular, bold };
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .bold = 1, .cap_height = 4 });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 3, .length = 3, .pitch = 10 });
    const src = "HOD \\textbf{ADD HOD} HOD";
    try m.insertRun(p, r, 0, .{ .style = body, .content = src });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
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
    try testing.expectEqual(@as(?engine.render.FaceId, 0), words[0].render.elements[0].face);
    try testing.expectEqual(@as(?engine.render.FaceId, 1), words[1].render.elements[0].face);
    try testing.expectEqual(@as(?engine.render.FaceId, 1), words[2].render.elements[0].face);
    try testing.expectEqual(@as(?engine.render.FaceId, 0), words[3].render.elements[0].face);
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

test "a label on a canvas, with no sheet or panel, solves and exports" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    const style = try m.addStyle("Label", .{ .upright = 0, .cap_height = 3 });
    // Far from the origin, below and left of it: the canvas has no edge.
    _ = try m.addLabel(c, .{ .at = .{ .x = -40, .y = -25 }, .style = style, .content = "HOD" });
    var labels: Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try solve(gpa, &m, c, &labels);
    defer s.deinit();
    try testing.expectEqual(0, s.issues.len);
    try testing.expectEqual(1, s.labels.len);
    try testing.expect(!s.bounds.isEmpty());
    try testing.expect(s.bounds.x0 >= -40 - 1e-9 and s.bounds.y0 < -24);
    const intrusions = try @import("drc.zig").marginIntrusions(gpa, &m, &.{s});
    defer gpa.free(intrusions);
    try testing.expectEqual(0, intrusions.len);
    const svg = try @import("output.zig").panelSvg(gpa, &s, &faces, .{});
    defer gpa.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}

test "a panel made from a rounded rectangle exports its outline with the cutouts as holes" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
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
    const style = try m.addStyle("Label", .{ .upright = 0, .cap_height = 3 });
    _ = try m.addLabel(c, .{ .at = .{ .x = 30, .y = 25 }, .style = style, .content = "HOD" });
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
