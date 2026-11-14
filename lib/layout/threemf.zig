//! 3MF output for multi-colour 3D printing, straight from a part's
//! fabrication slabs (fab.slabs): each colour region of each slab becomes a
//! closed prism mesh (its faces triangulated by geom.fill, its walls from
//! the same boundary loops, so every edge is shared by exactly two
//! triangles), one object per colour and slab, all parts of one object for
//! the part. The colours are 3MF base materials. No OCCT, and no 3D
//! booleans: the slabs' regions do not overlap.
//!
//! The package is a ZIP stored without compression: [Content_Types].xml,
//! _rels/.rels and 3D/3dmodel.model (3MF core specification, 2015/02).

const std = @import("std");
const engine = @import("graven_engine");
const fab = @import("fab.zig");
const art = @import("art.zig");
const geom = engine.geom;
const Allocator = std.mem.Allocator;

pub const Mesh = struct {
    vertices: []const [3]f64,
    triangles: []const [3]u32,
};

/// Curves are flattened to within this of the exact outline, mm.
pub const default_tolerance = 0.005;

/// A region swept from `z0` up to `z1` as a closed mesh, outward-facing:
/// each face (an outer contour, counter-clockwise, with the holes inside
/// it, clockwise, as geom.boolean gives them) triangulated by earcut, and
/// walls along the same rings, so faces and walls share every edge.
pub fn prism(a: Allocator, outline: geom.Outline, z0: f64, z1: f64, tol: f64) Allocator.Error!Mesh {
    var b: Builder = .{ .a = a, .tol = tol };
    try b.face(outline, z1, .up);
    try b.face(outline, z0, .down);
    try b.walls(outline, z0, z1);
    return b.mesh();
}

/// A region of one colour over a height range.
pub const Band = struct { outline: geom.Outline, z0: f64, z1: f64 };

/// The union of `bands` (one colour's, in order up, not overlapping in z)
/// as one closed mesh: each band's walls; at each height where bands meet,
/// faces only where one reaches past the other (the rest is inside). The
/// regions there come from exact 2D booleans over all the bands' outlines
/// at once, so every call cuts them into the same pieces and the faces meet
/// the walls edge to edge.
pub fn solid(a: Allocator, bands: []const Band, tol: f64) !Mesh {
    var b: Builder = .{ .a = a, .tol = tol };
    const inputs = try a.alloc(geom.Outline, bands.len);
    for (bands, inputs) |bd, *o| o.* = bd.outline;
    const Rule = struct {
        /// Inside `in_` and (when `out` is set) outside `out`.
        in_: usize,
        out: ?usize,
        fn inside(ctx: *const anyopaque, in: []const bool) bool {
            const r: *const @This() = @ptrCast(@alignCast(ctx));
            return in[r.in_] and !(if (r.out) |o| in[o] else false);
        }
    };
    // Every region the union needs, from one pass over the bands: each
    // band's walls (its outline cut where the others' cross it), and its
    // faces below and above (what it covers that the band meeting it there
    // does not).
    var rules: std.ArrayList(Rule) = .empty;
    var heights: std.ArrayList(struct { z0: f64, z1: f64, side: ?Side }) = .empty;
    for (bands, 0..) |bd, k| {
        try rules.append(a, .{ .in_ = k, .out = null });
        try heights.append(a, .{ .z0 = bd.z0, .z1 = bd.z1, .side = null });
        const below: ?usize = if (k > 0 and @abs(bands[k - 1].z1 - bd.z0) < 1e-9) k - 1 else null;
        try rules.append(a, .{ .in_ = k, .out = below });
        try heights.append(a, .{ .z0 = bd.z0, .z1 = bd.z0, .side = .down });
        const above: ?usize = if (k + 1 < bands.len and @abs(bands[k + 1].z0 - bd.z1) < 1e-9) k + 1 else null;
        try rules.append(a, .{ .in_ = k, .out = above });
        try heights.append(a, .{ .z0 = bd.z1, .z1 = bd.z1, .side = .up });
    }
    const gen = try a.alloc(geom.boolean.Rule, rules.items.len);
    for (rules.items, gen) |*r, *g| g.* = .{ .ctx = r, .inside = Rule.inside };
    const regions = try geom.boolean.combineMany(a, inputs, gen);
    for (regions, heights.items) |reg, h| {
        if (h.side) |side| try b.face(reg, h.z0, side) else try b.walls(reg, h.z0, h.z1);
    }
    return b.mesh();
}

