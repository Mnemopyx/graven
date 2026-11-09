//! The panel model: inputs only. Positions, boxes and rendered labels come
//! from `place.solve`, so the model stays the single source of truth.
//!
//! A panel holds regions, each a track: one flow of items (tiles, blanks,
//! runs of text or equations, hard breaks) poured through a list of
//! segments (rows or columns) at a pitch. A tile thicker than its segment
//! reaches into the ones after it, and their content flows around it. Each tile
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
    /// Its unit, mm per u (19.05 for PC keys): tile sizes are in it, so a
    /// tile keeps its size in any track, a text track included. Null takes
    /// the pitch of the track it is in.
    unit: ?f64 = null,
    /// Its tiles are spacers: no art and no labels, shown faintly while
    /// editing and left out of output (the built-in Blank prototype).
    spacer: bool = false,
    /// What happens to one of its tiles that lands at the start of a
    /// segment after a soft break: kept (blanks, like a keyboard's gaps), or
    /// dropped (a space between words).
    at_soft_break: enum { keep, drop } = .keep,
    /// Its tiles are letters (an illuminated initial, a symbol in a
    /// legend): one binds to the item after it when that is not a break,
    /// space or blank, so it stays with the rest of its word.
    letter: bool = false,
    /// Where its tiles' baseline lies, u above their bottom edge: in a row
    /// a tile is then set on the row's text baseline, and what reaches
    /// below the row (a drop cap) closes that stretch of the rows after.
    /// Null sets tiles from the row's top.
    baseline: ?f64 = null,

    /// mm per u for its tiles in a track of pitch `track_pitch`.
    pub fn unitIn(p: TilePrototype, track_pitch: f64) f64 {
        return p.unit orelse track_pitch;
    }

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
/// equations share one stream: a tile of any prototype (a blank is a tile
/// of the built-in Blank prototype), a run of markup, or a hard break,
/// which ends its segment so the next item starts the next one.
pub const Item = struct {
    gap: f64 = 0,
    /// No break between this item and the next: they belong to one group
    /// (the arrow cluster, a modifier with its key), which breaks as one
    /// while its items stay their own. A hard break is never bound.
    bind: bool = false,
    what: union(enum) {
        tile: TileId,
        run: Run,
        hard_break,
    },

    /// Whether this item and `next`, which follows it, are in one group.
    pub fn binds(item: Item, next: Item) bool {
        return item.bind and item.what != .hard_break and next.what != .hard_break;
    }

    pub fn tileOf(item: Item) ?TileId {
        return switch (item.what) {
            .tile => |id| id,
            else => null,
        };
    }
};

/// A segment's origin: one row, or one column, of a track, by where its
/// start corner sits, u from the region's origin: `along` the track's
/// length, and `across` it (down for rows, right for columns).
///
/// A track's segments lie on a path through their origins, in order. The
/// path is straight pieces between origins and carries on past the last
/// one in the direction of its last piece (across, at first); each new
/// segment goes one segment's thickness plus the track's gap along it.
pub const Segment = struct {
    along: f64 = 0,
    across: f64 = 0,

    /// The point `d` u along the direction (`dir_along`, `dir_across`).
    pub fn step(s: Segment, dir: [2]f64, d: f64) Segment {
        return .{ .along = s.along + dir[0] * d, .across = s.across + dir[1] * d };
    }
};

