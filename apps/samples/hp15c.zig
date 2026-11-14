//! A rough HP-15C keypad, to try spacing and sizes on: a plate with a
//! grid of holes and, above each hole, the gold f legend; and the keys, a
//! part whose grid follows the plate's, each with its white legend on top
//! and its blue g legend on the front, in the keys' tracks. ENTER spans
//! two rows, its legend down a column track.
//!
//! Only the spacing across (11.43 mm on centre) is given. Everything else
//! (the spacing down, key, hole and legend sizes, the plate) is a first
//! guess, there to be changed in the grids' and stamps' properties. The
//! holes are the ready-made rounded-rectangle sketch. The
//! legends are from memory and may be wrong in places.

const std = @import("std");
const layout = @import("graven_layout");
const geom = @import("graven_engine").geom;

const Model = layout.Model;
const model = layout.model;
const StyleId = model.StyleId;

/// Between key centres across, mm: given.
pub const spacing_across = 11.43;
/// Between key centres down, mm: a guess.
pub const spacing_down = 12.7;
/// A key's top, mm: a guess.
pub const key_w = 9.0;
pub const key_h = 8.0;
/// The hole a key comes through: the key with 0.25 mm clearance all round,
/// a rounded rectangle (the ready-made sketch) with this corner radius, mm:
/// a guess.
pub const clearance = 0.25;
pub const hole_r = 1.0;
/// The gold legend's strip above each hole, mm, and its centre's height
/// above the key's centre.
pub const legend_w = 11.0;
pub const legend_h = 2.6;
pub const legend_up = 6.0;

pub const plate_w = 128.0;
pub const plate_h = 62.0;
/// The top-left key's centre on the plate, mm: the keys centred across.
pub const first: geom.Point = .{ .x = (plate_w - 9 * spacing_across) / 2.0, .y = 50.0 };

pub const Styles = struct {
    /// The white legend on a key's top.
    key: StyleId,
    /// The blue g legend on a key's front, and the gold f legend above it.
    g: StyleId,
    f: StyleId,
};

/// The keys, row by row: the white legend, the blue g, and the gold f.
/// ENTER (row 3, column 6) spans rows 3 and 4; its row 4 point is empty.
const Key = struct { top: []const u8, g: []const u8 = "", f: []const u8 = "" };

const rows = [4][10]Key{
    .{
        .{ .top = "\\sqrt{x}", .g = "x^2", .f = "A" },
        .{ .top = "e^x", .g = "LN", .f = "B" },
        .{ .top = "10^x", .g = "LOG", .f = "C" },
        .{ .top = "y^x", .g = "\\%", .f = "D" },
        .{ .top = "1/x", .g = "Δ\\%", .f = "E" },
        .{ .top = "CHS", .g = "ABS", .f = "MATRIX" },
        .{ .top = "7", .g = "DEG", .f = "FIX" },
        .{ .top = "8", .g = "RAD", .f = "SCI" },
        .{ .top = "9", .g = "GRD", .f = "ENG" },
        .{ .top = "÷", .g = "x<0", .f = "x≤y" },
    },
    .{
        .{ .top = "SST", .g = "BST", .f = "LBL" },
        .{ .top = "GTO", .g = "HYP^{-1}", .f = "HYP" },
        .{ .top = "SIN", .g = "SIN^{-1}", .f = "DIM" },
        .{ .top = "COS", .g = "COS^{-1}", .f = "(i)" },
        .{ .top = "TAN", .g = "TAN^{-1}", .f = "I" },
        .{ .top = "EEX", .g = "π", .f = "RESULT" },
        .{ .top = "4", .g = "SF", .f = "x⇄" },
        .{ .top = "5", .g = "CF", .f = "DSE" },
        .{ .top = "6", .g = "F?", .f = "ISG" },
        .{ .top = "×", .g = "x=0", .f = "∫_x^y" },
    },
    .{
        .{ .top = "R/S", .g = "P/R", .f = "PSE" },
        .{ .top = "GSB", .g = "RTN", .f = "Σ" },
        .{ .top = "R↓", .g = "R↑", .f = "PRGM" },
        .{ .top = "x⇄y", .g = "RND", .f = "REG" },
        .{ .top = "←", .g = "CLx", .f = "PREFIX" },
        .{ .top = "ENTER", .g = "LSTx", .f = "RAN#" },
        .{ .top = "1", .g = "→P", .f = "→R" },
        .{ .top = "2", .g = "→H", .f = "→H.MS" },
        .{ .top = "3", .g = "→DEG", .f = "→RAD" },
        .{ .top = "−", .g = "TEST", .f = "Re⇄Im" },
    },
    .{
        .{ .top = "ON" },
        .{ .top = "f" },
        .{ .top = "g" },
        .{ .top = "STO", .g = "INT", .f = "FRAC" },
        .{ .top = "RCL", .g = "MEM", .f = "USER" },
        .{ .top = "" },
        .{ .top = "0", .g = "\\bar{x}", .f = "x!" },
        .{ .top = ".", .g = "s", .f = "ŷ,r" },
        .{ .top = "Σ+", .g = "Σ−", .f = "L.R." },
        .{ .top = "+", .g = "Cy,x", .f = "Py,x" },
    },
};

