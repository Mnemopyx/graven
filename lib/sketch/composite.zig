//! Composite objects (the owner, 2026-11-26): regular polygons and arrays
//! made as sealed groups (`constraint.group`) of a kind, holding their
//! construction properties. Their geometry and constraints are the
//! ordinary ones (`polygon.zig`, `arrays.zig`), in the sketch's one solve;
//! the group says they are one object, what kind, and how it was made.
//!
//! Changing a property (`setProp`: five sides to six, eight columns to
//! twelve) makes the object again where it is now, in the same group.
//! Constraints from outside to its geometry are carried over to the
//! geometry that plays the same part (the centre, the first side, the
//! outer ring, the right edge); those on parts that are gone are dropped,
//! and counted. `Remap` says which old geometry became which, for what
//! the sketch's users hold (an array grid's parts, inks, a caption's
//! point).

const std = @import("std");
const geom = @import("graven_geom");
const root = @import("root.zig");
const polygon = @import("polygon.zig");
const arrays = @import("arrays.zig");
const connector = @import("connector.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const Constraint = root.Constraint;
const group = root.group;
const GroupId = group.GroupId;
const Piece = root.pieces.Piece;

pub const Error = root.Error || group.Error || error{ NotAnObject, TooFewBindPoints };

/// Old geometry to new, after an object is made again (`to` null: gone).
pub const Remap = struct {
    pairs: std.ArrayList(struct { from: GeomId, to: ?GeomId }) = .empty,
    /// Constraints from outside dropped, their part being gone.
    dropped: usize = 0,
    /// In: pieces held outside the sketch on its geometry (a drawing's
    /// inks and fills): bindings like its constraints, so a macro's count
    /// goes no lower than they need, and they follow it.
    held: []const Piece = &.{},
    /// Out: a macro's indices along one run renumbered (its count
    /// changed): what holds its bind points and curves follows (`node`,
    /// `part`, `piece`).
    run: ?Run = null,

    pub const Run = struct { geom: GeomId, cols: bool, from: []const u32, to: []const u32 };

    pub fn deinit(r: *Remap, a: Allocator) void {
        r.pairs.deinit(a);
        if (r.run) |run| {
            a.free(run.from);
            a.free(run.to);
        }
    }

    fn index(run: Run, k: u32) u32 {
        if (k == last) return k;
        for (run.from, run.to) |f, t| if (f == k) return t;
        return k;
    }

    /// Point `p` renumbered (a bind point of the macro whose count changed).
    pub fn node(r: *const Remap, p: root.PointRef) root.PointRef {
        const run = r.run orelse return p;
        if (p.geom != run.geom or p.role != .node) return p;
        var o = p;
        if (run.cols) o.i = index(run, p.i) else o.j = index(run, p.j);
        return o;
    }

    /// Curve `p` of `g` renumbered.
    pub fn part(r: *const Remap, g: GeomId, p: root.Part) root.Part {
        const run = r.run orelse return p;
        if (g != run.geom) return p;
        var o = p;
        if ((p.role == .border) == run.cols and p.role != .whole) o.k = index(run, p.k);
        return o;
    }

    /// Piece `p`'s curve and ends renumbered.
    pub fn piece(r: *const Remap, p: Piece) Piece {
        var o = p;
        o.part = r.part(p.geom, p.part);
        if (p.from) |x| o.from = r.node(x);
        if (p.to) |x| o.to = r.node(x);
        return o;
    }

    pub fn get(r: *const Remap, g: GeomId) ?GeomId {
        for (r.pairs.items) |p| if (p.from == g) return p.to;
        return g;
    }

    /// Whether geometry `g` was part of the object made again.
    pub fn moved(r: *const Remap, g: GeomId) bool {
        for (r.pairs.items) |p| if (p.from == g) return true;
        return false;
    }
};

fn since(s: *const Sketch, a: Allocator, first: usize) Allocator.Error![]GeomId {
    var out: std.ArrayList(GeomId) = .empty;
    for (first..s.geometry.items.len) |g| try out.append(a, @intCast(g));
    return out.toOwnedSlice(a);
}

fn seal(s: *Sketch, a: Allocator, first: usize, kind: group.Kind) Error!GroupId {
    const ids = try since(s, a, first);
    defer a.free(ids);
    return s.makeGroup(a, ids, &.{}, kind, true);
}

/// A regular polygon (`polygon.addRegular`) as an object.
pub fn addPolygon(s: *Sketch, a: Allocator, c: Point, corner: Point, n: u32, construction: bool) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try polygon.addRegular(s, a, c, corner, n, construction);
    const id = try seal(s, a, first, .regular_polygon);
    try s.groups.setProp(a, id, "sides", @floatFromInt(n));
    try s.groups.setProp(a, id, "construction", if (construction) 1 else 0);
    return id;
}

/// A polar array (`arrays.addPolar`) as an object.
pub fn addPolar(s: *Sketch, a: Allocator, c: Point, r: f64, first_angle: f64, sweep: f64, cols: u32, rings: u32) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try arrays.addPolar(s, a, c, r, first_angle, sweep, cols, rings);
    const id = try seal(s, a, first, .polar_array);
    try s.groups.setProp(a, id, "columns", @floatFromInt(cols));
    try s.groups.setProp(a, id, "rings", @floatFromInt(rings));
    try s.groups.setProp(a, id, "sweep", @min(sweep, 2 * std.math.pi));
    return id;
}

/// A polar grid as a macro object (the owner, 2026-11-27): one geometry,
/// `Sketch.addPolarGrid`'s, its driving unknowns a centre, two radii and
/// two angles; its counts are properties. See `setCount`.
pub fn addPolarGrid(s: *Sketch, a: Allocator, c: Point, r0: f64, r1: f64, t0: f64, t1: f64, cols: u32, rings: u32) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try s.addPolarGrid(a, c, r0, r1, t0, t1, cols, rings, true);
    const id = try seal(s, a, first, .polar_grid);
    try s.groups.setProp(a, id, "columns", @floatFromInt(cols));
    try s.groups.setProp(a, id, "rings", @floatFromInt(rings));
    return id;
}

/// A dial as a macro object (the owner, 2026-11-28; `geometry.PolarGrid.
/// Dial`): a polar grid whose borders are ticks, its driving unknowns a
/// centre, four radii (outer, large ticks' and small ticks' inner ends,
/// labels) and two angles; its properties `large` (large ticks' intervals),
/// `small` (small ticks between two large) and `clockwise` (which way it
/// runs from its first angle, whose order its angles keep).
pub fn addDial(s: *Sketch, a: Allocator, c: Point, radii: [4]f64, t0: f64, t1: f64, large: u32, per: u32) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try s.addDial(a, c, radii, t0, t1, large, per, true);
    const id = try seal(s, a, first, .dial);
    try s.groups.setProp(a, id, "large", @floatFromInt(large));
    try s.groups.setProp(a, id, "small", @floatFromInt(per));
    try s.groups.setProp(a, id, "clockwise", if (t1 < t0) 1 else 0);
    return id;
}

