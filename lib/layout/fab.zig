//! A part's fabrication plan: its stack of layer operations (`model.Fab`)
//! resolved against the placed part into steps of plain geometry, each a
//! set of outlines swept between two heights and added or cut away. The
//! steps carry no OCCT: the bridge (bridge/occt/fab.zig) turns them into
//! solids, one per colour.

const std = @import("std");
const font = @import("graven_font");
const model = @import("model.zig");
const place = @import("place.zig");
const art = @import("art.zig");
const geom = @import("graven_geom");
const Allocator = std.mem.Allocator;

pub const Step = struct {
    /// The layer it comes from (its index in the stack).
    layer: usize,
    /// Its geometry, mm in the part's frame: outlines each filled even-odd,
    /// swept separately and joined (glyphs, holes, parts).
    pieces: []const geom.Outline,
    z0: f64,
    z1: f64,
    op: union(enum) { add: model.FabColour, subtract },
};

pub const Plan = struct {
    steps: []const Step,
    /// Depths and heights that are not whole multiples of the layer height:
    /// the layer indices (flagged, not refused).
    off_layers: []const usize,
};

/// The plan for panel `panel` as `placed` lays it out; `faces` are the
/// faces the labels were set in. Allocated from `a`.
pub fn plan(a: Allocator, m: *const model.Model, panel: usize, placed: *const place.Placed, faces: []const *font.Face) !Plan {
    const fab = m.panels.items[panel].fab;
    // The extent of everything but the through layers, for those to cut
    // clean through.
    var lo: f64 = 0;
    var hi: f64 = fab.thickness;
    for (fab.layers) |l| if (l.depth != null) {
        const z = extent(fab, l, 0, 0);
        lo = @min(lo, z[0]);
        hi = @max(hi, z[1]);
    };
    var steps: std.ArrayList(Step) = .empty;
    var off: std.ArrayList(usize) = .empty;
    for (fab.layers, 0..) |l, li| {
        // Depths in whole layers, where its process lays layers.
        if (l.depth) |d| if (m.processOf(panel)) |pr| if (pr.limits().layer) |lh| {
            const n = d / lh;
            if (@abs(n - @round(n)) > 1e-6) try off.append(a, li);
        };
        const pieces = try source(a, m, panel, placed, faces, l.source);
        if (pieces.len == 0) continue;
        const z = extent(fab, l, lo - 1, hi + 1);
        // The active plan's colour for it, where it gives one; else the
        // layer's own (a document without plans).
        const planned = m.planColour(panel, l.name);
        switch (l.op) {
            .add => |own| {
                const c = planned orelse own;
                try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .{ .add = c } });
            },
            .subtract => try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .subtract }),
            .inlay => |own| {
                const c = planned orelse own;
                try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .subtract });
                try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .{ .add = c } });
            },
        }
    }
    return .{ .steps = steps.items, .off_layers = off.items };
}

/// A height range the plan is the same throughout, and each colour's
/// footprint there: exact 2D regions, to be swept from `z0` to `z1`.
pub const Slab = struct {
    z0: f64,
    z1: f64,
    regions: []const Region,
};

pub const Region = struct {
    colour: model.FabColour,
    outline: geom.Outline,
};

/// The plan as slabs. Steps are straight sweeps along z, so between any two
/// of their heights each point of the plane belongs to the colour of the
/// last step covering it there (none, when that is a subtract): 2D
/// booleans per slab, so no 3D booleans are needed, and the colours cannot
/// overlap.
pub fn slabs(a: Allocator, steps: []const Step) ![]const Slab {
    var zs: std.ArrayList(f64) = .empty;
    for (steps) |st| try zs.appendSlice(a, &.{ st.z0, st.z1 });
    std.mem.sort(f64, zs.items, {}, std.sort.asc(f64));
    var out: std.ArrayList(Slab) = .empty;
    var k: usize = 0;
    while (k + 1 < zs.items.len) : (k += 1) {
        const lo = zs.items[k];
        const hi = zs.items[k + 1];
        if (hi - lo < 1e-9) continue;
        // The steps covering this slab, in order, and their pieces.
        var inputs: std.ArrayList(geom.Outline) = .empty;
        var owner: std.ArrayList(usize) = .empty;
        var kinds: std.ArrayList(?usize) = .empty;
        var colours: std.ArrayList(model.FabColour) = .empty;
        for (steps) |st| {
            if (!(st.z0 <= lo + 1e-9 and st.z1 >= hi - 1e-9)) continue;
            const kind: ?usize = switch (st.op) {
                .subtract => null,
                .add => |c| blk: {
                    for (colours.items, 0..) |have, ci| if (std.mem.eql(u8, have.name, c.name)) break :blk ci;
                    try colours.append(a, c);
                    break :blk colours.items.len - 1;
                },
            };
            try kinds.append(a, kind);
            for (st.pieces) |pc| {
                try inputs.append(a, pc);
                try owner.append(a, kinds.items.len - 1);
            }
        }
        if (colours.items.len == 0) continue;
        // Every colour's region from one pass over the inputs.
        const ctxs = try a.alloc(Owner, colours.items.len);
        const rules = try a.alloc(geom.boolean.Rule, colours.items.len);
        for (ctxs, rules, 0..) |*cx, *r, ci| {
            cx.* = .{ .owner = owner.items, .kinds = kinds.items, .colour = ci };
            r.* = .{ .ctx = cx, .inside = Owner.inside };
        }
        const outs = try geom.boolean.combineMany(a, inputs.items, rules);
        var regions: std.ArrayList(Region) = .empty;
        for (colours.items, outs) |col, o| {
            if (o.contours.len > 0) try regions.append(a, .{ .colour = col, .outline = o });
        }
        if (regions.items.len > 0) try out.append(a, .{ .z0 = lo, .z1 = hi, .regions = regions.items });
    }
    return out.items;
}

