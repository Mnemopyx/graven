//! The panel model: inputs only. Positions, boxes and rendered labels come
//! from `place.solve`, so the model stays the single source of truth.
//!
//! A panel holds regions, each a track: one flow of items (tiles, blanks,
//! runs of text or equations, hard breaks) poured through a list of
//! segments (rows or columns) at a pitch. A tile spanning segments is
//! listed again where it crosses each later one; its first entry places it. Each tile
//! is an instance of a tile prototype, which sets what tiles of its kind
//! share: the body and the face (the labelling surface) as insets, and the
//! named slots on the face where labels go. A tile holds only what is its
//! own: its size, and per slot its label and any overrides.
//!
//! Lengths are mm; tile sizes and gaps in a tile region are in pitch units
//! (u), so a 1.25u tile at 19.05 mm pitch is 23.8125 mm. Frames are y up.
//! Every change goes through an action function here, so the GUI, the CLI
//! and scripts make the same edits.

const std = @import("std");
const engine = @import("graven_engine");

const Allocator = std.mem.Allocator;
const geom = engine.geom;
const art_ = @import("art.zig");

pub const TileId = enum(u32) { _ };

pub const PrototypeId = u16;

/// Whether boxes `a` and `b` share any area (touching edges do not).
pub fn overlaps(a: geom.Box, b: geom.Box) bool {
    const tol = 1e-9;
    return a.x0 < b.x1 - tol and b.x0 < a.x1 - tol and a.y0 < b.y1 - tol and b.y0 < a.y1 - tol;
}

/// Whether box `a` lies inside box `b`, to within rounding.
pub fn within(a: geom.Box, b: geom.Box) bool {
    const tol = 1e-9;
    return a.x0 >= b.x0 - tol and a.y0 >= b.y0 - tol and a.x1 <= b.x1 + tol and a.y1 <= b.y1 + tol;
}
pub const StyleId = u16;

pub const Sides = struct {
    left: f64 = 0,
    right: f64 = 0,
    top: f64 = 0,
    bottom: f64 = 0,

    pub fn all(v: f64) Sides {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }

    pub fn inset(s: Sides, b: geom.Box) geom.Box {
        return .{ .x0 = b.x0 + s.left, .y0 = b.y0 + s.bottom, .x1 = b.x1 - s.right, .y1 = b.y1 - s.top };
    }
};

pub const Align = enum { start, centre, end };

/// Where a slot's label sits on the tile's face.
pub const SlotPlace = struct {
    /// The slot's box: the face less this inset, mm.
    inset: Sides = .{},
    /// Horizontal: start edge, centre, end edge. Vertical: top, centre,
    /// bottom (start is top).
    h: Align = .start,
    v: Align = .start,
};

/// A slot every tile of a prototype has: where its label goes on the face,
/// and the style it is set in unless a tile says otherwise.
pub const SlotPrototype = struct {
    name: []const u8,
    place: SlotPlace = .{},
    style: StyleId = 0,
};

/// A tile's own part of one of its prototype's slots, matched by name: its
/// label, and overrides of the prototype's style and place. Kept by name, so
/// a tile switched to another prototype and back keeps its labels.
pub const SlotFill = struct {
    slot: []const u8,
    /// Label markup; empty for an empty slot.
    content: []const u8 = "",
    style: ?StyleId = null,
    place: ?SlotPlace = null,
};

/// A slot as a tile has it: its prototype's slot with the tile's label and
/// overrides applied.
pub const Slot = struct {
    name: []const u8,
    place: SlotPlace,
    style: StyleId,
    content: []const u8,
};

/// A slot by tile and index into its prototype's slots.
pub const SlotRef = struct { tile: TileId, slot: usize };

/// Which ways tiles of a prototype may grow from 1u × 1u: wider along their
/// track, taller across tracks (spanning them), both or neither.
pub const Expand = struct {
    horizontal: bool = true,
    vertical: bool = true,
};

/// A kind of tile (a keyboard key, a calculator key): what every tile made
/// from it shares. Tiles refer to their prototype, never copy it, so a
/// change to it changes them all.
pub const TilePrototype = struct {
    name: []const u8,
    /// A tile's body: its pitch box less this inset, mm.
    body_inset: Sides = .{},
    /// Its labelling face: the body less this inset, mm.
    face_inset: Sides = .{},
    /// The slots on the face, in order.
    slots: []const SlotPrototype = &.{},
    /// Which ways its tiles may grow from 1u × 1u.
    expand: Expand = .{},
    /// The widths and heights its tiles may take where they may grow, u;
    /// empty allows any.
    widths: []const f64 = &.{},
    heights: []const f64 = &.{},
    /// How its tiles look, drawn for 1u × 1u and stretched; null for a flat
    /// body and face drawn from the insets.
    art: ?art_.Art = null,

    /// The size of tiles along `major`'s tracks (`.along`) or across them:
    /// widths for rows, heights for columns, and the reverse across.
    fn sizesFor(p: TilePrototype, major: Major, axis: Axis) struct { grows: bool, sizes: []const f64 } {
        const horizontal = (major == .row) == (axis == .along);
        return if (horizontal) .{ .grows = p.expand.horizontal, .sizes = p.widths } else .{ .grows = p.expand.vertical, .sizes = p.heights };
    }

    /// The smallest size its tiles take along or across `major`'s tracks, u.
    pub fn smallest(p: TilePrototype, major: Major, axis: Axis) f64 {
        const s = p.sizesFor(major, axis);
        if (!s.grows or s.sizes.len == 0) return 1;
        return std.mem.min(f64, s.sizes);
    }

    /// The finest step between the sizes its tiles take along or across
    /// `major`'s tracks, u: the largest step every allowed size is a whole
    /// multiple of (to 0.01 u). 1 where they do not grow; 0.25 where any
    /// size is allowed.
    pub fn step(p: TilePrototype, major: Major, axis: Axis) f64 {
        const s = p.sizesFor(major, axis);
        if (!s.grows) return 1;
        if (s.sizes.len == 0) return 0.25;
        var g: u64 = 0;
        for (s.sizes) |v| g = std.math.gcd(g, @as(u64, @intFromFloat(@round(v * 100))));
        return if (g == 0) 1 else @as(f64, @floatFromInt(g)) / 100;
    }

    /// Whether a tile `w` × `h` u keeps to the prototype's sizing rules. A
    /// tile that does not is flagged, not refused.
    pub fn allows(p: TilePrototype, w: f64, h: f64) bool {
        return fits(w, p.expand.horizontal, p.widths) and fits(h, p.expand.vertical, p.heights);
    }

    fn fits(size: f64, grows: bool, sizes: []const f64) bool {
        const tol = 1e-9;
        if (!grows) return @abs(size - 1) <= tol;
        if (sizes.len == 0) return true;
        for (sizes) |s| if (@abs(size - s) <= tol) return true;
        return false;
    }
};

pub const Tile = struct {
    /// The visible name, unique within its panel (K23, ENTER).
    designator: []const u8,
    /// Width and height in pitch units of its region.
    w: f64 = 1,
    h: f64 = 1,
    /// The kind of tile it is.
    prototype: PrototypeId = 0,
    fills: std.ArrayList(SlotFill) = .empty,
    removed: bool = false,
};

/// A run of label markup in a track's flow: words, an equation, or both
/// (equations are markup too). For now a run is one unbreakable item, set
/// as a single line in its style; breaking between its words comes later.
pub const Run = struct {
    style: StyleId = 0,
    content: []const u8,
};

/// One item in a track's flow, with any gap before it, u. Text, tiles and
/// equations share one stream: a tile of any prototype, a blank (a spacer
/// `blank` u long), a run of markup, or a hard break, which ends its
/// segment so the next item starts the next one.
pub const Item = struct {
    gap: f64 = 0,
    what: union(enum) {
        tile: TileId,
        blank: f64,
        run: Run,
        hard_break,
    },

    pub fn tileOf(item: Item) ?TileId {
        return switch (item.what) {
            .tile => |id| id,
            else => null,
        };
    }
};