/// A tessellation as a macro object (the owner, 2026-11-28): one
/// geometry (`tessellation.add`'s), filling the closed path `outline`,
/// its driving unknowns a tile's centre, the spacing, the turn and the
/// margin; its tile's sides and whether only whole tiles are kept are
/// properties. Nothing is made again when any of them changes.
pub fn addTessellation(s: *Sketch, a: Allocator, outline: []const root.pieces.Piece, c: Point, sides: u32, spacing: f64, whole: bool) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try root.tessellation.add(s, a, outline, c, sides, spacing, whole);
    const id = try seal(s, a, first, .tessellation);
    try s.groups.setProp(a, id, "sides", @floatFromInt(sides));
    try s.groups.setProp(a, id, "whole", if (whole) 1 else 0);
    return id;
}

/// A macro object's one geometry (a polar grid's, a tessellation's), if
/// it is one.
pub fn macroGeometry(s: *const Sketch, id: GroupId) ?GeomId {
    const g = s.groups.get(id) catch return null;
    if (!isMacro(g.kind) or g.geometry.items.len == 0) return null;
    const m = g.geometry.items[0];
    if (m >= s.geometry.items.len) return null;
    return switch (s.geometry.items[m].kind) {
        .polar_grid, .tessellation => m,
        else => null,
    };
}

/// A tessellation's value `name` set: its properties `sides` (3, 4, 6)
/// and `whole` (0 or 1), or its driving values `spacing`, `angle`
/// (radians), `margin`, `x` and `y` (its tile centre). Nothing is made
/// again: its tiles are worked out from these.
fn setTessellation(s: *Sketch, a: Allocator, id: GroupId, name: []const u8, value: f64) Error!void {
    const m = macroGeometry(s, id) orelse return error.NotAnObject;
    const t = &s.geometry.items[m].kind.tessellation;
    const v = s.vars.items;
    const eq = std.mem.eql;
    if (!std.math.isFinite(value)) return error.WrongKind;
    if (eq(u8, name, "sides")) {
        const n: u32 = @intFromFloat(@max(0, @round(value)));
        if (!root.tessellation.validSides(n)) return error.WrongKind;
        t.sides = n;
        try s.groups.setProp(a, id, name, @floatFromInt(n));
    } else if (eq(u8, name, "whole")) {
        t.whole = value != 0;
        try s.groups.setProp(a, id, name, if (t.whole) 1 else 0);
    } else if (eq(u8, name, "spacing")) {
        if (!(value > 0)) return error.WrongKind;
        v[t.spacing] = value;
    } else if (eq(u8, name, "angle")) {
        v[t.angle] = value;
    } else if (eq(u8, name, "margin")) {
        if (value < 0) return error.WrongKind;
        v[t.margin] = value;
    } else if (eq(u8, name, "x")) {
        v[t.c.x] = value;
    } else if (eq(u8, name, "y")) {
        v[t.c.y] = value;
    } else return error.WrongKind;
}

/// The constraints on bind points a macro object no longer has (a count
/// lowered): kept, left out of solving, each a problem to fix (raise the
/// count again, or remove the constraint). Into `out`.
pub fn abandoned(s: *const Sketch, a: Allocator, out: *std.ArrayList(root.ConstraintId)) Allocator.Error!void {
    const st = s.store();
    for (s.constraints.items, 0..) |c, ci| if (st.abandoned(c)) try out.append(a, @intCast(ci));
}

/// The count a constraint on a vanished bind point needs back: the least
/// value of property `name` (`columns` or `rings`) under which every bind
/// point it names is there again (null: not that).
pub fn countNeeded(s: *const Sketch, c: Constraint, name: []const u8) ?u32 {
    var buf: [4]root.Ref = undefined;
    var need: ?u32 = null;
    for (root.refs(c, &buf)) |r| switch (r) {
        .point => |p| if (p.role == .node and p.geom < s.geometry.items.len) switch (s.geometry.items[p.geom].kind) {
            .polar_grid => |pg| {
                // A dial's ticks: as many large ones as reach it.
                if (pg.dial) |d| {
                    if (std.mem.eql(u8, name, "large") and p.i != root.geometry.last and p.i > pg.cols)
                        need = @max(need orelse 0, std.math.divCeil(u32, p.i, d.per + 1) catch p.i);
                    continue;
                }
                const k = if (std.mem.eql(u8, name, "columns")) p.i else p.j;
                const n = if (std.mem.eql(u8, name, "columns")) pg.cols else pg.rings;
                if (k != root.geometry.last and k > n) need = @max(need orelse 0, k);
            },
            else => {},
        },
        .geom => {},
    };
    return need;
}

/// A rectangular array (`arrays.addRect`) as an object.
pub fn addRect(s: *Sketch, a: Allocator, b: geom.Box, cols: u32, rows: u32) Error!GroupId {
    const first = s.geometry.items.len;
    _ = try arrays.addRect(s, a, b, cols, rows);
    const id = try seal(s, a, first, .rect_array);
    try s.groups.setProp(a, id, "columns", @floatFromInt(cols));
    try s.groups.setProp(a, id, "rows", @floatFromInt(rows));
    return id;
}

fn count(g: *const group.Group, name: []const u8) u32 {
    return @intFromFloat(@max(0, @round(g.prop(name) orelse 0)));
}

/// The part a member plays, which survives a change of counts: a tag and
/// an index (`last` for the last of a run, which stays the last).
const Role = struct {
    tag: u8,
    i: u32 = 0,
};

const last: u32 = std.math.maxInt(u32);

/// Each member's role, in the order the builder made them.
fn roles(s: *const Sketch, a: Allocator, g: *const group.Group) Error![]Role {
    var out: std.ArrayList(Role) = .empty;
    errdefer out.deinit(a);
    switch (g.kind) {
        .regular_polygon => {
            const n = count(g, "sides");
            try out.append(a, .{ .tag = 0 }); // the circle through the corners
            for (0..n) |i| try out.append(a, .{ .tag = 1, .i = @intCast(i) });
            try out.append(a, .{ .tag = 2 }); // the inscribed circle
        },
        .rect_array => {
            const cols = count(g, "columns");
            const rows = count(g, "rows");
            for (0..cols + 1) |i| try out.append(a, if (i == 0) .{ .tag = 0 } else if (i == cols) .{ .tag = 1 } else .{ .tag = 2, .i = @intCast(i) });
            for (0..rows + 1) |j| try out.append(a, if (j == 0) .{ .tag = 3 } else if (j == rows) .{ .tag = 4 } else .{ .tag = 5, .i = @intCast(j) });
        },
        .polar_array => {
            const cols = count(g, "columns");
            const rings = count(g, "rings");
            const full = (g.prop("sweep") orelse 0) >= 2 * std.math.pi - 1e-9;
            const lines: u32 = if (full) cols else cols + 1;
            try out.append(a, .{ .tag = 0 }); // the centre
            for (0..lines) |i| try out.append(a, if (!full and i == lines - 1) .{ .tag = 1, .i = last } else .{ .tag = 1, .i = @intCast(i) });
            for (1..rings + 1) |k| {
                if (k == rings) {
                    try out.append(a, .{ .tag = 2, .i = last }); // the outer ring
                } else {
                    try out.append(a, .{ .tag = 2, .i = @intCast(k) });
                    if (full) try out.append(a, .{ .tag = 3, .i = @intCast(k) }); // its mark
                }
            }
        },
        else => return error.NotAnObject,
    }
    _ = s;
    return out.toOwnedSlice(a);
}