const Side = enum { up, down };

/// Builds a mesh from faces and walls on shared vertices.
const Builder = struct {
    a: Allocator,
    tol: f64,
    verts: std.ArrayList([3]f64) = .empty,
    index: std.AutoHashMapUnmanaged([3]u64, u32) = .empty,
    tris: std.ArrayList([3]u32) = .empty,

    fn vertex(b: *Builder, p: geom.Point, z: f64) Allocator.Error!u32 {
        const v = [3]f64{ p.x + 0.0, p.y + 0.0, z + 0.0 };
        const key = [3]u64{ @bitCast(v[0]), @bitCast(v[1]), @bitCast(v[2]) };
        const g = try b.index.getOrPut(b.a, key);
        if (!g.found_existing) {
            g.value_ptr.* = @intCast(b.verts.items.len);
            try b.verts.append(b.a, v);
        }
        return g.value_ptr.*;
    }

    fn mesh(b: *Builder) Mesh {
        return .{ .vertices = b.verts.items, .triangles = b.tris.items };
    }

    /// A region's faces at height `z`, facing up or down.
    fn face(b: *Builder, outline: geom.Outline, z: f64, side: Side) Allocator.Error!void {
        const rs = try rings(b.a, outline, b.tol);
        for (rs.rings, rs.areas, 0..) |outer, ar, k| {
            if (ar <= 0) continue;
            var holes: std.ArrayList([]const geom.Point) = .empty;
            var pts: std.ArrayList(geom.Point) = .empty;
            try pts.appendSlice(b.a, outer);
            for (rs.rings, rs.owner) |ring, o| if (o == k) {
                try holes.append(b.a, ring);
                try pts.appendSlice(b.a, ring);
            };
            // Earcut can run a triangle's edge through vertices lying
            // exactly on it (its ears are tested against reflex vertices
            // only, and it drops collinear ones): split such triangles
            // there, so faces meet the walls vertex to vertex.
            const grid = try Grid.of(b.a, pts.items);
            var tris: std.ArrayList([3]geom.Point) = .empty;
            for (try geom.earcut.triangulate(b.a, outer, holes.items)) |t| {
                try splitAt(b.a, &tris, &grid, .{ pts.items[t[0]], pts.items[t[1]], pts.items[t[2]] }, 0);
            }
            for (tris.items) |tri| {
                var p = tri;
                const cross = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x);
                if (cross == 0) continue;
                if ((cross < 0) == (side == .up)) std.mem.swap(geom.Point, &p[1], &p[2]);
                try b.tris.append(b.a, .{ try b.vertex(p[0], z), try b.vertex(p[1], z), try b.vertex(p[2], z) });
            }
        }
    }

    /// A region's walls from `z0` up to `z1`: every ring has the region on
    /// its left (outer rings counter-clockwise, holes clockwise), so its
    /// right is outward.
    fn walls(b: *Builder, outline: geom.Outline, z0: f64, z1: f64) Allocator.Error!void {
        const rs = try rings(b.a, outline, b.tol);
        for (rs.rings, rs.areas, rs.owner) |ring, ar, o| {
            if (ar < 0 and o == null) continue; // a hole in nothing
            for (ring, 0..) |p, i| {
                const q = ring[(i + 1) % ring.len];
                const p0 = try b.vertex(p, z0);
                const q0 = try b.vertex(q, z0);
                const q1 = try b.vertex(q, z1);
                const p1 = try b.vertex(p, z1);
                try b.tris.append(b.a, .{ p0, q0, q1 });
                try b.tris.append(b.a, .{ p0, q1, p1 });
            }
        }
    }
};

