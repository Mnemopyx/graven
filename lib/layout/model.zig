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
    /// Outline size, mm; the frame's origin is the bottom-left corner.
    w: f64,
    h: f64,
    regions: std.ArrayList(TileRegion) = .empty,
};

pub const LabelStyle = struct {
    name: []const u8,
    /// Face ids index the face table the caller renders with.
    spec: engine.style.Spec,
};

pub const Model = struct {
    /// Owns every string and list in the model.
    arena: std.heap.ArenaAllocator,
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
        if (!(w > 0 and h > 0)) return error.BadSize;
        try m.panels.append(m.a(), .{ .name = try m.a().dupe(u8, name), .w = w, .h = h });
        m.revision += 1;
        return m.panels.items.len - 1;
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