/// Where an object is: a polygon's centre and a corner; a polar array's
/// centre, outer radius and first border's angle (radians); a rectangular
/// array's box.
pub const Placement = union(enum) {
    polygon: struct { c: Point, corner: Point },
    /// A polar grid's centre, outer radius and first angle, as a polar
    /// array's (its other radius and angle follow in proportion).
    grid: struct { c: Point, r: f64, first: f64 },
    polar: struct { c: Point, r: f64, first: f64 },
    rect: geom.Box,
};

fn placement(s: *const Sketch, g: *const group.Group) Error!Placement {
    const m = g.geometry.items;
    switch (g.kind) {
        .regular_polygon => {
            if (m.len < 2) return error.NotAnObject;
            return .{ .polygon = .{ .c = try s.point(.{ .geom = m[0], .role = .centre }), .corner = try s.point(.{ .geom = m[1], .role = .start }) } };
        },
        .polar_array => {
            if (m.len < 2) return error.NotAnObject;
            const c = try s.point(.{ .geom = m[0] });
            const e = try s.point(.{ .geom = m[1], .role = .end });
            return .{ .polar = .{ .c = c, .r = std.math.hypot(e.x - c.x, e.y - c.y), .first = std.math.atan2(e.y - c.y, e.x - c.x) } };
        },
        .polar_grid, .dial => {
            if (m.len < 1) return error.NotAnObject;
            const pg = switch (s.geometry.items[m[0]].kind) {
                .polar_grid => |x| x,
                else => return error.NotAnObject,
            };
            const v = s.vars.items;
            return .{ .grid = .{ .c = .{ .x = v[pg.c.x], .y = v[pg.c.y] }, .r = @max(v[pg.r[0]], v[pg.r[1]]), .first = v[pg.t[0]] } };
        },
        .rect_array => {
            const cols = count(g, "columns");
            if (m.len < cols + 1) return error.NotAnObject;
            const tl = try s.point(.{ .geom = m[0], .role = .start });
            const br = try s.point(.{ .geom = m[cols], .role = .end });
            return .{ .rect = .{ .x0 = @min(tl.x, br.x), .x1 = @max(tl.x, br.x), .y0 = @min(tl.y, br.y), .y1 = @max(tl.y, br.y) } };
        },
        else => return error.NotAnObject,
    }
}

/// Object `id`'s array parts by ID (for an array grid), as made.
pub fn arrayRefs(s: *const Sketch, id: GroupId) Error!arrays.Refs {
    const g = try s.groups.get(id);
    const m = g.geometry.items;
    switch (g.kind) {
        .polar_array => {
            const cols = count(g, "columns");
            const full = (g.prop("sweep") orelse 0) >= 2 * std.math.pi - 1e-9;
            const lines: u32 = if (full) cols else cols + 1;
            if (m.len < lines + 2) return error.NotAnObject;
            return .{ .polar = .{ .centre = m[0], .first = m[1], .second = m[1 + (1 % lines)], .outer = m[m.len - 1] } };
        },
        .rect_array => {
            const cols = count(g, "columns");
            const rows = count(g, "rows");
            if (m.len < cols + rows + 2) return error.NotAnObject;
            return .{ .rect = .{ .left = m[0], .right = m[cols], .top = m[cols + 1], .bottom = m[cols + 1 + rows] } };
        },
        else => return error.NotAnObject,
    }
}

/// The object directly holding geometry `g`, if any (the outermost sealed
/// group round it).
pub fn objectOf(s: *const Sketch, g: GeomId) ?GroupId {
    if (g >= s.geometry.items.len) return null;
    const at = s.groups.objectOf(s.geometry.items[g].group);
    return if (at == group.none) null else at;
}

// Sealing (the owner, 2026-11-26): an object's members and its own
// constraints are not edited one by one; only its properties, the
// transforms it leaves free, and constraints from its parts to what is
// outside it. These say what that rule refuses; the editor applies it.

/// Geometry `g` is a member of an object (directly or deeper).
pub fn sealedGeometry(s: *const Sketch, g: GeomId) bool {
    return objectOf(s, g) != null;
}

/// Constraint `c` is internal to an object.
pub fn sealedConstraint(s: *const Sketch, c: root.ConstraintId) bool {
    if (c >= s.constraints.items.len) return false;
    return sealedBy(s, s.groups.objectOf(s.constraints.items[c].group));
}

/// Constraint `c`, added, would be internal to an object: everything it
/// names is in one. One naming something outside too is external.
pub fn sealsConstraint(s: *const Sketch, c: Constraint) bool {
    return sealedBy(s, s.groups.objectOf(s.groups.userHome(s.geometry.items, c)));
}

/// Whether a constraint homed in object `o` is its own (not editable). A
/// macro object has no constraints of its own: every constraint on its
/// bind points, even between two of them (its radius as a distance from
/// its centre), is the user's, how it is held.
fn sealedBy(s: *const Sketch, o: GroupId) bool {
    if (o == group.none) return false;
    const g = s.groups.get(o) catch return true;
    return !isMacro(g.kind);
}

/// A macro object: driving geometry and counts, made by no constraints.
pub fn isMacro(kind: group.Kind) bool {
    return kind == .polar_grid or kind == .dial or kind == .tessellation;
}

/// Where object `id` is now.
pub fn placementOf(s: *const Sketch, id: GroupId) Error!Placement {
    return placement(s, try s.groups.get(id));
}

/// A map of the plane: `p' = (xx·x + xy·y + tx, yx·x + yy·y + ty)`.
const Map = struct {
    xx: f64 = 1,
    xy: f64 = 0,
    yx: f64 = 0,
    yy: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,

    fn at(m: Map, p: Point) Point {
        return .{ .x = m.xx * p.x + m.xy * p.y + m.tx, .y = m.yx * p.x + m.yy * p.y + m.ty };
    }

    fn dir(m: Map, d: Point) Point {
        return .{ .x = m.xx * d.x + m.xy * d.y, .y = m.yx * d.x + m.yy * d.y };
    }

    /// The scale it gives lengths, when it keeps shapes (else null).
    fn scale(m: Map) ?f64 {
        if (@abs(m.xx - m.yy) > 1e-12 * @max(1, @abs(m.xx)) or @abs(m.xy + m.yx) > 1e-12 * @max(1, @abs(m.xy))) return null;
        return std.math.hypot(m.xx, m.yx);
    }

    /// Turning by `t` and scaling by `k` about `from`, then moving it to `to`.
    fn similar(from: Point, to: Point, t: f64, k: f64) Map {
        const c = k * @cos(t);
        const sn = k * @sin(t);
        return .{ .xx = c, .xy = -sn, .yx = sn, .yy = c, .tx = to.x - (c * from.x - sn * from.y), .ty = to.y - (sn * from.x + c * from.y) };
    }
};