/// A segment: one row, or one column, of a track. The track's flow is
/// poured through its segments in order. Segments are laid out one after
/// another across their region, but each may be moved on its own.
pub const Segment = struct {
    /// Space before the segment across the region (above a row, left of a
    /// column), u, while it follows the segment before it.
    gap: f64 = 0,
    /// Where the segment starts across the region, u from its start edge,
    /// once it has been placed on its own; null follows the segment before
    /// (one segment's thickness on, plus `gap`).
    across: ?f64 = null,
    /// How far the segment, content and all, is shifted along from the
    /// region's start, u; either way.
    offset: f64 = 0,
};

/// Which way a region's tracks run: rows, filled left to right and stacked
/// top to bottom, or columns, filled top to bottom and set left to right.
pub const Major = enum { row, column };

/// A region holding a track: one flow of items (tiles, blanks, runs of
/// text or equations, hard breaks) poured in order through its segments,
/// rows or columns placed from the region's top-left corner.
pub const TileRegion = struct {
    name: []const u8,
    /// The region's top-left corner in the panel frame, mm.
    origin: geom.Point,
    /// Its size in u: a segment's length along, and the room across.
    w: f64,
    h: f64,
    /// mm per u.
    pitch: f64,
    major: Major = .row,
    /// The kind of tile it was made for: what new tiles in it are.
    prototype: ?PrototypeId = null,
    /// Its segments, in order: rows top to bottom, or columns left to
    /// right. A segment's gap is the space before it.
    segments: std.ArrayList(Segment) = .empty,
    /// The flow, in order. A tile spanning segments (a 2 u tall key) is
    /// listed again where it crosses each later segment; its first entry
    /// places it, and the later ones keep its room.
    items: std.ArrayList(Item) = .empty,

    /// A segment's length, u.
    pub fn segmentLength(r: TileRegion) f64 {
        return if (r.major == .row) r.w else r.h;
    }

    /// Where segment `t` starts across the region, u from its start edge.
    pub fn segmentAcross(r: TileRegion, t: usize) f64 {
        var at: f64 = 0;
        for (r.segments.items[0 .. t + 1], 0..) |seg, i| {
            const follows = if (i == 0) 0 else at + 1;
            at = seg.across orelse follows + seg.gap;
        }
        return at;
    }

    /// Segment `t`'s band in the panel frame, mm: its length along, one
    /// pitch across, moved as the segment has been.
    pub fn segmentBox(r: TileRegion, t: usize) geom.Box {
        const across = r.segmentAcross(t) * r.pitch;
        const shift = r.segments.items[t].offset * r.pitch;
        const length = r.segmentLength() * r.pitch;
        return if (r.major == .row)
            .{ .x0 = r.origin.x + shift, .x1 = r.origin.x + shift + length, .y1 = r.origin.y - across, .y0 = r.origin.y - across - r.pitch }
        else
            .{ .x0 = r.origin.x + across, .x1 = r.origin.x + across + r.pitch, .y1 = r.origin.y - shift, .y0 = r.origin.y - shift - length };
    }
};

/// The length along a track, or across tracks.
pub const Axis = enum { along, across };

/// A label placed directly on a panel (a faceplate legend, say), rather
/// than in a tile's slot. It is set as one line from its anchor, without a
/// hard box: it sits exactly where it was put.
pub const PanelLabel = struct {
    /// The anchor on the label's baseline, mm in the panel frame.
    at: geom.Point,
    /// Which part of the line the anchor is: its start, centre or end.
    alignment: Align = .start,
    style: StyleId = 0,
    /// Label markup.
    content: []const u8,
    /// True while the content is the app's placeholder.
    default_content: bool = false,
};

pub const Panel = struct {
    name: []const u8,
    /// True while the name is one the app gave it (Panel 1), not the user.
    default_name: bool = false,
    /// Where the panel's frame origin (its bottom-left corner) sits on the
    /// worksheet, mm.
    origin: geom.Point = .{ .x = 0, .y = 0 },
    /// Outline size, mm; the frame's origin is the bottom-left corner.
    w: f64,
    h: f64,
    regions: std.ArrayList(TileRegion) = .empty,
    labels: std.ArrayList(PanelLabel) = .empty,
    /// Ink keep-out bands inside the panel's edges, mm: its ink area is the
    /// outline less these. 5 mm on each side until the user sets them.
    margins: Sides = .all(5),
    default_margins: bool = true,

    /// The panel's outline on the worksheet.
    pub fn box(p: Panel) geom.Box {
        return .{ .x0 = p.origin.x, .y0 = p.origin.y, .x1 = p.origin.x + p.w, .y1 = p.origin.y + p.h };
    }

    /// Where the panel's ink may go, on the worksheet.
    pub fn inkArea(p: Panel) geom.Box {
        return p.margins.inset(p.box());
    }
};

/// A standard paper size, portrait (w <= h), mm.
pub const Paper = struct {
    name: []const u8,
    w: f64,
    h: f64,
};

/// ISO 216 A sizes and ANSI/ASME Y14.1 sizes (1 in = 25.4 mm exactly).
pub const papers = [_]Paper{
    .{ .name = "A4", .w = 210, .h = 297 },
    .{ .name = "A3", .w = 297, .h = 420 },
    .{ .name = "A2", .w = 420, .h = 594 },
    .{ .name = "A1", .w = 594, .h = 841 },
    .{ .name = "A0", .w = 841, .h = 1189 },
    .{ .name = "ANSI A (letter)", .w = 215.9, .h = 279.4 },
    .{ .name = "ANSI B (tabloid)", .w = 279.4, .h = 431.8 },
    .{ .name = "ANSI C", .w = 431.8, .h = 558.8 },
    .{ .name = "ANSI D", .w = 558.8, .h = 863.6 },
    .{ .name = "ANSI E", .w = 863.6, .h = 1117.6 },
};

pub const Orientation = enum { landscape, portrait };

/// Where rulers and shown coordinates put zero, and which way they count.
pub const RulerOrigin = enum {
    bottom_left,
    top_left,
    bottom_right,
    top_right,

    pub fn fromRight(o: RulerOrigin) bool {
        return o == .bottom_right or o == .top_right;
    }

    pub fn fromTop(o: RulerOrigin) bool {
        return o == .top_left or o == .top_right;
    }
};

/// The units a context shows and takes values in. Values are stored in mm
/// as doubles whatever the units; units convert only at display and entry
/// (1 in = 25.4 mm exactly).
pub const Units = enum {
    mm,
    inch,

    pub fn perMm(u: Units) f64 {
        return switch (u) {
            .mm => 1,
            .inch => 1.0 / 25.4,
        };
    }

    pub fn symbol(u: Units) []const u8 {
        return switch (u) {
            .mm => "mm",
            .inch => "in",
        };
    }
};

