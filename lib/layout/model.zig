//! The panel model: inputs only. Positions, boxes and rendered labels come
//! from `place.solve`, so the model stays the single source of truth.
//!
//! This first slice covers what a PC keyboard needs: a panel holding tile
//! regions, each a list of rows of tiles at a pitch. A tile spanning rows
//! takes a place in each row it crosses; its first row places it. Each tile
//! has one face (its labelling surface) and named slots on it.
//!
//! Lengths are mm; tile sizes and gaps in a tile region are in pitch units
//! (u), so a 1.25u tile at 19.05 mm pitch is 23.8125 mm. Frames are y up.
//! Every change goes through an action function here, so the GUI, the CLI
//! and scripts make the same edits.

const std = @import("std");
const engine = @import("graven_engine");

const Allocator = std.mem.Allocator;
const geom = engine.geom;

pub const TileId = enum(u32) { _ };
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

pub const Slot = struct {
    name: []const u8,
    place: SlotPlace = .{},
    style: StyleId = 0,
    /// Label markup; empty for an empty slot.
    content: []const u8 = "",
};

pub const Tile = struct {
    /// The visible name, unique within its panel (K23, ENTER).
    designator: []const u8,
    /// Width and height in pitch units of its region.
    w: f64 = 1,
    h: f64 = 1,
    /// The tile's body: its pitch box less this inset, mm.
    body_inset: Sides = .{},
    /// Its labelling face: the body less this inset, mm.
    face_inset: Sides = .{},
    slots: std.ArrayList(Slot) = .empty,
    removed: bool = false,
};

/// One place in a row: a tile and the gap before it, in u.
pub const Place = struct {
    tile: TileId,
    gap: f64 = 0,
};

pub const Row = struct {
    /// Space above the row, in u.
    gap: f64 = 0,
    places: std.ArrayList(Place) = .empty,
};

/// A region whose content is rows of tiles, placed in order from the
/// region's top-left corner.
pub const TileRegion = struct {
    name: []const u8,
    /// The region's top-left corner in the panel frame, mm.
    origin: geom.Point,
    /// Its size in u: rows longer than `w` overflow.
    w: f64,
    h: f64,
    /// mm per u.
    pitch: f64,
    rows: std.ArrayList(Row) = .empty,
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

    /// The panel's outline on the worksheet.
    pub fn box(p: Panel) geom.Box {
        return .{ .x0 = p.origin.x, .y0 = p.origin.y, .x1 = p.origin.x + p.w, .y1 = p.origin.y + p.h };
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

    pub fn box(s: Sheet) geom.Box {
        return .{ .x0 = 0, .y0 = 0, .x1 = s.w, .y1 = s.h };
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
    styles: std.ArrayList(LabelStyle) = .empty,
    /// Bumped by every action, so callers can tell when to re-solve.
    revision: u64 = 0,

    pub const Error = Allocator.Error || error{ DuplicateDesignator, NoSuchSlot, NoSuchRow, BadSize };

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
        var p = panel;
        p.name = try m.a().dupe(u8, panel.name);
        p.regions = .empty;
        try m.panels.append(m.a(), p);
        m.revision += 1;
        return m.panels.items.len - 1;
    }

    /// Sets the worksheet's sheet. Panels keep their positions; one left
    /// partly off a smaller sheet is reported by the checks, not moved.
    pub fn setSheet(m: *Model, sheet: Sheet) Error!void {
        if (!(sheet.w > 0 and sheet.h > 0)) return error.BadSize;
        const name = m.sheet.name;
        const default_name = m.sheet.default_name;
        m.sheet = sheet;
        // Size changes keep the worksheet's name.
        m.sheet.name = name;
        m.sheet.default_name = default_name;
        m.revision += 1;
    }

    /// Names the worksheet.
    pub fn nameWorksheet(m: *Model, name: []const u8) Error!void {
        m.sheet.name = try m.a().dupe(u8, name);
        m.sheet.default_name = false;
        m.revision += 1;
    }

    /// Moves a panel on the worksheet.
    pub fn movePanel(m: *Model, panel: usize, origin: geom.Point) void {
        m.panels.items[panel].origin = origin;
        m.revision += 1;
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
        r.rows = .empty;
        const regions = &m.panels.items[panel].regions;
        try regions.append(m.a(), r);
        m.revision += 1;
        return regions.items.len - 1;
    }

    pub fn addRow(m: *Model, panel: usize, region: usize, gap: f64) Error!usize {
        const rows = &m.panels.items[panel].regions.items[region].rows;
        try rows.append(m.a(), .{ .gap = gap });
        m.revision += 1;
        return rows.items.len - 1;
    }

    /// Adds a tile with a designator unique among the model's tiles.
    pub fn addTile(m: *Model, t: Tile) Error!TileId {
        if (!(t.w > 0 and t.h > 0)) return error.BadSize;
        if (m.findTile(t.designator) != null) return error.DuplicateDesignator;
        var copy = t;
        copy.designator = try m.a().dupe(u8, t.designator);
        copy.slots = .empty;
        for (t.slots.items) |s| try copy.slots.append(m.a(), try m.dupeSlot(s));
        try m.tiles.append(m.a(), copy);
        m.revision += 1;
        return @fromBackingInt(@intCast(m.tiles.items.len - 1));
    }

    fn dupeSlot(m: *Model, s: Slot) Allocator.Error!Slot {
        var c = s;
        c.name = try m.a().dupe(u8, s.name);
        c.content = try m.a().dupe(u8, s.content);
        return c;
    }

    pub fn addSlot(m: *Model, id: TileId, s: Slot) Error!void {
        try m.tile(id).slots.append(m.a(), try m.dupeSlot(s));
        m.revision += 1;
    }

    /// Sets a slot's label markup.
    pub fn setContent(m: *Model, id: TileId, slot: []const u8, content: []const u8) Error!void {
        const s = m.findSlot(id, slot) orelse return error.NoSuchSlot;
        s.content = try m.a().dupe(u8, content);
        m.revision += 1;
    }

    /// Puts `id` in a row at `index` (null for the end).
    pub fn place(m: *Model, panel: usize, region: usize, row: usize, index: ?usize, p: Place) Error!void {
        const rows = m.panels.items[panel].regions.items[region].rows.items;
        if (row >= rows.len) return error.NoSuchRow;
        const places = &rows[row].places;
        try places.insert(m.a(), index orelse places.items.len, p);
        m.revision += 1;
    }

    /// Takes `id` out of every row it is in, keeping the tile itself.
    pub fn unplace(m: *Model, id: TileId) void {
        for (m.panels.items) |*panel| for (panel.regions.items) |*region| for (region.rows.items) |*row| {
            var i: usize = 0;
            while (i < row.places.items.len) {
                if (row.places.items[i].tile == id) _ = row.places.orderedRemove(i) else i += 1;
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

    pub fn findSlot(m: *Model, id: TileId, name: []const u8) ?*Slot {
        for (m.tile(id).slots.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
};

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
    _ = try m.addRow(p, r, 0);
    const q = try m.addTile(.{ .designator = "Q" });
    try std.testing.expectError(error.DuplicateDesignator, m.addTile(.{ .designator = "Q" }));
    try m.place(p, r, 0, null, .{ .tile = q });
    try m.addSlot(q, .{ .name = "top", .content = "Q" });
    const before = m.revision;
    try m.setContent(q, "top", "q");
    try std.testing.expect(m.revision > before);
    try std.testing.expectEqualStrings("q", m.findSlot(q, "top").?.content);
    try std.testing.expectError(error.NoSuchSlot, m.setContent(q, "front", "x"));
}