/// Moves object `id` to `to` (of its own kind): its geometry is mapped
/// there (a rectangular array's box scaled and moved; a polygon or a polar
/// array turned, scaled and moved about its centre), its IDs kept, so what
/// holds them (grids, inks, constraints from outside) is unchanged. The
/// sketch is not solved: its caller solves it.
pub fn place(s: *Sketch, a: Allocator, id: GroupId, to: Placement) Error!void {
    const now = try placementOf(s, id);
    if (std.meta.activeTag(now) != std.meta.activeTag(to)) return error.WrongKind;
    const map: Map = switch (now) {
        .rect => |b| blk: {
            const t = to.rect;
            if (!(b.x1 > b.x0 and b.y1 > b.y0 and t.x1 > t.x0 and t.y1 > t.y0)) return error.WrongKind;
            const sx = (t.x1 - t.x0) / (b.x1 - b.x0);
            const sy = (t.y1 - t.y0) / (b.y1 - b.y0);
            break :blk .{ .xx = sx, .yy = sy, .tx = t.x0 - sx * b.x0, .ty = t.y0 - sy * b.y0 };
        },
        .polar => |p| blk: {
            const t = to.polar;
            if (!(p.r > 0 and t.r > 0)) return error.WrongKind;
            break :blk Map.similar(p.c, t.c, t.first - p.first, t.r / p.r);
        },
        .grid => |p| blk: {
            const t = to.grid;
            if (!(p.r > 0 and t.r > 0)) return error.WrongKind;
            break :blk Map.similar(p.c, t.c, t.first - p.first, t.r / p.r);
        },
        .polygon => |p| blk: {
            const t = to.polygon;
            const r0 = std.math.hypot(p.corner.x - p.c.x, p.corner.y - p.c.y);
            const r1 = std.math.hypot(t.corner.x - t.c.x, t.corner.y - t.c.y);
            if (!(r0 > 0 and r1 > 0)) return error.WrongKind;
            const turn = std.math.atan2(t.corner.y - t.c.y, t.corner.x - t.c.x) - std.math.atan2(p.corner.y - p.c.y, p.corner.x - p.c.x);
            break :blk Map.similar(p.c, t.c, turn, r1 / r0);
        },
    };
    var members: std.ArrayList(GeomId) = .empty;
    defer members.deinit(a);
    try s.groups.internalGeometry(a, id, &members);
    // Checked first, so a map that cannot be made changes nothing.
    for (members.items) |g| switch (s.geometry.items[g].kind) {
        .circle, .polar_grid, .tessellation => if (map.scale() == null) return error.WrongKind,
        .affine => return error.WrongKind,
        else => {},
    };
    const v = s.vars.items;
    const P = struct {
        fn set(vars: []f64, m: Map, p: root.Pt) void {
            const q = m.at(.{ .x = vars[p.x], .y = vars[p.y] });
            vars[p.x] = q.x;
            vars[p.y] = q.y;
        }
    };
    for (members.items) |g| {
        const geo = s.geometry.items[g];
        if (geo.removed or geo.reference) continue;
        switch (geo.kind) {
            .point => |p| P.set(v, map, p),
            .segment => |sg| {
                P.set(v, map, sg.a);
                P.set(v, map, sg.b);
            },
            .circle => |c| {
                P.set(v, map, c.c);
                v[c.r] *= map.scale().?;
            },
            .arc => |ar| {
                P.set(v, map, ar.c);
                P.set(v, map, ar.a);
                P.set(v, map, ar.b);
            },
            .ray => |ry| {
                P.set(v, map, ry.o);
                const d = map.dir(.{ .x = @cos(v[ry.angle]), .y = @sin(v[ry.angle]) });
                v[ry.angle] = std.math.atan2(d.y, d.x);
            },
            .line => |ln| {
                const n: Point = .{ .x = @cos(v[ln.theta]), .y = @sin(v[ln.theta]) };
                const p = map.at(.{ .x = v[ln.rho] * n.x, .y = v[ln.rho] * n.y });
                const d = map.dir(.{ .x = -n.y, .y = n.x });
                const theta = std.math.atan2(d.y, d.x) + std.math.pi / 2.0;
                v[ln.theta] = theta;
                v[ln.rho] = @cos(theta) * p.x + @sin(theta) * p.y;
            },
            .polar_grid => |pg| {
                // Its centre mapped, its radii scaled, its angles turned.
                P.set(v, map, pg.c);
                const k = map.scale() orelse 1;
                v[pg.r[0]] *= k;
                v[pg.r[1]] *= k;
                if (pg.dial) |d| {
                    v[d.small] *= k;
                    v[d.label] *= k;
                }
                const turn = std.math.atan2(map.yx, map.xx);
                v[pg.t[0]] += turn;
                v[pg.t[1]] += turn;
            },
            .tessellation => |t| {
                // Its tile centre mapped, its spacing scaled, its turn
                // turned (the area it fills is the sketch's, not its own).
                P.set(v, map, t.c);
                v[t.spacing] *= map.scale() orelse 1;
                v[t.angle] += std.math.atan2(map.yx, map.xx);
            },
            .affine => unreachable,
        }
    }
}

/// Removes object (or group) `id` whole: every member, the constraints on
/// them (its own and outside ones), and the group with those inside it.
pub fn removeObject(s: *Sketch, a: Allocator, id: GroupId) Error!void {
    var geoms: std.ArrayList(GeomId) = .empty;
    defer geoms.deinit(a);
    try s.groups.internalGeometry(a, id, &geoms);
    for (geoms.items) |g| {
        if (g < s.geometry.items.len and !s.geometry.items[g].removed and !s.geometry.items[g].reference) try s.removeGeometry(g);
    }
    try s.groups.remove(a, id);
}