/// The worksheet: paper in drawing units, holding panels. Its frame's
/// origin is the sheet's bottom-left corner, y up.
pub const Sheet = struct {
    /// A short description for reference; the app's "Worksheet 1" until
    /// the user names it.
    name: []const u8 = "Worksheet 1",
    default_name: bool = true,
    /// Index into `papers`, or null for a custom size.
    paper: ?usize = 2,
    orientation: Orientation = .landscape,
    /// Sheet size, mm. For a standard paper it follows from the paper and
    /// orientation; A2 landscape until the user picks another.
    w: f64 = 594,
    h: f64 = 420,
    /// True while the size is the app's default.
    default_size: bool = true,
    /// Ink keep-out bands along the sheet's edges, mm. Panels may reach
    /// into them; ink inside a panel may not. ISO 5457's drawing-sheet
    /// margins (20 mm on the binding side, 10 mm elsewhere) until the user
    /// sets their own.
    margins: Sides = .{ .left = 20, .right = 10, .top = 10, .bottom = 10 },
    default_margins: bool = true,
    /// The worksheet's display and entry units; mm until the user picks.
    units: Units = .mm,
    default_units: bool = true,
    /// The corner the rulers and shown coordinates count from: bottom-left
    /// (the worksheet frame, y up) until the user picks; a right-hand
    /// origin suits right-to-left page design such as Hebrew. Stored
    /// positions are always in the worksheet frame.
    ruler_origin: RulerOrigin = .bottom_left,
    default_ruler_origin: bool = true,

    pub fn box(s: Sheet) geom.Box {
        return .{ .x0 = 0, .y0 = 0, .x1 = s.w, .y1 = s.h };
    }

    /// A worksheet point as the rulers count it, mm: from the ruler origin,
    /// increasing away from it.
    pub fn toRuler(s: Sheet, p: geom.Point) geom.Point {
        return .{
            .x = if (s.ruler_origin.fromRight()) s.w - p.x else p.x,
            .y = if (s.ruler_origin.fromTop()) s.h - p.y else p.y,
        };
    }

    /// The inverse of `toRuler`.
    pub fn fromRuler(s: Sheet, r: geom.Point) geom.Point {
        return s.toRuler(r);
    }

    /// Where ink may go: the sheet less its margins.
    pub fn inkArea(s: Sheet) geom.Box {
        return s.margins.inset(s.box());
    }

    /// A standard paper in an orientation.
    pub fn standard(paper: usize, orientation: Orientation) Sheet {
        const p = papers[paper];
        return .{
            .paper = paper,
            .orientation = orientation,
            .w = if (orientation == .landscape) p.h else p.w,
            .h = if (orientation == .landscape) p.w else p.h,
            .default_size = false,
        };
    }

    /// A custom size; its orientation follows from its proportions.
    pub fn custom(w: f64, h: f64) Sheet {
        return .{ .paper = null, .orientation = if (w >= h) .landscape else .portrait, .w = w, .h = h, .default_size = false };
    }
};

pub const LabelStyle = struct {
    name: []const u8,
    /// Face ids index the face table the caller renders with.
    spec: engine.style.Spec,
};

