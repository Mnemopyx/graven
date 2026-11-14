//! A part's fabrication plan: its stack of layer operations (`model.Fab`)
//! resolved against the placed part into steps of plain geometry, each a
//! set of outlines swept between two heights and added or cut away. The
//! steps carry no OCCT: the bridge (bridge/occt/fab.zig) turns them into
//! solids, one per colour.

const std = @import("std");
const engine = @import("graven_engine");
const model = @import("model.zig");
const place = @import("place.zig");
const art = @import("art.zig");
const geom = engine.geom;
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
pub fn plan(a: Allocator, m: *const model.Model, panel: usize, placed: *const place.Placed, faces: []const *engine.Face) !Plan {
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
        if (l.depth) |d| {
            const n = d / fab.layer_height;
            if (@abs(n - @round(n)) > 1e-6) try off.append(a, li);
        }
        const pieces = try source(a, m, panel, placed, faces, l.source);
        if (pieces.len == 0) continue;
        const z = extent(fab, l, lo - 1, hi + 1);
        switch (l.op) {
            .add => |c| try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .{ .add = c } }),
            .subtract => try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .subtract }),
            .inlay => |c| {
                try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .subtract });
                try steps.append(a, .{ .layer = li, .pieces = pieces, .z0 = z[0], .z1 = z[1], .op = .{ .add = c } });
            },
        }
    }
    return .{ .steps = steps.items, .off_layers = off.items };
}

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
fn source(a: Allocator, m: *const model.Model, panel: usize, placed: *const place.Placed, faces: []const *engine.Face, src: model.FabSource) ![]const geom.Outline {
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
        .text => |track| for (placed.labels) |l| {
            if (track.len > 0) {
                const tile = l.tile orelse continue;
                const proto = m.proto(m.tileConst(tile).prototype);
                if (l.slot >= proto.tracks.len or !std.mem.eql(u8, proto.tracks[l.slot].name, track)) continue;
            }
            const glyphs = try l.render.outlines(a, faces);
            for (glyphs) |g| {
                if (g.contours.len == 0) continue;
                try out.append(a, try g.transformed(a, .translate(l.origin.x, l.origin.y)));
            }
        },
    }
    return out.items;
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
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: model.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const style = try m.addStyle("Legend", .{ .upright = 0, .cap_height = 2 });
    const plate = try m.placePanel(.{ .name = "Plate", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 40, .h = 20 });
    const key = try m.addPrototype(.{ .name = "Key" });
    const legend = try m.addPrototype(.{ .name = "Legend", .tracks = &.{.{ .name = "f", .style = style, .alignment = .centre }} });
    const g = try m.addGrid(plate, .{ .x = 10, .y = 8 }, .{ .cols = 2, .rows = 1, .pitch_x = 20, .pitch_y = 10 });
    _ = try m.addStamp(plate, g, .{ .name = "Holes", .prototype = key, .role = .hole, .w = 6, .h = 5 });
    _ = try m.fillGrid(plate, g, 0);
    _ = try m.addStamp(plate, g, .{ .name = "Legends", .prototype = legend, .role = .legend, .w = 10, .h = 4, .offset = .{ .x = 0, .y = 6 } });
    const t = try m.placeInstance(plate, g, 1, 0, 0, 1, 1);
    try m.setTrackText(t, "f", "HOD");
    const gold: model.FabColour = .{ .name = "gold", .color = .hex("#d4a017") };
    try m.setPanelFab(plate, .{ .thickness = 2, .layers = &.{
        .{ .name = "Base", .source = .edge, .surface = .base_bottom, .dir = .up, .depth = 2, .op = .{ .add = .{ .name = "black", .color = .hex("#202020") } } },
        .{ .name = "Holes", .source = .cutouts, .op = .subtract },
        .{ .name = "Legends", .source = .{ .text = "f" }, .depth = 0.5, .op = .{ .inlay = gold } },
    } });

    var labels: place.Labels = .init(gpa, &faces);
    defer labels.deinit();
    var placed = try place.solve(gpa, &m, plate, &labels);
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
}