/// The path's direction from origin `prev` to `last`: a unit vector, or
/// straight across when there is no piece yet (or it has no length).
pub fn pathDirection(prev: ?Segment, last: Segment) [2]f64 {
    const p = prev orelse return .{ 0, 1 };
    const da = last.along - p.along;
    const dc = last.across - p.across;
    const len = @sqrt(da * da + dc * dc);
    if (len < 1e-9) return .{ 0, 1 };
    return .{ da / len, dc / len };
}

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
    /// The text style it was sized to, if any: its segments are one line
    /// pitch thick (the pitch is the style's baseline-to-baseline distance
    /// when the region was made), and new runs in it take the style.
    style: ?StyleId = null,
    /// Its segments' origins, in order, as far as they have been placed:
    /// the first, and any moved by hand (with those before it). The rest
    /// continue the path as the flow needs them (see `Segment`); the
    /// region's `w` × `h` is the soft area they expand into, and segments
    /// past it are flagged.
    segments: std.ArrayList(Segment) = .empty,
    /// Space between segments the path continues to, u.
    gap: f64 = 0,
    /// How each segment's content is set in it: from its start, about its
    /// centre, or back from its end. (Its origin places the segment; this
    /// only arranges what is in it.)
    alignment: Align = .start,
    /// The length of the blank put in after each hard break as it is
    /// entered, so a new paragraph starts indented, u; 0 for none. The blank
    /// is an ordinary item: it can be resized or removed.
    indent: f64 = 0,
    /// The flow, in order. A tile thicker than its segment (a 2 u tall
    /// key) reaches into the segments after it, closing the stretch it
    /// covers there; their content flows around it.
    items: std.ArrayList(Item) = .empty,

    /// A segment's length, u.
    pub fn segmentLength(r: TileRegion) f64 {
        return if (r.major == .row) r.w else r.h;
    }

    /// The origin after `last` (with `prev` before it) on the path, before
    /// any skip past a blocked place.
    pub fn nextOrigin(r: TileRegion, prev: ?Segment, last: Segment) Segment {
        return last.step(pathDirection(prev, last), 1 + r.gap);
    }

    /// The band of a segment at origin `s`, mm in the panel frame: its
    /// length along, one pitch across.
    pub fn boxAt(r: TileRegion, s: Segment) geom.Box {
        const across = s.across * r.pitch;
        const shift = s.along * r.pitch;
        const length = r.segmentLength() * r.pitch;
        return if (r.major == .row)
            .{ .x0 = r.origin.x + shift, .x1 = r.origin.x + shift + length, .y1 = r.origin.y - across, .y0 = r.origin.y - across - r.pitch }
        else
            .{ .x0 = r.origin.x + across, .x1 = r.origin.x + across + r.pitch, .y1 = r.origin.y - shift, .y0 = r.origin.y - shift - length };
    }

    /// Stored segment `t`'s band (see `boxAt`).
    pub fn segmentBox(r: TileRegion, t: usize) geom.Box {
        return r.boxAt(r.segments.items[t]);
    }

    /// The soft area its segments expand into, mm in the panel frame.
    pub fn softArea(r: TileRegion) geom.Box {
        return .{ .x0 = r.origin.x, .x1 = r.origin.x + r.w * r.pitch, .y1 = r.origin.y, .y0 = r.origin.y - r.h * r.pitch };
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

/// How an object on a panel makes the tracks under it flow: not at all,
/// around its bounding box, or around its ink (the exact outline of its
/// marks), either grown by its clearance.
pub const Wrap = enum { none, bounds, ink };

/// Line art placed on a panel: shapes in its own frame, set at `at`.
pub const PanelArt = struct {
    name: []const u8,
    /// Where its frame's origin sits, mm in the panel frame.
    at: geom.Point,
    /// Its shapes, back to front, mm in its own frame (y up).
    shapes: []const art_.Shape,
    /// Whether what it lies over flows around it, and how.
    wrap: Wrap = .ink,
    /// Whether the tracks under it flow around it. When not, their tiles
    /// stay under it, and only labels (a key's legend) wrap around it.
    wrap_tracks: bool = true,
    /// Space kept between it and the content flowing around it, mm.
    clearance: f64 = 1,

    /// Its shapes' bounds, mm in the panel frame.
    pub fn box(p: PanelArt) geom.Box {
        var b: geom.Box = .empty;
        for (p.shapes) |s| b = b.join(s.outline.bounds());
        if (b.isEmpty()) return b;
        return .{ .x0 = b.x0 + p.at.x, .x1 = b.x1 + p.at.x, .y0 = b.y0 + p.at.y, .y1 = b.y1 + p.at.y };
    }
};

/// A space: the canvas, or a frame. Each has its own coordinates, an
/// unbounded panel (`root`) holding its loose objects, its panels (those
/// whose `space` is it), and its selection groups.
pub const Space = struct {
    name: []const u8,
    /// True while the name is one the app gave it (Frame 1).
    default_name: bool = false,
    /// The panel holding the space's loose objects.
    root: usize,
    /// The frame's boundary in its own coordinates, mm; null for the canvas,
    /// which has none. Content past it is flagged, not refused.
    bound: ?geom.Box = null,
    groups: std.ArrayList(Group) = .empty,
};

/// An object in a space, as a selection names it: a panel, or one of a
/// panel's labels, tracks (regions) or line art, by index.
pub const Member = union(enum) {
    panel: usize,
    label: struct { panel: usize, index: usize },
    region: struct { panel: usize, index: usize },
    art: struct { panel: usize, index: usize },
};

/// A selection group: objects of one space treated as one. Members are
/// held by index, so removing an object from the space dissolves the
/// space's groups (a limit until objects have lasting IDs).
pub const Group = struct {
    name: []const u8,
    members: std.ArrayList(Member) = .empty,
};

pub const Panel = struct {
    name: []const u8,
    /// True while the name is one the app gave it (Panel 1), not the user.
    default_name: bool = false,
    /// A space's own panel: it holds the space's loose objects, with no
    /// outline, margins or sheet to keep to (see `Model.startCanvas` and
    /// `Model.addFrame`).
    unbounded: bool = false,
    /// The space (the canvas, or a frame) the panel lives in; its origin
    /// is in that space's coordinates.
    space: usize = 0,
    /// Where the panel's frame origin (its bottom-left corner) sits on the
    /// worksheet, mm.
    origin: geom.Point = .{ .x = 0, .y = 0 },
    /// Outline size, mm; the frame's origin is the bottom-left corner.
    w: f64,
    h: f64,
    regions: std.ArrayList(TileRegion) = .empty,
    labels: std.ArrayList(PanelLabel) = .empty,
    /// Line art placed on the panel, drawn over its tracks.
    art: std.ArrayList(PanelArt) = .empty,
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
    /// A thousandth of an inch, 25.4 µm.
    mil,

    pub fn perMm(u: Units) f64 {
        return switch (u) {
            .mm => 1,
            .inch => 1.0 / 25.4,
            .mil => 1000.0 / 25.4,
        };
    }

    pub fn symbol(u: Units) []const u8 {
        return switch (u) {
            .mm => "mm",
            .inch => "in",
            .mil => "mil",
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
    /// Whether the document has a sheet: false for a canvas started with
    /// `startCanvas`, where work is drafted without one.
    has_sheet: bool = true,
    /// The document's units, chosen when its canvas was made: how lengths
    /// are shown and typed outside a sheet. Lengths are stored in mm.
    units: Units = .mm,
    /// The canvas (space 0) and the frames, once the document is a canvas.
    spaces: std.ArrayList(Space) = .empty,
    panels: std.ArrayList(Panel) = .empty,
    tiles: std.ArrayList(Tile) = .empty,
    prototypes: std.ArrayList(TilePrototype) = .empty,
    /// The built-in Blank prototype, once a blank has been made.
    blank_prototype: ?PrototypeId = null,
    styles: std.ArrayList(LabelStyle) = .empty,
    /// Bumped by every action, so callers can tell when to re-solve.
    revision: u64 = 0,

    pub const Error = Allocator.Error || error{ NoRoom, DuplicateDesignator, NoSuchPrototype, NoSuchTile, NoSuchSlot, NoSuchLayer, DuplicateSlot, PrototypeInUse, NoSuchRow, NoSuchItem, NoSuchStyle, BadSize, OffSheet, NotCompliant };

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

    /// Starts an empty document as a canvas: an open drafting space in
    /// `units`, with no sheet, its loose objects held by one unbounded
    /// panel at the origin. Returns that panel's index.
    pub fn startCanvas(m: *Model, units: Units) Error!usize {
        if (m.panels.items.len > 0) return error.NoRoom;
        m.units = units;
        m.has_sheet = false;
        const root = try m.addRoot("Canvas", 0);
        try m.spaces.append(m.a(), .{ .name = "Canvas", .root = root });
        return root;
    }

    fn addRoot(m: *Model, name: []const u8, space: usize) Error!usize {
        try m.panels.append(m.a(), .{ .name = name, .unbounded = true, .space = space, .w = 0, .h = 0, .margins = .all(0), .default_margins = false });
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// The canvas's own panel, holding its loose objects, if the document
    /// is a canvas.
    pub fn canvas(m: *const Model) ?usize {
        if (m.spaces.items.len == 0) return null;
        return m.spaces.items[0].root;
    }

    /// Adds a frame: a space of its own, with `bound` (its own coordinates,
    /// mm) or none yet. Returns its index among the spaces.
    pub fn addFrame(m: *Model, name: []const u8, edge: ?geom.Box) Error!usize {
        if (m.spaces.items.len == 0) return error.NoRoom;
        if (edge) |b| if (!(b.width() > 0 and b.height() > 0)) return error.BadSize;
        const sid = m.spaces.items.len;
        const owned = try m.a().dupe(u8, name);
        const root = try m.addRoot(owned, sid);
        try m.spaces.append(m.a(), .{ .name = owned, .root = root, .bound = edge });
        return sid;
    }

    /// Sets a frame's boundary, as Fit frame does with its contents'
    /// extents plus a margin.
    pub fn setFrameBound(m: *Model, space: usize, edge: geom.Box) Error!void {
        if (space == 0 or space >= m.spaces.items.len) return error.NoSuchItem;
        if (!(edge.width() > 0 and edge.height() > 0)) return error.BadSize;
        m.spaces.items[space].bound = edge;
        m.revision += 1;
    }

    /// The space a panel lives in.
    pub fn spaceOf(m: *const Model, panel: usize) usize {
        return m.panels.items[panel].space;
    }

    /// The first "<prefix> N" not yet used as a space name.
    pub fn nextFrameName(m: *const Model, buf: []u8, prefix: []const u8) []const u8 {
        var n: usize = m.spaces.items.len;
        while (true) : (n += 1) {
            const name = std.fmt.bufPrint(buf, "{s} {d}", .{ prefix, n }) catch return prefix;
            for (m.spaces.items) |sp| {
                if (std.mem.eql(u8, sp.name, name)) break;
            } else return name;
        }
    }

    /// Moves `members` (all of one space) into space `dest`, keeping their
    /// coordinates: panels change space, and loose labels, tracks and line
    /// art move to `dest`'s own panel. They arrive as one selection group
    /// named "from <source>". Returns the group's index in `dest`. (Once
    /// constraints exist, the members' constraint group comes too, and
    /// constraints reaching outside it are dropped and listed.)
    pub fn moveToSpace(m: *Model, members: []const Member, dest: usize) Error!usize {
        return m.transfer(members, dest, false);
    }

    /// As `moveToSpace`, with copies: the originals stay where they were.
    pub fn copyToSpace(m: *Model, members: []const Member, dest: usize) Error!usize {
        return m.transfer(members, dest, true);
    }

    fn transfer(m: *Model, members: []const Member, dest: usize, copy: bool) Error!usize {
        if (dest >= m.spaces.items.len or members.len == 0) return error.NoSuchItem;
        const from = m.spaceOf(memberPanel(members[0]));
        for (members) |mb| if (m.spaceOf(memberPanel(mb)) != from) return error.NoSuchItem;
        if (from == dest and !copy) return error.NoSuchItem;
        const droot = m.spaces.items[dest].root;
        var name_buf: [96]u8 = undefined;
        const gname = std.fmt.bufPrint(&name_buf, "from {s}", .{m.spaces.items[from].name}) catch "moved";
        var group: Group = .{ .name = try m.a().dupe(u8, gname) };
        // Loose objects first, taken from the back so earlier indices hold;
        // then panels, which keep their indices.
        var order: std.ArrayList(Member) = .empty;
        try order.appendSlice(m.a(), members);
        std.mem.sort(Member, order.items, {}, struct {
            fn later(_: void, x: Member, y: Member) bool {
                return looseIndex(x) > looseIndex(y);
            }
        }.later);
        for (order.items) |mb| switch (mb) {
            .label => |l| {
                const src = &m.panels.items[l.panel].labels;
                var item = src.items[l.index];
                if (!copy) _ = src.orderedRemove(l.index) else item.content = try m.a().dupe(u8, item.content);
                try m.panels.items[droot].labels.append(m.a(), item);
                try group.members.append(m.a(), .{ .label = .{ .panel = droot, .index = m.panels.items[droot].labels.items.len - 1 } });
            },
            .art => |l| {
                const src = &m.panels.items[l.panel].art;
                var item = src.items[l.index];
                if (!copy) _ = src.orderedRemove(l.index) else item.shapes = try art_.dupeShapes(m.a(), item.shapes, .{ .x = 0, .y = 0 });
                try m.panels.items[droot].art.append(m.a(), item);
                try group.members.append(m.a(), .{ .art = .{ .panel = droot, .index = m.panels.items[droot].art.items.len - 1 } });
            },
            .region => |l| {
                const src = &m.panels.items[l.panel].regions;
                const item = if (copy) try m.copyRegion(src.items[l.index]) else src.orderedRemove(l.index);
                try m.panels.items[droot].regions.append(m.a(), item);
                try group.members.append(m.a(), .{ .region = .{ .panel = droot, .index = m.panels.items[droot].regions.items.len - 1 } });
            },
            .panel => |pi| {
                const target = if (copy) try m.copyPanel(pi) else pi;
                m.panels.items[target].space = dest;
                try group.members.append(m.a(), .{ .panel = target });
            },
        };
        // What was taken out of the source may have shifted its groups.
        if (!copy) m.spaces.items[from].groups.clearRetainingCapacity();
        try m.spaces.items[dest].groups.append(m.a(), group);
        m.revision += 1;
        return m.spaces.items[dest].groups.items.len - 1;
    }

    fn memberPanel(mb: Member) usize {
        return switch (mb) {
            .panel => |pi| pi,
            inline else => |l| l.panel,
        };
    }

    /// Sorting key: loose objects by index (removed back to front), panels
    /// last.
    fn looseIndex(mb: Member) usize {
        return switch (mb) {
            .panel => 0,
            inline else => |l| l.index + 1,
        };
    }

    /// A copy of a track, with copies of its tiles (new designators).
    fn copyRegion(m: *Model, r: TileRegion) Error!TileRegion {
        var c = r;
        c.name = try m.a().dupe(u8, r.name);
        c.segments = .empty;
        try c.segments.appendSlice(m.a(), r.segments.items);
        c.items = .empty;
        for (r.items.items) |item| {
            var it = item;
            switch (item.what) {
                .tile => |id| {
                    const t = m.tileConst(id);
                    var buf: [64]u8 = undefined;
                    const prefix = if (m.prototypes.items[t.prototype].spacer) "B" else "T";
                    var copy_t = t.*;
                    copy_t.designator = m.nextDesignator(&buf, prefix);
                    it.what = .{ .tile = try m.addTile(copy_t) };
                },
                .run => |run| it.what.run.content = try m.a().dupe(u8, run.content),
                .hard_break => {},
            }
            try c.items.append(m.a(), it);
        }
        return c;
    }

    /// A copy of a panel, appended, with copies of its content. Returns it.
    fn copyPanel(m: *Model, pi: usize) Error!usize {
        const p = m.panels.items[pi];
        var c = p;
        c.name = try m.a().dupe(u8, p.name);
        c.regions = .empty;
        c.labels = .empty;
        c.art = .empty;
        for (p.regions.items) |r| try c.regions.append(m.a(), try m.copyRegion(r));
        for (p.labels.items) |l| {
            var cl = l;
            cl.content = try m.a().dupe(u8, l.content);
            try c.labels.append(m.a(), cl);
        }
        for (p.art.items) |pa| {
            var ca = pa;
            ca.shapes = try art_.dupeShapes(m.a(), pa.shapes, .{ .x = 0, .y = 0 });
            try c.art.append(m.a(), ca);
        }
        try m.panels.append(m.a(), c);
        return m.panels.items.len - 1;
    }

    /// Moves every member of a space's group by (`dx`, `dy`) mm.
    pub fn moveGroup(m: *Model, space: usize, group: usize, dx: f64, dy: f64) Error!void {
        if (space >= m.spaces.items.len or group >= m.spaces.items[space].groups.items.len) return error.NoSuchItem;
        for (m.spaces.items[space].groups.items[group].members.items) |mb| switch (mb) {
            .panel => |pi| {
                const o = &m.panels.items[pi].origin;
                o.* = .{ .x = o.x + dx, .y = o.y + dy };
            },
            .label => |l| {
                const at = &m.panels.items[l.panel].labels.items[l.index].at;
                at.* = .{ .x = at.x + dx, .y = at.y + dy };
            },
            .art => |l| {
                const at = &m.panels.items[l.panel].art.items[l.index].at;
                at.* = .{ .x = at.x + dx, .y = at.y + dy };
            },
            .region => |l| {
                const o = &m.panels.items[l.panel].regions.items[l.index].origin;
                o.* = .{ .x = o.x + dx, .y = o.y + dy };
            },
        };
        m.revision += 1;
    }

    /// Dissolves a group; its members stay where they are.
    pub fn ungroup(m: *Model, space: usize, group: usize) void {
        _ = m.spaces.items[space].groups.orderedRemove(group);
        m.revision += 1;
    }

    /// Removing objects shifts indices: the groups of every space are
    /// dissolved (their members stay).
    fn dissolveGroups(m: *Model) void {
        for (m.spaces.items) |*sp| sp.groups.clearRetainingCapacity();
    }

    /// Changes the canvas's units: a conversion, so nothing moves or
    /// resizes; only how lengths are shown and typed changes.
    pub fn setCanvasUnits(m: *Model, units: Units) void {
        m.units = units;
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
        if (!m.has_sheet or m.panels.items[panel].unbounded) return true;
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
    /// Places line art on a panel; returns its index there.
    pub fn addArt(m: *Model, panel: usize, art: PanelArt) Error!usize {
        if (!(art.clearance >= 0)) return error.BadSize;
        var copy = art;
        copy.name = try m.a().dupe(u8, art.name);
        copy.shapes = try art_.dupeShapes(m.a(), art.shapes, .{ .x = 0, .y = 0 });
        const list = &m.panels.items[panel].art;
        try list.append(m.a(), copy);
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Moves line art to `at` (panel frame, mm): what flows around it
    /// reflows.
    pub fn moveArt(m: *Model, panel: usize, index: usize, at: geom.Point) Error!void {
        const list = m.panels.items[panel].art.items;
        if (index >= list.len) return error.NoSuchItem;
        list[index].at = at;
        m.revision += 1;
    }

    /// Sets how what line art lies over flows around it.
    pub fn setArtWrap(m: *Model, panel: usize, index: usize, wrap: Wrap, clearance: f64) Error!void {
        const list = m.panels.items[panel].art.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!(clearance >= 0)) return error.BadSize;
        list[index].wrap = wrap;
        list[index].clearance = clearance;
        m.revision += 1;
    }

    /// Sets whether the tracks under line art flow around it (else only
    /// labels do).
    pub fn setArtWrapsTracks(m: *Model, panel: usize, index: usize, on: bool) Error!void {
        const list = m.panels.items[panel].art.items;
        if (index >= list.len) return error.NoSuchItem;
        list[index].wrap_tracks = on;
        m.revision += 1;
    }

    pub fn removeArt(m: *Model, panel: usize, index: usize) void {
        _ = m.panels.items[panel].art.orderedRemove(index);
        m.dissolveGroups();
        m.revision += 1;
    }

    pub fn removeLabel(m: *Model, panel: usize, label: usize) void {
        _ = m.panels.items[panel].labels.orderedRemove(label);
        m.dissolveGroups();
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
        // Spaces' own panels follow the renumbering.
        for (m.spaces.items) |*sp| if (sp.root > panel) {
            sp.root -= 1;
        };
        m.dissolveGroups();
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
        if (!m.has_sheet) return origin;
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
        // With no sheet, there is nothing to keep a grip on.
        if (!m.has_sheet) return true;
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
        if (!m.has_sheet) return true;
        return within(b, m.sheet.box());
    }

    /// The first "<prefix> N" not yet used as a panel name.
    pub fn nextPanelName(m: *const Model, buf: []u8, prefix: []const u8) []const u8 {
        // Spaces' own panels are not counted.
        var n: usize = 1;
        for (m.panels.items) |p| {
            if (!p.unbounded) n += 1;
        }
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
        /// What sizes the segments: a tile prototype (as thick as its
        /// smallest tile, as long as one at least), or a text style (one
        /// line thick at `pitch`, its line pitch). One of the two.
        prototype: ?PrototypeId = null,
        style: ?StyleId = null,
        /// How many segments the soft area holds, and each one's length, u.
        count: usize,
        length: f64,
        pitch: f64,
    };

    /// Adds a track sized to a prototype or a text style (see `Tracks`):
    /// its first segment, and a soft area `count` segments thick for the
    /// rest to expand into. The user adds the content. Returns the region's
    /// index.
    pub fn addTracks(m: *Model, panel: usize, t: Tracks) Error!usize {
        var along: f64 = 0;
        var across: f64 = 1;
        if (t.prototype) |pid| {
            if (pid >= m.prototypes.items.len) return error.NoSuchPrototype;
            const proto = m.prototypes.items[pid];
            along = proto.smallest(t.major, .along);
            across = proto.smallest(t.major, .across);
        } else if (t.style) |sid| {
            if (sid >= m.styles.items.len) return error.NoSuchStyle;
        } else return error.NoSuchPrototype;
        if (t.count == 0 or !(t.length > 0) or !(t.length >= along - 1e-9)) return error.BadSize;
        const thickness = @as(f64, @floatFromInt(t.count)) * across;
        const r = try m.addRegion(panel, .{
            .name = t.name,
            .origin = t.origin,
            .w = if (t.major == .row) t.length else thickness,
            .h = if (t.major == .row) thickness else t.length,
            .pitch = t.pitch,
            .major = t.major,
            .prototype = t.prototype,
            .style = t.style,
        });
        // The first segment; the rest come as the flow needs them, within
        // the soft area `count` segments thick.
        _ = try m.addSegment(panel, r, 0);
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

    /// Whether flow item `k` and the one after it are in one group: bound
    /// by hand (see `Item.bind`), or a letter tile followed by anything but
    /// a break, a space or a blank (see `TilePrototype.letter`).
    pub fn bound(m: *const Model, items: []const Item, k: usize) bool {
        if (k + 1 >= items.len) return false;
        const item = items[k];
        const next = items[k + 1];
        if (item.binds(next)) return true;
        const id = item.tileOf() orelse return false;
        if (!m.prototypes.items[m.tileConst(id).prototype].letter) return false;
        return switch (next.what) {
            .hard_break => false,
            .run => true,
            .tile => |nid| blk: {
                const np = m.prototypes.items[m.tileConst(nid).prototype];
                break :blk !np.spacer;
            },
        };
    }

    /// The built-in Blank prototype, made the first time it is asked for:
    /// a spacer of any size, kept at soft breaks, in its track's unit.
    pub fn blankPrototype(m: *Model) Error!PrototypeId {
        if (m.blank_prototype) |id| return id;
        // Tiles default to prototype 0: keep that a plain one, not Blank.
        if (m.prototypes.items.len == 0) _ = try m.addPrototype(.{ .name = "Plain" });
        const id = try m.addPrototype(.{
            .name = "Blank",
            .expand = .{ .horizontal = true, .vertical = true },
            .spacer = true,
        });
        m.blank_prototype = id;
        return id;
    }

    /// Inserts a blank, a tile of the built-in Blank prototype, `length` u
    /// long (in the track's unit) at position `index` of a track. Returns it.
    pub fn insertBlank(m: *Model, panel: usize, region: usize, index: usize, length: f64) Error!TileId {
        if (!(length > 0)) return error.BadSize;
        if (index > m.flow(panel, region).items.len) return error.NoSuchItem;
        const blank = try m.blankPrototype();
        const major = m.panels.items[panel].regions.items[region].major;
        var buf: [64]u8 = undefined;
        const id = try m.addTile(.{
            .designator = m.nextDesignator(&buf, "B"),
            .prototype = blank,
            .w = if (major == .row) length else 1,
            .h = if (major == .row) 1 else length,
        });
        try m.place(panel, region, index, .{ .what = .{ .tile = id } });
        return id;
    }

    /// Inserts a hard break at position `index` of a track: what follows
    /// starts the next segment. With the track's indent set, a blank that
    /// long follows it. Returns how many items went in (1, or 2).
    pub fn insertBreak(m: *Model, panel: usize, region: usize, index: usize) Error!usize {
        try m.place(panel, region, index, .{ .what = .hard_break });
        const indent = m.panels.items[panel].regions.items[region].indent;
        if (!(indent > 0)) return 1;
        _ = try m.insertBlank(panel, region, index + 1, indent);
        return 2;
    }

    /// Joins item `index` of a track to the next one, or parts them: with
    /// `bind`, no break falls between them, so they move as one group.
    pub fn setBind(m: *Model, panel: usize, region: usize, index: usize, bind: bool) Error!void {
        const items = m.flow(panel, region).items;
        if (index + 1 >= items.len) return error.NoSuchItem;
        items[index].bind = bind;
        m.revision += 1;
    }

    /// Sets how a track's segments hold their content: its alignment, the
    /// indent after hard breaks (u), and the gap between segments the path
    /// continues to (u).
    pub fn setTrackFlow(m: *Model, panel: usize, region: usize, alignment: Align, indent: f64, gap: f64) Error!void {
        if (!(indent >= 0) or !(gap >= 0)) return error.BadSize;
        const r = &m.panels.items[panel].regions.items[region];
        r.alignment = alignment;
        r.indent = indent;
        r.gap = gap;
        m.revision += 1;
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
    /// `across` u across (down for a row, right for a column), either way:
    /// its origin moves, and the path bends through it, so the segments the
    /// path continues to after it follow. `solved` is the region's segment
    /// origins as last placed (see `place.PlacedTrack`): those up to this
    /// one are kept from now on. It may move past its region or panel
    /// (flagged when placed), but not onto any box in `avoid` (the other
    /// segments on the panel): that is refused with `NoRoom`.
    pub fn moveSegment(m: *Model, panel: usize, region: usize, segment: usize, solved: []const Segment, along: f64, across: f64, avoid: []const geom.Box) Error!void {
        const r = &m.panels.items[panel].regions.items[region];
        if (segment >= solved.len and segment >= r.segments.items.len) return error.NoSuchRow;
        const here = if (segment < r.segments.items.len) r.segments.items[segment] else solved[segment];
        const target: Segment = .{ .along = here.along + along, .across = here.across + across };
        const box = r.boxAt(target);
        for (avoid) |b| if (overlaps(box, b)) return error.NoRoom;
        // Keep the origins up to this one, as placed, so the path bends here.
        while (r.segments.items.len <= segment) try r.segments.append(m.a(), solved[r.segments.items.len]);
        r.segments.items[segment] = target;
        m.revision += 1;
    }

    /// Drops kept origins past the first `count` segments, which the flow
    /// no longer reaches: a segment left empty at the end goes. One stays.
    pub fn trimSegments(m: *Model, panel: usize, region: usize, count: usize) void {
        const segs = &m.panels.items[panel].regions.items[region].segments;
        const keep = @max(1, count);
        if (segs.items.len <= keep) return;
        segs.shrinkRetainingCapacity(keep);
        m.revision += 1;
    }

    /// Removes tile `id`: it leaves every track it is in, which reflows.
    pub fn removeTile(m: *Model, id: TileId) void {
        m.unplace(id);
        m.tile(id).removed = true;
        m.revision += 1;
    }

    /// Keeps one more segment origin, continuing the path with `gap` u of
    /// extra space before it (the first sits at the region's origin), as a
    /// sample laying out rows does. Returns its index.
    pub fn addSegment(m: *Model, panel: usize, region: usize, gap: f64) Error!usize {
        const r = &m.panels.items[panel].regions.items[region];
        const segs = &r.segments;
        const n = segs.items.len;
        const next: Segment = if (n == 0) .{} else blk: {
            const last = segs.items[n - 1];
            const prev = if (n >= 2) segs.items[n - 2] else null;
            break :blk last.step(pathDirection(prev, last), 1 + gap);
        };
        try segs.append(m.a(), next);
        m.revision += 1;
        return n;
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
        // Regions made for it, and the built-in Blank, follow the renumbering.
        for (m.panels.items) |*panel| for (panel.regions.items) |*r| if (r.prototype) |rp| {
            r.prototype = if (rp == id) null else if (rp > id) rp - 1 else rp;
        };
        if (m.blank_prototype) |b| m.blank_prototype = if (b == id) null else if (b > id) b - 1 else b;
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
    // One segment to start; the rest come as the flow needs them.
    try std.testing.expectEqual(1, region.segments.items.len);
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
    const b = try m.insertBlank(p, r, 1, 0.25);
    const items = m.panels.items[p].regions.items[r].items.items;
    try std.testing.expectEqual(4, items.len);
    // A blank is a tile of the built-in Blank prototype.
    try std.testing.expectEqual(b, items[1].tileOf().?);
    try std.testing.expectEqual(0.25, m.tileConst(b).w);
    try std.testing.expectEqualStrings("B1", m.tileConst(b).designator);
    try std.testing.expect(m.prototypes.items[m.tileConst(b).prototype].spacer);
    try std.testing.expectEqual(m.blank_prototype.?, try m.blankPrototype());
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
    _ = try m.insertBreak(p, r, 2);
    const mixed = m.panels.items[p].regions.items[r].items.items;
    try std.testing.expectEqual(5, mixed.len);
    try std.testing.expectEqualStrings("x = \\frac{1}{2}", mixed[1].what.run.content);
    try std.testing.expect(mixed[2].what == .hard_break);
    try m.setRunContent(p, r, 1, "word");
    try std.testing.expectEqualStrings("word", m.panels.items[p].regions.items[r].items.items[1].what.run.content);
    try std.testing.expectError(error.NoSuchItem, m.setRunContent(p, r, 0, "x"));
}

test "tracks sized to a text style are one line pitch thick, and keep the style" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 3 });
    // A 4.2 mm line pitch (the caller measures it from the style's font).
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 5, .y = 95 }, .style = body, .count = 3, .length = 20, .pitch = 4.2 });
    const region = m.panels.items[p].regions.items[r];
    try std.testing.expectEqual(body, region.style.?);
    try std.testing.expectEqual(null, region.prototype);
    try std.testing.expectEqual(20, region.w);
    try std.testing.expectEqual(3, region.h);
    try std.testing.expectApproxEqAbs(@as(f64, 4.2), region.boxAt(.{ .across = 1 }).height(), 1e-9);
    try std.testing.expectError(error.NoSuchStyle, m.addTracks(p, .{ .name = "x", .origin = .{ .x = 0, .y = 0 }, .style = 9, .count = 1, .length = 2, .pitch = 4 }));
    try std.testing.expectError(error.NoSuchPrototype, m.addTracks(p, .{ .name = "x", .origin = .{ .x = 0, .y = 0 }, .count = 1, .length = 2, .pitch = 4 }));
}

test "a canvas: units chosen up front, no sheet, loose objects on an unbounded panel" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c = try m.startCanvas(.mil);
    try std.testing.expectEqual(c, m.canvas().?);
    try std.testing.expectEqual(Units.mil, m.units);
    try std.testing.expect(!m.has_sheet);
    try std.testing.expectError(error.NoRoom, m.startCanvas(.mm));
    // A label anywhere, even far from the origin or at negative positions.
    _ = try m.addLabel(c, .{ .at = .{ .x = -500, .y = 1200 }, .content = "Volume" });
    try std.testing.expect(m.compliant(c));
    // A panel too can go anywhere: there is no sheet to keep to.
    const p = try m.placePanel(.{ .name = "Part", .origin = .{ .x = 5000, .y = -5000 }, .w = 50, .h = 20 });
    try std.testing.expect(m.compliant(p));
    m.setCanvasUnits(.mm);
    try std.testing.expectEqual(Units.mm, m.units);
    try std.testing.expectApproxEqAbs(@as(f64, 39.37007874), Units.mil.perMm(), 1e-6);
}

test "frames are spaces: moving keeps coordinates and arrives as one group; a group moves as one" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    // On the canvas: a panel, a loose track, a loose label and line art.
    const p = try m.placePanel(.{ .name = "Front", .origin = .{ .x = 10, .y = 10 }, .w = 50, .h = 30 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    const r = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = 100, .y = 50 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    _ = try m.insertTile(c, r, 0, key, 1);
    _ = try m.addLabel(c, .{ .at = .{ .x = 5, .y = 80 }, .content = "Stays" });
    _ = try m.addLabel(c, .{ .at = .{ .x = 120, .y = 70 }, .content = "Goes" });
    const f = try m.addFrame("Frame 1", null);
    try std.testing.expectEqual(1, f);
    const froot = m.spaces.items[f].root;
    const g = try m.moveToSpace(&.{ .{ .panel = p }, .{ .region = .{ .panel = c, .index = r } }, .{ .label = .{ .panel = c, .index = 1 } } }, f);
    // Panels change space; loose objects move to the frame's own panel,
    // coordinates kept.
    try std.testing.expectEqual(f, m.spaceOf(p));
    try std.testing.expectEqual(10, m.panels.items[p].origin.x);
    try std.testing.expectEqual(0, m.panels.items[c].regions.items.len);
    try std.testing.expectEqual(1, m.panels.items[c].labels.items.len);
    try std.testing.expectEqualStrings("Stays", m.panels.items[c].labels.items[0].content);
    try std.testing.expectEqual(100, m.panels.items[froot].regions.items[0].origin.x);
    try std.testing.expectEqualStrings("Goes", m.panels.items[froot].labels.items[0].content);
    // One group, named after where it came from; one move places all.
    const group = m.spaces.items[f].groups.items[g];
    try std.testing.expectEqualStrings("from Canvas", group.name);
    try std.testing.expectEqual(3, group.members.items.len);
    try m.moveGroup(f, g, -10, 5);
    try std.testing.expectEqual(0, m.panels.items[p].origin.x);
    try std.testing.expectEqual(90, m.panels.items[froot].regions.items[0].origin.x);
    try std.testing.expectEqual(75, m.panels.items[froot].labels.items[0].at.y);
    // Copying leaves the original, and copies tiles with new designators.
    const tiles_before = m.tiles.items.len;
    _ = try m.copyToSpace(&.{.{ .panel = p }}, 0);
    try std.testing.expectEqual(f, m.spaceOf(p));
    const copy = m.panels.items.len - 1;
    try std.testing.expectEqual(0, m.spaceOf(copy));
    try std.testing.expectEqual(tiles_before, m.tiles.items.len);
    _ = try m.copyToSpace(&.{.{ .region = .{ .panel = froot, .index = 0 } }}, 0);
    try std.testing.expectEqual(tiles_before + 1, m.tiles.items.len);
    try std.testing.expectEqualStrings("T2", m.tiles.items[tiles_before].designator);
    // A frame's boundary, as Fit frame sets it.
    try m.setFrameBound(f, .{ .x0 = -5, .y0 = 0, .x1 = 150, .y1 = 100 });
    try std.testing.expectEqual(150, m.spaces.items[f].bound.?.x1);
    try std.testing.expectError(error.NoSuchItem, m.setFrameBound(0, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    // Members of two spaces cannot move together.
    try std.testing.expectError(error.NoSuchItem, m.moveToSpace(&.{ .{ .panel = p }, .{ .panel = copy } }, 0));
    m.ungroup(f, g);
    try std.testing.expectEqual(0, m.spaces.items[f].groups.items.len);
}
