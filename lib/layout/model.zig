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
pub const sketch_ = @import("graven_sketch");
const constrain_ = @import("constrain.zig");
const edit_ = @import("edit.zig");

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
    /// A sketch its tiles are drawn from, in place of `art`.
    sketch: ?PrototypeSketch = null,
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
    /// Its own values for its prototype's sketch parameters (a homing bump
    /// switched on); the sketch's own expressions give the rest.
    params: std.ArrayList(TileParam) = .empty,
};

pub const TileParam = struct { name: []const u8, value: f64 };

/// A tile prototype's own copy of a sketch (see `Model.applySketch`): how its
/// tiles are drawn, solved again for each tile's size.
pub const PrototypeSketch = struct {
    /// The copy's own ID.
    id: ObjectId,
    /// The sketch it was copied from.
    from: ObjectId,
    sketch: sketch_.Sketch,
    /// The parameters that take a tile's horizontal and vertical size, mm.
    width_param: []const u8,
    height_param: []const u8,
    /// Where the sketch's origin sits from the tile's origin (its pitch
    /// box's bottom-left corner), mm.
    offset: geom.Point = .{ .x = 0, .y = 0 },
};

/// A run of label markup in a track's flow: words, an equation, or both
/// (equations are markup too). For now a run is one unbreakable item, set
/// as a single line in its style; breaking between its words comes later.
pub const Run = struct {
    style: StyleId = 0,
    content: []const u8,
    /// An equation, built in equation mode: its own item, which text typed
    /// in the flow beside it does not join, and which no run is joined to.
    equation: bool = false,
};

/// A place in a track's flow: before item `index`, or `offset` bytes into
/// the markup of the run there.
pub const FlowPos = struct { index: usize, offset: u32 = 0 };

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

