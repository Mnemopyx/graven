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

/// An object's lasting identity: a panel, a label, a track, a piece of
/// line art or a group keeps its ID for as long as it exists, wherever it
/// moves, so references to it (groups, selections, later constraints) never
/// go stale as other objects come and go. A copy gets a new one.
pub const ObjectId = enum(u32) { none = 0, _ };

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
/// The cap height, as a share of the em, that stands in for a style sized
/// by its em until its font is known: typical of text faces.
pub const cap_per_em = 0.7;

/// mm per point (1/72 in, as PostScript, PDF, OpenType and CSS have it).
pub const mm_per_pt = 25.4 / 72.0;

/// Where on an object's box its object origin is: low (left, bottom),
/// middle or high (right, top), on each axis. Choosing it never moves the
/// object; it says which point holds its position, and what a resize
/// keeps in place.
pub const Third = enum { low, mid, high };

pub const OriginPoint = struct {
    x: Third = .low,
    y: Third = .low,
};

/// A feature of an object that constraints act on: an edge, a centre
/// line, or the line through its object origin, on one axis. Points are
/// pairs of these, one on each axis.
pub const Feature = enum {
    left,
    centre_x,
    right,
    origin_x,
    bottom,
    centre_y,
    top,
    origin_y,
    /// The first baseline: a label's (its anchor's), or a text track's
    /// first row's. Other objects have none.
    baseline,

    pub fn vertical(f: Feature) bool {
        return @intFromEnum(f) >= @intFromEnum(Feature.bottom);
    }
};

/// One end of a constraint: a feature of an object, or (object `.none`)
/// of the parent the other end's object sits in: the space (its origin,
/// and its boundary's edges when it has one) or the panel (its outline and
/// its object origin, in its own frame).
pub const ConstraintEnd = struct {
    object: ObjectId = .none,
    feature: Feature,
};

/// A parametric constraint: adding it, or changing its value, moves what
/// it constrains (the object of end `a`; end `b` is the reference) to
/// exactly where it says. Both ends' features are on one axis, and their
/// objects share a parent (or `b` is that parent).
pub const Constraint = struct {
    id: ObjectId = .none,
    kind: enum {
        /// `a`'s feature lies `value` mm past `b`'s (right or up
        /// positive); 0 aligns them. Two features of one object give it a
        /// size (its right edge 40 mm past its left).
        offset,
        /// `a`'s size on the axis is `value` mm more than `b`'s; 0 makes
        /// them equal.
        equal_size,
    } = .offset,
    a: ConstraintEnd,
    b: ConstraintEnd,
    value: f64 = 0,
};

/// A paragraph style's index in `Model.paragraph_styles`.
pub const ParaId = u16;

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

/// How a paragraph's lines sit in their segments: as `Align`, or
/// justified (spaces between words stretched to fill each line but its
/// last).
pub const ParagraphAlign = enum { start, centre, end, justify };

/// Named paragraph settings, which a paragraph of a flow takes by its
/// separator. Lengths in mm: indents from a segment's start and end, the
/// first line's further indent (negative for a hanging one), space before
/// and after the paragraph and between its lines, added to where its
/// segments go along the track's path.
pub const ParagraphStyle = struct {
    name: []const u8,
    alignment: ParagraphAlign = .start,
    indent_start: f64 = 0,
    indent_end: f64 = 0,
    first: f64 = 0,
    space_before: f64 = 0,
    space_after: f64 = 0,
    line_gap: f64 = 0,
};

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
        /// A line break: what follows starts the next segment.
        hard_break,
        /// A paragraph separator: ends a paragraph, and starts the next
        /// in the paragraph style it names (null: the track's own).
        paragraph: ?ParaId,
    },

    /// Whether this item and `next`, which follows it, are in one group.
    pub fn binds(item: Item, next: Item) bool {
        return item.bind and !item.breaks() and !next.breaks();
    }

    /// Whether it is a line break or a paragraph separator: either ends
    /// its segment.
    pub fn breaks(item: Item) bool {
        return item.what == .hard_break or item.what == .paragraph;
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
/// Segments are made as content flows, never placed by hand: each goes one
/// segment's thickness (plus the track's gap and any paragraph spacing)
/// further across than the one before, and its `along` is where the
/// track's path is at that point across (see `TileRegion.pathAt`). So
/// rows keep an even pitch however the path bends.
pub const Segment = struct {
    along: f64 = 0,
    across: f64 = 0,
    /// Older documents only: an origin moved by hand, read now as a
    /// control point of the path.
    moved: bool = false,
};

/// A control point of a track's path: where the path passes, u from the
/// region's origin (`along` its length, `across` it). The path is a
/// smooth curve through its control points, giving an offset along for
/// every point across; it starts at the region's origin unless a control
/// point is there, and runs straight on past the last one.
pub const ControlPoint = struct {
    id: ObjectId = .none,
    along: f64,
    across: f64,
};

/// The value at `x` of the monotone cubic (Fritsch–Carlson) through
/// `pts` (sorted across, distinct): `along` as a function of `across`,
/// level outside them.
fn monotoneCubic(pts: []const ControlPoint, x: f64) f64 {
    const n = pts.len;
    if (n == 0) return 0;
    if (n == 1 or x <= pts[0].across) return pts[0].along;
    if (x >= pts[n - 1].across) return pts[n - 1].along;
    var i: usize = 0;
    while (i + 2 < n and x > pts[i + 1].across) i += 1;
    // The secant slopes, and tangents at each point limited so the curve
    // stays between its neighbours (flat at a peak or a trough).
    const slope = struct {
        fn of(p: []const ControlPoint, k: usize) f64 {
            return (p[k + 1].along - p[k].along) / (p[k + 1].across - p[k].across);
        }
    }.of;
    const tangent = struct {
        fn at(p: []const ControlPoint, k: usize) f64 {
            const last = p.len - 1;
            if (k == 0) return slope(p, 0);
            if (k == last) return slope(p, last - 1);
            const d0 = slope(p, k - 1);
            const d1 = slope(p, k);
            if (d0 * d1 <= 0) return 0;
            // A weighted harmonic mean keeps it monotone.
            const h0 = p[k].across - p[k - 1].across;
            const h1 = p[k + 1].across - p[k].across;
            const w1 = 2 * h1 + h0;
            const w2 = h1 + 2 * h0;
            return (w1 + w2) / (w1 / d0 + w2 / d1);
        }
    }.at;
    const x0 = pts[i].across;
    const h = pts[i + 1].across - x0;
    const t = (x - x0) / h;
    const t2 = t * t;
    const t3 = t2 * t;
    const m0 = tangent(pts, i) * h;
    const m1 = tangent(pts, i + 1) * h;
    return (2 * t3 - 3 * t2 + 1) * pts[i].along + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * pts[i + 1].along + (t3 - t2) * m1;
}

/// Which way a region's tracks run: rows, filled left to right and stacked
/// top to bottom, or columns, filled top to bottom and set left to right.
pub const Major = enum { row, column };

/// A region holding a track: one flow of items (tiles, blanks, runs of
/// text or equations, hard breaks) poured in order through its segments,
/// rows or columns placed from the region's top-left corner.
pub const TileRegion = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// The region's top-left corner in the panel frame, mm.
    origin: geom.Point,
    /// Its size in u: a segment's length along, and the room across.
    w: f64,
    h: f64,
    /// mm per u.
    pitch: f64,
    major: Major = .row,
    /// Its object origin on its soft area; by default the top-left corner,
    /// where `origin` is.
    holds: OriginPoint = .{ .y = .high },
    /// The kind of tile it was made for: what new tiles in it are.
    prototype: ?PrototypeId = null,
    /// The text style it was sized to, if any: its segments are one line
    /// pitch thick (the pitch is the style's baseline-to-baseline distance
    /// when the region was made), and new runs in it take the style.
    style: ?StyleId = null,
    /// Its path's control points, in any order (see `ControlPoint`). The
    /// region's `w` × `h` is the soft area segments are made in; segments
    /// past it are flagged. Control points stay when content no longer
    /// reaches them, so the path keeps its shape.
    path: std.ArrayList(ControlPoint) = .empty,
    /// Older documents only: segment origins as they were stored, those
    /// marked `moved` read as control points.
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
    /// The paragraph style of the flow's first paragraph (each later one
    /// takes its separator's); null for none: segments set by `alignment`.
    paragraph: ?ParaId = null,
    /// The flow, in order. A tile thicker than its segment (a 2 u tall
    /// key) reaches into the segments after it, closing the stretch it
    /// covers there; their content flows around it.
    items: std.ArrayList(Item) = .empty,

    /// Whether its path has been shaped: it has control points (or an
    /// older document's moved origins). An unshaped track sets each line
    /// in its whole segment, as its paragraph aligns it.
    pub fn shaped(r: TileRegion) bool {
        if (r.path.items.len > 0) return true;
        for (r.segments.items, 0..) |sg, k| if (k > 0 and sg.moved) return true;
        return false;
    }

    /// Where a line anchored `anchor` sits along on an unshaped track, u:
    /// its start at the near edge, its centre in the middle, its end at the
    /// far edge. The unshaped path is the track's own alignment's line.
    pub fn anchorRef(r: TileRegion, anchor: Align) f64 {
        return switch (anchor) {
            .start => 0,
            .centre => r.segmentLength() / 2,
            .end => r.segmentLength(),
        };
    }

    /// The path's points, sorted across, into `buf`: its control points
    /// (or an older document's moved origins), and a start on the track's
    /// alignment line (see `anchorRef`) unless a point is there or before.
    pub fn pathPoints(r: TileRegion, buf: []ControlPoint) []ControlPoint {
        var n: usize = 0;
        if (r.path.items.len > 0) {
            for (r.path.items) |cp| if (n < buf.len) {
                buf[n] = cp;
                n += 1;
            };
        } else for (r.segments.items, 0..) |sg, k| if (k > 0 and sg.moved and n < buf.len) {
            buf[n] = .{ .along = sg.along, .across = sg.across };
            n += 1;
        };
        var has_start = false;
        for (buf[0..n]) |cp| if (cp.across <= 1e-9) {
            has_start = true;
        };
        if (!has_start and n < buf.len) {
            buf[n] = .{ .along = r.anchorRef(r.alignment), .across = 0 };
            n += 1;
        }
        std.mem.sort(ControlPoint, buf[0..n], {}, struct {
            fn lt(_: void, x: ControlPoint, y: ControlPoint) bool {
                return x.across < y.across;
            }
        }.lt);
        // Two at one place across: the later one stands.
        var w: usize = 0;
        for (buf[0..n]) |cp| {
            if (w > 0 and @abs(buf[w - 1].across - cp.across) < 1e-9) {
                buf[w - 1] = cp;
            } else {
                buf[w] = cp;
                w += 1;
            }
        }
        return buf[0..w];
    }

    /// Where the path is along at `across`, u: a monotone cubic through
    /// its points (it passes through each, never overshooting them, so a
    /// bend peaks at its point), level before the first and after the last.
    pub fn pathAt(r: TileRegion, across: f64) f64 {
        var buf: [64]ControlPoint = undefined;
        const pts = r.pathPoints(&buf);
        return monotoneCubic(pts, across);
    }

    /// A segment's length, u.
    pub fn segmentLength(r: TileRegion) f64 {
        return if (r.major == .row) r.w else r.h;
    }



    /// The band of a segment at origin `s`, mm in the panel frame: from
    /// its origin to the far edge of the soft area along (the space
    /// reserved for the track; a segment the path starts further along is
    /// that much shorter), one pitch across.
    pub fn boxAt(r: TileRegion, s: Segment) geom.Box {
        return r.bandAt(s, .start);
    }

    /// The band of a segment whose line is anchored `anchor` at `s`, mm in
    /// the panel frame, within the soft area along: anchored at its start,
    /// from there to the far edge; at its end, from the near edge to
    /// there; at its centre, as far each way as the nearer edge allows.
    pub fn bandAt(r: TileRegion, s: Segment, anchor: Align) geom.Box {
        const across = s.across * r.pitch;
        const len = r.segmentLength();
        const lo: f64, const hi: f64 = switch (anchor) {
            .start => .{ s.along, @max(s.along, len) },
            .end => .{ @min(0, s.along), s.along },
            .centre => blk: {
                const half = @max(0, @min(s.along, len - s.along));
                break :blk .{ s.along - half, s.along + half };
            },
        };
        const shift = lo * r.pitch;
        const length = (hi - lo) * r.pitch;
        return if (r.major == .row)
            .{ .x0 = r.origin.x + shift, .x1 = r.origin.x + shift + length, .y1 = r.origin.y - across, .y0 = r.origin.y - across - r.pitch }
        else
            .{ .x0 = r.origin.x + across, .x1 = r.origin.x + across + r.pitch, .y1 = r.origin.y - shift, .y0 = r.origin.y - shift - length };
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
    id: ObjectId = .none,
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
    id: ObjectId = .none,
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
    /// Its object origin on its shapes' bounds.
    holds: OriginPoint = .{},
    /// The primitive it was drawn as, if any (so a corner radius can be
    /// changed).
    prim: art_.Primitive = .free,
    /// A cutout: on a panel, a hole cut through it. Drawn as an outline,
    /// never filled, and its SVG is a hole in the panel's outline.
    cutout: bool = false,

    /// Its outline, if it is one closed path (one shape, one contour):
    /// what Make panel can take as a panel's edge.
    pub fn closedPath(p: PanelArt) ?geom.Outline {
        if (p.shapes.len != 1 or p.shapes[0].outline.contours.len != 1) return null;
        return p.shapes[0].outline;
    }

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
    /// Views of other spaces placed in this one.
    views: std.ArrayList(SpaceView) = .empty,
    /// Its layers, bottom first. There is always one at least.
    layers: std.ArrayList(Layer) = .empty,
    /// The layer an object with no layer of its own (`.none`) is on; the
    /// space's loose objects are on it.
    base_layer: ObjectId = .none,
    /// Raster images placed in it.
    images: std.ArrayList(Image) = .empty,

    /// The index of layer `id` (`.none` meaning the base layer).
    pub fn layerIndex(sp: Space, id: ObjectId) ?usize {
        const want = if (id == .none) sp.base_layer else id;
        for (sp.layers.items, 0..) |l, i| if (l.id == want) return i;
        return null;
    }
};

/// How a layer's content combines with what lies under it.
pub const Blend = enum { normal, multiply, screen };

/// What makes a layer's content: a process, or none (a guide or reference
/// layer, shown but not made).
pub const Output = enum {
    none,
    print,
    engrave,
    cut,
    mill,

    /// Whether opacity and blending mean anything to it: only to what is
    /// seen (the screen) and printed.
    pub fn blends(o: Output) bool {
        return o == .none or o == .print;
    }
};

/// A layer of a space: what it shows, whether it can be changed, how it
/// is composited, and what makes it.
pub const Layer = struct {
    id: ObjectId = .none,
    name: []const u8,
    visible: bool = true,
    locked: bool = false,
    /// 0 (clear) to 1.
    opacity: f64 = 1,
    blend: Blend = .normal,
    output: Output = .print,
};

/// A raster image placed in a space at a physical size. Its file (PNG or
/// JPEG) is stored in the document.
pub const Image = struct {
    id: ObjectId = .none,
    name: []const u8,
    layer: ObjectId = .none,
    /// Its bottom-left corner, mm in the space.
    at: geom.Point,
    /// Its size, mm.
    w: f64,
    h: f64,
    /// Its object origin on its box.
    holds: OriginPoint = .{},
    /// Its pixels.
    px_w: u32,
    px_h: u32,
    /// The image file's bytes.
    data: []const u8,

    pub fn box(i: Image) geom.Box {
        return .{ .x0 = i.at.x, .y0 = i.at.y, .x1 = i.at.x + i.w, .y1 = i.at.y + i.h };
    }

    /// Its effective resolution, pixels per inch across.
    pub fn dpi(i: Image) f64 {
        return @as(f64, @floatFromInt(i.px_w)) / (i.w / 25.4);
    }
};

/// A layer the checks flag, and why.
pub const LayerIssue = struct {
    space: usize,
    layer: usize,
    kind: enum {
        /// Opacity or blending on a layer whose process ignores them
        /// (engrave, cut, mill).
        blend_ignored,
        /// An image printed at under `min_print_dpi`.
        low_resolution,
    },
    /// For `low_resolution`: the image, by index in the space.
    image: ?usize = null,
};

/// The least resolution an image is printed at without a flag.
pub const min_print_dpi = 150.0;

/// A view: a live, read-only window onto another space (its source),
/// placed in this one at a scale. What changes in the source shows in the
/// view at once; nothing in it can be picked or edited through the view.
/// A frame used this way many times is a symbol.
pub const SpaceView = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// The space it shows.
    source: usize,
    /// Where the source point `look.x0, look.y0` (the window's corner)
    /// lands in this space, mm.
    at: geom.Point,
    /// Host mm per source mm.
    scale: f64 = 1,
    /// The part of the source it shows, in the source's coordinates; null
    /// shows the source's boundary, or all its content when it has none.
    window: ?geom.Box = null,
    /// The layer of the host it is on (`.none`: the base layer).
    layer: ObjectId = .none,

    /// Where source point `q` lands in the host, given the window's corner
    /// `corner`.
    pub fn toHost(v: SpaceView, corner: geom.Point, q: geom.Point) geom.Point {
        return .{ .x = v.at.x + (q.x - corner.x) * v.scale, .y = v.at.y + (q.y - corner.y) * v.scale };
    }
};