const Rings = struct {
    rings: []const []const geom.Point,
    areas: []const f64,
    /// For each hole, the smallest outer ring around it.
    owner: []const ?usize,
};

/// An outline's contours flattened into rings: each segment in a fixed
/// direction (so a piece shared by two regions gives the same points
/// either way round), repeats dropped, holes given their outer ring.
fn rings(a: Allocator, outline: geom.Outline, tol: f64) Allocator.Error!Rings {
    var rs: std.ArrayList([]const geom.Point) = .empty;
    var areas: std.ArrayList(f64) = .empty;
    for (outline.contours) |ct| {
        if (ct.segments.len == 0) continue;
        var pts: std.ArrayList(geom.Point) = .empty;
        try pts.append(a, ct.segments[0].start());
        for (ct.segments) |sg| try flattenCanonical(a, &pts, sg, tol);
        var ring: std.ArrayList(geom.Point) = .empty;
        for (pts.items) |q| {
            if (ring.items.len > 0 and near(ring.items[ring.items.len - 1], q)) continue;
            try ring.append(a, q);
        }
        while (ring.items.len > 1 and near(ring.items[0], ring.items[ring.items.len - 1])) ring.items.len -= 1;
        if (ring.items.len < 3) continue;
        try rs.append(a, ring.items);
        try areas.append(a, ringArea(ring.items));
    }
    const owner = try a.alloc(?usize, rs.items.len);
    for (rs.items, areas.items, owner) |ring, ar, *o| {
        o.* = null;
        if (ar >= 0) continue;
        for (rs.items, areas.items, 0..) |other, oa, k| {
            if (oa <= 0 or !inRing(other, ring[0])) continue;
            if (o.* == null or oa < areas.items[o.*.?]) o.* = k;
        }
    }
    return .{ .rings = rs.items, .areas = areas.items, .owner = owner };
}

/// As `flatten`, but always sampled from the lesser end (by x, then y), so
/// a segment and its reverse give exactly the same points.
fn flattenCanonical(a: Allocator, pts: *std.ArrayList(geom.Point), s: geom.Segment, tol: f64) Allocator.Error!void {
    const p = s.start();
    const q = s.end();
    const forward = p.x < q.x or (p.x == q.x and p.y <= q.y);
    if (forward) return flatten(a, pts, s, tol);
    var tmp: std.ArrayList(geom.Point) = .empty;
    try tmp.append(a, q);
    try flatten(a, &tmp, s.reversed(), tol);
    // tmp runs q .. p: append it backwards, without q (already there as the
    // previous point) and ending on p's exact value.
    var k = tmp.items.len - 1;
    while (k > 0) {
        k -= 1;
        try pts.append(a, tmp.items[k]);
    }
}