/// A track by its panel and its index there.
pub const TrackRef = struct { panel: usize, region: usize };

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
    /// The track its flow goes on into once this one is full (`.none`:
    /// none). Tracks joined so make a thread: one flow, stored on the
    /// thread's first track, runs through each in order.
    next: ObjectId = .none,
    /// The flow, in order. A tile thicker than its segment (a 2 u tall
    /// key) reaches into the segments after it, closing the stretch it
    /// covers there; their content flows around it.
    items: std.ArrayList(Item) = .empty,

    /// Where an unshaped track's segments attach to its path, u: their
    /// middle. Every segment is bound to the path by its centre.
    pub fn middle(r: TileRegion) f64 {
        return r.segmentLength() / 2;
    }

    /// The path's points, sorted across, into `buf`: its control points
    /// (or an older document's moved origins, which were segment starts), and
    /// a start down the middle (see `middle`) unless a point is there or
    /// before.
    pub fn pathPoints(r: TileRegion, buf: []ControlPoint) []ControlPoint {
        var n: usize = 0;
        if (r.path.items.len > 0) {
            for (r.path.items) |cp| if (n < buf.len) {
                buf[n] = cp;
                n += 1;
            };
        } else for (r.segments.items, 0..) |sg, k| if (k > 0 and sg.moved and n < buf.len) {
            buf[n] = .{ .along = sg.along + r.middle(), .across = sg.across };
            n += 1;
        };
        var has_start = false;
        for (buf[0..n]) |cp| if (cp.across <= 1e-9) {
            has_start = true;
        };
        if (!has_start and n < buf.len) {
            buf[n] = .{ .along = r.middle(), .across = 0 };
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



    /// The band of a segment attached to the path at `s`, mm in the
    /// panel frame: a whole segment's length along, centred on `s` (the
    /// path binds each segment by its centre; its paragraph's alignment only
    /// arranges what is in it), one pitch across.
    pub fn boxAt(r: TileRegion, s: Segment) geom.Box {
        const across = s.across * r.pitch;
        const length = r.segmentLength() * r.pitch;
        const shift = (s.along - r.middle()) * r.pitch;
        return if (r.major == .row)
            .{ .x0 = r.origin.x + shift, .x1 = r.origin.x + shift + length, .y1 = r.origin.y - across, .y0 = r.origin.y - across - r.pitch }
        else
            .{ .x0 = r.origin.x + across, .x1 = r.origin.x + across + r.pitch, .y1 = r.origin.y - shift, .y0 = r.origin.y - shift - length };
    }

    /// How far across its reserved space reaches, u: as many segments as
    /// it was drawn out for.
    pub fn crossLength(r: TileRegion) f64 {
        return if (r.major == .row) r.h else r.w;
    }

    /// Where the track's boundary is along at `across`, u from its origin:
    /// a whole segment's length centred on the path. The path and the
    /// segment length bound the track, so a bent path takes its boundary
    /// with it.
    pub fn edgesAt(r: TileRegion, across: f64) [2]f64 {
        const c = r.pathAt(across);
        return .{ c - r.middle(), c + r.middle() };
    }

    /// The box around the track's boundary, mm in the panel frame: its
    /// reserved space as the path shifts it along.
    pub fn bounds(r: TileRegion) geom.Box {
        var lo: f64 = 0;
        var hi: f64 = r.segmentLength();
        const n: usize = 64;
        const reach = r.crossLength();
        for (0..n + 1) |k| {
            const e = r.edgesAt(reach * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
            if (k == 0) {
                lo = e[0];
                hi = e[1];
            }
            lo = @min(lo, e[0]);
            hi = @max(hi, e[1]);
        }
        var b = r.softArea();
        if (r.major == .row) {
            b.x0 = r.origin.x + lo * r.pitch;
            b.x1 = r.origin.x + hi * r.pitch;
        } else {
            b.y1 = r.origin.y - lo * r.pitch;
            b.y0 = r.origin.y - hi * r.pitch;
        }
        return b;
    }

    /// The space reserved for its segments as drawn out, mm in the panel
    /// frame: unshaped, the track's boundary; its frame for constraints.
    pub fn softArea(r: TileRegion) geom.Box {
        return .{ .x0 = r.origin.x, .x1 = r.origin.x + r.w * r.pitch, .y1 = r.origin.y, .y0 = r.origin.y - r.h * r.pitch };
    }
};

/// The length along a track, or across tracks.
pub const Axis = enum { along, across };

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
    /// Views of the document's sketches placed in it: what is drawn in it
    /// with a sketch.
    sketch_views: std.ArrayList(SketchView) = .empty,

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
/// A sketch drawn in a space: its geometry and constraints (see
/// `graven_sketch`), in its own frame, whose origin sits at `at`.
pub const SketchItem = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// True while the name is one the app gave it (Sketch 1).
    default_name: bool = false,
    sketch: sketch_.Sketch,
};

/// A view of a sketch placed in a space: what shows there of the sketch,
/// its origin at `at`. A sketch is the document's; drawing one on a canvas
/// or in a frame places a view of it there.
pub const SketchView = struct {
    id: ObjectId = .none,
    /// The sketch (its `SketchItem.id`).
    sketch: ObjectId,
    /// Where the sketch's origin sits, mm in the space.
    at: geom.Point,
    layer: ObjectId = .none,
};

/// One change to a sketch, as `editSketch` makes it (in the sketch's own
/// frame, mm and radians).
pub const SketchEdit = union(enum) {
    point: struct { at: geom.Point, construction: bool = false },
    segment: struct { a: geom.Point, b: geom.Point, construction: bool = false },
    circle: struct { c: geom.Point, r: f64, construction: bool = false },
    /// About `c`, counter-clockwise from `a` to `b`'s angle.
    arc: struct { c: geom.Point, a: geom.Point, b: geom.Point, construction: bool = false },
    line: struct { through: geom.Point, angle: f64 },
    ray: struct { o: geom.Point, angle: f64 },
    construction: struct { g: sketch_.GeomId, on: bool },
    remove: sketch_.GeomId,
    constrain: sketch_.Constraint,
    unconstrain: sketch_.ConstraintId,
    value: struct { c: sketch_.ConstraintId, value: f64 },
    /// A point moved towards `to` as far as its constraints let it.
    drag: struct { p: sketch_.PointRef, to: geom.Point },
    /// A dimension made reference (it reports) or driving again.
    reference: struct { c: sketch_.ConstraintId, on: bool },
    /// A dimension's expression (empty: its plain value).
    expr: struct { c: sketch_.ConstraintId, text: []const u8 },
    /// A parameter added or changed.
    param: struct { name: []const u8, expr: []const u8 },
    unparam: []const u8,
    /// Construction geometry output while a parameter is not 0 (empty name:
    /// never).
    physical_when: struct { g: sketch_.GeomId, param: []const u8 },
};

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

/// What a grid's instances are, as made: a part (a key, drawn as its
/// prototype draws it), a hole (its prototype's outline cut through the
/// panel: the prototype with inside and outside swapped), or a legend (only
/// its prototype's slots and their labels).
pub const GridRole = enum { part, hole, legend };

/// One kind of thing a grid stamps at its points: a prototype, as what,
/// at what size and where from the point. Every instance of a stamp shares
/// its size, so changing it changes them all.
pub const Stamp = struct {
    id: ObjectId = .none,
    name: []const u8,
    prototype: PrototypeId,
    role: GridRole = .part,
    /// The box an instance on one point takes, mm. An instance spanning
    /// more points grows by the pitch for each point more.
    w: f64,
    h: f64,
    /// From the point (or the middle of the points spanned) to the box's
    /// centre, mm.
    offset: geom.Point = .{ .x = 0, .y = 0 },
};

/// A tile made from a stamp and bound to a grid point: it sits where the
/// point is, and follows it. Spanning more than one point, it sits at
/// their middle. Left behind when its grid lost the point, it keeps its
/// place (`loose`) and is no longer bound.
pub const GridInstance = struct {
    tile: TileId,
    stamp: ObjectId,
    col: u32,
    row: u32,
    cols: u32 = 1,
    rows: u32 = 1,
    /// Its box's centre, mm in the panel frame, once unbound.
    loose: ?geom.Point = null,
};

/// How a Cartesian grid's points lie: counts, spacing and stretch.
pub const GridShape = struct {
    cols: u32,
    rows: u32,
    /// Between points, mm, before stretching.
    pitch_x: f64,
    pitch_y: f64,
    /// Scales the spacing, so the whole grid stretches.
    stretch_x: f64 = 1,
    stretch_y: f64 = 1,

    pub fn stepX(g: GridShape) f64 {
        return g.pitch_x * g.stretch_x;
    }

    pub fn stepY(g: GridShape) f64 {
        return g.pitch_y * g.stretch_y;
    }
};

/// A Cartesian grid on a panel: construction lines through its points
/// (columns left to right, rows top to bottom from `origin`), adding and
/// removing points as its counts change. Instances of its stamps are
/// bound to its points. A grid may follow another (`link`), on this panel
/// or another part: it then takes that grid's shape, so the two keep in
/// step (keys over the holes they come through).
pub const Grid = struct {
    id: ObjectId = .none,
    name: []const u8,
    default_name: bool = false,
    /// Point (0, 0), the top-left one, mm in the panel frame.
    origin: geom.Point,
    shape: GridShape,
    /// The grid whose shape it takes, if any.
    link: ObjectId = .none,
    stamps: std.ArrayList(Stamp) = .empty,
    instances: std.ArrayList(GridInstance) = .empty,
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
    /// The sketch whose outlines it is made from (see
    /// `Model.makeSketchPanel`), and where that sketch's origin sits in the
    /// space; `.none` for a panel of another kind. Its edge follows the
    /// sketch.
    sketch: ObjectId = .none,
    sketch_at: geom.Point = .{ .x = 0, .y = 0 },
    /// Cuts by nesting, counting the outlines inward: between an odd and
    /// the even one inside it is cut, so inside a hole is an island, and so
    /// on. Without islands only the holes in the outermost outline are cut.
    islands: bool = true,
    /// Its grids, whose instances are tiles bound to their points.
    grids: std.ArrayList(Grid) = .empty,

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
    /// The document's sketches; spaces hold views of them.
    sketches: std.ArrayList(SketchItem) = .empty,
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

    pub const Error = Allocator.Error || error{ NoRoom, DuplicateDesignator, NoSuchPrototype, NoSuchTile, NoSuchSlot, NoSuchLayer, DuplicateSlot, PrototypeInUse, NoSuchRow, NoSuchItem, NoSuchStyle, BadSize, OffSheet, NotCompliant, ViewCycle, NoSuchFont, FontInUse, NoSuchObject, BadConstraint, BadJoin, NotFullyConstrained, NotEnclosed, SketchInUse } || sketch_.Error;

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
            for (p.regions.items, 0..) |r, i| if (r.id == id) return .{ .region = .{ .panel = pi, .index = i } };
            for (p.art.items, 0..) |x, i| if (x.id == id) return .{ .art = .{ .panel = pi, .index = i } };
        }
        return null;
    }

    /// The ID of the object at `loc`.
    pub fn idAt(m: *const Model, loc: Member) ObjectId {
        return switch (loc) {
            .panel => |pi| m.panels.items[pi].id,
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
    /// Puts each of objects `ids` at its box in `boxes` (each in its
    /// parent's frame): moved, and resized where its kind can be. The
    /// constraints are then solved, so what they bind goes back and what
    /// keeps to these follows.
    pub fn placeObjects(m: *Model, ids: []const ObjectId, boxes: []const geom.Box) Error!void {
        if (ids.len != boxes.len) return error.NoSuchObject;
        for (ids, boxes) |id, b| {
            if (!(b.width() >= 0 and b.height() >= 0)) return error.BadSize;
            if (!constrain_.setBox(m, id, b)) return error.NoSuchObject;
        }
        m.revision += 1;
    }

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
        // A copy starts a thread of its own (copies of a whole panel are
        // rejoined by `copyPanel`).
        c.next = .none;
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
        c.art = .empty;
        for (p.regions.items) |r| try c.regions.append(m.a(), try m.copyRegion(r));
        // Its threads, among the copies.
        for (p.regions.items, 0..) |r, k| if (m.regionIndex(pi, r.next)) |n| {
            c.regions.items[k].next = c.regions.items[n].id;
        };
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
                if (base and (p.regions.items.len > 0 or p.art.items.len > 0)) return true;
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

    /// Starts a new sketch, with a view of it in space `space`, its origin
    /// at `at`. Returns the sketch's index; the view is the space's last.
    pub fn addSketch(m: *Model, space: usize, name: []const u8, at: geom.Point) Error!usize {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        const id = m.newId();
        try m.sketches.append(m.a(), .{
            .id = id,
            .name = try m.a().dupe(u8, name),
            .sketch = try sketch_.Sketch.init(m.a()),
        });
        try m.spaces.items[space].sketch_views.append(m.a(), .{ .id = m.newId(), .sketch = id, .at = at });
        m.revision += 1;
        return m.sketches.items.len - 1;
    }

    /// Places another view of sketch `index` in space `space`. Returns the
    /// view's index.
    pub fn addSketchView(m: *Model, space: usize, index: usize, at: geom.Point) Error!usize {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        const sk = try m.sketchAt(index);
        const list = &m.spaces.items[space].sketch_views;
        try list.append(m.a(), .{ .id = m.newId(), .sketch = sk.id, .at = at });
        m.revision += 1;
        return list.items.len - 1;
    }

    pub fn moveSketchView(m: *Model, space: usize, view: usize, at: geom.Point) Error!void {
        (try m.sketchView(space, view)).at = at;
        m.revision += 1;
    }

    pub fn removeSketchView(m: *Model, space: usize, view: usize) Error!void {
        _ = try m.sketchView(space, view);
        _ = m.spaces.items[space].sketch_views.orderedRemove(view);
        m.revision += 1;
    }

    /// Removes sketch `index` and its views. Refused while a panel is made
    /// from it.
    pub fn removeSketch(m: *Model, index: usize) Error!void {
        const id = (try m.sketchAt(index)).id;
        for (m.panels.items) |pn| if (pn.sketch == id) return error.SketchInUse;
        for (m.spaces.items) |*sp| {
            var k = sp.sketch_views.items.len;
            while (k > 0) {
                k -= 1;
                if (sp.sketch_views.items[k].sketch == id) _ = sp.sketch_views.orderedRemove(k);
            }
        }
        _ = m.sketches.orderedRemove(index);
        m.revision += 1;
    }

    pub fn renameSketch(m: *Model, index: usize, name: []const u8) Error!void {
        const sk = try m.sketchAt(index);
        sk.name = try m.a().dupe(u8, name);
        sk.default_name = false;
        m.revision += 1;
    }

    pub fn sketchAt(m: *Model, index: usize) Error!*SketchItem {
        if (index >= m.sketches.items.len) return error.NoSuchItem;
        return &m.sketches.items[index];
    }

    /// The index of the sketch with ID `id`.
    pub fn sketchIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.sketches.items, 0..) |sk, i| if (sk.id == id) return i;
        return null;
    }

    pub fn sketchView(m: *Model, space: usize, view: usize) Error!*SketchView {
        if (space >= m.spaces.items.len or view >= m.spaces.items[space].sketch_views.items.len) return error.NoSuchItem;
        return &m.spaces.items[space].sketch_views.items[view];
    }

    /// Makes a panel of the view `view` of an enclosed sketch, in space
    /// `space`: the view becomes the panel, its edge the sketch's outlines
    /// (cut by nesting), and it follows the sketch. What the outermost
    /// outline encloses (tracks, line art) moves onto the panel, keeping
    /// where it is. Refused unless the sketch's output has exactly one
    /// outermost closed outline. Returns the panel's index.
    pub fn makeSketchPanel(m: *Model, space: usize, view: usize) Error!usize {
        const v = (try m.sketchView(space, view)).*;
        const si = m.sketchIndex(v.sketch) orelse return error.NoSuchItem;
        var name_buf: [64]u8 = undefined;
        const name = m.nextPanelName(&name_buf, "Panel");
        var p: Panel = .{
            .id = m.newId(),
            .name = try m.a().dupe(u8, name),
            .default_name = true,
            .space = space,
            .w = 1,
            .h = 1,
            .sketch = v.sketch,
            .sketch_at = v.at,
            .layer = v.layer,
        };
        const edge = (try m.sketchEdge(&m.sketches.items[si].sketch, true)) orelse return error.NotEnclosed;
        p.origin = .{ .x = v.at.x + edge.min.x, .y = v.at.y + edge.min.y };
        p.w = edge.w;
        p.h = edge.h;
        p.edge = edge.art;
        // What the outermost outline encloses moves onto the panel.
        const root = m.spaces.items[space].root;
        const rp = m.panels.items[root];
        const outer: geom.Outline = .{ .contours = edge.art.shapes[0].outline.contours[0..1] };
        const off: geom.Point = .{ .x = p.origin.x - rp.origin.x, .y = p.origin.y - rp.origin.y };
        const inside = struct {
            fn f(o: geom.Outline, d: geom.Point, q: geom.Point) bool {
                return art_.contains(o, .{ .x = q.x - d.x, .y = q.y - d.y });
            }
            fn box(o: geom.Outline, d: geom.Point, bx: geom.Box) bool {
                if (bx.isEmpty()) return false;
                return f(o, d, .{ .x = bx.x0, .y = bx.y0 }) and f(o, d, .{ .x = bx.x1, .y = bx.y0 }) and
                    f(o, d, .{ .x = bx.x0, .y = bx.y1 }) and f(o, d, .{ .x = bx.x1, .y = bx.y1 });
            }
        };
        const src = &m.panels.items[root];
        const d: geom.Point = .{ .x = -off.x, .y = -off.y };
        var i = src.regions.items.len;
        while (i > 0) {
            i -= 1;
            const rg = src.regions.items[i];
            if (!inside.box(outer, off, rg.bounds())) continue;
            var moved = src.regions.orderedRemove(i);
            moved.origin = .{ .x = moved.origin.x + d.x, .y = moved.origin.y + d.y };
            try p.regions.insert(m.a(), 0, moved);
        }
        i = src.art.items.len;
        while (i > 0) {
            i -= 1;
            if (!inside.box(outer, off, src.art.items[i].box())) continue;
            var moved = src.art.orderedRemove(i);
            moved.at = .{ .x = moved.at.x + d.x, .y = moved.at.y + d.y };
            try p.art.insert(m.a(), 0, moved);
        }
        for (p.regions.items) |x| m.forget(x.id);
        for (p.art.items) |x| m.forget(x.id);
        _ = m.spaces.items[space].sketch_views.orderedRemove(view);
        try m.panels.append(m.a(), p);
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// Whether a sketch panel cuts islands (see `Panel.islands`).
    // Grids.

    /// The shape grid `gi` of panel `panel` has: its own, or the one it
    /// follows (through any chain of links).
    pub fn gridShape(m: *const Model, panel: usize, gi: usize) GridShape {
        var g = &m.panels.items[panel].grids.items[gi];
        var hops: usize = 0;
        while (g.link != .none and hops < 16) : (hops += 1) {
            const at = m.findGrid(g.link) orelse break;
            g = &m.panels.items[at.panel].grids.items[at.index];
        }
        return g.shape;
    }

    /// The panel and index of grid `id`.
    pub fn findGrid(m: *const Model, id: ObjectId) ?struct { panel: usize, index: usize } {
        if (id == .none) return null;
        for (m.panels.items, 0..) |p, pi| for (p.grids.items, 0..) |g, gi| {
            if (g.id == id) return .{ .panel = pi, .index = gi };
        };
        return null;
    }

    /// Where point (`col`, `row`) of grid `gi` is, mm in the panel frame.
    pub fn gridPoint(m: *const Model, panel: usize, gi: usize, col: f64, row: f64) geom.Point {
        const g = m.panels.items[panel].grids.items[gi];
        const sh = m.gridShape(panel, gi);
        return .{ .x = g.origin.x + col * sh.stepX(), .y = g.origin.y - row * sh.stepY() };
    }

    /// The stamp `id` of grid `gi`, by index.
    pub fn stampIndex(m: *const Model, panel: usize, gi: usize, id: ObjectId) ?usize {
        for (m.panels.items[panel].grids.items[gi].stamps.items, 0..) |st, i| if (st.id == id) return i;
        return null;
    }

    /// The box instance `ii` of grid `gi` takes, mm in the panel frame.
    pub fn instanceBox(m: *const Model, panel: usize, gi: usize, ii: usize) ?geom.Box {
        const g = m.panels.items[panel].grids.items[gi];
        const inst = g.instances.items[ii];
        const st = g.stamps.items[m.stampIndex(panel, gi, inst.stamp) orelse return null];
        const sh = m.gridShape(panel, gi);
        const w = st.w + @as(f64, @floatFromInt(inst.cols - 1)) * sh.stepX();
        const h = st.h + @as(f64, @floatFromInt(inst.rows - 1)) * sh.stepY();
        const c: geom.Point = inst.loose orelse blk: {
            const p = m.gridPoint(panel, gi, @as(f64, @floatFromInt(inst.col)) + @as(f64, @floatFromInt(inst.cols - 1)) / 2, @as(f64, @floatFromInt(inst.row)) + @as(f64, @floatFromInt(inst.rows - 1)) / 2);
            break :blk .{ .x = p.x + st.offset.x, .y = p.y + st.offset.y };
        };
        return .{ .x0 = c.x - w / 2, .x1 = c.x + w / 2, .y0 = c.y - h / 2, .y1 = c.y + h / 2 };
    }

    /// The grid and instance tile `id` is bound to, if any.
    pub fn gridInstanceOf(m: *const Model, id: TileId) ?struct { panel: usize, grid: usize, index: usize } {
        for (m.panels.items, 0..) |p, pi| for (p.grids.items, 0..) |g, gi| for (g.instances.items, 0..) |inst, ii| {
            if (inst.tile == id) return .{ .panel = pi, .grid = gi, .index = ii };
        };
        return null;
    }

    /// Adds a grid to panel `panel`, point (0, 0) at `origin`; returns its
    /// index.
    pub fn addGrid(m: *Model, panel: usize, origin: geom.Point, shape: GridShape) Error!usize {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        if (shape.cols == 0 or shape.rows == 0 or !(shape.pitch_x > 0 and shape.pitch_y > 0) or !(shape.stretch_x > 0 and shape.stretch_y > 0)) return error.BadSize;
        const p = &m.panels.items[panel];
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Grid {d}", .{p.grids.items.len + 1}) catch "Grid";
        try p.grids.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .default_name = true, .origin = origin, .shape = shape });
        m.revision += 1;
        return p.grids.items.len - 1;
    }

    /// Adds a grid to panel `panel` that follows grid `source` (on any
    /// panel), point (0, 0) at `origin`; returns its index.
    pub fn addLinkedGrid(m: *Model, panel: usize, origin: geom.Point, source: ObjectId) Error!usize {
        const at = m.findGrid(source) orelse return error.NoSuchObject;
        const gi = try m.addGrid(panel, origin, m.gridShape(at.panel, at.index));
        m.panels.items[panel].grids.items[gi].link = source;
        return gi;
    }

    /// What to do with instances on points a grid no longer has.
    pub const Dropped = enum { remove, leave };

    /// Changes grid `gi`'s shape (a grid that follows another takes this
    /// as its own and stops following). Instances on points it no longer
    /// has, on it and on every grid following it, are removed or left in
    /// place, unbound, as `dropped` says.
    pub fn setGridShape(m: *Model, panel: usize, gi: usize, shape: GridShape, dropped: Dropped) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        if (shape.cols == 0 or shape.rows == 0 or !(shape.pitch_x > 0 and shape.pitch_y > 0) or !(shape.stretch_x > 0 and shape.stretch_y > 0)) return error.BadSize;
        const id = m.panels.items[panel].grids.items[gi].id;
        // Settle the ones about to lose their points first, at their places
        // under the old shape.
        for (m.panels.items, 0..) |*p, pi| for (p.grids.items, 0..) |*g, gj| {
            if (!(pi == panel and gj == gi) and !m.follows(g.*, id)) continue;
            var ii: usize = 0;
            while (ii < g.instances.items.len) {
                const inst = g.instances.items[ii];
                const off = inst.loose == null and (inst.col + inst.cols > shape.cols or inst.row + inst.rows > shape.rows);
                if (!off) {
                    ii += 1;
                    continue;
                }
                switch (dropped) {
                    .leave => {
                        const b = m.instanceBox(pi, gj, ii).?;
                        g.instances.items[ii].loose = .{ .x = (b.x0 + b.x1) / 2, .y = (b.y0 + b.y1) / 2 };
                        ii += 1;
                    },
                    .remove => {
                        m.tile(inst.tile).removed = true;
                        _ = g.instances.orderedRemove(ii);
                    },
                }
            }
        };
        const g = &m.panels.items[panel].grids.items[gi];
        g.shape = shape;
        g.link = .none;
        m.revision += 1;
    }

    /// Whether grid `g` follows grid `id`, directly or through others.
    fn follows(m: *const Model, g: Grid, id: ObjectId) bool {
        var link = g.link;
        var hops: usize = 0;
        while (link != .none and hops < 16) : (hops += 1) {
            if (link == id) return true;
            const at = m.findGrid(link) orelse return false;
            link = m.panels.items[at.panel].grids.items[at.index].link;
        }
        return false;
    }

    /// Moves grid `gi`'s point (0, 0) to `origin`.
    pub fn moveGrid(m: *Model, panel: usize, gi: usize, origin: geom.Point) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        m.panels.items[panel].grids.items[gi].origin = origin;
        m.revision += 1;
    }

    /// Removes grid `gi` and its instances. Grids following it keep its
    /// shape as their own.
    pub fn removeGrid(m: *Model, panel: usize, gi: usize) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const id = m.panels.items[panel].grids.items[gi].id;
        const shape = m.gridShape(panel, gi);
        for (m.panels.items) |*p| for (p.grids.items) |*g| if (g.link == id) {
            g.shape = shape;
            g.link = .none;
        };
        const g = m.panels.items[panel].grids.orderedRemove(gi);
        for (g.instances.items) |inst| m.tile(inst.tile).removed = true;
        m.revision += 1;
    }

    /// Adds a stamp to grid `gi`; returns its index.
    pub fn addStamp(m: *Model, panel: usize, gi: usize, stamp: Stamp) Error!usize {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        if (stamp.prototype >= m.prototypes.items.len) return error.NoSuchPrototype;
        if (!(stamp.w > 0 and stamp.h > 0)) return error.BadSize;
        var st = stamp;
        st.id = m.newId();
        st.name = try m.a().dupe(u8, stamp.name);
        const g = &m.panels.items[panel].grids.items[gi];
        try g.stamps.append(m.a(), st);
        m.revision += 1;
        return g.stamps.items.len - 1;
    }

    /// Changes stamp `si` of grid `gi` (its prototype, role, size, offset
    /// or name), and with it every instance of it.
    pub fn setStamp(m: *Model, panel: usize, gi: usize, si: usize, stamp: Stamp) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const g = &m.panels.items[panel].grids.items[gi];
        if (si >= g.stamps.items.len) return error.NoSuchItem;
        if (stamp.prototype >= m.prototypes.items.len) return error.NoSuchPrototype;
        if (!(stamp.w > 0 and stamp.h > 0)) return error.BadSize;
        var st = stamp;
        st.id = g.stamps.items[si].id;
        st.name = try m.a().dupe(u8, stamp.name);
        g.stamps.items[si] = st;
        // The tiles take the stamp's prototype.
        for (g.instances.items) |inst| if (inst.stamp == st.id) {
            m.tile(inst.tile).prototype = st.prototype;
        };
        m.revision += 1;
    }

    /// Removes stamp `si` of grid `gi` and its instances.
    pub fn removeStamp(m: *Model, panel: usize, gi: usize, si: usize) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const g = &m.panels.items[panel].grids.items[gi];
        if (si >= g.stamps.items.len) return error.NoSuchItem;
        const st = g.stamps.orderedRemove(si);
        var ii: usize = 0;
        while (ii < g.instances.items.len) {
            if (g.instances.items[ii].stamp == st.id) {
                m.tile(g.instances.items[ii].tile).removed = true;
                _ = g.instances.orderedRemove(ii);
            } else ii += 1;
        }
        m.revision += 1;
    }

    /// The first free designator `prefix` followed by a number.
    fn freeDesignator(m: *Model, prefix: []const u8, buf: []u8) []const u8 {
        var n: usize = 1;
        while (true) : (n += 1) {
            const d = std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, n }) catch return prefix;
            if (m.findTile(d) == null) return d;
        }
    }

    /// The instance of stamp `stamp` on point (`col`, `row`) of grid `gi`,
    /// by index (one spanning it counts).
    pub fn instanceAt(m: *const Model, panel: usize, gi: usize, stamp: ObjectId, col: u32, row: u32) ?usize {
        for (m.panels.items[panel].grids.items[gi].instances.items, 0..) |inst, ii| {
            if (inst.stamp != stamp or inst.loose != null) continue;
            if (col >= inst.col and col < inst.col + inst.cols and row >= inst.row and row < inst.row + inst.rows) return ii;
        }
        return null;
    }

    /// Makes a tile of stamp `si` and binds it to point (`col`, `row`) of
    /// grid `gi`; returns the tile. A point already holding an instance of
    /// the stamp is refused.
    pub fn addInstance(m: *Model, panel: usize, gi: usize, si: usize, col: u32, row: u32) Error!TileId {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const st = blk: {
            const g = m.panels.items[panel].grids.items[gi];
            if (si >= g.stamps.items.len) return error.NoSuchItem;
            break :blk g.stamps.items[si];
        };
        const sh = m.gridShape(panel, gi);
        if (col >= sh.cols or row >= sh.rows) return error.NoSuchItem;
        if (m.instanceAt(panel, gi, st.id, col, row) != null) return error.NoRoom;
        var buf: [48]u8 = undefined;
        const prefix: []const u8 = switch (st.role) {
            .part => "K",
            .hole => "H",
            .legend => "L",
        };
        const id = try m.addTile(.{ .designator = m.freeDesignator(prefix, &buf), .prototype = st.prototype });
        try m.panels.items[panel].grids.items[gi].instances.append(m.a(), .{ .tile = id, .stamp = st.id, .col = col, .row = row });
        m.revision += 1;
        return id;
    }

    /// Fills every point of grid `gi` not holding an instance of stamp
    /// `si` with one; returns how many were made.
    pub fn fillGrid(m: *Model, panel: usize, gi: usize, si: usize) Error!usize {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const sh = m.gridShape(panel, gi);
        const g = m.panels.items[panel].grids.items[gi];
        if (si >= g.stamps.items.len) return error.NoSuchItem;
        const sid = g.stamps.items[si].id;
        var n: usize = 0;
        for (0..sh.rows) |r| for (0..sh.cols) |c| {
            if (m.instanceAt(panel, gi, sid, @intCast(c), @intCast(r)) != null) continue;
            _ = try m.addInstance(panel, gi, si, @intCast(c), @intCast(r));
            n += 1;
        };
        return n;
    }

    /// Sets how many points instance `ii` spans, from its point right and
    /// down. Instances of the same stamp on the points it newly covers are
    /// removed; refused past the grid's edge.
    pub fn setInstanceSpan(m: *Model, panel: usize, gi: usize, ii: usize, cols: u32, rows: u32) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const sh = m.gridShape(panel, gi);
        var g = &m.panels.items[panel].grids.items[gi];
        if (ii >= g.instances.items.len) return error.NoSuchItem;
        const inst = g.instances.items[ii];
        if (cols == 0 or rows == 0 or inst.col + cols > sh.cols or inst.row + rows > sh.rows) return error.BadSize;
        const tile_id = inst.tile;
        var k: usize = 0;
        while (k < g.instances.items.len) {
            const o = g.instances.items[k];
            const covered = o.tile != tile_id and o.stamp == inst.stamp and o.loose == null and
                o.col >= inst.col and o.col < inst.col + cols and o.row >= inst.row and o.row < inst.row + rows;
            if (covered) {
                m.tile(o.tile).removed = true;
                _ = g.instances.orderedRemove(k);
            } else k += 1;
        }
        for (g.instances.items) |*o| if (o.tile == tile_id) {
            o.cols = cols;
            o.rows = rows;
        };
        m.revision += 1;
    }

    /// Binds instance `ii` to point (`col`, `row`) (an unbound one too).
    pub fn bindInstance(m: *Model, panel: usize, gi: usize, ii: usize, col: u32, row: u32) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const sh = m.gridShape(panel, gi);
        const g = &m.panels.items[panel].grids.items[gi];
        if (ii >= g.instances.items.len) return error.NoSuchItem;
        const inst = &g.instances.items[ii];
        if (col + inst.cols > sh.cols or row + inst.rows > sh.rows) return error.BadSize;
        inst.col = col;
        inst.row = row;
        inst.loose = null;
        m.revision += 1;
    }

    /// Removes instance `ii` of grid `gi` and its tile.
    pub fn removeInstance(m: *Model, panel: usize, gi: usize, ii: usize) Error!void {
        if (panel >= m.panels.items.len or gi >= m.panels.items[panel].grids.items.len) return error.NoSuchItem;
        const g = &m.panels.items[panel].grids.items[gi];
        if (ii >= g.instances.items.len) return error.NoSuchItem;
        const inst = g.instances.orderedRemove(ii);
        m.tile(inst.tile).removed = true;
        m.revision += 1;
    }

    pub fn setPanelIslands(m: *Model, panel: usize, on: bool) Error!void {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        m.panels.items[panel].islands = on;
        try m.syncSketchPanel(panel);
        m.revision += 1;
    }

    const SketchEdge = struct { art: PanelArt, min: geom.Point, w: f64, h: f64 };

    /// A sketch's outlines as a panel's edge: its closed profiles, the
    /// outermost first, as one outline whose even-odd fill is the cut by
    /// nesting (without `islands`, only the outermost and the holes in it),
    /// moved so the outermost's box starts at (0, 0). Null unless there is
    /// exactly one outermost outline.
    fn sketchEdge(m: *Model, sk: *const sketch_.Sketch, islands: bool) Error!?SketchEdge {
        var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const prof = try sk.profiles(sa);
        if (prof.contours.len == 0) return null;
        // Each outline's depth: how many others contain it.
        const depth = try sa.alloc(usize, prof.contours.len);
        for (prof.contours, depth, 0..) |c, *dp, i| {
            dp.* = 0;
            const q = c.segments[0].at(0.5);
            for (prof.contours, 0..) |o, k| {
                if (k == i) continue;
                if (art_.contains(.{ .contours = &.{o} }, q)) dp.* += 1;
            }
        }
        var outer: ?usize = null;
        for (depth, 0..) |dp, i| if (dp == 0) {
            if (outer != null) return null;
            outer = i;
        };
        const oi = outer orelse return null;
        const b = prof.contours[oi].bounds();
        const move = geom.Affine.translate(-b.x0, -b.y0);
        var kept: std.ArrayList(geom.Contour) = .empty;
        for (prof.contours, depth, 0..) |c, dp, i| {
            if (i != oi and dp != 0 and !(islands or dp == 1)) continue;
            const segs = try m.a().alloc(geom.Segment, c.segments.len);
            for (c.segments, segs) |sg, *o| o.* = sg.transformed(move);
            const item: geom.Contour = .{ .segments = segs };
            if (i == oi) try kept.insert(m.a(), 0, item) else try kept.append(m.a(), item);
        }
        const shapes = try m.a().alloc(art_.Shape, 1);
        shapes[0] = .{ .name = "edge", .outline = .{ .contours = kept.items }, .paint = .{} };
        return .{
            .art = .{ .id = m.newId(), .name = "edge", .at = .{ .x = 0, .y = 0 }, .shapes = shapes },
            .min = .{ .x = b.x0, .y = b.y0 },
            .w = b.width(),
            .h = b.height(),
        };
    }

    /// Brings a sketch panel's edge up to date with its sketch; what is on
    /// the panel keeps where it is in the space.
    fn syncSketchPanel(m: *Model, panel: usize) Error!void {
        const p = &m.panels.items[panel];
        if (p.sketch == .none) return;
        const si = m.sketchIndex(p.sketch) orelse return;
        // A sketch that no longer encloses leaves the edge as it was.
        const edge = (try m.sketchEdge(&m.sketches.items[si].sketch, p.islands)) orelse return;
        const origin: geom.Point = .{ .x = p.sketch_at.x + edge.min.x, .y = p.sketch_at.y + edge.min.y };
        const d: geom.Point = .{ .x = p.origin.x - origin.x, .y = p.origin.y - origin.y };
        for (p.regions.items) |*rg| rg.origin = .{ .x = rg.origin.x + d.x, .y = rg.origin.y + d.y };
        for (p.art.items) |*pa| pa.at = .{ .x = pa.at.x + d.x, .y = pa.at.y + d.y };
        p.origin = origin;
        p.w = edge.w;
        p.h = edge.h;
        p.edge = edge.art;
    }

    /// Changes a sketch (see `SketchEdit`) and solves it again. Returns the
    /// new geometry's or constraint's ID, where the edit makes one (else 0).
    pub fn editSketch(m: *Model, index: usize, edit: SketchEdit) Error!u32 {
        const sk = &(try m.sketchAt(index)).sketch;
        const sid = m.sketches.items[index].id;
        defer for (m.panels.items, 0..) |pn, pi| if (pn.sketch == sid) {
            m.syncSketchPanel(pi) catch {};
        };
        const al = m.a();
        const gpa = m.arena.child_allocator;
        var out: u32 = 0;
        switch (edit) {
            .point => |e| out = try sk.addPoint(al, e.at, e.construction),
            .segment => |e| out = try sk.addSegment(al, e.a, e.b, e.construction),
            .circle => |e| out = try sk.addCircle(al, e.c, e.r, e.construction),
            .arc => |e| out = try sk.addArc(al, e.c, e.a, e.b, e.construction),
            .line => |e| out = try sk.addLine(al, e.through, e.angle),
            .ray => |e| out = try sk.addRay(al, e.o, e.angle),
            .construction => |e| try sk.setConstruction(e.g, e.on),
            .remove => |g| try sk.removeGeometry(g),
            .constrain => |c| {
                var k = c;
                k.name = try al.dupe(u8, c.name);
                out = try sk.addConstraint(al, k);
            },
            .unconstrain => |c| try sk.removeConstraint(c),
            .value => |e| try sk.setValue(e.c, e.value),
            .reference => |e| try sk.setDriving(e.c, !e.on),
            .expr => |e| try sk.setExpr(al, e.c, e.text),
            .param => |e| try sk.setParam(al, e.name, e.expr),
            .unparam => |name| try sk.removeParam(name),
            .physical_when => |e| try sk.setPhysicalWhen(al, e.g, e.param),
            .drag => |e| {
                _ = try sk.drag(al, gpa, e.p, e.to);
                m.revision += 1;
                return 0;
            },
        }
        _ = try sk.solve(gpa);
        m.revision += 1;
        return out;
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
    /// (tracks and other line art, by their boxes' corners) moves onto the panel, keeping where it is. The panel takes
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
        var i = src.regions.items.len;
        while (i > 0) {
            i -= 1;
            const r = src.regions.items[i];
            if (!inside.box(path, at, r.bounds())) continue;
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
        for (p.regions.items) |x| m.forget(x.id);
        for (p.art.items) |x| m.forget(x.id);
        m.replaceMember(edge_art.id, p.id);
        try m.panels.append(m.a(), p);
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// Release panel: the panel goes, its edge (a rectangle, if it had
    /// none) becomes loose line art in its space again, and its
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
        // A sketch panel goes back to being a view of its sketch.
        if (p.sketch != .none) {
            try m.spaces.items[p.space].sketch_views.append(m.a(), .{ .id = e.id, .sketch = p.sketch, .at = p.sketch_at, .layer = p.layer });
        } else try dst.art.append(m.a(), e);
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
        for (p.regions.items) |r| m.forget(r.id);
        for (p.art.items) |pa| m.forget(pa.id);
        for (p.regions.items) |region| for (region.items.items) |item| {
            const id = item.tileOf() orelse continue;
            if (!m.placedElsewhere(id)) m.tile(id).removed = true;
        };
        for (p.grids.items) |g| for (g.instances.items) |inst| {
            m.tile(inst.tile).removed = true;
        };
        // Grids elsewhere following one of its own keep its shape.
        for (p.grids.items) |gone| for (m.panels.items) |*q| for (q.grids.items) |*g| if (g.link == gone.id) {
            g.shape = gone.shape;
            g.link = .none;
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

    /// The index in `panel` of the track with ID `id`.
    pub fn regionIndex(m: *const Model, panel: usize, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.panels.items[panel].regions.items, 0..) |r, k| if (r.id == id) return k;
        return null;
    }

    /// The track with ID `id`, on whichever panel.
    pub fn trackById(m: *const Model, id: ObjectId) ?TrackRef {
        if (id == .none) return null;
        for (m.panels.items, 0..) |p, pi| for (p.regions.items, 0..) |r, k| if (r.id == id) return .{ .panel = pi, .region = k };
        return null;
    }

    /// The track whose flow goes on into track `region` of `panel`, on
    /// whichever panel, if any.
    pub fn threadBefore(m: *const Model, panel: usize, region: usize) ?TrackRef {
        const id = m.panels.items[panel].regions.items[region].id;
        if (id == .none) return null;
        for (m.panels.items, 0..) |p, pi| for (p.regions.items, 0..) |r, k| {
            if (r.next == id and !(pi == panel and k == region)) return .{ .panel = pi, .region = k };
        };
        return null;
    }

    /// The first track of the thread `region` is in (itself when none goes
    /// on into it): the one that holds the thread's flow.
    pub fn threadHead(m: *const Model, panel: usize, region: usize) TrackRef {
        var at: TrackRef = .{ .panel = panel, .region = region };
        var steps: usize = 0;
        while (m.threadBefore(at.panel, at.region)) |b| : (steps += 1) {
            if ((b.panel == panel and b.region == region) or steps > 4096) break;
            at = b;
        }
        return at;
    }

    /// The tracks of the thread starting at `head`, in order, into `buf`
    /// (stopping at a track already listed).
    pub fn thread(m: *const Model, head: TrackRef, buf: []TrackRef) []TrackRef {
        var n: usize = 0;
        var at: ?TrackRef = head;
        while (at) |k| {
            if (n >= buf.len) break;
            for (buf[0..n]) |x| if (x.panel == k.panel and x.region == k.region) return buf[0..n];
            buf[n] = k;
            n += 1;
            at = m.trackById(m.panels.items[k.panel].regions.items[k.region].next);
        }
        return buf[0..n];
    }

    fn trackPtr(m: *Model, t: TrackRef) *TileRegion {
        return &m.panels.items[t.panel].regions.items[t.region];
    }

    /// Joins track `to` after track `from`, on one panel (see
    /// `threadTracks`).
    pub fn joinTracks(m: *Model, panel: usize, from: usize, to: usize) Error!void {
        return m.threadTracks(panel, from, panel, to);
    }

    /// Joins track `to` (of `to_panel`) after track `from` (of
    /// `from_panel`): the flow of `from`'s thread goes on into `to` (and
    /// the thread `to` starts, if it starts one) before whatever followed
    /// `from`, on this panel or another. What `to`'s thread held is added
    /// to the end of the flow, as a new paragraph. Both must run the same
    /// way, and `to` must start its thread and not be in `from`'s.
    pub fn threadTracks(m: *Model, from_panel: usize, from: usize, to_panel: usize, to: usize) Error!void {
        if (from_panel >= m.panels.items.len or to_panel >= m.panels.items.len) return error.NoSuchRow;
        if (from >= m.panels.items[from_panel].regions.items.len or to >= m.panels.items[to_panel].regions.items.len) return error.NoSuchRow;
        const f: TrackRef = .{ .panel = from_panel, .region = from };
        const t: TrackRef = .{ .panel = to_panel, .region = to };
        if (m.trackPtr(f).major != m.trackPtr(t).major) return error.BadJoin;
        if (m.threadBefore(to_panel, to) != null) return error.BadJoin;
        const head = m.threadHead(from_panel, from);
        if (head.panel == to_panel and head.region == to) return error.BadJoin;
        var buf: [256]TrackRef = undefined;
        const joining = m.thread(t, &buf);
        const tail = joining[joining.len - 1];
        m.trackPtr(tail).next = m.trackPtr(f).next;
        m.trackPtr(f).next = m.trackPtr(t).id;
        // One flow: what `to` held goes on after the thread's.
        const hr = m.trackPtr(head);
        const tr = m.trackPtr(t);
        if (tr.items.items.len > 0) {
            if (hr.items.items.len > 0) try hr.items.append(m.a(), .{ .what = .{ .paragraph = tr.paragraph } });
            try hr.items.appendSlice(m.a(), tr.items.items);
            tr.items.clearRetainingCapacity();
        }
        m.revision += 1;
    }

    /// Takes track `region` out of its thread: the tracks either side are
    /// joined, and the flow stays whole on the thread (on the next track
    /// when `region` held it); what no longer fits overflows the last.
    pub fn unjoinTrack(m: *Model, panel: usize, region: usize) Error!void {
        if (panel >= m.panels.items.len or region >= m.panels.items[panel].regions.items.len) return error.NoSuchRow;
        const self: TrackRef = .{ .panel = panel, .region = region };
        const before = m.threadBefore(panel, region);
        const after = m.trackById(m.trackPtr(self).next);
        if (before == null and after == null) return error.BadJoin;
        if (before) |b| m.trackPtr(b).next = m.trackPtr(self).next;
        if (before == null) if (after) |n| {
            // It held the flow: the next track does now.
            const r = m.trackPtr(self);
            const nr = m.trackPtr(n);
            try nr.items.appendSlice(m.a(), r.items.items);
            r.items.clearRetainingCapacity();
            nr.paragraph = r.paragraph;
        };
        m.trackPtr(self).next = .none;
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

    // Editing a flow in place ------------------------------------------------
    //
    // As a word processor does: text typed in at a place, a range deleted,
    // a line or paragraph broken. Within a run the markup stays whole (see
    // `edit`): only characters are removed, and a run split in two keeps
    // what each part reads as.

    fn runAt(m: *Model, panel: usize, region: usize, index: usize) ?*Run {
        const items = m.flow(panel, region).items;
        if (index >= items.len or items[index].what != .run) return null;
        return &items[index].what.run;
    }

    /// Types plain `text` in at `at` (newlines break paragraphs): into the
    /// run there, else onto the end of the run before, else as a new run in
    /// `style`. Returns the place after it.
    pub fn insertText(m: *Model, panel: usize, region: usize, at: FlowPos, text: []const u8, style: StyleId) Error!FlowPos {
        var pos = at;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line_raw| {
            if (!first) pos = try m.breakAt(panel, region, pos, true);
            first = false;
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
            defer scratch.deinit();
            const esc = try edit_.escape(scratch.allocator(), line);
            const items = m.flow(panel, region).items;
            if (pos.index > items.len) return error.NoSuchItem;
            const here = m.runAt(panel, region, pos.index);
            const before = if (pos.index > 0) m.runAt(panel, region, pos.index - 1) else null;
            if (here != null and !(here.?.equation and pos.offset == 0)) {
                // Into the run at the place (inside an equation, into it).
                const r = here.?;
                const o = @min(pos.offset, r.content.len);
                r.content = try std.mem.concat(m.a(), u8, &.{ r.content[0..o], esc, r.content[o..] });
                pos = .{ .index = pos.index, .offset = @intCast(o + esc.len) };
            } else if (pos.offset == 0 and before != null and !before.?.equation) {
                // Onto the end of the run before, unless it is an equation.
                const r = before.?;
                r.content = try std.mem.concat(m.a(), u8, &.{ r.content, esc });
            } else {
                try m.place(panel, region, pos.index, .{ .what = .{ .run = .{ .style = style, .content = try m.a().dupe(u8, esc) } } });
                pos = .{ .index = pos.index + 1 };
            }
            // At the end of a run: the place before what follows it.
            if (m.runAt(panel, region, pos.index)) |r| if (pos.offset >= r.content.len) {
                pos = .{ .index = pos.index + 1 };
            };
        }
        m.revision += 1;
        return pos;
    }

    /// Deletes what lies between `from` and `to` (either way round): the
    /// characters of the runs at either end, and every item between; runs
    /// left side by side in one style are joined. Returns where it was.
    pub fn deleteRange(m: *Model, panel: usize, region: usize, from: FlowPos, to: FlowPos) Error!FlowPos {
        var f = from;
        var t = to;
        if (t.index < f.index or (t.index == f.index and t.offset < f.offset)) std.mem.swap(FlowPos, &f, &t);
        var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const len = m.flow(panel, region).items.len;
        if (f.index > len or t.index > len) return error.NoSuchItem;
        if (f.index == t.index) {
            if (m.runAt(panel, region, f.index)) |r| if (t.offset > f.offset) {
                r.content = try m.a().dupe(u8, try edit_.deleteChars(sa, r.content, f.offset, t.offset));
                // Nothing left of it: it goes.
                if (!try edit_.hasChars(sa, r.content)) {
                    try m.removeAt(panel, region, f.index);
                    f.offset = 0;
                }
            };
            m.revision += 1;
            return f;
        }
        // The start of the run the range ends in.
        if (t.offset > 0) if (m.runAt(panel, region, t.index)) |r| {
            r.content = try m.a().dupe(u8, try edit_.deleteChars(sa, r.content, 0, t.offset));
        };
        // The end of the run it starts in.
        var keep = f.index;
        if (f.offset > 0) if (m.runAt(panel, region, f.index)) |r| {
            r.content = try m.a().dupe(u8, try edit_.deleteChars(sa, r.content, f.offset, @intCast(r.content.len)));
            keep = f.index + 1;
        };
        // Every item between.
        var k = t.index;
        while (k > keep) {
            k -= 1;
            try m.removeAt(panel, region, k);
        }
        var result: FlowPos = if (f.offset > 0) f else .{ .index = keep };
        // Runs left side by side, in one style: one run.
        if (keep > 0) if (m.runAt(panel, region, keep - 1)) |a_run| if (m.runAt(panel, region, keep)) |b_run| {
            if (a_run.style == b_run.style and !a_run.equation and !b_run.equation) {
                const joined_at: u32 = @intCast(a_run.content.len);
                a_run.content = try std.mem.concat(m.a(), u8, &.{ a_run.content, b_run.content });
                try m.removeAt(panel, region, keep);
                if (f.offset == 0) result = .{ .index = keep - 1, .offset = joined_at };
            }
        };
        // A run left with nothing in it goes.
        if (m.runAt(panel, region, result.index)) |r| if (!try edit_.hasChars(sa, r.content)) {
            try m.removeAt(panel, region, result.index);
            result.offset = 0;
        };
        if (m.runAt(panel, region, result.index)) |r| if (result.offset >= r.content.len and result.offset > 0) {
            result = .{ .index = result.index + 1 };
        };
        m.revision += 1;
        return result;
    }

    /// Puts a new, empty equation at `at`, in `style`: inside a run of text
    /// the run is split there (its markup kept whole); inside an
    /// equation's structure, or in an equation, it goes after that run.
    /// Returns the equation's index.
    pub fn insertEquation(m: *Model, panel: usize, region: usize, at: FlowPos, style: StyleId) Error!usize {
        var index = at.index;
        if (index > m.flow(panel, region).items.len) return error.NoSuchItem;
        if (at.offset > 0) if (m.runAt(panel, region, at.index)) |r| {
            index = at.index + 1;
            if (at.offset < r.content.len and !r.equation) {
                var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
                defer scratch.deinit();
                if (try edit_.splitAt(scratch.allocator(), r.content, at.offset)) |parts| {
                    const rs = r.style;
                    r.content = try m.a().dupe(u8, parts[0]);
                    try m.place(panel, region, index, .{ .what = .{ .run = .{ .style = rs, .content = try m.a().dupe(u8, parts[1]) } } });
                }
            }
        };
        try m.place(panel, region, index, .{ .what = .{ .run = .{ .style = style, .content = "", .equation = true } } });
        m.revision += 1;
        return index;
    }

    /// Breaks the flow at `at`: a new paragraph (in the style of the one
    /// it splits) or a line break. Inside a run the run is split, its
    /// markup kept whole; inside an equation's structure the break goes
    /// after the run. Returns the place after the break.
    pub fn breakAt(m: *Model, panel: usize, region: usize, at: FlowPos, paragraph: bool) Error!FlowPos {
        var index = at.index;
        if (at.offset > 0) if (m.runAt(panel, region, at.index)) |r| {
            index = at.index + 1;
            if (at.offset < r.content.len) {
                var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
                defer scratch.deinit();
                if (try edit_.splitAt(scratch.allocator(), r.content, at.offset)) |parts| {
                    const style = r.style;
                    r.content = try m.a().dupe(u8, parts[0]);
                    try m.place(panel, region, index, .{ .what = .{ .run = .{ .style = style, .content = try m.a().dupe(u8, parts[1]) } } });
                }
            }
        };
        if (paragraph) {
            const style = m.paragraphStyleAt(panel, region, index);
            try m.insertParagraph(panel, region, index, style);
            return .{ .index = index + 1 };
        }
        const n = try m.insertBreak(panel, region, index);
        return .{ .index = index + n };
    }

    /// The plain text between `from` and `to` (either way round): the
    /// characters of runs, a newline for each break or paragraph.
    pub fn flowText(m: *Model, gpa: Allocator, panel: usize, region: usize, from: FlowPos, to: FlowPos) Error![]u8 {
        var f = from;
        var t = to;
        if (t.index < f.index or (t.index == f.index and t.offset < f.offset)) std.mem.swap(FlowPos, &f, &t);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var out: std.ArrayList(u8) = .empty;
        const items = m.flow(panel, region).items;
        var k = f.index;
        while (k <= t.index and k < items.len) : (k += 1) {
            const lo: u32 = if (k == f.index) f.offset else 0;
            switch (items[k].what) {
                .run => |r| {
                    const hi: u32 = if (k == t.index) t.offset else @intCast(r.content.len);
                    if (hi > lo) try edit_.plainText(sa, r.content, lo, hi, &out);
                },
                .hard_break, .paragraph => if (k < t.index) try out.append(sa, '\n'),
                else => {},
            }
        }
        return gpa.dupe(u8, out.items);
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
            try r.path.append(m.a(), .{ .id = m.newId(), .along = sg.along + r.middle(), .across = sg.across });
        };
        r.segments.clearRetainingCapacity();
    }

    /// Removes tile `id`: it leaves every track it is in, which reflows.
    pub fn removeTile(m: *Model, id: TileId) void {
        m.unplace(id);
        for (m.panels.items) |*p| for (p.grids.items) |*g| {
            var ii: usize = 0;
            while (ii < g.instances.items.len) {
                if (g.instances.items[ii].tile == id) _ = g.instances.orderedRemove(ii) else ii += 1;
            }
        };
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
    /// Gives prototype `id` its own copy of sketch `index` of space `space`,
    /// which must be fully constrained: its tiles are then drawn from it,
    /// solved for each tile's size with parameter `width_param` set to the
    /// tile's width and `height_param` to its height (mm), the sketch's
    /// origin `offset` from the tile's origin. Refused for a sketch that is
    /// not fully constrained or lacks the parameters.
    pub fn applySketch(m: *Model, id: PrototypeId, index: usize, width_param: []const u8, height_param: []const u8, offset: geom.Point) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const src = try m.sketchAt(index);
        var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        defer scratch.deinit();
        var copy = try src.sketch.clone(m.a());
        _ = try copy.solve(m.arena.child_allocator);
        const an = try copy.analyse(m.arena.child_allocator, scratch.allocator());
        if (!an.fully_constrained) return error.NotFullyConstrained;
        for ([_][]const u8{ width_param, height_param }) |name| {
            const found = for (copy.params.items) |p| {
                if (std.mem.eql(u8, p.name, name)) break true;
            } else false;
            if (!found) return error.NoSuchParameter;
        }
        m.prototypes.items[id].sketch = .{
            .id = m.newId(),
            .from = src.id,
            .sketch = copy,
            .width_param = try m.a().dupe(u8, width_param),
            .height_param = try m.a().dupe(u8, height_param),
            .offset = offset,
        };
        m.revision += 1;
    }

    /// Moves the sketch of prototype `id` on its tiles.
    pub fn setPrototypeSketchOffset(m: *Model, id: PrototypeId, offset: geom.Point) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        const ps = &(m.prototypes.items[id].sketch orelse return error.NoSuchItem);
        ps.offset = offset;
        m.revision += 1;
    }

    /// Takes prototype `id`'s sketch away: its tiles are drawn as before.
    pub fn removePrototypeSketch(m: *Model, id: PrototypeId) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        m.prototypes.items[id].sketch = null;
        m.revision += 1;
    }

    /// Sets tile `id`'s own value for its prototype's sketch parameter
    /// `name`; null takes it away, so the sketch's own expression holds.
    pub fn setTileParam(m: *Model, id: TileId, name: []const u8, value: ?f64) Error!void {
        const t = m.tile(id);
        for (t.params.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
            if (value) |v| t.params.items[i].value = v else _ = t.params.orderedRemove(i);
            m.revision += 1;
            return;
        };
        if (value) |v| try t.params.append(m.a(), .{ .name = try m.a().dupe(u8, name), .value = v });
        m.revision += 1;
    }

    pub fn setPrototypeArt(m: *Model, id: PrototypeId, art: ?art_.Art) Error!void {
        if (id >= m.prototypes.items.len) return error.NoSuchPrototype;
        m.prototypes.items[id].art = if (art) |x| try art_.dupe(m.a(), x) else null;
        m.revision += 1;
    }

    fn dupePrototype(m: *Model, p: TilePrototype) Allocator.Error!TilePrototype {
        var copy = p;
        copy.name = try m.a().dupe(u8, p.name);
        // A copy of its sketch, with an ID of its own.
        if (p.sketch) |ps| copy.sketch = .{
            .id = m.newId(),
            .from = ps.from,
            .sketch = try ps.sketch.clone(m.a()),
            .width_param = try m.a().dupe(u8, ps.width_param),
            .height_param = try m.a().dupe(u8, ps.height_param),
            .offset = ps.offset,
        };
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

/// A small dot of line art at `at` on panel `panel`, named `name` (tests:
/// an object to place, move and group). Returns its index there.
fn testDot(m: *Model, panel: usize, name: []const u8, at: geom.Point) !usize {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const prim: art_.Primitive = .{ .circle = 1 };
    return m.addArt(panel, .{ .name = name, .at = at, .shapes = try art_.primitive(arena.allocator(), name, prim, .{}), .prim = prim });
}

test "a canvas: units chosen up front, no sheet, loose objects on an unbounded panel" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c = try m.startCanvas(.mil);
    try std.testing.expectEqual(c, m.canvas().?);
    try std.testing.expectEqual(Units.mil, m.units);
    try std.testing.expect(!m.has_sheet);
    try std.testing.expectError(error.NoRoom, m.startCanvas(.mm));
    // Line art anywhere, even far from the origin or at negative positions.
    _ = try testDot(&m, c, "Volume", .{ .x = -500, .y = 1200 });
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
    // On the canvas: a panel, a loose track and line art.
    const p = try m.placePanel(.{ .name = "Front", .origin = .{ .x = 10, .y = 10 }, .w = 50, .h = 30 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    const r = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = 100, .y = 50 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    _ = try m.insertTile(c, r, 0, key, 1);
    _ = try testDot(&m, c, "Stays", .{ .x = 5, .y = 80 });
    _ = try testDot(&m, c, "Goes", .{ .x = 120, .y = 70 });
    const pid = m.panels.items[p].id;
    const rid = m.panels.items[c].regions.items[r].id;
    const lid = m.panels.items[c].art.items[1].id;
    const f = try m.addFrame("Frame 1", null);
    try std.testing.expectEqual(1, f);
    const froot = m.spaces.items[f].root;
    const g = try m.moveToSpace(&.{ pid, rid, lid }, f);
    // Panels change space; loose objects move to the frame's own panel,
    // coordinates and IDs kept.
    try std.testing.expectEqual(f, m.spaceOf(p));
    try std.testing.expectEqual(10, m.panels.items[p].origin.x);
    try std.testing.expectEqual(0, m.panels.items[c].regions.items.len);
    try std.testing.expectEqualStrings("Stays", m.panels.items[c].art.items[0].name);
    try std.testing.expectEqual(Member{ .region = .{ .panel = froot, .index = 0 } }, m.locate(rid).?);
    try std.testing.expectEqual(Member{ .art = .{ .panel = froot, .index = 0 } }, m.locate(lid).?);
    // One group, named after where it came from; one move places all.
    const group = m.group(g).?;
    try std.testing.expectEqualStrings("from Canvas", group.name);
    try std.testing.expectEqual(3, group.members.items.len);
    try m.moveGroup(g, -10, 5);
    try std.testing.expectEqual(0, m.panels.items[p].origin.x);
    try std.testing.expectEqual(90, m.panels.items[froot].regions.items[0].origin.x);
    try std.testing.expectEqual(75, m.panels.items[froot].art.items[0].at.y);
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
        const li = try testDot(&m, c, "L", .{ .x = @floatFromInt(i * 10), .y = 0 });
        id.* = m.panels.items[c].art.items[li].id;
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
    m.removeArt(c, 3);
    m.removeArt(c, 2);
    try std.testing.expectEqual(1, m.group(outer).?.members.items.len);
    // One move moves everything left in it, by ID.
    try m.moveGroup(outer, 5, 0);
    try std.testing.expectEqual(5, m.panels.items[c].art.items[0].at.x);
    try std.testing.expectEqual(15, m.panels.items[c].art.items[1].at.x);
    // Ungrouping the inner group hands its members to the outer one.
    try m.ungroup(inner);
    try std.testing.expectEqual(2, m.group(outer).?.members.items.len);
    try std.testing.expectEqual(outer, m.parentGroup(ids[0]).?);
    // Removing the last members removes the emptied group.
    m.removeArt(c, 0);
    m.removeArt(c, 0);
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
    // it, a dot and a track inside, and a dot outside.
    const prim: art_.Primitive = .{ .rounded = .{ .w = 100, .h = 60, .r = 6 } };
    const outline = try m.addArt(c, .{ .name = "Outline", .at = .{ .x = 10, .y = 10 }, .shapes = try art_.primitive(a, "Outline", prim, .{}), .prim = prim });
    for ([_]f64{ 20, 90 }) |x| {
        const hole: art_.Primitive = .{ .circle = 6 };
        const ai = try m.addArt(c, .{ .name = "Hole", .at = .{ .x = x, .y = 15 }, .shapes = try art_.primitive(a, "Hole", hole, .{}), .prim = hole });
        try m.setArtCutout(c, ai, true);
    }
    _ = try testDot(&m, c, "Inside", .{ .x = 40, .y = 50 });
    const outside = try testDot(&m, c, "Outside", .{ .x = 200, .y = 50 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    _ = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = 40, .y = 40 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    const edge_id = m.panels.items[c].art.items[outline].id;
    const g = try m.makeGroup(&.{ edge_id, m.panels.items[c].art.items[outside].id }, "g");

    const p = try m.makePanel(c, outline);
    const panel = m.panels.items[p];
    try std.testing.expect(!panel.unbounded);
    try std.testing.expectEqual(10, panel.origin.x);
    try std.testing.expectEqual(100, panel.w);
    try std.testing.expect(panel.edge != null);
    try std.testing.expectEqual(1, panel.regions.items.len);
    try std.testing.expectEqual(3, panel.art.items.len);
    try std.testing.expect(panel.art.items[0].cutout);
    // In the panel's frame now: the dot at (40, 50) on the canvas.
    try std.testing.expectEqual(30, panel.art.items[2].at.x);
    try std.testing.expectEqual(40, panel.art.items[2].at.y);
    // Left on the canvas: only the outside dot.
    try std.testing.expectEqual(1, m.panels.items[c].art.items.len);
    // The panel took the outline's place in its group.
    try std.testing.expectEqual(g, m.parentGroup(panel.id).?);

    // It moves with all of it; released, everything is loose again where
    // the move left it.
    try m.movePanel(p, .{ .x = 15, .y = 10 });
    const back = try m.releasePanel(p);
    try std.testing.expectEqual(1, m.panels.items.len);
    const root = m.panels.items[c];
    try std.testing.expectEqual(5, root.art.items.len);
    try std.testing.expectEqual(1, root.regions.items.len);
    try std.testing.expectEqual(edge_id, back);
    try std.testing.expectEqual(15, root.art.items[1].at.x);
    try std.testing.expectEqual(45, root.art.items[4].at.x);
    try std.testing.expectEqual(45, root.regions.items[0].origin.x);
    try std.testing.expectEqual(g, m.parentGroup(edge_id).?);
    // A rounded rectangle's corner can be changed.
    try m.setArtCorner(c, 1, 2);
    try std.testing.expectEqual(2, root.art.items[1].prim.rounded.r);
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

test "a flow is edited in place: typed into, deleted across items, broken and joined" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 100, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 2.5 });
    const r = try m.addTracks(p, .{ .name = "T", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 4, .length = 40, .pitch = 6 });
    const items = &m.panels.items[p].regions.items[r].items;
    // Typing into an empty flow makes a run; more goes on its end.
    var at = try m.insertText(p, r, .{ .index = 0 }, "Hello", body);
    try std.testing.expectEqual(FlowPos{ .index = 1 }, at);
    at = try m.insertText(p, r, at, " world {1}", body);
    try std.testing.expectEqualStrings("Hello world \\{1\\}", items.items[0].what.run.content);
    // A paragraph broken inside it: two runs either side of a separator.
    at = try m.breakAt(p, r, .{ .index = 0, .offset = 5 }, true);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("Hello", items.items[0].what.run.content);
    try std.testing.expectEqualStrings(" world \\{1\\}", items.items[2].what.run.content);
    try std.testing.expectEqual(FlowPos{ .index = 2 }, at);
    // Deleting across the separator joins the runs again, less what lay
    // between: "Hel" + "orld {1}".
    at = try m.deleteRange(p, r, .{ .index = 0, .offset = 3 }, .{ .index = 2, .offset = 2 });
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("Helorld \\{1\\}", items.items[0].what.run.content);
    try std.testing.expectEqual(FlowPos{ .index = 0, .offset = 3 }, at);
    // Copied as plain text.
    const text = try m.flowText(gpa, p, r, .{ .index = 0, .offset = 0 }, .{ .index = 1 });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Helorld {1}", text);
    // Deleting a whole run takes it away.
    _ = try m.deleteRange(p, r, .{ .index = 0 }, .{ .index = 1 });
    try std.testing.expectEqual(@as(usize, 0), items.items.len);
    // Pasted lines become paragraphs.
    at = try m.insertText(p, r, .{ .index = 0 }, "one\ntwo", body);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expect(items.items[1].what == .paragraph);
}

test "an equation is its own item: put in a run of text, kept apart from it" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 100, 100);
    const body = try m.addStyle("Body", .{ .upright = 0, .cap_height = 2.5 });
    const r = try m.addTracks(p, .{ .name = "T", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 4, .length = 40, .pitch = 6 });
    const items = &m.panels.items[p].regions.items[r].items;
    _ = try m.insertText(p, r, .{ .index = 0 }, "area is ", body);
    // Inside the text: the run splits either side of the new equation.
    const eq = try m.insertEquation(p, r, .{ .index = 0, .offset = 4 }, body);
    try std.testing.expectEqual(@as(usize, 1), eq);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expect(items.items[1].what.run.equation);
    try std.testing.expectEqualStrings("area", items.items[0].what.run.content);
    try std.testing.expectEqualStrings(" is ", items.items[2].what.run.content);
    items.items[1].what.run.content = "\\frac{a}{}";
    // Typed into an empty slot, it goes into the equation.
    var at = try m.insertText(p, r, .{ .index = 1, .offset = 9 }, "2", body);
    try std.testing.expectEqualStrings("\\frac{a}{2}", items.items[1].what.run.content);
    // Typed just before it or just after it, it goes into the text.
    at = try m.insertText(p, r, .{ .index = 1 }, ":", body);
    try std.testing.expectEqualStrings("area:", items.items[0].what.run.content);
    try std.testing.expectEqual(FlowPos{ .index = 1 }, at);
    at = try m.insertText(p, r, .{ .index = 2 }, "x", body);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("x is ", items.items[2].what.run.content);
    // Deleting the end of the text before it leaves the two apart.
    at = try m.deleteRange(p, r, .{ .index = 0, .offset = 2 }, .{ .index = 1 });
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("ar", items.items[0].what.run.content);
    try std.testing.expectEqualStrings("\\frac{a}{2}", items.items[1].what.run.content);
    // At the end of an equation a new one goes after it.
    try std.testing.expectEqual(@as(usize, 2), try m.insertEquation(p, r, .{ .index = 1, .offset = 3 }, body));
}