/// Sets construction property `name` of object `id` to `value` and makes
/// it again, where it is (see the file's comment). What became of its old
/// geometry goes in `remap`. `a` is the sketch's own allocator (its lists
/// grow in it), used for scratch too.
pub fn setProp(s: *Sketch, a: Allocator, id: GroupId, name: []const u8, value: f64, remap: *Remap) Error!void {
    const g = try s.groups.get(id);
    if (g.kind == .plain or g.kind == .connection or g.kind == .caption) return error.NotAnObject;
    if (g.kind == .polar_grid or g.kind == .dial) return setCount(s, a, id, name, value, remap);
    if (g.kind == .tessellation) return setTessellation(s, a, id, name, value);
    const kind = g.kind;
    const where = try placement(s, g);
    const old_roles = try roles(s, a, g);
    defer a.free(old_roles);
    const old = try a.dupe(GeomId, g.geometry.items);
    defer a.free(old);
    if (old.len != old_roles.len) return error.NotAnObject;

    // Constraints from outside on its geometry, to carry over.
    var outside: std.ArrayList(Constraint) = .empty;
    defer outside.deinit(a);
    for (s.constraints.items) |c| {
        if (s.groups.within(c.group, id)) continue;
        for (old) |m| if (root.refersTo(c, m)) {
            try outside.append(a, c);
            break;
        };
    }

    try s.groups.setProp(a, id, name, value);
    const gg = try s.groups.get(id);
    // The new counts must make an object; else nothing changes.
    const ok = switch (kind) {
        .regular_polygon => count(gg, "sides") >= 3,
        .rect_array => count(gg, "columns") >= 1 and count(gg, "rows") >= 1,
        .polar_array => count(gg, "columns") >= 1 and count(gg, "rings") >= 1 and (gg.prop("sweep") orelse 0) > 0,
        else => false,
    };
    if (!ok) return error.WrongKind;

    try s.groups.release(s.geometry.items, id);
    for (old) |m| try s.removeGeometry(m);

    const first = s.geometry.items.len;
    switch (where) {
        .polygon => |p| _ = try polygon.addRegular(s, a, p.c, p.corner, count(gg, "sides"), (gg.prop("construction") orelse 0) != 0),
        .polar => |p| _ = try arrays.addPolar(s, a, p.c, p.r, p.first, gg.prop("sweep").?, count(gg, "columns"), count(gg, "rings")),
        .grid => unreachable,
        .rect => |b| _ = try arrays.addRect(s, a, b, count(gg, "columns"), count(gg, "rows")),
    }
    const made = try since(s, a, first);
    defer a.free(made);
    try s.groups.adopt(a, s.geometry.items, s.constraints.items, id, made);
    const new_roles = try roles(s, a, try s.groups.get(id));
    defer a.free(new_roles);

    for (old, old_roles) |m, r| {
        var to: ?GeomId = null;
        for (made, new_roles) |n, q| if (q.tag == r.tag and q.i == r.i) {
            to = n;
            break;
        };
        try remap.pairs.append(a, .{ .from = m, .to = to });
    }
    // The constraints from outside, on the new parts.
    for (outside.items) |c_in| {
        var c = c_in;
        if (!root.geometry.mapGeoms(&c, remap, mapOne)) {
            remap.dropped += 1;
            continue;
        }
        _ = s.addConstraint(a, c) catch {
            remap.dropped += 1;
        };
    }
    // Connections attached to its parts.
    for (s.connectors.items) |*k| {
        switch (k.from) {
            .point => |*p| p.geom = remap.get(p.geom) orelse p.geom,
            .curve => |*cv| cv.* = remap.get(cv.*) orelse cv.*,
            .free => {},
        }
        if (k.normal) |n| k.normal = remap.get(n) orelse n;
    }
}

/// A macro object's count set (the owner, 2026-11-27/28): nothing is
/// made again and no unknown moves; only how many sections are drawn and
/// which bind points there are change. Bindings (constraints on its bind
/// points) move with the count: each bound index to the same fraction of
/// the run, in order, kept apart, the ends staying ends. A count may drop
/// only while there are bind points enough for every binding along that
/// run; below that, `error.TooFewBindPoints`, and bindings are removed by
/// hand first (`boundIndices` says how many there are).
fn setCount(s: *Sketch, a: Allocator, id: GroupId, name: []const u8, value: f64, remap: *Remap) Error!void {
    const m = macroGeometry(s, id) orelse return error.NotAnObject;
    if (s.geometry.items[m].kind.polar_grid.dial != null) return setDial(s, a, id, m, name, value, remap);
    const n: u32 = @intFromFloat(@max(0, @round(value)));
    if (n < 1 or n > 10_000) return error.WrongKind;
    const cols = std.mem.eql(u8, name, "columns");
    if (!cols and !std.mem.eql(u8, name, "rings")) return error.WrongKind;
    const pg = &s.geometry.items[m].kind.polar_grid;
    const old = if (cols) pg.cols else pg.rings;
    try remapRun(s, a, m, cols, old, n, remap);
    if (cols) pg.cols = n else pg.rings = n;
    try s.groups.setProp(a, id, name, @floatFromInt(n));
}

/// A dial's property set: `large` (its large ticks' intervals), `small`
/// (small ticks between two large: 0 for none) or `clockwise` (0 or 1:
/// its second angle put the other way round from its first, the same
/// sweep). The counts change its borders' count (large × (small + 1)),
/// bindings following as a grid's do, so a large tick stays a large tick.
fn setDial(s: *Sketch, a: Allocator, id: GroupId, m: GeomId, name: []const u8, value: f64, remap: *Remap) Error!void {
    const eq = std.mem.eql;
    if (!std.math.isFinite(value)) return error.WrongKind;
    const pg = &s.geometry.items[m].kind.polar_grid;
    const v = s.vars.items;
    if (eq(u8, name, "clockwise")) {
        const cw = value != 0;
        const sw = v[pg.t[1]] - v[pg.t[0]];
        if ((sw < 0) != cw) v[pg.t[1]] = v[pg.t[0]] - sw;
        try s.groups.setProp(a, id, name, if (cw) 1 else 0);
        return;
    }
    const n: u32 = @intFromFloat(@max(0, @round(value)));
    var large = pg.largeCount();
    var per = pg.dial.?.per;
    if (eq(u8, name, "large")) {
        if (n < 1 or n > 1000) return error.WrongKind;
        large = n;
    } else if (eq(u8, name, "small")) {
        if (n > 100) return error.WrongKind;
        per = n;
    } else return error.WrongKind;
    const cols = large * (per + 1);
    try remapRun(s, a, m, true, pg.cols, cols, remap);
    pg.cols = cols;
    pg.dial.?.per = per;
    try s.groups.setProp(a, id, "large", @floatFromInt(large));
    try s.groups.setProp(a, id, "small", @floatFromInt(per));
}

/// A macro's run (`cols`: its borders, else its rings) from `old` to `n`:
/// every binding along it renumbered to the same fraction along (in
/// order, kept apart, ends staying ends), into `remap.run`; refused
/// (`TooFewBindPoints`) when there are more bindings than places.
fn remapRun(s: *Sketch, a: Allocator, m: GeomId, cols: bool, old: u32, n: u32, remap: *Remap) Error!void {
    if (n != old) {
        // The distinct bound indices along this run, in order.
        const bound = try boundIndices(s, a, m, cols, remap.held);
        errdefer a.free(bound);
        if (bound.len > n + 1) return error.TooFewBindPoints;
        const to = try a.alloc(u32, bound.len);
        errdefer a.free(to);
        for (bound, to) |b, *t| {
            t.* = if (b == old) n else @intFromFloat(@round(@as(f64, @floatFromInt(b)) * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(old))));
        }
        // Kept in order and apart, within 0..n.
        for (to, 0..) |*t, k| {
            if (k > 0) t.* = @max(t.*, to[k - 1] + 1);
        }
        var k = to.len;
        while (k > 0) {
            k -= 1;
            const room: u32 = n - @as(u32, @intCast(to.len - 1 - k));
            to[k] = @min(to[k], room);
            if (k + 1 < to.len) to[k] = @min(to[k], to[k + 1] - 1);
        }
        if (remap.run) |old_run| {
            a.free(old_run.from);
            a.free(old_run.to);
        }
        remap.run = .{ .geom = m, .cols = cols, .from = bound, .to = to };
        for (s.constraints.items) |*c| {
            var buf: [8]*root.PointRef = undefined;
            for (root.geometry.pointRefs(c, &buf)) |r| r.* = remap.node(r.*);
            switch (c.kind) {
                .point_on => |*po| po.part = remap.part(po.on, po.part),
                else => {},
            }
        }
    }
}