/// A face's vertices in a grid of cells, to find those on an edge.
const Grid = struct {
    cells: std.AutoHashMapUnmanaged([2]i64, std.ArrayList(geom.Point)),
    size: f64,

    fn of(a: Allocator, pts: []const geom.Point) Allocator.Error!Grid {
        var b = geom.Box.empty;
        for (pts) |p| b = b.addPoint(p);
        // About one vertex per cell on average.
        const size = @max(1e-6, @sqrt(@max(b.width() * b.height(), 1e-12) / @as(f64, @floatFromInt(@max(pts.len, 1)))) * 2);
        var g: Grid = .{ .cells = .empty, .size = size };
        for (pts) |p| {
            const e = try g.cells.getOrPut(a, g.cell(p));
            if (!e.found_existing) e.value_ptr.* = .empty;
            try e.value_ptr.append(a, p);
        }
        return g;
    }

    fn cell(g: Grid, p: geom.Point) [2]i64 {
        return .{ @intFromFloat(@floor(p.x / g.size)), @intFromFloat(@floor(p.y / g.size)) };
    }

    /// A vertex strictly inside segment p-q and on it, if any.
    fn onEdge(g: Grid, p: geom.Point, q: geom.Point) ?geom.Point {
        const c0 = g.cell(.{ .x = @min(p.x, q.x), .y = @min(p.y, q.y) });
        const c1 = g.cell(.{ .x = @max(p.x, q.x), .y = @max(p.y, q.y) });
        const dx = q.x - p.x;
        const dy = q.y - p.y;
        const len2 = dx * dx + dy * dy;
        if (len2 == 0) return null;
        var cx = c0[0];
        while (cx <= c1[0]) : (cx += 1) {
            var cy = c0[1];
            while (cy <= c1[1]) : (cy += 1) {
                const list = g.cells.get(.{ cx, cy }) orelse continue;
                for (list.items) |v| {
                    if (v.eql(p) or v.eql(q)) continue;
                    const cross = (v.x - p.x) * dy - (v.y - p.y) * dx;
                    if (@abs(cross) > 1e-12 * len2) continue;
                    const t = ((v.x - p.x) * dx + (v.y - p.y) * dy) / len2;
                    if (t > 0 and t < 1) return v;
                }
            }
        }
        return null;
    }
};

/// Appends `t`, split wherever a vertex lies on one of its edges.
fn splitAt(a: Allocator, out: *std.ArrayList([3]geom.Point), g: *const Grid, t: [3]geom.Point, depth: usize) Allocator.Error!void {
    if (depth < 64) for (0..3) |k| {
        const p = t[k];
        const q = t[(k + 1) % 3];
        const r = t[(k + 2) % 3];
        if (g.onEdge(p, q)) |m| {
            try splitAt(a, out, g, .{ p, m, r }, depth + 1);
            try splitAt(a, out, g, .{ m, q, r }, depth + 1);
            return;
        }
    };
    try out.append(a, t);
}

fn near(p: geom.Point, q: geom.Point) bool {
    return @abs(p.x - q.x) <= 1e-9 and @abs(p.y - q.y) <= 1e-9;
}

fn ringArea(ring: []const geom.Point) f64 {
    var s: f64 = 0;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        s += p.x * q.y - q.x * p.y;
    }
    return s / 2;
}

fn inRing(ring: []const geom.Point, p: geom.Point) bool {
    var inside = false;
    var j = ring.len - 1;
    for (ring, 0..) |q, i| {
        const r = ring[j];
        if ((q.y > p.y) != (r.y > p.y) and q.x + (p.y - q.y) * (r.x - q.x) / (r.y - q.y) > p.x) inside = !inside;
        j = i;
    }
    return inside;
}

/// Whether the mesh is closed and consistently oriented: every directed
/// edge appears once, and its reverse once.
pub fn closed(a: Allocator, m: Mesh) Allocator.Error!bool {
    var edges: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
    defer edges.deinit(a);
    for (m.triangles) |t| for (0..3) |k| {
        const g = try edges.getOrPut(a, .{ t[k], t[(k + 1) % 3] });
        g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
    };
    var it = edges.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != 1) return false;
        const back = edges.get(.{ e.key_ptr[1], e.key_ptr[0] }) orelse return false;
        if (back != 1) return false;
    }
    return true;
}

/// Its enclosed volume (divergence theorem).
pub fn volume(m: Mesh) f64 {
    var v: f64 = 0;
    for (m.triangles) |t| {
        const p = m.vertices[t[0]];
        const q = m.vertices[t[1]];
        const r = m.vertices[t[2]];
        v += p[0] * (q[1] * r[2] - q[2] * r[1]) - p[1] * (q[0] * r[2] - q[2] * r[0]) + p[2] * (q[0] * r[1] - q[1] * r[0]);
    }
    return v / 6;
}

pub const Part = struct {
    /// Its name, and its colour's name and colour.
    name: []const u8,
    colour: []const u8,
    color: art.Color,
    mesh: Mesh,
};