/// Whose a point is: the colour of the last covering step's add.
const Owner = struct {
    owner: []const usize,
    kinds: []const ?usize,
    colour: usize,

    fn inside(ctx: *const anyopaque, in: []const bool) bool {
        const o: *const Owner = @ptrCast(@alignCast(ctx));
        var last: ?usize = null;
        for (in, o.owner) |hit, step| if (hit) {
            if (last == null or step > last.?) last = step;
        };
        const step = last orelse return false;
        return if (o.kinds[step]) |k| k == o.colour else false;
    }
};

/// The heights layer `l` spans; a through layer spans `lo` to `hi`.
fn extent(fab: model.Fab, l: model.FabLayer, lo: f64, hi: f64) [2]f64 {
    const d = l.depth orelse return .{ lo, hi };
    const plane = l.offset + switch (l.surface) {
        .base_bottom => @as(f64, 0),
        .base_top => fab.thickness,
    };
    return switch (l.dir) {
        .up => .{ plane, plane + d },
        .down => .{ plane - d, plane },
    };
}

/// The outlines source `src` takes from the placed part.
fn source(a: Allocator, m: *const model.Model, panel: usize, placed: *const place.Placed, faces: []const *font.Face, src: model.FabSource) ![]const geom.Outline {
    var out: std.ArrayList(geom.Outline) = .empty;
    switch (src) {
        .edge => {
            if (placed.edge) |e| {
                try out.append(a, e);
            } else {
                const p = m.panels.items[panel];
                const shapes = try art.primitive(a, "edge", .{ .rect = .{ .w = p.w, .h = p.h } }, .{});
                try out.append(a, shapes[0].outline);
            }
        },
        .cutouts => {
            for (placed.art) |pa| if (pa.cutout) for (pa.shapes) |sh| try out.append(a, sh.outline);
            for (placed.tiles) |t| if (t.grid == .hole) for (t.shapes) |sh| try out.append(a, sh.outline);
        },
        .parts => for (placed.tiles) |t| if (t.grid == .part) {
            if (largest(t.shapes)) |sh| try out.append(a, sh.outline);
        },
        .text => |track| {
            for (placed.labels) |l| {
                if (!takes(m, track, l)) continue;
                const glyphs = try l.render.outlines(a, faces);
                for (glyphs) |g| {
                    if (g.contours.len == 0) continue;
                    try out.append(a, try g.transformed(a, .translate(l.origin.x, l.origin.y)));
                }
            }
            // Paragraph rules are the text's ink too (not a tile track's).
            if (track.len == 0) for (placed.rules) |r| for (r.shapes) |sh| try out.append(a, sh.outline);
        },
        .ink, .fills => |name| {
            const list = m.panels.items[panel].art.items;
            for (placed.art) |pa| {
                if (pa.cutout or pa.index >= list.len) continue;
                if (name.len > 0 and !std.mem.eql(u8, list[pa.index].name, name)) continue;
                for (pa.shapes) |sh| {
                    const ink = try art.inkRegions(a, sh, model.figure_tolerance);
                    const take = if (src == .ink) [2]?geom.Outline{ ink.stroke, ink.edge } else [2]?geom.Outline{ ink.fill, null };
                    for (take) |o| if (o) |x| try out.append(a, x);
                }
            }
        },
    }
    return out.items;
}

/// Whether a text layer naming `track` (every label when empty) takes
/// label `l`: a tile's text in a track of that name.
pub fn takes(m: *const model.Model, track: []const u8, l: place.PlacedLabel) bool {
    if (track.len == 0) return true;
    const tile = l.tile orelse return false;
    const proto = m.proto(m.tileConst(tile).prototype);
    return l.slot < proto.tracks.len and std.mem.eql(u8, proto.tracks[l.slot].name, track);
}