/// The distinct indices along a macro's run (`cols`: its borders, else its
/// rings) that constraints are bound to, `last` read as the count, in
/// order. Owned by `a`.
pub fn boundIndices(s: *const Sketch, a: Allocator, m: GeomId, cols: bool, held: []const Piece) Allocator.Error![]u32 {
    const pg = s.geometry.items[m].kind.polar_grid;
    const n = if (cols) pg.cols else pg.rings;
    var out: std.ArrayList(u32) = .empty;
    const B = struct {
        fn add(al: Allocator, o: *std.ArrayList(u32), k: ?u32) Allocator.Error!void {
            const x = k orelse return;
            if (std.mem.indexOfScalar(u32, o.items, x) == null) try o.append(al, x);
        }
    };
    const P = root.geometry.PolarGrid;
    const nodeAt = struct {
        fn f(r: root.PointRef, mm: GeomId, c: bool, nn: u32) ?u32 {
            if (r.geom != mm or r.role != .node) return null;
            return P.index(if (c) r.i else r.j, nn);
        }
    }.f;
    // A ring is on the rings' run, a border on the borders'.
    const partAt = struct {
        fn f(g: GeomId, p: root.Part, mm: GeomId, c: bool, nn: u32) ?u32 {
            if (g != mm or p.role == .whole or (p.role == .border) != c) return null;
            return P.index(p.k, nn);
        }
    }.f;
    for (s.constraints.items) |c_in| {
        var c = c_in;
        var buf: [8]*root.PointRef = undefined;
        for (root.geometry.pointRefs(&c, &buf)) |r| try B.add(a, &out, nodeAt(r.*, m, cols, n));
        switch (c.kind) {
            .point_on => |po| try B.add(a, &out, partAt(po.on, po.part, m, cols, n)),
            else => {},
        }
    }
    for (held) |p| {
        try B.add(a, &out, partAt(p.geom, p.part, m, cols, n));
        if (p.from) |r| try B.add(a, &out, nodeAt(r, m, cols, n));
        if (p.to) |r| try B.add(a, &out, nodeAt(r, m, cols, n));
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return out.toOwnedSlice(a);
}

/// How few of property `name` (`columns` or `rings`) object `id` may have:
/// enough bind points for every binding along that run (at least 1).
pub fn countFloor(s: *const Sketch, a: Allocator, id: GroupId, name: []const u8, held: []const Piece) Allocator.Error!u32 {
    const m = macroGeometry(s, id) orelse return 1;
    const pg = switch (s.geometry.items[m].kind) {
        .polar_grid => |x| x,
        else => return 1,
    };
    const eq = std.mem.eql;
    const b = try boundIndices(s, a, m, if (pg.dial != null) true else eq(u8, name, "columns"), held);
    defer a.free(b);
    const need = @max(1, @as(u32, @intCast(b.len)) -| 1);
    // A dial's borders are its large count times one more than its small.
    if (pg.dial) |d| {
        if (eq(u8, name, "large")) return @max(1, std.math.divCeil(u32, need, d.per + 1) catch need);
        if (eq(u8, name, "small")) return (std.math.divCeil(u32, need, @max(pg.largeCount(), 1)) catch need) -| 1;
    }
    return need;
}

fn mapOne(r: *Remap, g: GeomId) ?GeomId {
    return r.get(g);
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

test "a polygon is an object; more sides make it again in place, outside constraints carried over" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const id = try addPolygon(&s, al, .{ .x = 5, .y = 5 }, .{ .x = 15, .y = 5 }, 5, false);
    const g = try s.groups.get(id);
    try testing.expect(g.sealed);
    try testing.expectEqual(group.Kind.regular_polygon, g.kind);
    try testing.expectEqual(@as(?f64, 5), g.prop("sides"));
    // Its centre held to the origin from outside: an external constraint.
    const circle = g.geometry.items[0];
    _ = try s.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = circle, .role = .centre }, .{ .geom = root.origin } } } });
    try testing.expectEqual(group.none, s.constraints.items[s.constraints.items.len - 1].group);
    _ = try s.solve(al);
    try testing.expectEqual(id, objectOf(&s, g.geometry.items[3]).?);

    var remap: Remap = .{};
    try setProp(&s, al, id, "sides", 6, &remap);
    const g6 = try s.groups.get(id);
    try testing.expectEqual(@as(usize, 6 + 2), g6.geometry.items.len);
    try testing.expectEqual(@as(usize, 0), remap.dropped);
    const new_circle = remap.get(circle).?;
    try testing.expect(new_circle != circle);
    _ = try s.solve(al);
    const c = try s.point(.{ .geom = new_circle, .role = .centre });
    try testing.expectApproxEqAbs(0, c.x, 1e-6);
    try testing.expectApproxEqAbs(0, c.y, 1e-6);
    // Still fully its own: its constraints are internal, the origin's not.
    var inside: usize = 0;
    for (s.constraints.items) |k| {
        if (k.group == id) inside += 1;
    }
    try testing.expect(inside > 6);
    const an = try s.analyse(al, al);
    try testing.expectEqual(@as(usize, 0), an.conflicting.len);
    try testing.expectEqual(@as(usize, 0), an.redundant.len);
}

test "arrays as objects: counts changed in place, their parts found again" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const p = try addPolar(&s, al, .{ .x = 0, .y = 0 }, 20, std.math.pi / 2.0, 2 * std.math.pi, 8, 2);
    const q = try addRect(&s, al, .{ .x0 = 30, .y0 = 0, .x1 = 60, .y1 = 20 }, 3, 2);
    _ = try s.solve(al);
    var remap: Remap = .{};
    try setProp(&s, al, p, "columns", 12, &remap);
    try setProp(&s, al, q, "rows", 4, &remap);
    _ = try s.solve(al);
    const cp = try arrays.cells(&s, try arrayRefs(&s, p));
    try testing.expectApproxEqAbs(2 * std.math.pi / 12.0, cp.polar.step, 1e-6);
    try testing.expectApproxEqAbs(20, cp.polar.r, 1e-6);
    const cq = try arrays.cells(&s, try arrayRefs(&s, q));
    try testing.expectApproxEqAbs(30, cq.rect.x1 - cq.rect.x0, 1e-6);
    try testing.expectApproxEqAbs(20, cq.rect.y1 - cq.rect.y0, 1e-6);
    try testing.expectEqual(@as(?f64, 4), (try s.groups.get(q)).prop("rows"));
}