pub const Model = struct {
    /// Owns every string and list in the model.
    arena: std.heap.ArenaAllocator,
    sheet: Sheet = .{},
    panels: std.ArrayList(Panel) = .empty,
    tiles: std.ArrayList(Tile) = .empty,
    prototypes: std.ArrayList(TilePrototype) = .empty,
    styles: std.ArrayList(LabelStyle) = .empty,
    /// Bumped by every action, so callers can tell when to re-solve.
    revision: u64 = 0,

    pub const Error = Allocator.Error || error{ NoRoom, DuplicateDesignator, NoSuchPrototype, NoSuchTile, NoSuchSlot, NoSuchLayer, DuplicateSlot, PrototypeInUse, NoSuchRow, NoSuchItem, BadSize, OffSheet, NotCompliant };

    pub fn init(gpa: Allocator) Model {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Model) void {
        m.arena.deinit();
        m.* = undefined;
    }

    fn a(m: *Model) Allocator {
        return m.arena.allocator();
    }

    pub fn tile(m: *Model, id: TileId) *Tile {
        return &m.tiles.items[@backingInt(id)];
    }

    pub fn tileConst(m: *const Model, id: TileId) *const Tile {
        return &m.tiles.items[@backingInt(id)];
    }

    /// The prototype tile `id` is an instance of.
    pub fn prototypeOf(m: *const Model, id: TileId) *const TilePrototype {
        return &m.prototypes.items[m.tileConst(id).prototype];
    }

    /// How many slots tile `id` has: its prototype's.
    pub fn slotCount(m: *const Model, id: TileId) usize {
        return m.prototypeOf(id).slots.len;
    }

    /// Slot `i` of tile `id`, its prototype's with the tile's label and
    /// overrides applied.
    pub fn slot(m: *const Model, id: TileId, i: usize) Slot {
        const sp = m.prototypeOf(id).slots[i];
        const own = m.fillConst(id, sp.name);
        return .{
            .name = sp.name,
            .place = if (own) |f| f.place orelse sp.place else sp.place,
            .style = if (own) |f| f.style orelse sp.style else sp.style,
            .content = if (own) |f| f.content else "",
        };
    }

    /// The index of tile `id`'s slot called `name`.
    pub fn slotIndex(m: *const Model, id: TileId, name: []const u8) ?usize {
        for (m.prototypeOf(id).slots, 0..) |sp, i| if (std.mem.eql(u8, sp.name, name)) return i;
        return null;
    }

    /// A slot named as the label content format writes it: a designator,
    /// a dot and a slot name, as in `K23.top`.
    pub fn findSlotPath(m: *const Model, path: []const u8) ?SlotRef {
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
        const id = m.findTile(path[0..dot]) orelse return null;
        return .{ .tile = id, .slot = m.slotIndex(id, path[dot + 1 ..]) orelse return null };
    }

    /// Tile `id`'s own part of slot `name`, if it has one.
    pub fn fillConst(m: *const Model, id: TileId, name: []const u8) ?*const SlotFill {
        for (m.tileConst(id).fills.items) |*f| if (std.mem.eql(u8, f.slot, name)) return f;
        return null;
    }

    /// Tile `id`'s fill for its slot `name`, made if it has none; the slot
    /// must be one of its prototype's.
    fn fill(m: *Model, id: TileId, name: []const u8) Error!*SlotFill {
        if (m.slotIndex(id, name) == null) return error.NoSuchSlot;
        const fills = &m.tile(id).fills;
        for (fills.items) |*f| if (std.mem.eql(u8, f.slot, name)) return f;
        try fills.append(m.a(), .{ .slot = try m.a().dupe(u8, name) });
        return &fills.items[fills.items.len - 1];
    }

    // Actions -----------------------------------------------------------

    pub fn addStyle(m: *Model, name: []const u8, spec: engine.style.Spec) Error!StyleId {
        try m.styles.append(m.a(), .{ .name = try m.a().dupe(u8, name), .spec = spec });
        m.revision += 1;
        return @intCast(m.styles.items.len - 1);
    }

    pub fn setStyle(m: *Model, id: StyleId, spec: engine.style.Spec) void {
        m.styles.items[id].spec = spec;
        m.revision += 1;
    }

    pub fn addPanel(m: *Model, name: []const u8, w: f64, h: f64) Error!usize {
        return m.placePanel(.{ .name = name, .w = w, .h = h });
    }

    /// Adds a panel on the worksheet: its name, size, origin and whether
    /// the name is the app's choice are taken from `panel`.
    pub fn placePanel(m: *Model, panel: Panel) Error!usize {
        if (!(panel.w > 0 and panel.h > 0)) return error.BadSize;
        // It may hang past the sheet's edge (it is flagged), but not lie
        // off it.
        if (!m.gripsSheet(panel.box())) return error.OffSheet;
        var p = panel;
        p.name = try m.a().dupe(u8, panel.name);
        p.regions = .empty;
        p.labels = .empty;
        try m.panels.append(m.a(), p);
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// Sets the worksheet's sheet. Panels keep their positions; one left
    /// partly off a smaller sheet is reported by the checks (drc.offSheet),
    /// not moved.
    pub fn setSheet(m: *Model, sheet: Sheet) Error!void {
        if (!(sheet.w > 0 and sheet.h > 0)) return error.BadSize;
        const old = m.sheet;
        m.sheet = sheet;
        // Size changes keep the worksheet's name and margins.
        m.sheet.name = old.name;
        m.sheet.default_name = old.default_name;
        m.sheet.margins = old.margins;
        m.sheet.default_margins = old.default_margins;
        m.sheet.units = old.units;
        m.sheet.default_units = old.default_units;
        m.sheet.ruler_origin = old.ruler_origin;
        m.sheet.default_ruler_origin = old.default_ruler_origin;
        m.revision += 1;
    }

    /// Sets the worksheet's margins, mm.
    pub fn setMargins(m: *Model, margins: Sides) Error!void {
        const ok = margins.left >= 0 and margins.right >= 0 and margins.top >= 0 and margins.bottom >= 0;
        if (!ok or margins.left + margins.right >= m.sheet.w or margins.top + margins.bottom >= m.sheet.h) return error.BadSize;
        m.sheet.margins = margins;
        m.sheet.default_margins = false;
        m.revision += 1;
    }

    /// Sets the corner the rulers count from.
    pub fn setRulerOrigin(m: *Model, origin: RulerOrigin) void {
        m.sheet.ruler_origin = origin;
        m.sheet.default_ruler_origin = false;
        m.revision += 1;
    }

    /// Sets the worksheet's units.
    pub fn setUnits(m: *Model, units: Units) void {
        m.sheet.units = units;
        m.sheet.default_units = false;
        m.revision += 1;
    }

    /// Names the worksheet.
    pub fn nameWorksheet(m: *Model, name: []const u8) Error!void {
        m.sheet.name = try m.a().dupe(u8, name);
        m.sheet.default_name = false;
        m.revision += 1;
    }

    /// Moves a panel on the worksheet.
    /// Moves a panel. Like tracks on a panel, it may hang past the sheet's
    /// edge, flagged, but a grip of it must stay on the sheet.
    pub fn movePanel(m: *Model, panel: usize, origin: geom.Point) Error!void {
        var p = m.panels.items[panel];
        p.origin = origin;
        if (!m.gripsSheet(p.box())) return error.OffSheet;
        m.panels.items[panel].origin = origin;
        m.revision += 1;
    }

    /// Whether a panel complies: its outline on the sheet, and its ink area
    /// inside the sheet's ink area (its outline may reach into the sheet's
    /// margins).
    pub fn compliant(m: *const Model, panel: usize) bool {
        return m.compliantAt(panel, m.panels.items[panel].origin);
    }

    pub fn compliantAt(m: *const Model, panel: usize, origin: geom.Point) bool {
        var p = m.panels.items[panel];
        p.origin = origin;
        return m.onSheet(p.box()) and within(p.inkArea(), m.sheet.inkArea());
    }

    /// Adds a label to a panel; returns its index on the panel.
    pub fn addLabel(m: *Model, panel: usize, label: PanelLabel) Error!usize {
        var l = label;
        l.content = try m.a().dupe(u8, label.content);
        const list = &m.panels.items[panel].labels;
        try list.append(m.a(), l);
        m.revision += 1;
        return list.items.len - 1;
    }

    pub fn setLabelContent(m: *Model, panel: usize, label: usize, content: []const u8) Error!void {
        const l = &m.panels.items[panel].labels.items[label];
        l.content = try m.a().dupe(u8, content);
        l.default_content = false;
        m.revision += 1;
    }

    pub fn moveLabel(m: *Model, panel: usize, label: usize, at: geom.Point) void {
        m.panels.items[panel].labels.items[label].at = at;
        m.revision += 1;
    }

    pub fn alignLabel(m: *Model, panel: usize, label: usize, alignment: Align) void {
        m.panels.items[panel].labels.items[label].alignment = alignment;
        m.revision += 1;
    }

    /// Removes a label; later labels on the panel move down one index.
    pub fn removeLabel(m: *Model, panel: usize, label: usize) void {
        _ = m.panels.items[panel].labels.orderedRemove(label);
        m.revision += 1;
    }

    /// Sets a style's size as cap height, mm; every label using it changes.
    pub fn setCapHeight(m: *Model, style: StyleId, cap_height: f64) Error!void {
        if (!(cap_height > 0)) return error.BadSize;
        m.styles.items[style].spec.cap_height = cap_height;
        m.revision += 1;
    }

    /// Sets a panel's margins, mm.
    pub fn setPanelMargins(m: *Model, panel: usize, margins: Sides) Error!void {
        const p = &m.panels.items[panel];
        const ok = margins.left >= 0 and margins.right >= 0 and margins.top >= 0 and margins.bottom >= 0;
        if (!ok or margins.left + margins.right >= p.w or margins.top + margins.bottom >= p.h) return error.BadSize;
        p.margins = margins;
        p.default_margins = false;
        m.revision += 1;
    }

    /// Removes a panel with its regions; tiles placed only on it are
    /// removed too. Later panels move down one index.
    pub fn removePanel(m: *Model, panel: usize) void {
        const p = m.panels.orderedRemove(panel);
        for (p.regions.items) |region| for (region.items.items) |item| {
            const id = item.tileOf() orelse continue;
            if (!m.placedElsewhere(id)) m.tile(id).removed = true;
        };
        m.revision += 1;
    }

    fn placedElsewhere(m: *const Model, id: TileId) bool {
        for (m.panels.items) |p| for (p.regions.items) |region| for (region.items.items) |item| {
            if (item.tileOf() == id) return true;
        };
        return false;
    }

    /// How much of a panel stays on the sheet however it is moved, mm on
    /// each axis: enough to grab it again (all of it, if it is smaller).
    pub const panel_grip = 5.0;

    /// The origin nearest `origin` that keeps a grip of panel `panel` on
    /// the sheet; past that, it may hang off any edge.
    pub fn clampOnSheet(m: *const Model, panel: usize, origin: geom.Point) geom.Point {
        const p = m.panels.items[panel];
        const s = m.sheet;
        const gx = @min(panel_grip, p.w);
        const gy = @min(panel_grip, p.h);
        return .{
            .x = std.math.clamp(origin.x, gx - p.w, s.w - gx),
            .y = std.math.clamp(origin.y, gy - p.h, s.h - gy),
        };
    }

    /// Whether box `b` keeps a grip on the sheet (see `panel_grip`).
    pub fn gripsSheet(m: *const Model, b: geom.Box) bool {
        const s = m.sheet.box();
        const tol = 1e-9;
        const ox = @min(b.x1, s.x1) - @max(b.x0, s.x0);
        const oy = @min(b.y1, s.y1) - @max(b.y0, s.y0);
        return ox >= @min(panel_grip, b.width()) - tol and oy >= @min(panel_grip, b.height()) - tol;
    }

    /// Whether a box lies on the sheet. Panels are placed and moved only
    /// within it (they may overlap each other); a sheet change that leaves
    /// one hanging over the edge is reported by the checks instead.
    pub fn onSheet(m: *const Model, b: geom.Box) bool {
        return within(b, m.sheet.box());
    }

    /// The first "<prefix> N" not yet used as a panel name.
    pub fn nextPanelName(m: *const Model, buf: []u8, prefix: []const u8) []const u8 {
        var n: usize = m.panels.items.len + 1;
        while (true) : (n += 1) {
            const name = std.fmt.bufPrint(buf, "{s} {d}", .{ prefix, n }) catch return prefix;
            for (m.panels.items) |p| {
                if (std.mem.eql(u8, p.name, name)) break;
            } else return name;
        }
    }

    pub fn addRegion(m: *Model, panel: usize, region: TileRegion) Error!usize {
        if (!(region.pitch > 0 and region.w > 0 and region.h > 0)) return error.BadSize;
        var r = region;
        r.name = try m.a().dupe(u8, region.name);
        r.segments = .empty;
        r.items = .empty;
        const regions = &m.panels.items[panel].regions;
        try regions.append(m.a(), r);
        m.revision += 1;
        return regions.items.len - 1;
    }

    pub const Tracks = struct {
        name: []const u8,
        /// The region's top-left corner in the panel frame, mm.
        origin: geom.Point,
        major: Major = .row,
        prototype: PrototypeId,
        /// How many tracks, and each one's length, u.
        count: usize,
        length: f64,
        pitch: f64,
    };

    /// Adds a region of `count` empty tracks for tiles made from
    /// `prototype`, each as thick as its smallest tile; the user adds the
    /// tiles. Returns the region's index.
    pub fn addTracks(m: *Model, panel: usize, t: Tracks) Error!usize {
        if (t.prototype >= m.prototypes.items.len) return error.NoSuchPrototype;
        const proto = m.prototypes.items[t.prototype];
        const along = proto.smallest(t.major, .along);
        const across = proto.smallest(t.major, .across);
        if (t.count == 0 or !(t.length >= along - 1e-9)) return error.BadSize;
        const thickness = @as(f64, @floatFromInt(t.count)) * across;
        const r = try m.addRegion(panel, .{
            .name = t.name,
            .origin = t.origin,
            .w = if (t.major == .row) t.length else thickness,
            .h = if (t.major == .row) thickness else t.length,
            .pitch = t.pitch,
            .major = t.major,
            .prototype = t.prototype,
        });
        for (0..t.count) |_| _ = try m.addSegment(panel, r, 0);
        return r;
    }

    /// The lowest-numbered designator `prefix`1, `prefix`2 … not taken.
    fn nextDesignator(m: *const Model, buf: []u8, prefix: []const u8) []const u8 {
        var n: usize = 1;
        while (true) : (n += 1) {
            const candidate = std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, n }) catch return prefix;
            if (m.findTile(candidate) == null) return candidate;
        }
    }

    fn flow(m: *Model, panel: usize, region: usize) *std.ArrayList(Item) {
        return &m.panels.items[panel].regions.items[region].items;
    }

    /// Inserts item `item` at position `index` of a track's flow (0
    /// before the first item; null for the end). Its tile, if any, must
    /// already exist.
    pub fn place(m: *Model, panel: usize, region: usize, index: ?usize, item: Item) Error!void {
        const items = m.flow(panel, region);
        const at = index orelse items.items.len;
        if (at > items.items.len) return error.NoSuchItem;
        var it = item;
        if (it.what == .run) it.what.run.content = try m.a().dupe(u8, it.what.run.content);
        try items.insert(m.a(), at, it);
        m.revision += 1;
    }

    /// Inserts a new tile made from `prototype` at position `index` of a
    /// track's flow: `along` u long in the track's direction and the
    /// prototype's smallest size across. Returns it.
    pub fn insertTile(m: *Model, panel: usize, region: usize, index: usize, prototype: PrototypeId, along: f64) Error!TileId {
        if (prototype >= m.prototypes.items.len) return error.NoSuchPrototype;
        if (index > m.flow(panel, region).items.len) return error.NoSuchItem;
        const major = m.panels.items[panel].regions.items[region].major;
        const across = m.prototypes.items[prototype].smallest(major, .across);
        var buf: [64]u8 = undefined;
        const id = try m.addTile(.{
            .designator = m.nextDesignator(&buf, "T"),
            .prototype = prototype,
            .w = if (major == .row) along else across,
            .h = if (major == .row) across else along,
        });
        try m.place(panel, region, index, .{ .what = .{ .tile = id } });
        return id;
    }

    /// Inserts a blank `length` u long at position `index` of a track.
    pub fn insertBlank(m: *Model, panel: usize, region: usize, index: usize, length: f64) Error!void {
        if (!(length > 0)) return error.BadSize;
        try m.place(panel, region, index, .{ .what = .{ .blank = length } });
    }

    /// Inserts a hard break at position `index` of a track: what follows
    /// starts the next segment.
    pub fn insertBreak(m: *Model, panel: usize, region: usize, index: usize) Error!void {
        try m.place(panel, region, index, .{ .what = .hard_break });
    }

    /// Inserts a run of markup (text, an equation, or both) at position
    /// `index` of a track.
    pub fn insertRun(m: *Model, panel: usize, region: usize, index: usize, run: Run) Error!void {
        try m.place(panel, region, index, .{ .what = .{ .run = run } });
    }

    /// Sets the markup of the run at position `index` of a track.
    pub fn setRunContent(m: *Model, panel: usize, region: usize, index: usize, content: []const u8) Error!void {
        const items = m.flow(panel, region).items;
        if (index >= items.len or items[index].what != .run) return error.NoSuchItem;
        items[index].what.run.content = try m.a().dupe(u8, content);
        m.revision += 1;
    }

    /// Removes item `index` of a track: a blank, run or break, or a tile,
    /// which leaves every track it is in.
    pub fn removeAt(m: *Model, panel: usize, region: usize, index: usize) Error!void {
        const items = m.flow(panel, region);
        if (index >= items.items.len) return error.NoSuchItem;
        if (items.items[index].tileOf()) |id| {
            m.removeTile(id);
        } else {
            _ = items.orderedRemove(index);
            m.revision += 1;
        }
    }

    /// Sets the length of a track's segments, u, as Fit to tiles does with
    /// the length its longest paragraph needs (see `place.Placed`).
    pub fn setSegmentLength(m: *Model, panel: usize, region: usize, length: f64) Error!void {
        if (!(length > 0)) return error.BadSize;
        const r = &m.panels.items[panel].regions.items[region];
        if (r.major == .row) r.w = length else r.h = length;
        m.revision += 1;
    }

    /// Moves a segment, content and all, `along` u along its length and
    /// `across` u across the region (down for a row, right for a column),
    /// either way. Every other segment keeps its place. It may move past
    /// its region or its panel (flagged when placed), but not onto another
    /// segment's band anywhere on the panel: that is refused with `NoRoom`.
    pub fn moveSegment(m: *Model, panel: usize, region: usize, segment: usize, along: f64, across: f64) Error!void {
        const r = &m.panels.items[panel].regions.items[region];
        const segs = r.segments.items;
        if (segment >= segs.len) return error.NoSuchRow;
        // Where it would go, with the others where they are now.
        var seg = segs[segment];
        seg.across = r.segmentAcross(segment) + across;
        seg.offset += along;
        const saved = segs[segment];
        segs[segment] = seg;
        const target = r.segmentBox(segment);
        segs[segment] = saved;
        for (m.panels.items[panel].regions.items, 0..) |other, oi| for (0..other.segments.items.len) |ot| {
            if (oi == region and ot == segment) continue;
            if (overlaps(target, other.segmentBox(ot))) return error.NoRoom;
        };
        // Every segment of the region placed on its own from now on, so its
        // neighbours stay where they are.
        var places: [256]f64 = undefined;
        if (segs.len > places.len) return error.NoRoom;
        for (0..segs.len) |t| places[t] = r.segmentAcross(t);
        for (segs, 0..) |*t, i| t.across = places[i];
        segs[segment] = seg;
        m.revision += 1;
    }

    /// Removes tile `id`: it leaves every track it is in, which reflows.
    pub fn removeTile(m: *Model, id: TileId) void {
        m.unplace(id);
        m.tile(id).removed = true;
        m.revision += 1;
    }

    pub fn addSegment(m: *Model, panel: usize, region: usize, gap: f64) Error!usize {
        const segs = &m.panels.items[panel].regions.items[region].segments;
        try segs.append(m.a(), .{ .gap = gap });
        m.revision += 1;
        return segs.items.len - 1;
    }

    pub fn addPrototype(m: *Model, p: TilePrototype) Error!PrototypeId {
        try m.prototypes.append(m.a(), try m.dupePrototype(p));
        m.revision += 1;
        return @intCast(m.prototypes.items.len - 1);
    }

    /// Changes a prototype, and with it every tile made from it.
    pub fn setPrototype(m: *Model, id: PrototypeId, p: TilePrototype) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        m.prototypes.items[id] = try m.dupePrototype(p);
        m.revision += 1;
    }

    /// Changes slot `i` of a prototype (its place, default style or name),
    /// and so that slot on every tile made from it, except where a tile has
    /// its own.
    pub fn setPrototypeSlot(m: *Model, id: PrototypeId, i: usize, sp: SlotPrototype) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const p = &m.prototypes.items[id];
        if (i >= p.slots.len) return error.NoSuchSlot;
        const slots = try m.a().dupe(SlotPrototype, p.slots);
        slots[i] = sp;
        slots[i].name = try m.a().dupe(u8, sp.name);
        p.slots = slots;
        m.revision += 1;
    }

    /// Changes how layer `i` of a prototype's art is painted. Its outline is
    /// left as drawn.
    pub fn setLayerPaint(m: *Model, id: PrototypeId, i: usize, paint: art_.Paint) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const p = &m.prototypes.items[id];
        const art = p.art orelse return error.NoSuchLayer;
        if (i >= art.layers.len) return error.NoSuchLayer;
        const layers = try m.a().dupe(art_.Layer, art.layers);
        layers[i].paint = paint;
        p.art.?.layers = layers;
        m.revision += 1;
    }

    /// How many tiles are made from prototype `id`.
    pub fn prototypeUses(m: *const Model, id: PrototypeId) usize {
        var n: usize = 0;
        for (m.tiles.items) |t| {
            if (!t.removed and t.prototype == id) n += 1;
        }
        return n;
    }

    /// Adds a slot to a prototype, and so to every tile made from it.
    pub fn addPrototypeSlot(m: *Model, id: PrototypeId, sp: SlotPrototype) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const p = &m.prototypes.items[id];
        for (p.slots) |s| if (std.mem.eql(u8, s.name, sp.name)) return error.DuplicateSlot;
        const slots = try m.a().alloc(SlotPrototype, p.slots.len + 1);
        @memcpy(slots[0..p.slots.len], p.slots);
        slots[p.slots.len] = sp;
        slots[p.slots.len].name = try m.a().dupe(u8, sp.name);
        p.slots = slots;
        m.revision += 1;
    }

    /// A copy of prototype `id` named `name`, art and all; returns its id.
    pub fn duplicatePrototype(m: *Model, id: PrototypeId, name: []const u8) Error!PrototypeId {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        var copy = m.prototypes.items[id];
        copy.name = name;
        return m.addPrototype(copy);
    }

    /// Removes prototype `id`, which no tile may still be made from. Later
    /// prototypes move down one, and tiles follow them.
    pub fn removePrototype(m: *Model, id: PrototypeId) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        if (m.prototypeUses(id) > 0) return error.PrototypeInUse;
        _ = m.prototypes.orderedRemove(id);
        for (m.tiles.items) |*t| {
            if (t.prototype > id) t.prototype -= 1;
        }
        m.revision += 1;
    }

    /// Renames slot `i` of a prototype; every tile made from it keeps its
    /// label and overrides under the new name.
    pub fn renamePrototypeSlot(m: *Model, id: PrototypeId, i: usize, name: []const u8) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const p = &m.prototypes.items[id];
        if (i >= p.slots.len) return error.NoSuchSlot;
        for (p.slots, 0..) |sp, k| {
            if (k != i and std.mem.eql(u8, sp.name, name)) return error.DuplicateSlot;
        }
        const old = p.slots[i].name;
        const new = try m.a().dupe(u8, name);
        for (m.tiles.items) |*t| {
            if (t.prototype != id) continue;
            for (t.fills.items) |*f| {
                if (std.mem.eql(u8, f.slot, old)) f.slot = new;
            }
        }
        var sp = p.slots[i];
        sp.name = new;
        try m.setPrototypeSlot(id, i, sp);
    }

    /// Removes slot `i` from a prototype. Tiles keep what they had in it,
    /// unshown, so adding a slot of that name back brings it back.
    pub fn removePrototypeSlot(m: *Model, id: PrototypeId, i: usize) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const p = &m.prototypes.items[id];
        if (i >= p.slots.len) return error.NoSuchSlot;
        const slots = try m.a().alloc(SlotPrototype, p.slots.len - 1);
        @memcpy(slots[0..i], p.slots[0..i]);
        @memcpy(slots[i..], p.slots[i + 1 ..]);
        p.slots = slots;
        m.revision += 1;
    }

    /// Sets or clears a prototype's art; null draws it plain from its insets.
    pub fn setPrototypeArt(m: *Model, id: PrototypeId, art: ?art_.Art) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        m.prototypes.items[id].art = if (art) |x| try art_.dupe(m.a(), x) else null;
        m.revision += 1;
    }

    fn dupePrototype(m: *Model, p: TilePrototype) Allocator.Error!TilePrototype {
        var copy = p;
        copy.name = try m.a().dupe(u8, p.name);
        const slots = try m.a().alloc(SlotPrototype, p.slots.len);
        for (p.slots, slots) |sp, *out| {
            out.* = sp;
            out.name = try m.a().dupe(u8, sp.name);
        }
        copy.slots = slots;
        if (p.art) |art| copy.art = try art_.dupe(m.a(), art);
        copy.widths = try m.a().dupe(f64, p.widths);
        copy.heights = try m.a().dupe(f64, p.heights);
        return copy;
    }

    /// Resizes tile `id`, u. A size its prototype does not allow is kept and
    /// flagged when placed.
    pub fn setTileSize(m: *Model, id: TileId, w: f64, h: f64) Error!void {
        if (!(w > 0 and h > 0)) return error.BadSize;
        const t = m.tile(id);
        t.w = w;
        t.h = h;
        m.revision += 1;
    }

    /// Makes tile `id` an instance of another prototype.
    pub fn setTilePrototype(m: *Model, id: TileId, prototype: PrototypeId) Error!void {
        if (prototype >= m.prototypes.items.len) return error.NoSuchPrototype;
        m.tile(id).prototype = prototype;
        m.revision += 1;
    }

    /// Adds a tile with a designator unique among the model's tiles. A tile
    /// added before any prototype gets a plain one, with no insets.
    pub fn addTile(m: *Model, t: Tile) Error!TileId {
        if (!(t.w > 0 and t.h > 0)) return error.BadSize;
        if (m.findTile(t.designator) != null) return error.DuplicateDesignator;
        if (m.prototypes.items.len == 0 and t.prototype == 0) _ = try m.addPrototype(.{ .name = "Plain" });
        if (t.prototype >= m.prototypes.items.len) return error.NoSuchPrototype;
        var copy = t;
        copy.designator = try m.a().dupe(u8, t.designator);
        copy.fills = .empty;
        for (t.fills.items) |f| {
            var c = f;
            c.slot = try m.a().dupe(u8, f.slot);
            c.content = try m.a().dupe(u8, f.content);
            try copy.fills.append(m.a(), c);
        }
        try m.tiles.append(m.a(), copy);
        m.revision += 1;
        return @fromBackingInt(@intCast(m.tiles.items.len - 1));
    }

    /// Sets the label markup in tile `id`'s slot `name`.
    pub fn setContent(m: *Model, id: TileId, name: []const u8, content: []const u8) Error!void {
        const f = try m.fill(id, name);
        f.content = try m.a().dupe(u8, content);
        m.revision += 1;
    }

    /// Sets the label markup in the slot `path` names (`K23.top`).
    pub fn setContentAt(m: *Model, path: []const u8, content: []const u8) Error!void {
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return error.NoSuchSlot;
        const id = m.findTile(path[0..dot]) orelse return error.NoSuchTile;
        return m.setContent(id, path[dot + 1 ..], content);
    }

    /// Sets tile `id`'s own style for slot `name`; null takes the
    /// prototype's again.
    pub fn setSlotStyle(m: *Model, id: TileId, name: []const u8, style: ?StyleId) Error!void {
        (try m.fill(id, name)).style = style;
        m.revision += 1;
    }

    /// Sets tile `id`'s own place for slot `name`; null takes the
    /// prototype's again.
    pub fn setSlotPlace(m: *Model, id: TileId, name: []const u8, place_: ?SlotPlace) Error!void {
        (try m.fill(id, name)).place = place_;
        m.revision += 1;
    }

    /// Takes `id` out of every track it is in, keeping the tile itself.
    pub fn unplace(m: *Model, id: TileId) void {
        for (m.panels.items) |*panel| for (panel.regions.items) |*region| {
            var i: usize = 0;
            while (i < region.items.items.len) {
                const here = region.items.items[i].tileOf();
                if (here != null and here.? == id) _ = region.items.orderedRemove(i) else i += 1;
            }
        };
        m.revision += 1;
    }

    pub fn findTile(m: *const Model, designator: []const u8) ?TileId {
        for (m.tiles.items, 0..) |t, i| {
            if (!t.removed and std.mem.eql(u8, t.designator, designator)) return @fromBackingInt(@intCast(i));
        }
        return null;
    }
};