/// How a part's meshes are grouped.
pub const Grouping = enum {
    /// One per colour and height band (the slabs' regions).
    bands,
    /// One per colour: the union of its bands.
    colours,
};

/// The part's meshes, grouped by `grouping`.
pub fn parts(a: Allocator, slabs: []const fab.Slab, tol: f64, grouping: Grouping) ![]const Part {
    if (grouping == .colours) return colourParts(a, slabs, tol);
    var out: std.ArrayList(Part) = .empty;
    for (slabs) |slab| for (slab.regions) |reg| {
        const mesh = try prism(a, reg.outline, slab.z0, slab.z1, tol);
        if (mesh.triangles.len == 0) continue;
        try out.append(a, .{
            .name = try std.fmt.allocPrint(a, "{s}, {d:.2} to {d:.2} mm", .{ reg.colour.name, slab.z0, slab.z1 }),
            .colour = reg.colour.name,
            .color = reg.colour.color,
            .mesh = mesh,
        });
    };
    return out.items;
}

fn colourParts(a: Allocator, slabs: []const fab.Slab, tol: f64) ![]const Part {
    var names: std.ArrayList(@import("model.zig").FabColour) = .empty;
    for (slabs) |sl| for (sl.regions) |reg| {
        for (names.items) |n| {
            if (std.mem.eql(u8, n.name, reg.colour.name)) break;
        } else try names.append(a, reg.colour);
    };
    var out: std.ArrayList(Part) = .empty;
    for (names.items) |col| {
        var bands: std.ArrayList(Band) = .empty;
        for (slabs) |sl| for (sl.regions) |reg| if (std.mem.eql(u8, reg.colour.name, col.name)) {
            try bands.append(a, .{ .outline = reg.outline, .z0 = sl.z0, .z1 = sl.z1 });
        };
        const mesh = try solid(a, bands.items, tol);
        if (mesh.triangles.len == 0) continue;
        try out.append(a, .{ .name = col.name, .colour = col.name, .color = col.color, .mesh = mesh });
    }
    return out.items;
}

/// Which face of the part goes on the print bed.
pub const Bed = enum {
    /// Its lowest z, as built.
    bottom,
    /// Its highest z: turned over (half a turn about the y axis), so the
    /// top's text lies on the bed, reading mirrored from below.
    top,
};

/// `ps` turned so `bed` faces the print bed, standing on z = 0, in the same
/// place across. A rotation, not a reflection: the triangles keep their
/// facing.
pub fn orient(a: Allocator, ps: []const Part, bed: Bed) Allocator.Error![]const Part {
    var x0 = std.math.inf(f64);
    var x1 = -std.math.inf(f64);
    var z0 = std.math.inf(f64);
    var z1 = -std.math.inf(f64);
    for (ps) |p| for (p.mesh.vertices) |v| {
        x0 = @min(x0, v[0]);
        x1 = @max(x1, v[0]);
        z0 = @min(z0, v[2]);
        z1 = @max(z1, v[2]);
    };
    const out = try a.alloc(Part, ps.len);
    for (ps, out) |p, *o| {
        const vs = try a.alloc([3]f64, p.mesh.vertices.len);
        for (p.mesh.vertices, vs) |v, *w| w.* = switch (bed) {
            .bottom => .{ v[0], v[1], v[2] - z0 },
            .top => .{ x0 + x1 - v[0], v[1], z1 - v[2] },
        };
        o.* = p;
        o.mesh = .{ .vertices = vs, .triangles = p.mesh.triangles };
    }
    return out;
}

/// A 3MF package of `parts` as one object named `name`.
pub fn package(a: Allocator, name: []const u8, ps: []const Part) ![]u8 {
    const model_xml = try modelXml(a, name, ps);
    return zipStored(a, &.{
        .{ .name = "[Content_Types].xml", .data = content_types },
        .{ .name = "_rels/.rels", .data = rels },
        .{ .name = "3D/3dmodel.model", .data = model_xml },
    });
}