test "a sealed object: its members and own constraints refused one by one, removed whole" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var s = try Sketch.init(al);
    const id = try addPolygon(&s, al, .{ .x = 5, .y = 5 }, .{ .x = 15, .y = 5 }, 5, false);
    const g = try s.groups.get(id);
    const side = g.geometry.items[1];
    const other = g.geometry.items[2];
    try testing.expect(sealedGeometry(&s, side));
    try testing.expect(sealedConstraint(&s, g.constraints.items[0]));
    // Inside it: refused. To the origin: external.
    try testing.expect(sealsConstraint(&s, .{ .kind = .{ .parallel = .{ .a = side, .b = other } } }));
    try testing.expect(!sealsConstraint(&s, .{ .kind = .{ .coincident = .{ .{ .geom = side, .role = .start }, .{ .geom = root.origin } } } }));
    _ = try s.addConstraint(al, .{ .kind = .{ .coincident = .{ .{ .geom = side, .role = .start }, .{ .geom = root.origin } } } });
    const before = s.constraints.items.len;
    try removeObject(&s, al, id);
    for (s.geometry.items[side..]) |x| try testing.expect(x.removed);
    try testing.expect(s.constraints.items.len < before);
    try testing.expectError(error.NoSuchGroup, s.groups.get(id));
    try testing.expect(!sealedGeometry(&s, side));
}

test "an object placed: a rectangular array to a new box, a polar one turned and sized, its IDs kept" {
    const al = std.testing.allocator;
    var s = try Sketch.init(al);
    defer s.deinit(al);
    const q = try addRect(&s, al, .{ .x0 = 0, .y0 = 0, .x1 = 30, .y1 = 20 }, 3, 2);
    _ = try s.solve(al);
    const ids_before = (try s.groups.get(q)).geometry.items.len;
    try place(&s, al, q, .{ .rect = .{ .x0 = 6.85, .y0 = 5.55, .x1 = 6.85 + 3 * 11.43, .y1 = 5.55 + 2 * 12.7 } });
    _ = try s.solve(al);
    const b = (try placementOf(&s, q)).rect;
    try std.testing.expectApproxEqAbs(6.85, b.x0, 1e-9);
    try std.testing.expectApproxEqAbs(6.85 + 34.29, b.x1, 1e-9);
    try std.testing.expectApproxEqAbs(5.55 + 25.4, b.y1, 1e-9);
    try std.testing.expectEqual(ids_before, (try s.groups.get(q)).geometry.items.len);
    const r = try arrayRefs(&s, q);
    const cl = try arrays.cells(&s, r);
    try std.testing.expectApproxEqAbs(6.85, cl.rect.x0, 1e-9);

    const p = try addPolar(&s, al, .{ .x = 50, .y = 0 }, 10, std.math.pi / 2.0, 2 * std.math.pi, 6, 2);
    _ = try s.solve(al);
    try place(&s, al, p, .{ .polar = .{ .c = .{ .x = 60, .y = 5 }, .r = 15, .first = std.math.pi / 3.0 } });
    _ = try s.solve(al);
    const pp = (try placementOf(&s, p)).polar;
    try std.testing.expectApproxEqAbs(60, pp.c.x, 1e-9);
    try std.testing.expectApproxEqAbs(15, pp.r, 1e-9);
    try std.testing.expectApproxEqAbs(std.math.pi / 3.0, pp.first, 1e-9);
}

test "a polar grid macro: counts are properties, bindings move with them, never below them" {
    const al = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(al);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    // A stem's room in the middle: radius 3 to 12, a quarter turn the
    // "wrong" way (angles in either order), 4 sections round, 3 out.
    const id = try addPolarGrid(&s, a, .{ .x = 0, .y = 0 }, 12, 3, std.math.pi / 2.0, 0, 4, 3);
    const m = macroGeometry(&s, id).?;
    const vars_before = s.vars.items.len;
    // The last border's first ring held to a point; the centre to the
    // origin; border 3, ring 1 at 9 from the origin.
    const p = try s.addPoint(a, .{ .x = 30, .y = 1 }, false);
    _ = try s.addConstraint(a, .{ .kind = .{ .fixed = .{ .p = .{ .geom = p }, .at = .{ .x = 20, .y = 0 } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = m, .role = .node, .i = root.geometry.last, .j = 0 }, .{ .geom = p } } } });
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = m, .role = .centre }, .{ .geom = root.origin } } } });
    const mid = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = .{ .geom = m, .role = .node, .i = 3, .j = 1 }, .b = .{ .geom = root.origin }, .value = 9 } } });
    try testing.expect((try s.solve(a)).solved);
    const corner = try s.point(.{ .geom = m, .role = .node, .i = root.geometry.last, .j = 0 });
    try testing.expectApproxEqAbs(20, corner.x, 1e-6);
    try testing.expectApproxEqAbs(0, corner.y, 1e-6);

    // Fewer columns: nothing made again, no unknown added; border 3 of 4
    // moves to border 1 of 2 (the last stays the last, apart from it).
    var remap: Remap = .{};
    try setProp(&s, a, id, "columns", 2, &remap);
    try testing.expectEqual(vars_before + 2, s.vars.items.len);
    try testing.expectEqual(@as(u32, 1), s.constraints.items[mid].kind.distance.a.i);
    try testing.expect((try s.solve(a)).solved);
    // Down to one: two bindings, two borders; still fits.
    try setProp(&s, a, id, "columns", 1, &remap);
    try testing.expectEqual(@as(u32, 0), s.constraints.items[mid].kind.distance.a.i);
    try testing.expectEqual(@as(u32, 1), try countFloor(&s, a, id, "columns", &.{}));
    // Three bindings along the rings (0, 1 and the last): no fewer than 2.
    _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = .{ .geom = m, .role = .node, .i = 0, .j = root.geometry.last }, .b = .{ .geom = root.origin }, .value = 12 } } });
    try testing.expectEqual(@as(u32, 2), try countFloor(&s, a, id, "rings", &.{}));
    try testing.expectError(error.TooFewBindPoints, setProp(&s, a, id, "rings", 1, &remap));
    try testing.expectEqual(@as(u32, 3), s.geometry.items[m].kind.polar_grid.rings);
    try setProp(&s, a, id, "rings", 2, &remap);
    try testing.expectEqual(@as(?f64, 2), (try s.groups.get(id)).prop("rings"));
    var lost: std.ArrayList(root.ConstraintId) = .empty;
    try abandoned(&s, a, &lost);
    try testing.expectEqual(@as(usize, 0), lost.items.len);
    // Drawn: 3 rings and 2 borders.
    var segs: std.ArrayList(geom.Segment) = .empty;
    try s.appendSegments(a, s.geometry.items[m], &segs);
    var lines: usize = 0;
    for (segs.items) |sg| if (sg == .line) {
        lines += 1;
    };
    try testing.expectEqual(@as(usize, 2), lines);
}