/// The shape with the largest box: a part's outline.
fn largest(shapes: []const art.Shape) ?art.Shape {
    var best: ?art.Shape = null;
    var best_area: f64 = -1;
    for (shapes) |sh| {
        const b = sh.outline.bounds();
        if (b.width() * b.height() > best_area) {
            best_area = b.width() * b.height();
            best = sh;
        }
    }
    return best;
}

const testing = std.testing;
const testdata = @import("graven_testdata");

test "a plate's stack: base, holes through, an inlaid legend; heights from its surfaces" {
    const gpa = testing.allocator;
    const face = try font.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*font.Face{face};
    var m: model.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const style = try m.addStyle("Legend", .{ .cap_height = 2 });
    const plate = try m.placePanel(.{ .name = "Plate", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 40, .h = 20 });
    const key = try m.addPrototype(.{ .name = "Key" });
    const legend = try m.addPrototype(.{ .name = "Legend", .tracks = &.{.{ .name = "f", .style = style, .alignment = .centre }} });
    const g = try m.addGrid(.{ .panel = plate }, .{ .x = 10, .y = 8 }, .{ .cols = 2, .rows = 1, .pitch_x = 20, .pitch_y = 10 });
    _ = try m.addStamp(.{ .panel = plate }, g, .{ .name = "Holes", .prototype = key, .role = .hole, .w = 6, .h = 5 });
    _ = try m.fillGrid(.{ .panel = plate }, g, 0);
    _ = try m.addStamp(.{ .panel = plate }, g, .{ .name = "Legends", .prototype = legend, .role = .legend, .w = 10, .h = 4, .offset = .{ .x = 0, .y = 6 } });
    const t = try m.placeInstance(.{ .panel = plate }, g, 1, 0, 0, 1, 1);
    try m.setTrackText(t, "f", "HOD");
    const gold: model.FabColour = .{ .name = "gold", .color = .hex("#d4a017") };
    // Made by FDM at 0.2 mm layers: a depth not a whole number of them is
    // flagged.
    const fdm = try m.addProcess(model.process.builtin("Generic FDM, 0.4 mm nozzle").?);
    try m.setPanelFab(plate, .{ .thickness = 2, .process = fdm, .layers = &.{
        .{ .name = "Base", .source = .edge, .surface = .base_bottom, .dir = .up, .depth = 2, .op = .{ .add = .{ .name = "black", .color = .hex("#202020") } } },
        .{ .name = "Holes", .source = .cutouts, .op = .subtract },
        .{ .name = "Legends", .source = .{ .text = "f" }, .depth = 0.5, .op = .{ .inlay = gold } },
    } });

    var labels: place.Labels = .init(gpa, &faces);
    defer labels.deinit();
    var placed = try place.solve(gpa, &m, .{ .panel = plate }, &labels);
    defer placed.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = try plan(arena.allocator(), &m, plate, &placed, &faces);
    // Base, holes, and the inlay's cut and fill.
    try testing.expectEqual(@as(usize, 4), p.steps.len);
    const base = p.steps[0];
    try testing.expectEqual(@as(usize, 1), base.pieces.len);
    try testing.expectEqual(@as(f64, 0), base.z0);
    try testing.expectEqual(@as(f64, 2), base.z1);
    // Through: past the base both ways.
    const holes = p.steps[1];
    try testing.expectEqual(@as(usize, 2), holes.pieces.len);
    try testing.expect(holes.op == .subtract and holes.z0 < 0 and holes.z1 > 2);
    // The inlay: cut then filled, 0.5 down from the top; a piece a glyph.
    try testing.expect(p.steps[2].op == .subtract and p.steps[3].op == .add);
    try testing.expectEqual(@as(usize, 3), p.steps[3].pieces.len);
    try testing.expectApproxEqAbs(@as(f64, 1.5), p.steps[3].z0, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), p.steps[3].z1, 1e-12);
    try testing.expectEqualStrings("gold", p.steps[3].op.add.name);
    // 0.5 is not a whole number of 0.2 mm layers: flagged.
    try testing.expectEqualSlices(usize, &.{2}, p.off_layers);
    // Glyphs lie over the legend's box, above the first hole.
    const gb = p.steps[3].pieces[0].bounds();
    try testing.expect(gb.y0 > 8 + 2.5);

    // As slabs: 0 to 1.5, the plate less its holes; 1.5 to 2, the plate
    // less its holes and the glyphs, and the glyphs in gold. Every slab's
    // colours fill the plate less its holes between them.
    const sl = try slabs(arena.allocator(), p.steps);
    try testing.expectEqual(@as(usize, 2), sl.len);
    try testing.expectApproxEqAbs(@as(f64, 1.5), sl[0].z1, 1e-12);
    try testing.expectEqual(@as(usize, 1), sl[0].regions.len);
    try testing.expectEqual(@as(usize, 2), sl[1].regions.len);
    const solid = sl[0].regions[0].outline.signedArea();
    var hole_area: f64 = 0;
    for (holes.pieces) |h| hole_area += @abs(h.signedArea());
    try testing.expectApproxEqAbs(800 - hole_area, solid, 1e-6);
    const black = sl[1].regions[0].outline.signedArea();
    const gold_area = sl[1].regions[1].outline.signedArea();
    try testing.expectEqualStrings("gold", sl[1].regions[1].colour.name);
    try testing.expect(gold_area > 1);
    try testing.expectApproxEqAbs(solid, black + gold_area, 1e-6);
}