test "panels may hang off the sheet, flagged, but keep a grip on it; a smaller sheet does not move them" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    // A2 landscape is 594 wide: a 700 mm panel hangs off, but is placed.
    const big = try m.placePanel(.{ .name = "big", .w = 700, .h = 100 });
    try std.testing.expect(!m.compliant(big));
    try std.testing.expectError(error.OffSheet, m.placePanel(.{ .name = "away", .origin = .{ .x = 600, .y = 10 }, .w = 50, .h = 50 }));
    const p = try m.placePanel(.{ .name = "P", .origin = .{ .x = 400, .y = 10 }, .w = 150, .h = 100 });
    // Past the right edge: allowed, and flagged.
    try m.movePanel(p, .{ .x = 500, .y = 10 });
    try std.testing.expect(!m.compliant(p));
    // But not off it: 5 mm must stay on.
    try std.testing.expectError(error.OffSheet, m.movePanel(p, .{ .x = 590, .y = 10 }));
    try std.testing.expectEqual(589, m.clampOnSheet(p, .{ .x = 700, .y = 10 }).x);
    try std.testing.expectEqual(-145, m.clampOnSheet(p, .{ .x = -400, .y = 10 }).x);
    try m.setSheet(.standard(1, .portrait)); // A3 portrait: 297 wide
    try std.testing.expectEqual(500, m.panels.items[p].origin.x);
    // Left entirely off by the smaller sheet, it can be brought back.
    try m.movePanel(p, .{ .x = 100, .y = 10 });
    // Ink area 105..245 inside the sheet's 20..287: compliant.
    try std.testing.expect(m.compliant(p));
    // Its outline may reach into the sheet's margins, its ink area may not.
    try std.testing.expect(m.compliantAt(p, .{ .x = 15, .y = 10 }));
    try std.testing.expect(!m.compliantAt(p, .{ .x = 14, .y = 10 }));
}