test "a polar grid's rings and borders as curves: pieces, cells, a point held on one, held pieces renumbered" {
    const al = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(al);
    defer arena.deinit();
    const a = arena.allocator();
    const pieces = root.pieces;
    var s = try Sketch.init(a);
    // A quarter turn from 0 to 90°, radius 3 to 12, 4 sections round, 3 out.
    const id = try addPolarGrid(&s, a, .{ .x = 0, .y = 0 }, 3, 12, 0, std.math.pi / 2.0, 4, 3);
    const m = macroGeometry(&s, id).?;
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = m, .role = .centre }, .{ .geom = root.origin } } } });
    try testing.expect((try s.solve(a)).solved);
    // Ring 1 (radius 6) between borders 1 and 2 (22.5° and 45°).
    const t: f64 = 33 * std.math.pi / 180.0;
    const f = try pieces.pieceAt(&s, a, m, .{ .x = 6.05 * @cos(t), .y = 6.05 * @sin(t) });
    try testing.expectEqual(.ring, f.part.role);
    try testing.expectEqual(@as(u32, 1), f.part.k);
    try testing.expectEqual(@as(u32, 1), f.from.?.point.i);
    try testing.expectEqual(@as(u32, 2), f.to.?.point.i);
    // Its ends are the grid's own bind points: nothing added to hold them.
    const n = s.geometry.items.len;
    const p = (try pieces.attach(&s, a, f, true)).?;
    try testing.expectEqual(n, s.geometry.items.len);
    var segs: std.ArrayList(geom.Segment) = .empty;
    try pieces.appendSegments(&s, a, p, &segs);
    try testing.expect(segs.items.len > 0);
    try testing.expectApproxEqAbs(6 * @cos(std.math.pi / 8.0), segs.items[0].start().x, 1e-9);
    // A cell is a closed path of four pieces (two rings, two borders).
    const cell = (try pieces.loopAround(&s, a, .{ .x = 7.5 * @cos(t), .y = 7.5 * @sin(t) })).?;
    try testing.expectEqual(4, cell.len);
    // Made lasting, its pieces close a path (a fill's boundary).
    var cell_segs: std.ArrayList(geom.Segment) = .empty;
    for (cell) |cf| try pieces.appendSegments(&s, a, (try pieces.attach(&s, a, cf, true)).?, &cell_segs);
    const ch = try Sketch.chain(a, cell_segs.items);
    try testing.expectEqual(1, ch.contours.len);
    try testing.expectEqual(0, ch.open);
    // A segment across the last ring: the crossing held on that ring.
    const seg = try s.addSegment(a, .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 20 }, true);
    const x = try pieces.pieceAt(&s, a, seg, .{ .x = 15, .y = 15 });
    try testing.expect(x.from.? == .cross);
    try testing.expectEqual(.ring, x.from.?.cross.other_part.role);
    _ = (try pieces.attach(&s, a, x, true)).?;
    var held = false;
    for (s.constraints.items) |c| if (c.kind == .point_on and c.kind.point_on.on == m and c.kind.point_on.part.role == .ring) {
        held = true;
    };
    try testing.expect(held);
    // The grid grows: the point stays on its outer ring.
    _ = try s.addConstraint(a, .{ .kind = .{ .distance = .{ .a = .{ .geom = m, .role = .node, .i = 0, .j = root.geometry.last }, .b = .{ .geom = root.origin }, .value = 15 } } });
    try testing.expect((try s.solve(a)).solved);
    var segs2: std.ArrayList(geom.Segment) = .empty;
    try pieces.appendSegments(&s, a, .{ .geom = seg, .from = .{ .geom = seg, .role = .start }, .to = .{ .geom = seg, .role = .end } }, &segs2);
    var on15 = false;
    for (s.geometry.items, 0..) |g, gi| if (g.kind == .point and gi > 3) {
        const q = try s.point(.{ .geom = @intCast(gi) });
        if (@abs(std.math.hypot(q.x, q.y) - 15) < 1e-6) on15 = true;
    };
    try testing.expect(on15);
    // Held outside (an ink): counted as a binding, and renumbered with
    // the count (borders 1 and 2 of 4 become 1 and 2 of 2).
    const ink = [_]Piece{p};
    // With the distance on border 0: three borders bound, two columns at least.
    try testing.expectEqual(@as(u32, 2), try countFloor(&s, a, id, "columns", &ink));
    try testing.expectEqual(@as(u32, 1), try countFloor(&s, a, id, "columns", &.{}));
    var remap: Remap = .{ .held = &ink };
    try setProp(&s, a, id, "columns", 2, &remap);
    const moved = remap.piece(p);
    try testing.expectEqual(@as(u32, 1), moved.from.?.i);
    try testing.expectEqual(@as(u32, 2), moved.to.?.i);
    try testing.expectEqual(@as(u32, 1), moved.part.k);
}

test "a dial macro: large and small ticks as properties, a bound large tick stays a large tick" {
    const al = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(al);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sketch.init(a);
    // A clock face: all the way round clockwise from the top, 12 hours,
    // 4 minute ticks between.
    const top = std.math.pi / 2.0;
    const id = try addDial(&s, a, .{ .x = 0, .y = 0 }, .{ 20, 16, 18, 12 }, top, top - 2 * std.math.pi, 12, 4);
    const m = macroGeometry(&s, id).?;
    const pg = s.geometry.items[m].kind.polar_grid;
    try testing.expectEqual(@as(u32, 60), pg.cols);
    try testing.expectEqual(@as(?f64, 1), (try s.groups.get(id)).prop("clockwise"));
    // 60 ticks and the rim: 12 long, 48 short.
    var segs: std.ArrayList(geom.Segment) = .empty;
    try s.appendSegments(a, s.geometry.items[m], &segs);
    var long: usize = 0;
    var short: usize = 0;
    for (segs.items) |sg| if (sg == .line) {
        const l = std.math.hypot(sg.line[1].x - sg.line[0].x, sg.line[1].y - sg.line[0].y);
        if (@abs(l - 4) < 1e-9) long += 1 else if (@abs(l - 2) < 1e-9) short += 1;
    };
    try testing.expectEqual(@as(usize, 12), long);
    try testing.expectEqual(@as(usize, 48), short);
    // Three o'clock's label point is to the right of the centre.
    const three = try s.point(.{ .geom = m, .role = .node, .i = 15, .j = 3 });
    try testing.expectApproxEqAbs(12, three.x, 1e-9);
    try testing.expectApproxEqAbs(0, three.y, 1e-9);
    // A point held on three o'clock's tick end; one small tick between
    // large ones: it is still three o'clock's.
    const p = try s.addPoint(a, .{ .x = 16, .y = 0 }, false);
    _ = try s.addConstraint(a, .{ .kind = .{ .coincident = .{ .{ .geom = m, .role = .node, .i = 15, .j = 1 }, .{ .geom = p } } } });
    var remap: Remap = .{};
    try setProp(&s, a, id, "small", 1, &remap);
    const now = s.geometry.items[m].kind.polar_grid;
    try testing.expectEqual(@as(u32, 24), now.cols);
    const c = s.constraints.items[s.constraints.items.len - 1].kind.coincident;
    try testing.expectEqual(@as(u32, 6), c[0].i);
    try testing.expect(now.large(c[0].i));
    // Anticlockwise now: the same sweep the other way.
    try setProp(&s, a, id, "clockwise", 0, &remap);
    try testing.expect(s.geometry.items[m].kind.polar_grid.sweep(s.vars.items) > 0);
    // A tick is a curve, from the rim in to its own end.
    var k: std.ArrayList(geom.Segment) = .empty;
    try root.pieces.appendSegments(&s, a, .{ .geom = m, .part = .{ .role = .border, .k = 1 } }, &k);
    try testing.expectEqual(@as(usize, 1), k.items.len);
    const ln = k.items[0].line;
    try testing.expectApproxEqAbs(2, std.math.hypot(ln[1].x - ln[0].x, ln[1].y - ln[0].y), 1e-9);
}