const content_types =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
    \\
;

const rels =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
    \\
;

fn modelXml(a: Allocator, name: []const u8, ps: []const Part) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        \\<metadata name="Application">Graven</metadata>
        \\<resources>
        \\
    );
    // The colours, in the order they first appear.
    var colours: std.ArrayList(Part) = .empty;
    for (ps) |p| {
        for (colours.items) |c| {
            if (std.mem.eql(u8, c.colour, p.colour)) break;
        } else try colours.append(a, p);
    }
    try w.writeAll("<basematerials id=\"1\">\n");
    for (colours.items) |c| {
        try w.writeAll("<base name=\"");
        try xmlText(w, c.colour);
        try w.print("\" displaycolor=\"#{X:0>2}{X:0>2}{X:0>2}FF\"/>\n", .{ c.color.r, c.color.g, c.color.b });
    }
    try w.writeAll("</basematerials>\n");
    for (ps, 0..) |p, i| {
        const pindex = for (colours.items, 0..) |c, k| {
            if (std.mem.eql(u8, c.colour, p.colour)) break k;
        } else 0;
        try w.print("<object id=\"{d}\" type=\"model\" pid=\"1\" pindex=\"{d}\" name=\"", .{ i + 2, pindex });
        try xmlText(w, p.name);
        try w.writeAll("\"><mesh><vertices>\n");
        for (p.mesh.vertices) |v| try w.print("<vertex x=\"{d:.6}\" y=\"{d:.6}\" z=\"{d:.6}\"/>\n", .{ v[0], v[1], v[2] });
        try w.writeAll("</vertices><triangles>\n");
        for (p.mesh.triangles) |t| try w.print("<triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\"/>\n", .{ t[0], t[1], t[2] });
        try w.writeAll("</triangles></mesh></object>\n");
    }
    const whole = ps.len + 2;
    try w.print("<object id=\"{d}\" type=\"model\" name=\"", .{whole});
    try xmlText(w, name);
    try w.writeAll("\"><components>\n");
    for (0..ps.len) |i| try w.print("<component objectid=\"{d}\"/>\n", .{i + 2});
    try w.print("</components></object>\n</resources>\n<build><item objectid=\"{d}\"/></build>\n</model>\n", .{whole});
    return out.toOwnedSlice();
}

fn xmlText(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

const File = struct { name: []const u8, data: []const u8 };

/// A ZIP archive of `files`, stored (no compression), dated 1980-01-01.
fn zipStored(a: Allocator, files: []const File) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const offsets = try a.alloc(u32, files.len);
    const crcs = try a.alloc(u32, files.len);
    for (files, offsets, crcs) |f, *off, *crc| {
        off.* = @intCast(out.written().len);
        crc.* = std.hash.Crc32.hash(f.data);
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u16, 0, .little); // time
        try w.writeInt(u16, 0x0021, .little); // date: 1980-01-01
        try w.writeInt(u32, crc.*, .little);
        try w.writeInt(u32, @intCast(f.data.len), .little);
        try w.writeInt(u32, @intCast(f.data.len), .little);
        try w.writeInt(u16, @intCast(f.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(f.name);
        try w.writeAll(f.data);
    }
    const cd_start: u32 = @intCast(out.written().len);
    for (files, offsets, crcs) |f, off, crc| {
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, 20, .little); // made by
        try w.writeInt(u16, 20, .little); // needed
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x0021, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(f.data.len), .little);
        try w.writeInt(u32, @intCast(f.data.len), .little);
        try w.writeInt(u16, @intCast(f.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, 0, .little); // external attributes
        try w.writeInt(u32, off, .little);
        try w.writeAll(f.name);
    }
    const cd_size: u32 = @as(u32, @intCast(out.written().len)) - cd_start;
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

/// Appends the points after `s`'s start, chords within `tol` of the curve.
fn flatten(a: Allocator, pts: *std.ArrayList(geom.Point), s: geom.Segment, tol: f64) !void {
    const n: usize = switch (s) {
        .line => 1,
        .conic => |c| blk: {
            if (!(c.w > 0 and c.w < 1)) break :blk 16;
            const e = c.ellipse();
            const r = @max(@sqrt(e.a.x * e.a.x + e.a.y * e.a.y), @sqrt(e.b.x * e.b.x + e.b.y * e.b.y));
            const step = 2 * std.math.acos(@max(0, 1 - tol / @max(r, 1e-12)));
            break :blk @max(2, @min(256, @as(usize, @intFromFloat(@ceil(2 * e.half / @max(step, 1e-6))))));
        },
        .quad => |p| blk: {
            const dev = 0.25 * @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            break :blk @max(1, @min(256, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol))))));
        },
        .cubic => |p| blk: {
            const d1 = @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const d2 = @sqrt(sq(p[1].x - 2 * p[2].x + p[3].x) + sq(p[1].y - 2 * p[2].y + p[3].y));
            break :blk @max(1, @min(256, @as(usize, @intFromFloat(@ceil(@sqrt(0.75 * @max(d1, d2) / tol))))));
        },
    };
    for (1..n) |i| try pts.append(a, s.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
    // The end exactly, so contours close on their first point.
    try pts.append(a, s.end());
}