test "removing a panel removes its tiles and frees their designators" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.placePanel(.{ .name = "A", .w = 50, .h = 50 });
    const b = try m.placePanel(.{ .name = "B", .origin = .{ .x = 100, .y = 0 }, .w = 50, .h = 50 });
    const r = try m.addRegion(b, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 2, .h = 1, .pitch = 19.05 });
    _ = try m.addSegment(b, r, 0);
    try m.place(b, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = "K1" }) } });
    m.removePanel(0);
    try std.testing.expectEqualStrings("B", m.panels.items[0].name);
    m.removePanel(0);
    try std.testing.expectEqual(0, m.panels.items.len);
    try std.testing.expect(m.findTile("K1") == null);
    _ = try m.addTile(.{ .designator = "K1" });
}

test "ruler coordinates count from the chosen corner" {
    var s: Sheet = .{};
    const p: geom.Point = .{ .x = 100, .y = 50 };
    try std.testing.expectEqual(p, s.toRuler(p));
    s.ruler_origin = .top_right;
    const r = s.toRuler(p);
    try std.testing.expectEqual(494, r.x);
    try std.testing.expectEqual(370, r.y);
    try std.testing.expectEqual(p, s.fromRuler(r));
}

test "standard sheets turn with their orientation" {
    const a3 = Sheet.standard(1, .landscape);
    try std.testing.expectEqual(420, a3.w);
    try std.testing.expectEqual(297, a3.h);
    const letter = Sheet.standard(5, .portrait);
    try std.testing.expectEqual(215.9, letter.w);
    const default: Sheet = .{};
    try std.testing.expectEqual(Sheet.standard(2, .landscape).w, default.w);
}