/// Where an object is: a panel, or one of a panel's labels, tracks
/// (regions) or line art, by index. Indices change as objects come and go;
/// hold an `ObjectId` and find it with `Model.locate`.
pub const Member = union(enum) {
    panel: usize,
    label: struct { panel: usize, index: usize },
    region: struct { panel: usize, index: usize },
    art: struct { panel: usize, index: usize },
};

/// A selection group: objects and groups of one space, treated as one.
/// Groups nest: a member may be another group of the same space.
pub const Group = struct {
    id: ObjectId,
    name: []const u8,
    members: std.ArrayList(ObjectId) = .empty,
};

pub const Panel = struct {
    id: ObjectId = .none,
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
    /// Its object origin on its outline.
    holds: OriginPoint = .{},
    default_margins: bool = true,
    /// The closed path its outline was made from (Make panel), in the
    /// panel frame, its box from (0, 0) to (w, h); none for a rectangle.
    edge: ?PanelArt = null,
    /// The layer of its space it is on (`.none`: the base layer). A
    /// space's own panel is always on the base layer.
    layer: ObjectId = .none,

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

/// A font as a document names it: by family and style, never by file, so
/// a document opens alike on any machine that has the font.
pub const FontName = struct {
    family: []const u8,
    style: []const u8 = "Regular",

    pub fn eql(a: FontName, b: FontName) bool {
        return std.ascii.eqlIgnoreCase(a.family, b.family) and std.ascii.eqlIgnoreCase(a.style, b.style);
    }
};

/// One face of a composed font besides its main one, and how it is set
/// beside the main face (see `engine.style.Member`).
pub const FontMember = struct {
    font: FontName,
    /// Its italic, for letters asked to be italic; else `font`.
    italic: ?FontName = null,
    /// Its bold and bold italic, for bold text; else the weights above.
    bold: ?FontName = null,
    bold_italic: ?FontName = null,
    /// The math alphabet it sets from ordinary letters (a blackboard face
    /// for \mathbb); normal for a member that sets characters as they are.
    alphabet: engine.style.Alphabet = .normal,
    /// The characters it sets: what the faces before it lack (a fallback),
    /// or codepoint ranges, taken even where the main face has them.
    coverage: engine.style.Coverage = .fallback,
    /// How it is sized against the main face, then a further factor.
    match: engine.style.Match = .cap_height,
    scale: f64 = 1,
    /// Baseline shift, a fraction of the cap height, up positive.
    shift: f64 = 0,
};

/// A composed font: a named, virtual font that styles reference. A main
/// font (and its italic) and an ordered list of members, each with its
/// coverage and its size and baseline adjustments. Styles share it, so
/// changing it restyles every label set in it.
pub const ComposedFont = struct {
    id: ObjectId = .none,
    name: []const u8,
    main: FontName,
    italic: ?FontName = null,
    /// Its bold and bold italic: bold text falls back to the regular
    /// weight (and is reported) without them, or in math to Unicode's
    /// mathematical bold where a face has it.
    bold: ?FontName = null,
    bold_italic: ?FontName = null,
    members: std.ArrayList(FontMember) = .empty,

    pub fn variants(f: ComposedFont) FontVariants {
        return .{ .italic = f.italic, .bold = f.bold, .bold_italic = f.bold_italic };
    }
};

/// A family's other weights and slants beside its regular face.
pub const FontVariants = struct {
    italic: ?FontName = null,
    bold: ?FontName = null,
    bold_italic: ?FontName = null,
};

pub const LabelStyle = struct {
    name: []const u8,
    /// The composed font the style is set in; none: the faces `spec`
    /// names directly, in the caller's face table.
    font: ObjectId = .none,
    /// Face ids index the face table the caller renders with; a style set
    /// in a composed font has them filled in when its font is resolved
    /// (see `fonts.resolve`).
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
    /// The next object ID to give out.
    next_id: u32 = 1,
    /// The canvas (space 0) and the frames, once the document is a canvas.
    spaces: std.ArrayList(Space) = .empty,
    panels: std.ArrayList(Panel) = .empty,
    tiles: std.ArrayList(Tile) = .empty,
    prototypes: std.ArrayList(TilePrototype) = .empty,
    /// The built-in Blank prototype, once a blank has been made.
    blank_prototype: ?PrototypeId = null,
    styles: std.ArrayList(LabelStyle) = .empty,
    /// Named paragraph settings, which paragraphs of flows take.
    paragraph_styles: std.ArrayList(ParagraphStyle) = .empty,
    /// The document's composed fonts, which styles reference.
    fonts: std.ArrayList(ComposedFont) = .empty,
    /// Parametric constraints on objects' features (see `constrain`).
    constraints: std.ArrayList(Constraint) = .empty,
    /// Bumped by every action, so callers can tell when to re-solve.
    revision: u64 = 0,

    pub const Error = Allocator.Error || error{ NoRoom, DuplicateDesignator, NoSuchPrototype, NoSuchTile, NoSuchSlot, NoSuchLayer, DuplicateSlot, PrototypeInUse, NoSuchRow, NoSuchItem, NoSuchStyle, BadSize, OffSheet, NotCompliant, ViewCycle, NoSuchFont, FontInUse, NoSuchObject, BadConstraint };

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

    // Composed fonts ---------------------------------------------------------

    fn dupeFontName(m: *Model, n: FontName) Allocator.Error!FontName {
        return .{ .family = try m.a().dupe(u8, n.family), .style = try m.a().dupe(u8, n.style) };
    }

    fn dupeOptFontName(m: *Model, n: ?FontName) Allocator.Error!?FontName {
        return if (n) |v| try m.dupeFontName(v) else null;
    }

    fn dupeMember(m: *Model, mb: FontMember) Allocator.Error!FontMember {
        var out = mb;
        out.font = try m.dupeFontName(mb.font);
        out.italic = try m.dupeOptFontName(mb.italic);
        out.bold = try m.dupeOptFontName(mb.bold);
        out.bold_italic = try m.dupeOptFontName(mb.bold_italic);
        out.coverage = switch (mb.coverage) {
            .fallback => .fallback,
            .ranges => |rs| .{ .ranges = try m.a().dupe(engine.style.Range, rs) },
        };
        return out;
    }

    /// The index of composed font `id`.
    pub fn fontIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.fonts.items, 0..) |f, i| if (f.id == id) return i;
        return null;
    }

    fn font(m: *Model, id: ObjectId) Error!*ComposedFont {
        return &m.fonts.items[m.fontIndex(id) orelse return error.NoSuchFont];
    }

    /// A new composed font named `name`, its main font `main`, with no
    /// members yet. Returns its ID.
    pub fn addFont(m: *Model, name: []const u8, main: FontName) Error!ObjectId {
        const id = m.newId();
        try m.fonts.append(m.a(), .{ .id = id, .name = try m.a().dupe(u8, name), .main = try m.dupeFontName(main) });
        m.revision += 1;
        return id;
    }

    /// The first "Font N" no composed font uses yet.
    pub fn nextFontName(m: *const Model, buf: []u8) []const u8 {
        var n: usize = m.fonts.items.len + 1;
        while (true) : (n += 1) {
            const name = std.fmt.bufPrint(buf, "Font {d}", .{n}) catch return "Font";
            for (m.fonts.items) |f| {
                if (std.mem.eql(u8, f.name, name)) break;
            } else return name;
        }
    }

    pub fn renameFont(m: *Model, id: ObjectId, name: []const u8) Error!void {
        const f = try m.font(id);
        f.name = try m.a().dupe(u8, name);
        m.revision += 1;
    }

    /// Sets the main font of composed font `id`, and its italic (null for
    /// none: letters asked to be italic are then upright, and reported).
    pub fn setFontMain(m: *Model, id: ObjectId, main: FontName, italic: ?FontName) Error!void {
        const f = try m.font(id);
        f.main = try m.dupeFontName(main);
        f.italic = if (italic) |it| try m.dupeFontName(it) else null;
        m.revision += 1;
    }

    /// Sets the italic, bold and bold italic of composed font `id`'s main
    /// font (null for each it lacks).
    pub fn setFontVariants(m: *Model, id: ObjectId, v: FontVariants) Error!void {
        const f = try m.font(id);
        f.italic = try m.dupeOptFontName(v.italic);
        f.bold = try m.dupeOptFontName(v.bold);
        f.bold_italic = try m.dupeOptFontName(v.bold_italic);
        m.revision += 1;
    }

    /// Inserts `member` into composed font `id` at `at` (past the end:
    /// last). Returns where it went.
    pub fn addFontMember(m: *Model, id: ObjectId, at: usize, member: FontMember) Error!usize {
        const f = try m.font(id);
        const i = @min(at, f.members.items.len);
        try f.members.insert(m.a(), i, try m.dupeMember(member));
        m.revision += 1;
        return i;
    }

    pub fn setFontMember(m: *Model, id: ObjectId, index: usize, member: FontMember) Error!void {
        const f = try m.font(id);
        if (index >= f.members.items.len) return error.NoSuchItem;
        f.members.items[index] = try m.dupeMember(member);
        m.revision += 1;
    }

    /// Moves member `index` one place earlier (`up`) or later in the order
    /// faces are tried. Returns its new index.
    pub fn moveFontMember(m: *Model, id: ObjectId, index: usize, up: bool) Error!usize {
        const list = (try m.font(id)).members.items;
        if (index >= list.len) return error.NoSuchItem;
        const to = if (up) (if (index == 0) return index else index - 1) else index + 1;
        if (to >= list.len) return index;
        std.mem.swap(FontMember, &list[index], &list[to]);
        m.revision += 1;
        return to;
    }

    pub fn removeFontMember(m: *Model, id: ObjectId, index: usize) Error!void {
        const f = try m.font(id);
        if (index >= f.members.items.len) return error.NoSuchItem;
        _ = f.members.orderedRemove(index);
        m.revision += 1;
    }

    /// How many styles are set in composed font `id`.
    pub fn fontUsers(m: *const Model, id: ObjectId) usize {
        var n: usize = 0;
        for (m.styles.items) |st| {
            if (st.font == id) n += 1;
        }
        return n;
    }

    /// Removes composed font `id`; refused while a style is set in it.
    pub fn removeFont(m: *Model, id: ObjectId) Error!void {
        const i = m.fontIndex(id) orelse return error.NoSuchFont;
        if (m.fontUsers(id) > 0) return error.FontInUse;
        _ = m.fonts.orderedRemove(i);
        m.revision += 1;
    }

    /// Sets style `style` in composed font `font` (none: back to the faces
    /// its spec names).
    pub fn setStyleFont(m: *Model, style: StyleId, font_id: ObjectId) Error!void {
        if (style >= m.styles.items.len) return error.NoSuchStyle;
        if (font_id != .none and m.fontIndex(font_id) == null) return error.NoSuchFont;
        m.styles.items[style].font = font_id;
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
        try m.addBaseLayer(0);
        return root;
    }

    /// A new object ID.
    pub fn newId(m: *Model) ObjectId {
        const id: ObjectId = @enumFromInt(m.next_id);
        m.next_id += 1;
        return id;
    }

    fn addRoot(m: *Model, name: []const u8, space: usize) Error!usize {
        try m.panels.append(m.a(), .{ .id = m.newId(), .name = name, .unbounded = true, .space = space, .w = 0, .h = 0, .margins = .all(0), .default_margins = false });
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
        try m.addBaseLayer(sid);
        return sid;
    }

    /// Marks a frame's name as the app's choice (Frame 2), not the user's.
    pub fn markFrameNameDefault(m: *Model, space: usize) Error!void {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        m.spaces.items[space].default_name = true;
        m.revision += 1;
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

    /// Where object `id` is now, if it exists (groups are not objects in
    /// panels: see `findGroup`).
    pub fn locate(m: *const Model, id: ObjectId) ?Member {
        if (id == .none) return null;
        for (m.panels.items, 0..) |p, pi| {
            if (p.id == id) return .{ .panel = pi };
            for (p.labels.items, 0..) |l, i| if (l.id == id) return .{ .label = .{ .panel = pi, .index = i } };
            for (p.regions.items, 0..) |r, i| if (r.id == id) return .{ .region = .{ .panel = pi, .index = i } };
            for (p.art.items, 0..) |x, i| if (x.id == id) return .{ .art = .{ .panel = pi, .index = i } };
        }
        return null;
    }

    /// The ID of the object at `loc`.
    pub fn idAt(m: *const Model, loc: Member) ObjectId {
        return switch (loc) {
            .panel => |pi| m.panels.items[pi].id,
            .label => |l| m.panels.items[l.panel].labels.items[l.index].id,
            .region => |l| m.panels.items[l.panel].regions.items[l.index].id,
            .art => |l| m.panels.items[l.panel].art.items[l.index].id,
        };
    }

    /// The space and index of group `id`.
    pub fn findGroup(m: *const Model, id: ObjectId) ?struct { space: usize, index: usize } {
        for (m.spaces.items, 0..) |sp, si| {
            for (sp.groups.items, 0..) |g, gi| if (g.id == id) return .{ .space = si, .index = gi };
        }
        return null;
    }

    pub fn group(m: *const Model, id: ObjectId) ?*Group {
        const at = m.findGroup(id) orelse return null;
        return &m.spaces.items[at.space].groups.items[at.index];
    }

    /// The space an object or a group is in.
    pub fn spaceOfId(m: *const Model, id: ObjectId) ?usize {
        if (m.findGroup(id)) |at| return at.space;
        const loc = m.locate(id) orelse return null;
        return m.spaceOf(memberPanel(loc));
    }

    /// The group directly holding `id` (an object or a group), if any.
    pub fn parentGroup(m: *const Model, id: ObjectId) ?ObjectId {
        for (m.spaces.items) |sp| for (sp.groups.items) |g| {
            for (g.members.items) |mb| if (mb == id) return g.id;
        };
        return null;
    }

    /// The outermost group holding `id`, or `id` itself when it is in none.
    pub fn topLevel(m: *const Model, id: ObjectId) ObjectId {
        var at = id;
        while (m.parentGroup(at)) |p| at = p;
        return at;
    }

    /// The objects `id` stands for: itself, or every object in the group
    /// and its nested groups, appended to `out`.
    pub fn leaves(m: *Model, id: ObjectId, out: *std.ArrayList(ObjectId)) Allocator.Error!void {
        if (m.group(id)) |g| {
            for (g.members.items) |mb| try m.leaves(mb, out);
        } else try out.append(m.a(), id);
    }

    /// Makes a group of `ids` (objects and groups of one space) where they
    /// are. Where they were members of a group, the new group takes their
    /// place in it. Returns the new group's ID.
    pub fn makeGroup(m: *Model, ids: []const ObjectId, name: []const u8) Error!ObjectId {
        if (ids.len == 0) return error.NoSuchItem;
        const space = m.spaceOfId(ids[0]) orelse return error.NoSuchItem;
        for (ids) |id| if (m.spaceOfId(id) != space) return error.NoSuchItem;
        const gid = m.newId();
        var g: Group = .{ .id = gid, .name = try m.a().dupe(u8, name) };
        try g.members.appendSlice(m.a(), ids);
        // Out of their old group, which holds the new one instead.
        const parent = m.parentGroup(ids[0]);
        for (ids) |id| m.dropMember(id);
        try m.spaces.items[space].groups.append(m.a(), g);
        if (parent) |p| if (m.group(p)) |pg| try pg.members.append(m.a(), gid);
        m.revision += 1;
        return gid;
    }

    /// Takes `id` out of whatever group holds it.
    fn dropMember(m: *Model, id: ObjectId) void {
        for (m.spaces.items) |*sp| for (sp.groups.items) |*g| {
            var i: usize = 0;
            while (i < g.members.items.len) {
                if (g.members.items[i] == id) _ = g.members.orderedRemove(i) else i += 1;
            }
        };
    }

    /// Dissolves a group; its members stay where they are, and go to the
    /// group that held it, if any.
    pub fn ungroup(m: *Model, id: ObjectId) Error!void {
        const at = m.findGroup(id) orelse return error.NoSuchItem;
        const g = m.spaces.items[at.space].groups.orderedRemove(at.index);
        if (m.parentGroup(id)) |p| {
            m.dropMember(id);
            if (m.group(p)) |pg| try pg.members.appendSlice(m.a(), g.members.items);
        }
        m.revision += 1;
    }

    /// An object is gone: out of every group, and groups left empty go too.
    fn forget(m: *Model, id: ObjectId) void {
        m.dropMember(id);
        var again = true;
        while (again) {
            again = false;
            for (m.spaces.items) |*sp| {
                var i: usize = 0;
                while (i < sp.groups.items.len) {
                    if (sp.groups.items[i].members.items.len == 0) {
                        const empty = sp.groups.orderedRemove(i);
                        m.dropMember(empty.id);
                        again = true;
                    } else i += 1;
                }
            }
        }
    }

    /// Moves every object of group `id` (nested groups included) by
    /// (`dx`, `dy`) mm.
    pub fn moveGroup(m: *Model, id: ObjectId, dx: f64, dy: f64) Error!void {
        if (m.group(id) == null) return error.NoSuchItem;
        var objs: std.ArrayList(ObjectId) = .empty;
        try m.leaves(id, &objs);
        for (objs.items) |oid| {
            const loc = m.locate(oid) orelse continue;
            switch (loc) {
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
            }
        }
        m.revision += 1;
    }

    /// Moves `ids` (objects and groups, all of one space) into space
    /// `dest`, keeping their coordinates: panels change space, loose
    /// labels, tracks and line art move to `dest`'s own panel, and groups
    /// go with their members. They arrive as one new group named
    /// "from <source>", whose ID is returned. (Once constraints exist, the
    /// constraint group comes too, and constraints reaching outside it are
    /// dropped and listed.)
    pub fn moveToSpace(m: *Model, ids: []const ObjectId, dest: usize) Error!ObjectId {
        return m.transfer(ids, dest, false);
    }

    /// As `moveToSpace`, with copies (new IDs): the originals stay where
    /// they were.
    pub fn copyToSpace(m: *Model, ids: []const ObjectId, dest: usize) Error!ObjectId {
        return m.transfer(ids, dest, true);
    }

    fn transfer(m: *Model, ids: []const ObjectId, dest: usize, copy: bool) Error!ObjectId {
        if (dest >= m.spaces.items.len or ids.len == 0) return error.NoSuchItem;
        const from = m.spaceOfId(ids[0]) orelse return error.NoSuchItem;
        for (ids) |id| if (m.spaceOfId(id) != from) return error.NoSuchItem;
        if (from == dest and !copy) return error.NoSuchItem;
        var name_buf: [96]u8 = undefined;
        const gname = std.fmt.bufPrint(&name_buf, "from {s}", .{m.spaces.items[from].name}) catch "moved";

        // The constraint group: what is constrained to anything going comes
        // too (and what is constrained to that), so the layout holds.
        var going: std.ArrayList(ObjectId) = .empty;
        for (ids) |id| try m.constrainedLeaves(id, &going);
        var all: std.ArrayList(ObjectId) = .empty;
        try all.appendSlice(m.a(), ids);
        var grew = true;
        while (grew) {
            grew = false;
            for (m.constraints.items) |c| {
                if (c.b.object == .none or std.mem.indexOfScalar(ObjectId, going.items, c.b.object) == null) continue;
                if (std.mem.indexOfScalar(ObjectId, going.items, c.a.object) != null) continue;
                if (m.spaceOfId(c.a.object) != from) continue;
                const top = m.topLevel(c.a.object);
                try all.append(m.a(), top);
                try m.constrainedLeaves(top, &going);
                grew = true;
            }
        }

        var pairs: std.ArrayList([2]ObjectId) = .empty;
        var arrived: std.ArrayList(ObjectId) = .empty;
        for (all.items) |id| try arrived.append(m.a(), try m.carry(id, dest, copy, &pairs));
        // Moved out of the source: out of its groups too.
        if (!copy) for (all.items) |id| m.dropMember(id);

        if (copy) {
            // Copies keep the constraints among them (and on their parent);
            // one on something not copied stays with the original only.
            const n = m.constraints.items.len;
            for (0..n) |ci| {
                const c = m.constraints.items[ci];
                const na = pairOf(pairs.items, c.a.object) orelse continue;
                const nb: ObjectId = if (c.b.object == .none) .none else pairOf(pairs.items, c.b.object) orelse continue;
                var cc = c;
                cc.id = m.newId();
                cc.a.object = na;
                cc.b.object = nb;
                try m.constraints.append(m.a(), cc);
            }
        } else {
            // What moved keeps to nothing left behind: those constraints go
            // (undo brings them back), and the objects keep their places.
            var k: usize = 0;
            while (k < m.constraints.items.len) {
                const c = m.constraints.items[k];
                const a_goes = std.mem.indexOfScalar(ObjectId, going.items, c.a.object) != null;
                const b_goes = c.b.object == .none or std.mem.indexOfScalar(ObjectId, going.items, c.b.object) != null;
                if (a_goes != b_goes and !(c.b.object == .none and !a_goes)) {
                    _ = m.constraints.orderedRemove(k);
                } else k += 1;
            }
        }
        const gid = m.newId();
        var g: Group = .{ .id = gid, .name = try m.a().dupe(u8, gname) };
        try g.members.appendSlice(m.a(), arrived.items);
        try m.spaces.items[dest].groups.append(m.a(), g);
        m.revision += 1;
        return gid;
    }

    /// The objects `id` stands for: itself; a group's members, nested; a
    /// panel and everything on it.
    fn constrainedLeaves(m: *Model, id: ObjectId, out: *std.ArrayList(ObjectId)) Allocator.Error!void {
        if (m.findGroup(id)) |at| {
            for (m.spaces.items[at.space].groups.items[at.index].members.items) |mb| try m.constrainedLeaves(mb, out);
            return;
        }
        try out.append(m.a(), id);
        for (m.panels.items) |p| if (p.id == id) {
            for (p.regions.items) |r| try out.append(m.a(), r.id);
            for (p.labels.items) |l| try out.append(m.a(), l.id);
            for (p.art.items) |x| try out.append(m.a(), x.id);
        };
    }

    fn pairOf(pairs: []const [2]ObjectId, id: ObjectId) ?ObjectId {
        for (pairs) |pr| if (pr[0] == id) return pr[1];
        return null;
    }

    /// Takes object or group `id` to space `dest` (a copy with new IDs when
    /// `copy`, each original and copy noted in `pairs`). Returns its ID
    /// there.
    fn carry(m: *Model, id: ObjectId, dest: usize, copy: bool, pairs: *std.ArrayList([2]ObjectId)) Error!ObjectId {
        if (m.findGroup(id)) |at| {
            const g = m.spaces.items[at.space].groups.items[at.index];
            var members: std.ArrayList(ObjectId) = .empty;
            for (g.members.items) |mb| try members.append(m.a(), try m.carry(mb, dest, copy, pairs));
            if (copy) {
                const nid = m.newId();
                try m.spaces.items[dest].groups.append(m.a(), .{ .id = nid, .name = try m.a().dupe(u8, g.name), .members = members });
                return nid;
            }
            // The group itself moves: out of the source's list, into dest's.
            const at2 = m.findGroup(id).?;
            var moved = m.spaces.items[at2.space].groups.orderedRemove(at2.index);
            moved.members = members;
            try m.spaces.items[dest].groups.append(m.a(), moved);
            return id;
        }
        const loc = m.locate(id) orelse return error.NoSuchItem;
        const droot = m.spaces.items[dest].root;
        switch (loc) {
            .label => |l| {
                const src = &m.panels.items[l.panel].labels;
                var item = src.items[l.index];
                if (copy) {
                    item.content = try m.a().dupe(u8, item.content);
                    item.id = m.newId();
                } else _ = src.orderedRemove(l.index);
                try m.panels.items[droot].labels.append(m.a(), item);
                try pairs.append(m.a(), .{ id, item.id });
                return item.id;
            },
            .art => |l| {
                const src = &m.panels.items[l.panel].art;
                var item = src.items[l.index];
                if (copy) {
                    item.shapes = try art_.dupeShapes(m.a(), item.shapes, .{ .x = 0, .y = 0 });
                    item.prim = try art_.dupePrimitive(m.a(), item.prim);
                    item.id = m.newId();
                } else _ = src.orderedRemove(l.index);
                try m.panels.items[droot].art.append(m.a(), item);
                try pairs.append(m.a(), .{ id, item.id });
                return item.id;
            },
            .region => |l| {
                const src = &m.panels.items[l.panel].regions;
                const item = if (copy) try m.copyRegion(src.items[l.index]) else src.orderedRemove(l.index);
                try m.panels.items[droot].regions.append(m.a(), item);
                try pairs.append(m.a(), .{ id, item.id });
                return item.id;
            },
            .panel => |pi| {
                const target = if (copy) try m.copyPanel(pi) else pi;
                m.panels.items[target].space = dest;
                // A copy's contents are in the same order as the original's.
                const orig = m.panels.items[pi];
                const got = m.panels.items[target];
                try pairs.append(m.a(), .{ orig.id, got.id });
                for (orig.regions.items, got.regions.items) |o, n| try pairs.append(m.a(), .{ o.id, n.id });
                for (orig.labels.items, got.labels.items) |o, n| try pairs.append(m.a(), .{ o.id, n.id });
                for (orig.art.items, got.art.items) |o, n| try pairs.append(m.a(), .{ o.id, n.id });
                // Layers belong to their space: it lands on dest's base layer.
                m.panels.items[target].layer = .none;
                return m.panels.items[target].id;
            },
        }
    }

    fn memberPanel(mb: Member) usize {
        return switch (mb) {
            .panel => |pi| pi,
            inline else => |l| l.panel,
        };
    }

    /// A copy of a track, with copies of its tiles (new designators) and a
    /// new ID.
    fn copyRegion(m: *Model, r: TileRegion) Error!TileRegion {
        var c = r;
        c.id = m.newId();
        c.name = try m.a().dupe(u8, r.name);
        c.segments = .empty;
        try c.segments.appendSlice(m.a(), r.segments.items);
        c.path = .empty;
        for (r.path.items) |cp| try c.path.append(m.a(), .{ .id = m.newId(), .along = cp.along, .across = cp.across });
        c.items = .empty;
        for (r.items.items) |item| {
            var it = item;
            switch (item.what) {
                .tile => |tid| {
                    const t = m.tileConst(tid);
                    var buf: [64]u8 = undefined;
                    const prefix = if (m.prototypes.items[t.prototype].spacer) "B" else "T";
                    var copy_t = t.*;
                    copy_t.designator = m.nextDesignator(&buf, prefix);
                    it.what = .{ .tile = try m.addTile(copy_t) };
                },
                .run => |run| it.what.run.content = try m.a().dupe(u8, run.content),
                .hard_break, .paragraph => {},
            }
            try c.items.append(m.a(), it);
        }
        return c;
    }

    /// A copy of a panel, appended, with copies of its content, all with
    /// new IDs. Returns it.
    fn copyPanel(m: *Model, pi: usize) Error!usize {
        const p = m.panels.items[pi];
        var c = p;
        c.id = m.newId();
        c.name = try m.a().dupe(u8, p.name);
        c.regions = .empty;
        c.labels = .empty;
        c.art = .empty;
        for (p.regions.items) |r| try c.regions.append(m.a(), try m.copyRegion(r));
        for (p.labels.items) |l| {
            var cl = l;
            cl.id = m.newId();
            cl.content = try m.a().dupe(u8, l.content);
            try c.labels.append(m.a(), cl);
        }
        for (p.art.items) |pa| {
            var ca = pa;
            ca.id = m.newId();
            ca.shapes = try art_.dupeShapes(m.a(), pa.shapes, .{ .x = 0, .y = 0 });
            ca.prim = try art_.dupePrimitive(m.a(), pa.prim);
            try c.art.append(m.a(), ca);
        }
        if (p.edge) |e| {
            var ce = e;
            ce.shapes = try art_.dupeShapes(m.a(), e.shapes, .{ .x = 0, .y = 0 });
            ce.prim = try art_.dupePrimitive(m.a(), e.prim);
            c.edge = ce;
        }
        try m.panels.append(m.a(), c);
        return m.panels.items.len - 1;
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
        p.id = m.newId();
        p.name = try m.a().dupe(u8, panel.name);
        p.regions = .empty;
        p.labels = .empty;
        p.art = .empty;
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
        l.id = m.newId();
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
        copy.id = m.newId();
        copy.name = try m.a().dupe(u8, art.name);
        copy.shapes = try art_.dupeShapes(m.a(), art.shapes, .{ .x = 0, .y = 0 });
        copy.prim = try art_.dupePrimitive(m.a(), art.prim);
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

    fn addBaseLayer(m: *Model, space: usize) Error!void {
        const id = m.newId();
        try m.spaces.items[space].layers.append(m.a(), .{ .id = id, .name = "Layer 1" });
        m.spaces.items[space].base_layer = id;
    }

    /// Adds a layer at the top of space `space`'s stack; returns its index.
    pub fn addLayer(m: *Model, space: usize, name: []const u8) Error!usize {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        const list = &m.spaces.items[space].layers;
        try list.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name) });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// The first "Layer N" not yet used in space `space`.
    pub fn nextLayerName(m: *const Model, space: usize, buf: []u8) []const u8 {
        var n: usize = m.spaces.items[space].layers.items.len + 1;
        while (true) : (n += 1) {
            const name = std.fmt.bufPrint(buf, "Layer {d}", .{n}) catch return "Layer";
            for (m.spaces.items[space].layers.items) |l| {
                if (std.mem.eql(u8, l.name, name)) break;
            } else return name;
        }
    }

    /// Changes a layer's settings (not its ID).
    pub fn setLayer(m: *Model, space: usize, index: usize, layer: Layer) Error!void {
        const list = m.spaces.items[space].layers.items;
        if (index >= list.len) return error.NoSuchLayer;
        if (!(layer.opacity >= 0 and layer.opacity <= 1)) return error.BadSize;
        var l = layer;
        l.id = list[index].id;
        if (!std.mem.eql(u8, l.name, list[index].name)) l.name = try m.a().dupe(u8, layer.name);
        list[index] = l;
        m.revision += 1;
    }

    /// Moves a layer one place up (toward the top) or down the stack;
    /// returns its new index.
    pub fn moveLayer(m: *Model, space: usize, index: usize, up: bool) Error!usize {
        const list = m.spaces.items[space].layers.items;
        if (index >= list.len) return error.NoSuchLayer;
        const to = if (up) index + 1 else if (index == 0) return index else index - 1;
        if (to >= list.len) return index;
        std.mem.swap(Layer, &list[index], &list[to]);
        m.revision += 1;
        return to;
    }

    /// Whether anything is on layer `index` of space `space`.
    pub fn layerUsed(m: *const Model, space: usize, index: usize) bool {
        const sp = m.spaces.items[space];
        const id = sp.layers.items[index].id;
        const base = id == sp.base_layer;
        for (m.panels.items, 0..) |p, pi| {
            if (p.space != space) continue;
            if (pi == sp.root) {
                if (base and (p.labels.items.len > 0 or p.regions.items.len > 0 or p.art.items.len > 0)) return true;
                continue;
            }
            if (p.layer == id or (p.layer == .none and base)) return true;
        }
        for (sp.views.items) |v| if (v.layer == id or (v.layer == .none and base)) return true;
        for (sp.images.items) |im| if (im.layer == id or (im.layer == .none and base)) return true;
        return false;
    }

    /// Removes an empty layer that is not the base layer.
    pub fn removeLayer(m: *Model, space: usize, index: usize) Error!void {
        const sp = &m.spaces.items[space];
        if (index >= sp.layers.items.len) return error.NoSuchLayer;
        if (sp.layers.items[index].id == sp.base_layer or m.layerUsed(space, index)) return error.NoRoom;
        _ = sp.layers.orderedRemove(index);
        m.revision += 1;
    }

    /// Puts panel `panel` on layer `layer` of its space.
    pub fn setPanelLayer(m: *Model, panel: usize, layer: ObjectId) Error!void {
        const p = &m.panels.items[panel];
        if (p.unbounded) return error.NoSuchItem;
        if (m.spaces.items[p.space].layerIndex(layer) == null) return error.NoSuchLayer;
        p.layer = layer;
        m.revision += 1;
    }

    /// Places image file `data` (`px_w` × `px_h` pixels) in space `space`,
    /// its corner at `at`, `w` mm wide (its height keeps its proportions),
    /// on layer `layer`. The bytes are copied into the document. Returns
    /// its index among the space's images.
    pub fn addImage(m: *Model, space: usize, name: []const u8, data: []const u8, px_w: u32, px_h: u32, at: geom.Point, w: f64, layer: ObjectId) Error!usize {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        if (px_w == 0 or px_h == 0 or !(w > 0)) return error.BadSize;
        if (m.spaces.items[space].layerIndex(layer) == null) return error.NoSuchLayer;
        const h = w * @as(f64, @floatFromInt(px_h)) / @as(f64, @floatFromInt(px_w));
        const list = &m.spaces.items[space].images;
        try list.append(m.a(), .{
            .id = m.newId(),
            .name = try m.a().dupe(u8, name),
            .layer = layer,
            .at = at,
            .w = w,
            .h = h,
            .px_w = px_w,
            .px_h = px_h,
            .data = try m.a().dupe(u8, data),
        });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Sets an image's place, width (its height follows) and layer.
    pub fn setImage(m: *Model, space: usize, index: usize, at: geom.Point, w: f64, layer: ObjectId) Error!void {
        const list = m.spaces.items[space].images.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!(w > 0)) return error.BadSize;
        if (m.spaces.items[space].layerIndex(layer) == null) return error.NoSuchLayer;
        const im = &list[index];
        im.at = at;
        im.h = w * @as(f64, @floatFromInt(im.px_h)) / @as(f64, @floatFromInt(im.px_w));
        im.w = w;
        im.layer = layer;
        m.revision += 1;
    }

    pub fn removeImage(m: *Model, space: usize, index: usize) void {
        _ = m.spaces.items[space].images.orderedRemove(index);
        m.revision += 1;
    }

    /// The layer checks: opacity or blending on a layer whose process
    /// ignores them, where it holds something; images printed under
    /// `min_print_dpi`. Allocated from `gpa`.
    pub fn layerIssues(m: *const Model, gpa: Allocator) Allocator.Error![]LayerIssue {
        var out: std.ArrayList(LayerIssue) = .empty;
        errdefer out.deinit(gpa);
        for (m.spaces.items, 0..) |sp, si| {
            for (sp.layers.items, 0..) |l, li| {
                if (!l.output.blends() and (l.opacity < 1 or l.blend != .normal) and m.layerUsed(si, li))
                    try out.append(gpa, .{ .space = si, .layer = li, .kind = .blend_ignored });
            }
            for (sp.images.items, 0..) |im, ii| {
                const li = sp.layerIndex(im.layer) orelse continue;
                if (sp.layers.items[li].output == .print and im.dpi() < min_print_dpi)
                    try out.append(gpa, .{ .space = si, .layer = li, .kind = .low_resolution, .image = ii });
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Places a view of space `source` in space `host`, at `at` and
    /// `scale`; returns its index among the host's views. Refused when the
    /// source would show the host, directly or through its own views.
    pub fn addView(m: *Model, host: usize, source: usize, at: geom.Point, scale: f64) Error!usize {
        if (host >= m.spaces.items.len or source >= m.spaces.items.len) return error.NoSuchItem;
        if (!(scale > 0)) return error.BadSize;
        if (m.viewWouldCycle(host, source)) return error.ViewCycle;
        var buf: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "View of {s}", .{m.spaces.items[source].name}) catch "View";
        const list = &m.spaces.items[host].views;
        try list.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .source = source, .at = at, .scale = scale });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Whether a view of `source` placed in `host` would show `host`
    /// inside itself: `source` is `host`, or reaches it through views.
    pub fn viewWouldCycle(m: *const Model, host: usize, source: usize) bool {
        if (host == source) return true;
        for (m.spaces.items[source].views.items) |v| {
            if (m.viewWouldCycle(host, v.source)) return true;
        }
        return false;
    }

    pub fn moveView(m: *Model, host: usize, index: usize, at: geom.Point) Error!void {
        const list = m.spaces.items[host].views.items;
        if (index >= list.len) return error.NoSuchItem;
        list[index].at = at;
        m.revision += 1;
    }

    pub fn setViewScale(m: *Model, host: usize, index: usize, scale: f64) Error!void {
        const list = m.spaces.items[host].views.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!(scale > 0)) return error.BadSize;
        list[index].scale = scale;
        m.revision += 1;
    }

    pub fn removeView(m: *Model, host: usize, index: usize) void {
        _ = m.spaces.items[host].views.orderedRemove(index);
        m.revision += 1;
    }

    /// Makes line art a cutout (a hole, on a panel) or plain art again.
    pub fn setArtCutout(m: *Model, panel: usize, index: usize, on: bool) Error!void {
        const list = m.panels.items[panel].art.items;
        if (index >= list.len) return error.NoSuchItem;
        list[index].cutout = on;
        // A hole keeps what flows away from it (by its ink, with the
        // clearance), unless told otherwise.
        if (on and list[index].wrap == .none) list[index].wrap = .ink;
        m.revision += 1;
    }

    /// Sets a rounded rectangle's corner radius, mm: it is redrawn.
    pub fn setArtCorner(m: *Model, panel: usize, index: usize, r: f64) Error!void {
        const list = m.panels.items[panel].art.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!(r >= 0)) return error.BadSize;
        const pa = &list[index];
        const rr = switch (pa.prim) {
            .rounded => |rr| rr,
            else => return error.NoSuchItem,
        };
        const paint: art_.Paint = if (pa.shapes.len > 0) pa.shapes[0].paint else .{};
        pa.prim = .{ .rounded = .{ .w = rr.w, .h = rr.h, .r = r } };
        pa.shapes = try art_.primitive(m.a(), try m.a().dupe(u8, pa.name), pa.prim, paint);
        m.revision += 1;
    }

    /// Make panel: loose line art `index` in space panel `root`, a closed
    /// path, becomes the edge of a new panel there, and what it encloses
    /// (labels by their anchor, tracks and other line art by their boxes'
    /// corners) moves onto the panel, keeping where it is. The panel takes
    /// the path's place in its group; what moves onto it leaves its groups.
    /// Returns the panel's index.
    pub fn makePanel(m: *Model, root: usize, index: usize) Error!usize {
        const rp = m.panels.items[root];
        if (!rp.unbounded or index >= rp.art.items.len) return error.NoSuchItem;
        const edge_art = rp.art.items[index];
        const path = edge_art.closedPath() orelse return error.NoSuchItem;
        const b = edge_art.box();
        if (!(b.width() > 0 and b.height() > 0)) return error.BadSize;
        // The path in the space panel's frame, for the enclosure test.
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
        const name = m.nextPanelName(&name_buf, "Panel");
        const origin: geom.Point = .{ .x = rp.origin.x + b.x0, .y = rp.origin.y + b.y0 };
        // From the space panel's frame to the new panel's.
        const d: geom.Point = .{ .x = rp.origin.x - origin.x, .y = rp.origin.y - origin.y };
        var p: Panel = .{
            .id = m.newId(),
            .name = try m.a().dupe(u8, name),
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
        // What it encloses moves across, from the end so indices hold.
        const src = &m.panels.items[root];
        var i = src.labels.items.len;
        while (i > 0) {
            i -= 1;
            const l = src.labels.items[i];
            if (!inside.f(path, at, l.at)) continue;
            var moved = src.labels.orderedRemove(i);
            moved.at = .{ .x = moved.at.x + d.x, .y = moved.at.y + d.y };
            try p.labels.insert(m.a(), 0, moved);
        }
        i = src.regions.items.len;
        while (i > 0) {
            i -= 1;
            const r = src.regions.items[i];
            if (!inside.box(path, at, r.softArea())) continue;
            var moved = src.regions.orderedRemove(i);
            moved.origin = .{ .x = moved.origin.x + d.x, .y = moved.origin.y + d.y };
            try p.regions.insert(m.a(), 0, moved);
        }
        i = src.art.items.len;
        while (i > 0) {
            i -= 1;
            if (i == index) continue;
            if (!inside.box(path, at, src.art.items[i].box())) continue;
            var moved = src.art.orderedRemove(i);
            moved.at = .{ .x = moved.at.x + d.x, .y = moved.at.y + d.y };
            try p.art.insert(m.a(), 0, moved);
        }
        // The path itself, which is now the panel's edge (its index has
        // moved down by the art taken before it).
        for (src.art.items, 0..) |x, k| if (x.id == edge_art.id) {
            _ = src.art.orderedRemove(k);
            break;
        };
        for (p.labels.items) |x| m.forget(x.id);
        for (p.regions.items) |x| m.forget(x.id);
        for (p.art.items) |x| m.forget(x.id);
        m.replaceMember(edge_art.id, p.id);
        try m.panels.append(m.a(), p);
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// Release panel: the panel goes, its edge (a rectangle, if it had
    /// none) becomes loose line art in its space again, and its labels,
    /// tracks and line art become loose objects there, all where they
    /// were. The edge takes the panel's place in its group. Returns the
    /// edge's ID.
    pub fn releasePanel(m: *Model, panel: usize) Error!ObjectId {
        const p = m.panels.items[panel];
        if (p.unbounded) return error.NoSuchItem;
        const root_before = m.spaces.items[p.space].root;
        const rp = m.panels.items[root_before];
        // From the panel's frame to its space panel's.
        const d: geom.Point = .{ .x = p.origin.x - rp.origin.x, .y = p.origin.y - rp.origin.y };
        var e: PanelArt = p.edge orelse blk: {
            const prim: art_.Primitive = .{ .rect = .{ .w = p.w, .h = p.h } };
            break :blk .{
                .id = m.newId(),
                .name = try m.a().dupe(u8, p.name),
                .at = .{ .x = 0, .y = 0 },
                .shapes = try art_.primitive(m.a(), try m.a().dupe(u8, p.name), prim, .{ .edge = .{ .r = 0x33, .g = 0x33, .b = 0x33 } }),
                .prim = prim,
                .wrap = .none,
            };
        };
        if (e.id == .none) e.id = m.newId();
        e.at = .{ .x = e.at.x + d.x, .y = e.at.y + d.y };
        const dst = &m.panels.items[root_before];
        try dst.art.append(m.a(), e);
        for (p.labels.items) |l| {
            var x = l;
            x.at = .{ .x = x.at.x + d.x, .y = x.at.y + d.y };
            try dst.labels.append(m.a(), x);
        }
        for (p.regions.items) |r| {
            var x = r;
            x.origin = .{ .x = x.origin.x + d.x, .y = x.origin.y + d.y };
            try dst.regions.append(m.a(), x);
        }
        for (p.art.items) |pa| {
            var x = pa;
            x.at = .{ .x = x.at.x + d.x, .y = x.at.y + d.y };
            try dst.art.append(m.a(), x);
        }
        m.replaceMember(p.id, e.id);
        _ = m.panels.orderedRemove(panel);
        for (m.spaces.items) |*sp| if (sp.root > panel) {
            sp.root -= 1;
        };
        m.revision += 1;
        return e.id;
    }

    /// Where `old` is a group's member, `new` takes its place.
    fn replaceMember(m: *Model, old: ObjectId, new: ObjectId) void {
        for (m.spaces.items) |*sp| for (sp.groups.items) |*g| {
            for (g.members.items) |*mb| if (mb.* == old) {
                mb.* = new;
            };
        };
    }

    pub fn removeArt(m: *Model, panel: usize, index: usize) void {
        const gone = m.panels.items[panel].art.orderedRemove(index);
        m.forget(gone.id);
        m.revision += 1;
    }

    pub fn removeLabel(m: *Model, panel: usize, label: usize) void {
        const gone = m.panels.items[panel].labels.orderedRemove(label);
        m.forget(gone.id);
        m.revision += 1;
    }

    /// Sets a style's size as cap height, mm; every label using it changes.
    /// A style sized by its em is sized by cap height from then on.
    pub fn setCapHeight(m: *Model, style: StyleId, cap_height: f64) Error!void {
        if (!(cap_height > 0)) return error.BadSize;
        m.styles.items[style].spec.cap_height = cap_height;
        m.styles.items[style].spec.em_size = null;
        m.revision += 1;
    }

    /// Sets a style's size as its em, mm (a point size: 12 pt is 25.4 × 12
    /// / 72 mm), as other software sizes type: its cap height then follows
    /// from its font. Until the font is resolved, `cap_per_em` of the em
    /// stands in for the cap height.
    pub fn setEmSize(m: *Model, style: StyleId, em: f64) Error!void {
        if (!(em > 0)) return error.BadSize;
        m.styles.items[style].spec.em_size = em;
        m.styles.items[style].spec.cap_height = em * cap_per_em;
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
        m.forget(p.id);
        for (p.labels.items) |l| m.forget(l.id);
        for (p.regions.items) |r| m.forget(r.id);
        for (p.art.items) |pa| m.forget(pa.id);
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
        r.id = m.newId();
        r.name = try m.a().dupe(u8, region.name);
        r.segments = .empty;
        r.path = .empty;
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
        // Segments come as the flow needs them, along its path, within the
        // soft area `count` segments thick.
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
            .hard_break, .paragraph => false,
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

    // Constraints -----------------------------------------------------------

    /// Adds constraint `c` (its ends checked: one axis, objects that
    /// exist). The history then solves, moving what it constrains into
    /// place. Returns its ID.
    pub fn addConstraint(m: *Model, c: Constraint) Error!ObjectId {
        if (c.a.object == .none) return error.BadConstraint;
        if (c.a.feature.vertical() != c.b.feature.vertical()) return error.BadConstraint;
        if (!std.math.isFinite(c.value)) return error.BadConstraint;
        var out = c;
        out.id = m.newId();
        try m.constraints.append(m.a(), out);
        m.revision += 1;
        return out.id;
    }

    fn constraintIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.constraints.items, 0..) |c, i| if (c.id == id) return i;
        return null;
    }

    /// Sets constraint `id`'s value: what it constrains moves to match.
    pub fn setConstraintValue(m: *Model, id: ObjectId, value: f64) Error!void {
        if (!std.math.isFinite(value)) return error.BadConstraint;
        const i = m.constraintIndex(id) orelse return error.NoSuchObject;
        m.constraints.items[i].value = value;
        m.revision += 1;
    }

    pub fn removeConstraint(m: *Model, id: ObjectId) Error!void {
        const i = m.constraintIndex(id) orelse return error.NoSuchObject;
        _ = m.constraints.orderedRemove(i);
        m.revision += 1;
    }

    /// Designates object `id`'s object origin. Nothing moves.
    pub fn setObjectOrigin(m: *Model, id: ObjectId, at: OriginPoint) Error!void {
        for (m.panels.items) |*p| {
            if (p.id == id) {
                p.holds = at;
                m.revision += 1;
                return;
            }
            for (p.regions.items) |*r| if (r.id == id) {
                r.holds = at;
                m.revision += 1;
                return;
            };
            for (p.art.items) |*x| if (x.id == id) {
                x.holds = at;
                m.revision += 1;
                return;
            };
        }
        for (m.spaces.items) |*s| for (s.images.items) |*im| if (im.id == id) {
            im.holds = at;
            m.revision += 1;
            return;
        };
        return error.NoSuchObject;
    }

    // Paragraphs ------------------------------------------------------------

    fn checkParagraph(p: ParagraphStyle) Error!void {
        for ([_]f64{ p.indent_start, p.indent_end, p.space_before, p.space_after, p.line_gap }) |v| if (!(v >= 0)) return error.BadSize;
        if (!std.math.isFinite(p.first)) return error.BadSize;
    }

    /// A new paragraph style. Returns its ID.
    pub fn addParagraphStyle(m: *Model, style: ParagraphStyle) Error!ParaId {
        try checkParagraph(style);
        var s = style;
        s.name = try m.a().dupe(u8, style.name);
        try m.paragraph_styles.append(m.a(), s);
        m.revision += 1;
        return @intCast(m.paragraph_styles.items.len - 1);
    }

    /// Changes paragraph style `id` (its name too): every paragraph in it
    /// follows.
    pub fn setParagraphStyle(m: *Model, id: ParaId, style: ParagraphStyle) Error!void {
        if (id >= m.paragraph_styles.items.len) return error.NoSuchStyle;
        try checkParagraph(style);
        var s = style;
        s.name = try m.a().dupe(u8, style.name);
        m.paragraph_styles.items[id] = s;
        m.revision += 1;
    }

    /// The first "Paragraph N" no paragraph style uses yet.
    pub fn nextParagraphStyleName(m: *const Model, buf: []u8) []const u8 {
        var n: usize = m.paragraph_styles.items.len + 1;
        while (true) : (n += 1) {
            const name = std.fmt.bufPrint(buf, "Paragraph {d}", .{n}) catch return "Paragraph";
            for (m.paragraph_styles.items) |p| {
                if (std.mem.eql(u8, p.name, name)) break;
            } else return name;
        }
    }

    /// Inserts a paragraph separator at position `index` of a track: the
    /// paragraph before it ends, and the one after it is set in `style`
    /// (null: the track's).
    pub fn insertParagraph(m: *Model, panel: usize, region: usize, index: usize, style: ?ParaId) Error!void {
        if (style) |id| if (id >= m.paragraph_styles.items.len) return error.NoSuchStyle;
        try m.place(panel, region, index, .{ .what = .{ .paragraph = style } });
    }

    /// Where the paragraph holding item `index` of a track takes its
    /// style from: the separator before it, or (null) the track.
    pub fn paragraphStart(m: *const Model, panel: usize, region: usize, index: usize) ?usize {
        const items = m.panels.items[panel].regions.items[region].items.items;
        var k = @min(index, items.len);
        while (k > 0) {
            k -= 1;
            if (items[k].what == .paragraph) return k;
        }
        return null;
    }

    /// The paragraph style of the paragraph holding item `index`.
    pub fn paragraphStyleAt(m: *const Model, panel: usize, region: usize, index: usize) ?ParaId {
        const r = m.panels.items[panel].regions.items[region];
        const k = m.paragraphStart(panel, region, index) orelse return r.paragraph;
        return r.items.items[k].what.paragraph;
    }

    /// Sets the paragraph style of the paragraph holding item `index`
    /// (null: none), at its separator or, for the first, on the track.
    pub fn setParagraphAt(m: *Model, panel: usize, region: usize, index: usize, style: ?ParaId) Error!void {
        if (style) |id| if (id >= m.paragraph_styles.items.len) return error.NoSuchStyle;
        const r = &m.panels.items[panel].regions.items[region];
        if (m.paragraphStart(panel, region, index)) |k| {
            r.items.items[k].what = .{ .paragraph = style };
        } else r.paragraph = style;
        m.revision += 1;
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

    /// Older documents' history only: a segment moved by hand, now a
    /// control point where that segment was placed (see `bendPath`).
    pub fn moveSegment(m: *Model, panel: usize, region: usize, segment: usize, solved: []const Segment, along: f64, across: f64, avoid: []const geom.Box) Error!void {
        _ = avoid;
        if (segment >= solved.len) return error.NoSuchRow;
        const here = solved[segment];
        _ = try m.bendPath(panel, region, here.across, here.along + along, here.across + across);
    }

    /// Older documents' history only: the path now keeps its control points.
    pub fn trimSegments(m: *Model, panel: usize, region: usize, count: usize) void {
        _ = m;
        _ = panel;
        _ = region;
        _ = count;
    }

    /// Adds a control point to a track's path at (`along`, `across`) u
    /// from its region's origin. Returns its ID.
    pub fn addControlPoint(m: *Model, panel: usize, region: usize, along: f64, across: f64) Error!ObjectId {
        if (!std.math.isFinite(along) or !std.math.isFinite(across) or across < 0) return error.BadSize;
        const r = &m.panels.items[panel].regions.items[region];
        try m.adoptLegacyPath(r);
        const id = m.newId();
        try r.path.append(m.a(), .{ .id = id, .along = along, .across = across });
        m.revision += 1;
        return id;
    }

    /// Bends a track's path where a segment attaches to it (`at_across`):
    /// the control point there moves to (`along`, `across`), or one is
    /// made there and moved. The segments after it follow the new shape.
    pub fn bendPath(m: *Model, panel: usize, region: usize, at_across: f64, along: f64, across: f64) Error!ObjectId {
        if (!std.math.isFinite(along) or !std.math.isFinite(across) or across < 0) return error.BadSize;
        const r = &m.panels.items[panel].regions.items[region];
        try m.adoptLegacyPath(r);
        for (r.path.items) |*cp| if (@abs(cp.across - at_across) < 1e-6) {
            cp.along = along;
            cp.across = across;
            m.revision += 1;
            return cp.id;
        };
        return m.addControlPoint(panel, region, along, across);
    }

    fn controlPoint(m: *Model, id: ObjectId) ?*ControlPoint {
        for (m.panels.items) |*p| for (p.regions.items) |*r| for (r.path.items) |*cp| if (cp.id == id) return cp;
        return null;
    }

    pub fn moveControlPoint(m: *Model, id: ObjectId, along: f64, across: f64) Error!void {
        if (!std.math.isFinite(along) or !std.math.isFinite(across) or across < 0) return error.BadSize;
        const cp = m.controlPoint(id) orelse return error.NoSuchObject;
        cp.along = along;
        cp.across = across;
        m.revision += 1;
    }

    pub fn removeControlPoint(m: *Model, id: ObjectId) Error!void {
        for (m.panels.items) |*p| for (p.regions.items) |*r| for (r.path.items, 0..) |cp, k| if (cp.id == id) {
            _ = r.path.orderedRemove(k);
            m.revision += 1;
            return;
        };
        return error.NoSuchObject;
    }

    /// An older document's moved origins, made control points (once), so
    /// a change to the path keeps them.
    fn adoptLegacyPath(m: *Model, r: *TileRegion) Error!void {
        if (r.path.items.len > 0) return;
        for (r.segments.items, 0..) |sg, k| if (k > 0 and sg.moved) {
            try r.path.append(m.a(), .{ .id = m.newId(), .along = sg.along, .across = sg.across });
        };
        r.segments.clearRetainingCapacity();
    }

    /// Removes tile `id`: it leaves every track it is in, which reflows.
    pub fn removeTile(m: *Model, id: TileId) void {
        m.unplace(id);
        m.tile(id).removed = true;
        m.revision += 1;
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
    // No segments stored: they come as the flow needs them, along a path
    // that is straight until it is given control points.
    try std.testing.expectEqual(0, region.segments.items.len);
    try std.testing.expectEqual(0, region.path.items.len);
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

test "frames are spaces: moving keeps coordinates and IDs, and arrives as one group; a group moves as one" {
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
    const pid = m.panels.items[p].id;
    const rid = m.panels.items[c].regions.items[r].id;
    const lid = m.panels.items[c].labels.items[1].id;
    const f = try m.addFrame("Frame 1", null);
    try std.testing.expectEqual(1, f);
    const froot = m.spaces.items[f].root;
    const g = try m.moveToSpace(&.{ pid, rid, lid }, f);
    // Panels change space; loose objects move to the frame's own panel,
    // coordinates and IDs kept.
    try std.testing.expectEqual(f, m.spaceOf(p));
    try std.testing.expectEqual(10, m.panels.items[p].origin.x);
    try std.testing.expectEqual(0, m.panels.items[c].regions.items.len);
    try std.testing.expectEqualStrings("Stays", m.panels.items[c].labels.items[0].content);
    try std.testing.expectEqual(Member{ .region = .{ .panel = froot, .index = 0 } }, m.locate(rid).?);
    try std.testing.expectEqual(Member{ .label = .{ .panel = froot, .index = 0 } }, m.locate(lid).?);
    // One group, named after where it came from; one move places all.
    const group = m.group(g).?;
    try std.testing.expectEqualStrings("from Canvas", group.name);
    try std.testing.expectEqual(3, group.members.items.len);
    try m.moveGroup(g, -10, 5);
    try std.testing.expectEqual(0, m.panels.items[p].origin.x);
    try std.testing.expectEqual(90, m.panels.items[froot].regions.items[0].origin.x);
    try std.testing.expectEqual(75, m.panels.items[froot].labels.items[0].at.y);
    // Copying leaves the original, and copies get new IDs (and tiles new
    // designators).
    const tiles_before = m.tiles.items.len;
    const cg = try m.copyToSpace(&.{pid}, 0);
    try std.testing.expectEqual(f, m.spaceOf(p));
    const copy_id = m.group(cg).?.members.items[0];
    try std.testing.expect(copy_id != pid);
    try std.testing.expectEqual(0, m.spaceOfId(copy_id).?);
    try std.testing.expectEqual(tiles_before, m.tiles.items.len);
    _ = try m.copyToSpace(&.{rid}, 0);
    try std.testing.expectEqual(tiles_before + 1, m.tiles.items.len);
    try std.testing.expectEqualStrings("T2", m.tiles.items[tiles_before].designator);
    // A frame's boundary, as Fit frame sets it.
    try m.setFrameBound(f, .{ .x0 = -5, .y0 = 0, .x1 = 150, .y1 = 100 });
    try std.testing.expectEqual(150, m.spaces.items[f].bound.?.x1);
    try std.testing.expectError(error.NoSuchItem, m.setFrameBound(0, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    // Objects of two spaces cannot move together.
    try std.testing.expectError(error.NoSuchItem, m.moveToSpace(&.{ pid, copy_id }, 0));
    try m.ungroup(g);
    try std.testing.expectEqual(null, m.group(g));
}

test "groups made in place nest, survive other objects going, move as one, and ungroup into their parent" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    var ids: [4]ObjectId = undefined;
    for (&ids, 0..) |*id, i| {
        const li = try m.addLabel(c, .{ .at = .{ .x = @floatFromInt(i * 10), .y = 0 }, .content = "L" });
        id.* = m.panels.items[c].labels.items[li].id;
    }
    // A and B grouped; that group and C grouped: nested.
    const inner = try m.makeGroup(&.{ ids[0], ids[1] }, "inner");
    const outer = try m.makeGroup(&.{ inner, ids[2] }, "outer");
    try std.testing.expectEqual(outer, m.topLevel(ids[0]));
    try std.testing.expectEqual(inner, m.parentGroup(ids[0]).?);
    var all: std.ArrayList(ObjectId) = .empty;
    try m.leaves(outer, &all);
    try std.testing.expectEqual(3, all.items.len);
    // Removing D (in no group) and then C: the groups stay, minus C.
    m.removeLabel(c, 3);
    m.removeLabel(c, 2);
    try std.testing.expectEqual(1, m.group(outer).?.members.items.len);
    // One move moves everything left in it, by ID.
    try m.moveGroup(outer, 5, 0);
    try std.testing.expectEqual(5, m.panels.items[c].labels.items[0].at.x);
    try std.testing.expectEqual(15, m.panels.items[c].labels.items[1].at.x);
    // Ungrouping the inner group hands its members to the outer one.
    try m.ungroup(inner);
    try std.testing.expectEqual(2, m.group(outer).?.members.items.len);
    try std.testing.expectEqual(outer, m.parentGroup(ids[0]).?);
    // Removing the last members removes the emptied group.
    m.removeLabel(c, 0);
    m.removeLabel(c, 0);
    try std.testing.expectEqual(null, m.group(outer));
}

test "a closed path becomes a panel with what it encloses, cutouts included, and releases back" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A rounded rectangle 100 x 60 at (10, 10), two circular cutouts in
    // it, a label and a track inside, and a label outside.
    const prim: art_.Primitive = .{ .rounded = .{ .w = 100, .h = 60, .r = 6 } };
    const outline = try m.addArt(c, .{ .name = "Outline", .at = .{ .x = 10, .y = 10 }, .shapes = try art_.primitive(a, "Outline", prim, .{}), .prim = prim });
    for ([_]f64{ 20, 90 }) |x| {
        const hole: art_.Primitive = .{ .circle = 6 };
        const ai = try m.addArt(c, .{ .name = "Hole", .at = .{ .x = x, .y = 15 }, .shapes = try art_.primitive(a, "Hole", hole, .{}), .prim = hole });
        try m.setArtCutout(c, ai, true);
    }
    _ = try m.addLabel(c, .{ .at = .{ .x = 40, .y = 50 }, .content = "Inside" });
    _ = try m.addLabel(c, .{ .at = .{ .x = 200, .y = 50 }, .content = "Outside" });
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    _ = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = 40, .y = 40 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    const edge_id = m.panels.items[c].art.items[outline].id;
    const g = try m.makeGroup(&.{ edge_id, m.panels.items[c].labels.items[1].id }, "g");

    const p = try m.makePanel(c, outline);
    const panel = m.panels.items[p];
    try std.testing.expect(!panel.unbounded);
    try std.testing.expectEqual(10, panel.origin.x);
    try std.testing.expectEqual(100, panel.w);
    try std.testing.expect(panel.edge != null);
    try std.testing.expectEqual(1, panel.labels.items.len);
    try std.testing.expectEqual(1, panel.regions.items.len);
    try std.testing.expectEqual(2, panel.art.items.len);
    try std.testing.expect(panel.art.items[0].cutout);
    // In the panel's frame now: the label at (40, 50) on the canvas.
    try std.testing.expectEqual(30, panel.labels.items[0].at.x);
    try std.testing.expectEqual(40, panel.labels.items[0].at.y);
    // Left on the canvas: only the outside label.
    try std.testing.expectEqual(0, m.panels.items[c].art.items.len);
    try std.testing.expectEqual(1, m.panels.items[c].labels.items.len);
    // The panel took the outline's place in its group.
    try std.testing.expectEqual(g, m.parentGroup(panel.id).?);

    // It moves with all of it; released, everything is loose again where
    // the move left it.
    try m.movePanel(p, .{ .x = 15, .y = 10 });
    const back = try m.releasePanel(p);
    try std.testing.expectEqual(1, m.panels.items.len);
    const root = m.panels.items[c];
    try std.testing.expectEqual(3, root.art.items.len);
    try std.testing.expectEqual(2, root.labels.items.len);
    try std.testing.expectEqual(1, root.regions.items.len);
    try std.testing.expectEqual(edge_id, back);
    try std.testing.expectEqual(15, root.art.items[0].at.x);
    try std.testing.expectEqual(45, root.labels.items[1].at.x);
    try std.testing.expectEqual(45, root.regions.items[0].origin.x);
    try std.testing.expectEqual(g, m.parentGroup(edge_id).?);
    // A rounded rectangle's corner can be changed.
    try m.setArtCorner(c, 0, 2);
    try std.testing.expectEqual(2, root.art.items[0].prim.rounded.r);
}

test "a view shows another space live, at a scale, and views that would show themselves are refused" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const f = try m.addFrame("Front", .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 50 });
    const g = try m.addFrame("Back", null);
    // A view of the front frame on the canvas, at half size.
    const v = try m.addView(0, f, .{ .x = 200, .y = 10 }, 0.5);
    const view = m.spaces.items[0].views.items[v];
    try std.testing.expectEqualStrings("View of Front", view.name);
    try std.testing.expect(view.id != .none);
    // The frame's corner lands at the view's place; its far corner at half.
    const far = view.toHost(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 50 });
    try std.testing.expectEqual(250, far.x);
    try std.testing.expectEqual(35, far.y);
    // A space in itself, or in a space it shows, is refused.
    try std.testing.expectError(error.ViewCycle, m.addView(f, f, .{ .x = 0, .y = 0 }, 1));
    try std.testing.expectError(error.ViewCycle, m.addView(f, 0, .{ .x = 0, .y = 0 }, 1));
    // Front shows Back; Back may not then show Front, or the canvas.
    _ = try m.addView(f, g, .{ .x = 0, .y = 0 }, 1);
    try std.testing.expectError(error.ViewCycle, m.addView(g, f, .{ .x = 0, .y = 0 }, 1));
    try std.testing.expectError(error.ViewCycle, m.addView(g, 0, .{ .x = 0, .y = 0 }, 1));
    // The canvas may show Back too: no loop.
    _ = try m.addView(0, g, .{ .x = 0, .y = 100 }, 2);
    try m.setViewScale(0, v, 0.25);
    try m.moveView(0, v, .{ .x = 5, .y = 5 });
    try std.testing.expectEqual(0.25, m.spaces.items[0].views.items[v].scale);
    m.removeView(0, v);
    try std.testing.expectEqual(1, m.spaces.items[0].views.items.len);
}

