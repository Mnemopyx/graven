//! The panel model: inputs only. Positions, boxes and rendered labels come
//! from `place.solve`, so the model stays the single source of truth.
//!
//! A panel holds regions, each a track: one flow of items (tiles, blanks,
//! runs of text or equations, hard breaks) poured through a list of
//! segments (rows or columns) at a pitch. A tile thicker than its segment
//! reaches into the ones after it, and their content flows around it. Each tile
//! is an instance of a tile prototype, which sets what tiles of its kind
//! share: the body and the face (the labelling surface) as insets, and the
//! tracks on the face its text is set in. A tile holds only what is its
//! own: its size, and what is in each of those tracks.
//!
//! Lengths are mm; tile sizes and gaps in a tile region are in pitch units
//! (u), so a 1.25u tile at 19.05 mm pitch is 23.8125 mm. Frames are y up.
//! Every change goes through an action function here, so the GUI, the CLI
//! and scripts make the same edits.

const std = @import("std");
const names = @import("names.zig");

const glyphic = @import("graven_glyphic");

const Allocator = std.mem.Allocator;
const geom = @import("graven_geom");
const keyboard = @import("graven_keys");
const art_ = @import("art.zig");
const figure_ = @import("figure.zig");
pub const process = @import("process.zig");
pub const manufacture = @import("manufacture.zig");
pub const sketch_ = @import("graven_sketch");
const constrain_ = @import("constrain.zig");
const edit_ = @import("edit.zig");

/// A tile's ID: its own object ID.
pub const TileId = ObjectId;

/// An object's lasting identity: a panel, a label, a track, a piece of
/// line art or a group keeps its ID for as long as it exists, wherever it
/// moves, so references to it (groups, selections, later constraints) never
/// go stale as other objects come and go. A copy gets a new one.
pub const ObjectId = enum(u32) { none = 0, _ };

/// A tile prototype's ID: its own object ID.
pub const PrototypeId = ObjectId;

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
/// A text style's ID: its own object ID. `.none` means the document's
/// first style.
pub const StyleId = ObjectId;
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
        return @backingInt(f) >= @backingInt(Feature.bottom);
    }
};

/// One end of a constraint: a feature of an object, or (object `.none`)
/// of the parent the other end's object sits in: the space (its origin,
/// and its boundary's edges when it has one) or the panel (its outline and
/// its object origin, in its own frame).
pub const ConstraintEnd = struct {
    object: ObjectId = .none,
    feature: Feature,
    /// With `object` a sketch view: the point of its sketch this end is
    /// (its `origin_x` or `origin_y`, as a construction line's point). It
    /// follows the sketch, and is never moved for the constraint.
    point: ?sketch_.PointRef = null,
};

/// A parametric constraint: adding it, or changing its value, moves what
/// it constrains (the object of end `a`; end `b` is the reference) to
/// exactly where it says. Both ends' features are on one axis, and their
/// objects share a parent (or `b` is that parent).
pub const Constraint = struct {
    id: ObjectId = .none,
    kind: enum {
        /// `a`'s feature and `b`'s lie `value` mm apart; 0 aligns them.
        /// Two features of one object give it a size (its right edge 40
        /// mm from its left).
        offset,
        /// `a`'s size on the axis and `b`'s differ by `value` mm; 0 makes
        /// them equal.
        equal_size,
    } = .offset,
    a: ConstraintEnd,
    b: ConstraintEnd,
    /// Never negative: a distance has no start or end (the owner,
    /// 2026-11-24). Which way it runs is `side`.
    value: f64 = 0,
    /// 1: `a`'s feature right of (or above) `b`'s, or `a` the larger; -1:
    /// the other way. Kept as it was made, whatever the value.
    side: f64 = 1,
    /// Driving: it sets where things are. Reference (false): a dimension
    /// that reports what the geometry measures, follows it, and takes no
    /// part in solving (drawn with its value in parentheses).
    driving: bool = true,
    /// Where its dimension is drawn, relative to the constrained object
    /// (end `a`), so it moves with it.
    place: ConstraintPlace = .{},
};

/// Where a constraint's dimension is drawn, after drafting practice
/// (`graven_constraint.dimension.Placement`): its line `offset` mm from the
/// middle of its features (up for a horizontal dimension, left for a
/// vertical one), its value `text` mm along the line from its middle,
/// arrows outside, hidden. Saved with it; placement only: it changes
/// nothing the constraint holds. (An older file's `across` and `along`
/// are not read: its dimensions come back on their features.)
pub const ConstraintPlace = @import("graven_constraint").dimension.Placement;

/// A named pen: what a stroke is drawn with (colour, width, caps, joins).
/// Ink that takes it follows when it changes.
pub const StrokeStyle = struct {
    id: ObjectId = .none,
    name: []const u8,
    stroke: figure_.Stroke,
};

/// What a connection's end is drawn with.
pub const ConnectorEnd = enum { none, arrow, dot, bar };

/// How connections (`sketch_.connector`) look: their path's stroke and
/// what marks each end. A connection names one by its ID.
pub const ConnectorStyle = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// Its path's stroke style. With one, its connections are
    /// manufactured: drawn in the sketch's figure, so in panels and
    /// output. With none, they are annotation: seen only as the sketch's
    /// construction (the owner, 2026-11-25).
    stroke: ObjectId = .none,
    /// At the attachment point, and at the end.
    start: ConnectorEnd = .arrow,
    end: ConnectorEnd = .none,
    /// The marks' length (an arrow's), mm.
    size: f64 = 1.2,
    /// A Dubins path's bend radius and straight leads, mm: where a new
    /// connection starts; each may then change its own.
    radius: f64 = 2,
    lead: f64 = 1,
};

/// A named fill: a colour in a pattern (solid, or a hatch). `cutout`
/// says what it means for manufacture: the area is cut out.
pub const FillStyle = struct {
    id: ObjectId = .none,
    name: []const u8,
    color: art_.Color,
    pattern: figure_.Pattern,
    cutout: bool = false,
};

/// A paragraph style's ID: its own object ID.
pub const ParaId = ObjectId;

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
/// See `ParagraphStyle.tall`.
pub const TallContent = enum { around, move, fixed };

/// A sort: one unit typed into a flow and taken out of it whole, as a
/// piece of hand-set type was (Travis, 2026-11-24). Sorts are kept in
/// cases, a keyboard's worth each (see `Case`).
pub const Sort = union(enum) {
    /// Text, set as typed (a glyph, usually).
    text: []const u8,
    /// A tile of `prototype` (null: the track's own), as long along its
    /// track as `size`.
    tile: struct { prototype: ?PrototypeId = null, size: SortSize, id: []const u8 = "" },
    /// A blank (space between tiles), as long as `size`.
    blank: struct { size: SortSize, id: []const u8 = "" },

    /// The short id a key shows for the sort (Travis, 2026-11-24): its own
    /// `id` when it has one; else text as it is, a tile by its length
    /// (`length`, resolved where it is put: 1¼), a blank by its length after
    /// a ␣ (␣½). Written into `buf` when made.
    pub fn shortId(s: Sort, buf: []u8, length: ?f64) []const u8 {
        switch (s) {
            .text => |t| return t,
            .tile => |t| if (t.id.len > 0) return t.id,
            .blank => |b| if (b.id.len > 0) return b.id,
        }
        const mark: []const u8 = if (s == .blank) "␣" else "";
        const v = length orelse return if (s == .blank) "␣" else "▭";
        const whole = @floor(v + 1e-9);
        const frac = v - whole;
        const fracs = [_]struct { f64, []const u8 }{ .{ 0.25, "¼" }, .{ 0.5, "½" }, .{ 0.75, "¾" }, .{ 1.0 / 3.0, "⅓" }, .{ 2.0 / 3.0, "⅔" }, .{ 0.125, "⅛" } };
        if (frac < 1e-6) return std.fmt.bufPrint(buf, "{s}{d}", .{ mark, whole }) catch mark;
        for (fracs) |f| if (@abs(frac - f[0]) < 1e-6) {
            return if (whole == 0)
                std.fmt.bufPrint(buf, "{s}{s}", .{ mark, f[1] }) catch mark
            else
                std.fmt.bufPrint(buf, "{s}{d}{s}", .{ mark, whole, f[1] }) catch mark;
        };
        var t = std.fmt.bufPrint(buf, "{s}{d:.2}", .{ mark, v }) catch return mark;
        while (t[t.len - 1] == '0') t = t[0 .. t.len - 1];
        return t;
    }
};

/// A sort's length along its track: `units` of its prototype's unit, or
/// the `step`th length its prototype offers (0: the first; for a blank,
/// `step` + 1 of the prototype's steps), so one case serves every track.
pub const SortSize = union(enum) {
    units: f64,
    step: u8,
};

/// One key of a case: which key (`graven_keys`: by its position, the same
/// key whatever the layout, or by the symbol it types, wherever the layout
/// puts it), its sort, and the sort its upper case (Shift or Caps Lock)
/// types.
pub const CaseKey = struct {
    key: keyboard.Key,
    lower: ?Sort = null,
    upper: ?Sort = null,
};

/// A case: sorts on the keys of the keyboard, chosen while typing in a
/// flow so the keys type them. A document keeps its own; Graven has
/// `builtin_cases`.
pub const Case = struct {
    id: ObjectId = .none,
    name: []const u8,
    keys: []const CaseKey = &.{},

    /// The sort typed text `txt` stands for in this case, on keyboard
    /// layout `on`: the key that types it there, its lower sort, or its
    /// upper one where typing `txt` took Shift (or Caps Lock).
    pub fn sortFor(c: Case, on: *const keyboard.Layout, txt: []const u8) ?Sort {
        const at = on.find(txt) orelse return null;
        for (c.keys) |k| if (k.key.on(on)) |p| if (p.eql(at.pos)) return if (at.shift) k.upper else k.lower;
        return null;
    }
};

/// Graven's own cases. Tiles: the digit row's keys (E01 to E10, which type
/// digits unshifted on most layouts, shifted on French) type the track's
/// tiles, its first ten lengths; with Shift, blanks of one to ten steps
/// (the keyboard tile entry of before, 2026-11-18). Greek: on the keys
/// that type the Latin letters, wherever the layout has them.
pub const builtin_cases = [_]Case{
    .{ .name = "Tiles", .keys = &tiles_keys },
    .{ .name = "Greek", .keys = &greek_keys },
};

/// Greek on the Latin letters as RFC 1345 pairs them (a α, h θ, c ξ, q ψ,
/// w ω …); Shift gives the capital.
const greek_keys = blk: {
    const pairs = [_]struct { u8, []const u8, []const u8 }{
        .{ 'a', "α", "Α" },
        .{ 'b', "β", "Β" },
        .{ 'g', "γ", "Γ" },
        .{ 'd', "δ", "Δ" },
        .{ 'e', "ε", "Ε" },
        .{ 'z', "ζ", "Ζ" },
        .{ 'y', "η", "Η" },
        .{ 'h', "θ", "Θ" },
        .{ 'i', "ι", "Ι" },
        .{ 'k', "κ", "Κ" },
        .{ 'l', "λ", "Λ" },
        .{ 'm', "μ", "Μ" },
        .{ 'n', "ν", "Ν" },
        .{ 'c', "ξ", "Ξ" },
        .{ 'o', "ο", "Ο" },
        .{ 'p', "π", "Π" },
        .{ 'r', "ρ", "Ρ" },
        .{ 's', "σ", "Σ" },
        .{ 't', "τ", "Τ" },
        .{ 'u', "υ", "Υ" },
        .{ 'f', "φ", "Φ" },
        .{ 'x', "χ", "Χ" },
        .{ 'q', "ψ", "Ψ" },
        .{ 'w', "ω", "Ω" },
        .{ 'j', "ς", "ϑ" },
        .{ 'v', "ϕ", "ϖ" },
    };
    var ks: [pairs.len]CaseKey = undefined;
    for (pairs, 0..) |p, i| ks[i] = .{ .key = .{ .sym = &.{p[0]} }, .lower = .{ .text = p[1] }, .upper = .{ .text = p[2] } };
    break :blk ks;
};

const tiles_keys = blk: {
    var ks: [10]CaseKey = undefined;
    for (0..10) |i| ks[i] = .{
        .key = .{ .pos = .{ .row = .E, .col = @intCast(i + 1) } },
        .lower = .{ .tile = .{ .size = .{ .step = i } } },
        .upper = .{ .blank = .{ .size = .{ .step = i } } },
    };
    break :blk ks;
};

pub const ParagraphStyle = struct {
    id: ObjectId = .none,
    name: []const u8,
    alignment: ParagraphAlign = .start,
    indent_start: f64 = 0,
    indent_end: f64 = 0,
    first: f64 = 0,
    space_before: f64 = 0,
    space_after: f64 = 0,
    line_gap: f64 = 0,
    /// What a line does about something it holds that reaches past its
    /// font's own ascender or descender (a display-style formula): the
    /// lines above and below break around it (the owner, 2026-11-23), it
    /// moves down to clear the line above (the lines after it follow), or
    /// the spacing is fixed (FrameMaker's Fixed) and they may overlap.
    tall: TallContent = .around,
    /// The style a new paragraph takes when Enter ends one in this style
    /// (FrameMaker's Next ¶ Tag); null: this one.
    next: ?ParaId = null,
};

/// Where a track lies on a tile's face.
pub const FacePlace = struct {
    /// The track's box: the face less this inset, mm.
    inset: Sides = .{},
};

/// A track every tile of a prototype has: where it lies on the face, which
/// way it runs, and the style of its text. Its shape is the prototype's;
/// what is in it is each tile's own (see `TileFlow`), matched by the
/// track's ID. A row track sets its text in lines across the face; a
/// column track sets it a character at a time down the face, upright,
/// going on into the next column (neither turns text).
pub const TileTrack = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// Its box on the face.
    place: FacePlace = .{},
    major: Major = .row,
    style: StyleId = .none,
    /// How each line (row) or column is set along: from its start, about
    /// its centre, or back from its end.
    alignment: Align = .start,
};

/// A tile's content in one of its prototype's tracks: runs of text and
/// equations, and hard breaks (no tiles). It has an ID of its own, so the
/// tile's track can be connected to by ID.
pub const TileFlow = struct {
    id: ObjectId = .none,
    /// The prototype track it fills.
    track: ObjectId,
    items: std.ArrayList(Item) = .empty,
};

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
    id: ObjectId = .none,
    name: []const u8,
    /// A tile's body: its pitch box less this inset, mm.
    body_inset: Sides = .{},
    /// Its labelling face: the body less this inset, mm.
    face_inset: Sides = .{},
    /// The tracks on the face, in order (see `TileTrack`).
    tracks: []const TileTrack = &.{},
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
    id: ObjectId = .none,
    /// The visible name, unique within its panel (K23, ENTER).
    designator: []const u8,
    /// Width and height in pitch units of its region.
    w: f64 = 1,
    h: f64 = 1,
    /// The kind of tile it is.
    /// `.none` takes the document's first prototype (see `addTile`).
    prototype: PrototypeId = .none,
    removed: bool = false,
    /// Its own values for its prototype's sketch parameters (a homing bump
    /// switched on); the sketch's own expressions give the rest.
    params: std.ArrayList(TileParam) = .empty,
    /// Its content in its prototype's tracks.
    flows: std.ArrayList(TileFlow) = .empty,
};

pub const TileParam = struct { name: []const u8, value: f64 };

/// A legend sheet: the content of a keypad's keys' slots, as a table, as
/// in a spreadsheet. Each row is a key, found by its name (its tile's
/// designator) among the keys in the sheet's scope; each column a slot,
/// by its name (a prototype track's), on the key or on a tile at the same
/// grid place in a grid linked with the key's (a legend printed on the
/// plate beside it). The sheet drives those slots: their content is the
/// cells', and editing a slot on its key edits the cell (`syncSheets`).
pub const LegendSheet = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// The keys it covers: those of a grid, of a track's flow, or of a
    /// panel (its grids' and tracks'), by the ID of that object.
    scope: ObjectId,
    /// The slots' names, a column each (after the name column).
    columns: std.ArrayList([]const u8) = .empty,
    rows: std.ArrayList(SheetRow) = .empty,
    /// Where it was imported from, if it was.
    sources: std.ArrayList(FlowSource) = .empty,
    /// A text sheet (the owner, 2026-11-25): each row a named text holder
    /// (a caption, or any track, by name), its first column the default
    /// text, each other column a language. Its scope is `.none`.
    texts: bool = false,
    /// A text sheet's column shown in its text holders (0: the default);
    /// an empty cell shows the default.
    shown: usize = 0,
};

/// A key's row: its name, and a cell for each column (markup; missing
/// ones are empty).
pub const SheetRow = struct {
    key: []const u8,
    cells: std.ArrayList([]const u8) = .empty,
};

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
    /// The source's version, when it is drawn from a sketch live (a grid
    /// stamp's): a change to it solves its instances again.
    version: u32 = 0,
};

/// A run of label markup in a track's flow: words, an equation, or both
/// (equations are markup too). For now a run is one unbreakable item, set
/// as a single line in its style; breaking between its words comes later.
pub const Run = struct {
    style: StyleId = .none,
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

/// What a content layout (a track or a region) or a grid sits in: a
/// workspace (the canvas or a frame, by index), or a panel (by index). A
/// workspace is not a container: it holds containers (panels, content
/// layouts, grids, figure placements), never content of its own.
pub const Parent = union(enum) {
    space: usize,
    panel: usize,

    pub fn eql(x: Parent, y: Parent) bool {
        return switch (x) {
            .space => |i| y == .space and y.space == i,
            .panel => |i| y == .panel and y.panel == i,
        };
    }

    /// The panel it is, if it is one.
    pub fn panelIndex(x: Parent) ?usize {
        return switch (x) {
            .panel => |i| i,
            .space => null,
        };
    }
};

/// A track by its parent and its index there.
pub const TrackRef = struct { parent: Parent, region: usize };

/// A flow: a continuous body of content that belongs together (an
/// article, a chapter, a row of keys), poured through the tracks it is
/// assigned to, in order, on any panel. It may be assigned to none
/// (unplaced): its content is kept and shown nowhere. A track belongs to
/// one flow; a track drawn makes a flow of its own.
pub const Flow = struct {
    id: ObjectId = .none,
    name: []const u8 = "",
    /// The tracks it runs through, in order.
    tracks: std.ArrayList(ObjectId) = .empty,
    /// The paragraph style of its first paragraph (each later one takes
    /// its separator's); null for none: segments set by their track's
    /// `alignment`.
    paragraph: ?ParaId = null,
    /// The length of the blank put in after each hard break as it is
    /// entered, so a new paragraph starts indented, u; 0 for none. The
    /// blank is an ordinary item: it can be resized or removed.
    indent: f64 = 0,
    /// Its content, in order. A tile thicker than its segment (a 2 u tall
    /// key) reaches into the segments after it, closing the stretch it
    /// covers there; their content flows around it.
    items: std.ArrayList(Item) = .empty,
    /// Where text imported into it came from, in the order it came.
    sources: std.ArrayList(FlowSource) = .empty,
    /// Its flow style (decided 2026-11-23, the owner; shared, as
    /// FrameMaker's catalog formats are, the same evening): the text style
    /// its runs are set in unless given another, the paragraph settings a
    /// paragraph in no style of its own takes, and its leading (its
    /// tracks' baselines). A new flow takes its template's styles
    /// themselves, shared with every flow made from it; a flow overrides
    /// them with styles of its own (a text style based on the template's,
    /// a copy of its paragraph style) and a leading of its own (null:
    /// the template's).
    style: StyleId = .none,
    paragraph_default: ?ParaId = null,
    leading: ?Leading = null,
    /// The template it was copied from.
    template: ObjectId = .none,
};

/// A style template (decided 2026-11-23, the owner): what a new flow's
/// style comes from. A document has a Default one. Its styles are shared
/// by the flows made from it: changing them changes every such flow that
/// does not override them.
pub const StyleTemplate = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// The text style and paragraph style it holds (the document's, kept
    /// for it), and its leading.
    text: StyleId = .none,
    paragraph: ?ParaId = null,
    leading: ?Leading = null,
};

/// Where imported text came from: the source's URI (relative to the
/// document when it lies in the document's folder, else absolute; a
/// fragment may name a part of it), the SHA-256 of what was read (64 hex
/// digits), so a change since can be seen, and when (Unix seconds).
pub const FlowSource = struct {
    uri: []const u8,
    sha256: []const u8 = "",
    imported: i64 = 0,
};

/// A region holding a track: one flow of items (tiles, blanks, runs of
/// text or equations, hard breaks) poured in order through its segments,
/// rows or columns placed from the region's top-left corner.
/// Leading, the distance from one baseline to the next (decided
/// 2026-11-23, the owner): a quantity kept as typed (see `units`): fixed
/// ("12pt", "5mm") or relative to the prevailing font size ("+2pt",
/// "+3mm", "+10%", "120%").
pub const Leading = units_.Quantity;
const units_ = @import("graven_constraint").units;

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
    /// A region (a reserved space that makes tracks as its content needs
    /// them: a column of rows or a row of columns) or a single track (one
    /// line, placed in advance: a keyboard's row).
    kind: Kind = .region,
    /// The direction its tracks' baselines run, degrees in the panel frame
    /// (0: to the right, -90: down), and how content stands on them: its
    /// rotation from the path's normal, degrees (0: on the baseline, as
    /// text is; 90 on a baseline running down: upright). Horizontal and
    /// vertical are not settings: they are these. A region stacks its
    /// tracks on one side of their direction: a column of rows to the
    /// right (down the panel), a row of columns to the left (across it).
    /// Placement takes the two axis cases (see `oriented`) for now; other
    /// angles are kept and flagged (`unsupported_direction`).
    direction: f64 = 0,
    rotation: f64 = 0,
    stack: Side = .right,
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
    /// Space between segments the path continues to, u.
    gap: f64 = 0,
    /// Its leading, as typed: what sets `pitch` (baseline to baseline) for
    /// a region of text; null for its style's own line spacing.
    leading: ?Leading = null,
    /// How each segment's content is set in it: from its start, about its
    /// centre, or back from its end. (Its origin places the segment; this
    /// only arranges what is in it.)
    alignment: Align = .start,
    /// The flow it is assigned to (see `Flow`): the content it holds.
    flow: ObjectId = .none,
    /// A use's track for a sketch's caption (`SketchCaption.id`): made
    /// and kept at its leader's end, its text the caption's base text,
    /// by `syncCaptions`. `.none` for every other track.
    caption: ObjectId = .none,
    /// A caption's track: the base text as last copied into it, to tell
    /// an edit made in it (which gives it text of its own: the owner,
    /// 2026-11-25) from a change to the base.
    caption_copy: []const Item = &.{},
    /// Its text is its own, not the base's: edited in place.
    caption_own: bool = false,
    /// A track a text sheet drives: the text it last wrote there, to tell
    /// an edit made in the track (which goes into the cell shown) from a
    /// change to the sheet. Null while no sheet drives it.
    sheet_copy: ?[]const u8 = null,
    /// Older documents' orientation (read, never written): rows or
    /// columns, turned into a direction on loading (`upgradeOrientation`).
    old_major: Major = .row,

    /// The older fields' names in files (read, never written).
    pub const file_names = .{ .old_major = "major" };

    pub const Kind = enum { region, track };
    pub const Side = enum { right, left };

    /// The orientation that rows (`.row`: running right, stacking down,
    /// content on the baseline) or columns (`.column`: running down,
    /// stacking right, content upright) have.
    pub fn oriented(m: Major) struct { direction: f64, rotation: f64, stack: Side } {
        return switch (m) {
            .row => .{ .direction = 0, .rotation = 0, .stack = .right },
            .column => .{ .direction = -90, .rotation = 90, .stack = .left },
        };
    }

    /// Rows or columns: the axis case its orientation is nearest (columns
    /// when its baselines run down, else rows).
    pub fn major(r: TileRegion) Major {
        const d = @mod(r.direction + 360, 360);
        return if (@abs(d - 270) < 45) .column else .row;
    }

    /// Whether placement can set it as it is: one of the two axis cases
    /// exactly.
    pub fn supported(r: TileRegion) bool {
        const o = oriented(r.major());
        const d = @mod(r.direction - o.direction + 360, 360);
        const q = @mod(r.rotation - o.rotation + 360, 360);
        return (d < 1e-9 or d > 360 - 1e-9) and (q < 1e-9 or q > 360 - 1e-9) and (r.kind == .track or r.stack == o.stack);
    }

    /// Where an unshaped track's segments attach to its path, u: their
    /// middle. Every segment is bound to the path by its centre.
    pub fn middle(r: TileRegion) f64 {
        return r.segmentLength() / 2;
    }

    /// The path's points, sorted across, into `buf`: its control points, and
    /// a start down the middle (see `middle`) unless a point is there or
    /// before.
    pub fn pathPoints(r: TileRegion, buf: []ControlPoint) []ControlPoint {
        var n: usize = 0;
        for (r.path.items) |cp| if (n < buf.len) {
            buf[n] = cp;
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
        return if (r.major() == .row) r.w else r.h;
    }

    /// The band of a segment attached to the path at `s`, mm in the
    /// panel frame: a whole segment's length along, centred on `s` (the
    /// path binds each segment by its centre; its paragraph's alignment only
    /// arranges what is in it), one pitch across.
    pub fn boxAt(r: TileRegion, s: Segment) geom.Box {
        const across = s.across * r.pitch;
        const length = r.segmentLength() * r.pitch;
        const shift = (s.along - r.middle()) * r.pitch;
        return if (r.major() == .row)
            .{ .x0 = r.origin.x + shift, .x1 = r.origin.x + shift + length, .y1 = r.origin.y - across, .y0 = r.origin.y - across - r.pitch }
        else
            .{ .x0 = r.origin.x + across, .x1 = r.origin.x + across + r.pitch, .y1 = r.origin.y - shift, .y0 = r.origin.y - shift - length };
    }

    /// How far across its reserved space reaches, u: as many segments as
    /// it was drawn out for.
    pub fn crossLength(r: TileRegion) f64 {
        if (r.kind == .track) return 1;
        return if (r.major() == .row) r.h else r.w;
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
        if (r.major() == .row) {
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
    /// The figure it is a placement of (its id), if any: its shapes are
    /// that figure's ink, its frame's origin at the ink's bottom left,
    /// made again when the figure changes or it is resized.
    figure: ObjectId = .none,
    /// A figure's placement's border (its margin is the clearance).
    border: FigureBorder = .{},
    /// Made from its panel's sketch (`Panel.sketch`): the sketch's ink, or
    /// a cutout from one of its cutout fills. Made again whenever the
    /// sketch is accepted or its drawing changes; never edited by hand.
    sketch_ink: bool = false,

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

/// A space: the canvas, or a frame. A workspace, not a container: it has
/// its own coordinates and holds containers (its panels, those whose
/// `space` is it; the content layouts and grids set straight on it; figure
/// placements and images), its construction lines and its selection
/// groups, never loose content.
pub const Space = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// True while the name is one the app gave it (Frame 1).
    default_name: bool = false,
    /// Content layouts (tracks and regions) set straight on it, in its
    /// coordinates.
    regions: std.ArrayList(TileRegion) = .empty,
    /// Grids set straight on it.
    grids: std.ArrayList(Grid) = .empty,
    /// Older documents' own panel for loose objects (read, never written):
    /// its content layouts and grids move onto the space on loading
    /// (`upgradeRoots`), and the panel goes.
    old_root: ObjectId = .none,
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
    /// Figures placed in it, each with its own boundary.
    figure_places: std.ArrayList(FigurePlace) = .empty,
    /// Views of the document's sketches placed in it: what is drawn in it
    /// with a sketch.
    sketch_views: std.ArrayList(SketchView) = .empty,
    /// Construction lines: infinite lines, guides for alignment and
    /// attachment, never drawn as output (a canvas or a frame holds no
    /// drawing of its own).
    guides: std.ArrayList(Guide) = .empty,
    /// A sketch's own space (the owner, 2026-11-25): the sketch's ID. It
    /// holds that sketch's one view, at its origin, and nothing else; it is
    /// not a frame (never listed with them, never output, never a place to
    /// move to). Kept, unlisted, if the sketch is removed.
    home: ObjectId = .none,
    /// The layers the editor draws besides the document's (the grid, the
    /// axes, the check results, the construction lines, the flow marks):
    /// in the space's stack, so the document's (the owner, 2026-11-22):
    /// each shown or not, and where among the document's layers.
    overlays: Overlays = .{},
    /// The grid's spacing, mm; 0: adaptive, decades of the units that
    /// follow the zoom. How the grid is drawn (lines, dots, pluses) is the
    /// editor's preference, not the document's.
    grid_spacing: f64 = 0,

    /// The older fields' names in files (read, never written).
    pub const file_names = .{ .old_root = "root" };

    /// The index of layer `id` (`.none` meaning the base layer).
    pub fn layerIndex(sp: Space, id: ObjectId) ?usize {
        const want = if (id == .none) sp.base_layer else id;
        for (sp.layers.items, 0..) |l, i| if (l.id == want) return i;
        return null;
    }
};

/// What holds a construction line's direction.
pub const GuideLock = enum {
    /// Turned freely.
    free,
    /// Its angle kept; it moves parallel.
    angle,
    /// Horizontal (angle 0).
    horizontal,
    /// Vertical (angle 90).
    vertical,
};

/// A construction line (decided 2026-11-21): an infinite line in a space,
/// through `at` at `angle`. On a canvas it runs on without end (drawn
/// where it crosses the view); in a frame it ends at the frame's
/// boundary. Never output: an alignment guide and an attachment for
/// containers.
pub const Guide = struct {
    id: ObjectId = .none,
    name: []const u8 = "",
    /// A point it passes through, mm in the space.
    at: geom.Point,
    /// Its direction, degrees anticlockwise from the x axis, in [0, 180).
    angle: f64,
    lock: GuideLock = .free,

    /// Its unit direction.
    pub fn dir(g: Guide) geom.Point {
        const r = g.angle * std.math.pi / 180;
        return .{ .x = @cos(r), .y = @sin(r) };
    }

    /// The part of it inside box `b`, or null where it misses it.
    pub fn clip(g: Guide, b: geom.Box) ?[2]geom.Point {
        return clipLine(g.at, g.dir(), b);
    }

    /// How far point `p` is from it, mm.
    pub fn distance(g: Guide, p: geom.Point) f64 {
        const d = g.dir();
        return @abs((p.x - g.at.x) * d.y - (p.y - g.at.y) * d.x);
    }
};

/// The angle in [0, 180) of the line through `a` and `b`, degrees.
pub fn lineAngle(a: geom.Point, b: geom.Point) f64 {
    var deg = std.math.atan2(b.y - a.y, b.x - a.x) * 180 / std.math.pi;
    while (deg < 0) deg += 180;
    while (deg >= 180) deg -= 180;
    return deg;
}

/// The infinite line through `p` along unit direction `d`, clipped to box
/// `b` (Liang–Barsky): its two ends, or null where it misses.
pub fn clipLine(p: geom.Point, d: geom.Point, b: geom.Box) ?[2]geom.Point {
    var t0: f64 = -std.math.inf(f64);
    var t1: f64 = std.math.inf(f64);
    const sides = [_]struct { dd: f64, lo: f64, hi: f64, at: f64 }{
        .{ .dd = d.x, .lo = b.x0, .hi = b.x1, .at = p.x },
        .{ .dd = d.y, .lo = b.y0, .hi = b.y1, .at = p.y },
    };
    for (sides) |sd| {
        if (@abs(sd.dd) < 1e-12) {
            if (sd.at < sd.lo or sd.at > sd.hi) return null;
            continue;
        }
        var ta = (sd.lo - sd.at) / sd.dd;
        var tb = (sd.hi - sd.at) / sd.dd;
        if (ta > tb) std.mem.swap(f64, &ta, &tb);
        t0 = @max(t0, ta);
        t1 = @min(t1, tb);
    }
    if (!(t0 <= t1)) return null;
    return .{ .{ .x = p.x + d.x * t0, .y = p.y + d.y * t0 }, .{ .x = p.x + d.x * t1, .y = p.y + d.y * t1 } };
}

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
/// One of the editor's own layers in a space's stack (`Space.overlays`).
pub const Overlay = enum { grid, axes, check_strokes, check_gaps, check_other, simulation, guides, flow_marks, constraints };

/// An editor layer in a space's stack: shown or not, and how many of the
/// space's layers lie below it (`maxInt`: above them all).
pub const OverlayState = struct {
    shown: bool = true,
    below: u16 = std.math.maxInt(u16),
};

/// Each editor layer's state, by name (so a file read without one gives
/// it its default): the grid and the axes at the back, the rest in front.
pub const Overlays = struct {
    grid: OverlayState = .{ .below = 0 },
    axes: OverlayState = .{ .below = 0 },
    check_strokes: OverlayState = .{},
    check_gaps: OverlayState = .{},
    check_other: OverlayState = .{},
    simulation: OverlayState = .{},
    guides: OverlayState = .{},
    flow_marks: OverlayState = .{},
    constraints: OverlayState = .{},

    pub fn get(o: Overlays, w: Overlay) OverlayState {
        return switch (w) {
            inline else => |t| @field(o, @tagName(t)),
        };
    }

    pub fn set(o: *Overlays, w: Overlay, v: OverlayState) void {
        switch (w) {
            inline else => |t| @field(o, @tagName(t)) = v,
        }
    }
};

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
/// A caption of a sketch (the owner, 2026-11-25: captions are the
/// sketch's): its leader is the sketch's own geometry; the text is held
/// at the leader's end, in a track made with it (its base: the text
/// typed there is the base example every use shows) and in a track of
/// each other use (a sketch panel's), made and kept there by
/// `syncCaptions`.
pub const SketchCaption = struct {
    id: ObjectId = .none,
    /// Its name, which a text sheet's row finds it by (its base track's
    /// when made: Caption1).
    name: []const u8 = "",
    /// The leader's end, where the text is held.
    end: sketch_.PointRef,
    /// The leader runs right (the text's left edge on its end), else left.
    right: bool,
    style: StyleId,
    /// Its track's line pitch and length, mm.
    pitch: f64,
    length: f64,
    /// The track it was made with.
    base: ObjectId,
    /// Its leader: a connection in the sketch (`Sketch.connectors`).
    connector: u32 = 0,
};

pub const SketchItem = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// True while the name is one the app gave it (Sketch 1).
    default_name: bool = false,
    sketch: sketch_.Sketch,
    /// Bumped by every edit, so what is solved from it (its instances) is
    /// solved again.
    version: u32 = 0,
    /// The ready-made shape it was made as (it may have been edited since).
    shape: ?ShapeSketch = null,
    /// While a draft is being edited (the sketch editor's changes not yet
    /// accepted): the sketch as last accepted, which every use reads (its
    /// drawings and their placements, panels, stamps, layout constraints
    /// naming its points). Null when nothing is pending. Changes reach the
    /// uses only when accepted (`acceptSketch`: Update, Finish), so the
    /// user controls when they propagate (the owner, 2026-11-25).
    accepted: ?sketch_.Sketch = null,
    /// The drawing (a figure over it) the sketch editor inks and fills in:
    /// one of its ink contexts (the owner, 2026-11-25: several drawings
    /// over one sketch, often one per process). `.none`: its first.
    drawing: ObjectId = .none,
    /// Its captions (Add caption): every use of the sketch shows each as
    /// a track of its own (`syncCaptions`).
    captions: std.ArrayList(SketchCaption) = .empty,

    /// What its uses read: the accepted sketch while a draft is pending,
    /// else the sketch itself.
    pub fn used(it: *SketchItem) *sketch_.Sketch {
        if (it.accepted) |*a| return a;
        return &it.sketch;
    }

    pub fn usedConst(it: *const SketchItem) *const sketch_.Sketch {
        if (it.accepted) |*a| return a;
        return &it.sketch;
    }
};

/// The sketches Graven offers ready-made (see `Model.addShapeSketch`):
/// closed shapes centred on their origin, sized by parameters `w` and `h`
/// (and `r`, a rounded rectangle's corner radius).
pub const ShapeSketch = enum { circle, rectangle, rounded_rectangle, slot };

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
    /// An array's geometry (see `sketch_.arrays`): polar, centred at `at`
    /// out to `to` (its first border there), `cols` round and `rows`
    /// rings over `sweep` degrees; or rectangular, `cols` × `rows` cells
    /// between corners `at` and `to`.
    array: struct { polar: bool, at: geom.Point, to: geom.Point, cols: u32, rows: u32, sweep: f64 = 360 },
    /// A regular polygon (see `sketch_.polygon`) of `sides`, centred at
    /// `c`, a corner at `corner`.
    polygon: struct { c: geom.Point, corner: geom.Point, sides: u32, construction: bool = false },
    construction: struct { g: sketch_.GeomId, on: bool },
    remove: sketch_.GeomId,
    constrain: sketch_.Constraint,
    unconstrain: sketch_.ConstraintId,
    value: struct { c: sketch_.ConstraintId, value: f64 },
    /// A point moved towards `to` as far as its constraints let it.
    drag: struct { p: sketch_.PointRef, to: geom.Point },
    /// A dimension made reference (it reports) or driving again.
    reference: struct { c: sketch_.ConstraintId, on: bool },
    /// Where a dimension is drawn.
    place: struct { c: sketch_.ConstraintId, place: sketch_.constraint.dimension.Placement },
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

/// How a figure's placement is bordered: a box round its ink at the
/// margin, or a wrap (`geom.wrap`) of lines and arcs no tighter than
/// `radius` round its ink at the margin, made by Apply and kept: `path`,
/// mm with the ink's bottom left at the origin, made at ink width
/// `made_w` (scaled with the placement since).
pub const BorderKind = enum { box, dubins };
pub const FigureBorder = struct {
    kind: BorderKind = .box,
    radius: f64 = 3,
    path: geom.Outline = .{ .contours = &.{} },
    made_w: f64 = 0,

    /// The wrap's bounds as multiples of the ink's width, about the ink's
    /// bottom left; null for a box (or a wrap not made).
    pub fn fractions(b: FigureBorder) ?geom.Box {
        if (b.kind != .dubins or !(b.made_w > 0) or b.path.contours.len == 0) return null;
        const pb = b.path.bounds();
        return .{ .x0 = pb.x0 / b.made_w, .y0 = pb.y0 / b.made_w, .x1 = pb.x1 / b.made_w, .y1 = pb.y1 / b.made_w };
    }

    /// The border round ink box `ink` at `margin`, in `ink`'s frame.
    pub fn outline(b: FigureBorder, a: std.mem.Allocator, ink: geom.Box, margin: f64) std.mem.Allocator.Error!geom.Outline {
        if (b.fractions() == null) {
            const g = margin;
            const pts = [_]geom.Point{ .{ .x = ink.x0 - g, .y = ink.y0 - g }, .{ .x = ink.x1 + g, .y = ink.y0 - g }, .{ .x = ink.x1 + g, .y = ink.y1 + g }, .{ .x = ink.x0 - g, .y = ink.y1 + g } };
            const segs = try a.alloc(geom.Segment, 4);
            for (segs, 0..) |*sg, i| sg.* = .{ .line = .{ pts[i], pts[(i + 1) % 4] } };
            const cs = try a.alloc(geom.Contour, 1);
            cs[0] = .{ .segments = segs };
            return .{ .contours = cs };
        }
        const k = ink.width() / b.made_w;
        return b.path.transformed(a, geom.Affine.scale(k).then(geom.Affine.translate(ink.x0, ink.y0))) catch |e| switch (e) {
            else => return error.OutOfMemory,
        };
    }
};

/// A figure placed in a space: which figure, where its ink is and how big
/// (its proportions the figure's), and its boundary, a box round the ink
/// at a margin: what is selected, moved and resized, and what content
/// will keep clear of.
pub const FigurePlace = struct {
    id: ObjectId = .none,
    name: []const u8,
    layer: ObjectId = .none,
    /// The figure's id.
    figure: ObjectId,
    /// Its ink's bottom-left corner, mm in the space.
    at: geom.Point,
    /// Its ink's size, mm.
    w: f64,
    h: f64,
    /// The boundary's distance outside the ink, mm.
    margin: f64 = default_figure_margin,
    /// Its object origin on its boundary.
    holds: OriginPoint = .{},
    border: FigureBorder = .{},

    /// Its ink's box.
    pub fn inkBox(f: FigurePlace) geom.Box {
        return .{ .x0 = f.at.x, .y0 = f.at.y, .x1 = f.at.x + f.w, .y1 = f.at.y + f.h };
    }
    /// Its boundary's box: the ink's box grown by the margin, or its
    /// wrap's bounds.
    pub fn box(f: FigurePlace) geom.Box {
        if (f.border.fractions()) |fr| return .{ .x0 = f.at.x + fr.x0 * f.w, .y0 = f.at.y + fr.y0 * f.w, .x1 = f.at.x + fr.x1 * f.w, .y1 = f.at.y + fr.y1 * f.w };
        const g = f.margin;
        return .{ .x0 = f.at.x - g, .y0 = f.at.y - g, .x1 = f.at.x + f.w + g, .y1 = f.at.y + f.h + g };
    }
};

/// A new placement's margin, mm.
pub const default_figure_margin = 1.0;

/// The tolerance a figure's strokes are made to, mm.
pub const figure_tolerance = 0.002;

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
    /// The space it shows (see `Model.spaceIndex`).
    source: ObjectId,
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
    region: struct { parent: Parent, index: usize },
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
/// its prototype's tracks and their text).
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
    /// A sketch its instances are drawn from (by ID), solved for each
    /// instance's box: its `w` and `h` parameters take the box's size, and
    /// `params` its others. The sketch is the shape's prototype; each
    /// instance is it with its parameters resolved. `.none`: drawn by the
    /// stamp's prototype.
    sketch: ObjectId = .none,
    params: []const TileParam = &.{},
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
    /// A polar grid (a polar array): its columns run round a centre (the
    /// grid's origin) and its rows are rings out from it. Then the step
    /// across (`stepX`) is the angle between columns, degrees, clockwise,
    /// and the step down (`stepY`) the distance between rings, mm. Null: a
    /// Cartesian grid.
    polar: ?Polar = null,

    pub const Polar = struct {
        /// The first ring's radius (row 0), mm.
        radius: f64,
        /// Column 0's direction, degrees (90: straight up).
        start: f64 = 90,
    };

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
    /// An array: the sketch whose geometry gives its points (the middles of
    /// its cells), and that geometry's parts by ID. Its origin and spacing
    /// come from that sketch as solved, where its first view in the space
    /// puts it; its counts are its own (`shape.cols`, `shape.rows`).
    sketch: ObjectId = .none,
    array: ?sketch_.arrays.Refs = null,
    stamps: std.ArrayList(Stamp) = .empty,
    instances: std.ArrayList(GridInstance) = .empty,
};

pub const Panel = struct {
    id: ObjectId = .none,
    name: []const u8,
    /// True while the name is one the app gave it (Panel 1), not the user.
    default_name: bool = false,
    /// The space (the canvas, or a frame) the panel lives in (see
    /// `Model.spaceOf`); its origin is in that space's coordinates.
    /// `.none` for a panel of a worksheet, which has no spaces.
    space: ObjectId = .none,
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
    /// Which of its sketch's drawings the panel carries (its ink, its
    /// cutouts); `.none`: the sketch's first.
    drawing: ObjectId = .none,
    /// Cuts by nesting, counting the outlines inward: between an odd and
    /// the even one inside it is cut, so inside a hole is an island, and so
    /// on. Without islands only the holes in the outermost outline are cut.
    islands: bool = true,
    /// Its grids, whose instances are tiles bound to their points.
    grids: std.ArrayList(Grid) = .empty,
    /// How it is made: its stack of layer operations (see `Fab`).
    fab: Fab = .{},

    /// The panel's outline on the worksheet.
    pub fn box(p: Panel) geom.Box {
        return .{ .x0 = p.origin.x, .y0 = p.origin.y, .x1 = p.origin.x + p.w, .y1 = p.origin.y + p.h };
    }

    /// Where the panel's ink may go, on the worksheet.
    pub fn inkArea(p: Panel) geom.Box {
        return p.margins.inset(p.box());
    }
};

/// A part as made: a base of some thickness and a stack of layer
/// operations, applied in order. Each layer takes geometry from the part by
/// a rule and sweeps it from a plane up or down, adding solid in a colour
/// or cutting it away. An add takes its volume from earlier solids of other
/// colours, so the result is one solid per colour, none overlapping: what a
/// multi-colour slicer wants.
pub const Fab = struct {
    /// The base's thickness, mm: the base's top is this far above its
    /// bottom (z = 0).
    thickness: f64 = 2,
    layers: []const FabLayer = &.{},
    /// The process profile it is made with (one of `Model.processes`),
    /// which the manufacture stage checks the design against; none until
    /// one is chosen. Layout does not limit by it.
    process: ObjectId = .none,
    /// Older documents' process settings, kept on the panel until
    /// 2026-11-19: read, turned into a profile (`upgradeProcesses`), never
    /// written.
    old_layer_height: f64 = 0.2,
    old_min_stroke: f64 = 0.4,
    old_min_gap: f64 = 0.4,
    old_min_cap: f64 = 1.0,

    pub const file_names = .{ .old_layer_height = "layer_height", .old_min_stroke = "min_stroke", .old_min_gap = "min_gap", .old_min_cap = "min_cap" };
};

/// A process profile the document keeps: its ID, and the profile.
pub const Process = struct {
    id: ObjectId = .none,
    profile: process.Profile,
};

pub const FabLayer = struct {
    name: []const u8,
    source: FabSource,
    /// The plane it starts from: a surface of the base, plus `offset` mm.
    surface: enum { base_bottom, base_top } = .base_top,
    offset: f64 = 0,
    dir: enum { up, down } = .down,
    /// How far it reaches from its plane, mm; null: through the whole part.
    depth: ?f64 = null,
    op: FabOp,
};

/// The part's geometry a layer takes.
pub const FabSource = union(enum) {
    /// The part's outline, without its holes.
    edge,
    /// Its holes: hole tiles and cutouts, each its own outline.
    cutouts,
    /// Its grid parts (instances made as parts), each its own outline.
    parts,
    /// Its text: the labels in tiles' tracks of this name, or every label
    /// (runs in its tracks too) when empty.
    text: []const u8,
};

pub const FabOp = union(enum) {
    /// Solid, in a colour (or material) of this name.
    add: FabColour,
    /// Cut away from every solid made so far.
    subtract,
    /// Cut away, then filled in this colour: a subtract and an add of the
    /// same geometry and extent.
    inlay: FabColour,
};

pub const FabColour = struct { name: []const u8, color: art_.Color };

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

/// A face a text style sets in, for a role (see `Model.setStyleFace`).
pub const StyleFace = struct {
    role: []const u8,
    font: FontName,
};

/// A parameter a text style sets: for every object, or for objects of
/// one kind (see `glyphic.param`).
pub const StyleRule = struct {
    kind: ?glyphic.Kind = null,
    param: glyphic.Param,
    value: glyphic.Value,
};

/// A text style's size and base, as a new style is made with.
pub const StyleSize = struct {
    /// Cap height, mm.
    cap_height: f64 = 3,
    /// Sized by its em instead, mm (see `Model.setEmSize`).
    em_size: ?f64 = null,
    /// Baseline to baseline, in cap heights; null for its text face's
    /// ascender to descender.
    line_pitch: ?f64 = null,
    base: StyleId = .none,
};

/// A text style: a glyphic style context the document keeps (decided
/// 2026-11-16). Its faces by role and its rules are what glyphic's
/// context gets; what it does not set comes from its base, then from
/// glyphic's defaults. Its size is the text's cap height.
pub const TextStyle = struct {
    id: ObjectId = .none,
    name: []const u8,
    base: StyleId = .none,
    cap_height: f64,
    em_size: ?f64 = null,
    line_pitch: ?f64 = null,
    faces: std.ArrayList(StyleFace) = .empty,
    rules: std.ArrayList(StyleRule) = .empty,

    /// Its font for `role`, if it sets one itself.
    pub fn face(st: TextStyle, role: []const u8) ?FontName {
        for (st.faces.items) |f| if (std.mem.eql(u8, f.role, role)) return f.font;
        return null;
    }
};

/// Draws ready-made shape `kind` into the empty sketch `sk` (see
/// `Model.addShapeSketch`).
fn buildShape(al: Allocator, gpa: Allocator, sk: *sketch_.Sketch, kind: ShapeSketch) sketch_.Error!void {
    const P = struct {
        fn f(x: f64, y: f64) geom.Point {
            return .{ .x = x, .y = y };
        }
    }.f;
    const Ref = sketch_.PointRef;
    const o: Ref = .{ .geom = sketch_.origin };
    const w = 10.0;
    const h = 6.0;
    const r = 1.5;
    try sk.setParam(al, "w", "10");
    try sk.setParam(al, "h", "6");
    switch (kind) {
        .circle => {
            const c = try sk.addCircle(al, P(0, 0), w / 2, false);
            _ = try sk.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = c, .role = .centre }, o } } });
            const d = try sk.addConstraint(al, .{ .kind = .{ .radius = .{ .g = c, .value = w / 2 } } });
            try sk.setExpr(al, d, "w / 2");
        },
        .rectangle => {
            const b = try sk.addSegment(al, P(-w / 2, -h / 2), P(w / 2, -h / 2), false);
            const rt = try sk.addSegment(al, P(w / 2, -h / 2), P(w / 2, h / 2), false);
            const t = try sk.addSegment(al, P(w / 2, h / 2), P(-w / 2, h / 2), false);
            const l = try sk.addSegment(al, P(-w / 2, h / 2), P(-w / 2, -h / 2), false);
            const segs = [_]sketch_.GeomId{ b, rt, t, l };
            for (0..4) |i| _ = try sk.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = segs[i], .role = .end }, .{ .geom = segs[(i + 1) % 4], .role = .start } } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = b } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = t } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .geom = l } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .geom = rt } } });
            const corner: Ref = .{ .geom = b, .role = .start };
            try dim(al, sk, .{ .distance_x = .{ .a = o, .b = corner, .value = w / 2 } }, "w / 2");
            try dim(al, sk, .{ .distance_y = .{ .a = o, .b = corner, .value = h / 2 } }, "h / 2");
            try dim(al, sk, .{ .distance_x = .{ .a = corner, .b = .{ .geom = b, .role = .end }, .value = w } }, "w");
            try dim(al, sk, .{ .distance_y = .{ .a = .{ .geom = rt, .role = .start }, .b = .{ .geom = rt, .role = .end }, .value = h } }, "h");
        },
        .rounded_rectangle => {
            try sk.setParam(al, "r", "1.5");
            const x0 = -w / 2;
            const x1 = w / 2;
            const y0 = -h / 2;
            const y1 = h / 2;
            const b = try sk.addSegment(al, P(x0 + r, y0), P(x1 - r, y0), false);
            const br = try sk.addArc(al, P(x1 - r, y0 + r), P(x1 - r, y0), P(x1, y0 + r), false);
            const rt = try sk.addSegment(al, P(x1, y0 + r), P(x1, y1 - r), false);
            const tr = try sk.addArc(al, P(x1 - r, y1 - r), P(x1, y1 - r), P(x1 - r, y1), false);
            const t = try sk.addSegment(al, P(x1 - r, y1), P(x0 + r, y1), false);
            const tl = try sk.addArc(al, P(x0 + r, y1 - r), P(x0 + r, y1), P(x0, y1 - r), false);
            const l = try sk.addSegment(al, P(x0, y1 - r), P(x0, y0 + r), false);
            const bl = try sk.addArc(al, P(x0 + r, y0 + r), P(x0, y0 + r), P(x0 + r, y0), false);
            const ring = [_]sketch_.GeomId{ b, br, rt, tr, t, tl, l, bl };
            for (0..8) |i| _ = try sk.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = ring[i], .role = .end }, .{ .geom = ring[(i + 1) % 8], .role = .start } } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = b } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = t } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .geom = l } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .geom = rt } } });
            // Each corner meets its sides smoothly: its centre square with
            // both its ends (a tangent at a shared end would be degenerate
            // for the solver).
            for ([_]sketch_.GeomId{ br, tr, tl, bl }, 0..) |arc, k| {
                const c: Ref = .{ .geom = arc, .role = .centre };
                const s0: Ref = .{ .geom = arc, .role = .start };
                const s1: Ref = .{ .geom = arc, .role = .end };
                // Corners 0 and 2 start on a horizontal side, 1 and 3 on a
                // vertical one.
                if (k % 2 == 0) {
                    _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .points = .{ c, s0 } } } });
                    _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .points = .{ c, s1 } } } });
                } else {
                    _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .points = .{ c, s0 } } } });
                    _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .points = .{ c, s1 } } } });
                }
            }
            for ([_]sketch_.GeomId{ tr, tl, bl }) |arc| _ = try sk.addConstraint(al, .{ .kind = .{ .equal = .{ .a = br, .b = arc } } });
            try dim(al, sk, .{ .radius = .{ .g = br, .value = r } }, "r");
            try dim(al, sk, .{ .distance_x = .{ .a = o, .b = .{ .geom = l, .role = .start }, .value = -x0 } }, "w / 2");
            try dim(al, sk, .{ .distance_y = .{ .a = o, .b = .{ .geom = b, .role = .start }, .value = -y0 } }, "h / 2");
            try dim(al, sk, .{ .distance_x = .{ .a = .{ .geom = l, .role = .start }, .b = .{ .geom = rt, .role = .start }, .value = w } }, "w");
            try dim(al, sk, .{ .distance_y = .{ .a = .{ .geom = b, .role = .start }, .b = .{ .geom = t, .role = .start }, .value = h } }, "h");
        },
        .slot => {
            const c = w / 2 - h / 2;
            const b = try sk.addSegment(al, P(-c, -h / 2), P(c, -h / 2), false);
            const ar = try sk.addArc(al, P(c, 0), P(c, -h / 2), P(c, h / 2), false);
            const t = try sk.addSegment(al, P(c, h / 2), P(-c, h / 2), false);
            const al_ = try sk.addArc(al, P(-c, 0), P(-c, h / 2), P(-c, -h / 2), false);
            const ring = [_]sketch_.GeomId{ b, ar, t, al_ };
            for (0..4) |i| _ = try sk.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = ring[i], .role = .end }, .{ .geom = ring[(i + 1) % 4], .role = .start } } } });
            _ = try sk.addConstraint(al, .{ .kind = .{ .horizontal = .{ .geom = b } } });
            // Each end meets the sides smoothly: its centre square with both
            // its ends.
            for ([_]sketch_.GeomId{ ar, al_ }) |arc| for ([_]@TypeOf(o.role){ .start, .end }) |role| {
                _ = try sk.addConstraint(al, .{ .kind = .{ .vertical = .{ .points = .{ .{ .geom = arc, .role = .centre }, .{ .geom = arc, .role = role } } } } });
            };
            _ = try sk.addConstraint(al, .{ .kind = .{ .equal = .{ .a = ar, .b = al_ } } });
            try dim(al, sk, .{ .radius = .{ .g = ar, .value = h / 2 } }, "h / 2");
            try dim(al, sk, .{ .distance_x = .{ .a = o, .b = .{ .geom = ar, .role = .centre }, .value = c } }, "w / 2 - h / 2");
            try dim(al, sk, .{ .distance_y = .{ .a = o, .b = .{ .geom = ar, .role = .centre }, .value = 0 } }, "");
            try dim(al, sk, .{ .distance_x = .{ .a = .{ .geom = al_, .role = .centre }, .b = .{ .geom = ar, .role = .centre }, .value = 2 * c } }, "w - h");
        },
    }
    _ = try sk.solve(gpa);
}

fn dim(al: Allocator, sk: *sketch_.Sketch, kind: @FieldType(sketch_.Constraint, "kind"), expr: []const u8) sketch_.Error!void {
    const id = try sk.addConstraint(al, .{ .kind = kind });
    if (expr.len > 0) try sk.setExpr(al, id, expr);
}

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
    /// The document's figures: line art kept as prototypes, ink only
    /// (see `figure.zig`).
    figures: std.ArrayList(figure_.Figure) = .empty,
    /// The built-in Blank prototype, once a blank has been made.
    blank_prototype: ?PrototypeId = null,
    styles: std.ArrayList(TextStyle) = .empty,
    /// Named paragraph settings, which paragraphs of flows take.
    paragraph_styles: std.ArrayList(ParagraphStyle) = .empty,
    /// Named pens (see `StrokeStyle`): what inked line art is drawn with.
    stroke_styles: std.ArrayList(StrokeStyle) = .empty,
    connector_styles: std.ArrayList(ConnectorStyle) = .empty,
    /// Named fills (see `FillStyle`): what sketch areas are filled with.
    fill_styles: std.ArrayList(FillStyle) = .empty,
    /// The fill style new fills take.
    current_fill: ObjectId = .none,
    /// The stroke style new ink takes (`.none`: the first, or a default
    /// made when first wanted).
    current_stroke: ObjectId = .none,
    /// Style templates, which new flows' styles are copied from (see
    /// `StyleTemplate`); the first is the Default.
    templates: std.ArrayList(StyleTemplate) = .empty,
    /// The document's cases of sorts (see `Case`; Graven's own are
    /// `builtin_cases`).
    cases: std.ArrayList(Case) = .empty,
    /// The flows: content and the tracks it runs through (see `Flow`).
    flows: std.ArrayList(Flow) = .empty,
    /// Legend sheets: keypads' slot content as tables (see `LegendSheet`).
    sheets: std.ArrayList(LegendSheet) = .empty,
    /// The process profiles its panels are made with (see `process`).
    processes: std.ArrayList(Process) = .empty,
    /// The materials its plans make parts of (see `manufacture`).
    materials: std.ArrayList(manufacture.DocMaterial) = .empty,
    /// How its products are made: manufacturing plans, each over one or
    /// more panels (see `manufacture`); the active one is exported.
    plans: std.ArrayList(manufacture.Plan) = .empty,
    active_plan: ObjectId = .none,
    /// Parametric constraints on objects' features (see `constrain`).
    constraints: std.ArrayList(Constraint) = .empty,
    /// Bumped by every action, so callers can tell when to re-solve.
    revision: u64 = 0,

    pub const Error = Allocator.Error || error{ NoRoom, DuplicateDesignator, NoSuchPrototype, NoSuchTile, NoSuchTrack, NoSuchLayer, DuplicateTrack, PrototypeInUse, NoSuchRow, NoSuchItem, NoSuchStyle, BadSize, OffSheet, NotCompliant, ViewCycle, StyleLoop, BadValue, NoSuchObject, BadConstraint, BadJoin, NotFullyConstrained, NotEnclosed, SketchInUse, ProcessInUse, MaterialInUse, NotOnACurve } || sketch_.Error;

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

    /// The index of tile `id` in the list, if it is one.
    pub fn tileIndex(m: *const Model, id: TileId) ?usize {
        if (id == .none) return null;
        for (m.tiles.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    /// Tile `id`, which must be one of the document's.
    pub fn tile(m: *Model, id: TileId) *Tile {
        return &m.tiles.items[m.tileIndex(id).?];
    }

    pub fn tileConst(m: *const Model, id: TileId) *const Tile {
        return &m.tiles.items[m.tileIndex(id).?];
    }

    /// The index of prototype `id` in the list, if it is one.
    pub fn protoIndex(m: *const Model, id: PrototypeId) ?usize {
        if (id == .none) return null;
        for (m.prototypes.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    /// Prototype `id`, which must be one of the document's.
    pub fn proto(m: *const Model, id: PrototypeId) *TilePrototype {
        return &m.prototypes.items[m.protoIndex(id).?];
    }

    /// The prototype tile `id` is an instance of.
    pub fn prototypeOf(m: *const Model, id: TileId) *const TilePrototype {
        return m.proto(m.tileConst(id).prototype);
    }

    // Actions -----------------------------------------------------------

    /// A new text style named `name`, of size `size`, with no faces of its
    /// own (its base's, else the default face) and no rules.
    pub fn addStyle(m: *Model, name: []const u8, size: StyleSize) Error!StyleId {
        if (!(size.cap_height > 0)) return error.BadSize;
        const id = m.newId();
        try m.styles.append(m.a(), .{ .id = id, .name = try m.a().dupe(u8, name), .cap_height = size.cap_height, .em_size = size.em_size, .line_pitch = size.line_pitch, .base = size.base });
        m.revision += 1;
        return id;
    }

    /// The index of text style `id` in the list (`.none`: the first one).
    pub fn styleIndex(m: *const Model, id: StyleId) ?usize {
        if (id == .none) return if (m.styles.items.len > 0) 0 else null;
        for (m.styles.items, 0..) |st, i| if (st.id == id) return i;
        return null;
    }

    /// Text style `id`, which must be one of the document's.
    pub fn textStyle(m: *const Model, id: StyleId) *TextStyle {
        return &m.styles.items[m.styleIndex(id).?];
    }

    /// The index of paragraph style `id` in the list.
    pub fn paraIndex(m: *const Model, id: ParaId) ?usize {
        if (id == .none) return null;
        for (m.paragraph_styles.items, 0..) |ps, i| if (ps.id == id) return i;
        return null;
    }

    /// Paragraph style `id`, if it is one of the document's.
    pub fn paraStyle(m: *const Model, id: ParaId) ?*ParagraphStyle {
        return &m.paragraph_styles.items[m.paraIndex(id) orelse return null];
    }

    // Text styles ------------------------------------------------------------

    fn dupeFontName(m: *Model, n: FontName) Allocator.Error!FontName {
        return .{ .family = try m.a().dupe(u8, n.family), .style = try m.a().dupe(u8, n.style) };
    }

    fn styleMut(m: *Model, id: StyleId) Error!*TextStyle {
        return &m.styles.items[m.styleIndex(id) orelse return error.NoSuchStyle];
    }

    /// Renames style `id`.
    pub fn renameStyle(m: *Model, id: StyleId, name: []const u8) Error!void {
        (try m.styleMut(id)).name = try m.a().dupe(u8, name);
        m.revision += 1;
    }

    /// Sets style `id`'s line pitch, baseline to baseline in cap heights;
    /// null takes it from its text face (ascender to descender).
    pub fn setLinePitch(m: *Model, id: StyleId, pitch: ?f64) Error!void {
        if (pitch) |p| if (!(p > 0)) return error.BadSize;
        (try m.styleMut(id)).line_pitch = pitch;
        m.revision += 1;
    }

    /// Sets the style style `id` takes its faces and rules from where it
    /// sets none of its own (none: no base). Refused where it would loop.
    pub fn setStyleBase(m: *Model, id: StyleId, base: StyleId) Error!void {
        if (base != .none) {
            if (m.styleIndex(base) == null) return error.NoSuchStyle;
            var at = base;
            var n: usize = 0;
            while (at != .none) : (n += 1) {
                if (at == id or n > m.styles.items.len) return error.StyleLoop;
                at = m.textStyle(at).base;
            }
        }
        (try m.styleMut(id)).base = base;
        m.revision += 1;
    }

    /// Sets the font style `id` sets role `role` in ("text", "italic",
    /// "bold", "bold_italic", "math", or any other name: a fallback, tried
    /// in the order they were set); null removes it.
    pub fn setStyleFace(m: *Model, id: StyleId, role: []const u8, font: ?FontName) Error!void {
        const st = try m.styleMut(id);
        const at: ?usize = for (st.faces.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.role, role)) break i;
        } else null;
        if (font) |f| {
            const v: StyleFace = .{ .role = try m.a().dupe(u8, role), .font = try m.dupeFontName(f) };
            if (at) |i| st.faces.items[i] = v else try st.faces.append(m.a(), v);
        } else if (at) |i| _ = st.faces.orderedRemove(i);
        m.revision += 1;
    }

    /// Sets parameter `param` to `value` in style `id`, for every object
    /// (kind null) or for objects of `kind`; null removes the rule.
    pub fn setStyleRule(m: *Model, id: StyleId, kind: ?glyphic.Kind, param: glyphic.Param, value: ?glyphic.Value) Error!void {
        const st = try m.styleMut(id);
        const at: ?usize = for (st.rules.items, 0..) |r, i| {
            if (r.kind == kind and r.param == param) break i;
        } else null;
        if (value) |v| {
            glyphic.param.check(param, v) catch return error.BadValue;
            var owned = v;
            if (v == .name) owned = .{ .name = try m.a().dupe(u8, v.name) };
            const r: StyleRule = .{ .kind = kind, .param = param, .value = owned };
            if (at) |i| st.rules.items[i] = r else try st.rules.append(m.a(), r);
        } else if (at) |i| _ = st.rules.orderedRemove(i);
        m.revision += 1;
    }

    /// How many styles take style `id` as their base.
    pub fn styleUsers(m: *const Model, id: StyleId) usize {
        var n: usize = 0;
        for (m.styles.items) |st| {
            if (st.base == id) n += 1;
        }
        return n;
    }

    /// Makes the document a canvas (space 0), in `units`. Returns the
    /// canvas's index among the spaces.
    pub fn startCanvas(m: *Model, units: Units) Error!usize {
        if (m.panels.items.len > 0 or m.spaces.items.len > 0) return error.NoRoom;
        m.units = units;
        m.has_sheet = false;
        try m.spaces.append(m.a(), .{ .id = m.newId(), .name = "Canvas" });
        try m.addBaseLayer(0);
        m.revision += 1;
        return 0;
    }

    /// A new object ID.
    pub fn newId(m: *Model) ObjectId {
        const id: ObjectId = @fromBackingInt(@intCast(m.next_id));
        m.next_id += 1;
        return id;
    }

    /// The canvas, as a parent, if the document is a canvas.
    pub fn canvas(m: *const Model) ?Parent {
        if (m.spaces.items.len == 0) return null;
        return .{ .space = 0 };
    }

    /// The content layouts (tracks and regions) in `parent`.
    pub fn regionsIn(m: *const Model, parent: Parent) []TileRegion {
        return switch (parent) {
            .space => |i| m.spaces.items[i].regions.items,
            .panel => |i| m.panels.items[i].regions.items,
        };
    }

    /// The list of `parent`'s content layouts, to add to or take from.
    pub fn regionList(m: *Model, parent: Parent) *std.ArrayList(TileRegion) {
        return switch (parent) {
            .space => |i| &m.spaces.items[i].regions,
            .panel => |i| &m.panels.items[i].regions,
        };
    }

    /// The grids in `parent`.
    pub fn gridsIn(m: *const Model, parent: Parent) []Grid {
        return switch (parent) {
            .space => |i| m.spaces.items[i].grids.items,
            .panel => |i| m.panels.items[i].grids.items,
        };
    }

    pub fn gridList(m: *Model, parent: Parent) *std.ArrayList(Grid) {
        return switch (parent) {
            .space => |i| &m.spaces.items[i].grids,
            .panel => |i| &m.panels.items[i].grids,
        };
    }

    /// Line art in `parent`: a panel's; a workspace holds none.
    pub fn artIn(m: *const Model, parent: Parent) []PanelArt {
        return switch (parent) {
            .space => &.{},
            .panel => |i| m.panels.items[i].art.items,
        };
    }

    /// Whether `parent` still exists.
    pub fn hasParent(m: *const Model, parent: Parent) bool {
        return switch (parent) {
            .space => |i| i < m.spaces.items.len,
            .panel => |i| i < m.panels.items.len,
        };
    }

    /// The index of the space `parent` is in (a workspace is its own).
    pub fn spaceOfParent(m: *const Model, parent: Parent) usize {
        return switch (parent) {
            .space => |i| i,
            .panel => |i| m.spaceOf(i),
        };
    }

    /// Where `parent`'s frame origin sits in its space, mm: a panel's
    /// origin; a workspace's own (0, 0).
    pub fn parentOrigin(m: *const Model, parent: Parent) geom.Point {
        return switch (parent) {
            .space => .{ .x = 0, .y = 0 },
            .panel => |i| m.panels.items[i].origin,
        };
    }

    /// The object ID of `parent`.
    pub fn parentId(m: *const Model, parent: Parent) ObjectId {
        return switch (parent) {
            .space => |i| m.spaces.items[i].id,
            .panel => |i| m.panels.items[i].id,
        };
    }

    /// The parent whose ID is `id`.
    pub fn parentOfId(m: *const Model, id: ObjectId) ?Parent {
        if (m.spaceIndex(id)) |i| return .{ .space = i };
        if (m.panelIndex(id)) |i| return .{ .panel = i };
        return null;
    }

    /// `parent`'s name.
    pub fn parentName(m: *const Model, parent: Parent) []const u8 {
        return switch (parent) {
            .space => |i| m.spaces.items[i].name,
            .panel => |i| m.panels.items[i].name,
        };
    }

    /// Where names of `parent`'s content layouts and grids must be unique.
    pub fn containerOf(m: *const Model, parent: Parent) Container {
        return switch (parent) {
            .space => |i| .{ .space = m.spaces.items[i].id },
            .panel => |i| .{ .panel = i },
        };
    }

    /// How many parents there are: the spaces, then the panels (see
    /// `parentAt`).
    pub fn parentCount(m: *const Model) usize {
        return m.spaces.items.len + m.panels.items.len;
    }

    /// The `i`th parent, counting the spaces, then the panels.
    pub fn parentAt(m: *const Model, i: usize) Parent {
        return if (i < m.spaces.items.len) .{ .space = i } else .{ .panel = i - m.spaces.items.len };
    }

    /// The inverse of `parentAt`.
    pub fn parentSlot(m: *const Model, parent: Parent) usize {
        return switch (parent) {
            .space => |i| i,
            .panel => |i| m.spaces.items.len + i,
        };
    }

    /// Adds a frame: a space of its own, with `bound` (its own coordinates,
    /// mm) or none yet. Returns its index among the spaces.
    pub fn addFrame(m: *Model, name: []const u8, edge: ?geom.Box) Error!usize {
        if (m.spaces.items.len == 0) return error.NoRoom;
        if (edge) |b| if (!(b.width() > 0 and b.height() > 0)) return error.BadSize;
        const sid = m.spaces.items.len;
        const id = m.newId();
        const owned = try m.a().dupe(u8, name);
        try m.spaces.append(m.a(), .{ .id = id, .name = owned, .bound = edge });
        try m.addBaseLayer(sid);
        m.revision += 1;
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

    /// The index of the space a panel lives in (0 for a worksheet's
    /// panel, which has none).
    pub fn spaceOf(m: *const Model, panel: usize) usize {
        return m.spaceIndex(m.panels.items[panel].space) orelse 0;
    }

    /// The index of space `id`.
    pub fn spaceIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.spaces.items, 0..) |sp, i| if (sp.id == id) return i;
        return null;
    }

    /// The index of panel `id`.
    pub fn panelIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.panels.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    /// Whether panel `panel` lives in space `space` (by index).
    pub fn inSpace(m: *const Model, panel: usize, space: usize) bool {
        return space < m.spaces.items.len and m.panels.items[panel].space == m.spaces.items[space].id;
    }

    /// Where a name must be unique (see `names`): the objects of one
    /// container share one namespace, whatever their kind.
    pub const Container = union(enum) {
        /// The document's canvas and frames.
        spaces,
        /// A space's panels, content layouts, grids, layers, groups,
        /// views, images and sketch views (`.none`: a worksheet's panels).
        space: ObjectId,
        /// A panel's tracks and regions, grids and line art.
        panel: usize,
        /// A panel's fabrication layers.
        fab: usize,
        styles,
        paragraph_styles,
        prototypes,
        flows,
        sheets,
        sketches,
        figures,
        processes,
        materials,
        plans,
        stroke_styles,
        fill_styles,
        /// A prototype's slots.
        prototype: PrototypeId,
        /// A plan's operations.
        plan: ObjectId,
        /// Keys' designators (the document's, for now).
        keys,
    };

    /// Whether an object in container `c` is named `name`.
    pub fn nameTaken(m: *const Model, c: Container, name: []const u8) bool {
        const eq = std.mem.eql;
        switch (c) {
            .spaces => for (m.spaces.items) |sp| if (eq(u8, sp.name, name)) return true,
            .space => |sid| {
                for (m.panels.items) |p| if (p.space == sid and eq(u8, p.name, name)) return true;
                if (m.spaceIndex(sid)) |si| {
                    const sp = m.spaces.items[si];
                    for (sp.regions.items) |r| if (eq(u8, r.name, name)) return true;
                    for (sp.grids.items) |g| if (eq(u8, g.name, name)) return true;
                    for (sp.layers.items) |l| if (eq(u8, l.name, name)) return true;
                    for (sp.groups.items) |g| if (eq(u8, g.name, name)) return true;
                    for (sp.images.items) |im| if (eq(u8, im.name, name)) return true;
                }
            },
            .panel => |pi| if (pi < m.panels.items.len) {
                const p = m.panels.items[pi];
                for (p.regions.items) |r| if (eq(u8, r.name, name)) return true;
                for (p.grids.items) |g| if (eq(u8, g.name, name)) return true;
                for (p.art.items) |a_| if (eq(u8, a_.name, name)) return true;
            },
            .fab => |pi| if (pi < m.panels.items.len) {
                for (m.panels.items[pi].fab.layers) |l| if (eq(u8, l.name, name)) return true;
            },
            .styles => for (m.styles.items) |st| if (eq(u8, st.name, name)) return true,
            .paragraph_styles => for (m.paragraph_styles.items) |ps| if (eq(u8, ps.name, name)) return true,
            .prototypes => for (m.prototypes.items) |pr| if (eq(u8, pr.name, name)) return true,
            .flows => for (m.flows.items) |f| if (eq(u8, f.name, name)) return true,
            .sheets => for (m.sheets.items) |sh| if (eq(u8, sh.name, name)) return true,
            .sketches => for (m.sketches.items) |sk| if (eq(u8, sk.name, name)) return true,
            .figures => for (m.figures.items) |f| if (eq(u8, f.name, name)) return true,
            .processes => for (m.processes.items) |pr| if (eq(u8, pr.profile.name, name)) return true,
            .materials => for (m.materials.items) |mt| if (eq(u8, mt.material.name, name)) return true,
            .plans => for (m.plans.items) |pl| if (eq(u8, pl.name, name)) return true,
            .stroke_styles => for (m.stroke_styles.items) |st| if (eq(u8, st.name, name)) return true,
            .fill_styles => for (m.fill_styles.items) |st| if (eq(u8, st.name, name)) return true,
            .prototype => |id| if (m.protoIndex(id)) |k| {
                for (m.prototypes.items[k].tracks) |tt| if (eq(u8, tt.name, name)) return true;
            },
            .plan => |id| for (m.plans.items) |pl| if (pl.id == id) {
                for (pl.operations) |op| if (eq(u8, op.name, name)) return true;
            },
            .keys => return m.findTile(name) != null,
        }
        return false;
    }

    const Taken = struct {
        m: *const Model,
        c: Container,
        fn f(t: Taken, name: []const u8) bool {
            return t.m.nameTaken(t.c, name);
        }
    };

    /// A name Graven makes up in container `c`: `prefix` (an identifier)
    /// and the lowest number free there, into `buf` (Track1, Track2 …).
    pub fn freshName(m: *const Model, buf: []u8, c: Container, prefix: []const u8) []const u8 {
        return names.fresh(buf, prefix, Taken{ .m = m, .c = c }, Taken.f);
    }

    /// `name` made an identifier, itself when free in `c`, else numbered.
    pub fn freshOrSame(m: *const Model, buf: []u8, c: Container, name: []const u8, fallback: []const u8) []const u8 {
        var ib: [96]u8 = undefined;
        const id = names.identifier(&ib, name, fallback);
        return names.freshOrSame(buf, id, Taken{ .m = m, .c = c }, Taken.f);
    }

    /// What a name path reaches (see `resolve`).
    pub const Ref = union(enum) {
        space: usize,
        panel: usize,
        region: struct { parent: Parent, region: usize },
        grid: struct { parent: Parent, index: usize },
        art: struct { panel: usize, index: usize },
        tile: TileId,
        /// A document collection itself (Styles, Flows …).
        collection: Collection,
        style: ObjectId,
        paragraph_style: ObjectId,
        prototype: PrototypeId,
        flow: ObjectId,
        sheet: ObjectId,
        sketch: usize,
        figure: usize,
        process: ObjectId,
        material: ObjectId,
        plan: ObjectId,
    };

    pub const Collection = enum { styles, paragraph_styles, prototypes, flows, sheets, sketches, figures, processes, materials, plans };

    /// The collections' names in paths.
    pub const collection_names = [_]struct { []const u8, Collection }{
        .{ "Styles", .styles },       .{ "ParagraphStyles", .paragraph_styles }, .{ "Prototypes", .prototypes },
        .{ "Flows", .flows },         .{ "Sheets", .sheets },                    .{ "Sketches", .sketches },
        .{ "Processes", .processes }, .{ "Materials", .materials },              .{ "Plans", .plans },
        .{ "Figures", .figures },
    };

    /// The object a name path reaches: names joined by "." (a name that is
    /// not an identifier in double quotes), each found among the objects of
    /// the one before (see `Container`). It starts at a space (Canvas,
    /// Frame1), a panel (in any space, the canvas's first), a collection
    /// (Styles, Flows, Plans …), or a member of one by its name alone (a
    /// flow, a style …). Then: a panel's tracks, regions, grids and art; a
    /// track's or a flow's keys (by designator: keys are named within
    /// their flow); a collection's members. Null when nothing has the name.
    pub fn resolve(m: *const Model, path: []const u8) ?Ref {
        var parts: [16][]const u8 = undefined;
        const n = splitPath(path, &parts) orelse return null;
        if (n == 0) return null;
        var at: Ref = m.resolveFirst(parts[0]) orelse return null;
        for (parts[1..n]) |name| at = m.resolveIn(at, name) orelse return null;
        return at;
    }

    fn splitPath(path: []const u8, out: *[16][]const u8) ?usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < path.len) {
            if (n == out.len) return null;
            if (path[i] == '"') {
                const end = std.mem.indexOfScalarPos(u8, path, i + 1, '"') orelse return null;
                out[n] = path[i + 1 .. end];
                i = end + 1;
            } else {
                const end = std.mem.indexOfScalarPos(u8, path, i, '.') orelse path.len;
                out[n] = path[i..end];
                i = end;
            }
            n += 1;
            if (i < path.len) {
                if (path[i] != '.') return null;
                i += 1;
            }
        }
        return n;
    }

    fn resolveFirst(m: *const Model, name: []const u8) ?Ref {
        const eq = std.mem.eql;
        for (m.spaces.items, 0..) |sp, i| if (eq(u8, sp.name, name)) return .{ .space = i };
        for (m.panels.items, 0..) |p, i| if (eq(u8, p.name, name)) return .{ .panel = i };
        for (collection_names) |c| if (eq(u8, c[0], name)) return .{ .collection = c[1] };
        for (collection_names) |c| if (m.resolveIn(.{ .collection = c[1] }, name)) |r| return r;
        return null;
    }

    fn resolveIn(m: *const Model, at: Ref, name: []const u8) ?Ref {
        const eq = std.mem.eql;
        switch (at) {
            .space => |si| {
                const sp = m.spaces.items[si];
                for (m.panels.items, 0..) |p, i| if (p.space == sp.id and eq(u8, p.name, name)) return .{ .panel = i };
                for (sp.regions.items, 0..) |r, i| if (eq(u8, r.name, name)) return .{ .region = .{ .parent = .{ .space = si }, .region = i } };
                for (sp.grids.items, 0..) |g, i| if (eq(u8, g.name, name)) return .{ .grid = .{ .parent = .{ .space = si }, .index = i } };
                return null;
            },
            .panel => |pi| {
                const p = m.panels.items[pi];
                for (p.regions.items, 0..) |r, i| if (eq(u8, r.name, name)) return .{ .region = .{ .parent = .{ .panel = pi }, .region = i } };
                for (p.grids.items, 0..) |g, i| if (eq(u8, g.name, name)) return .{ .grid = .{ .parent = .{ .panel = pi }, .index = i } };
                for (p.art.items, 0..) |a_, i| if (eq(u8, a_.name, name)) return .{ .art = .{ .panel = pi, .index = i } };
                return null;
            },
            .region => |r| return m.keyInFlow(m.flowItems(r.parent, r.region), name),
            .flow => |id| {
                const fi = m.flowIndex(id) orelse return null;
                return m.keyInFlow(m.flows.items[fi].items.items, name);
            },
            .collection => |c| switch (c) {
                .styles => for (m.styles.items) |st| if (eq(u8, st.name, name)) return .{ .style = st.id },
                .paragraph_styles => for (m.paragraph_styles.items) |ps| if (eq(u8, ps.name, name)) return .{ .paragraph_style = ps.id },
                .prototypes => for (m.prototypes.items) |pr| if (eq(u8, pr.name, name)) return .{ .prototype = pr.id },
                .flows => for (m.flows.items) |f| if (eq(u8, f.name, name)) return .{ .flow = f.id },
                .sheets => for (m.sheets.items) |sh| if (eq(u8, sh.name, name)) return .{ .sheet = sh.id },
                .sketches => for (m.sketches.items, 0..) |sk, i| if (eq(u8, sk.name, name)) return .{ .sketch = i },
                .figures => for (m.figures.items, 0..) |f, i| if (eq(u8, f.name, name)) return .{ .figure = i },
                .processes => for (m.processes.items) |pr| if (eq(u8, pr.profile.name, name)) return .{ .process = pr.id },
                .materials => for (m.materials.items) |mt| if (eq(u8, mt.material.name, name)) return .{ .material = mt.id },
                .plans => for (m.plans.items) |pl| if (eq(u8, pl.name, name)) return .{ .plan = pl.id },
            },
            else => return null,
        }
        return null;
    }

    fn keyInFlow(m: *const Model, items: []const Item, name: []const u8) ?Ref {
        for (items) |item| if (item.tileOf()) |t| {
            if (m.tileIndex(t) == null) continue;
            const tl = m.tileConst(t);
            if (!tl.removed and std.mem.eql(u8, tl.designator, name)) return .{ .tile = t };
        };
        return null;
    }

    /// The first "<prefix>N" not yet used as a space name (Frame1).
    pub fn nextFrameName(m: *const Model, buf: []u8, prefix: []const u8) []const u8 {
        return m.freshName(buf, .spaces, prefix);
    }

    /// Where object `id` is now, if it exists (groups are not objects in
    /// panels: see `findGroup`).
    pub fn locate(m: *const Model, id: ObjectId) ?Member {
        if (id == .none) return null;
        for (m.spaces.items, 0..) |sp, si| {
            for (sp.regions.items, 0..) |r, i| if (r.id == id) return .{ .region = .{ .parent = .{ .space = si }, .index = i } };
        }
        for (m.panels.items, 0..) |p, pi| {
            if (p.id == id) return .{ .panel = pi };
            for (p.regions.items, 0..) |r, i| if (r.id == id) return .{ .region = .{ .parent = .{ .panel = pi }, .index = i } };
            for (p.art.items, 0..) |x, i| if (x.id == id) return .{ .art = .{ .panel = pi, .index = i } };
        }
        return null;
    }

    /// The ID of the object at `loc`.
    pub fn idAt(m: *const Model, loc: Member) ObjectId {
        return switch (loc) {
            .panel => |pi| m.panels.items[pi].id,
            .region => |l| m.regionsIn(l.parent)[l.index].id,
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
        return m.spaceOfParent(memberParent(loc));
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
    pub fn forget(m: *Model, id: ObjectId) void {
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
                    const o = &m.regionsIn(l.parent)[l.index].origin;
                    o.* = .{ .x = o.x + dx, .y = o.y + dy };
                },
            }
        }
        m.revision += 1;
    }

    /// Moves `ids` (objects and groups, all of one space) into space
    /// `dest`, keeping their coordinates: panels change space, content
    /// layouts move onto `dest`, and groups
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
        switch (loc) {
            // Line art is content: it goes only with its panel, never
            // loose onto a workspace.
            .art => return error.NoRoom,
            .region => |l| {
                const src = m.regionList(l.parent);
                const item = if (copy) try m.copyRegion(src.items[l.index]) else src.orderedRemove(l.index);
                try m.spaces.items[dest].regions.append(m.a(), item);
                try pairs.append(m.a(), .{ id, item.id });
                return item.id;
            },
            .panel => |pi| {
                const target = if (copy) try m.copyPanel(pi) else pi;
                m.panels.items[target].space = m.spaces.items[dest].id;
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

    fn memberParent(mb: Member) Parent {
        return switch (mb) {
            .panel => |pi| .{ .panel = pi },
            .region => |l| l.parent,
            .art => |l| .{ .panel = l.panel },
        };
    }

    /// A copy of a track, with copies of its tiles (new designators) and a
    /// new ID.
    fn copyRegion(m: *Model, r: TileRegion) Error!TileRegion {
        var c = r;
        c.id = m.newId();
        c.name = try m.a().dupe(u8, r.name);
        // A copy has a flow of its own, with a copy of what the track's
        // flow holds when the track starts it (copies of a whole panel are
        // rejoined by `copyPanel`).
        const src = m.trackById(r.id);
        const own: []const Item = if (src) |t| m.ownItems(t.parent, t.region) else &.{};
        const src_flow: ?Flow = if (src) |t| (if (m.trackFlow(t.parent, t.region)) |f| f.* else null) else null;
        const fi = try m.newFlow(r.name, c.id);
        c.flow = m.flows.items[fi].id;
        if (src_flow) |f| {
            m.flows.items[fi].indent = f.indent;
            if (own.len > 0 or m.firstOfFlow(src.?.parent, src.?.region)) m.flows.items[fi].paragraph = f.paragraph;
        }
        c.path = .empty;
        for (r.path.items) |cp| try c.path.append(m.a(), .{ .id = m.newId(), .along = cp.along, .across = cp.across });
        var items: std.ArrayList(Item) = .empty;
        for (own) |item| {
            var it = item;
            switch (item.what) {
                .tile => |tid| {
                    const t = m.tileConst(tid);
                    var buf: [64]u8 = undefined;
                    const prefix = if (m.proto(t.prototype).spacer) "B" else "T";
                    var copy_t = t.*;
                    copy_t.designator = m.nextDesignator(&buf, prefix);
                    it.what = .{ .tile = try m.addTile(copy_t) };
                },
                .run => |run| it.what.run.content = try m.a().dupe(u8, run.content),
                .hard_break, .paragraph => {},
            }
            try items.append(m.a(), it);
        }
        m.flows.items[fi].items = items;
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
        // Its flows, among the copies: the copies of a flow's tracks on
        // the panel run through the flow of the first of them, in order.
        for (p.regions.items, 0..) |r, k| {
            const f = m.trackFlow(.{ .panel = pi }, k) orelse continue;
            // Only from the first of the flow's tracks on this panel.
            const first = for (f.tracks.items) |id| {
                if (m.regionIndex(.{ .panel = pi }, id) != null) break id;
            } else continue;
            if (first != r.id) continue;
            const into = m.flowIndex(c.regions.items[k].flow).?;
            for (f.tracks.items) |id| {
                if (id == r.id) continue;
                const n = m.regionIndex(.{ .panel = pi }, id) orelse continue;
                const gone = c.regions.items[n].flow;
                try m.flows.items[into].tracks.append(m.a(), c.regions.items[n].id);
                c.regions.items[n].flow = m.flows.items[into].id;
                if (m.flowIndex(gone)) |gi| _ = m.flows.orderedRemove(gi);
            }
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
        p.art = .empty;
        // On a canvas, a panel given no space goes on the canvas.
        if (p.space == .none and m.spaces.items.len > 0) p.space = m.spaces.items[0].id;
        if (p.space != .none and m.spaceIndex(p.space) == null) return error.NoSuchItem;
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

    /// Renames panel `panel`.
    pub fn renamePanel(m: *Model, panel: usize, name: []const u8) Error!void {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        if (name.len == 0) return error.BadValue;
        m.panels.items[panel].name = try m.a().dupe(u8, name);
        if (@hasField(Panel, "default_name")) m.panels.items[panel].default_name = false;
        m.revision += 1;
    }

    /// Sets a rectangular panel's size, mm (its origin, bottom left, stays
    /// put). A panel whose outline is drawn (an edge or a sketch) is sized
    /// by that, so it refuses.
    pub fn setPanelSize(m: *Model, panel: usize, w: f64, h: f64) Error!void {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        if (!(w > 0) or !(h > 0)) return error.BadSize;
        const p = &m.panels.items[panel];
        if (p.edge != null or p.sketch != .none) return error.BadSize;
        p.w = w;
        p.h = h;
        m.revision += 1;
    }

    /// Whether a panel complies: its outline on the sheet, and its ink area
    /// inside the sheet's ink area (its outline may reach into the sheet's
    /// margins).
    pub fn compliant(m: *const Model, panel: usize) bool {
        return m.compliantAt(panel, m.panels.items[panel].origin);
    }

    pub fn compliantAt(m: *const Model, panel: usize, origin: geom.Point) bool {
        if (!m.has_sheet) return true;
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
        try m.spaces.items[space].layers.append(m.a(), .{ .id = id, .name = "Layer1" });
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

    /// The first "LayerN" not yet used in space `space`.
    pub fn nextLayerName(m: *const Model, space: usize, buf: []u8) []const u8 {
        return m.freshName(buf, .{ .space = m.spaces.items[space].id }, "Layer");
    }

    /// Shows or hides editor layer `which` in space `space`, and places it
    /// with `below` of the space's layers under it (`maxInt`: on top).
    pub fn setOverlay(m: *Model, space: usize, which: Overlay, shown: bool, below: u16) Error!void {
        if (space >= m.spaces.items.len) return error.BadValue;
        m.spaces.items[space].overlays.set(which, .{ .shown = shown, .below = below });
        m.revision += 1;
    }

    /// Sets space `space`'s grid spacing, mm (0: adaptive).
    pub fn setGridSpacing(m: *Model, space: usize, spacing: f64) Error!void {
        if (space >= m.spaces.items.len) return error.BadValue;
        if (!(spacing >= 0) or !std.math.isFinite(spacing)) return error.BadSize;
        m.spaces.items[space].grid_spacing = spacing;
        m.revision += 1;
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
        // Content layouts and grids set on the workspace are on its base
        // layer.
        if (base and (sp.regions.items.len > 0 or sp.grids.items.len > 0)) return true;
        for (m.panels.items) |p| {
            if (p.space != sp.id) continue;
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
        if (m.spaces.items[m.spaceOf(panel)].layerIndex(layer) == null) return error.NoSuchLayer;
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

    /// A construction line in space `space` through `at` at `angle`
    /// degrees, named Guide1, Guide2 …; its index.
    pub fn addGuide(m: *Model, space: usize, at: geom.Point, angle: f64) Error!usize {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        if (!std.math.isFinite(angle) or !std.math.isFinite(at.x) or !std.math.isFinite(at.y)) return error.BadSize;
        const list = &m.spaces.items[space].guides;
        var nb: [32]u8 = undefined;
        var n: usize = 1;
        const name = while (true) : (n += 1) {
            const cand = std.fmt.bufPrint(&nb, "Guide{d}", .{n}) catch "Guide";
            const taken = for (list.items) |g| {
                if (std.mem.eql(u8, g.name, cand)) break true;
            } else false;
            if (!taken) break cand;
        };
        var deg = @mod(angle, 180);
        if (deg < 0) deg += 180;
        try list.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .at = at, .angle = deg });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Construction line `index` of space `space` set: through `at`, at
    /// `angle` (horizontal and vertical locks set their own), held by `lock`.
    pub fn setGuide(m: *Model, space: usize, index: usize, at: geom.Point, angle: f64, lock: GuideLock) Error!void {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        const list = m.spaces.items[space].guides.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!std.math.isFinite(angle) or !std.math.isFinite(at.x) or !std.math.isFinite(at.y)) return error.BadSize;
        const g = &list[index];
        g.at = at;
        g.lock = lock;
        var deg = @mod(angle, 180);
        if (deg < 0) deg += 180;
        g.angle = switch (lock) {
            .horizontal => 0,
            .vertical => 90,
            else => deg,
        };
        m.revision += 1;
    }

    pub fn removeGuide(m: *Model, space: usize, index: usize) Error!void {
        if (space >= m.spaces.items.len or index >= m.spaces.items[space].guides.items.len) return error.NoSuchItem;
        _ = m.spaces.items[space].guides.orderedRemove(index);
        m.revision += 1;
    }

    /// Places figure `figure` (its index) in space `space`, its ink's
    /// bottom-left corner at `at`, `w` mm wide (its height keeps the ink's
    /// proportions), on layer `layer`, named after the figure. Its index
    /// among the space's placements.
    pub fn placeFigure(m: *Model, space: usize, figure: usize, at: geom.Point, w: f64, layer: ObjectId) Error!usize {
        if (space >= m.spaces.items.len or figure >= m.figures.items.len) return error.NoSuchItem;
        if (!(w > 0)) return error.BadSize;
        if (m.spaces.items[space].layerIndex(layer) == null) return error.NoSuchLayer;
        const f = m.figures.items[figure];
        const fb = f.bounds();
        if (fb.isEmpty() or !(fb.width() > 0)) return error.BadSize;
        const list = &m.spaces.items[space].figure_places;
        try list.append(m.a(), .{
            .id = m.newId(),
            .name = try m.a().dupe(u8, f.name),
            .layer = layer,
            .figure = f.id,
            .at = at,
            .w = w,
            .h = w * fb.height() / fb.width(),
        });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Sets a placement's ink corner, width (its height follows), margin
    /// and layer.
    pub fn setFigurePlace(m: *Model, space: usize, index: usize, at: geom.Point, w: f64, margin: f64, layer: ObjectId) Error!void {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        const list = m.spaces.items[space].figure_places.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!(w > 0) or !(margin >= 0)) return error.BadSize;
        if (m.spaces.items[space].layerIndex(layer) == null) return error.NoSuchLayer;
        const fp = &list[index];
        fp.h = if (fp.w > 0) w * fp.h / fp.w else fp.h;
        fp.w = w;
        fp.at = at;
        const remake = fp.margin != margin;
        fp.margin = margin;
        fp.layer = layer;
        if (remake and fp.border.kind == .dubins) if (m.figureIndex(fp.figure)) |fi| {
            fp.border.path = try m.figureWrap(fi, fp.w, fp.margin, fp.border.radius);
            fp.border.made_w = fp.w;
        };
        m.revision += 1;
    }

    /// The wrap round figure `fi`'s ink placed `w` mm wide, at `margin`,
    /// bending no tighter than `radius`: mm, the ink's bottom left at the
    /// origin.
    pub fn figureWrap(m: *Model, fi: usize, w: f64, margin: f64, radius: f64) Error!geom.Outline {
        const al = m.a();
        const shapes = try m.figureShapes(fi, w);
        var pts: std.ArrayList(geom.Point) = .empty;
        for (shapes) |sh| for (sh.outline.contours) |c| {
            try pts.appendSlice(al, try figure_.flatten(al, c.segments, figure_tolerance));
        };
        return geom.wrap.wrap(al, pts.items, margin, radius);
    }

    /// A space's placement's border set: a box, or a wrap no tighter than
    /// `radius` (made now, at its margin).
    pub fn setPlaceBorder(m: *Model, space: usize, index: usize, kind: BorderKind, radius: f64) Error!void {
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        const list = m.spaces.items[space].figure_places.items;
        if (index >= list.len) return error.NoSuchItem;
        if (!(radius >= 0)) return error.BadSize;
        const fp = &list[index];
        fp.border.kind = kind;
        fp.border.radius = radius;
        if (kind == .dubins) {
            const fi = m.figureIndex(fp.figure) orelse return error.NoSuchItem;
            fp.border.path = try m.figureWrap(fi, fp.w, fp.margin, radius);
            fp.border.made_w = fp.w;
        }
        m.revision += 1;
    }

    /// A panel's figure placement's border set (its clearance the margin).
    pub fn setArtBorder(m: *Model, panel: usize, index: usize, kind: BorderKind, radius: f64) Error!void {
        if (panel >= m.panels.items.len or index >= m.panels.items[panel].art.items.len) return error.NoSuchItem;
        if (!(radius >= 0)) return error.BadSize;
        const x = &m.panels.items[panel].art.items[index];
        x.border.kind = kind;
        x.border.radius = radius;
        if (kind == .dubins) {
            const fi = m.figureIndex(x.figure) orelse return error.NoSuchItem;
            const w = x.box().width();
            x.border.path = try m.figureWrap(fi, w, x.clearance, radius);
            x.border.made_w = w;
        }
        m.revision += 1;
    }

    pub fn removeFigurePlace(m: *Model, space: usize, index: usize) Error!void {
        if (space >= m.spaces.items.len or index >= m.spaces.items[space].figure_places.items.len) return error.NoSuchItem;
        _ = m.spaces.items[space].figure_places.orderedRemove(index);
        m.revision += 1;
    }

    /// The figure with id `id`: its index.
    pub fn figureIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.figures.items, 0..) |f, i| if (f.id == id) return i;
        return null;
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

    /// Starts a new sketch in a space of its own (see `Space.home`), its
    /// origin at the space's. Returns the sketch's index; its space is the
    /// last.
    pub fn addSketchSpace(m: *Model, name: []const u8) Error!usize {
        if (m.spaces.items.len == 0) return error.NoRoom;
        const id = m.newId();
        try m.sketches.append(m.a(), .{
            .id = id,
            .name = try m.a().dupe(u8, name),
            .sketch = try sketch_.Sketch.init(m.a()),
        });
        _ = try m.homeSpace(m.sketches.items.len - 1);
        return m.sketches.items.len - 1;
    }

    /// Sketch `index`'s own space, made (with its view) if it has none yet.
    pub fn homeSpace(m: *Model, index: usize) Error!usize {
        const sk = try m.sketchAt(index);
        if (m.homeOf(sk.id)) |si| return si;
        const sid = m.spaces.items.len;
        try m.spaces.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, sk.name), .home = sk.id });
        try m.addBaseLayer(sid);
        try m.spaces.items[sid].sketch_views.append(m.a(), .{ .id = m.newId(), .sketch = sk.id, .at = .{ .x = 0, .y = 0 } });
        m.revision += 1;
        return sid;
    }

    /// The own space of the sketch with ID `sketch`, if it has one.
    pub fn homeOf(m: *const Model, sketch: ObjectId) ?usize {
        if (sketch == .none) return null;
        for (m.spaces.items, 0..) |sp, i| if (sp.home == sketch) return i;
        return null;
    }

    /// Whether space `space` is a sketch's own space (not the canvas or a
    /// frame).
    pub fn isHome(m: *const Model, space: usize) bool {
        return space < m.spaces.items.len and m.spaces.items[space].home != .none;
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

    /// Adds a figure made of `paths` (copied), its name `name`, from file
    /// `source` (a name, or ""). Returns its index.
    pub fn addFigure(m: *Model, name: []const u8, paths: []const figure_.Path, source: []const u8) Error!usize {
        const al = m.a();
        const copy = try al.alloc(figure_.Path, paths.len);
        for (paths, copy) |p, *c| {
            c.* = p;
            const subs = try al.alloc(figure_.Subpath, p.subpaths.len);
            for (p.subpaths, subs) |sp, *o| o.* = .{ .segments = try al.dupe(geom.Segment, sp.segments), .closed = sp.closed };
            c.subpaths = subs;
        }
        try m.figures.append(al, .{
            .id = m.newId(),
            .name = try al.dupe(u8, name),
            .paths = copy,
            .source = try al.dupe(u8, source),
        });
        m.revision += 1;
        return m.figures.items.len - 1;
    }

    /// Renames a figure, and its placements with it.
    pub fn renameFigure(m: *Model, index: usize, name: []const u8) Error!void {
        if (index >= m.figures.items.len) return error.NoSuchItem;
        const id = m.figures.items[index].id;
        const n = try m.a().dupe(u8, name);
        m.figures.items[index].name = n;
        m.figures.items[index].default_name = false;
        for (m.spaces.items) |*sp| for (sp.figure_places.items) |*fp| {
            if (fp.figure == id) fp.name = n;
        };
        for (m.panels.items) |*p| for (p.art.items) |*x| {
            if (x.figure == id) x.name = n;
        };
        m.revision += 1;
    }

    /// Removes a figure and every placement of it.
    pub fn removeFigure(m: *Model, index: usize) Error!void {
        if (index >= m.figures.items.len) return error.NoSuchItem;
        const id = m.figures.items[index].id;
        for (m.spaces.items) |*sp| {
            var k: usize = sp.figure_places.items.len;
            while (k > 0) {
                k -= 1;
                if (sp.figure_places.items[k].figure == id) _ = sp.figure_places.orderedRemove(k);
            }
        }
        for (m.panels.items) |*p| {
            var k: usize = p.art.items.len;
            while (k > 0) {
                k -= 1;
                if (p.art.items[k].figure == id) _ = p.art.orderedRemove(k);
            }
        }
        _ = m.figures.orderedRemove(index);
        m.revision += 1;
    }

    /// How many times figure `index` is placed (in spaces and on panels).
    pub fn figureUses(m: *const Model, index: usize) usize {
        if (index >= m.figures.items.len) return 0;
        const id = m.figures.items[index].id;
        var n: usize = 0;
        for (m.spaces.items) |sp| for (sp.figure_places.items) |fp| {
            if (fp.figure == id) n += 1;
        };
        for (m.panels.items) |p| for (p.art.items) |x| {
            if (x.figure == id) n += 1;
        };
        return n;
    }

    /// Figure `index`'s ink, `w` mm wide (its proportions kept), its
    /// bottom left at the origin; empty when it has no ink.
    pub fn figureShapes(m: *Model, index: usize, w: f64) Error![]const art_.Shape {
        const al = m.a();
        const ink = try figure_.ink(al, m.figures.items[index], figure_tolerance);
        const b = figure_.inkBounds(ink);
        if (b.isEmpty() or !(b.width() > 0) or !(w > 0)) return &.{};
        const k = w / b.width();
        const t = geom.Affine.translate(-b.x0, -b.y0).then(geom.Affine.scale(k));
        return art_.transformShapes(al, ink, t);
    }

    /// Places figure `figure` on panel `panel` as line art: its ink's
    /// bottom left at `at` (panel frame), `w` mm wide; what flows under it
    /// flows round its box at the placement margin. Its index among the
    /// panel's art.
    pub fn placeFigureOnPanel(m: *Model, panel: usize, figure: usize, at: geom.Point, w: f64) Error!usize {
        if (panel >= m.panels.items.len or figure >= m.figures.items.len) return error.NoSuchItem;
        if (!(w > 0)) return error.BadSize;
        const shapes = try m.figureShapes(figure, w);
        if (shapes.len == 0) return error.BadSize;
        const f = m.figures.items[figure];
        const list = &m.panels.items[panel].art;
        try list.append(m.a(), .{
            .id = m.newId(),
            .name = try m.a().dupe(u8, f.name),
            .at = at,
            .shapes = shapes,
            .wrap = .bounds,
            .clearance = default_figure_margin,
            .figure = f.id,
        });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Line art that is a figure's placement, made `w` mm wide (its
    /// proportions kept), its bottom left where it was.
    pub fn setFigureArtWidth(m: *Model, panel: usize, index: usize, w: f64) Error!void {
        if (panel >= m.panels.items.len or index >= m.panels.items[panel].art.items.len) return error.NoSuchItem;
        const x = &m.panels.items[panel].art.items[index];
        const fi = m.figureIndex(x.figure) orelse return error.NoSuchItem;
        if (!(w > 0)) return error.BadSize;
        x.shapes = try m.figureShapes(fi, w);
        m.revision += 1;
    }

    /// Figure `index`'s drawing replaced (from a file read again): every
    /// placement follows, keeping its width and corner.
    pub fn replaceFigure(m: *Model, index: usize, paths: []const figure_.Path, source: []const u8) Error!void {
        if (index >= m.figures.items.len) return error.NoSuchItem;
        const al = m.a();
        const copy = try al.alloc(figure_.Path, paths.len);
        for (paths, copy) |p, *c| {
            c.* = p;
            const subs = try al.alloc(figure_.Subpath, p.subpaths.len);
            for (p.subpaths, subs) |sp, *o| o.* = .{ .segments = try al.dupe(geom.Segment, sp.segments), .closed = sp.closed };
            c.subpaths = subs;
        }
        const f = &m.figures.items[index];
        f.paths = copy;
        f.source = try al.dupe(u8, source);
        const fb = f.bounds();
        for (m.spaces.items) |*sp| for (sp.figure_places.items) |*fp| {
            if (fp.figure != f.id) continue;
            if (fb.width() > 0) fp.h = fp.w * fb.height() / fb.width();
            if (fp.border.kind == .dubins) {
                fp.border.path = try m.figureWrap(index, fp.w, fp.margin, fp.border.radius);
                fp.border.made_w = fp.w;
            }
        };
        for (m.panels.items) |*p| for (p.art.items) |*x| {
            if (x.figure != f.id or x.sketch_ink) continue;
            const w = x.box().width();
            x.shapes = try m.figureShapes(index, if (w > 0) w else 10);
            if (x.border.kind == .dubins) {
                x.border.path = try m.figureWrap(index, x.box().width(), x.clearance, x.border.radius);
                x.border.made_w = x.box().width();
            }
        };
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
    /// outline encloses (content layouts) moves onto the panel, keeping
    /// where it is. Refused unless the sketch's output has exactly one
    /// outermost closed outline. Returns the panel's index.
    /// Inserts sketch `index` into space `space` as a panel, its origin at
    /// `at` (a view placed and made a panel at once; see
    /// `makeSketchPanel`). Refused, changing nothing, unless the sketch is
    /// enclosed. Returns the panel's index.
    pub fn insertSketchPanel(m: *Model, space: usize, index: usize, at: geom.Point) Error!usize {
        const it = try m.sketchAt(index);
        _ = (try m.sketchEdge(it.used(), true, true)) orelse return error.NotEnclosed;
        const vi = try m.addSketchView(space, index, at);
        return m.makeSketchPanel(space, vi);
    }

    pub fn makeSketchPanel(m: *Model, space: usize, view: usize) Error!usize {
        const v = (try m.sketchView(space, view)).*;
        const si = m.sketchIndex(v.sketch) orelse return error.NoSuchItem;
        var name_buf: [64]u8 = undefined;
        const name = m.nextPanelName(&name_buf, m.spaces.items[space].id, "Panel");
        var p: Panel = .{
            .id = m.newId(),
            .name = try m.a().dupe(u8, name),
            .default_name = true,
            .space = m.spaces.items[space].id,
            .w = 1,
            .h = 1,
            .sketch = v.sketch,
            .sketch_at = v.at,
            .layer = v.layer,
            // The drawing being worked on now, kept when another is chosen.
            .drawing = if (m.sketchFigure(v.sketch)) |fi| m.figures.items[fi].id else .none,
        };
        const edge = (try m.sketchEdge(m.sketches.items[si].used(), true, m.sketchFigure(v.sketch) != null)) orelse return error.NotEnclosed;
        p.origin = .{ .x = v.at.x + edge.min.x, .y = v.at.y + edge.min.y };
        p.w = edge.w;
        p.h = edge.h;
        p.edge = edge.art;
        // What the outermost outline encloses moves onto the panel.
        const outer: geom.Outline = .{ .contours = edge.art.shapes[0].outline.contours[0..1] };
        const off: geom.Point = p.origin;
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
        const src = &m.spaces.items[space];
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
        for (p.regions.items) |x| m.forget(x.id);
        _ = m.spaces.items[space].sketch_views.orderedRemove(view);
        try m.panels.append(m.a(), p);
        try m.syncSketchPanelInk(m.panels.items.len - 1);
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// Whether a sketch panel cuts islands (see `Panel.islands`).
    // Grids.

    /// The shape grid `gi` of panel `panel` has: its own, or the one it
    /// follows (through any chain of links).
    pub fn gridShape(m: *const Model, parent: Parent, gi: usize) GridShape {
        if (m.arrayLayout(parent, gi)) |al| return al.shape;
        var g = &m.gridsIn(parent)[gi];
        var hops: usize = 0;
        while (g.link != .none and hops < 16) : (hops += 1) {
            const at = m.findGrid(g.link) orelse break;
            g = &m.gridsIn(at.parent)[at.index];
        }
        return g.shape;
    }

    /// The panel and index of grid `id`.
    pub fn findGrid(m: *const Model, id: ObjectId) ?struct { parent: Parent, index: usize } {
        if (id == .none) return null;
        for (0..m.parentCount()) |k| for (m.gridsIn(m.parentAt(k)), 0..) |g, gi| {
            if (g.id == id) return .{ .parent = m.parentAt(k), .index = gi };
        };
        return null;
    }

    /// Where point (`col`, `row`) of grid `gi` is, mm in the panel frame.
    pub fn gridPoint(m: *const Model, parent: Parent, gi: usize, col: f64, row: f64) geom.Point {
        const go = m.gridOrigin(parent, gi);
        const sh = m.gridShape(parent, gi);
        if (sh.polar) |pol| {
            const ang = std.math.degreesToRadians(pol.start - col * sh.stepX());
            const r = @max(0, pol.radius + row * sh.stepY());
            return .{ .x = go.x + r * @cos(ang), .y = go.y + r * @sin(ang) };
        }
        return .{ .x = go.x + col * sh.stepX(), .y = go.y - row * sh.stepY() };
    }

    /// An array grid's shape and origin (in its parent's frame), from its
    /// sketch as solved; null for a grid of another kind, or one whose
    /// sketch or view is gone.
    pub fn arrayLayout(m: *const Model, parent: Parent, gi: usize) ?struct { shape: GridShape, origin: geom.Point } {
        const g = m.gridsIn(parent)[gi];
        const refs = g.array orelse return null;
        const si = m.sketchIndex(g.sketch) orelse return null;
        const space = switch (parent) {
            .space => |i| i,
            .panel => |pi| m.spaceOf(pi),
        };
        if (space >= m.spaces.items.len) return null;
        var at: ?geom.Point = null;
        for (m.spaces.items[space].sketch_views.items) |v| if (v.sketch == g.sketch) {
            at = v.at;
            break;
        };
        var o = at orelse return null;
        if (parent == .panel) {
            const po = m.panels.items[parent.panel].origin;
            o = .{ .x = o.x - po.x, .y = o.y - po.y };
        }
        const cells = sketch_.arrays.cells(m.sketches.items[si].usedConst(), refs) catch return null;
        const cols: f64 = @floatFromInt(@max(1, g.shape.cols));
        const rows: f64 = @floatFromInt(@max(1, g.shape.rows));
        var sh = g.shape;
        sh.stretch_x = 1;
        sh.stretch_y = 1;
        switch (cells) {
            .polar => |p| {
                sh.pitch_x = std.math.radiansToDegrees(p.step);
                sh.pitch_y = p.r / rows;
                sh.polar = .{ .radius = sh.pitch_y / 2, .start = std.math.radiansToDegrees(p.first - p.step / 2) };
                return .{ .shape = sh, .origin = .{ .x = o.x + p.c.x, .y = o.y + p.c.y } };
            },
            .rect => |b| {
                sh.pitch_x = (b.x1 - b.x0) / cols;
                sh.pitch_y = (b.y1 - b.y0) / rows;
                sh.polar = null;
                return .{ .shape = sh, .origin = .{ .x = o.x + b.x0 + sh.pitch_x / 2, .y = o.y + b.y1 - sh.pitch_y / 2 } };
            },
        }
    }

    /// Grid `gi`'s point (0, 0), mm in its parent's frame (an array's from
    /// its sketch).
    pub fn gridOrigin(m: *const Model, parent: Parent, gi: usize) geom.Point {
        if (m.arrayLayout(parent, gi)) |al| return al.origin;
        return m.gridsIn(parent)[gi].origin;
    }

    /// Adds an array to `parent` (a workspace, or a panel): a sketch of its
    /// geometry (see `sketch_.arrays`), viewed in the space at `at`, and a
    /// grid whose points are its cells' middles. Polar: `cols` round, `rows`
    /// rings, centred at `at`, out to `size.x` (its first border at angle
    /// `size.y`, degrees), over `sweep` degrees. Rectangular: its top-left
    /// cell's corner at `at`, `size` across and down. Returns the grid's
    /// index.
    /// Where a caption was put: its track.
    pub const Caption = struct { parent: Parent, region: usize };

    /// A caption from `from` (a point on a side, circle or arc, or one of
    /// those itself) of sketch view `view`: the sketch gains a leader
    /// (`sketch_.caption`), and a single
    /// track of text in `style` (`pitch` its line pitch, mm), `length` mm
    /// long, is held by its left edge (the leader running right) or its
    /// right edge, and its middle, to the leader's end, its text aligned
    /// toward it. The track is in the panel the end is over, else straight
    /// in the workspace.
    pub fn addCaption(m: *Model, view: ObjectId, from: sketch_.caption.From, style: StyleId, pitch: f64, length: f64) Error!Caption {
        if (!(pitch > 0) or !(length > 0)) return error.BadSize;
        var space: ?usize = null;
        var v: SketchView = undefined;
        for (m.spaces.items, 0..) |sp, si| for (sp.sketch_views.items) |x| {
            if (x.id == view) {
                space = si;
                v = x;
            }
        };
        const si = space orelse return error.NoSuchItem;
        const ski = m.sketchIndex(v.sketch) orelse return error.NoSuchItem;
        const sk = &m.sketches.items[ski].sketch;
        const lead = sketch_.caption.addLeaderFrom(sk, m.a(), from, 3, 4) catch |e| return switch (e) {
            error.NotOnACurve => error.NotOnACurve,
            else => |x| x,
        };
        _ = try sk.solve(m.arena.child_allocator);
        m.sketches.items[ski].version +%= 1;
        // The leader is a connection, drawn in the sketch's figure in its
        // style (the document's "Leader").
        m.styleConnector(sk, lead.connector, try m.leaderStyle());
        _ = try m.sketchFigureFor(ski, true);
        try m.syncSketchFigures(m.sketches.items[ski].id);
        const e = try sk.point(lead.end);
        const at: geom.Point = .{ .x = v.at.x + e.x, .y = v.at.y + e.y };
        // The panel it is over.
        var parent: Parent = .{ .space = si };
        var off: geom.Point = .{ .x = 0, .y = 0 };
        for (m.panels.items, 0..) |pn, pi| {
            if (m.spaceOf(pi) != si) continue;
            const b = pn.box();
            if (at.x >= b.x0 and at.x <= b.x1 and at.y >= b.y0 and at.y <= b.y1) {
                parent = .{ .panel = pi };
                off = pn.origin;
            }
        }
        var name_buf: [32]u8 = undefined;
        const name = m.freshName(&name_buf, m.containerOf(parent), "Caption");
        const x0 = if (lead.right) at.x else at.x - length;
        const r = try m.addTracks(parent, .{
            .name = name,
            .origin = .{ .x = x0 - off.x, .y = at.y + pitch / 2 - off.y },
            .kind = .track,
            .style = style,
            .count = 1,
            .length = length / pitch,
            .pitch = pitch,
        });
        const region = &m.regionsIn(parent)[r];
        region.alignment = if (lead.right) .start else .end;
        const rid = region.id;
        // The caption is the sketch's: each use shows it.
        const cid = m.newId();
        region.caption = cid;
        try m.sketches.items[ski].captions.append(m.a(), .{ .id = cid, .name = region.name, .end = lead.end, .right = lead.right, .style = style, .pitch = pitch, .length = length, .base = rid, .connector = @intCast(lead.connector) });
        _ = try m.addConstraint(.{ .a = .{ .object = rid, .feature = if (lead.right) .left else .right }, .b = .{ .object = view, .feature = .origin_x, .point = lead.end } });
        _ = try m.addConstraint(.{ .a = .{ .object = rid, .feature = .centre_y }, .b = .{ .object = view, .feature = .origin_y, .point = lead.end } });
        m.revision += 1;
        return .{ .parent = parent, .region = r };
    }

    pub fn addArray(m: *Model, parent: Parent, at: geom.Point, polar: bool, cols: u32, rows: u32, size: geom.Point, sweep: f64) Error!usize {
        if (!m.hasParent(parent)) return error.NoSuchItem;
        if (cols == 0 or rows == 0) return error.BadSize;
        const space = switch (parent) {
            .space => |i| i,
            .panel => |pi| m.spaceOf(pi),
        };
        if (space >= m.spaces.items.len) return error.NoSuchItem;
        var name_buf: [32]u8 = undefined;
        const sk_name = m.freshName(&name_buf, .sketches, "Array");
        var sk = try sketch_.Sketch.init(m.a());
        const refs = (if (polar)
            sketch_.arrays.addPolar(&sk, m.a(), .{ .x = 0, .y = 0 }, size.x, std.math.degreesToRadians(size.y), std.math.degreesToRadians(sweep), cols, rows)
        else
            sketch_.arrays.addRect(&sk, m.a(), .{ .x0 = 0, .y0 = -size.y, .x1 = size.x, .y1 = 0 }, cols, rows)) catch return error.BadSize;
        const sid = m.newId();
        try m.sketches.append(m.a(), .{ .id = sid, .name = try m.a().dupe(u8, sk_name), .default_name = true, .sketch = sk });
        try m.spaces.items[space].sketch_views.append(m.a(), .{ .id = m.newId(), .sketch = sid, .at = at });
        const gi = try m.addGrid(parent, .{ .x = 0, .y = 0 }, .{ .cols = cols, .rows = rows, .pitch_x = 1, .pitch_y = 1 });
        const g = &m.gridsIn(parent)[gi];
        g.sketch = sid;
        g.array = refs;
        m.revision += 1;
        return gi;
    }

    /// Grid `gi`'s extent, mm in its parent's frame: its cells' outer
    /// borders, half a step past its outer points; a polar grid's, the
    /// square round its outer ring.
    pub fn gridExtent(m: *const Model, parent: Parent, gi: usize) geom.Box {
        const go = m.gridOrigin(parent, gi);
        const sh = m.gridShape(parent, gi);
        if (sh.polar) |pol| {
            const r = @max(0, pol.radius + (@as(f64, @floatFromInt(sh.rows)) - 0.5) * sh.stepY());
            return .{ .x0 = go.x - r, .x1 = go.x + r, .y0 = go.y - r, .y1 = go.y + r };
        }
        const w = @as(f64, @floatFromInt(sh.cols)) * sh.stepX();
        const h = @as(f64, @floatFromInt(sh.rows)) * sh.stepY();
        const x0 = go.x - sh.stepX() / 2;
        const y1 = go.y + sh.stepY() / 2;
        return .{ .x0 = x0, .x1 = x0 + w, .y0 = y1 - h, .y1 = y1 };
    }

    /// The stamp `id` of grid `gi`, by index.
    pub fn stampIndex(m: *const Model, parent: Parent, gi: usize, id: ObjectId) ?usize {
        for (m.gridsIn(parent)[gi].stamps.items, 0..) |st, i| if (st.id == id) return i;
        return null;
    }

    /// The box instance `ii` of grid `gi` takes, mm in the panel frame.
    pub fn instanceBox(m: *const Model, parent: Parent, gi: usize, ii: usize) ?geom.Box {
        const g = m.gridsIn(parent)[gi];
        const inst = g.instances.items[ii];
        const st = g.stamps.items[m.stampIndex(parent, gi, inst.stamp) orelse return null];
        const sh = m.gridShape(parent, gi);
        // A polar grid's spans do not grow the box (its steps are an angle
        // and a ring): the stamp's size, at the spanned points' middle.
        const polar = sh.polar != null;
        const w = if (polar) st.w else st.w + @as(f64, @floatFromInt(inst.cols - 1)) * sh.stepX();
        const h = if (polar) st.h else st.h + @as(f64, @floatFromInt(inst.rows - 1)) * sh.stepY();
        const c: geom.Point = inst.loose orelse blk: {
            const p = m.gridPoint(parent, gi, @as(f64, @floatFromInt(inst.col)) + @as(f64, @floatFromInt(inst.cols - 1)) / 2, @as(f64, @floatFromInt(inst.row)) + @as(f64, @floatFromInt(inst.rows - 1)) / 2);
            break :blk .{ .x = p.x + st.offset.x, .y = p.y + st.offset.y };
        };
        return .{ .x0 = c.x - w / 2, .x1 = c.x + w / 2, .y0 = c.y - h / 2, .y1 = c.y + h / 2 };
    }

    /// The grid and instance tile `id` is bound to, if any.
    pub fn gridInstanceOf(m: *const Model, id: TileId) ?struct { parent: Parent, grid: usize, index: usize } {
        for (0..m.parentCount()) |k| for (m.gridsIn(m.parentAt(k)), 0..) |g, gi| for (g.instances.items, 0..) |inst, ii| {
            if (inst.tile == id) return .{ .parent = m.parentAt(k), .grid = gi, .index = ii };
        };
        return null;
    }

    /// Adds a grid to panel `panel`, point (0, 0) at `origin`; returns its
    /// index.
    pub fn addGrid(m: *Model, parent: Parent, origin: geom.Point, shape: GridShape) Error!usize {
        if (!m.hasParent(parent)) return error.NoSuchItem;
        if (shape.cols == 0 or shape.rows == 0 or !(shape.pitch_x > 0 and shape.pitch_y > 0) or !(shape.stretch_x > 0 and shape.stretch_y > 0)) return error.BadSize;
        var name_buf: [32]u8 = undefined;
        const name = m.freshName(&name_buf, m.containerOf(parent), "Grid");
        const list = m.gridList(parent);
        try list.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .default_name = true, .origin = origin, .shape = shape });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Adds a grid to panel `panel` that follows grid `source` (on any
    /// panel), point (0, 0) at `origin`; returns its index.
    pub fn addLinkedGrid(m: *Model, parent: Parent, origin: geom.Point, source: ObjectId) Error!usize {
        const at = m.findGrid(source) orelse return error.NoSuchObject;
        const gi = try m.addGrid(parent, origin, m.gridShape(at.parent, at.index));
        m.gridsIn(parent)[gi].link = source;
        return gi;
    }

    /// What to do with instances on points a grid no longer has.
    pub const Dropped = enum { remove, leave };

    /// Changes grid `gi`'s shape (a grid that follows another takes this
    /// as its own and stops following). Instances on points it no longer
    /// has, on it and on every grid following it, are removed or left in
    /// place, unbound, as `dropped` says.
    pub fn setGridShape(m: *Model, parent: Parent, gi: usize, shape: GridShape, dropped: Dropped) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        if (shape.cols == 0 or shape.rows == 0 or !(shape.pitch_x > 0 and shape.pitch_y > 0) or !(shape.stretch_x > 0 and shape.stretch_y > 0)) return error.BadSize;
        const id = m.gridsIn(parent)[gi].id;
        // Settle the ones about to lose their points first, at their places
        // under the old shape.
        for (0..m.parentCount()) |pk| for (m.gridsIn(m.parentAt(pk)), 0..) |*g, gj| {
            const pi = m.parentAt(pk);
            if (!(pi.eql(parent) and gj == gi) and !m.follows(g.*, id)) continue;
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
        const g = &m.gridsIn(parent)[gi];
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
            link = m.gridsIn(at.parent)[at.index].link;
        }
        return false;
    }

    /// Moves grid `gi`'s point (0, 0) to `origin`.
    pub fn moveGrid(m: *Model, parent: Parent, gi: usize, origin: geom.Point) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        m.gridsIn(parent)[gi].origin = origin;
        m.revision += 1;
    }

    /// Removes grid `gi` and its instances. Grids following it keep its
    /// shape as their own.
    pub fn removeGrid(m: *Model, parent: Parent, gi: usize) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const id = m.gridsIn(parent)[gi].id;
        const shape = m.gridShape(parent, gi);
        for (m.panels.items) |*p| for (p.grids.items) |*g| if (g.link == id) {
            g.shape = shape;
            g.link = .none;
        };
        const g = m.gridList(parent).orderedRemove(gi);
        for (g.instances.items) |inst| m.tile(inst.tile).removed = true;
        m.revision += 1;
    }

    /// Adds a stamp to grid `gi`; returns its index.
    pub fn addStamp(m: *Model, parent: Parent, gi: usize, stamp: Stamp) Error!usize {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        if (m.protoIndex(stamp.prototype) == null) return error.NoSuchPrototype;
        if (!(stamp.w > 0 and stamp.h > 0)) return error.BadSize;
        if (stamp.sketch != .none and m.sketchIndex(stamp.sketch) == null) return error.NoSuchItem;
        var st = stamp;
        st.id = m.newId();
        st.name = try m.a().dupe(u8, stamp.name);
        st.params = try m.dupeParams(stamp.params);
        const g = &m.gridsIn(parent)[gi];
        try g.stamps.append(m.a(), st);
        m.revision += 1;
        return g.stamps.items.len - 1;
    }

    /// Changes stamp `si` of grid `gi` (its prototype, role, size, offset
    /// or name), and with it every instance of it.
    pub fn setStamp(m: *Model, parent: Parent, gi: usize, si: usize, stamp: Stamp) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const g = &m.gridsIn(parent)[gi];
        if (si >= g.stamps.items.len) return error.NoSuchItem;
        if (m.protoIndex(stamp.prototype) == null) return error.NoSuchPrototype;
        if (!(stamp.w > 0 and stamp.h > 0)) return error.BadSize;
        if (stamp.sketch != .none and m.sketchIndex(stamp.sketch) == null) return error.NoSuchItem;
        var st = stamp;
        st.id = g.stamps.items[si].id;
        st.name = try m.a().dupe(u8, stamp.name);
        st.params = try m.dupeParams(stamp.params);
        // The tiles take the stamp's new prototype, but for those given
        // one of their own (an ENTER key among the keys).
        const was = g.stamps.items[si].prototype;
        g.stamps.items[si] = st;
        for (g.instances.items) |inst| if (inst.stamp == st.id and m.tileConst(inst.tile).prototype == was) {
            m.tile(inst.tile).prototype = st.prototype;
        };
        m.revision += 1;
    }

    /// Removes stamp `si` of grid `gi` and its instances.
    pub fn removeStamp(m: *Model, parent: Parent, gi: usize, si: usize) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const g = &m.gridsIn(parent)[gi];
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
        return m.freshName(buf, .keys, prefix);
    }

    /// The instance of stamp `stamp` on point (`col`, `row`) of grid `gi`,
    /// by index (one spanning it counts).
    pub fn instanceAt(m: *const Model, parent: Parent, gi: usize, stamp: ObjectId, col: u32, row: u32) ?usize {
        for (m.gridsIn(parent)[gi].instances.items, 0..) |inst, ii| {
            if (inst.stamp != stamp or inst.loose != null) continue;
            if (col >= inst.col and col < inst.col + inst.cols and row >= inst.row and row < inst.row + inst.rows) return ii;
        }
        return null;
    }

    /// Makes a tile of stamp `si` and binds it to point (`col`, `row`) of
    /// grid `gi`; returns the tile. A point already holding an instance of
    /// the stamp is refused.
    pub fn addInstance(m: *Model, parent: Parent, gi: usize, si: usize, col: u32, row: u32) Error!TileId {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const st = blk: {
            const g = m.gridsIn(parent)[gi];
            if (si >= g.stamps.items.len) return error.NoSuchItem;
            break :blk g.stamps.items[si];
        };
        const sh = m.gridShape(parent, gi);
        if (col >= sh.cols or row >= sh.rows) return error.NoSuchItem;
        if (m.instanceAt(parent, gi, st.id, col, row) != null) return error.NoRoom;
        var buf: [48]u8 = undefined;
        const prefix: []const u8 = switch (st.role) {
            .part => "K",
            .hole => "H",
            .legend => "L",
        };
        const id = try m.addTile(.{ .designator = m.freeDesignator(prefix, &buf), .prototype = st.prototype });
        try m.gridsIn(parent)[gi].instances.append(m.a(), .{ .tile = id, .stamp = st.id, .col = col, .row = row });
        m.revision += 1;
        return id;
    }

    /// Fills every point of grid `gi` not holding an instance of stamp
    /// `si` with one; returns how many were made.
    pub fn fillGrid(m: *Model, parent: Parent, gi: usize, si: usize) Error!usize {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const sh = m.gridShape(parent, gi);
        const g = m.gridsIn(parent)[gi];
        if (si >= g.stamps.items.len) return error.NoSuchItem;
        const sid = g.stamps.items[si].id;
        var n: usize = 0;
        for (0..sh.rows) |r| for (0..sh.cols) |c| {
            if (m.instanceAt(parent, gi, sid, @intCast(c), @intCast(r)) != null) continue;
            _ = try m.addInstance(parent, gi, si, @intCast(c), @intCast(r));
            n += 1;
        };
        return n;
    }

    /// Sets how many points instance `ii` spans, from its point right and
    /// down. Instances of the same stamp on the points it newly covers are
    /// removed; refused past the grid's edge.
    pub fn setInstanceSpan(m: *Model, parent: Parent, gi: usize, ii: usize, cols: u32, rows: u32) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const sh = m.gridShape(parent, gi);
        var g = &m.gridsIn(parent)[gi];
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

    /// Puts an instance of stamp `si` on the `cols` × `rows` points from
    /// (`col`, `row`). What of the stamp already lies there makes way: the
    /// first such instance (its labels with it) is moved and stretched to
    /// the block, the rest removed; with none, a new one is made. Returns
    /// its tile.
    pub fn placeInstance(m: *Model, parent: Parent, gi: usize, si: usize, col: u32, row: u32, cols: u32, rows: u32) Error!TileId {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const sh = m.gridShape(parent, gi);
        if (cols == 0 or rows == 0 or col + cols > sh.cols or row + rows > sh.rows) return error.BadSize;
        const g = &m.gridsIn(parent)[gi];
        if (si >= g.stamps.items.len) return error.NoSuchItem;
        const sid = g.stamps.items[si].id;
        var kept: ?TileId = null;
        var k: usize = 0;
        while (k < g.instances.items.len) {
            const o = g.instances.items[k];
            const meets = o.stamp == sid and o.loose == null and o.col < col + cols and col < o.col + o.cols and o.row < row + rows and row < o.row + o.rows;
            if (!meets) {
                k += 1;
                continue;
            }
            if (kept == null) {
                kept = o.tile;
                g.instances.items[k].col = col;
                g.instances.items[k].row = row;
                g.instances.items[k].cols = cols;
                g.instances.items[k].rows = rows;
                k += 1;
            } else {
                m.tile(o.tile).removed = true;
                _ = g.instances.orderedRemove(k);
            }
        }
        if (kept) |t| {
            m.revision += 1;
            return t;
        }
        const id = try m.addInstance(parent, gi, si, col, row);
        const gg = &m.gridsIn(parent)[gi];
        gg.instances.items[gg.instances.items.len - 1].cols = cols;
        gg.instances.items[gg.instances.items.len - 1].rows = rows;
        return id;
    }

    /// Binds instance `ii` to point (`col`, `row`) (an unbound one too).
    pub fn bindInstance(m: *Model, parent: Parent, gi: usize, ii: usize, col: u32, row: u32) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const sh = m.gridShape(parent, gi);
        const g = &m.gridsIn(parent)[gi];
        if (ii >= g.instances.items.len) return error.NoSuchItem;
        const inst = &g.instances.items[ii];
        if (col + inst.cols > sh.cols or row + inst.rows > sh.rows) return error.BadSize;
        inst.col = col;
        inst.row = row;
        inst.loose = null;
        m.revision += 1;
    }

    /// Removes instance `ii` of grid `gi` and its tile.
    pub fn removeInstance(m: *Model, parent: Parent, gi: usize, ii: usize) Error!void {
        if (!m.hasParent(parent) or gi >= m.gridsIn(parent).len) return error.NoSuchItem;
        const g = &m.gridsIn(parent)[gi];
        if (ii >= g.instances.items.len) return error.NoSuchItem;
        const inst = g.instances.orderedRemove(ii);
        m.tile(inst.tile).removed = true;
        m.revision += 1;
    }

    // Tile tracks.

    /// Adds a track to prototype `id`, and so to every tile made from it;
    /// returns the track's ID. Names are unique within a prototype.
    pub fn addPrototypeTrack(m: *Model, id: PrototypeId, track: TileTrack) Error!ObjectId {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        const p = m.proto(id);
        for (p.tracks) |tt| if (std.mem.eql(u8, tt.name, track.name)) return error.DuplicateTrack;
        const list = try m.a().alloc(TileTrack, p.tracks.len + 1);
        @memcpy(list[0..p.tracks.len], p.tracks);
        var t = track;
        t.id = m.newId();
        t.name = try m.a().dupe(u8, track.name);
        list[p.tracks.len] = t;
        p.tracks = list;
        m.revision += 1;
        return t.id;
    }

    /// Changes track `track` of prototype `id` (its name, place, direction,
    /// style or alignment); every tile's content in it stays.
    pub fn setPrototypeTrack(m: *Model, id: PrototypeId, track: ObjectId, to: TileTrack) Error!void {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        const p = m.proto(id);
        const list = try m.a().dupe(TileTrack, p.tracks);
        for (list) |*tt| if (tt.id == track) {
            tt.* = to;
            tt.id = track;
            tt.name = try m.a().dupe(u8, to.name);
            p.tracks = list;
            m.revision += 1;
            return;
        };
        return error.NoSuchTrack;
    }

    /// Removes track `track` from prototype `id`. Tiles keep what they had
    /// in it, unshown.
    pub fn removePrototypeTrack(m: *Model, id: PrototypeId, track: ObjectId) Error!void {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        const p = m.proto(id);
        var list: std.ArrayList(TileTrack) = .empty;
        var found = false;
        for (p.tracks) |tt| {
            if (tt.id == track) found = true else try list.append(m.a(), tt);
        }
        if (!found) return error.NoSuchTrack;
        p.tracks = list.items;
        m.revision += 1;
    }

    /// The track of tile `tile`'s prototype called `name`.
    pub fn tileTrackNamed(m: *const Model, tile_id: TileId, name: []const u8) ?ObjectId {
        for (m.prototypeOf(tile_id).tracks) |tt| if (std.mem.eql(u8, tt.name, name)) return tt.id;
        return null;
    }

    /// Where track `track` is among tile `tile_id`'s prototype's tracks.
    pub fn tileTrackIndex(m: *const Model, tile_id: TileId, track: ObjectId) ?usize {
        for (m.prototypeOf(tile_id).tracks, 0..) |tt, k| if (tt.id == track) return k;
        return null;
    }

    /// Tile `tile_id`'s content in track `track`, if it has any.
    pub fn tileFlow(m: *const Model, tile_id: TileId, track: ObjectId) ?*TileFlow {
        const t = &m.tiles.items[m.tileIndex(tile_id) orelse return null];
        for (t.flows.items) |*f| if (f.track == track) return f;
        return null;
    }

    /// Sets the content of tile `tile_id`'s track called `name` (see
    /// `setTileTrackText`).
    pub fn setTrackText(m: *Model, tile_id: TileId, name: []const u8, text: []const u8) Error!void {
        if (m.tileIndex(tile_id) == null) return error.NoSuchTile;
        return m.setTileTrackText(tile_id, m.tileTrackNamed(tile_id, name) orelse return error.NoSuchTrack, text);
    }

    /// Tile `tile_id`'s content in track `track` as text, as
    /// `setTileTrackText` takes it: its runs, a newline for each hard
    /// break. Allocated with `al`.
    pub fn tileTrackText(m: *const Model, al: Allocator, tile_id: TileId, track: ObjectId) Allocator.Error![]u8 {
        const f = m.tileFlow(tile_id, track) orelse return al.alloc(u8, 0);
        return itemsText(al, f.items.items);
    }

    /// Content as plain text: its runs' markup, a newline for each break
    /// (tiles left out). The one reading of a slot or a text holder.
    pub fn itemsText(al: Allocator, items: []const Item) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (items) |it| switch (it.what) {
            .run => |r| try out.appendSlice(al, r.content),
            .hard_break, .paragraph => try out.append(al, '\n'),
            .tile => {},
        };
        return out.toOwnedSlice(al);
    }

    /// `items` made `text`: runs in `style`, a hard break at each newline.
    /// The one writing of a slot or a text holder.
    fn setItemsText(m: *Model, items: *std.ArrayList(Item), style: StyleId, text: []const u8) Error!void {
        items.* = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try items.append(m.a(), .{ .what = .hard_break });
            first = false;
            if (line.len > 0) try items.append(m.a(), .{ .what = .{ .run = .{ .style = style, .content = try m.a().dupe(u8, line) } } });
        }
        m.revision += 1;
    }

    /// Sets tile `tile_id`'s content in its prototype's track `track` to
    /// `text`: runs in the track's style, a hard break at each newline.
    /// Where a legend sheet drives that slot, its cell is set instead.
    pub fn setTileTrackText(m: *Model, tile_id: TileId, track: ObjectId, text: []const u8) Error!void {
        if (m.tileIndex(tile_id) == null) return error.NoSuchTile;
        const tt = for (m.prototypeOf(tile_id).tracks) |tt| {
            if (tt.id == track) break tt;
        } else return error.NoSuchTrack;
        if (m.sheetCellOf(tile_id, tt.name)) |c| {
            m.sheets.items[c.sheet].rows.items[c.row].cells.items[c.col] = try m.a().dupe(u8, text);
            try m.syncSheets();
            m.revision += 1;
            return;
        }
        try m.writeSlot(tile_id, track, text);
    }

    /// Sets a slot's content as `setTileTrackText` does, whatever drives it.
    fn writeSlot(m: *Model, tile_id: TileId, track: ObjectId, text: []const u8) Error!void {
        const tt = for (m.prototypeOf(tile_id).tracks) |tt| {
            if (tt.id == track) break tt;
        } else return error.NoSuchTrack;
        const f = m.tileFlow(tile_id, track) orelse blk: {
            const t = m.tile(tile_id);
            try t.flows.append(m.a(), .{ .id = m.newId(), .track = track });
            break :blk &t.flows.items[t.flows.items.len - 1];
        };
        try m.setItemsText(&f.items, tt.style, text);
    }

    // Process profiles ---------------------------------------------------

    pub fn processIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.processes.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    /// The profile panel `panel` is made with, if it has one.
    pub fn processOf(m: *const Model, panel: usize) ?*const process.Profile {
        const i = m.processIndex(m.panels.items[panel].fab.process) orelse return null;
        return &m.processes.items[i].profile;
    }

    fn dupeProfile(m: *Model, p: process.Profile) Allocator.Error!process.Profile {
        var c = p;
        c.name = try m.a().dupe(u8, p.name);
        return c;
    }

    /// Adds a process profile (a copy); returns its ID.
    pub fn addProcess(m: *Model, p: process.Profile) Error!ObjectId {
        if (!p.valid() or p.name.len == 0) return error.BadValue;
        const id = m.newId();
        try m.processes.append(m.a(), .{ .id = id, .profile = try m.dupeProfile(p) });
        m.revision += 1;
        return id;
    }

    /// Changes process profile `id` to `p` (every panel made with it
    /// follows).
    pub fn setProcess(m: *Model, id: ObjectId, p: process.Profile) Error!void {
        const i = m.processIndex(id) orelse return error.NoSuchObject;
        if (!p.valid() or p.name.len == 0) return error.BadValue;
        m.processes.items[i].profile = try m.dupeProfile(p);
        m.revision += 1;
    }

    /// Removes process profile `id`; refused while a panel is made with it
    /// or a plan's operation uses it.
    pub fn removeProcess(m: *Model, id: ObjectId) Error!void {
        const i = m.processIndex(id) orelse return error.NoSuchObject;
        for (m.panels.items) |p| if (p.fab.process == id) return error.ProcessInUse;
        for (m.plans.items) |pl| for (pl.operations) |op| if (op.process == id) return error.ProcessInUse;
        _ = m.processes.orderedRemove(i);
        m.revision += 1;
    }

    /// Makes panel `panel` with process profile `id` (none: no process).
    pub fn setPanelProcess(m: *Model, panel: usize, id: ObjectId) Error!void {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        if (id != .none and m.processIndex(id) == null) return error.NoSuchObject;
        m.panels.items[panel].fab.process = id;
        m.revision += 1;
    }

    /// Turns an older document's per-panel process settings into profiles:
    /// each panel with fabrication layers and no profile is given one, the
    /// built-in 0.4 mm FDM profile where its settings were the defaults (as
    /// they all were), else a profile of its own settings, one for each
    /// different set. Called on loading; does nothing to a newer document.
    pub fn upgradeProcesses(m: *Model) Error!void {
        for (m.panels.items) |*p| {
            if (p.fab.layers.len == 0 or p.fab.process != .none) continue;
            const f = p.fab;
            const defaults = f.old_layer_height == 0.2 and f.old_min_stroke == 0.4 and f.old_min_gap == 0.4 and f.old_min_cap == 1.0;
            var want: process.Profile = process.builtin("Generic FDM, 0.4 mm nozzle").?;
            var name_buf: [96]u8 = undefined;
            if (!defaults) {
                want.name = std.fmt.bufPrint(&name_buf, "FDM, {d} mm layers (from an older file)", .{f.old_layer_height}) catch "FDM (from an older file)";
                want.params.fdm.layer_height = f.old_layer_height;
                want.params.fdm.first_layer = f.old_layer_height;
                want.stroke = .{ .pass = f.old_min_stroke, .fail = @min(f.old_min_stroke, want.limits().stroke.fail) };
                want.gap = .{ .pass = f.old_min_gap, .fail = @min(f.old_min_gap, want.limits().gap.fail) };
                want.cap = .{ .pass = f.old_min_cap, .fail = @min(f.old_min_cap, want.limits().cap.fail) };
            }
            // One profile for each different set.
            const found = for (m.processes.items) |q| {
                if (std.mem.eql(u8, q.profile.name, want.name) and std.meta.eql(q.profile.params, want.params)) break q.id;
            } else null;
            p.fab.process = found orelse blk: {
                const id = m.newId();
                try m.processes.append(m.a(), .{ .id = id, .profile = try m.dupeProfile(want) });
                break :blk id;
            };
        }
    }

    // Materials and manufacturing plans ---------------------------------

    pub fn profileById(m: *const Model, id: ObjectId) ?*const process.Profile {
        const i = m.processIndex(id) orelse return null;
        return &m.processes.items[i].profile;
    }

    pub fn materialIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.materials.items, 0..) |x, i| if (x.id == id) return i;
        return null;
    }

    pub fn planIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.plans.items, 0..) |x, i| if (x.id == id) return i;
        return null;
    }

    /// The most curves may stray when output is made of them: the active
    /// plan's tolerance, else the library default (0.05 mm).
    pub fn exportTolerance(m: *const Model) f64 {
        return if (m.activePlan()) |p| p.tolerance else @import("threemf.zig").default_tolerance;
    }

    /// The plan exported, if any.
    pub fn activePlan(m: *const Model) ?*const manufacture.Plan {
        const i = m.planIndex(m.active_plan) orelse return null;
        return &m.plans.items[i];
    }

    fn dupeFinish(m: *Model, f: manufacture.Finish) Allocator.Error!manufacture.Finish {
        return .{ .name = try m.a().dupe(u8, f.name), .color = f.color };
    }

    fn dupeMaterial(m: *Model, x: manufacture.Material) Allocator.Error!manufacture.Material {
        var c = x;
        c.name = try m.a().dupe(u8, x.name);
        const fs = try m.a().alloc(manufacture.Finish, x.finishes.len);
        for (x.finishes, fs) |f, *d| d.* = try m.dupeFinish(f);
        c.finishes = fs;
        if (x.core) |f| c.core = try m.dupeFinish(f);
        c.thicknesses = try m.a().dupe(f64, x.thicknesses);
        return c;
    }

    fn dupePlan(m: *Model, x: manufacture.Plan) Allocator.Error!manufacture.Plan {
        var c = x;
        c.name = try m.a().dupe(u8, x.name);
        c.parts = try m.a().dupe(manufacture.Part, x.parts);
        const ops = try m.a().alloc(manufacture.Operation, x.operations.len);
        for (x.operations, ops) |op, *d| {
            d.* = op;
            d.name = try m.a().dupe(u8, op.name);
            const ts = try m.a().alloc(manufacture.Target, op.targets.len);
            for (op.targets, ts) |t, *dt| {
                dt.* = t;
                dt.layer = try m.a().dupe(u8, t.layer);
                if (t.colour) |f| dt.colour = try m.dupeFinish(f);
            }
            d.targets = ts;
        }
        c.operations = ops;
        return c;
    }

    /// Adds a material (a copy); returns its ID.
    pub fn addMaterial(m: *Model, x: manufacture.Material) Error!ObjectId {
        if (!x.valid()) return error.BadValue;
        const id = m.newId();
        try m.materials.append(m.a(), .{ .id = id, .material = try m.dupeMaterial(x) });
        m.revision += 1;
        return id;
    }

    pub fn setMaterial(m: *Model, id: ObjectId, x: manufacture.Material) Error!void {
        const i = m.materialIndex(id) orelse return error.NoSuchObject;
        if (!x.valid()) return error.BadValue;
        m.materials.items[i].material = try m.dupeMaterial(x);
        m.revision += 1;
    }

    /// Removes material `id`; refused while a plan's part is made of it.
    pub fn removeMaterial(m: *Model, id: ObjectId) Error!void {
        const i = m.materialIndex(id) orelse return error.NoSuchObject;
        for (m.plans.items) |pl| for (pl.parts) |pt| if (pt.material == id) return error.MaterialInUse;
        _ = m.materials.orderedRemove(i);
        m.revision += 1;
    }

    /// Adds a plan (a copy), active when it is the first; returns its ID.
    /// What it names need not exist: `manufacture.warnings` says so.
    pub fn addPlan(m: *Model, x: manufacture.Plan) Error!ObjectId {
        if (x.name.len == 0 or !(x.tolerance > 0 and x.tolerance <= 1)) return error.BadValue;
        for (x.operations) |op| if (op.passes == 0) return error.BadValue;
        const id = m.newId();
        var c = try m.dupePlan(x);
        c.id = id;
        try m.plans.append(m.a(), c);
        if (m.active_plan == .none) m.active_plan = id;
        m.revision += 1;
        return id;
    }

    /// Replaces plan `id` with `x` (its parts, operations, name).
    pub fn setPlan(m: *Model, id: ObjectId, x: manufacture.Plan) Error!void {
        const i = m.planIndex(id) orelse return error.NoSuchObject;
        if (x.name.len == 0 or !(x.tolerance > 0 and x.tolerance <= 1)) return error.BadValue;
        for (x.operations) |op| if (op.passes == 0) return error.BadValue;
        var c = try m.dupePlan(x);
        c.id = id;
        m.plans.items[i] = c;
        m.revision += 1;
    }

    /// Removes plan `id`; the next one, if any, becomes active if it was.
    pub fn removePlan(m: *Model, id: ObjectId) Error!void {
        const i = m.planIndex(id) orelse return error.NoSuchObject;
        _ = m.plans.orderedRemove(i);
        if (m.active_plan == id) m.active_plan = if (m.plans.items.len > 0) m.plans.items[0].id else .none;
        m.revision += 1;
    }

    pub fn setActivePlan(m: *Model, id: ObjectId) Error!void {
        if (id != .none and m.planIndex(id) == null) return error.NoSuchObject;
        m.active_plan = id;
        m.revision += 1;
    }

    /// The colour the active plan gives stackup layer `layer` of panel
    /// `panel`, if it gives one: the last operation's that does.
    pub fn planColour(m: *const Model, panel: usize, layer: []const u8) ?manufacture.Finish {
        const pl = m.activePlan() orelse return null;
        const pid = m.panels.items[panel].id;
        var found: ?manufacture.Finish = null;
        for (pl.operations) |op| for (op.targets) |t| {
            if (t.panel == pid and std.mem.eql(u8, t.layer, layer)) if (t.colour) |c| {
                found = c;
            };
        };
        return found;
    }

    /// An older document's fabrication, as a plan: its panels with
    /// fabrication layers and a process profile become one plan's parts,
    /// of PLA (with the layers' colours among its finishes); for each
    /// profile, one operation making every layer of its panels, each in
    /// the colour the layer named. Called on loading; does nothing to a
    /// document with plans.
    pub fn upgradePlans(m: *Model) Error!void {
        if (m.plans.items.len > 0) return;
        var any = false;
        for (m.panels.items) |p| {
            if (p.fab.layers.len > 0 and p.fab.process != .none) any = true;
        }
        if (!any) return;
        const al = m.a();
        // The material: PLA, with every colour the layers named.
        var mat = manufacture.libraryMaterial("PLA").?;
        var finishes: std.ArrayList(manufacture.Finish) = .empty;
        try finishes.appendSlice(al, mat.finishes);
        for (m.panels.items) |p| for (p.fab.layers) |l| {
            const c: ?manufacture.Finish = switch (l.op) {
                .add, .inlay => |col| col,
                .subtract => null,
            };
            const col = c orelse continue;
            for (finishes.items) |f| {
                if (std.mem.eql(u8, f.name, col.name)) break;
            } else try finishes.append(al, col);
        };
        mat.finishes = finishes.items;
        const mid = m.newId();
        try m.materials.append(al, .{ .id = mid, .material = try m.dupeMaterial(mat) });
        var parts: std.ArrayList(manufacture.Part) = .empty;
        var ops: std.ArrayList(manufacture.Operation) = .empty;
        for (m.panels.items) |p| {
            if (p.fab.layers.len == 0 or p.fab.process == .none) continue;
            if (p.id == .none) continue;
            try parts.append(al, .{ .panel = p.id, .material = mid });
            const op = for (ops.items) |*o| {
                if (o.process == p.fab.process) break o;
            } else blk: {
                const prof = m.profileById(p.fab.process).?;
                try ops.append(al, .{ .name = try std.fmt.allocPrint(al, "Print ({s})", .{prof.name}), .process = p.fab.process });
                break :blk &ops.items[ops.items.len - 1];
            };
            var ts: std.ArrayList(manufacture.Target) = .empty;
            try ts.appendSlice(al, op.targets);
            for (p.fab.layers) |l| try ts.append(al, .{ .panel = p.id, .layer = l.name, .colour = switch (l.op) {
                .add, .inlay => |col| col,
                .subtract => null,
            } });
            op.targets = ts.items;
        }
        const pid = m.newId();
        try m.plans.append(al, try m.dupePlan(.{ .id = pid, .name = "Plan1", .parts = parts.items, .operations = ops.items }));
        m.plans.items[m.plans.items.len - 1].id = pid;
        m.active_plan = pid;
    }

    // Legend sheets ------------------------------------------------------

    pub fn sheetIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.sheets.items, 0..) |sh, i| if (sh.id == id) return i;
        return null;
    }

    fn sheetById(m: *Model, id: ObjectId) Error!*LegendSheet {
        return &m.sheets.items[m.sheetIndex(id) orelse return error.NoSuchObject];
    }

    /// Whether `id` names a grid, a track or a panel: something a sheet's
    /// scope may be.
    fn isScope(m: *const Model, id: ObjectId) bool {
        if (id == .none) return false;
        for (m.panels.items) |p| {
            if (p.id == id) return true;
            for (p.grids.items) |g| if (g.id == id) return true;
            for (p.regions.items) |r| if (r.id == id) return true;
        }
        return false;
    }

    /// The keys in scope `scope` (a grid's, in rows, then columns; a
    /// track's, in its flow's order; a panel's grids' and tracks'), into
    /// `out`.
    pub fn scopeTiles(m: *const Model, al: Allocator, scope: ObjectId, out: *std.ArrayList(TileId)) Allocator.Error!void {
        for (0..m.parentCount()) |k| {
            const pi = m.parentAt(k);
            const whole = m.parentId(pi) == scope;
            for (m.gridsIn(pi)) |g| if (whole or g.id == scope) try gridTiles(m, al, g, out);
            for (m.regionsIn(pi), 0..) |r, ri| if (whole or r.id == scope) {
                for (m.ownItems(pi, ri)) |item| if (item.tileOf()) |t| if (!m.tileConst(t).removed) try out.append(al, t);
            };
        }
    }

    fn gridTiles(m: *const Model, al: Allocator, g: Grid, out: *std.ArrayList(TileId)) Allocator.Error!void {
        const start = out.items.len;
        for (g.instances.items) |inst| if (m.tileIndex(inst.tile) != null and !m.tileConst(inst.tile).removed) try out.append(al, inst.tile);
        // In rows, then columns.
        const Ctx = struct {
            g: Grid,
            fn at(c: @This(), t: TileId) [2]u32 {
                for (c.g.instances.items) |inst| if (inst.tile == t) return .{ inst.row, inst.col };
                return .{ 0, 0 };
            }
            fn lt(c: @This(), a_: TileId, b_: TileId) bool {
                const x = c.at(a_);
                const y = c.at(b_);
                return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
            }
        };
        std.mem.sort(TileId, out.items[start..], Ctx{ .g = g }, Ctx.lt);
    }

    /// Tile `t` and the tiles at its grid place in grids linked with its
    /// grid (sharing a shape: a key and the legend printed beside it on
    /// the plate), into `out`. Holes are left out: they show no text.
    pub fn companions(m: *const Model, al: Allocator, t: TileId, out: *std.ArrayList(TileId)) Allocator.Error!void {
        try out.append(al, t);
        const at = m.gridInstanceOf(t) orelse return;
        const g = m.gridsIn(at.parent)[at.grid];
        const inst = g.instances.items[at.index];
        const root = if (g.link != .none) g.link else g.id;
        for (0..m.parentCount()) |pk| for (m.gridsIn(m.parentAt(pk))) |h| {
            if (h.id == g.id) continue;
            const hroot = if (h.link != .none) h.link else h.id;
            if (hroot != root) continue;
            for (h.instances.items) |hi| if (hi.col == inst.col and hi.row == inst.row and m.tileIndex(hi.tile) != null and !m.tileConst(hi.tile).removed) {
                const hole = for (h.stamps.items) |st| {
                    if (st.id == hi.stamp) break st.role == .hole;
                } else false;
                if (!hole) try out.append(al, hi.tile);
            };
        };
    }

    /// The key named `name` among those in scope `scope`.
    pub fn keyInScope(m: *const Model, al: Allocator, scope: ObjectId, name: []const u8) Allocator.Error!?TileId {
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        try m.scopeTiles(al, scope, &keys);
        for (keys.items) |t| if (std.mem.eql(u8, m.tileConst(t).designator, name)) return t;
        return null;
    }

    /// The cell that drives slot `slot` of tile `t`, if a sheet's does: the
    /// first sheet's whose row's key is `t`, or has `t` beside it, with a
    /// column of that name.
    pub fn sheetCellOf(m: *const Model, t: TileId, slot: []const u8) ?struct { sheet: usize, row: usize, col: usize } {
        const al = m.arena.child_allocator;
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        var near: std.ArrayList(TileId) = .empty;
        defer near.deinit(al);
        for (m.sheets.items, 0..) |sh, si| {
            if (sh.texts) continue;
            const col = for (sh.columns.items, 0..) |c, k| {
                if (std.mem.eql(u8, c, slot)) break k;
            } else continue;
            keys.clearRetainingCapacity();
            m.scopeTiles(al, sh.scope, &keys) catch return null;
            for (sh.rows.items, 0..) |row, ri| {
                const key = for (keys.items) |k| {
                    if (std.mem.eql(u8, m.tileConst(k).designator, row.key)) break k;
                } else continue;
                near.clearRetainingCapacity();
                m.companions(al, key, &near) catch return null;
                if (std.mem.indexOfScalar(TileId, near.items, t) != null) return .{ .sheet = si, .row = ri, .col = col };
            }
        }
        return null;
    }

    fn itemsEql(x_items: []const Item, y_items: []const Item) bool {
        if (x_items.len != y_items.len) return false;
        for (x_items, y_items) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// The track (anywhere) whose ID is `id`.
    fn regionWithId(m: *Model, id: ObjectId) ?*TileRegion {
        for (0..m.parentCount()) |k| for (m.regionsIn(m.parentAt(k))) |*r| if (r.id == id) return r;
        return null;
    }

    /// Shows every sketch's captions in its sketch panels: in each, a
    /// track for each caption (made the first time), held at its leader's
    /// end as the sketch stands, its text the caption's base track's.
    /// Run after every action, with `syncSheets`.
    pub fn syncCaptions(m: *Model) Error!void {
        for (m.panels.items, 0..) |*p, pi| {
            if (p.sketch == .none) continue;
            const si = m.sketchIndex(p.sketch) orelse continue;
            const item = &m.sketches.items[si];
            if (item.captions.items.len == 0) continue;
            const sk = item.used();
            const parent: Parent = .{ .panel = pi };
            for (item.captions.items) |sc| {
                const e = sk.point(sc.end) catch continue;
                const at: geom.Point = .{ .x = p.sketch_at.x - p.origin.x + e.x, .y = p.sketch_at.y - p.origin.y + e.y };
                const origin: geom.Point = .{ .x = if (sc.right) at.x else at.x - sc.length, .y = at.y + sc.pitch / 2 };
                const ri = for (m.regionsIn(parent), 0..) |r, k| {
                    if (r.caption == sc.id) break k;
                } else blk: {
                    if (m.styleIndex(sc.style) == null) continue;
                    var name_buf: [32]u8 = undefined;
                    const name = m.freshName(&name_buf, m.containerOf(parent), "Caption");
                    const k = try m.addTracks(parent, .{ .name = name, .origin = origin, .kind = .track, .style = sc.style, .count = 1, .length = sc.length / sc.pitch, .pitch = sc.pitch });
                    const r = &m.regionsIn(parent)[k];
                    r.caption = sc.id;
                    r.alignment = if (sc.right) .start else .end;
                    break :blk k;
                };
                const r = &m.regionsIn(parent)[ri];
                if (r.origin.x != origin.x or r.origin.y != origin.y) r.origin = origin;
                // Its text: the base track's (text and breaks; no tiles),
                // unless edited here, which makes it its own; emptied, it
                // follows the base again.
                const fi = m.flowIndex(m.regionsIn(parent)[ri].flow) orelse continue;
                const f = &m.flows.items[fi];
                if (r.caption_own) {
                    if (f.items.items.len > 0) continue;
                    r.caption_own = false;
                    r.caption_copy = &.{};
                }
                if (!itemsEql(f.items.items, r.caption_copy)) {
                    r.caption_own = true;
                    m.revision += 1;
                    continue;
                }
                const base = m.regionWithId(sc.base) orelse continue;
                const bfi = m.flowIndex(base.flow) orelse continue;
                if (bfi == fi) continue;
                const bf = &m.flows.items[bfi];
                f.style = bf.style;
                f.paragraph_default = bf.paragraph_default;
                f.leading = bf.leading;
                f.paragraph = bf.paragraph;
                var text: std.ArrayList(Item) = .empty;
                for (bf.items.items) |it| if (it.what != .tile) try text.append(m.a(), it);
                if (itemsEql(f.items.items, text.items)) continue;
                f.items.clearRetainingCapacity();
                try f.items.appendSlice(m.a(), text.items);
                m.regionsIn(parent)[ri].caption_copy = text.items;
                m.revision += 1;
            }
        }
    }

    /// The name a text sheet finds track `r` by: its caption's, else its own.
    pub fn textHolderName(m: *const Model, r: *const TileRegion) []const u8 {
        if (r.caption != .none) for (m.sketches.items) |it| for (it.captions.items) |sc| {
            if (sc.id == r.caption) return sc.name;
        };
        return r.name;
    }

    /// Whether track `r` is a use's copy of a caption (which follows its
    /// base, not a sheet).
    fn isCaptionCopy(m: *const Model, r: *const TileRegion) bool {
        if (r.caption == .none) return false;
        for (m.sketches.items) |it| for (it.captions.items) |sc| {
            if (sc.id == r.caption) return sc.base != r.id;
        };
        return false;
    }

    /// Writes each text sheet's cells into its text holders: for each
    /// row, the tracks of that name (a caption's base by its caption's
    /// name) get the cell of the column shown, or the default when that
    /// is empty. A holder edited since (its text not what was last
    /// written) puts its text into that cell first: the sheet and the
    /// text holders are one text, edited in either.
    pub fn syncTextSheets(m: *Model) Error!void {
        const al = m.arena.child_allocator;
        for (m.sheets.items) |*sh| {
            if (!sh.texts) continue;
            for (sh.rows.items) |*row| {
                while (row.cells.items.len < sh.columns.items.len) try row.cells.append(m.a(), "");
                for (0..m.parentCount()) |k| {
                    const pi = m.parentAt(k);
                    for (m.regionsIn(pi)) |*r| {
                        if (!std.mem.eql(u8, m.textHolderName(r), row.key) or m.isCaptionCopy(r)) continue;
                        const fi = m.flowIndex(r.flow) orelse continue;
                        const f = &m.flows.items[fi];
                        const now = try itemsText(al, f.items.items);
                        defer al.free(now);
                        const col = @min(sh.shown, sh.columns.items.len -| 1);
                        if (r.sheet_copy) |last| if (!std.mem.eql(u8, now, last)) {
                            // Edited in the track: into the cell shown.
                            row.cells.items[col] = try m.a().dupe(u8, now);
                        };
                        const cell = row.cells.items[col];
                        const text = if (cell.len == 0) row.cells.items[0] else cell;
                        if (!std.mem.eql(u8, now, text)) try m.setItemsText(&f.items, if (r.style) |st| st else f.style, text);
                        if (r.sheet_copy == null or !std.mem.eql(u8, r.sheet_copy.?, text)) r.sheet_copy = try m.a().dupe(u8, text);
                    }
                }
            }
        }
    }

    /// A text sheet named `name`: a row for each caption (by its name),
    /// its default text what the caption's base shows now, and a column
    /// for each of `languages` after the default. Returns its ID.
    pub fn makeTextSheet(m: *Model, name: []const u8, languages: []const []const u8) Error!ObjectId {
        const al = m.arena.child_allocator;
        var sh: LegendSheet = .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .scope = .none, .texts = true };
        try sh.columns.append(m.a(), "Default");
        for (languages) |l| try sh.columns.append(m.a(), try m.a().dupe(u8, l));
        for (m.sketches.items) |it| for (it.captions.items) |sc| {
            var row: SheetRow = .{ .key = try m.a().dupe(u8, sc.name) };
            const base = m.regionWithId(sc.base);
            const text = if (base) |b| if (m.flowIndex(b.flow)) |fi| try itemsText(al, m.flows.items[fi].items.items) else try al.alloc(u8, 0) else try al.alloc(u8, 0);
            defer al.free(text);
            try row.cells.append(m.a(), try m.a().dupe(u8, text));
            for (languages) |_| try row.cells.append(m.a(), "");
            try sh.rows.append(m.a(), row);
        };
        try m.sheets.append(m.a(), sh);
        m.revision += 1;
        try m.syncSheets();
        return sh.id;
    }

    /// Which of text sheet `id`'s columns its text holders show (0: the
    /// default).
    pub fn setSheetShown(m: *Model, id: ObjectId, col: usize) Error!void {
        const sh = try m.sheetById(id);
        if (!sh.texts or col >= sh.columns.items.len) return error.NoSuchItem;
        sh.shown = col;
        m.revision += 1;
        try m.syncSheets();
    }

    /// Writes every slot a sheet drives from its cell: for each row whose
    /// key is in its sheet's scope, each column's slot on the key and on
    /// the tiles beside it that have one of that name. A slot two sheets
    /// drive takes the first's. Slots no column names keep their own
    /// content. Run after every action (as constraints are solved), so
    /// the keys always show their sheets.
    pub fn syncSheets(m: *Model) Error!void {
        // Text sheets' cells in their text holders (a caption's base
        // among them), then a sketch's captions in its uses: content
        // driven from elsewhere, as a sheet's cells drive slots.
        try m.syncTextSheets();
        try m.syncCaptions();
        if (m.sheets.items.len == 0) return;
        const al = m.arena.child_allocator;
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        var near: std.ArrayList(TileId) = .empty;
        defer near.deinit(al);
        var done: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
        defer done.deinit(al);
        for (m.sheets.items) |sh| {
            if (sh.texts) continue;
            keys.clearRetainingCapacity();
            try m.scopeTiles(al, sh.scope, &keys);
            for (sh.rows.items) |row| {
                const key = for (keys.items) |k| {
                    if (std.mem.eql(u8, m.tileConst(k).designator, row.key)) break k;
                } else continue;
                near.clearRetainingCapacity();
                try m.companions(al, key, &near);
                for (sh.columns.items, 0..) |col, ci| {
                    const text = if (ci < row.cells.items.len) row.cells.items[ci] else "";
                    for (near.items) |t| {
                        const track = m.tileTrackNamed(t, col) orelse continue;
                        const gop = try done.getOrPut(al, .{ @backingInt(t), @backingInt(track) });
                        if (gop.found_existing) continue;
                        const now = try m.tileTrackText(al, t, track);
                        defer al.free(now);
                        if (!std.mem.eql(u8, now, text)) try m.writeSlot(t, track, text);
                    }
                }
            }
        }
    }

    /// A new legend sheet named `name` over scope `scope` (a grid's, a
    /// track's or a panel's ID), with columns for the slots `columns` and
    /// no rows. Returns its ID.
    pub fn addSheet(m: *Model, name: []const u8, scope: ObjectId, columns: []const []const u8) Error!ObjectId {
        if (!m.isScope(scope)) return error.NoSuchObject;
        var sh: LegendSheet = .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .scope = scope };
        for (columns) |c| try sh.columns.append(m.a(), try m.a().dupe(u8, c));
        try m.sheets.append(m.a(), sh);
        m.revision += 1;
        return sh.id;
    }

    /// A legend sheet for the keys in scope `scope`, holding what their
    /// slots hold now (nothing changes on them): a row for each key, by
    /// its name, and a column for each slot name its keys and the tiles
    /// beside them have, in their prototypes' order. Named `name`.
    /// Returns its ID.
    pub fn makeSheet(m: *Model, name: []const u8, scope: ObjectId) Error!ObjectId {
        if (!m.isScope(scope)) return error.NoSuchObject;
        const al = m.arena.child_allocator;
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        try m.scopeTiles(al, scope, &keys);
        var near: std.ArrayList(TileId) = .empty;
        defer near.deinit(al);
        var cols: std.ArrayList([]const u8) = .empty;
        defer cols.deinit(al);
        for (keys.items) |k| {
            near.clearRetainingCapacity();
            try m.companions(al, k, &near);
            for (near.items) |t| for (m.prototypeOf(t).tracks) |tt| {
                for (cols.items) |c| {
                    if (std.mem.eql(u8, c, tt.name)) break;
                } else try cols.append(al, tt.name);
            };
        }
        const id = try m.addSheet(name, scope, cols.items);
        const sh = &m.sheets.items[m.sheetIndex(id).?];
        for (keys.items) |k| {
            var row: SheetRow = .{ .key = try m.a().dupe(u8, m.tileConst(k).designator) };
            near.clearRetainingCapacity();
            try m.companions(al, k, &near);
            for (sh.columns.items) |c| {
                var text: []const u8 = "";
                for (near.items) |t| if (m.tileTrackNamed(t, c)) |track| {
                    const got = try m.tileTrackText(m.a(), t, track);
                    if (got.len > 0) {
                        text = got;
                        break;
                    }
                };
                try row.cells.append(m.a(), text);
            }
            try sh.rows.append(m.a(), row);
        }
        try m.syncSheets();
        return id;
    }

    /// Sets the cell of sheet `id` at row `row`, column `col`: column 0
    /// is the key's name (renaming the key too, when there is one), the
    /// others the columns' slots, which follow.
    pub fn setSheetCell(m: *Model, id: ObjectId, row: usize, col: usize, text: []const u8) Error!void {
        const sh = try m.sheetById(id);
        if (row >= sh.rows.items.len or col > sh.columns.items.len) return error.NoSuchItem;
        const r = &sh.rows.items[row];
        if (col == 0) {
            if (std.mem.eql(u8, r.key, text)) return;
            const al = m.arena.child_allocator;
            if (try m.keyInScope(al, sh.scope, r.key)) |t| try m.renameTile(t, text);
            m.sheets.items[m.sheetIndex(id).?].rows.items[row].key = try m.a().dupe(u8, text);
        } else {
            while (r.cells.items.len < sh.columns.items.len) try r.cells.append(m.a(), "");
            r.cells.items[col - 1] = try m.a().dupe(u8, text);
        }
        try m.syncSheets();
        m.revision += 1;
    }

    /// Adds a row for key `key` to sheet `id` at `at` (null: last), its
    /// cells empty.
    pub fn addSheetRow(m: *Model, id: ObjectId, at: ?usize, key: []const u8) Error!void {
        const sh = try m.sheetById(id);
        var row: SheetRow = .{ .key = try m.a().dupe(u8, key) };
        for (sh.columns.items) |_| try row.cells.append(m.a(), "");
        try sh.rows.insert(m.a(), @min(at orelse sh.rows.items.len, sh.rows.items.len), row);
        try m.syncSheets();
        m.revision += 1;
    }

    /// Removes row `row` of sheet `id`: its key's slots keep what they
    /// hold, no longer driven.
    pub fn removeSheetRow(m: *Model, id: ObjectId, row: usize) Error!void {
        const sh = try m.sheetById(id);
        if (row >= sh.rows.items.len) return error.NoSuchItem;
        _ = sh.rows.orderedRemove(row);
        try m.syncSheets();
        m.revision += 1;
    }

    /// Adds a column for slot `slot` to sheet `id` at `at` (null: last),
    /// each row's cell holding what its key's slot holds now.
    pub fn addSheetColumn(m: *Model, id: ObjectId, at: ?usize, slot: []const u8) Error!void {
        const si = m.sheetIndex(id) orelse return error.NoSuchObject;
        const al = m.arena.child_allocator;
        const sh = &m.sheets.items[si];
        const k = @min(at orelse sh.columns.items.len, sh.columns.items.len);
        try sh.columns.insert(m.a(), k, try m.a().dupe(u8, slot));
        var near: std.ArrayList(TileId) = .empty;
        defer near.deinit(al);
        for (sh.rows.items) |*row| {
            while (row.cells.items.len < k) try row.cells.append(m.a(), "");
            var text: []const u8 = "";
            if (try m.keyInScope(al, sh.scope, row.key)) |key| {
                near.clearRetainingCapacity();
                try m.companions(al, key, &near);
                for (near.items) |t| if (m.tileTrackNamed(t, slot)) |track| {
                    const got = try m.tileTrackText(m.a(), t, track);
                    if (got.len > 0) {
                        text = got;
                        break;
                    }
                };
            }
            try row.cells.insert(m.a(), k, text);
        }
        try m.syncSheets();
        m.revision += 1;
    }

    /// Removes column `col` (from 0, after the name column) of sheet `id`:
    /// its slots keep what they hold, no longer driven.
    pub fn removeSheetColumn(m: *Model, id: ObjectId, col: usize) Error!void {
        const sh = try m.sheetById(id);
        if (col >= sh.columns.items.len) return error.NoSuchItem;
        _ = sh.columns.orderedRemove(col);
        for (sh.rows.items) |*row| if (col < row.cells.items.len) {
            _ = row.cells.orderedRemove(col);
        };
        try m.syncSheets();
        m.revision += 1;
    }

    pub fn renameSheet(m: *Model, id: ObjectId, name: []const u8) Error!void {
        (try m.sheetById(id)).name = try m.a().dupe(u8, name);
        m.revision += 1;
    }

    /// Removes sheet `id`: the slots it drove keep what they hold.
    pub fn removeSheet(m: *Model, id: ObjectId) Error!void {
        _ = m.sheets.orderedRemove(m.sheetIndex(id) orelse return error.NoSuchObject);
        try m.syncSheets();
        m.revision += 1;
    }

    /// Records that sheet `id` was filled from `src`.
    pub fn addSheetSource(m: *Model, id: ObjectId, src: FlowSource) Error!void {
        const sh = try m.sheetById(id);
        try sh.sources.append(m.a(), .{ .uri = try m.a().dupe(u8, src.uri), .sha256 = try m.a().dupe(u8, src.sha256), .imported = src.imported });
        m.revision += 1;
    }

    /// Renames tile `id` (its designator), which must stay unique.
    pub fn renameTile(m: *Model, id: TileId, designator: []const u8) Error!void {
        if (m.tileIndex(id) == null) return error.NoSuchTile;
        if (designator.len == 0) return error.BadValue;
        if (m.findTile(designator)) |other| if (other != id) return error.DuplicateDesignator;
        m.tile(id).designator = try m.a().dupe(u8, designator);
        m.revision += 1;
    }

    /// What is wrong with sheet `id`, cell by cell: rows whose name is no
    /// key in its scope, and columns no key there (or beside one) has a
    /// slot for. Into `rows` and `cols` (indices).
    pub fn sheetProblems(m: *const Model, al: Allocator, id: ObjectId, rows: *std.ArrayList(usize), cols: *std.ArrayList(usize)) Allocator.Error!void {
        const si = m.sheetIndex(id) orelse return;
        const sh = m.sheets.items[si];
        if (sh.texts) {
            // A text sheet: rows naming no text holder; its columns are
            // languages, none unused.
            for (sh.rows.items, 0..) |row, ri| {
                var found = false;
                for (0..m.parentCount()) |k| for (m.regionsIn(m.parentAt(k))) |*r| {
                    if (std.mem.eql(u8, m.textHolderName(r), row.key)) found = true;
                };
                if (!found) try rows.append(al, ri);
            }
            return;
        }
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        try m.scopeTiles(al, sh.scope, &keys);
        var near: std.ArrayList(TileId) = .empty;
        defer near.deinit(al);
        var used = try al.alloc(bool, sh.columns.items.len);
        defer al.free(used);
        @memset(used, false);
        for (sh.rows.items, 0..) |row, ri| {
            const key = for (keys.items) |k| {
                if (std.mem.eql(u8, m.tileConst(k).designator, row.key)) break k;
            } else {
                try rows.append(al, ri);
                continue;
            };
            near.clearRetainingCapacity();
            try m.companions(al, key, &near);
            for (sh.columns.items, 0..) |c, ci| for (near.items) |t| if (m.tileTrackNamed(t, c) != null) {
                used[ci] = true;
            };
        }
        for (used, 0..) |u, ci| if (!u) try cols.append(al, ci);
    }

    fn dupeParams(m: *Model, params: []const TileParam) Allocator.Error![]const TileParam {
        const out = try m.a().alloc(TileParam, params.len);
        for (params, out) |p, *o| o.* = .{ .name = try m.a().dupe(u8, p.name), .value = p.value };
        return out;
    }

    /// Adds a ready-made shape sketch to the document's sketches (no view
    /// of it is placed), unless there is one made as `kind` already;
    /// returns its index. It is fully constrained,
    /// centred on its origin, and sized by its parameters: `w` and `h` (a
    /// circle's diameter is `w`), and a rounded rectangle's `r`.
    pub fn addShapeSketch(m: *Model, kind: ShapeSketch) Error!usize {
        // One of each is enough: the one there is, if any.
        for (m.sketches.items, 0..) |item, i| if (item.shape == kind) return i;
        const name: []const u8 = switch (kind) {
            .circle => "Circle",
            .rectangle => "Rectangle",
            .rounded_rectangle => "RoundedRectangle",
            .slot => "Slot",
        };
        var sk = try sketch_.Sketch.init(m.a());
        try buildShape(m.a(), m.arena.child_allocator, &sk, kind);
        const id = m.newId();
        try m.sketches.append(m.a(), .{ .id = id, .name = name, .sketch = sk, .shape = kind });
        m.revision += 1;
        return m.sketches.items.len - 1;
    }

    /// Sets how panel `panel` is made (see `Fab`); a copy is kept.
    pub fn setPanelFab(m: *Model, panel: usize, fab: Fab) Error!void {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        if (!(fab.thickness > 0)) return error.BadSize;
        if (fab.process != .none and m.processIndex(fab.process) == null) return error.NoSuchObject;
        const layers = try m.a().alloc(FabLayer, fab.layers.len);
        for (fab.layers, layers) |l, *o| {
            if (l.depth) |d| if (!(d > 0)) return error.BadSize;
            o.* = l;
            o.name = try m.a().dupe(u8, l.name);
            o.source = switch (l.source) {
                .text => |t| .{ .text = try m.a().dupe(u8, t) },
                else => l.source,
            };
            o.op = switch (l.op) {
                .add => |c| .{ .add = .{ .name = try m.a().dupe(u8, c.name), .color = c.color } },
                .inlay => |c| .{ .inlay = .{ .name = try m.a().dupe(u8, c.name), .color = c.color } },
                .subtract => .subtract,
            };
        }
        m.panels.items[panel].fab = .{ .thickness = fab.thickness, .layers = layers, .process = fab.process };
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
    /// exactly one outermost outline. A `drawn` sketch (one with a drawing)
    /// gives only its outermost: its holes are its cutout fills, so a ring
    /// it inks is not cut.
    fn sketchEdge(m: *Model, sk: *const sketch_.Sketch, islands: bool, drawn: bool) Error!?SketchEdge {
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
            if (i != oi and (drawn or (dp != 0 and !(islands or dp == 1)))) continue;
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
        const edge = (try m.sketchEdge(m.sketches.items[si].used(), p.islands, m.sketchFigure(p.sketch) != null)) orelse return;
        const origin: geom.Point = .{ .x = p.sketch_at.x + edge.min.x, .y = p.sketch_at.y + edge.min.y };
        const d: geom.Point = .{ .x = p.origin.x - origin.x, .y = p.origin.y - origin.y };
        for (p.regions.items) |*rg| rg.origin = .{ .x = rg.origin.x + d.x, .y = rg.origin.y + d.y };
        for (p.art.items) |*pa| pa.at = .{ .x = pa.at.x + d.x, .y = pa.at.y + d.y };
        p.origin = origin;
        p.w = edge.w;
        p.h = edge.h;
        p.edge = edge.art;
        try m.syncSketchPanelInk(panel);
    }

    /// Makes a sketch panel's art from its sketch's drawings again: each
    /// drawing's ink as one piece of line art, set where the sketch is,
    /// that the panel's tracks flow round (at its clearance); each fill in
    /// a cutout style a cutout through the panel. The art made before is
    /// dropped; a clearance or wrap changed on it is kept.
    fn syncSketchPanelInk(m: *Model, panel: usize) Error!void {
        const p = &m.panels.items[panel];
        if (p.sketch == .none) return;
        const si = m.sketchIndex(p.sketch) orelse return;
        const sk = m.sketches.items[si].used();
        const al = m.a();
        var wrap: Wrap = .ink;
        var clearance: f64 = 1;
        var i = p.art.items.len;
        var at_index: usize = p.art.items.len;
        while (i > 0) {
            i -= 1;
            if (!p.art.items[i].sketch_ink) continue;
            const old = p.art.orderedRemove(i);
            if (!old.cutout) {
                wrap = old.wrap;
                clearance = old.clearance;
            }
            at_index = i;
        }
        const at: geom.Point = .{ .x = p.sketch_at.x - p.origin.x, .y = p.sketch_at.y - p.origin.y };
        var made: std.ArrayList(PanelArt) = .empty;
        const chosen = m.panelDrawing(panel);
        for (m.figures.items, 0..) |f, k_fig| {
            if (f.sketch != p.sketch or k_fig != chosen) continue;
            // Cutout fills cut the panel; the rest are its drawing's ink.
            var kept: std.ArrayList(figure_.Fill) = .empty;
            for (f.fills) |fill| {
                const fi = m.fillStyleIndex(fill.style) orelse continue;
                const st = m.fill_styles.items[fi];
                if (!st.cutout) {
                    try kept.append(al, fill);
                    continue;
                }
                const region = try fillRegion(al, sk, fill, .solid);
                if (region.contours.len == 0) continue;
                const shapes = try al.alloc(art_.Shape, 1);
                shapes[0] = .{ .name = "cutout", .outline = region, .paint = .{} };
                try made.append(al, .{ .id = m.newId(), .name = try al.dupe(u8, st.name), .at = at, .shapes = shapes, .cutout = true, .wrap = .ink, .clearance = clearance, .figure = f.id, .sketch_ink = true });
            }
            var g = f;
            g.fills = kept.items;
            g.paths = try m.figurePathsFrom(sk, g);
            const shapes = try figure_.ink(al, g, figure_tolerance);
            if (shapes.len == 0) continue;
            try made.insert(al, 0, .{ .id = m.newId(), .name = try al.dupe(u8, f.name), .at = at, .shapes = shapes, .wrap = wrap, .clearance = clearance, .figure = f.id, .sketch_ink = true });
        }
        try p.art.insertSlice(al, @min(at_index, p.art.items.len), made.items);
    }

    /// `editSketch` as a draft: the sketch as it stands is kept as the
    /// accepted one (when no draft is pending yet), so the change shows
    /// in the sketch editor but reaches no use until `acceptSketch`.
    pub fn editSketchDraft(m: *Model, index: usize, edit: SketchEdit) Error!u32 {
        const it = try m.sketchAt(index);
        if (it.accepted == null) it.accepted = try it.sketch.clone(m.a());
        return m.editSketch(index, edit);
    }

    /// Accepts sketch `index`'s draft: its uses follow it now (its panels'
    /// edges, its drawings, what is solved from it).
    pub fn acceptSketch(m: *Model, index: usize) Error!void {
        const it = try m.sketchAt(index);
        if (it.accepted == null) return;
        it.accepted = null;
        it.version +%= 1;
        const sid = it.id;
        for (m.figures.items) |*f| if (f.sketch == sid) if (f.pending) |p| {
            f.inks = p.inks;
            f.fills = p.fills;
            f.pending = null;
        };
        try m.syncSketchFigures(sid);
        for (m.panels.items, 0..) |pn, pi| if (pn.sketch == sid) try m.syncSketchPanel(pi);
    }

    /// Drops sketch `index`'s draft: back to the sketch as last accepted.
    pub fn discardSketchDraft(m: *Model, index: usize) Error!void {
        const it = try m.sketchAt(index);
        const back = it.accepted orelse return;
        it.sketch = back;
        it.accepted = null;
        it.version +%= 1;
        for (m.figures.items) |*f| if (f.sketch == it.id) {
            f.pending = null;
        };
        try m.syncSketchFigures(it.id);
    }

    /// Changes a sketch (see `SketchEdit`) and solves it again. Returns the
    /// new geometry's or constraint's ID, where the edit makes one (else 0).
    pub fn editSketch(m: *Model, index: usize, edit: SketchEdit) Error!u32 {
        const sk = &(try m.sketchAt(index)).sketch;
        const sid = m.sketches.items[index].id;
        m.sketches.items[index].version +%= 1;
        defer for (m.panels.items, 0..) |pn, pi| if (pn.sketch == sid) {
            m.syncSketchPanel(pi) catch {};
        };
        defer m.syncSketchFigures(sid) catch {};
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
            .array => |e| {
                const r = @sqrt((e.to.x - e.at.x) * (e.to.x - e.at.x) + (e.to.y - e.at.y) * (e.to.y - e.at.y));
                const refs = if (e.polar)
                    try sketch_.arrays.addPolar(sk, al, e.at, r, std.math.atan2(e.to.y - e.at.y, e.to.x - e.at.x), std.math.degreesToRadians(e.sweep), e.cols, e.rows)
                else
                    try sketch_.arrays.addRect(sk, al, .{ .x0 = @min(e.at.x, e.to.x), .y0 = @min(e.at.y, e.to.y), .x1 = @max(e.at.x, e.to.x), .y1 = @max(e.at.y, e.to.y) }, e.cols, e.rows);
                out = switch (refs) {
                    .polar => |p| p.centre,
                    .rect => |q| q.left,
                };
            },
            .polygon => |e| out = (try sketch_.polygon.addRegular(sk, al, e.c, e.corner, e.sides, e.construction)).first,
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
            .place => |e| try sk.setPlace(e.c, e.place),
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
        try list.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .source = m.spaces.items[source].id, .at = at, .scale = scale });
        m.revision += 1;
        return list.items.len - 1;
    }

    /// Whether a view of `source` placed in `host` would show `host`
    /// inside itself: `source` is `host`, or reaches it through views.
    pub fn viewWouldCycle(m: *const Model, host: usize, source: usize) bool {
        if (host == source) return true;
        for (m.spaces.items[source].views.items) |v| {
            if (m.viewWouldCycle(host, m.spaceIndex(v.source) orelse continue)) return true;
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

    /// Release panel: a panel made from a sketch goes back to being a view
    /// of its sketch, and its content layouts are set straight on its
    /// space, all where they were; the view takes the panel's place in its
    /// group. A panel holding line art not of a sketch is refused: line art
    /// is content, and a workspace holds none. Returns what takes the
    /// panel's place: the view, or nothing.
    pub fn releasePanel(m: *Model, panel: usize) Error!ObjectId {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        const p = m.panels.items[panel];
        if (p.art.items.len > 0 or p.grids.items.len > 0) return error.NoRoom;
        const space = m.spaceOf(panel);
        const d = p.origin;
        var took: ObjectId = .none;
        if (p.sketch != .none) {
            took = m.newId();
            try m.spaces.items[space].sketch_views.append(m.a(), .{ .id = took, .sketch = p.sketch, .at = p.sketch_at, .layer = p.layer });
        }
        const dst = &m.spaces.items[space];
        for (p.regions.items) |r| {
            var x = r;
            x.origin = .{ .x = x.origin.x + d.x, .y = x.origin.y + d.y };
            try dst.regions.append(m.a(), x);
        }
        if (took != .none) m.replaceMember(p.id, took) else m.forget(p.id);
        _ = m.panels.orderedRemove(panel);
        m.revision += 1;
        return took;
    }

    /// Where `old` is a group's member, `new` takes its place.
    pub fn replaceMember(m: *Model, old: ObjectId, new: ObjectId) void {
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
        if (m.styleIndex(style) == null) return error.NoSuchStyle;
        m.textStyle(style).cap_height = cap_height;
        m.textStyle(style).em_size = null;
        m.revision += 1;
    }

    /// Sets a style's size as its em, mm (a point size: 12 pt is 25.4 × 12
    /// / 72 mm), as other software sizes type: its cap height then follows
    /// from its font. Until the font is resolved, `cap_per_em` of the em
    /// stands in for the cap height.
    pub fn setEmSize(m: *Model, style: StyleId, em: f64) Error!void {
        if (!(em > 0)) return error.BadSize;
        if (m.styleIndex(style) == null) return error.NoSuchStyle;
        m.textStyle(style).em_size = em;
        m.textStyle(style).cap_height = em * cap_per_em;
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
        m.forget(p.id);
        for (p.regions.items) |r| m.forget(r.id);
        for (p.art.items) |pa| m.forget(pa.id);
        // Its tracks leave their flows; a flow left with none keeps its
        // text, unplaced, and lets go of its tiles.
        m.tidyFlows();
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
        return m.tileInFlows(id);
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

    /// The first "<prefix>N" not yet used by a panel or other object of
    /// space `space` (Panel1).
    pub fn nextPanelName(m: *const Model, buf: []u8, space: ObjectId, prefix: []const u8) []const u8 {
        return m.freshName(buf, .{ .space = space }, prefix);
    }

    pub fn addRegion(m: *Model, parent: Parent, region: TileRegion) Error!usize {
        if (!(region.pitch > 0 and region.w > 0 and region.h > 0)) return error.BadSize;
        var r = region;
        r.id = m.newId();
        r.name = try m.a().dupe(u8, region.name);
        r.path = .empty;
        // A track is one line: one thickness across.
        if (r.kind == .track) {
            if (r.major() == .row) r.h = 1 else r.w = 1;
        }
        // A flow of its own.
        const fi = try m.newFlow(r.name, r.id);
        r.flow = m.flows.items[fi].id;
        const regions = m.regionList(parent);
        try regions.append(m.a(), r);
        m.revision += 1;
        return regions.items.len - 1;
    }

    pub const Tracks = struct {
        name: []const u8,
        /// The region's top-left corner in the panel frame, mm.
        origin: geom.Point,
        /// Rows (a column of rows, or a row track) or columns.
        major: Major = .row,
        /// A region that makes its tracks as needed, or one track.
        kind: TileRegion.Kind = .region,
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
    pub fn addTracks(m: *Model, parent: Parent, t: Tracks) Error!usize {
        var along: f64 = 0;
        var across: f64 = 1;
        if (t.prototype) |pid| {
            if (m.protoIndex(pid) == null) return error.NoSuchPrototype;
            const pr = m.proto(pid).*;
            along = pr.smallest(t.major, .along);
            across = pr.smallest(t.major, .across);
        } else if (t.style) |sid| {
            if (m.styleIndex(sid) == null) return error.NoSuchStyle;
        } else return error.NoSuchPrototype;
        if (t.count == 0 or !(t.length > 0) or !(t.length >= along - 1e-9)) return error.BadSize;
        const thickness = @as(f64, @floatFromInt(t.count)) * across;
        const r = try m.addRegion(parent, .{
            .name = t.name,
            .origin = t.origin,
            .w = if (t.major == .row) t.length else thickness,
            .h = if (t.major == .row) thickness else t.length,
            .pitch = t.pitch,
            .direction = TileRegion.oriented(t.major).direction,
            .rotation = TileRegion.oriented(t.major).rotation,
            .stack = TileRegion.oriented(t.major).stack,
            .kind = t.kind,
            .prototype = t.prototype,
            .style = t.style,
        });
        // Segments come as the flow needs them, along its path, within the
        // soft area `count` segments thick.
        return r;
    }

    /// Removes track or region `region` of `panel`. Its flow goes on in
    /// its other tracks; left with none, it keeps its text, unplaced, and
    /// lets go of its tiles (as a removed panel's tracks do).
    pub fn removeRegion(m: *Model, parent: Parent, region: usize) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchRow;
        const r = m.regionList(parent).orderedRemove(region);
        m.forget(r.id);
        m.tidyFlows();
        m.revision += 1;
    }

    /// Sets the way track or region `region`'s baselines run and how its
    /// content stands on them, degrees (see `TileRegion.direction`). Turned
    /// between rows and columns, its length stays its length: a track
    /// stays one thick, a region keeps its depth, and a region stacks on
    /// the side its new axis case does. A flow's tracks all run one way, so
    /// that turn is refused for a track sharing its flow (`BadJoin`).
    pub fn setOrientation(m: *Model, parent: Parent, region: usize, direction: f64, rotation: f64) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchRow;
        if (!std.math.isFinite(direction) or !std.math.isFinite(rotation)) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        const before = r.major();
        var next = r.*;
        next.direction = direction;
        next.rotation = rotation;
        const after = next.major();
        if (after != before) {
            if (m.trackFlow(parent, region)) |f| if (f.tracks.items.len > 1) return error.BadJoin;
            std.mem.swap(f64, &r.w, &r.h);
            if (r.kind == .region) r.stack = TileRegion.oriented(after).stack;
        }
        r.direction = direction;
        r.rotation = rotation;
        m.revision += 1;
    }

    /// Makes region `region` of `panel` into tracks, one a row (or
    /// column), each one thick at its origin in `origins` (panel mm, top
    /// left, as `TileRegion.origin`): the region becomes the first, and the
    /// rest follow it in its flow, so its content runs
    /// on through them as it did (named after it, numbered within the panel:
    /// keys1, keys2 …). Its path's control points go (a track's
    /// path is its own); its length stays. Returns how many tracks.
    pub fn splitIntoTracks(m: *Model, parent: Parent, region: usize, origins: []const geom.Point) Error!usize {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchRow;
        if (origins.len == 0) return error.BadSize;
        const r0 = m.regionsIn(parent)[region];
        if (r0.kind != .region) return error.BadJoin;
        const base = try m.a().dupe(u8, r0.name);
        const into = r0.flow;
        var pos = m.flowPosition(parent, region) orelse return error.BadJoin;
        var name_buf: [160]u8 = undefined;
        var ib: [96]u8 = undefined;
        // Its own name gives way, and numbers follow its stem (Rows1 →
        // Rows1, Rows2 …; keys → keys1, keys2 …).
        const stem = std.mem.trimEnd(u8, names.identifier(&ib, base, "Track"), "0123456789");
        m.regionsIn(parent)[region].name = "";
        for (origins, 0..) |o, k| {
            const name = m.freshName(&name_buf, m.containerOf(parent), stem);
            if (k == 0) {
                const r = &m.regionsIn(parent)[region];
                r.kind = .track;
                r.name = try m.a().dupe(u8, name);
                r.origin = o;
                if (r.major() == .row) r.h = 1 else r.w = 1;
                r.path = .empty;
                continue;
            }
            var t = m.regionsIn(parent)[region];
            t.name = name;
            t.origin = o;
            const ri = try m.addRegion(parent, t);
            // Its own flow, made for it, gives way to the region's.
            const own = m.regionsIn(parent)[ri].flow;
            pos += 1;
            try m.assignTrack(parent, ri, into, pos);
            if (m.flowIndex(own)) |fi| if (m.flows.items[fi].tracks.items.len == 0 and m.flows.items[fi].items.items.len == 0) {
                _ = m.flows.orderedRemove(fi);
            };
        }
        m.revision += 1;
        return origins.len;
    }

    /// The lowest-numbered designator `prefix`1, `prefix`2 … not taken.
    fn nextDesignator(m: *const Model, buf: []u8, prefix: []const u8) []const u8 {
        return m.freshName(buf, .keys, prefix);
    }

    // Flows ------------------------------------------------------------

    /// The index of flow `id`, if it is one.
    pub fn flowIndex(m: *const Model, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.flows.items, 0..) |f, i| if (f.id == id) return i;
        return null;
    }

    /// The index of the flow track `region` of `panel` is assigned to.
    pub fn trackFlowIndex(m: *const Model, parent: Parent, region: usize) ?usize {
        return m.flowIndex(m.regionsIn(parent)[region].flow);
    }

    /// The flow track `region` of `panel` is assigned to.
    pub fn trackFlow(m: *const Model, parent: Parent, region: usize) ?*const Flow {
        return &m.flows.items[m.trackFlowIndex(parent, region) orelse return null];
    }

    /// Whether track `region` of `panel` is the first of its flow's: the
    /// one its content starts in (as a thread's first track held it).
    pub fn firstOfFlow(m: *const Model, parent: Parent, region: usize) bool {
        const f = m.trackFlow(parent, region) orelse return true;
        return f.tracks.items.len == 0 or f.tracks.items[0] == m.regionsIn(parent)[region].id;
    }

    /// The content of track `region`'s flow, where that track starts it:
    /// on the flow's first track, all of it; on the others, nothing. (So
    /// a pass over every track meets each flow's content once.)
    pub fn ownItems(m: *const Model, parent: Parent, region: usize) []const Item {
        if (!m.firstOfFlow(parent, region)) return &.{};
        const f = m.trackFlow(parent, region) orelse return &.{};
        return f.items.items;
    }

    /// The content of the flow track `region` of `panel` is assigned to,
    /// whichever of its tracks it is.
    pub fn flowItems(m: *const Model, parent: Parent, region: usize) []const Item {
        const f = m.trackFlow(parent, region) orelse return &.{};
        return f.items.items;
    }

    /// The first paragraph's style of track `region`'s flow, where the
    /// track starts it (else null, as `ownItems`).
    pub fn ownParagraph(m: *const Model, parent: Parent, region: usize) ?ParaId {
        if (!m.firstOfFlow(parent, region)) return null;
        const f = m.trackFlow(parent, region) orelse return null;
        return f.paragraph;
    }

    /// The new-paragraph indent of track `region`'s flow, u.
    pub fn trackIndent(m: *const Model, parent: Parent, region: usize) f64 {
        const f = m.trackFlow(parent, region) orelse return 0;
        return f.indent;
    }

    /// The flow track `region` of `panel` is assigned to, to change. Every
    /// track has one (`addRegion`, `copyRegion`).
    fn flowOf(m: *Model, parent: Parent, region: usize) *Flow {
        return &m.flows.items[m.trackFlowIndex(parent, region).?];
    }

    fn flow(m: *Model, parent: Parent, region: usize) *std.ArrayList(Item) {
        return &m.flowOf(parent, region).items;
    }

    /// A new flow named `name` (or, when a flow has that name, `name` 2,
    /// 3 …) running through track `track` (or none), empty. Returns its
    /// index.
    fn newFlow(m: *Model, name: []const u8, track: ObjectId) Error!usize {
        var nb: [160]u8 = undefined;
        var ib: [96]u8 = undefined;
        const id = names.identifier(&ib, name, "Flow");
        const unique = if (!m.nameTaken(.flows, id)) id else m.freshName(&nb, .flows, "Flow");
        var f: Flow = .{ .id = m.newId(), .name = try m.a().dupe(u8, unique) };
        if (track != .none) try f.tracks.append(m.a(), track);
        try m.flows.append(m.a(), f);
        return m.flows.items.len - 1;
    }

    /// Whether a flow is named `name`.
    pub fn flowNamed(m: *const Model, name: []const u8) bool {
        for (m.flows.items) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }

    /// Flows after tracks have gone: each loses the tracks no longer
    /// there; one left with none keeps its text, unplaced, and lets go of
    /// its tiles (removed, unless placed in another flow); one left with
    /// nothing at all goes.
    fn tidyFlows(m: *Model) void {
        for (m.flows.items) |*f| {
            var k: usize = 0;
            while (k < f.tracks.items.len) {
                if (m.trackById(f.tracks.items[k]) == null) _ = f.tracks.orderedRemove(k) else k += 1;
            }
        }
        var i: usize = 0;
        while (i < m.flows.items.len) {
            const f = &m.flows.items[i];
            if (f.tracks.items.len > 0) {
                i += 1;
                continue;
            }
            var j: usize = 0;
            var text = false;
            while (j < f.items.items.len) {
                if (f.items.items[j].tileOf()) |tid| {
                    _ = f.items.orderedRemove(j);
                    if (!m.tileInFlows(tid)) if (m.tileIndex(tid) != null) {
                        m.tile(tid).removed = true;
                    };
                } else {
                    if (f.items.items[j].what == .run) text = true;
                    j += 1;
                }
            }
            if (!text) _ = m.flows.orderedRemove(i) else i += 1;
        }
    }

    /// Whether tile `id` is in any flow's content.
    fn tileInFlows(m: *const Model, id: TileId) bool {
        for (m.flows.items) |f| for (f.items.items) |item| if (item.tileOf() == id) return true;
        return false;
    }

    /// A new flow named `name`, empty and unplaced. Returns its ID.
    pub fn addFlow(m: *Model, name: []const u8) Error!ObjectId {
        const fi = try m.newFlow(name, .none);
        m.revision += 1;
        return m.flows.items[fi].id;
    }

    /// Renames flow `id`.
    pub fn renameFlow(m: *Model, id: ObjectId, name: []const u8) Error!void {
        const fi = m.flowIndex(id) orelse return error.NoSuchObject;
        m.flows.items[fi].name = try m.a().dupe(u8, name);
        m.revision += 1;
    }

    /// Assigns track `region` of `panel` to flow `id`, at `position` among
    /// its tracks (null: after the last); to its own flow, it moves within
    /// it. The flow it leaves keeps its content, going on from its next
    /// track; left with none, it keeps its text unplaced, or goes when it
    /// held none. A flow's tracks all run the same way.
    pub fn assignTrack(m: *Model, parent: Parent, region: usize, id: ObjectId, position: ?usize) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchRow;
        const to = m.flowIndex(id) orelse return error.NoSuchObject;
        const r = m.regionsIn(parent)[region];
        for (m.flows.items[to].tracks.items) |tid| if (tid != r.id) if (m.trackById(tid)) |t| {
            if (m.trackPtr(t).major() != r.major()) return error.BadJoin;
        };
        // Out of the flow it is in.
        if (m.trackFlowIndex(parent, region)) |from| {
            const k = m.flowPosition(parent, region).?;
            _ = m.flows.items[from].tracks.orderedRemove(k);
        }
        const list = &m.flows.items[to].tracks;
        const at = @min(position orelse list.items.len, list.items.len);
        try list.insert(m.a(), at, r.id);
        m.regionsIn(parent)[region].flow = id;
        m.tidyFlows();
        m.revision += 1;
    }

    /// Takes track `region` of `panel` out of its flow, which keeps its
    /// content (unplaced, if this was its only track); the track gets a
    /// new flow of its own, empty. Not for a track alone in an empty flow.
    pub fn detachTrack(m: *Model, parent: Parent, region: usize) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchRow;
        const f = m.trackFlow(parent, region) orelse return error.BadJoin;
        if (f.tracks.items.len <= 1 and f.items.items.len == 0) return error.BadJoin;
        const fi = m.trackFlowIndex(parent, region).?;
        _ = m.flows.items[fi].tracks.orderedRemove(m.flowPosition(parent, region).?);
        const r = &m.regionsIn(parent)[region];
        const ni = try m.newFlow(r.name, r.id);
        m.flows.items[ni].indent = m.flows.items[fi].indent;
        m.regionsIn(parent)[region].flow = m.flows.items[ni].id;
        m.revision += 1;
    }

    /// Removes flow `id` and its content (its tiles too, unless in another
    /// flow); each of its tracks gets a new flow of its own, empty.
    pub fn removeFlow(m: *Model, id: ObjectId) Error!void {
        const fi = m.flowIndex(id) orelse return error.NoSuchObject;
        const gone = m.flows.orderedRemove(fi);
        for (gone.items.items) |item| if (item.tileOf()) |tid| {
            if (!m.tileInFlows(tid) and m.tileIndex(tid) != null) m.tile(tid).removed = true;
        };
        for (gone.tracks.items) |tid| if (m.trackById(tid)) |t| {
            const r = m.trackPtr(t);
            const ni = try m.newFlow(r.name, r.id);
            m.flows.items[ni].indent = gone.indent;
            m.trackPtr(t).flow = m.flows.items[ni].id;
        };
        m.revision += 1;
    }

    /// Flow `id`, to change.
    fn flowById(m: *Model, id: ObjectId) Error!*Flow {
        return &m.flows.items[m.flowIndex(id) orelse return error.NoSuchObject];
    }

    /// Records that text was imported into flow `id` from `src`.
    pub fn addFlowSource(m: *Model, id: ObjectId, src: FlowSource) Error!void {
        const f = try m.flowById(id);
        try f.sources.append(m.a(), .{ .uri = try m.a().dupe(u8, src.uri), .sha256 = try m.a().dupe(u8, src.sha256), .imported = src.imported });
        m.revision += 1;
    }

    /// Inserts `item` (a run, a hard break or a paragraph separator; not a
    /// tile) at position `index` of flow `id` (null: its end), whether or
    /// not it has tracks.
    pub fn placeInFlow(m: *Model, id: ObjectId, index: ?usize, item: Item) Error!void {
        if (item.what == .tile) return error.NoSuchItem;
        if (item.what == .paragraph) if (item.what.paragraph) |ps| if (m.paraIndex(ps) == null) return error.NoSuchStyle;
        const f = try m.flowById(id);
        const at = index orelse f.items.items.len;
        if (at > f.items.items.len) return error.NoSuchItem;
        var it = item;
        if (it.what == .run) it.what.run.content = try m.a().dupe(u8, it.what.run.content);
        try f.items.insert(m.a(), at, it);
        m.revision += 1;
    }

    /// As `insertBreak`, in flow `id`: a hard break at `index`, and the
    /// flow's indent after it. How many items went in.
    pub fn insertBreakIn(m: *Model, id: ObjectId, index: usize) Error!usize {
        try m.placeInFlow(id, index, .{ .what = .hard_break });
        const f = try m.flowById(id);
        if (!(f.indent > 0)) return 1;
        // A blank as long as the indent, running the flow's way.
        var major: Major = .row;
        for (f.tracks.items) |tid| if (m.trackById(tid)) |t| {
            major = m.trackPtr(t).major();
            break;
        };
        const blank = try m.blankPrototype();
        var buf: [64]u8 = undefined;
        const tile_id = try m.addTile(.{
            .designator = m.nextDesignator(&buf, "B"),
            .prototype = blank,
            .w = if (major == .row) f.indent else 1,
            .h = if (major == .row) 1 else f.indent,
        });
        const g = try m.flowById(id);
        try g.items.insert(m.a(), index + 1, .{ .what = .{ .tile = tile_id } });
        m.revision += 1;
        return 2;
    }

    /// As `setParagraphAt`, in flow `id`.
    pub fn setParagraphAtIn(m: *Model, id: ObjectId, index: usize, style: ?ParaId) Error!void {
        if (style) |ps| if (m.paraIndex(ps) == null) return error.NoSuchStyle;
        const f = try m.flowById(id);
        var k = @min(index, f.items.items.len);
        while (k > 0) {
            k -= 1;
            if (f.items.items[k].what == .paragraph) {
                f.items.items[k].what = .{ .paragraph = style };
                m.revision += 1;
                return;
            }
        }
        f.paragraph = style;
        m.revision += 1;
    }

    /// The pitch of flow `id`'s first track, if it has one, mm.
    pub fn flowPitch(m: *const Model, id: ObjectId) ?f64 {
        const fi = m.flowIndex(id) orelse return null;
        for (m.flows.items[fi].tracks.items) |tid| if (m.trackById(tid)) |t| return m.regionsIn(t.parent)[t.region].pitch;
        return null;
    }

    /// An older document kept each workspace's loose objects on a panel of
    /// its own (its `root`), standing in for the workspace. Called on
    /// loading: that panel's content layouts and grids are set straight on
    /// the workspace, where they were (the panel sat at the workspace's
    /// origin), and the panel goes. Line art on it, which a workspace
    /// cannot hold, goes onto a new panel around it, so nothing is lost.
    pub fn upgradeRoots(m: *Model) Error!void {
        for (m.spaces.items) |*sp| {
            const root = sp.old_root;
            sp.old_root = .none;
            const pi = m.panelIndex(root) orelse continue;
            const rp = m.panels.items[pi];
            const d = rp.origin;
            for (rp.regions.items) |r| {
                var x = r;
                x.origin = .{ .x = x.origin.x + d.x, .y = x.origin.y + d.y };
                try sp.regions.append(m.a(), x);
            }
            for (rp.grids.items) |g| {
                var x = g;
                x.origin = .{ .x = x.origin.x + d.x, .y = x.origin.y + d.y };
                try sp.grids.append(m.a(), x);
            }
            var art_panel: ?Panel = null;
            if (rp.art.items.len > 0) {
                var b: geom.Box = .empty;
                for (rp.art.items) |x| b = b.join(x.box());
                if (b.isEmpty()) b = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
                var name_buf: [64]u8 = undefined;
                const name = m.nextPanelName(&name_buf, sp.id, "Panel");
                var np: Panel = .{
                    .id = m.newId(),
                    .name = try m.a().dupe(u8, name),
                    .default_name = true,
                    .space = sp.id,
                    .origin = .{ .x = d.x + b.x0, .y = d.y + b.y0 },
                    .w = @max(b.width(), 1),
                    .h = @max(b.height(), 1),
                    .margins = .all(0),
                    .default_margins = false,
                };
                for (rp.art.items) |x| {
                    var y = x;
                    y.at = .{ .x = y.at.x - b.x0, .y = y.at.y - b.y0 };
                    try np.art.append(m.a(), y);
                }
                art_panel = np;
            }
            m.forget(root);
            _ = m.panels.orderedRemove(pi);
            if (art_panel) |np| try m.panels.append(m.a(), np);
        }
    }

    /// An older document's rows or columns, as directions (see
    /// `TileRegion.oriented`). Called on loading; a newer document's
    /// tracks keep theirs.
    pub fn upgradeOrientation(m: *Model) void {
        for (m.panels.items) |*p| for (p.regions.items) |*r| {
            if (r.old_major == .column and r.direction == 0 and r.rotation == 0) {
                const o = TileRegion.oriented(.column);
                r.direction = o.direction;
                r.rotation = o.rotation;
                r.stack = o.stack;
            }
            r.old_major = .row;
        };
    }

    /// Inserts item `item` at position `index` of a track's flow (0
    /// before the first item; null for the end). Its tile, if any, must
    /// already exist.
    pub fn place(m: *Model, parent: Parent, region: usize, index: ?usize, item: Item) Error!void {
        const items = m.flow(parent, region);
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
    pub fn insertTile(m: *Model, parent: Parent, region: usize, index: usize, prototype: PrototypeId, along: f64) Error!TileId {
        if (m.protoIndex(prototype) == null) return error.NoSuchPrototype;
        if (index > m.flow(parent, region).items.len) return error.NoSuchItem;
        const major = m.regionsIn(parent)[region].major();
        const across = m.proto(prototype).smallest(major, .across);
        var buf: [64]u8 = undefined;
        const id = try m.addTile(.{
            .designator = m.nextDesignator(&buf, "T"),
            .prototype = prototype,
            .w = if (major == .row) along else across,
            .h = if (major == .row) across else along,
        });
        try m.place(parent, region, index, .{ .what = .{ .tile = id } });
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
        if (!m.proto(m.tileConst(id).prototype).letter) return false;
        return switch (next.what) {
            .hard_break, .paragraph => false,
            .run => true,
            .tile => |nid| blk: {
                const np = m.proto(m.tileConst(nid).prototype).*;
                break :blk !np.spacer;
            },
        };
    }

    /// The built-in Blank prototype, made the first time it is asked for:
    /// a spacer of any size, kept at soft breaks, in its track's unit.
    pub fn blankPrototype(m: *Model) Error!PrototypeId {
        if (m.blank_prototype) |id| return id;
        // Tiles default to the first prototype: keep that a plain one, not
        // Blank.
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
    pub fn insertBlank(m: *Model, parent: Parent, region: usize, index: usize, length: f64) Error!TileId {
        if (!(length > 0)) return error.BadSize;
        if (index > m.flow(parent, region).items.len) return error.NoSuchItem;
        const blank = try m.blankPrototype();
        const major = m.regionsIn(parent)[region].major();
        var buf: [64]u8 = undefined;
        const id = try m.addTile(.{
            .designator = m.nextDesignator(&buf, "B"),
            .prototype = blank,
            .w = if (major == .row) length else 1,
            .h = if (major == .row) 1 else length,
        });
        try m.place(parent, region, index, .{ .what = .{ .tile = id } });
        return id;
    }

    /// Inserts a hard break at position `index` of a track: what follows
    /// starts the next segment. With the track's indent set, a blank that
    /// long follows it. Returns how many items went in (1, or 2).
    pub fn insertBreak(m: *Model, parent: Parent, region: usize, index: usize) Error!usize {
        try m.place(parent, region, index, .{ .what = .hard_break });
        const indent = m.trackIndent(parent, region);
        if (!(indent > 0)) return 1;
        _ = try m.insertBlank(parent, region, index + 1, indent);
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
        // A signed value given: its sign is the side.
        if (out.value < 0) {
            out.value = -out.value;
            out.side = -out.side;
        }
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
    /// Never negative (its side stays as it is).
    pub fn setConstraintValue(m: *Model, id: ObjectId, value: f64) Error!void {
        if (!std.math.isFinite(value) or value < 0) return error.BadConstraint;
        const i = m.constraintIndex(id) orelse return error.NoSuchObject;
        m.constraints.items[i].value = value;
        m.revision += 1;
    }

    /// Makes constraint `id` driving or a reference. Made driving, it holds
    /// `value` on `side` (what it measures now, so nothing moves).
    pub fn setConstraintDriving(m: *Model, id: ObjectId, driving: bool, value: f64, side: f64) Error!void {
        if (!std.math.isFinite(value) or value < 0) return error.BadConstraint;
        const i = m.constraintIndex(id) orelse return error.NoSuchObject;
        const c = &m.constraints.items[i];
        c.driving = driving;
        if (driving) {
            c.value = value;
            c.side = if (side < 0) -1 else 1;
        }
        m.revision += 1;
    }

    /// Places constraint `id`'s dimension (where it is drawn only).
    pub fn setConstraintPlace(m: *Model, id: ObjectId, at: ConstraintPlace) Error!void {
        if (!std.math.isFinite(at.offset) or !std.math.isFinite(at.text)) return error.BadConstraint;
        const i = m.constraintIndex(id) orelse return error.NoSuchObject;
        m.constraints.items[i].place = at;
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

    /// The figure drawn over sketch `sketch` (its ID), if any.
    pub fn sketchFigure(m: *const Model, sketch: ObjectId) ?usize {
        if (sketch == .none) return null;
        // The drawing the editor works in, when it names one still there.
        if (m.sketchIndex(sketch)) |si| if (m.figureIndex(m.sketches.items[si].drawing)) |fi| {
            if (m.figures.items[fi].sketch == sketch) return fi;
        };
        return m.firstDrawing(sketch);
    }

    /// Sketch `sketch`'s first drawing (the one made first), if any.
    pub fn firstDrawing(m: *const Model, sketch: ObjectId) ?usize {
        if (sketch == .none) return null;
        for (m.figures.items, 0..) |f, i| if (f.sketch == sketch) return i;
        return null;
    }

    /// The drawing panel `panel` carries: its own choice, else its sketch's
    /// first.
    pub fn panelDrawing(m: *const Model, panel: usize) ?usize {
        const p = m.panels.items[panel];
        if (m.figureIndex(p.drawing)) |fi| if (m.figures.items[fi].sketch == p.sketch) return fi;
        return m.firstDrawing(p.sketch);
    }

    /// A new drawing over sketch `index` (empty), named `name`, made the
    /// one the editor inks in. Its index among the figures.
    pub fn addDrawing(m: *Model, index: usize, name: []const u8) Error!usize {
        const it = try m.sketchAt(index);
        const id = m.newId();
        try m.figures.append(m.a(), .{ .id = id, .name = try m.a().dupe(u8, name), .paths = &.{}, .sketch = it.id });
        it.drawing = id;
        m.revision += 1;
        return m.figures.items.len - 1;
    }

    /// Makes drawing `drawing` (one over sketch `index`) the one the editor
    /// inks in.
    pub fn setSketchDrawing(m: *Model, index: usize, drawing: ObjectId) Error!void {
        const it = try m.sketchAt(index);
        const fi = m.figureIndex(drawing) orelse return error.NoSuchItem;
        if (m.figures.items[fi].sketch != it.id) return error.NoSuchItem;
        it.drawing = drawing;
        m.revision += 1;
    }

    /// Chooses which of its sketch's drawings panel `panel` carries.
    pub fn setPanelDrawing(m: *Model, panel: usize, drawing: ObjectId) Error!void {
        if (panel >= m.panels.items.len) return error.NoSuchItem;
        const p = &m.panels.items[panel];
        const fi = m.figureIndex(drawing) orelse return error.NoSuchItem;
        if (m.figures.items[fi].sketch != p.sketch) return error.NoSuchItem;
        p.drawing = drawing;
        try m.syncSketchPanelInk(panel);
        m.revision += 1;
    }

    /// Makes the paths of the figures drawn over sketch `sketch` (all of
    /// them when `.none`) from its geometry and their inks: each inked
    /// geometry one path, stroked in its style. Ink whose geometry or
    /// style is gone is left out.
    pub fn syncSketchFigures(m: *Model, sketch: ObjectId) Error!void {
        for (m.figures.items) |*f| {
            if (f.sketch == .none or (sketch != .none and f.sketch != sketch)) continue;
            const ski = m.sketchIndex(f.sketch) orelse continue;
            const item = &m.sketches.items[ski];
            f.paths = try m.figurePathsFrom(item.used(), f.*);
            // The sketch editor's view of a pending draft.
            // The editor's view of a pending draft: the draft sketch, with
            // its pending marks.
            if (item.accepted != null or f.pending != null) {
                var d = f.*;
                if (f.pending) |p| {
                    d.inks = p.inks;
                    d.fills = p.fills;
                }
                f.draft = try m.figurePathsFrom(&item.sketch, d);
            } else f.draft = &.{};
        }
        for (m.panels.items, 0..) |pn, pi| {
            if (pn.sketch == .none or (sketch != .none and pn.sketch != sketch)) continue;
            try m.syncSketchPanelInk(pi);
        }
    }

    /// The paths of figure `f`, drawn over sketch `sk`: its fills, then each
    /// inked geometry one path, stroked in its style.
    fn figurePathsFrom(m: *Model, sk: *const sketch_.Sketch, f: figure_.Figure) Error![]const figure_.Path {
        const al = m.a();
        var paths: std.ArrayList(figure_.Path) = .empty;
        for (f.fills) |fill| {
            const si = m.fillStyleIndex(fill.style) orelse continue;
            const st = m.fill_styles.items[si];
            const region = try fillRegion(al, sk, fill, st.pattern);
            if (region.contours.len == 0) continue;
            const sub = try al.alloc(figure_.Subpath, region.contours.len);
            for (region.contours, sub) |c, *sp| sp.* = .{ .segments = c.segments, .closed = true };
            try paths.append(al, .{ .subpaths = sub, .fill = st.color, .fill_rule = .evenodd });
        }
        // Each style's ink joined into runs (`Sketch.runs`), so a pen's
        // joins fall at the corners and its caps only at true ends.
        var styles: std.ArrayList(ObjectId) = .empty;
        for (f.inks) |ink| {
            for (styles.items) |st| {
                if (st == ink.style) break;
            } else try styles.append(al, ink.style);
        }
        for (styles.items) |style| {
            const si = m.strokeStyleIndex(style) orelse continue;
            var segs: std.ArrayList(geom.Segment) = .empty;
            for (f.inks) |ink| {
                if (ink.style != style or ink.geom >= sk.geometry.items.len) continue;
                const g = sk.geometry.items[ink.geom];
                if (g.removed) continue;
                try sk.appendSegments(al, g, &segs);
            }
            if (segs.items.len == 0) continue;
            const runs = try sketch_.Sketch.runs(al, segs.items);
            const sub = try al.alloc(figure_.Subpath, runs.len);
            for (runs, sub) |r, *sp| sp.* = .{ .segments = r.segments, .closed = r.closed };
            try paths.append(al, .{ .subpaths = sub, .stroke = m.stroke_styles.items[si].stroke });
        }
        try m.connectorPaths(sk, &paths);
        return paths.items;
    }

    /// Sketch `sk`'s connections, drawn in their styles: each path
    /// stroked, and its ends marked.
    fn connectorPaths(m: *Model, sk: *const sketch_.Sketch, paths: *std.ArrayList(figure_.Path)) Error!void {
        const al = m.a();
        for (sk.connectors.items, 0..) |c, ci| {
            var segs: std.ArrayList(geom.Segment) = .empty;
            if (m.strokeStyleIndex(m.connectorStyleOf(@enumFromInt(c.style)).stroke) == null) continue;
            const dirs = sketch_.connector.segments(sk, al, ci, &segs) catch continue;
            if (segs.items.len == 0) continue;
            const cs = m.connectorStyleOf(@enumFromInt(c.style));
            // Annotation (no stroke): not drawn.
            const stroke: figure_.Stroke = if (m.strokeStyleIndex(cs.stroke)) |i| m.stroke_styles.items[i].stroke else continue;
            const runs = try sketch_.Sketch.runs(al, segs.items);
            const sub = try al.alloc(figure_.Subpath, runs.len);
            for (runs, sub) |r, *sp| sp.* = .{ .segments = r.segments, .closed = r.closed };
            try paths.append(al, .{ .subpaths = sub, .stroke = stroke });
            const ends = [2]struct { mark: ConnectorEnd, p: sketch_.PointRef, th: f64 }{
                // Into the feature at the start, and on into the end.
                .{ .mark = cs.start, .p = .{ .geom = c.start, .role = .point }, .th = dirs.leave + std.math.pi },
                .{ .mark = cs.end, .p = .{ .geom = c.end, .role = .point }, .th = dirs.arrive },
            };
            for (ends) |e| {
                if (e.mark == .none) continue;
                const p = sk.point(e.p) catch continue;
                if (try connectorMark(al, e.mark, p, e.th, cs.size, stroke)) |path| try paths.append(al, path);
            }
        }
    }

    /// A connection's end mark at `p`, pointing at angle `th` (radians).
    fn connectorMark(al: std.mem.Allocator, mark: ConnectorEnd, p: geom.Point, th: f64, size: f64, stroke: figure_.Stroke) Error!?figure_.Path {
        const d: geom.Point = .{ .x = @cos(th), .y = @sin(th) };
        const n: geom.Point = .{ .x = -d.y, .y = d.x };
        switch (mark) {
            .none => return null,
            .arrow => {
                // A closed head, a third as wide as long, its tip on `p`.
                const b: geom.Point = .{ .x = p.x - d.x * size, .y = p.y - d.y * size };
                const w = size / 3;
                const q = [3]geom.Point{ p, .{ .x = b.x + n.x * w, .y = b.y + n.y * w }, .{ .x = b.x - n.x * w, .y = b.y - n.y * w } };
                const segs = try al.alloc(geom.Segment, 3);
                for (0..3) |j| segs[j] = .{ .line = .{ q[j], q[(j + 1) % 3] } };
                const sub = try al.dupe(figure_.Subpath, &.{.{ .segments = segs, .closed = true }});
                return .{ .subpaths = sub, .fill = stroke.color };
            },
            .dot => {
                var buf: [4]geom.Segment = undefined;
                const segs = try al.dupe(geom.Segment, geom.arc(p, size / 3, 0, 2 * std.math.pi, &buf));
                const sub = try al.dupe(figure_.Subpath, &.{.{ .segments = segs, .closed = true }});
                return .{ .subpaths = sub, .fill = stroke.color };
            },
            .bar => {
                const h = size / 2;
                const segs = try al.dupe(geom.Segment, &.{.{ .line = .{ .{ .x = p.x + n.x * h, .y = p.y + n.y * h }, .{ .x = p.x - n.x * h, .y = p.y - n.y * h } } }});
                const sub = try al.dupe(figure_.Subpath, &.{.{ .segments = segs, .closed = false }});
                var st = stroke;
                st.dash = &.{};
                return .{ .subpaths = sub, .stroke = st };
            },
        }
    }

    pub fn connectorStyleIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.connector_styles.items, 0..) |st, i| if (st.id == id) return i;
        return null;
    }

    /// Connector style `id`, or the default (a plain arrow at the start)
    /// when there is none of that ID.
    pub fn connectorStyleOf(m: *const Model, id: ObjectId) ConnectorStyle {
        if (m.connectorStyleIndex(id)) |i| return m.connector_styles.items[i];
        return .{ .name = "Leader" };
    }

    /// The connector style leaders take: the one named "Leader", made
    /// (a solid pen, an arrow at the start) when there is none.
    fn leaderStyle(m: *Model) Error!ObjectId {
        for (m.connector_styles.items) |st| if (std.mem.eql(u8, st.name, "Leader")) return st.id;
        // A solid pen: the first undashed stroke style, else one made.
        var stroke: ObjectId = .none;
        for (m.stroke_styles.items) |st| if (st.stroke.dash.len == 0) {
            stroke = st.id;
            break;
        };
        if (stroke == .none) stroke = try m.addStrokeStyle("Leader", .{ .color = .{ .r = 0, .g = 0, .b = 0 }, .width = 0.25, .cap = .round, .join = .round });
        const id = m.newId();
        try m.connector_styles.append(m.a(), .{ .id = id, .name = "Leader", .stroke = stroke });
        return id;
    }

    /// Changes connector style `style.id`: the connections in it follow.
    pub fn setConnectorStyle(m: *Model, style: ConnectorStyle) Error!void {
        const i = m.connectorStyleIndex(style.id) orelse return error.NoSuchStyle;
        if (!(style.size > 0) or !std.math.isFinite(style.size)) return error.BadValue;
        if (!(style.radius > 0) or !(style.lead >= 0) or !std.math.isFinite(style.radius) or !std.math.isFinite(style.lead)) return error.BadValue;
        if (style.stroke != .none and m.strokeStyleIndex(style.stroke) == null) return error.NoSuchStyle;
        var st = style;
        st.name = try m.a().dupe(u8, style.name);
        m.connector_styles.items[i] = st;
        try m.syncSketchFigures(.none);
        m.revision += 1;
    }

    /// Gives connection `ci` of `sk` connector style `id`, and the style's
    /// bend radius and leads to start from.
    fn styleConnector(m: *Model, sk: *sketch_.Sketch, ci: usize, id: ObjectId) void {
        const cs = m.connectorStyleOf(id);
        const c = &sk.connectors.items[ci];
        c.style = @intFromEnum(id);
        c.radius = cs.radius;
        c.lead = cs.lead;
    }

    /// Adds a connection to sketch `sketch` from `from` (a point, a side or
    /// curve, or nowhere), of kind `kind`, in the leaders' style; with
    /// `to`, made to reach that point (a Dubins path). Returns its index.
    pub fn addConnection(m: *Model, sketch: ObjectId, from: sketch_.connector.From, to: ?sketch_.PointRef, kind: sketch_.connector.Kind) Error!u32 {
        const ski = m.sketchIndex(sketch) orelse return error.NoSuchItem;
        const style = try m.leaderStyle();
        const sk = &m.sketches.items[ski].sketch;
        const ci = sketch_.connector.add(sk, m.a(), from, .segments, 3, 6) catch |e| return switch (e) {
            error.NotOnACurve => error.NotOnACurve,
            error.OutOfMemory => error.OutOfMemory,
            else => error.NoSuchItem,
        };
        m.styleConnector(sk, ci, style);
        if (to) |p| {
            sketch_.connector.reach(sk, m.a(), ci, p) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NoSuchItem,
            };
        } else if (kind == .dubins) sketch_.connector.convert(sk, m.a(), ci, .dubins) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.NoSuchItem,
        };
        _ = try sk.solve(m.arena.child_allocator);
        m.sketches.items[ski].version +%= 1;
        _ = try m.sketchFigureFor(ski, true);
        try m.syncSketchFigures(sketch);
        m.revision += 1;
        return @intCast(ci);
    }

    /// Sets connection `ci`'s own bend radius and leads (a Dubins path's).
    pub fn setConnectorShape(m: *Model, sketch: ObjectId, ci: u32, radius: f64, lead: f64) Error!void {
        const ski = m.sketchIndex(sketch) orelse return error.NoSuchItem;
        const sk = &m.sketches.items[ski].sketch;
        if (ci >= sk.connectors.items.len) return error.NoSuchItem;
        sketch_.connector.setShape(sk, m.a(), ci, radius, lead) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadValue,
        };
        _ = try sk.solve(m.arena.child_allocator);
        m.sketches.items[ski].version +%= 1;
        try m.syncSketchFigures(sketch);
        m.revision += 1;
    }

    /// Makes connection `ci` of sketch `sketch` a path of kind `kind`
    /// (joined segments, or a Dubins path); its ends stay where they are.
    pub fn setConnectorKind(m: *Model, sketch: ObjectId, ci: u32, kind: sketch_.connector.Kind) Error!void {
        const ski = m.sketchIndex(sketch) orelse return error.NoSuchItem;
        const sk = &m.sketches.items[ski].sketch;
        if (ci >= sk.connectors.items.len) return error.NoSuchItem;
        sketch_.connector.convert(sk, m.a(), ci, kind) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadValue,
        };
        _ = try sk.solve(m.arena.child_allocator);
        m.sketches.items[ski].version +%= 1;
        try m.syncSketchFigures(sketch);
        m.revision += 1;
    }

    /// The area fill `fill` covers in sketch `sk`, in `pattern`: exact
    /// contours (a hatch's lines as thin areas cut to it).
    fn fillRegion(al: std.mem.Allocator, sk: *const sketch_.Sketch, fill: figure_.Fill, pattern: figure_.Pattern) Error!geom.Outline {
        const Sk = sketch_.Sketch;
        const edge = try Sk.chain(al, try sk.segmentsOf(al, fill.geoms));
        if (edge.contours.len == 0) return .blank;
        var inputs: std.ArrayList(geom.Outline) = .empty;
        try inputs.append(al, .{ .contours = edge.contours });
        const box = (geom.Outline{ .contours = edge.contours }).bounds();
        // The holes: the closed paths of the rest of the sketch's bounded
        // geometry inside it (each circle a path of its own).
        if (!fill.enclosed) {
            var rest: std.ArrayList(geom.Segment) = .empty;
            var circles: std.ArrayList(geom.Contour) = .empty;
            for (sk.geometry.items, 0..) |g, gi| {
                if (g.removed or g.reference) continue;
                if (std.mem.indexOfScalar(u32, fill.geoms, @intCast(gi)) != null) continue;
                if (g.kind == .circle) {
                    var one: std.ArrayList(geom.Segment) = .empty;
                    try sk.appendSegments(al, g, &one);
                    try circles.append(al, .{ .segments = one.items });
                } else try sk.appendSegments(al, g, &rest);
            }
            const chained = try Sk.chain(al, rest.items);
            try circles.appendSlice(al, chained.contours);
            for (circles.items) |c| {
                if (c.segments.len == 0) continue;
                if (!insideContours(edge.contours, c.segments[0].at(0.5))) continue;
                try inputs.append(al, .{ .contours = try al.dupe(geom.Contour, &.{c}) });
            }
        }
        const holes = inputs.items.len - 1;
        switch (pattern) {
            .solid => {},
            .hatch => |h| {
                if (!(h.spacing > 0) or !(h.width > 0)) return .blank;
                // Strips across the box, at the angle, a spacing apart.
                const th = h.angle * std.math.pi / 180;
                const d: geom.Point = .{ .x = @cos(th), .y = @sin(th) };
                const n: geom.Point = .{ .x = -d.y, .y = d.x };
                const c: geom.Point = .{ .x = (box.x0 + box.x1) / 2, .y = (box.y0 + box.y1) / 2 };
                const half = std.math.hypot(box.x1 - box.x0, box.y1 - box.y0) / 2 + h.width;
                const count: usize = @intFromFloat(@min(4000, @ceil(half / h.spacing)));
                var strips: std.ArrayList(geom.Contour) = .empty;
                var k: isize = -@as(isize, @intCast(count));
                while (k <= @as(isize, @intCast(count))) : (k += 1) {
                    const o = @as(f64, @floatFromInt(k)) * h.spacing;
                    const lo = o - h.width / 2;
                    const hi = o + h.width / 2;
                    const P = struct {
                        fn p(cc: geom.Point, dd: geom.Point, nn: geom.Point, t: f64, s: f64) geom.Point {
                            return .{ .x = cc.x + dd.x * t + nn.x * s, .y = cc.y + dd.y * t + nn.y * s };
                        }
                    };
                    const q = [4]geom.Point{ P.p(c, d, n, -half, lo), P.p(c, d, n, half, lo), P.p(c, d, n, half, hi), P.p(c, d, n, -half, hi) };
                    const segs = try al.alloc(geom.Segment, 4);
                    for (0..4) |j| segs[j] = .{ .line = .{ q[j], q[(j + 1) % 4] } };
                    try strips.append(al, .{ .segments = segs });
                }
                try inputs.append(al, .{ .contours = strips.items });
            },
        }
        const R = struct {
            holes: usize,
            fn inside(ctx: *const anyopaque, in: []const bool) bool {
                const r: *const @This() = @ptrCast(@alignCast(ctx));
                if (!in[0]) return false;
                for (in[1 .. 1 + r.holes]) |x| if (x) return false;
                return in.len == 1 + r.holes or in[in.len - 1];
            }
        };
        const r: R = .{ .holes = holes };
        return geom.boolean.combine(al, inputs.items, .{ .ctx = &r, .inside = R.inside }) catch return error.OutOfMemory;
    }

    /// Whether `p` is inside `contours` (even-odd), their segments
    /// flattened finely.
    fn insideContours(contours: []const geom.Contour, p: geom.Point) bool {
        var in = false;
        for (contours) |c| for (c.segments) |sg| {
            var prev = sg.start();
            for (1..33) |i| {
                const q = sg.at(@as(f64, @floatFromInt(i)) / 32);
                if ((prev.y > p.y) != (q.y > p.y)) {
                    const x = prev.x + (p.y - prev.y) * (q.x - prev.x) / (q.y - prev.y);
                    if (x > p.x) in = !in;
                }
                prev = q;
            }
        };
        return in;
    }

    pub fn fillStyleIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.fill_styles.items, 0..) |st, i| if (st.id == id) return i;
        return null;
    }

    fn checkFill(st: FillStyle) Error!void {
        switch (st.pattern) {
            .solid => {},
            .hatch => |h| if (!(h.spacing > 0) or !(h.width > 0) or !std.math.isFinite(h.angle) or !(h.width < h.spacing) or !std.math.isFinite(h.spacing)) return error.BadValue,
        }
    }

    /// Adds a fill style; returns its ID.
    pub fn addFillStyle(m: *Model, style: FillStyle) Error!ObjectId {
        try checkFill(style);
        var st = style;
        st.id = m.newId();
        st.name = try m.a().dupe(u8, style.name);
        try m.fill_styles.append(m.a(), st);
        m.revision += 1;
        return st.id;
    }

    /// Changes fill style `id` (its name too): the fills in it follow.
    pub fn setFillStyle(m: *Model, id: ObjectId, style: FillStyle) Error!void {
        const i = m.fillStyleIndex(id) orelse return error.NoSuchStyle;
        try checkFill(style);
        var st = style;
        st.id = id;
        st.name = try m.a().dupe(u8, style.name);
        m.fill_styles.items[i] = st;
        try m.syncSketchFigures(.none);
        m.revision += 1;
    }

    /// Makes fill style `id` the one new fills take.
    pub fn setCurrentFill(m: *Model, id: ObjectId) Error!void {
        if (m.fillStyleIndex(id) == null) return error.NoSuchStyle;
        m.current_fill = id;
        m.revision += 1;
    }

    /// The fill style new fills take: the current one, else the first.
    pub fn currentFill(m: *const Model) ?ObjectId {
        if (m.fillStyleIndex(m.current_fill) != null) return m.current_fill;
        return if (m.fill_styles.items.len > 0) m.fill_styles.items[0].id else null;
    }

    /// The fill style new fills take, made (a 45° hatch, meaning a
    /// cutout) when the document has none.
    fn fillStyleForNew(m: *Model) Error!ObjectId {
        if (m.currentFill()) |id| return id;
        const id = try m.addFillStyle(.{ .name = "Hatch 45°", .color = .{ .r = 0, .g = 0, .b = 0 }, .pattern = .{ .hatch = .{} }, .cutout = true });
        m.current_fill = id;
        return id;
    }

    /// `setInk` as a draft (the sketch editor's): the change shows in the
    /// editor, and reaches the drawing's uses only when the sketch is
    /// accepted (`acceptSketch`); discarded with its draft.
    pub fn setInkDraft(m: *Model, index: usize, g: u32, on: bool) Error!void {
        const fi = try m.beginMarksDraft(index);
        const kept = m.swapMarks(fi);
        errdefer _ = m.swapMarks(fi);
        try m.setInk(index, g, on);
        m.endMarksDraft(fi, kept);
        try m.syncSketchFigures(m.sketches.items[index].id);
    }

    /// `setFill` as a draft (see `setInkDraft`).
    pub fn setFillDraft(m: *Model, index: usize, geoms: []const u32, enclosed: bool, on: bool) Error!void {
        const fi = try m.beginMarksDraft(index);
        const kept = m.swapMarks(fi);
        errdefer _ = m.swapMarks(fi);
        try m.setFill(index, geoms, enclosed, on);
        m.endMarksDraft(fi, kept);
        try m.syncSketchFigures(m.sketches.items[index].id);
    }

    /// Opens sketch `index`'s draft for its drawing's marks: the sketch
    /// kept as accepted (as `editSketchDraft` does), the drawing made if
    /// it has none, its pending marks started from its own. The figure's
    /// index.
    fn beginMarksDraft(m: *Model, index: usize) Error!usize {
        const it = try m.sketchAt(index);
        if (it.accepted == null) it.accepted = try it.sketch.clone(m.a());
        const fi = (try m.sketchFigureFor(index, true)).?;
        const f = &m.figures.items[fi];
        if (f.pending == null) f.pending = .{ .inks = f.inks, .fills = f.fills };
        return fi;
    }

    /// Puts figure `fi`'s pending marks in its own place, for the plain
    /// edit to work on; returns the marks it had (to put back).
    fn swapMarks(m: *Model, fi: usize) figure_.Marks {
        const f = &m.figures.items[fi];
        const own: figure_.Marks = .{ .inks = f.inks, .fills = f.fills };
        const p = f.pending orelse return own;
        f.inks = p.inks;
        f.fills = p.fills;
        f.pending = own;
        return own;
    }

    /// After the plain edit: its result pending, the figure's own marks back.
    fn endMarksDraft(m: *Model, fi: usize, kept: figure_.Marks) void {
        const f = &m.figures.items[fi];
        f.pending = .{ .inks = f.inks, .fills = f.fills };
        f.inks = kept.inks;
        f.fills = kept.fills;
    }

    /// Fills the area geometry `geoms` of sketch `index` closes, in the
    /// current fill style, its enclosed paths filled too or left out
    /// (`enclosed`); with `on` false, takes off the fill of that boundary.
    /// A fill of the same boundary is replaced.
    pub fn setFill(m: *Model, index: usize, geoms: []const u32, enclosed: bool, on: bool) Error!void {
        const item = try m.sketchAt(index);
        if (geoms.len == 0) return error.NoSuchItem;
        for (geoms) |g| if (g >= item.sketch.geometry.items.len or item.sketch.geometry.items[g].removed) return error.NoSuchItem;
        // The boundary must close.
        {
            var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
            defer scratch.deinit();
            const ch = try sketch_.Sketch.chain(scratch.allocator(), try item.sketch.segmentsOf(scratch.allocator(), geoms));
            if (on and (ch.contours.len == 0 or ch.open > 0)) return error.NotEnclosed;
        }
        const sorted = try m.a().dupe(u32, geoms);
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        const fi = try m.sketchFigureFor(index, on) orelse return;
        const f = &m.figures.items[fi];
        var fills: std.ArrayList(figure_.Fill) = .empty;
        var replaced = false;
        for (f.fills) |k| {
            if (!std.mem.eql(u32, k.geoms, sorted)) {
                try fills.append(m.a(), k);
            } else if (on) {
                // In its place, the current style taken.
                try fills.append(m.a(), .{ .geoms = sorted, .style = try m.fillStyleForNew(), .enclosed = enclosed });
                replaced = true;
            }
        }
        if (on and !replaced) try fills.append(m.a(), .{ .geoms = sorted, .style = try m.fillStyleForNew(), .enclosed = enclosed });
        f.fills = fills.items;
        try m.syncSketchFigures(item.id);
        m.revision += 1;
    }

    /// The figure over sketch `index`, made when it has none and `make`.
    fn sketchFigureFor(m: *Model, index: usize, make: bool) Error!?usize {
        const item = try m.sketchAt(index);
        if (m.sketchFigure(item.id)) |fi| return fi;
        if (!make) return null;
        var name_buf: [64]u8 = undefined;
        const base = std.fmt.bufPrint(&name_buf, "{s} figure", .{item.name}) catch "Figure";
        var buf2: [80]u8 = undefined;
        const name = m.freshName(&buf2, .figures, base);
        try m.figures.append(m.a(), .{ .id = m.newId(), .name = try m.a().dupe(u8, name), .paths = &.{}, .sketch = item.id });
        return m.figures.items.len - 1;
    }

    /// The stroke style new ink takes, made (a fine black pen) when the
    /// document has none.
    fn inkStyle(m: *Model) Error!ObjectId {
        if (m.currentStroke()) |id| return id;
        const id = try m.addStrokeStyle("Pen", .{ .color = .{ .r = 0, .g = 0, .b = 0 }, .width = 0.3, .cap = .round, .join = .round });
        m.current_stroke = id;
        return id;
    }

    /// Inks geometry `g` of sketch `index` in the current stroke style
    /// (`on`), or takes its ink off. The sketch's figure is made when it
    /// has none.
    pub fn setInk(m: *Model, index: usize, g: u32, on: bool) Error!void {
        const item = try m.sketchAt(index);
        if (g >= item.sketch.geometry.items.len or item.sketch.geometry.items[g].removed) return error.NoSuchItem;
        const fi = try m.sketchFigureFor(index, on) orelse return;
        const f = &m.figures.items[fi];
        var inks: std.ArrayList(figure_.Ink) = .empty;
        for (f.inks) |k| if (k.geom != g) try inks.append(m.a(), k);
        if (on) try inks.append(m.a(), .{ .geom = g, .style = try m.inkStyle() });
        f.inks = inks.items;
        try m.syncSketchFigures(item.id);
        m.revision += 1;
    }

    pub fn strokeStyleIndex(m: *const Model, id: ObjectId) ?usize {
        for (m.stroke_styles.items, 0..) |st, i| if (st.id == id) return i;
        return null;
    }

    fn checkStroke(st: figure_.Stroke) Error!void {
        if (!(st.width > 0) or !std.math.isFinite(st.width) or !(st.miter_limit >= 1)) return error.BadValue;
        for (st.dash) |d| if (!(d >= 0) or !std.math.isFinite(d)) return error.BadValue;
        if (!std.math.isFinite(st.dash_offset)) return error.BadValue;
    }

    /// A stroke with its dash pattern in the model's memory.
    fn ownStroke(m: *Model, st: figure_.Stroke) Error!figure_.Stroke {
        var o = st;
        o.dash = try m.a().dupe(f64, st.dash);
        return o;
    }

    /// Adds a stroke style; returns its ID.
    pub fn addStrokeStyle(m: *Model, name: []const u8, stroke: figure_.Stroke) Error!ObjectId {
        try checkStroke(stroke);
        const id = m.newId();
        try m.stroke_styles.append(m.a(), .{ .id = id, .name = try m.a().dupe(u8, name), .stroke = try m.ownStroke(stroke) });
        m.revision += 1;
        return id;
    }

    /// Changes stroke style `id` (its name too): the ink in it follows.
    pub fn setStrokeStyle(m: *Model, id: ObjectId, name: []const u8, stroke: figure_.Stroke) Error!void {
        const i = m.strokeStyleIndex(id) orelse return error.NoSuchStyle;
        try checkStroke(stroke);
        m.stroke_styles.items[i] = .{ .id = id, .name = try m.a().dupe(u8, name), .stroke = try m.ownStroke(stroke) };
        try m.syncSketchFigures(.none);
        m.revision += 1;
    }

    /// Makes stroke style `id` the one new ink takes.
    pub fn setCurrentStroke(m: *Model, id: ObjectId) Error!void {
        if (m.strokeStyleIndex(id) == null) return error.NoSuchStyle;
        m.current_stroke = id;
        m.revision += 1;
    }

    /// The stroke style new ink takes: the current one, else the first;
    /// null when there is none.
    pub fn currentStroke(m: *const Model) ?ObjectId {
        if (m.strokeStyleIndex(m.current_stroke) != null) return m.current_stroke;
        return if (m.stroke_styles.items.len > 0) m.stroke_styles.items[0].id else null;
    }

    /// A new paragraph style. Returns its ID.
    pub fn addParagraphStyle(m: *Model, style: ParagraphStyle) Error!ParaId {
        try checkParagraph(style);
        var s = style;
        s.name = try m.a().dupe(u8, style.name);
        s.id = m.newId();
        try m.paragraph_styles.append(m.a(), s);
        m.revision += 1;
        return s.id;
    }

    /// Changes paragraph style `id` (its name too): every paragraph in it
    /// follows.
    pub fn setParagraphStyle(m: *Model, id: ParaId, style: ParagraphStyle) Error!void {
        const i = m.paraIndex(id) orelse return error.NoSuchStyle;
        try checkParagraph(style);
        var s = style;
        s.name = try m.a().dupe(u8, style.name);
        s.id = id;
        m.paragraph_styles.items[i] = s;
        m.revision += 1;
    }

    /// A copy of text style `id` named `name`: its size, base, faces and
    /// rules, its own from now on.
    pub fn copyStyle(m: *Model, id: StyleId, name: []const u8) Error!StyleId {
        const src = m.textStyle(id).*;
        const nid = m.newId();
        var st: TextStyle = .{ .id = nid, .name = try m.a().dupe(u8, name), .base = src.base, .cap_height = src.cap_height, .em_size = src.em_size, .line_pitch = src.line_pitch };
        try st.faces.appendSlice(m.a(), src.faces.items);
        try st.rules.appendSlice(m.a(), src.rules.items);
        try m.styles.append(m.a(), st);
        m.revision += 1;
        return nid;
    }

    /// A copy of paragraph style `id` named `name`.
    pub fn copyParagraphStyle(m: *Model, id: ParaId, name: []const u8) Error!ParaId {
        var ps = (m.paraStyle(id) orelse return error.NoSuchStyle).*;
        ps.name = name;
        return m.addParagraphStyle(ps);
    }

    /// A new style template holding text style `text`, paragraph style
    /// `paragraph` and leading `leading`. Returns its ID.
    pub fn addStyleTemplate(m: *Model, name: []const u8, text: StyleId, paragraph: ?ParaId, leading: ?Leading) Error!ObjectId {
        if (m.styleIndex(text) == null) return error.NoSuchStyle;
        if (paragraph) |p| if (m.paraIndex(p) == null) return error.NoSuchStyle;
        const id = m.newId();
        try m.templates.append(m.a(), .{ .id = id, .name = try m.a().dupe(u8, name), .text = text, .paragraph = paragraph, .leading = leading });
        m.revision += 1;
        return id;
    }

    /// A new text style based on `base` (its faces and rules come from
    /// it) at its size, named `name`: an override of it.
    pub fn deriveStyle(m: *Model, base: StyleId, name: []const u8) Error!StyleId {
        const src = m.textStyle(base).*;
        const nid = m.newId();
        try m.styles.append(m.a(), .{ .id = nid, .name = try m.a().dupe(u8, name), .base = base, .cap_height = src.cap_height, .em_size = src.em_size, .line_pitch = src.line_pitch });
        m.revision += 1;
        return nid;
    }

    /// Sets style template `id`'s leading (null: its font's own).
    pub fn setTemplateLeading(m: *Model, id: ObjectId, leading: ?Leading) Error!void {
        const t = m.styleTemplate(id) orelse return error.NoSuchObject;
        t.leading = leading;
        m.revision += 1;
    }

    /// The leading flow `f` comes to: its own, else its template's.
    pub fn flowLeading(m: *const Model, f: *const Flow) ?Leading {
        if (f.leading) |l| return l;
        if (m.styleTemplate(f.template)) |t| return t.leading;
        return null;
    }

    /// Renames style template `id`.
    pub fn renameStyleTemplate(m: *Model, id: ObjectId, name: []const u8) Error!void {
        const t = m.styleTemplate(id) orelse return error.NoSuchObject;
        t.name = try m.a().dupe(u8, name);
        m.revision += 1;
    }

    /// Style template `id`, if it is one.
    pub fn styleTemplate(m: *const Model, id: ObjectId) ?*StyleTemplate {
        for (m.templates.items) |*t| if (t.id == id) return t;
        return null;
    }

    /// Sets flow `id`'s style: its text style, the paragraph settings its
    /// paragraphs in no style take, its leading, and the template it came
    /// from. Its runs in its old text style move to the new one.
    pub fn setFlowStyle(m: *Model, id: ObjectId, text: StyleId, paragraph: ?ParaId, leading: ?Leading, template: ObjectId) Error!void {
        const fi = m.flowIndex(id) orelse return error.NoSuchObject;
        if (m.styleIndex(text) == null) return error.NoSuchStyle;
        if (paragraph) |p| if (m.paraIndex(p) == null) return error.NoSuchStyle;
        const f = &m.flows.items[fi];
        const old = f.style;
        if (old != .none and old != text) for (f.items.items) |*it| switch (it.what) {
            .run => |*r| if (r.style == old) {
                r.style = text;
            },
            else => {},
        };
        f.style = text;
        // Its tracks take it for new runs.
        for (f.tracks.items) |tid| if (m.trackById(tid)) |tr| {
            const rg = &m.regionsIn(tr.parent)[tr.region];
            if (rg.style != null) rg.style = text;
        };
        f.paragraph_default = paragraph;
        f.leading = leading;
        f.template = template;
        m.revision += 1;
    }

    /// The first "Paragraph N" no paragraph style uses yet.
    pub fn nextParagraphStyleName(m: *const Model, buf: []u8) []const u8 {
        return m.freshName(buf, .paragraph_styles, "Paragraph");
    }

    /// Inserts a paragraph separator at position `index` of a track: the
    /// paragraph before it ends, and the one after it is set in `style`
    /// (null: the track's).
    pub fn insertParagraph(m: *Model, parent: Parent, region: usize, index: usize, style: ?ParaId) Error!void {
        if (style) |id| if (m.paraIndex(id) == null) return error.NoSuchStyle;
        try m.place(parent, region, index, .{ .what = .{ .paragraph = style } });
    }

    /// Where the paragraph holding item `index` of a track takes its
    /// style from: the separator before it, or (null) the track.
    pub fn paragraphStart(m: *const Model, parent: Parent, region: usize, index: usize) ?usize {
        const items = m.flowItems(parent, region);
        var k = @min(index, items.len);
        while (k > 0) {
            k -= 1;
            if (items[k].what == .paragraph) return k;
        }
        return null;
    }

    /// The paragraph style of the paragraph holding item `index`.
    pub fn paragraphStyleAt(m: *const Model, parent: Parent, region: usize, index: usize) ?ParaId {
        const f = m.trackFlow(parent, region) orelse return null;
        const k = m.paragraphStart(parent, region, index) orelse return f.paragraph;
        return f.items.items[k].what.paragraph;
    }

    /// Sets the paragraph style of the paragraph holding item `index`
    /// (null: none), at its separator or, for the first, on the track.
    pub fn setParagraphAt(m: *Model, parent: Parent, region: usize, index: usize, style: ?ParaId) Error!void {
        if (style) |id| if (m.paraIndex(id) == null) return error.NoSuchStyle;
        const f = m.flowOf(parent, region);
        if (m.paragraphStart(parent, region, index)) |k| {
            f.items.items[k].what = .{ .paragraph = style };
        } else f.paragraph = style;
        m.revision += 1;
    }

    /// Joins item `index` of a track to the next one, or parts them: with
    /// `bind`, no break falls between them, so they move as one group.
    pub fn setBind(m: *Model, parent: Parent, region: usize, index: usize, bind: bool) Error!void {
        const items = m.flow(parent, region).items;
        if (index + 1 >= items.len) return error.NoSuchItem;
        items[index].bind = bind;
        m.revision += 1;
    }

    /// Sets the gap before flow item `index`, u (in its track's pitch).
    pub fn setItemGap(m: *Model, parent: Parent, region: usize, index: usize, gap: f64) Error!void {
        if (!(gap >= 0)) return error.BadSize;
        const items = m.flow(parent, region).items;
        if (index >= items.len) return error.NoSuchItem;
        items[index].gap = gap;
        m.revision += 1;
    }

    /// Renames track `region` of `panel`.
    pub fn renameRegion(m: *Model, parent: Parent, region: usize, name: []const u8) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchItem;
        if (name.len == 0) return error.BadValue;
        m.regionsIn(parent)[region].name = try m.a().dupe(u8, name);
        m.revision += 1;
    }

    /// Names the keys of the flow track `region` of `panel` is in, in flow
    /// order, `prefix`1, `prefix`2 … (spacers left out). Refused, changing
    /// nothing, when a name would be another key's elsewhere.
    pub fn nameKeysInOrder(m: *Model, parent: Parent, region: usize, prefix: []const u8) Error!usize {
        if (prefix.len == 0) return error.BadValue;
        const al = m.arena.child_allocator;
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        for (m.flowItems(parent, region)) |item| if (item.tileOf()) |t| {
            if (m.tileConst(t).removed or m.proto(m.tileConst(t).prototype).spacer) continue;
            try keys.append(al, t);
        };
        var buf: [64]u8 = undefined;
        for (keys.items, 1..) |_, n| {
            const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, n }) catch return error.BadValue;
            if (m.findTile(name)) |other| if (std.mem.indexOfScalar(TileId, keys.items, other) == null) return error.DuplicateDesignator;
        }
        for (keys.items, 1..) |t, n| {
            const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, n }) catch unreachable;
            m.tile(t).designator = try m.a().dupe(u8, name);
        }
        m.revision += 1;
        return keys.items.len;
    }

    /// Names the keys of every flow placed on panel `panel` "<prefix>1",
    /// "<prefix>2" …: its tracks in order, each flow's keys in flow order
    /// (a flow once, from the first of its tracks on the panel), spacers
    /// left out. So a panel of one flow a row is named as one flow through
    /// them all would be. A name that is another key's elsewhere names
    /// none. The count named.
    pub fn nameKeysInPanel(m: *Model, parent: Parent, prefix: []const u8) Error!usize {
        if (prefix.len == 0) return error.BadValue;
        const al = m.arena.child_allocator;
        var keys: std.ArrayList(TileId) = .empty;
        defer keys.deinit(al);
        var seen: std.ArrayList(ObjectId) = .empty;
        defer seen.deinit(al);
        for (m.regionsIn(parent), 0..) |_, ri| {
            const f = m.trackFlow(parent, ri);
            if (f) |fl| {
                if (std.mem.indexOfScalar(ObjectId, seen.items, fl.id) != null) continue;
                try seen.append(al, fl.id);
            }
            for (m.flowItems(parent, ri)) |item| if (item.tileOf()) |t| {
                if (m.tileConst(t).removed or m.proto(m.tileConst(t).prototype).spacer) continue;
                try keys.append(al, t);
            };
        }
        var buf: [64]u8 = undefined;
        for (keys.items, 1..) |_, n| {
            const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, n }) catch return error.BadValue;
            if (m.findTile(name)) |other| if (std.mem.indexOfScalar(TileId, keys.items, other) == null) return error.DuplicateDesignator;
        }
        for (keys.items, 1..) |t, n| {
            const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, n }) catch unreachable;
            m.tile(t).designator = try m.a().dupe(u8, name);
        }
        m.revision += 1;
        return keys.items.len;
    }

    /// The index in `panel` of the track with ID `id`.
    pub fn regionIndex(m: *const Model, parent: Parent, id: ObjectId) ?usize {
        if (id == .none) return null;
        for (m.regionsIn(parent), 0..) |r, k| if (r.id == id) return k;
        return null;
    }

    /// The track with ID `id`, on whichever panel.
    pub fn trackById(m: *const Model, id: ObjectId) ?TrackRef {
        if (id == .none) return null;
        for (0..m.parentCount()) |i| {
            const parent = m.parentAt(i);
            for (m.regionsIn(parent), 0..) |r, k| if (r.id == id) return .{ .parent = parent, .region = k };
        }
        return null;
    }

    /// Where track `region` of `panel` comes in its flow's list, if it is
    /// in it.
    fn flowPosition(m: *const Model, parent: Parent, region: usize) ?usize {
        const f = m.trackFlow(parent, region) orelse return null;
        const id = m.regionsIn(parent)[region].id;
        for (f.tracks.items, 0..) |t, k| if (t == id) return k;
        return null;
    }

    /// The track before track `region` of `panel` in its flow (whose
    /// content goes on into it), on whichever panel, if any.
    pub fn threadBefore(m: *const Model, parent: Parent, region: usize) ?TrackRef {
        const f = m.trackFlow(parent, region) orelse return null;
        var k = m.flowPosition(parent, region) orelse return null;
        while (k > 0) {
            k -= 1;
            if (m.trackById(f.tracks.items[k])) |t| return t;
        }
        return null;
    }

    /// The track after track `region` of `panel` in its flow (its content
    /// goes on into it once this one is full), if any.
    pub fn threadAfter(m: *const Model, parent: Parent, region: usize) ?TrackRef {
        const f = m.trackFlow(parent, region) orelse return null;
        const k = m.flowPosition(parent, region) orelse return null;
        for (f.tracks.items[k + 1 ..]) |id| if (m.trackById(id)) |t| return t;
        return null;
    }

    /// The first track of track `region`'s flow (itself when it is the
    /// first, or in none).
    pub fn threadHead(m: *const Model, parent: Parent, region: usize) TrackRef {
        const f = m.trackFlow(parent, region) orelse return .{ .parent = parent, .region = region };
        for (f.tracks.items) |id| if (m.trackById(id)) |t| return t;
        return .{ .parent = parent, .region = region };
    }

    /// The tracks of the flow track `head` is in, in order, into `buf`.
    pub fn thread(m: *const Model, head: TrackRef, buf: []TrackRef) []TrackRef {
        const f = m.trackFlow(head.parent, head.region) orelse {
            if (buf.len == 0) return buf[0..0];
            buf[0] = head;
            return buf[0..1];
        };
        var n: usize = 0;
        for (f.tracks.items) |id| {
            if (n >= buf.len) break;
            const t = m.trackById(id) orelse continue;
            buf[n] = t;
            n += 1;
        }
        return buf[0..n];
    }

    fn trackPtr(m: *Model, t: TrackRef) *TileRegion {
        return &m.regionsIn(t.parent)[t.region];
    }

    /// Joins track `to` after track `from`, on one panel (see
    /// `threadTracks`).
    pub fn joinTracks(m: *Model, parent: Parent, from: usize, to: usize) Error!void {
        return m.threadTracks(parent, from, parent, to);
    }

    /// Joins track `to` (of `to_panel`) after track `from` (of
    /// `from_panel`): the flow of `from`'s thread goes on into `to` (and
    /// the thread `to` starts, if it starts one) before whatever followed
    /// `from`, on this panel or another. What `to`'s thread held is added
    /// to the end of the flow, as a new paragraph. Both must run the same
    /// way, and `to` must start its thread and not be in `from`'s.
    pub fn threadTracks(m: *Model, from_parent: Parent, from: usize, to_parent: Parent, to: usize) Error!void {
        if (!m.hasParent(from_parent) or !m.hasParent(to_parent)) return error.NoSuchRow;
        if (from >= m.regionsIn(from_parent).len or to >= m.regionsIn(to_parent).len) return error.NoSuchRow;
        const f: TrackRef = .{ .parent = from_parent, .region = from };
        const t: TrackRef = .{ .parent = to_parent, .region = to };
        if (m.trackPtr(f).major() != m.trackPtr(t).major()) return error.BadJoin;
        if (m.threadBefore(to_parent, to) != null) return error.BadJoin;
        const fi = m.trackFlowIndex(from_parent, from) orelse return error.BadJoin;
        const gi = m.trackFlowIndex(to_parent, to) orelse return error.BadJoin;
        if (fi == gi) return error.BadJoin;
        // `to`'s flow's tracks go in after `from`, its content after the
        // flow's, as a new paragraph; its flow goes.
        const at = (m.flowPosition(from_parent, from) orelse return error.BadJoin) + 1;
        const g = m.flows.items[gi];
        const into = &m.flows.items[fi];
        try into.tracks.insertSlice(m.a(), at, g.tracks.items);
        if (g.items.items.len > 0) {
            if (into.items.items.len > 0) try into.items.append(m.a(), .{ .what = .{ .paragraph = g.paragraph } });
            try into.items.appendSlice(m.a(), g.items.items);
        }
        const fid = into.id;
        for (g.tracks.items) |id| if (m.trackById(id)) |tr| {
            m.trackPtr(tr).flow = fid;
        };
        _ = m.flows.orderedRemove(gi);
        m.revision += 1;
    }

    /// Takes track `region` out of its thread: the tracks either side are
    /// joined, and the flow stays whole on the thread (on the next track
    /// when `region` held it); what no longer fits overflows the last.
    pub fn unjoinTrack(m: *Model, parent: Parent, region: usize) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchRow;
        const before = m.threadBefore(parent, region);
        const after = m.threadAfter(parent, region);
        if (before == null and after == null) return error.BadJoin;
        // Its flow keeps the content (starting in the next track, when it
        // started in this one); the track gets a flow of its own, empty.
        const fi = m.trackFlowIndex(parent, region).?;
        const k = m.flowPosition(parent, region).?;
        _ = m.flows.items[fi].tracks.orderedRemove(k);
        const indent = m.flows.items[fi].indent;
        const r = &m.regionsIn(parent)[region];
        const ni = try m.newFlow(r.name, r.id);
        m.flows.items[ni].indent = indent;
        m.regionsIn(parent)[region].flow = m.flows.items[ni].id;
        m.revision += 1;
    }

    /// Sets how a track's segments hold their content: its alignment, the
    /// indent after hard breaks (u), and the gap between segments the path
    /// continues to (u).
    pub fn setTrackFlow(m: *Model, parent: Parent, region: usize, alignment: Align, indent: f64, gap: f64) Error!void {
        if (!(indent >= 0) or !(gap >= 0)) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        r.alignment = alignment;
        r.gap = gap;
        m.flowOf(parent, region).indent = indent;
        m.revision += 1;
    }

    /// Inserts a run of markup (text, an equation, or both) at position
    /// `index` of a track.
    pub fn insertRun(m: *Model, parent: Parent, region: usize, index: usize, run: Run) Error!void {
        try m.place(parent, region, index, .{ .what = .{ .run = run } });
    }

    /// Sets the markup of the run at position `index` of a track.
    pub fn setRunContent(m: *Model, parent: Parent, region: usize, index: usize, content: []const u8) Error!void {
        const items = m.flow(parent, region).items;
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

    fn runAt(m: *Model, parent: Parent, region: usize, index: usize) ?*Run {
        const items = m.flow(parent, region).items;
        if (index >= items.len or items[index].what != .run) return null;
        return &items[index].what.run;
    }

    /// Types plain `text` in at `at` (newlines break paragraphs): into the
    /// run there, else onto the end of the run before, else as a new run in
    /// `style`. Returns the place after it.
    pub fn insertText(m: *Model, parent: Parent, region: usize, at: FlowPos, text: []const u8, style: StyleId) Error!FlowPos {
        var pos = at;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line_raw| {
            if (!first) pos = try m.breakAt(parent, region, pos, true);
            first = false;
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
            defer scratch.deinit();
            const esc = try edit_.escape(scratch.allocator(), line);
            const items = m.flow(parent, region).items;
            if (pos.index > items.len) return error.NoSuchItem;
            const here = m.runAt(parent, region, pos.index);
            const before = if (pos.index > 0) m.runAt(parent, region, pos.index - 1) else null;
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
                try m.place(parent, region, pos.index, .{ .what = .{ .run = .{ .style = style, .content = try m.a().dupe(u8, esc) } } });
                pos = .{ .index = pos.index + 1 };
            }
            // At the end of a run: the place before what follows it.
            if (m.runAt(parent, region, pos.index)) |r| if (pos.offset >= r.content.len) {
                pos = .{ .index = pos.index + 1 };
            };
        }
        m.revision += 1;
        return pos;
    }

    /// Deletes what lies between `from` and `to` (either way round): the
    /// characters of the runs at either end, and every item between; runs
    /// left side by side in one style are joined. Returns where it was.
    pub fn deleteRange(m: *Model, parent: Parent, region: usize, from: FlowPos, to: FlowPos) Error!FlowPos {
        var f = from;
        var t = to;
        if (t.index < f.index or (t.index == f.index and t.offset < f.offset)) std.mem.swap(FlowPos, &f, &t);
        var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const len = m.flow(parent, region).items.len;
        if (f.index > len or t.index > len) return error.NoSuchItem;
        if (f.index == t.index) {
            if (m.runAt(parent, region, f.index)) |r| if (t.offset > f.offset) {
                r.content = try m.a().dupe(u8, try edit_.deleteChars(sa, r.content, f.offset, t.offset, r.equation));
                // Nothing left of it: it goes.
                if (!try edit_.hasChars(sa, r.content, r.equation)) {
                    try m.removeAt(parent, region, f.index);
                    f.offset = 0;
                }
            };
            m.revision += 1;
            return f;
        }
        // The start of the run the range ends in.
        if (t.offset > 0) if (m.runAt(parent, region, t.index)) |r| {
            r.content = try m.a().dupe(u8, try edit_.deleteChars(sa, r.content, 0, t.offset, r.equation));
        };
        // The end of the run it starts in.
        var keep = f.index;
        if (f.offset > 0) if (m.runAt(parent, region, f.index)) |r| {
            r.content = try m.a().dupe(u8, try edit_.deleteChars(sa, r.content, f.offset, @intCast(r.content.len), r.equation));
            keep = f.index + 1;
        };
        // Every item between.
        var k = t.index;
        while (k > keep) {
            k -= 1;
            try m.removeAt(parent, region, k);
        }
        var result: FlowPos = if (f.offset > 0) f else .{ .index = keep };
        // Runs left side by side, in one style: one run.
        if (keep > 0) if (m.runAt(parent, region, keep - 1)) |a_run| if (m.runAt(parent, region, keep)) |b_run| {
            if (a_run.style == b_run.style and !a_run.equation and !b_run.equation) {
                const joined_at: u32 = @intCast(a_run.content.len);
                a_run.content = try std.mem.concat(m.a(), u8, &.{ a_run.content, b_run.content });
                try m.removeAt(parent, region, keep);
                if (f.offset == 0) result = .{ .index = keep - 1, .offset = joined_at };
            }
        };
        // A run left with nothing in it goes.
        if (m.runAt(parent, region, result.index)) |r| if (!try edit_.hasChars(sa, r.content, r.equation)) {
            try m.removeAt(parent, region, result.index);
            result.offset = 0;
        };
        if (m.runAt(parent, region, result.index)) |r| if (result.offset >= r.content.len and result.offset > 0) {
            result = .{ .index = result.index + 1 };
        };
        m.revision += 1;
        return result;
    }

    /// Puts a new, empty equation at `at`, in `style`: inside a run of text
    /// the run is split there (its markup kept whole); inside an
    /// equation's structure, or in an equation, it goes after that run.
    /// Returns the equation's index.
    pub fn insertEquation(m: *Model, parent: Parent, region: usize, at: FlowPos, style: StyleId) Error!usize {
        var index = at.index;
        if (index > m.flow(parent, region).items.len) return error.NoSuchItem;
        if (at.offset > 0) if (m.runAt(parent, region, at.index)) |r| {
            index = at.index + 1;
            if (at.offset < r.content.len and !r.equation) {
                var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
                defer scratch.deinit();
                if (try edit_.splitAt(scratch.allocator(), r.content, at.offset)) |parts| {
                    const rs = r.style;
                    r.content = try m.a().dupe(u8, parts[0]);
                    try m.place(parent, region, index, .{ .what = .{ .run = .{ .style = rs, .content = try m.a().dupe(u8, parts[1]) } } });
                }
            }
        };
        try m.place(parent, region, index, .{ .what = .{ .run = .{ .style = style, .content = "", .equation = true } } });
        m.revision += 1;
        return index;
    }

    /// Breaks the flow at `at`: a new paragraph (in the style of the one
    /// it splits) or a line break. Inside a run the run is split, its
    /// markup kept whole; inside an equation's structure the break goes
    /// after the run. Returns the place after the break.
    /// The style a paragraph begun at item `index` of a track takes: the
    /// one it splits, or, begun at that one's end, its next (FrameMaker's
    /// Next ¶ Tag); null for the flow's own.
    pub fn paragraphStyleAfter(m: *Model, parent: Parent, region: usize, index: usize) ?ParaId {
        const here = m.paragraphStyleAt(parent, region, index);
        const f = m.trackFlow(parent, region) orelse return here;
        const items = f.items.items;
        const at_end = index >= items.len or items[index].what == .paragraph;
        if (!at_end) return here;
        const eff = here orelse f.paragraph_default orelse return here;
        const next = (m.paraStyle(eff) orelse return here).next orelse return here;
        return if (next == f.paragraph_default) null else next;
    }

    /// Adds an empty case named `name`; its ID.
    pub fn addCase(m: *Model, name: []const u8) Error!ObjectId {
        const id = m.newId();
        try m.cases.append(m.a(), .{ .id = id, .name = try m.a().dupe(u8, name) });
        m.revision += 1;
        return id;
    }

    /// Puts `sort` (null: none) on key `key` of case `id`, its lower or
    /// upper case.
    pub fn setCaseKey(m: *Model, id: ObjectId, key: keyboard.Key, upper: bool, sort: ?Sort) Error!void {
        const c = for (m.cases.items) |*c| {
            if (c.id == id) break c;
        } else return error.NoSuchObject;
        var s = sort;
        if (s) |*v| if (v.* == .text) {
            v.text = try m.a().dupe(u8, v.text);
        };
        var keys = try m.a().alloc(CaseKey, c.keys.len + 1);
        @memcpy(keys[0..c.keys.len], c.keys);
        var n = c.keys.len;
        const at = for (keys[0..n], 0..) |k, i| {
            if (k.key.eql(key)) break i;
        } else blk: {
            keys[n] = .{ .key = key };
            n += 1;
            break :blk n - 1;
        };
        if (upper) keys[at].upper = s else keys[at].lower = s;
        c.keys = keys[0..n];
        m.revision += 1;
    }

    /// Splits the run at `at` when `at` is inside one: where an item put
    /// in at `at` goes (the index after the run, or `at`'s own).
    pub fn splitAt(m: *Model, parent: Parent, region: usize, at: FlowPos) Error!usize {
        if (at.offset == 0) return at.index;
        const r = m.runAt(parent, region, at.index) orelse return at.index;
        if (at.offset < r.content.len) {
            var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
            defer scratch.deinit();
            if (try edit_.splitAt(scratch.allocator(), r.content, at.offset)) |parts| {
                const style = r.style;
                r.content = try m.a().dupe(u8, parts[0]);
                try m.place(parent, region, at.index + 1, .{ .what = .{ .run = .{ .style = style, .content = try m.a().dupe(u8, parts[1]) } } });
            }
        }
        return at.index + 1;
    }

    pub fn breakAt(m: *Model, parent: Parent, region: usize, at: FlowPos, paragraph: bool) Error!FlowPos {
        var index = at.index;
        if (at.offset > 0) if (m.runAt(parent, region, at.index)) |r| {
            index = at.index + 1;
            if (at.offset < r.content.len) {
                var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
                defer scratch.deinit();
                if (try edit_.splitAt(scratch.allocator(), r.content, at.offset)) |parts| {
                    const style = r.style;
                    r.content = try m.a().dupe(u8, parts[0]);
                    try m.place(parent, region, index, .{ .what = .{ .run = .{ .style = style, .content = try m.a().dupe(u8, parts[1]) } } });
                }
            }
        };
        if (paragraph) {
            const style = m.paragraphStyleAfter(parent, region, index);
            try m.insertParagraph(parent, region, index, style);
            return .{ .index = index + 1 };
        }
        const n = try m.insertBreak(parent, region, index);
        return .{ .index = index + n };
    }

    /// The plain text between `from` and `to` (either way round): the
    /// characters of runs, a newline for each break or paragraph.
    pub fn flowText(m: *Model, gpa: Allocator, parent: Parent, region: usize, from: FlowPos, to: FlowPos) Error![]u8 {
        var f = from;
        var t = to;
        if (t.index < f.index or (t.index == f.index and t.offset < f.offset)) std.mem.swap(FlowPos, &f, &t);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var out: std.ArrayList(u8) = .empty;
        const items = m.flow(parent, region).items;
        var k = f.index;
        while (k <= t.index and k < items.len) : (k += 1) {
            const lo: u32 = if (k == f.index) f.offset else 0;
            switch (items[k].what) {
                .run => |r| {
                    const hi: u32 = if (k == t.index) t.offset else @intCast(r.content.len);
                    if (hi > lo) try edit_.plainText(sa, r.content, lo, hi, r.equation, &out);
                },
                .hard_break, .paragraph => if (k < t.index) try out.append(sa, '\n'),
                else => {},
            }
        }
        return gpa.dupe(u8, out.items);
    }

    /// Removes item `index` of a track: a blank, run or break, or a tile,
    /// which leaves every track it is in.
    pub fn removeAt(m: *Model, parent: Parent, region: usize, index: usize) Error!void {
        const items = m.flow(parent, region);
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
    /// Moves a track region to `origin` (the point it holds, panel mm).
    pub fn moveRegion(m: *Model, parent: Parent, region: usize, origin: geom.Point) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchItem;
        // Its bends are along and across it: they move with it.
        m.regionsIn(parent)[region].origin = origin;
        m.revision += 1;
    }

    /// Sets a track region's extent, in its pitch: `along` its tracks and
    /// `across` them (how many tracks deep, fractions allowed).
    pub fn setRegionSize(m: *Model, parent: Parent, region: usize, along: f64, across: f64) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchItem;
        if (!(along > 0) or !(across > 0)) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        if (r.major() == .row) {
            r.w = along;
            r.h = across;
        } else {
            r.w = across;
            r.h = along;
        }
        m.revision += 1;
    }

    /// Sets a region's leading (null: its style's own line spacing) and
    /// the baseline-to-baseline distance it comes to, `pitch` mm; the
    /// region keeps its size in mm, its rows re-spaced.
    pub fn setLeading(m: *Model, parent: Parent, region: usize, leading: ?Leading, pitch: f64) Error!void {
        if (!m.hasParent(parent) or region >= m.regionsIn(parent).len) return error.NoSuchItem;
        if (!(pitch > 0.01) or !std.math.isFinite(pitch)) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        const k = r.pitch / pitch;
        r.w *= k;
        r.h *= k;
        r.gap *= k;
        r.pitch = pitch;
        r.leading = leading;
        m.revision += 1;
    }

    pub fn setSegmentLength(m: *Model, parent: Parent, region: usize, length: f64) Error!void {
        if (!(length > 0)) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        if (r.major() == .row) r.w = length else r.h = length;
        m.revision += 1;
    }

    /// Older documents' history only: a segment moved by hand, now a
    /// control point where that segment was placed (see `bendPath`).
    pub fn moveSegment(m: *Model, parent: Parent, region: usize, segment: usize, solved: []const Segment, along: f64, across: f64, avoid: []const geom.Box) Error!void {
        _ = avoid;
        if (segment >= solved.len) return error.NoSuchRow;
        const here = solved[segment];
        _ = try m.bendPath(parent, region, here.across, here.along + along, here.across + across);
    }

    /// Older documents' history only: the path now keeps its control points.
    pub fn trimSegments(m: *Model, parent: Parent, region: usize, count: usize) void {
        _ = m;
        _ = parent;
        _ = region;
        _ = count;
    }

    /// Adds a control point to a track's path at (`along`, `across`) u
    /// from its region's origin. Returns its ID.
    pub fn addControlPoint(m: *Model, parent: Parent, region: usize, along: f64, across: f64) Error!ObjectId {
        if (!std.math.isFinite(along) or !std.math.isFinite(across) or across < 0) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        const id = m.newId();
        try r.path.append(m.a(), .{ .id = id, .along = along, .across = across });
        m.revision += 1;
        return id;
    }

    /// Bends a track's path where a segment attaches to it (`at_across`):
    /// the control point there moves to (`along`, `across`), or one is
    /// made there and moved. The segments after it follow the new shape.
    pub fn bendPath(m: *Model, parent: Parent, region: usize, at_across: f64, along: f64, across: f64) Error!ObjectId {
        if (!std.math.isFinite(along) or !std.math.isFinite(across) or across < 0) return error.BadSize;
        const r = &m.regionsIn(parent)[region];
        for (r.path.items) |*cp| if (@abs(cp.across - at_across) < 1e-6) {
            cp.along = along;
            cp.across = across;
            m.revision += 1;
            return cp.id;
        };
        return m.addControlPoint(parent, region, along, across);
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
        var copy = try m.dupePrototype(p);
        copy.id = m.newId();
        try m.prototypes.append(m.a(), copy);
        m.revision += 1;
        return copy.id;
    }

    /// Changes a prototype, and with it every tile made from it.
    pub fn setPrototype(m: *Model, id: PrototypeId, p: TilePrototype) Error!void {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        var copy = try m.dupePrototype(p);
        copy.id = id;
        m.proto(id).* = copy;
        m.revision += 1;
    }

    /// Changes how layer `i` of a prototype's art is painted. Its outline is
    /// left as drawn.
    pub fn setLayerPaint(m: *Model, id: PrototypeId, i: usize, paint: art_.Paint) Error!void {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        const p = m.proto(id);
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
        // A grid's stamp uses it whether or not it has instances yet.
        for (0..m.parentCount()) |pk| for (m.gridsIn(m.parentAt(pk))) |g| for (g.stamps.items) |st| {
            if (st.prototype == id) n += 1;
        };
        return n;
    }

    /// A copy of prototype `id` named `name`, art and all; returns its id.
    pub fn duplicatePrototype(m: *Model, id: PrototypeId, name: []const u8) Error!PrototypeId {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        var copy = m.proto(id).*;
        copy.name = name;
        // Its tracks are its own: new IDs.
        const tracks = try m.a().dupe(TileTrack, copy.tracks);
        for (tracks) |*tt| tt.id = .none;
        copy.tracks = tracks;
        return m.addPrototype(copy);
    }

    /// Removes prototype `id`, which no tile or stamp may still use.
    /// Tracks made for it no longer name a prototype.
    pub fn removePrototype(m: *Model, id: PrototypeId) Error!void {
        const i = m.protoIndex(id) orelse return error.NoSuchPrototype;
        if (m.prototypeUses(id) > 0) return error.PrototypeInUse;
        _ = m.prototypes.orderedRemove(i);
        for (m.panels.items) |*panel| for (panel.regions.items) |*r| if (r.prototype) |rp| {
            if (rp == id) r.prototype = null;
        };
        if (m.blank_prototype) |b| if (b == id) {
            m.blank_prototype = null;
        };
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
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
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
        m.proto(id).sketch = .{
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
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        const ps = &(m.proto(id).sketch orelse return error.NoSuchItem);
        ps.offset = offset;
        m.revision += 1;
    }

    /// Takes prototype `id`'s sketch away: its tiles are drawn as before.
    pub fn removePrototypeSketch(m: *Model, id: PrototypeId) Error!void {
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        m.proto(id).sketch = null;
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
        if (m.protoIndex(id) == null) return error.NoSuchPrototype;
        m.proto(id).art = if (art) |x| try art_.dupe(m.a(), x) else null;
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
        const tracks = try m.a().alloc(TileTrack, p.tracks.len);
        for (p.tracks, tracks) |tt, *out| {
            out.* = tt;
            out.name = try m.a().dupe(u8, tt.name);
            if (out.id == .none) out.id = m.newId();
        }
        copy.tracks = tracks;
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
        if (m.protoIndex(prototype) == null) return error.NoSuchPrototype;
        m.tile(id).prototype = prototype;
        m.revision += 1;
    }

    /// Adds a tile with a designator unique among the model's tiles. A tile
    /// added before any prototype gets a plain one, with no insets.
    pub fn addTile(m: *Model, t: Tile) Error!TileId {
        if (!(t.w > 0 and t.h > 0)) return error.BadSize;
        if (m.findTile(t.designator) != null) return error.DuplicateDesignator;
        if (m.prototypes.items.len == 0 and t.prototype == .none) _ = try m.addPrototype(.{ .name = "Plain" });
        var copy = t;
        if (copy.prototype == .none) copy.prototype = m.prototypes.items[0].id;
        if (m.protoIndex(copy.prototype) == null) return error.NoSuchPrototype;
        copy.designator = try m.a().dupe(u8, t.designator);
        // Its own copy of what is in its tracks, each with an ID of its own.
        copy.flows = .empty;
        for (t.flows.items) |f| {
            var c: TileFlow = .{ .id = m.newId(), .track = f.track };
            for (f.items.items) |it| {
                var ci = it;
                if (ci.what == .run) ci.what.run.content = try m.a().dupe(u8, it.what.run.content);
                try c.items.append(m.a(), ci);
            }
            try copy.flows.append(m.a(), c);
        }
        copy.id = m.newId();
        try m.tiles.append(m.a(), copy);
        m.revision += 1;
        return copy.id;
    }

    /// Takes `id` out of every track it is in, keeping the tile itself.
    pub fn unplace(m: *Model, id: TileId) void {
        for (m.flows.items) |*f| {
            var i: usize = 0;
            while (i < f.items.items.len) {
                const here = f.items.items[i].tileOf();
                if (here != null and here.? == id) _ = f.items.orderedRemove(i) else i += 1;
            }
        }
        m.revision += 1;
    }

    pub fn findTile(m: *const Model, designator: []const u8) ?TileId {
        for (m.tiles.items) |t| {
            if (!t.removed and std.mem.eql(u8, t.designator, designator)) return t.id;
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
    const r = try m.addRegion(.{ .panel = b }, .{ .name = "row", .origin = .{ .x = 0, .y = 50 }, .w = 2, .h = 1, .pitch = 19.05 });
    try m.place(.{ .panel = b }, r, null, .{ .what = .{ .tile = try m.addTile(.{ .designator = "K1" }) } });
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
    const r = try m.addRegion(.{ .panel = p }, .{ .name = "main", .origin = .{ .x = 0, .y = 50 }, .w = 5, .h = 2, .pitch = 19.05 });
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{.{ .name = "top" }} });
    const q = try m.addTile(.{ .designator = "Q", .prototype = key });
    try std.testing.expectError(error.DuplicateDesignator, m.addTile(.{ .designator = "Q" }));
    try std.testing.expectError(error.NoSuchPrototype, m.addTile(.{ .designator = "R", .prototype = @fromBackingInt(@intCast(9999)) }));
    try m.place(.{ .panel = p }, r, null, .{ .what = .{ .tile = q } });
    const before = m.revision;
    try m.setTrackText(q, "top", "q");
    try std.testing.expect(m.revision > before);
    try std.testing.expectEqualStrings("q", m.tileFlow(q, m.tileTrackNamed(q, "top").?).?.items.items[0].what.run.content);
    try std.testing.expectError(error.NoSuchTrack, m.setTrackText(q, "front", "x"));
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
    const before = m.proto(key).art.?.layers[0].outline.contours.ptr;
    try m.setLayerPaint(key, 0, .{ .fill = .{ .solid = .hex("#202020") }, .edge = .hex("#000000") });
    const layer = m.proto(key).art.?.layers[0];
    try std.testing.expectEqual(art_.Color.hex("#202020"), layer.paint.fill.solid);
    try std.testing.expectEqual(before, layer.outline.contours.ptr);
    try std.testing.expectError(error.NoSuchLayer, m.setLayerPaint(key, 5, .{}));
    const plain = try m.addPrototype(.{ .name = "plain" });
    try std.testing.expectError(error.NoSuchLayer, m.setLayerPaint(plain, 0, .{}));
}

test "prototypes are duplicated with tracks of their own; a renamed track keeps each tile's text; prototypes are removed when unused" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const key = try m.addPrototype(.{ .name = "key", .face_inset = .all(2), .tracks = &.{ .{ .name = "top" }, .{ .name = "front" } } });
    const k = try m.addTile(.{ .designator = "K1", .prototype = key });
    try m.setTrackText(k, "top", "A");
    const top = m.tileTrackNamed(k, "top").?;

    // A copy is independent of its original, its tracks its own.
    const wide = try m.duplicatePrototype(key, "wide key");
    try std.testing.expectEqualStrings("wide key", m.proto(wide).name);
    try std.testing.expectEqual(2, m.proto(wide).tracks.len);
    try std.testing.expect(m.proto(wide).tracks[0].id != top);
    _ = try m.addPrototypeTrack(wide, .{ .name = "side" });
    try std.testing.expectEqual(2, m.proto(key).tracks.len);
    try std.testing.expectError(error.DuplicateTrack, m.addPrototypeTrack(wide, .{ .name = "side" }));

    // A renamed track keeps each tile's text: it is matched by ID.
    var renamed = m.proto(key).tracks[0];
    renamed.name = "legend";
    try m.setPrototypeTrack(key, top, renamed);
    try std.testing.expectEqual(top, m.tileTrackNamed(k, "legend").?);
    try std.testing.expectEqualStrings("A", m.tileFlow(k, top).?.items.items[0].what.run.content);

    // A removed track hides the tile's text, which stays.
    try m.removePrototypeTrack(key, top);
    try std.testing.expectEqual(1, m.proto(key).tracks.len);
    try std.testing.expect(m.tileFlow(k, top) != null);

    // Only an unused prototype goes; tiles of others keep theirs.
    const spare = try m.addPrototype(.{ .name = "spare" });
    try m.setTilePrototype(k, spare);
    try std.testing.expectError(error.PrototypeInUse, m.removePrototype(spare));
    try m.removePrototype(key);
    try std.testing.expectEqual(spare, m.tileConst(k).prototype);
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
    const key = try m.addPrototype(.{ .name = "key", .widths = &.{ 1, 1.5 }, .tracks = &.{.{ .name = "top" }} });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "keys", .origin = .{ .x = 5, .y = 95 }, .prototype = key, .count = 2, .length = 4.5, .pitch = 19.05 });
    const region = m.panels.items[p].regions.items[r];
    try std.testing.expectEqual(4.5, region.w);
    try std.testing.expectEqual(2, region.h);
    // No segments stored: they come as the flow needs them, along a path
    // that is straight until it is given control points.
    try std.testing.expectEqual(0, region.path.items.len);
    try std.testing.expectEqual(0, m.flowItems(.{ .panel = p }, r).len);
    try std.testing.expectEqual(0, m.tiles.items.len);

    // Columns: as thick as the smallest width, as long as asked.
    const c = try m.addTracks(.{ .panel = p }, .{ .name = "side", .origin = .{ .x = 120, .y = 95 }, .major = .column, .prototype = key, .count = 3, .length = 2, .pitch = 19.05 });
    const side = m.panels.items[p].regions.items[c];
    try std.testing.expectEqual(3, side.w);
    try std.testing.expectEqual(2, side.h);
    try std.testing.expectError(error.BadSize, m.addTracks(.{ .panel = p }, .{ .name = "x", .origin = .{ .x = 0, .y = 0 }, .prototype = key, .count = 1, .length = 0.5, .pitch = 19.05 }));

    for (0..4) |i| _ = try m.insertTile(.{ .panel = p }, r, i, key, 1);
    const t1 = m.findTile("T1").?;
    m.removeTile(t1);
    try std.testing.expectEqual(null, m.findTile("T1"));
    try std.testing.expectEqual(3, m.flowItems(.{ .panel = p }, r).len);
}

test "tiles, blanks, runs and breaks are inserted and removed in flow order" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const key = try m.addPrototype(.{ .name = "key", .widths = &.{ 1, 1.25, 1.5 } });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "keys", .origin = .{ .x = 5, .y = 95 }, .prototype = key, .count = 1, .length = 2, .pitch = 19.05 });
    _ = try m.insertTile(.{ .panel = p }, r, 0, key, 1);
    _ = try m.insertTile(.{ .panel = p }, r, 1, key, 1);
    // T1 T2; insert a 1.5 u tile between them, and a blank before it.
    const t = try m.insertTile(.{ .panel = p }, r, 1, key, 1.5);
    const b = try m.insertBlank(.{ .panel = p }, r, 1, 0.25);
    const items = m.flowItems(.{ .panel = p }, r);
    try std.testing.expectEqual(4, items.len);
    // A blank is a tile of the built-in Blank prototype.
    try std.testing.expectEqual(b, items[1].tileOf().?);
    try std.testing.expectEqual(0.25, m.tileConst(b).w);
    try std.testing.expectEqualStrings("B1", m.tileConst(b).designator);
    try std.testing.expect(m.proto(m.tileConst(b).prototype).spacer);
    try std.testing.expectEqual(m.blank_prototype.?, try m.blankPrototype());
    try std.testing.expectEqual(t, items[2].tileOf().?);
    try std.testing.expectEqualStrings("T3", m.tileConst(t).designator);
    try std.testing.expectEqual(1.5, m.tileConst(t).w);
    // Removing the blank, then the tile.
    try m.removeAt(.{ .panel = p }, r, 1);
    try m.removeAt(.{ .panel = p }, r, 1);
    const left = m.flowItems(.{ .panel = p }, r);
    try std.testing.expectEqual(2, left.len);
    try std.testing.expectEqual(null, m.findTile("T3"));
    try std.testing.expectError(error.NoSuchItem, m.removeAt(.{ .panel = p }, r, 5));
    // A new tile takes the lowest free designator.
    _ = try m.insertTile(.{ .panel = p }, r, 0, key, 1);
    try std.testing.expect(m.findTile("T3") != null);
    // Text and equations share the flow with the tiles, and a hard break
    // goes between any two items.
    try m.insertRun(.{ .panel = p }, r, 1, .{ .content = "x = \\frac{1}{2}" });
    _ = try m.insertBreak(.{ .panel = p }, r, 2);
    const mixed = m.flowItems(.{ .panel = p }, r);
    try std.testing.expectEqual(5, mixed.len);
    try std.testing.expectEqualStrings("x = \\frac{1}{2}", mixed[1].what.run.content);
    try std.testing.expect(mixed[2].what == .hard_break);
    try m.setRunContent(.{ .panel = p }, r, 1, "word");
    try std.testing.expectEqualStrings("word", m.flowItems(.{ .panel = p }, r)[1].what.run.content);
    try std.testing.expectError(error.NoSuchItem, m.setRunContent(.{ .panel = p }, r, 0, "x"));
}

test "tracks sized to a text style are one line pitch thick, and keep the style" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("board", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 3 });
    // A 4.2 mm line pitch (the caller measures it from the style's font).
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "text", .origin = .{ .x = 5, .y = 95 }, .style = body, .count = 3, .length = 20, .pitch = 4.2 });
    const region = m.panels.items[p].regions.items[r];
    try std.testing.expectEqual(body, region.style.?);
    try std.testing.expectEqual(null, region.prototype);
    try std.testing.expectEqual(20, region.w);
    try std.testing.expectEqual(3, region.h);
    try std.testing.expectApproxEqAbs(@as(f64, 4.2), region.boxAt(.{ .across = 1 }).height(), 1e-9);
    try std.testing.expectError(error.NoSuchStyle, m.addTracks(.{ .panel = p }, .{ .name = "x", .origin = .{ .x = 0, .y = 0 }, .style = @fromBackingInt(@intCast(9999)), .count = 1, .length = 2, .pitch = 4 }));
    try std.testing.expectError(error.NoSuchPrototype, m.addTracks(.{ .panel = p }, .{ .name = "x", .origin = .{ .x = 0, .y = 0 }, .count = 1, .length = 2, .pitch = 4 }));
}

/// A small dot of line art at `at` on panel `panel`, named `name` (tests:
/// an object to place, move and group). Returns its index there.
fn testDot(m: *Model, panel: usize, name: []const u8, at: geom.Point) !usize {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const prim: art_.Primitive = .{ .circle = 1 };
    return m.addArt(panel, .{ .name = name, .at = at, .shapes = try art_.primitive(arena.allocator(), name, prim, .{}), .prim = prim });
}

test "a canvas: units chosen up front, no sheet; it holds containers, never content of its own" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const ci = try m.startCanvas(.mil);
    const c: Parent = .{ .space = ci };
    try std.testing.expect(c.eql(m.canvas().?));
    try std.testing.expectEqual(Units.mil, m.units);
    try std.testing.expect(!m.has_sheet);
    try std.testing.expectError(error.NoRoom, m.startCanvas(.mm));
    // No panel stands in for the canvas.
    try std.testing.expectEqual(0, m.panels.items.len);
    // A content layout set straight on it, anywhere, even far from the
    // origin or at negative positions.
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    const r = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = -500, .y = 1200 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    try std.testing.expectEqual(Member{ .region = .{ .parent = c, .index = r } }, m.locate(m.regionsIn(c)[r].id).?);
    try std.testing.expectEqual(ci, m.spaceOfId(m.regionsIn(c)[r].id).?);
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
    const c: Parent = .{ .space = try m.startCanvas(.mm) };
    // On the canvas: a panel holding line art, and a track set straight
    // on the canvas.
    const p = try m.placePanel(.{ .name = "Front", .origin = .{ .x = 10, .y = 10 }, .w = 50, .h = 30 });
    _ = try testDot(&m, p, "Dot", .{ .x = 5, .y = 8 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    const r = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = 100, .y = 50 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    _ = try m.insertTile(c, r, 0, key, 1);
    const pid = m.panels.items[p].id;
    const rid = m.regionsIn(c)[r].id;
    const f = try m.addFrame("Frame 1", null);
    try std.testing.expectEqual(1, f);
    const fp: Parent = .{ .space = f };
    const g = try m.moveToSpace(&.{ pid, rid }, f);
    // Panels change space, their line art with them; the track is set on
    // the frame; coordinates and IDs kept.
    try std.testing.expectEqual(f, m.spaceOf(p));
    try std.testing.expectEqual(10, m.panels.items[p].origin.x);
    try std.testing.expectEqual(1, m.panels.items[p].art.items.len);
    try std.testing.expectEqual(0, m.regionsIn(c).len);
    try std.testing.expectEqual(Member{ .region = .{ .parent = fp, .index = 0 } }, m.locate(rid).?);
    // Line art goes only with its panel.
    try std.testing.expectError(error.NoRoom, m.moveToSpace(&.{m.panels.items[p].art.items[0].id}, 0));
    // One group, named after where it came from; one move places all.
    const group = m.group(g).?;
    try std.testing.expectEqualStrings("from Canvas", group.name);
    try std.testing.expectEqual(2, group.members.items.len);
    try m.moveGroup(g, -10, 5);
    try std.testing.expectEqual(0, m.panels.items[p].origin.x);
    try std.testing.expectEqual(90, m.regionsIn(fp)[0].origin.x);
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
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
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

test "releasing a panel sets its content layouts on its workspace; one holding line art is refused" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c: Parent = .{ .space = try m.startCanvas(.mm) };
    const p = try m.placePanel(.{ .name = "Front", .origin = .{ .x = 10, .y = 10 }, .w = 100, .h = 60 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 10 });
    _ = try m.addTracks(.{ .panel = p }, .{ .name = "keys", .origin = .{ .x = 30, .y = 40 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    const g = try m.makeGroup(&.{m.panels.items[p].id}, "g");
    try std.testing.expectEqual(ObjectId.none, try m.releasePanel(p));
    try std.testing.expectEqual(0, m.panels.items.len);
    // Where it was, now in the canvas's coordinates; the group went with
    // its only member.
    try std.testing.expectEqual(1, m.regionsIn(c).len);
    try std.testing.expectEqual(40, m.regionsIn(c)[0].origin.x);
    try std.testing.expectEqual(null, m.group(g));
    const q = try m.placePanel(.{ .name = "Back", .w = 100, .h = 60 });
    _ = try testDot(&m, q, "Dot", .{ .x = 5, .y = 5 });
    try std.testing.expectError(error.NoRoom, m.releasePanel(q));
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
    try std.testing.expectEqualStrings("Layer2", m.spaces.items[0].layers.items[bg].name);
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

test "a flow is edited in place: typed into, deleted across items, broken and joined" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 100, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "T", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 4, .length = 40, .pitch = 6 });
    const items = &m.flowOf(.{ .panel = p }, r).items;
    // Typing into an empty flow makes a run; more goes on its end.
    var at = try m.insertText(.{ .panel = p }, r, .{ .index = 0 }, "Hello", body);
    try std.testing.expectEqual(FlowPos{ .index = 1 }, at);
    at = try m.insertText(.{ .panel = p }, r, at, " world {1}", body);
    try std.testing.expectEqualStrings("Hello world \\{1\\}", items.items[0].what.run.content);
    // A paragraph broken inside it: two runs either side of a separator.
    at = try m.breakAt(.{ .panel = p }, r, .{ .index = 0, .offset = 5 }, true);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("Hello", items.items[0].what.run.content);
    try std.testing.expectEqualStrings(" world \\{1\\}", items.items[2].what.run.content);
    try std.testing.expectEqual(FlowPos{ .index = 2 }, at);
    // Deleting across the separator joins the runs again, less what lay
    // between: "Hel" + "orld {1}".
    at = try m.deleteRange(.{ .panel = p }, r, .{ .index = 0, .offset = 3 }, .{ .index = 2, .offset = 2 });
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("Helorld \\{1\\}", items.items[0].what.run.content);
    try std.testing.expectEqual(FlowPos{ .index = 0, .offset = 3 }, at);
    // Copied as plain text.
    const text = try m.flowText(gpa, .{ .panel = p }, r, .{ .index = 0, .offset = 0 }, .{ .index = 1 });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Helorld {1}", text);
    // Deleting a whole run takes it away.
    _ = try m.deleteRange(.{ .panel = p }, r, .{ .index = 0 }, .{ .index = 1 });
    try std.testing.expectEqual(@as(usize, 0), items.items.len);
    // Pasted lines become paragraphs.
    at = try m.insertText(.{ .panel = p }, r, .{ .index = 0 }, "one\ntwo", body);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expect(items.items[1].what == .paragraph);
}

test "an equation is its own item: put in a run of text, kept apart from it" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 100, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "T", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 4, .length = 40, .pitch = 6 });
    const items = &m.flowOf(.{ .panel = p }, r).items;
    _ = try m.insertText(.{ .panel = p }, r, .{ .index = 0 }, "area is ", body);
    // Inside the text: the run splits either side of the new equation.
    const eq = try m.insertEquation(.{ .panel = p }, r, .{ .index = 0, .offset = 4 }, body);
    try std.testing.expectEqual(@as(usize, 1), eq);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expect(items.items[1].what.run.equation);
    try std.testing.expectEqualStrings("area", items.items[0].what.run.content);
    try std.testing.expectEqualStrings(" is ", items.items[2].what.run.content);
    items.items[1].what.run.content = "\\frac{a}{}";
    // Typed into an empty slot, it goes into the equation.
    var at = try m.insertText(.{ .panel = p }, r, .{ .index = 1, .offset = 9 }, "2", body);
    try std.testing.expectEqualStrings("\\frac{a}{2}", items.items[1].what.run.content);
    // Typed just before it or just after it, it goes into the text.
    at = try m.insertText(.{ .panel = p }, r, .{ .index = 1 }, ":", body);
    try std.testing.expectEqualStrings("area:", items.items[0].what.run.content);
    try std.testing.expectEqual(FlowPos{ .index = 1 }, at);
    at = try m.insertText(.{ .panel = p }, r, .{ .index = 2 }, "x", body);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("x is ", items.items[2].what.run.content);
    // Deleting the end of the text before it leaves the two apart.
    at = try m.deleteRange(.{ .panel = p }, r, .{ .index = 0, .offset = 2 }, .{ .index = 1 });
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("ar", items.items[0].what.run.content);
    try std.testing.expectEqualStrings("\\frac{a}{2}", items.items[1].what.run.content);
    // At the end of an equation a new one goes after it.
    try std.testing.expectEqual(@as(usize, 2), try m.insertEquation(.{ .panel = p }, r, .{ .index = 1, .offset = 3 }, body));
}

test "a panel made from an enclosed sketch: cut by nesting, following its sketch" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const c: Parent = .{ .space = try m.startCanvas(.mm) };
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
    const st = try m.addStyle("Body", .{ .cap_height = 2 });
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

test "spaces, prototypes, styles and tiles are connected by ID; a panel given no space goes on the canvas" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.addPanel("P", 50, 30);
    const f = try m.addFrame("Frame 1", null);
    try std.testing.expectEqual(m.spaces.items[0].id, m.panels.items[p].space);
    try std.testing.expect(m.inSpace(p, 0));
    try std.testing.expect(!m.inSpace(p, f));
    // A workspace stands for itself: no panel stands in for it.
    m.removePanel(p);
    try std.testing.expectEqual(0, m.panels.items.len);
    try std.testing.expectEqual(Parent{ .space = f }, m.parentOfId(m.spaces.items[f].id).?);
    // Tiles are found by their IDs, which are not positions.
    const t = try m.addTile(.{ .designator = "A" });
    try std.testing.expect(@backingInt(t) >= m.tiles.items.len);
    try std.testing.expectEqualStrings("A", m.tileConst(t).designator);
    try std.testing.expectEqual(t, m.findTile("A").?);
}

test "a tile's track text reads back as set; a stamp's new prototype leaves a tile given its own" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.addPanel("P", 50, 30);
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{.{ .name = "top" }} });
    const tall = try m.addPrototype(.{ .name = "tall", .tracks = &.{.{ .name = "top", .major = .column }} });
    const other = try m.addPrototype(.{ .name = "other" });
    const g = try m.addGrid(.{ .panel = p }, .{ .x = 10, .y = 20 }, .{ .cols = 2, .rows = 1, .pitch_x = 10, .pitch_y = 10 });
    const st = try m.addStamp(.{ .panel = p }, g, .{ .name = "Keys", .prototype = key, .w = 8, .h = 8 });
    const a = try m.addInstance(.{ .panel = p }, g, st, 0, 0);
    const b = try m.addInstance(.{ .panel = p }, g, st, 1, 0);
    const top = m.tileTrackNamed(a, "top").?;
    try m.setTileTrackText(a, top, "ON\nOFF");
    const text = try m.tileTrackText(std.testing.allocator, a, top);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ON\nOFF", text);
    try std.testing.expectEqual(@as(usize, 3), m.tileFlow(a, top).?.items.items.len);
    try m.setTilePrototype(b, tall);
    var next = m.panels.items[p].grids.items[g].stamps.items[st];
    next.prototype = other;
    try m.setStamp(.{ .panel = p }, g, st, next);
    try std.testing.expectEqual(other, m.tileConst(a).prototype);
    try std.testing.expectEqual(tall, m.tileConst(b).prototype);
}

test "ready-made shape sketches are fully constrained, sized by their parameters" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    for ([_]ShapeSketch{ .circle, .rectangle, .rounded_rectangle, .slot }) |kind| {
        const si = try m.addShapeSketch(kind);
        const sk = &m.sketches.items[si].sketch;
        const an = try sk.analyse(std.testing.allocator, scratch.allocator());
        std.testing.expect(an.fully_constrained and an.redundant.len == 0 and an.conflicting.len == 0) catch |err| {
            std.debug.print("{s}: dof {d}, redundant {any}, conflicting {d}\n", .{ @tagName(kind), an.dof, an.redundant, an.conflicting.len });
            for (an.redundant) |ci| std.debug.print("  {any}\n", .{sk.constraints.items[ci].kind});
            return err;
        };
        // Resized by its parameters, its outline keeps centred.
        try sk.setParam(m.a(), "w", "20");
        try sk.setParam(m.a(), "h", "8");
        _ = try sk.solve(std.testing.allocator);
        const profiles = try sk.profiles(scratch.allocator());
        try std.testing.expectEqual(@as(usize, 1), profiles.contours.len);
        try std.testing.expectEqual(@as(usize, 0), profiles.open);
        const bx = profiles.contours[0].bounds();
        try std.testing.expectApproxEqAbs(@as(f64, 20), bx.width(), 1e-6);
        if (kind != .circle) try std.testing.expectApproxEqAbs(@as(f64, 8), bx.height(), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f64, 0), (bx.x0 + bx.x1) / 2, 1e-6);
    }
}

test "generated names: identifiers, numbered within their container" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const q = try m.addPanel("other", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    var buf: [32]u8 = undefined;
    // Within a panel: tracks, grids and art share one namespace.
    try std.testing.expectEqualStrings("Track1", m.freshName(&buf, .{ .panel = p }, "Track"));
    _ = try m.addTracks(.{ .panel = p }, .{ .name = "Track1", .origin = .{ .x = 0, .y = 90 }, .style = body, .kind = .track, .count = 1, .length = 40, .pitch = 6 });
    try std.testing.expectEqualStrings("Track2", m.freshName(&buf, .{ .panel = p }, "Track"));
    // Another panel is another container.
    try std.testing.expectEqualStrings("Track1", m.freshName(&buf, .{ .panel = q }, "Track"));
    _ = try m.addGrid(.{ .panel = p }, .{ .x = 0, .y = 0 }, .{ .cols = 2, .rows = 2, .pitch_x = 10, .pitch_y = 10 });
    try std.testing.expectEqualStrings("Grid1", m.panels.items[p].grids.items[0].name);
    // A typed name made an identifier when it must be one: kept when free.
    try std.testing.expectEqualStrings("RoundedRectangle", m.freshOrSame(&buf, .{ .panel = p }, "Rounded rectangle", "Shape"));
    try std.testing.expectEqualStrings("Track11", m.freshOrSame(&buf, .{ .panel = p }, "Track1", "Shape"));
    try std.testing.expectEqualStrings("Paragraph1", m.nextParagraphStyleName(&buf));
}

test "name paths: a panel's track, a flow's key, a collection's member, quoted names" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("PC keyboard", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "Row1", .origin = .{ .x = 0, .y = 90 }, .style = body, .kind = .track, .count = 1, .length = 40, .pitch = 6 });
    try std.testing.expectEqual(Model.Ref{ .region = .{ .parent = .{ .panel = p }, .region = r } }, m.resolve("\"PC keyboard\".Row1").?);
    try std.testing.expectEqual(Model.Ref{ .style = body }, m.resolve("Styles.Body").?);
    // A member of a collection by its name alone.
    try std.testing.expectEqual(Model.Ref{ .style = body }, m.resolve("Body").?);
    try std.testing.expectEqual(Model.Ref{ .collection = .flows }, m.resolve("Flows").?);
    // Alone, Row1 is the flow that took the track's name; the track is the
    // panel's.
    try std.testing.expectEqual(Model.Ref{ .flow = m.trackFlow(.{ .panel = p }, r).?.id }, m.resolve("Row1").?);
    try std.testing.expect(m.resolve("Nowhere") == null);
    try std.testing.expect(m.resolve("\"PC keyboard\".Row2") == null);
    try std.testing.expect(m.resolve("\"unclosed") == null);
    // Keys within their flow, from the flow or a track of it.
    const proto = try m.addPrototype(.{ .name = "Key" });
    const t = try m.addTile(.{ .designator = "K1", .prototype = proto });
    try m.flow(.{ .panel = p }, r).append(m.a(), .{ .what = .{ .tile = t } });
    const flow_name = m.trackFlow(.{ .panel = p }, r).?.name;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(Model.Ref{ .tile = t }, m.resolve(std.fmt.bufPrint(&buf, "{s}.K1", .{flow_name}) catch unreachable).?);
    try std.testing.expectEqual(Model.Ref{ .tile = t }, m.resolve("\"PC keyboard\".Row1.K1").?);
}

test "flows: a track drawn has its own; joining makes one flow, unjoining gives the track a new one" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    const b = try m.addTracks(.{ .panel = p }, .{ .name = "B", .origin = .{ .x = 50, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    try std.testing.expectEqual(2, m.flows.items.len);
    try std.testing.expectEqualStrings("A", m.trackFlow(.{ .panel = p }, a).?.name);
    // A second flow named alike gets a generated name (an identifier,
    // numbered among the flows).
    try std.testing.expectEqualStrings("Flow1", m.flows.items[m.flowIndex(try m.addFlow("A")).?].name);
    try m.removeFlow(m.flows.items[2].id);
    _ = try m.insertText(.{ .panel = p }, a, .{ .index = 0 }, "first", body);
    _ = try m.insertText(.{ .panel = p }, b, .{ .index = 0 }, "second", body);
    try m.joinTracks(.{ .panel = p }, a, b);
    // One flow through both, A's content then B's as a new paragraph.
    try std.testing.expectEqual(1, m.flows.items.len);
    try std.testing.expectEqual(m.trackFlow(.{ .panel = p }, a), m.trackFlow(.{ .panel = p }, b));
    try std.testing.expectEqual(3, m.flowItems(.{ .panel = p }, b).len);
    try std.testing.expectEqual(3, m.ownItems(.{ .panel = p }, a).len);
    try std.testing.expectEqual(0, m.ownItems(.{ .panel = p }, b).len);
    try std.testing.expectEqual(b, m.threadAfter(.{ .panel = p }, a).?.region);
    try std.testing.expectEqual(a, m.threadHead(.{ .panel = p }, b).region);
    // A out: the flow keeps everything and starts in B; A has a new one.
    try m.unjoinTrack(.{ .panel = p }, a);
    try std.testing.expectEqual(2, m.flows.items.len);
    try std.testing.expectEqual(3, m.ownItems(.{ .panel = p }, b).len);
    try std.testing.expectEqual(0, m.flowItems(.{ .panel = p }, a).len);
    try std.testing.expect(m.threadAfter(.{ .panel = p }, b) == null);
}

test "tracks: removed, the flow goes on in the rest; the last one's text kept unplaced" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 0, .y = 90 }, .style = body, .kind = .track, .count = 1, .length = 40, .pitch = 6 });
    const b = try m.addTracks(.{ .panel = p }, .{ .name = "B", .origin = .{ .x = 0, .y = 80 }, .style = body, .kind = .track, .count = 1, .length = 40, .pitch = 6 });
    try std.testing.expectEqual(1, m.panels.items[p].regions.items[a].h);
    _ = try m.insertText(.{ .panel = p }, a, .{ .index = 0 }, "words", body);
    const flow = m.trackFlow(.{ .panel = p }, a).?.id;
    try m.assignTrack(.{ .panel = p }, b, flow, null);
    try std.testing.expectEqual(1, m.flows.items.len);
    try m.removeRegion(.{ .panel = p }, a);
    // B, now first, holds the flow.
    try std.testing.expectEqual(1, m.panels.items[p].regions.items.len);
    try std.testing.expectEqual(1, m.flowItems(.{ .panel = p }, 0).len);
    try m.removeRegion(.{ .panel = p }, 0);
    try std.testing.expectEqual(1, m.flows.items.len);
    try std.testing.expectEqual(0, m.flows.items[0].tracks.items.len);
}

test "tracks: turned to run down, a track keeps its length and stays one thick; not while it shares its flow" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 0, .y = 90 }, .style = body, .kind = .track, .count = 1, .length = 40, .pitch = 6 });
    try m.setOrientation(.{ .panel = p }, a, -90, 90);
    const r = m.panels.items[p].regions.items[a];
    try std.testing.expectEqual(Major.column, r.major());
    try std.testing.expectEqual(1, r.w);
    try std.testing.expectEqual(40, r.h);
    try std.testing.expect(r.supported());
    // At an angle: kept, not supported yet.
    try m.setOrientation(.{ .panel = p }, a, -80, 90);
    try std.testing.expect(!m.panels.items[p].regions.items[a].supported());
    try m.setOrientation(.{ .panel = p }, a, 0, 0);
    const b = try m.addTracks(.{ .panel = p }, .{ .name = "B", .origin = .{ .x = 0, .y = 80 }, .style = body, .kind = .track, .count = 1, .length = 40, .pitch = 6 });
    try m.assignTrack(.{ .panel = p }, b, m.trackFlow(.{ .panel = p }, a).?.id, null);
    try std.testing.expectError(error.BadJoin, m.setOrientation(.{ .panel = p }, a, -90, 90));
    // Rotation alone is any track's own.
    try m.setOrientation(.{ .panel = p }, a, 0, 180);
}

test "flows: a panel's copy gets copies of its flows; a panel removed leaves its text unplaced" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const q = try m.addPanel("other", 200, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    const b = try m.addTracks(.{ .panel = p }, .{ .name = "B", .origin = .{ .x = 50, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    _ = try m.insertText(.{ .panel = p }, a, .{ .index = 0 }, "words", body);
    try m.joinTracks(.{ .panel = p }, a, b);
    const c = try m.copyPanel(p);
    // The copy's two tracks run through one new flow holding a copy.
    try std.testing.expectEqual(2, m.flows.items.len);
    try std.testing.expect(m.trackFlow(.{ .panel = c }, a) != m.trackFlow(.{ .panel = p }, a));
    try std.testing.expectEqual(m.trackFlow(.{ .panel = c }, a), m.trackFlow(.{ .panel = c }, b));
    try std.testing.expectEqualStrings("words", m.flowItems(.{ .panel = c }, a)[0].what.run.content);
    // A flow on two panels: removing one leaves it on the other.
    const k = try m.addTracks(.{ .panel = q }, .{ .name = "K", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    try m.threadTracks(.{ .panel = p }, b, .{ .panel = q }, k);
    m.removePanel(c);
    m.removePanel(p);
    // q is now panel 0: the flow runs through K alone, its text kept; the
    // copy's flow, its tracks gone, keeps its text unplaced.
    try std.testing.expectEqual(2, m.flows.items.len);
    try std.testing.expectEqualStrings("words", m.ownItems(.{ .panel = 0 }, k)[0].what.run.content);
    // Its last track gone, that text stays too, unplaced.
    m.removePanel(0);
    try std.testing.expectEqual(2, m.flows.items.len);
    for (m.flows.items) |f| {
        try std.testing.expectEqual(0, f.tracks.items.len);
        try std.testing.expectEqual(1, f.items.items.len);
    }
}

test "flows: tracks assigned, moved within, detached; flows added, renamed, removed" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 300, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    const b = try m.addTracks(.{ .panel = p }, .{ .name = "B", .origin = .{ .x = 50, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    const c = try m.addTracks(.{ .panel = p }, .{ .name = "C", .origin = .{ .x = 100, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    _ = try m.insertText(.{ .panel = p }, a, .{ .index = 0 }, "story", body);
    const story = m.trackFlow(.{ .panel = p }, a).?.id;
    try m.renameFlow(story, "Story");
    // B and C into A's flow: their own empty flows go.
    try m.assignTrack(.{ .panel = p }, b, story, null);
    try m.assignTrack(.{ .panel = p }, c, story, null);
    try std.testing.expectEqual(1, m.flows.items.len);
    try std.testing.expectEqual(c, m.threadAfter(.{ .panel = p }, b).?.region);
    // C moved to the front: the content starts there now.
    try m.assignTrack(.{ .panel = p }, c, story, 0);
    try std.testing.expectEqual(c, m.threadHead(.{ .panel = p }, a).region);
    try std.testing.expectEqual(1, m.ownItems(.{ .panel = p }, c).len);
    try std.testing.expectEqual(0, m.ownItems(.{ .panel = p }, a).len);
    // An unplaced flow, and a track given to it: Story keeps its content.
    const notes = try m.addFlow("Notes");
    try std.testing.expectEqual(0, m.flows.items[m.flowIndex(notes).?].tracks.items.len);
    try m.assignTrack(.{ .panel = p }, a, notes, null);
    try std.testing.expectEqualStrings("Notes", m.trackFlow(.{ .panel = p }, a).?.name);
    try std.testing.expectEqualStrings("Story", m.trackFlow(.{ .panel = p }, c).?.name);
    // Detaching every Story track leaves it unplaced, its text kept.
    try m.detachTrack(.{ .panel = p }, c);
    try m.detachTrack(.{ .panel = p }, b);
    const si = m.flowIndex(story).?;
    try std.testing.expectEqual(0, m.flows.items[si].tracks.items.len);
    try std.testing.expectEqual(1, m.flows.items[si].items.items.len);
    // A track alone in an empty flow has nothing to detach from.
    try std.testing.expectError(error.BadJoin, m.detachTrack(.{ .panel = p }, b));
    // Removing Notes gives A an empty flow of its own; Story removed, gone.
    try m.removeFlow(notes);
    try std.testing.expect(m.trackFlow(.{ .panel = p }, a).?.id != notes);
    try m.removeFlow(story);
    try std.testing.expect(m.flowIndex(story) == null);
}

test "flows: a flow's tracks run one way" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("page", 300, 100);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 0, .y = 90 }, .style = body, .count = 2, .length = 40, .pitch = 6 });
    const col = try m.addTracks(.{ .panel = p }, .{ .name = "Col", .origin = .{ .x = 50, .y = 90 }, .major = .column, .style = body, .count = 2, .length = 40, .pitch = 6 });
    try std.testing.expectError(error.BadJoin, m.assignTrack(.{ .panel = p }, col, m.trackFlow(.{ .panel = p }, a).?.id, null));
}

/// A two-key keypad with a gold legend beside one key on a plate grid
/// linked to the keys' (as the HP-15C is built), for the sheet tests.
const SheetFixture = struct {
    keys_grid: ObjectId,
    a: TileId,
    b: TileId,
    gold: TileId,

    fn make(m: *Model) !SheetFixture {
        _ = try m.startCanvas(.mm);
        const plate = try m.addPanel("Plate", 60, 30);
        const keys = try m.addPanel("Keys", 60, 30);
        const key = try m.addPrototype(.{ .name = "key", .tracks = &.{ .{ .name = "top" }, .{ .name = "g" } } });
        const goldp = try m.addPrototype(.{ .name = "gold", .tracks = &.{.{ .name = "f" }} });
        const pg = try m.addGrid(.{ .panel = plate }, .{ .x = 10, .y = 20 }, .{ .cols = 2, .rows = 1, .pitch_x = 12, .pitch_y = 12 });
        const golds = try m.addStamp(.{ .panel = plate }, pg, .{ .name = "Gold", .prototype = goldp, .w = 8, .h = 3 });
        const kg = try m.addLinkedGrid(.{ .panel = keys }, .{ .x = 10, .y = 20 }, m.panels.items[plate].grids.items[pg].id);
        const caps = try m.addStamp(.{ .panel = keys }, kg, .{ .name = "Keys", .prototype = key, .w = 8, .h = 8 });
        const a = try m.addInstance(.{ .panel = keys }, kg, caps, 0, 0);
        const b = try m.addInstance(.{ .panel = keys }, kg, caps, 1, 0);
        const gold = try m.addInstance(.{ .panel = plate }, pg, golds, 1, 0);
        try m.renameTile(a, "SIN");
        try m.renameTile(b, "COS");
        try m.setTileTrackText(a, m.tileTrackNamed(a, "top").?, "SIN");
        try m.setTileTrackText(b, m.tileTrackNamed(b, "top").?, "COS");
        try m.setTileTrackText(gold, m.tileTrackNamed(gold, "f").?, "ACOS");
        return .{ .keys_grid = m.panels.items[keys].grids.items[kg].id, .a = a, .b = b, .gold = gold };
    }
};

fn slotText(m: *const Model, t: TileId, slot: []const u8) ![]u8 {
    return m.tileTrackText(std.testing.allocator, t, m.tileTrackNamed(t, slot).?);
}

test "a sheet made from a keypad holds what its keys and the legends beside them show" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const fx = try SheetFixture.make(&m);
    const id = try m.makeSheet("Legends", fx.keys_grid);
    const sh = m.sheets.items[m.sheetIndex(id).?];
    // Columns: the keys' slots, then the plate legend's.
    try std.testing.expectEqual(3, sh.columns.items.len);
    try std.testing.expectEqualStrings("top", sh.columns.items[0]);
    try std.testing.expectEqualStrings("f", sh.columns.items[2]);
    try std.testing.expectEqual(2, sh.rows.items.len);
    try std.testing.expectEqualStrings("SIN", sh.rows.items[0].key);
    try std.testing.expectEqualStrings("COS", sh.rows.items[1].cells.items[0]);
    try std.testing.expectEqualStrings("ACOS", sh.rows.items[1].cells.items[2]);
    try std.testing.expectEqualStrings("", sh.rows.items[0].cells.items[2]);
}

test "the sheet drives the slots: a cell sets them, an edit on the key sets the cell" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const fx = try SheetFixture.make(&m);
    const id = try m.makeSheet("Legends", fx.keys_grid);
    // A cell: the key's slot, and the gold legend beside it.
    try m.setSheetCell(id, 1, 1, "cos");
    try m.setSheetCell(id, 1, 3, "cos^{-1}");
    const t1 = try slotText(&m, fx.b, "top");
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("cos", t1);
    const t2 = try slotText(&m, fx.gold, "f");
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("cos^{-1}", t2);
    // On the key: the cell changes, and so the slot.
    try m.setTileTrackText(fx.a, m.tileTrackNamed(fx.a, "g").?, "ASIN");
    const si = m.sheetIndex(id).?;
    try std.testing.expectEqualStrings("ASIN", m.sheets.items[si].rows.items[0].cells.items[1]);
    const t3 = try slotText(&m, fx.a, "g");
    defer std.testing.allocator.free(t3);
    try std.testing.expectEqualStrings("ASIN", t3);
    // The name column renames the key.
    try m.setSheetCell(id, 0, 0, "sin");
    try std.testing.expectEqualStrings("sin", m.tileConst(fx.a).designator);
    try std.testing.expectError(error.DuplicateDesignator, m.setSheetCell(id, 0, 0, "COS"));
    // A column removed: its slots keep what they show, no longer driven.
    try m.removeSheetColumn(id, 0);
    try m.setTileTrackText(fx.b, m.tileTrackNamed(fx.b, "top").?, "own");
    try std.testing.expectEqualStrings("ASIN", m.sheets.items[si].rows.items[0].cells.items[0]);
}

test "a sheet's problems: rows naming no key, columns no key has" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const fx = try SheetFixture.make(&m);
    const id = try m.addSheet("Legends", fx.keys_grid, &.{ "top", "nothing" });
    try m.addSheetRow(id, null, "SIN");
    try m.addSheetRow(id, null, "TAN");
    var rows: std.ArrayList(usize) = .empty;
    defer rows.deinit(std.testing.allocator);
    var cols: std.ArrayList(usize) = .empty;
    defer cols.deinit(std.testing.allocator);
    try m.sheetProblems(std.testing.allocator, id, &rows, &cols);
    try std.testing.expectEqualSlices(usize, &.{1}, rows.items);
    try std.testing.expectEqualSlices(usize, &.{1}, cols.items);
    // A row for a key the sheet drives: its empty cell empties the slot.
    const t = try slotText(&m, fx.a, "top");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("", t);
}

test "a panel sized and a track moved and sized by typing, each undoable" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("P", 100, 50);
    try m.setPanelSize(p, 448.63, 143.83);
    try std.testing.expectEqual(448.63, m.panels.items[p].w);
    try std.testing.expectError(error.BadSize, m.setPanelSize(p, 0, 10));
    const st = try m.addStyle("s", .{});
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "keys", .origin = .{ .x = 3, .y = 4 }, .style = st, .count = 2, .length = 10, .pitch = 5 });
    try m.moveRegion(.{ .panel = p }, r, .{ .x = 10, .y = 133.83 });
    try m.setRegionSize(.{ .panel = p }, r, 22.5, 6.5);
    const reg = m.panels.items[p].regions.items[r];
    try std.testing.expectEqual(10, reg.origin.x);
    try std.testing.expectEqual(22.5, reg.w);
    try std.testing.expectEqual(6.5, reg.h);
}

test "a panel's keys named in order across its tracks, one flow each, as one flow would be" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("P", 200, 80);
    const key = try m.addPrototype(.{ .name = "key", .unit = 19.05 });
    const r1 = try m.addTracks(.{ .panel = p }, .{ .name = "Row1", .origin = .{ .x = 5, .y = 60 }, .prototype = key, .count = 1, .length = 8, .pitch = 19.05 });
    const r2 = try m.addTracks(.{ .panel = p }, .{ .name = "Row2", .origin = .{ .x = 5, .y = 40 }, .prototype = key, .count = 1, .length = 8, .pitch = 19.05 });
    try std.testing.expect(m.trackFlow(.{ .panel = p }, r1).?.id != m.trackFlow(.{ .panel = p }, r2).?.id);
    for (0..3) |k| _ = try m.insertTile(.{ .panel = p }, r1, k, key, 1);
    for (0..2) |k| _ = try m.insertTile(.{ .panel = p }, r2, k, key, 1);
    try std.testing.expectEqual(@as(usize, 5), try m.nameKeysInPanel(.{ .panel = p }, "K"));
    try std.testing.expectEqualStrings("K3", m.tileConst(m.flowItems(.{ .panel = p }, r1)[2].tileOf().?).designator);
    try std.testing.expectEqualStrings("K4", m.tileConst(m.flowItems(.{ .panel = p }, r2)[0].tileOf().?).designator);
    try std.testing.expectEqualStrings("K5", m.tileConst(m.flowItems(.{ .panel = p }, r2)[1].tileOf().?).designator);
}

test "a track renamed, its keys named in order, a gap set before one" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const p = try m.addPanel("P", 200, 50);
    const key = try m.addPrototype(.{ .name = "key", .unit = 19.05 });
    const r = try m.addTracks(.{ .panel = p }, .{ .name = "Tracks 1", .origin = .{ .x = 5, .y = 40 }, .prototype = key, .count = 1, .length = 8, .pitch = 19.05 });
    for (0..3) |k| _ = try m.insertTile(.{ .panel = p }, r, k, key, 1);
    try m.renameRegion(.{ .panel = p }, r, "keys");
    try std.testing.expectEqualStrings("keys", m.panels.items[p].regions.items[r].name);
    try std.testing.expectEqual(@as(usize, 3), try m.nameKeysInOrder(.{ .panel = p }, r, "K"));
    try std.testing.expectEqualStrings("K2", m.tileConst(m.flowItems(.{ .panel = p }, r)[1].tileOf().?).designator);
    try m.setItemGap(.{ .panel = p }, r, 2, 0.25);
    try std.testing.expectEqual(0.25, m.flowItems(.{ .panel = p }, r)[2].gap);
    // A name another key has elsewhere: refused, nothing renamed.
    const other = try m.addTile(.{ .designator = "Q1", .prototype = key });
    _ = other;
    try std.testing.expectError(error.DuplicateDesignator, m.nameKeysInOrder(.{ .panel = p }, r, "Q"));
    try std.testing.expectEqualStrings("K1", m.tileConst(m.flowItems(.{ .panel = p }, r)[0].tileOf().?).designator);
}

test "an older file's per-panel process settings become profiles: the 0.4 mm built-in, or their own" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const base: FabLayer = .{ .name = "Base", .source = .edge, .op = .{ .add = .{ .name = "black", .color = .hex("#000000") } } };
    var ids: [3]usize = undefined;
    for (&ids, 0..) |*pi, k| {
        pi.* = try m.addPanel("P", 50, 30);
        try m.setPanelFab(pi.*, .{ .layers = &.{base} });
        // As an older file reads: its settings on the panel, no profile.
        if (k > 0) m.panels.items[pi.*].fab.old_layer_height = 0.1;
    }
    try m.upgradeProcesses();
    try std.testing.expectEqualStrings("Generic FDM, 0.4 mm nozzle", m.processOf(ids[0]).?.name);
    // The two alike share one profile of their own settings.
    try std.testing.expectEqual(m.panels.items[ids[1]].fab.process, m.panels.items[ids[2]].fab.process);
    try std.testing.expectEqual(@as(?f64, 0.1), m.processOf(ids[1]).?.limits().layer);
    try std.testing.expectEqual(@as(usize, 2), m.processes.items.len);
    // Done again, nothing changes.
    try m.upgradeProcesses();
    try std.testing.expectEqual(@as(usize, 2), m.processes.items.len);
}

test "construction lines: added named, clipped to a box, set by their locks, removed" {
    const testing = std.testing;
    var m: Model = .init(testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const g0 = try m.addGuide(0, .{ .x = 0, .y = 0 }, 45);
    const g1 = try m.addGuide(0, .{ .x = 5, .y = 1 }, 0);
    const gs = m.spaces.items[0].guides.items;
    try testing.expectEqualStrings("Guide1", gs[g0].name);
    try testing.expectEqualStrings("Guide2", gs[g1].name);
    // The 45° line through the origin crosses a 10 mm box corner to corner.
    const seg = gs[g0].clip(.{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }).?;
    try testing.expectApproxEqAbs(0, seg[0].x, 1e-9);
    try testing.expectApproxEqAbs(10, seg[1].y, 1e-9);
    // A horizontal one at y 1 misses a box above it.
    try testing.expect(gs[g1].clip(.{ .x0 = 0, .y0 = 2, .x1 = 10, .y1 = 10 }) == null);
    try testing.expectApproxEqAbs(1, gs[g1].distance(.{ .x = 100, .y = 2 }), 1e-9);
    // Locked vertical: its angle is 90 whatever is given.
    try m.setGuide(0, g1, .{ .x = 5, .y = 1 }, 30, .vertical);
    try testing.expectEqual(@as(f64, 90), m.spaces.items[0].guides.items[g1].angle);
    try testing.expectApproxEqAbs(135, lineAngle(.{ .x = 0, .y = 0 }, .{ .x = -1, .y = 1 }), 1e-9);
    try m.removeGuide(0, g0);
    try testing.expectEqual(1, m.spaces.items[0].guides.items.len);
}

test "a sketch's area filled: a hatch inside a circle, an enclosed circle left out or filled" {
    const gpa = std.testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketch(0, "Disc", .{ .x = 0, .y = 0 });
    const outer = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 10, .construction = true } });
    _ = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 5, .construction = true } });
    // Solid, the inner circle a hole: the ring's area.
    _ = try m.addFillStyle(.{ .name = "Solid", .color = .{ .r = 0, .g = 0, .b = 0 }, .pattern = .solid });
    try m.setFill(si, &.{outer}, false, true);
    const fi = m.sketchFigure(m.sketches.items[si].id).?;
    const area = struct {
        fn f(fig: figure_.Figure) f64 {
            var t: f64 = 0;
            for (fig.paths) |p| for (p.subpaths) |sp| {
                t += (geom.Contour{ .segments = sp.segments }).signedArea();
            };
            return @abs(t);
        }
    }.f;
    const ring = std.math.pi * (100.0 - 25.0);
    try std.testing.expectApproxEqRel(ring, area(m.figures.items[fi]), 1e-3);
    // Enclosed paths filled: the whole disc.
    try m.setFill(si, &.{outer}, true, true);
    try std.testing.expectEqual(@as(usize, 1), m.figures.items[fi].fills.len);
    try std.testing.expectApproxEqRel(std.math.pi * 100.0, area(m.figures.items[fi]), 1e-3);
    // A hatch (lines 0.25 of their spacing wide): about a quarter of it.
    const h = try m.addFillStyle(.{ .name = "Hatch", .color = .{ .r = 0, .g = 0, .b = 0 }, .pattern = .{ .hatch = .{ .spacing = 1, .width = 0.25 } } });
    try m.setCurrentFill(h);
    try m.setFill(si, &.{outer}, true, true);
    try std.testing.expectApproxEqRel(std.math.pi * 25.0, area(m.figures.items[fi]), 0.03);
    // An open boundary is refused.
    const seg = try m.editSketch(si, .{ .segment = .{ .a = .{ .x = 20, .y = 0 }, .b = .{ .x = 30, .y = 0 } } });
    try std.testing.expectError(error.NotEnclosed, m.setFill(si, &.{seg}, false, true));
    // Off.
    try m.setFill(si, &.{outer}, false, false);
    try std.testing.expectEqual(@as(usize, 0), m.figures.items[fi].fills.len);
}

test "a sketch's draft reaches its drawing only when accepted; discarded, it goes back" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketch(0, "Drawn", .{ .x = 0, .y = 0 });
    const g = try m.editSketch(si, .{ .segment = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 0 } } });
    try m.setInk(si, g, true);
    const fi = m.sketchFigure(m.sketches.items[si].id).?;
    const end = struct {
        fn x(paths: []const figure_.Path) f64 {
            return paths[0].subpaths[0].segments[0].end().x;
        }
    }.x;
    try std.testing.expectApproxEqAbs(10, end(m.figures.items[fi].paths), 1e-9);
    // A draft: the line made longer shows in the draft's paths only.
    _ = try m.editSketchDraft(si, .{ .drag = .{ .p = .{ .geom = g, .role = .end }, .to = .{ .x = 20, .y = 0 } } });
    try std.testing.expect(m.sketches.items[si].accepted != null);
    try std.testing.expectApproxEqAbs(10, end(m.figures.items[fi].paths), 1e-9);
    try std.testing.expectApproxEqAbs(20, end(m.figures.items[fi].draft), 1e-9);
    // Accepted: the drawing follows.
    try m.acceptSketch(si);
    try std.testing.expect(m.sketches.items[si].accepted == null);
    try std.testing.expectApproxEqAbs(20, end(m.figures.items[fi].paths), 1e-9);
    // Another draft, discarded: back to 20.
    _ = try m.editSketchDraft(si, .{ .drag = .{ .p = .{ .geom = g, .role = .end }, .to = .{ .x = 30, .y = 0 } } });
    try m.discardSketchDraft(si);
    try std.testing.expectApproxEqAbs(20, end(m.figures.items[fi].paths), 1e-9);
    try std.testing.expectApproxEqAbs(20, (try m.sketches.items[si].sketch.point(.{ .geom = g, .role = .end })).x, 1e-9);
}

test "a sketch in its own space: made there, then inserted on the canvas as a panel" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketchSpace("Plate");
    const home = m.homeOf(m.sketches.items[si].id).?;
    try std.testing.expect(m.isHome(home) and !m.isHome(0));
    try std.testing.expectEqual(1, m.spaces.items[home].sketch_views.items.len);
    // Asked again, the same space.
    try std.testing.expectEqual(home, try m.homeSpace(si));
    try std.testing.expectEqual(2, m.spaces.items.len);
    _ = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 10 } });
    const p = try m.insertSketchPanel(0, si, .{ .x = 50, .y = 50 });
    try std.testing.expectEqual(m.spaces.items[0].id, m.panels.items[p].space);
    try std.testing.expectApproxEqAbs(20, m.panels.items[p].w, 1e-6);
    // Its own space keeps its view.
    try std.testing.expectEqual(1, m.spaces.items[home].sketch_views.items.len);
}

test "a sketch's caption shows in its panel: at its leader's end, with the base text, following both" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketchSpace("Dial");
    const home = m.homeOf(m.sketches.items[si].id).?;
    const g = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 10 } });
    const style = try m.addStyle("Label", .{ .cap_height = 3 });
    const view = m.spaces.items[home].sketch_views.items[0].id;
    const cap = try m.addCaption(view, .{ .curve = g }, style, 4, 30);
    _ = try m.insertText(cap.parent, cap.region, .{ .index = 0 }, "Volume", style);
    const p = try m.insertSketchPanel(0, si, .{ .x = 50, .y = 50 });
    try m.syncCaptions();
    const sc = m.sketches.items[si].captions.items[0];
    var found: ?usize = null;
    for (m.panels.items[p].regions.items, 0..) |r, k| {
        if (r.caption == sc.id) found = k;
    }
    const k = found orelse return error.TestUnexpectedResult;
    const r = m.panels.items[p].regions.items[k];
    // At the leader's end (the sketch's 0,0 at 50,50).
    const e = try m.sketches.items[si].sketch.point(sc.end);
    try std.testing.expectApproxEqAbs(50 + e.x - m.panels.items[p].origin.x, r.origin.x, 1e-6);
    // The base text.
    const f = m.trackFlow(.{ .panel = p }, k).?;
    try std.testing.expectEqual(1, f.items.items.len);
    // The base text changed: the panel's follows; synced again, nothing new.
    _ = try m.insertText(cap.parent, cap.region, .{ .index = 1 }, "\nLevel", style);
    try m.syncCaptions();
    const nb = m.trackFlow(cap.parent, cap.region).?.items.items.len;
    try std.testing.expectEqual(nb, m.trackFlow(.{ .panel = p }, k).?.items.items.len);
    const rev = m.revision;
    try m.syncCaptions();
    try std.testing.expectEqual(rev, m.revision);
    // Edited in place: its own text, the base's changes no longer reach it.
    _ = try m.insertText(.{ .panel = p }, k, .{ .index = 0 }, "Lautstärke ", style);
    try m.syncCaptions();
    const own = m.trackFlow(.{ .panel = p }, k).?.items.items.len;
    try std.testing.expect(m.panels.items[p].regions.items[k].caption_own);
    _ = try m.insertText(cap.parent, cap.region, .{ .index = 0 }, "Master ", style);
    try m.syncCaptions();
    try std.testing.expectEqual(own, m.trackFlow(.{ .panel = p }, k).?.items.items.len);
    // Emptied, it follows the base again.
    m.flows.items[m.trackFlowIndex(.{ .panel = p }, k).?].items.clearRetainingCapacity();
    try m.syncCaptions();
    try std.testing.expect(!m.panels.items[p].regions.items[k].caption_own);
    try std.testing.expectEqual(m.trackFlow(cap.parent, cap.region).?.items.items.len, m.trackFlow(.{ .panel = p }, k).?.items.items.len);
    try std.testing.expectEqual(1, blk: {
        var n: usize = 0;
        for (m.panels.items[p].regions.items) |x| {
            if (x.caption == sc.id) n += 1;
        }
        break :blk n;
    });
}

test "a caption's leader is a connection: drawn in its style, an arrow at the start, converted to a Dubins path in place" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketchSpace("Dial");
    const home = m.homeOf(m.sketches.items[si].id).?;
    const g = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 10 } });
    const style = try m.addStyle("Label", .{ .cap_height = 3 });
    const view = m.spaces.items[home].sketch_views.items[0].id;
    _ = try m.addCaption(view, .{ .curve = g }, style, 4, 30);
    const sid = m.sketches.items[si].id;
    const sc = m.sketches.items[si].captions.items[0];
    const fi = m.sketchFigure(sid).?;
    const Count = struct {
        fn of(ps: []const figure_.Path) [2]usize {
            var n = [2]usize{ 0, 0 };
            for (ps) |x| {
                if (x.fill != null) n[0] += 1;
                if (x.stroke != null) n[1] += 1;
            }
            return n;
        }
    };
    // Drawn where the sketch is edited (its draft) and once accepted.
    const draft = Count.of(if (m.figures.items[fi].draft.len > 0) m.figures.items[fi].draft else m.figures.items[fi].paths);
    try std.testing.expectEqual(1, draft[0]);
    try std.testing.expectEqual(1, draft[1]);
    const e0 = try m.sketches.items[si].sketch.point(sc.end);
    try m.setConnectorKind(sid, sc.connector, .dubins);
    const sk = &m.sketches.items[si].sketch;
    try std.testing.expectEqual(.dubins, sk.connectors.items[sc.connector].kind);
    const e1 = try sk.point(sc.end);
    try std.testing.expectApproxEqAbs(e0.x, e1.x, 1e-6);
    try std.testing.expectApproxEqAbs(e0.y, e1.y, 1e-6);
    // A dot at the end too.
    var cs = m.connector_styles.items[0];
    cs.end = .dot;
    try m.setConnectorStyle(cs);
    const both = Count.of(if (m.figures.items[fi].draft.len > 0) m.figures.items[fi].draft else m.figures.items[fi].paths);
    try std.testing.expectEqual(2, both[0]);
    // No stroke style: annotation, not drawn.
    cs.stroke = .none;
    try m.setConnectorStyle(cs);
    const none = Count.of(if (m.figures.items[fi].draft.len > 0) m.figures.items[fi].draft else m.figures.items[fi].paths);
    try std.testing.expectEqual(0, none[0] + none[1]);
    // A free connection, made to reach the caption's end: in the style.
    const sk2 = &m.sketches.items[si].sketch;
    const k = try m.addConnection(sid, .{ .free = .{ .at = .{ .x = -20, .y = -5 } } }, sc.end, .segments);
    try std.testing.expectEqual(.dubins, m.sketches.items[si].sketch.connectors.items[k].kind);
    try m.setConnectorShape(sid, k, 3, 0.5);
    try std.testing.expectEqual(3, sk2.connectors.items[k].radius);
}

test "a text sheet: a caption's text by its name, default and a language, edited in either" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketchSpace("Dial");
    const home = m.homeOf(m.sketches.items[si].id).?;
    const g = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 10 } });
    const style = try m.addStyle("Label", .{ .cap_height = 3 });
    const view = m.spaces.items[home].sketch_views.items[0].id;
    const cap = try m.addCaption(view, .{ .curve = g }, style, 4, 30);
    _ = try m.insertText(cap.parent, cap.region, .{ .index = 0 }, "Volume", style);
    const p = try m.insertSketchPanel(0, si, .{ .x = 50, .y = 50 });
    const id = try m.makeTextSheet("Texts", &.{ "de", "fr" });
    const sh = m.sheets.items[m.sheetIndex(id).?];
    try std.testing.expectEqualStrings("Caption1", sh.rows.items[0].key);
    try std.testing.expectEqualStrings("Volume", sh.rows.items[0].cells.items[0]);
    try m.setSheetCell(id, 0, 2, "Lautstärke");
    // German shown: the base and the panel's copy say it.
    try m.setSheetShown(id, 1);
    try m.syncSheets();
    const al = std.testing.allocator;
    const base_text = try Model.itemsText(al, m.trackFlow(cap.parent, cap.region).?.items.items);
    defer al.free(base_text);
    try std.testing.expectEqualStrings("Lautstärke", base_text);
    var k: usize = 0;
    for (m.panels.items[p].regions.items, 0..) |r, ri| {
        if (r.caption != .none) k = ri;
    }
    const copy_text = try Model.itemsText(al, m.trackFlow(.{ .panel = p }, k).?.items.items);
    defer al.free(copy_text);
    try std.testing.expectEqualStrings("Lautstärke", copy_text);
    // French empty: the default.
    try m.setSheetShown(id, 2);
    const fr = try Model.itemsText(al, m.trackFlow(cap.parent, cap.region).?.items.items);
    defer al.free(fr);
    try std.testing.expectEqualStrings("Volume", fr);
    // Typed in the caption: into the cell shown.
    _ = try m.insertText(cap.parent, cap.region, .{ .index = 0 }, "Le ", style);
    try m.syncSheets();
    try std.testing.expectEqualStrings("Le Volume", m.sheets.items[m.sheetIndex(id).?].rows.items[0].cells.items[2]);
    try std.testing.expectEqualStrings("Volume", m.sheets.items[m.sheetIndex(id).?].rows.items[0].cells.items[0]);
}

test "ink and fills changed in the editor wait for the sketch's update; discarded, they go" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketch(0, "Drawn", .{ .x = 0, .y = 0 });
    const g = try m.editSketch(si, .{ .segment = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 0 } } });
    const c = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 20, .y = 0 }, .r = 3 } });
    try m.setInkDraft(si, g, true);
    const fi = m.sketchFigure(m.sketches.items[si].id).?;
    // Pending: the editor shows it, the drawing does not have it yet.
    try std.testing.expectEqual(0, m.figures.items[fi].inks.len);
    try std.testing.expectEqual(0, m.figures.items[fi].paths.len);
    try std.testing.expect(m.figures.items[fi].draft.len > 0);
    try std.testing.expect(m.sketches.items[si].accepted != null);
    try m.acceptSketch(si);
    try std.testing.expectEqual(1, m.figures.items[fi].inks.len);
    try std.testing.expect(m.figures.items[fi].pending == null);
    // A fill, then discarded: the drawing as it was.
    try m.setFillDraft(si, &.{c}, true, true);
    try std.testing.expectEqual(0, m.figures.items[fi].fills.len);
    try m.discardSketchDraft(si);
    try std.testing.expectEqual(0, m.figures.items[fi].fills.len);
    try std.testing.expect(m.figures.items[fi].pending == null);
    try std.testing.expectEqual(1, m.figures.items[fi].inks.len);
}

test "several drawings over one sketch: the editor inks in the current one, a panel carries its own" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const si = try m.addSketchSpace("Plate");
    const c = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 10 } });
    const dot = try m.editSketch(si, .{ .circle = .{ .c = .{ .x = 0, .y = 0 }, .r = 2 } });
    try m.setInk(si, c, true);
    const first = m.sketchFigure(m.sketches.items[si].id).?;
    // A second drawing: the dot inked there only.
    const second = try m.addDrawing(si, "Engraved");
    try std.testing.expectEqual(second, m.sketchFigure(m.sketches.items[si].id).?);
    try m.setInk(si, dot, true);
    try std.testing.expectEqual(1, m.figures.items[first].inks.len);
    try std.testing.expectEqual(1, m.figures.items[second].inks.len);
    // A panel made now carries the current drawing (the dot's).
    const p = try m.insertSketchPanel(0, si, .{ .x = 0, .y = 0 });
    var ink_w: f64 = 0;
    for (m.panels.items[p].art.items) |x| if (x.sketch_ink) {
        ink_w = x.box().width();
    };
    try std.testing.expectApproxEqAbs(4.3, ink_w, 0.05);
    // Switched to the first: the ring.
    try m.setPanelDrawing(p, m.figures.items[first].id);
    for (m.panels.items[p].art.items) |x| if (x.sketch_ink) {
        ink_w = x.box().width();
    };
    try std.testing.expectApproxEqAbs(20.3, ink_w, 0.05);
    // The editor's drawing changed back: the panel keeps its own.
    try m.setSketchDrawing(si, m.figures.items[second].id);
    try m.setInk(si, dot, false);
    try std.testing.expectApproxEqAbs(20.3, m.panels.items[p].art.items[0].box().width(), 0.05);
}