pub const enter_col = 5;
pub const enter_row = 2;

pub const Built = struct { plate: usize, keys: usize };

/// Adds the plate and the keys as two panels in space `space`, the plate's
/// bottom-left corner at `at` and the keys beside it; returns them.
pub fn build(m: *Model, styles: Styles, space: usize, at: geom.Point) !Built {
    const plate = try m.placePanel(.{ .name = "HP-15C plate", .space = m.spaces.items[space].id, .origin = at, .w = plate_w, .h = plate_h, .margins = .all(3), .default_margins = false });
    const keys = try m.placePanel(.{ .name = "HP-15C keys", .space = m.spaces.items[space].id, .origin = .{ .x = at.x + plate_w + 15, .y = at.y }, .w = plate_w, .h = plate_h, .margins = .all(3), .default_margins = false });

    // A key: its top, a row track for the white legend in its upper part
    // and one for the blue g on its front, a band along the bottom. Its
    // face is 8.2 x 7.2 mm.
    const key = try m.addPrototype(.{
        .name = "15C key",
        .face_inset = .all(0.4),
        .tracks = &.{
            .{ .name = "top", .style = styles.key, .alignment = .centre, .place = .{ .inset = .{ .top = 0.8, .bottom = 3.0 } } },
            .{ .name = "g", .style = styles.g, .alignment = .centre, .place = .{ .inset = .{ .top = 4.8 } } },
        },
    });
    // ENTER: its legend in a column track down the key, a character at a
    // time; the g legend on the front as on the others. Its face is
    // 8.2 x (key_h + spacing_down - 0.8) mm.
    const enter_face_h = key_h + spacing_down - 0.8;
    const enter_proto = try m.addPrototype(.{
        .name = "15C ENTER key",
        .face_inset = .all(0.4),
        .tracks = &.{
            // One column wide (a cap height and a half at the 1.9 mm caps
            // the app gives it), so the letters centre on the key.
            .{ .name = "top", .style = styles.key, .major = .column, .alignment = .centre, .place = .{ .inset = .{ .top = 1.0, .bottom = 3.0, .left = 2.675, .right = 2.675 } } },
            .{ .name = "g", .style = styles.g, .alignment = .centre, .place = .{ .inset = .{ .top = enter_face_h - 2.4 } } },
        },
    });
    // The gold legend above a hole: only its track.
    const gold = try m.addPrototype(.{
        .name = "15C gold legend",
        .tracks = &.{.{ .name = "f", .style = styles.f, .alignment = .centre }},
    });

    const shape: model.GridShape = .{ .cols = 10, .rows = 4, .pitch_x = spacing_across, .pitch_y = spacing_down };
    const pg = try m.addGrid(plate, first, shape);
    const rounded = m.sketches.items[try m.addShapeSketch(.rounded_rectangle)].id;
    const holes = try m.addStamp(plate, pg, .{ .name = "Holes", .prototype = key, .role = .hole, .w = key_w + 2 * clearance, .h = key_h + 2 * clearance, .sketch = rounded, .params = &.{.{ .name = "r", .value = hole_r }} });
    const golds = try m.addStamp(plate, pg, .{ .name = "Gold legends", .prototype = gold, .role = .legend, .w = legend_w, .h = legend_h, .offset = .{ .x = 0, .y = legend_up } });
    const kg = try m.addLinkedGrid(keys, first, m.panels.items[plate].grids.items[pg].id);
    const caps = try m.addStamp(keys, kg, .{ .name = "Keys", .prototype = key, .w = key_w, .h = key_h });

    for (rows, 0..) |row, r| for (row, 0..) |k, c| {
        const col: u32 = @intCast(c);
        const ro: u32 = @intCast(r);
        // ENTER's lower half: covered by ENTER.
        if (c == enter_col and r == enter_row + 1) continue;
        const span: u32 = if (c == enter_col and r == enter_row) 2 else 1;
        _ = try m.placeInstance(plate, pg, holes, col, ro, 1, span);
        const t = try m.placeInstance(keys, kg, caps, col, ro, 1, span);
        if (span > 1) try m.setTilePrototype(t, enter_proto);
        if (k.top.len > 0) try m.setTileTrackText(t, m.tileTrackNamed(t, "top").?, k.top);
        if (k.g.len > 0) try m.setTileTrackText(t, m.tileTrackNamed(t, "g").?, k.g);
        if (k.f.len > 0) {
            const l = try m.placeInstance(plate, pg, golds, col, ro, 1, 1);
            try m.setTileTrackText(l, m.tileTrackNamed(l, "f").?, k.f);
        }
    };
    return .{ .plate = plate, .keys = keys };
}