test "a panel made from an enclosed sketch: cut by nesting, following its sketch" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    const si = try m.addSketch(0, "Plate", .{ .x = 10, .y = 20 });
    const al = m.a();
    const P = struct {
        fn f(x: f64, y: f64) geom.Point {
            return .{ .x = x, .y = y };
        }
    }.f;
    const sk = &m.sketches.items[si].sketch;
    // A 40 × 30 outline, a hole in it, and an island in the hole.
    const bottom = try sk.addSegment(al, P(0, 0), P(40, 0), false);
    const right = try sk.addSegment(al, P(40, 0), P(40, 30), false);
    const top = try sk.addSegment(al, P(40, 30), P(0, 30), false);
    const left = try sk.addSegment(al, P(0, 30), P(0, 0), false);
    const sides = [_]sketch_.GeomId{ bottom, right, top, left };
    for (0..4) |k| _ = try sk.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = sides[k], .role = .end }, .{ .geom = sides[(k + 1) % 4], .role = .start } } } });
    _ = try sk.addCircle(al, P(28, 15), 8, false);
    _ = try sk.addCircle(al, P(28, 15), 3, false);
    // A track on the canvas inside the outline, and one outside it.
    const st = try m.addStyle("Body", .{ .upright = 0, .cap_height = 2 });
    _ = try m.addTracks(c, .{ .name = "in", .origin = .{ .x = 12, .y = 40 }, .style = st, .count = 1, .length = 1, .pitch = 5 });
    _ = try m.addTracks(c, .{ .name = "out", .origin = .{ .x = 100, .y = 100 }, .style = st, .count = 1, .length = 1, .pitch = 5 });
    const pi = try m.makeSketchPanel(0, 0);
    const p = m.panels.items[pi];
    try std.testing.expectEqual(@as(usize, 0), m.spaces.items[0].sketch_views.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 10), p.origin.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 40), p.w, 1e-9);
    // Outline, hole, island: even-odd, the outline first.
    const edge = p.edge.?.shapes[0].outline;
    try std.testing.expectEqual(@as(usize, 3), edge.contours.len);
    try std.testing.expectApproxEqAbs(@as(f64, 40), edge.contours[0].bounds().width(), 1e-9);
    // The track inside came onto the panel, where it was.
    try std.testing.expectEqual(@as(usize, 1), p.regions.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 12), p.origin.x + p.regions.items[0].origin.x, 1e-9);
    // Without islands: the outline and the hole only.
    try m.setPanelIslands(pi, false);
    try std.testing.expectEqual(@as(usize, 2), m.panels.items[pi].edge.?.shapes[0].outline.contours.len);
    // The sketch grows to the left: the panel follows, its track stays put.
    try m.setPanelIslands(pi, true);
    _ = try m.editSketch(si, .{ .drag = .{ .p = .{ .geom = bottom, .role = .start }, .to = P(-5, 0) } });
    const q = m.panels.items[pi];
    try std.testing.expectApproxEqAbs(@as(f64, 5), q.origin.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 12), q.origin.x + q.regions.items[0].origin.x, 1e-6);
    // A sketch with two separate outlines does not make one panel.
    const two = try m.addSketch(0, "Two", .{ .x = 200, .y = 0 });
    const sk2 = &m.sketches.items[two].sketch;
    _ = try sk2.addCircle(al, P(0, 0), 2, false);
    _ = try sk2.addCircle(al, P(10, 0), 2, false);
    try std.testing.expectError(error.NotEnclosed, m.makeSketchPanel(0, 0));
    // While a panel is made from it, a sketch stays.
    try std.testing.expectError(error.SketchInUse, m.removeSketch(si));
    // Released, the panel is a view of its sketch again, its track loose.
    _ = try m.releasePanel(pi);
    try std.testing.expectEqual(@as(usize, 2), m.spaces.items[0].sketch_views.items.len);
    try std.testing.expectEqual(m.sketches.items[si].id, m.spaces.items[0].sketch_views.items[1].sketch);
    try m.removeSketch(si);
}