test "line art's ink and fills are sources: edges stroked exactly, fills as filled" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const plate = try m.placePanel(.{ .name = "Plate", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 40, .h = 20 });
    var shape_arena: std.heap.ArenaAllocator = .init(gpa);
    defer shape_arena.deinit();
    const square = try art.primitive(shape_arena.allocator(), "square", .{ .rect = .{ .w = 10, .h = 10 } }, .{});
    const patch = try art.primitive(shape_arena.allocator(), "patch", .{ .rect = .{ .w = 10, .h = 5 } }, .{});
    // A square drawn with a 0.5 mm pen, a patch filled red.
    const shapes = [_]art.Shape{
        .{ .name = "square", .outline = square[0].outline, .paint = .{ .edge = .hex("#000000"), .edge_width = 0.5 } },
        .{ .name = "patch", .outline = patch[0].outline, .paint = .{ .fill = .{ .solid = .hex("#ff0000") } } },
    };
    _ = try m.addArt(plate, .{ .name = "Drawing", .at = .{ .x = 5, .y = 5 }, .shapes = &shapes, .wrap = .none });
    const red: model.FabColour = .{ .name = "red", .color = .hex("#ff0000") };
    try m.setPanelFab(plate, .{ .thickness = 2, .layers = &.{
        .{ .name = "Base", .source = .edge, .op = .{ .add = .{ .name = "white", .color = .hex("#ffffff") } } },
        .{ .name = "Ink", .source = .{ .ink = "" }, .depth = 0.4, .op = .{ .inlay = .{ .name = "black", .color = .hex("#000000") } } },
        .{ .name = "Fills", .source = .{ .fills = "Drawing" }, .depth = 0.4, .op = .{ .inlay = red } },
        .{ .name = "None", .source = .{ .fills = "Other" }, .depth = 0.4, .op = .{ .inlay = red } },
    } });
    var labels: place.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var placed = try place.solve(gpa, &m, .{ .panel = plate }, &labels);
    defer placed.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = try plan(arena.allocator(), &m, plate, &placed, &.{});
    // Base; the ink's cut and fill; the fills' cut and fill; none named Other.
    try testing.expectEqual(@as(usize, 5), p.steps.len);
    // The square's pen: 10.5² less 9.5² (mitred corners).
    const ink = p.steps[2];
    try testing.expectEqualStrings("black", ink.op.add.name);
    try testing.expectEqual(@as(usize, 1), ink.pieces.len);
    var ink_area: f64 = 0;
    for (ink.pieces[0].contours) |c| ink_area += (geom.Outline{ .contours = &.{c} }).signedArea();
    try testing.expectApproxEqAbs(@as(f64, 20), @abs(ink_area), 1e-6);
    const ib = ink.pieces[0].bounds();
    try testing.expectApproxEqAbs(@as(f64, 4.75), ib.x0, 1e-9);
    // The patch: its own region, red.
    const fl = p.steps[4];
    try testing.expectEqualStrings("red", fl.op.add.name);
    try testing.expectApproxEqAbs(@as(f64, 50), @abs(fl.pieces[0].signedArea()), 1e-9);
}

test "a drawing's ink is stroked, so it is ink and not fill" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const figure = @import("figure.zig");
    const segs = [_]geom.Segment{.{ .line = .{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } } }};
    const f: figure.Figure = .{ .name = "L", .paths = &.{.{ .subpaths = &.{.{ .segments = &segs }}, .stroke = .{ .color = .hex("#000000"), .width = 1 } }} };
    const shapes = try figure.ink(a, f, 1e-3);
    const ink = try art.inkRegions(a, shapes[0], 1e-3);
    try testing.expect(ink.fill == null and ink.edge == null);
    try testing.expectApproxEqAbs(@as(f64, 10), @abs(ink.stroke.?.signedArea()), 1e-9);
}