test "designators are unique and actions bump the revision" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 50);
    const r = try m.addRegion(p, .{ .name = "main", .origin = .{ .x = 0, .y = 50 }, .w = 5, .h = 2, .pitch = 19.05 });
    _ = try m.addSegment(p, r, 0);
    const key = try m.addPrototype(.{ .name = "key", .slots = &.{.{ .name = "top" }} });
    const q = try m.addTile(.{ .designator = "Q", .prototype = key });
    try std.testing.expectError(error.DuplicateDesignator, m.addTile(.{ .designator = "Q" }));
    try std.testing.expectError(error.NoSuchPrototype, m.addTile(.{ .designator = "R", .prototype = 7 }));
    try m.place(p, r, null, .{ .what = .{ .tile = q } });
    const before = m.revision;
    try m.setContent(q, "top", "q");
    try std.testing.expect(m.revision > before);
    try std.testing.expectEqualStrings("q", m.slot(q, 0).content);
    try std.testing.expectError(error.NoSuchSlot, m.setContent(q, "front", "x"));
}

test "a prototype's sizing rules: which ways a tile grows, and to what" {
    const key: TilePrototype = .{ .name = "key", .widths = &.{ 1, 1.25, 2.25 }, .heights = &.{ 1, 2 } };
    try std.testing.expect(key.allows(1, 1));
    try std.testing.expect(key.allows(2.25, 2));
    try std.testing.expect(!key.allows(1.3, 1));
    try std.testing.expect(!key.allows(1, 3));
    // Growing only wider: any width, but one track high.
    const bar: TilePrototype = .{ .name = "bar", .expand = .{ .vertical = false } };
    try std.testing.expect(bar.allows(6.25, 1));
    try std.testing.expect(!bar.allows(1, 2));
    // Not growing at all: 1u × 1u only.
    const button: TilePrototype = .{ .name = "button", .expand = .{ .horizontal = false, .vertical = false } };
    try std.testing.expect(button.allows(1, 1));
    try std.testing.expect(!button.allows(1.25, 1));
}

test "a tile's slots are its prototype's, with its own labels and overrides" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const key = try m.addPrototype(.{ .name = "key", .slots = &.{
        .{ .name = "top", .style = 1, .place = .{ .inset = .all(1) } },
        .{ .name = "front", .style = 1 },
    } });
    const plain = try m.addPrototype(.{ .name = "plain" });
    const k = try m.addTile(.{ .designator = "K23", .prototype = key });

    // Addressed as the label content format writes it.
    try m.setContentAt("K23.top", "Q");
    try std.testing.expectEqual(SlotRef{ .tile = k, .slot = 0 }, m.findSlotPath("K23.top").?);
    try std.testing.expectEqual(null, m.findSlotPath("K23.side"));
    try std.testing.expectError(error.NoSuchTile, m.setContentAt("K99.top", "x"));

    // The prototype's style and place until the tile overrides one.
    try std.testing.expectEqual(1, m.slot(k, 0).style);
    try m.setSlotStyle(k, "top", 2);
    try std.testing.expectEqual(2, m.slot(k, 0).style);
    try std.testing.expectEqual(1, m.slot(k, 1).style);
    try m.setSlotStyle(k, "top", null);
    try std.testing.expectEqual(1, m.slot(k, 0).style);
    try std.testing.expectEqual(1, m.slot(k, 0).place.inset.left);

    // Changing the prototype's slot changes the tile's, where it has no own.
    var top = m.prototypes.items[key].slots[0];
    top.place.h = .centre;
    try m.setPrototypeSlot(key, 0, top);
    try std.testing.expectEqual(Align.centre, m.slot(k, 0).place.h);
    try std.testing.expectEqual(1, m.prototypeUses(key));

    // A slot added to the prototype appears on its tiles, empty.
    try m.addPrototypeSlot(key, .{ .name = "side" });
    try std.testing.expectEqual(3, m.slotCount(k));
    try std.testing.expectEqualStrings("", m.slot(k, 2).content);

    // Switched to a prototype without the slot and back, the label is kept.
    try m.setTilePrototype(k, plain);
    try std.testing.expectEqual(0, m.slotCount(k));
    try std.testing.expectError(error.NoSuchSlot, m.setContent(k, "top", "x"));
    try m.setTilePrototype(k, key);
    try std.testing.expectEqualStrings("Q", m.slot(k, 0).content);
}