test "layers: a background image under a panel, and blending on an engrave layer flagged" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const sp = &m.spaces.items[0];
    // Every space starts with one layer, its base.
    try std.testing.expectEqual(1, sp.layers.items.len);
    try std.testing.expectEqual(sp.base_layer, sp.layers.items[0].id);
    // A background layer, moved under the base layer, half opaque.
    var buf: [32]u8 = undefined;
    const bg = try m.addLayer(0, m.nextLayerName(0, &buf));
    try std.testing.expectEqualStrings("Layer 2", m.spaces.items[0].layers.items[bg].name);
    const at = try m.moveLayer(0, bg, false);
    try std.testing.expectEqual(0, at);
    var l = m.spaces.items[0].layers.items[0];
    l.name = "Background";
    l.opacity = 0.5;
    try m.setLayer(0, 0, l);
    const bg_id = m.spaces.items[0].layers.items[0].id;
    // An image 400 × 200 px placed 100 mm wide: 50 mm tall, 101.6 dpi.
    const im = try m.addImage(0, "photo.png", "not decoded here", 400, 200, .{ .x = 0, .y = 0 }, 100, bg_id);
    const image = m.spaces.items[0].images.items[im];
    try std.testing.expectEqual(50, image.h);
    try std.testing.expectApproxEqAbs(101.6, image.dpi(), 1e-9);
    // A panel on the base layer, above it.
    const p = try m.placePanel(.{ .name = "Front", .origin = .{ .x = 10, .y = 10 }, .w = 60, .h = 30 });
    try std.testing.expectEqual(1, m.spaces.items[0].layerIndex(m.panels.items[p].layer).?);
    // The image prints under 150 dpi: flagged. Blending on a print layer
    // is not.
    {
        const issues = try m.layerIssues(std.testing.allocator);
        defer std.testing.allocator.free(issues);
        try std.testing.expectEqual(1, issues.len);
        try std.testing.expectEqual(.low_resolution, issues[0].kind);
    }
    // Set to engrave, the half-opaque layer is flagged; resolution is not
    // checked for engraving here.
    l = m.spaces.items[0].layers.items[0];
    l.output = .engrave;
    l.blend = .multiply;
    try m.setLayer(0, 0, l);
    {
        const issues = try m.layerIssues(std.testing.allocator);
        defer std.testing.allocator.free(issues);
        try std.testing.expectEqual(1, issues.len);
        try std.testing.expectEqual(.blend_ignored, issues[0].kind);
        try std.testing.expectEqual(0, issues[0].layer);
    }
    // A layer in use cannot be removed, nor the base layer; an empty one
    // can.
    try std.testing.expectError(error.NoRoom, m.removeLayer(0, 0));
    try std.testing.expectError(error.NoRoom, m.removeLayer(0, 1));
    m.removeImage(0, im);
    try m.removeLayer(0, 0);
    try std.testing.expectEqual(1, m.spaces.items[0].layers.items.len);
    // A frame has its own base layer; a panel moved there lands on it.
    const f = try m.addFrame("F", null);
    try std.testing.expectEqual(1, m.spaces.items[f].layers.items.len);
    _ = try m.moveToSpace(&.{m.panels.items[p].id}, f);
    try std.testing.expectEqual(.none, m.panels.items[p].layer);
}