fn sq(x: f64) f64 {
    return x * x;
}

const testing = std.testing;

test "a region with a round hole as a closed prism: watertight, outward, its volume" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const square = [_]geom.Segment{
        .{ .line = .{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 } } },
        .{ .line = .{ .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 } } },
        .{ .line = .{ .{ .x = 20, .y = 10 }, .{ .x = 0, .y = 10 } } },
        .{ .line = .{ .{ .x = 0, .y = 10 }, .{ .x = 0, .y = 0 } } },
    };
    var buf: [4]geom.Segment = undefined;
    const hole_ccw = geom.arc(.{ .x = 5, .y = 5 }, 2, 0, 2 * std.math.pi, &buf);
    var hole: [4]geom.Segment = undefined;
    for (hole_ccw, 0..) |s, i| hole[hole_ccw.len - 1 - i] = s.reversed();
    const contours = [_]geom.Contour{ .{ .segments = &square }, .{ .segments = hole[0..hole_ccw.len] } };
    const m = try prism(a, .{ .contours = &contours }, 0, 2, default_tolerance);
    try testing.expect(try closed(a, m));
    // Within the flattening of the circle (chords inside it).
    const exact = (200 - std.math.pi * 4) * 2;
    const v = volume(m);
    try testing.expect(v > exact and v - exact < 2 * std.math.pi * 2 * default_tolerance * 2);

    // And as a package: a ZIP with the three parts, stored.
    const ps = [_]Part{.{ .name = "plate, 0 to 2 mm", .colour = "black", .color = .hex("#1e1e1e"), .mesh = m }};
    const zip = try package(a, "Plate", &ps);
    try testing.expectEqual(@as(u32, 0x04034b50), std.mem.readInt(u32, zip[0..4], .little));
    try testing.expect(std.mem.indexOf(u8, zip, "3D/3dmodel.model") != null);
    try testing.expect(std.mem.indexOf(u8, zip, "displaycolor=\"#1E1E1EFF\"") != null);
    try testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, zip[zip.len - 22 ..][0..4], .little));
}