test "the HP-15C keypad: 39 holes and keys at 11.43 mm across, ENTER over two rows, gold legends over the holes" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const st = try m.addStyle("key", .{ .upright = 0, .cap_height = 1.9 });
    const b = try build(&m, .{ .key = st, .g = st, .f = st }, 0, .{ .x = 0, .y = 0 });
    const pg = m.panels.items[b.plate].grids.items[0];
    const kg = m.panels.items[b.keys].grids.items[0];
    try std.testing.expectEqual(@as(usize, 39), kg.instances.items.len);
    var holes: usize = 0;
    for (pg.instances.items) |inst| {
        if (inst.stamp == pg.stamps.items[0].id) holes += 1;
    }
    try std.testing.expectEqual(@as(usize, 39), holes);
    // The holes are the ready-made rounded rectangle.
    const hs = pg.stamps.items[0];
    try std.testing.expectEqual(model.ShapeSketch.rounded_rectangle, m.sketches.items[m.sketchIndex(hs.sketch).?].shape.?);
    // Keys one apart are 11.43 mm apart across, on the plate and the keys.
    const a = m.instanceBox(b.keys, 0, m.instanceAt(b.keys, 0, kg.stamps.items[0].id, 3, 0).?).?;
    const z = m.instanceBox(b.keys, 0, m.instanceAt(b.keys, 0, kg.stamps.items[0].id, 4, 0).?).?;
    try std.testing.expectApproxEqAbs(spacing_across, (z.x0 + z.x1) / 2 - (a.x0 + a.x1) / 2, 1e-9);
    const enter = m.instanceBox(b.keys, 0, m.instanceAt(b.keys, 0, kg.stamps.items[0].id, enter_col, enter_row + 1).?).?;
    try std.testing.expectApproxEqAbs(key_h + spacing_down, enter.height(), 1e-9);
    // A gold legend sits above its hole, clear of it.
    const hole = m.instanceBox(b.plate, 0, m.instanceAt(b.plate, 0, pg.stamps.items[0].id, 0, 0).?).?;
    const gold = m.instanceBox(b.plate, 0, m.instanceAt(b.plate, 0, pg.stamps.items[1].id, 0, 0).?).?;
    try std.testing.expect(gold.y0 > hole.y1);
    try std.testing.expectApproxEqAbs((hole.x0 + hole.x1) / 2, (gold.x0 + gold.x1) / 2, 1e-9);
    // Everything lies on the plate.
    for (pg.instances.items, 0..) |_, ii| {
        const bx = m.instanceBox(b.plate, 0, ii).?;
        try std.testing.expect(bx.x0 >= 0 and bx.x1 <= plate_w and bx.y0 >= 0 and bx.y1 <= plate_h);
    }
}