test "a layer's paint changes; its outline does not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const look = try art_.keycap(arena.allocator(), .{
        .pitch = 19.05,
        .body_inset = .all(0.5),
        .face_inset = .all(3),
        .body = .{ .solid = .hex("#ffffff") },
        .edge = null,
        .face = .{ .solid = .hex("#eeeeee") },
    });
    const key = try m.addPrototype(.{ .name = "key", .art = look });
    const before = m.prototypes.items[key].art.?.layers[0].outline.contours.ptr;
    try m.setLayerPaint(key, 0, .{ .fill = .{ .solid = .hex("#202020") }, .edge = .hex("#000000") });
    const layer = m.prototypes.items[key].art.?.layers[0];
    try std.testing.expectEqual(art_.Color.hex("#202020"), layer.paint.fill.solid);
    try std.testing.expectEqual(before, layer.outline.contours.ptr);
    try std.testing.expectError(error.NoSuchLayer, m.setLayerPaint(key, 5, .{}));
    const plain = try m.addPrototype(.{ .name = "plain" });
    try std.testing.expectError(error.NoSuchLayer, m.setLayerPaint(plain, 0, .{}));
}

test "prototypes are duplicated, have slots renamed and removed, and are removed when unused" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const key = try m.addPrototype(.{ .name = "key", .face_inset = .all(2), .slots = &.{ .{ .name = "top" }, .{ .name = "front" } } });
    const k = try m.addTile(.{ .designator = "K1", .prototype = key });
    try m.setContent(k, "top", "A");

    // A copy is independent of its original.
    const wide = try m.duplicatePrototype(key, "wide key");
    try std.testing.expectEqualStrings("wide key", m.prototypes.items[wide].name);
    try std.testing.expectEqual(2, m.prototypes.items[wide].slots.len);
    try m.addPrototypeSlot(wide, .{ .name = "side" });
    try std.testing.expectEqual(2, m.prototypes.items[key].slots.len);
    try std.testing.expectError(error.DuplicateSlot, m.addPrototypeSlot(wide, .{ .name = "side" }));

    // A renamed slot keeps each tile's label.
    try m.renamePrototypeSlot(key, 0, "legend");
    try std.testing.expectEqualStrings("A", m.slot(k, 0).content);
    try std.testing.expectEqualStrings("legend", m.slot(k, 0).name);
    try std.testing.expectError(error.DuplicateSlot, m.renamePrototypeSlot(key, 0, "front"));

    // A removed slot hides its label; added back, it shows again.
    try m.removePrototypeSlot(key, 0);
    try std.testing.expectEqual(1, m.slotCount(k));
    try m.addPrototypeSlot(key, .{ .name = "legend" });
    try std.testing.expectEqualStrings("A", m.slot(k, 1).content);

    // Only an unused prototype goes; tiles of later ones follow them down.
    const spare = try m.addPrototype(.{ .name = "spare" });
    try m.setTilePrototype(k, spare);
    try std.testing.expectError(error.PrototypeInUse, m.removePrototype(spare));
    try m.removePrototype(key);
    try std.testing.expectEqual(spare - 1, m.tileConst(k).prototype);
    try std.testing.expectEqualStrings("spare", m.prototypeOf(k).name);
}

test "a prototype's smallest size and size step follow which way its tracks run" {
    const key: TilePrototype = .{ .name = "key", .widths = &.{ 1, 1.25, 1.5, 2.25, 6.25 }, .heights = &.{ 1, 2 } };
    try std.testing.expectEqual(1, key.smallest(.row, .along));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), key.step(.row, .along), 1e-9);
    try std.testing.expectEqual(1, key.step(.row, .across));
    // Columns run the other way: heights along, widths across.
    try std.testing.expectEqual(1, key.step(.column, .along));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), key.step(.column, .across), 1e-9);
    const bar: TilePrototype = .{ .name = "bar", .widths = &.{ 2, 3 }, .expand = .{ .vertical = false } };
    try std.testing.expectEqual(2, bar.smallest(.row, .along));
    try std.testing.expectEqual(1, bar.step(.row, .along));
    try std.testing.expectEqual(1, bar.step(.row, .across));
}

test "tracks are added empty; a removed tile leaves them" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key", .widths = &.{ 1, 1.5 }, .slots = &.{.{ .name = "top" }} });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 5, .y = 95 }, .prototype = key, .count = 2, .length = 4.5, .pitch = 19.05 });
    const region = m.panels.items[p].regions.items[r];
    try std.testing.expectEqual(4.5, region.w);
    try std.testing.expectEqual(2, region.h);
    try std.testing.expectEqual(2, region.segments.items.len);
    try std.testing.expectEqual(0, region.items.items.len);
    try std.testing.expectEqual(0, m.tiles.items.len);

    // Columns: as thick as the smallest width, as long as asked.
    const c = try m.addTracks(p, .{ .name = "side", .origin = .{ .x = 120, .y = 95 }, .major = .column, .prototype = key, .count = 3, .length = 2, .pitch = 19.05 });
    const side = m.panels.items[p].regions.items[c];
    try std.testing.expectEqual(3, side.w);
    try std.testing.expectEqual(2, side.h);
    try std.testing.expectError(error.BadSize, m.addTracks(p, .{ .name = "x", .origin = .{ .x = 0, .y = 0 }, .prototype = key, .count = 1, .length = 0.5, .pitch = 19.05 }));

    for (0..4) |i| _ = try m.insertTile(p, r, i, key, 1);
    const t1 = m.findTile("T1").?;
    m.removeTile(t1);
    try std.testing.expectEqual(null, m.findTile("T1"));
    try std.testing.expectEqual(3, m.panels.items[p].regions.items[r].items.items.len);
}

test "tiles, blanks, runs and breaks are inserted and removed in flow order" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key", .widths = &.{ 1, 1.25, 1.5 } });
    const r = try m.addTracks(p, .{ .name = "keys", .origin = .{ .x = 5, .y = 95 }, .prototype = key, .count = 1, .length = 2, .pitch = 19.05 });
    _ = try m.insertTile(p, r, 0, key, 1);
    _ = try m.insertTile(p, r, 1, key, 1);
    // T1 T2; insert a 1.5 u tile between them, and a blank before it.
    const t = try m.insertTile(p, r, 1, key, 1.5);
    try m.insertBlank(p, r, 1, 0.25);
    const items = m.panels.items[p].regions.items[r].items.items;
    try std.testing.expectEqual(4, items.len);
    try std.testing.expectEqual(null, items[1].tileOf());
    try std.testing.expectEqual(0.25, items[1].what.blank);
    try std.testing.expectEqual(t, items[2].tileOf().?);
    try std.testing.expectEqualStrings("T3", m.tileConst(t).designator);
    try std.testing.expectEqual(1.5, m.tileConst(t).w);
    // Removing the blank, then the tile.
    try m.removeAt(p, r, 1);
    try m.removeAt(p, r, 1);
    const left = m.panels.items[p].regions.items[r].items.items;
    try std.testing.expectEqual(2, left.len);
    try std.testing.expectEqual(null, m.findTile("T3"));
    try std.testing.expectError(error.NoSuchItem, m.removeAt(p, r, 5));
    // A new tile takes the lowest free designator.
    _ = try m.insertTile(p, r, 0, key, 1);
    try std.testing.expect(m.findTile("T3") != null);
    // Text and equations share the flow with the tiles, and a hard break
    // goes between any two items.
    try m.insertRun(p, r, 1, .{ .content = "x = \\frac{1}{2}" });
    try m.insertBreak(p, r, 2);
    const mixed = m.panels.items[p].regions.items[r].items.items;
    try std.testing.expectEqual(5, mixed.len);
    try std.testing.expectEqualStrings("x = \\frac{1}{2}", mixed[1].what.run.content);
    try std.testing.expect(mixed[2].what == .hard_break);
    try m.setRunContent(p, r, 1, "word");
    try std.testing.expectEqualStrings("word", m.panels.items[p].regions.items[r].items.items[1].what.run.content);
    try std.testing.expectError(error.NoSuchItem, m.setRunContent(p, r, 0, "x"));
}