test "holes along one line (glyphs on a baseline): faces split there, the mesh closed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var contours: std.ArrayList(geom.Contour) = .empty;
    const Rect = struct {
        fn ring(al: Allocator, x0: f64, y0: f64, x1: f64, y1: f64, ccw: bool) ![]const geom.Segment {
            const pts = [4]geom.Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
            const segs = try al.alloc(geom.Segment, 4);
            for (0..4) |i| {
                const p = if (ccw) pts[i] else pts[(4 - i) % 4];
                const q = if (ccw) pts[(i + 1) % 4] else pts[(3 - i + 4) % 4];
                segs[i] = .{ .line = .{ p, q } };
            }
            return segs;
        }
    };
    try contours.append(a, .{ .segments = try Rect.ring(a, 0, 0, 40, 10, true) });
    // Six holes standing on y = 3, as letters on a baseline.
    for (0..6) |i| {
        const x: f64 = 3 + @as(f64, @floatFromInt(i)) * 6;
        try contours.append(a, .{ .segments = try Rect.ring(a, x, 3, x + 3, 3 + @as(f64, @floatFromInt(i % 3 + 2)), false) });
    }
    const m = try prism(a, .{ .contours = contours.items }, 1.4, 2, default_tolerance);
    try testing.expect(try closed(a, m));
    var holes: f64 = 0;
    for (0..6) |i| holes += 3 * @as(f64, @floatFromInt(i % 3 + 2));
    try testing.expectApproxEqAbs((400 - holes) * 0.6, volume(m), 1e-9);
}


test "one colour's bands as one closed solid, and turned over onto its top" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rect = struct {
        fn ring(al: Allocator, x0: f64, y0: f64, x1: f64, y1: f64, ccw: bool) ![]const geom.Segment {
            const c = [4]geom.Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
            const segs = try al.alloc(geom.Segment, 4);
            for (0..4) |i| segs[i] = if (ccw) .{ .line = .{ c[i], c[(i + 1) % 4] } } else .{ .line = .{ c[(4 - i) % 4], c[(3 - i + 4) % 4] } };
            return segs;
        }
    }.ring;
    // A plate 20 x 10, 0 to 1.4 whole; 1.4 to 2 with a pocket (an inlay's
    // place) and a round hole through both.
    var buf: [4]geom.Segment = undefined;
    const ccw = geom.arc(.{ .x = 15, .y = 5 }, 2, 0, 2 * std.math.pi, &buf);
    var hole: [4]geom.Segment = undefined;
    for (ccw, 0..) |sg, i| hole[ccw.len - 1 - i] = sg.reversed();
    const low = try a.dupe(geom.Contour, &.{ .{ .segments = try rect(a, 0, 0, 20, 10, true) }, .{ .segments = hole[0..ccw.len] } });
    const high = try a.dupe(geom.Contour, &.{ .{ .segments = try rect(a, 0, 0, 20, 10, true) }, .{ .segments = hole[0..ccw.len] }, .{ .segments = try rect(a, 3, 3, 8, 6, false) } });
    const bands = [_]Band{ .{ .outline = .{ .contours = low }, .z0 = 0, .z1 = 1.4 }, .{ .outline = .{ .contours = high }, .z0 = 1.4, .z1 = 2 } };
    const m = try solid(a, &bands, default_tolerance);
    try testing.expect(try closed(a, m));
    const lo = try prism(a, bands[0].outline, 0, 1.4, default_tolerance);
    const hi = try prism(a, bands[1].outline, 1.4, 2, default_tolerance);
    // The same within the curves' flattening (the union's arcs are cut
    // by the 2D booleans, so flattened at other points).
    try testing.expectApproxEqAbs(volume(lo) + volume(hi), volume(m), 2 * std.math.pi * 2 * default_tolerance * 2);
    try testing.expectApproxEqAbs((200 - std.math.pi * 4) * 2 - 15 * 0.6, volume(m), 0.05);

    // Turned over: still closed and facing out, standing on z = 0.
    const ps = [_]Part{.{ .name = "black", .colour = "black", .color = .hex("#000000"), .mesh = m }};
    const flipped = try orient(a, &ps, .top);
    try testing.expect(try closed(a, flipped[0].mesh));
    try testing.expectApproxEqAbs(volume(m), volume(flipped[0].mesh), 1e-9);
    var zmin = std.math.inf(f64);
    for (flipped[0].mesh.vertices) |v| zmin = @min(zmin, v[2]);
    try testing.expectEqual(@as(f64, 0), zmin);
}