test "composed fonts: members in order, styles set in them, and a font in use kept" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 3 });
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Font 1", m.nextFontName(&buf));
    const f = try m.addFont("Legend", .{ .family = "Inter", .style = "Medium" });
    try std.testing.expectEqualStrings("Font 2", m.nextFontName(&buf));
    try m.setFontMain(f, .{ .family = "Inter", .style = "Medium" }, .{ .family = "Inter", .style = "Medium Italic" });
    // A fallback, then Greek from another family taken before it.
    var greek_ranges = [_]engine.style.Range{.{ .first = 0x0370, .last = 0x03FF }};
    _ = try m.addFontMember(f, 99, .{ .font = .{ .family = "Noto Sans Symbols" } });
    const g = try m.addFontMember(f, 0, .{ .font = .{ .family = "GFS Didot" }, .coverage = .{ .ranges = &greek_ranges }, .match = .x_height, .shift = -0.02 });
    try std.testing.expectEqual(0, g);
    // The model keeps its own copy of the ranges.
    greek_ranges[0].last = 0;
    const cf = m.fonts.items[m.fontIndex(f).?];
    try std.testing.expectEqual(2, cf.members.items.len);
    try std.testing.expectEqual(0x03FF, cf.members.items[0].coverage.ranges[0].last);
    try std.testing.expectEqual(1, try m.moveFontMember(f, 0, false));
    try std.testing.expectEqualStrings("Noto Sans Symbols", m.fonts.items[0].members.items[0].font.family);

    try m.setStyleFont(body, f);
    try std.testing.expectEqual(1, m.fontUsers(f));
    try std.testing.expectError(error.FontInUse, m.removeFont(f));
    try std.testing.expectError(error.NoSuchFont, m.setStyleFont(body, @enumFromInt(9999)));
    try m.setStyleFont(body, .none);
    try m.removeFontMember(f, 0);
    try m.removeFont(f);
    try std.testing.expectEqual(0, m.fonts.items.len);
}
