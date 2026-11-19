//! The example documents, as files: each opens, and lays out as it
//! should. These are the checks the samples' code had, kept for the files
//! that replace it.

const std = @import("std");
const layout = @import("graven_layout");

const testing = std.testing;

const Opened = layout.history.Opened;

fn open(bytes: []const u8) !Opened {
    return layout.history.openFile(testing.allocator, bytes);
}

fn close(o: *Opened) void {
    o.model.deinit();
    o.history.deinit();
}

fn panelNamed(m: *const layout.Model, name: []const u8) !usize {
    for (m.panels.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return error.TestUnexpectedResult;
}

test "the PC keyboard: 104 keys in 22.5 × 6.5 u, nothing overflowing, its legends one a slot" {
    var o = try open(@embedFile("pc-keyboard.graven"));
    defer close(&o);
    const m = &o.model;
    const p = try panelNamed(m, "PC keyboard (ANSI 104)");
    var labels: layout.Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var placed = try layout.solve(testing.allocator, m, p, &labels);
    defer placed.deinit();
    try testing.expectEqual(104, placed.tiles.len);
    for (placed.issues) |i| try testing.expect(i.kind != .row_overflow and i.kind != .tile_size);
    const pitch = 19.05;
    try testing.expectApproxEqAbs(22.5 * pitch, placed.bounds.width(), 1e-9);
    try testing.expectApproxEqAbs(6.5 * pitch, placed.bounds.height(), 1e-9);
    // Its legends' faces named, so it sets the same wherever it is opened.
    for (m.styles.items) |st| {
        if (!std.mem.startsWith(u8, st.name, "legend")) continue;
        try testing.expectEqualStrings("Inter", st.face("text").?.family);
    }
    // A sheet over its track: a column a slot.
    const id = try m.makeSheet("Keyboard legends", m.panels.items[p].regions.items[0].id);
    const sh = m.sheets.items[m.sheetIndex(id).?];
    try testing.expectEqual(104, sh.rows.items.len);
    try testing.expectEqualStrings("top", sh.columns.items[0]);
    try testing.expectEqualStrings("bottom", sh.columns.items[1]);
    try testing.expectEqualStrings("words", sh.columns.items[2]);
}

test "the HP-15C: 39 keys and holes at 11.43 mm, ENTER over two rows, gold legends, fabrication layers" {
    var o = try open(@embedFile("hp15c.graven"));
    defer close(&o);
    const m = &o.model;
    const plate = try panelNamed(m, "HP-15C plate");
    const keys = try panelNamed(m, "HP-15C keys");
    const pg = m.panels.items[plate].grids.items[0];
    const kg = m.panels.items[keys].grids.items[0];
    try testing.expectEqual(39, kg.instances.items.len);
    var holes: usize = 0;
    for (pg.instances.items) |inst| {
        if (inst.stamp == pg.stamps.items[0].id) holes += 1;
    }
    try testing.expectEqual(39, holes);
    const caps = kg.stamps.items[0].id;
    const a = m.instanceBox(keys, 0, m.instanceAt(keys, 0, caps, 3, 0).?).?;
    const z = m.instanceBox(keys, 0, m.instanceAt(keys, 0, caps, 4, 0).?).?;
    try testing.expectApproxEqAbs(11.43, (z.x0 + z.x1) / 2 - (a.x0 + a.x1) / 2, 1e-9);
    const enter = m.instanceBox(keys, 0, m.instanceAt(keys, 0, caps, 5, 3).?).?;
    try testing.expectApproxEqAbs(7.2 + 12.7, enter.height(), 1e-9);
    // Plate: black, holes cut, gold inlaid; keys: black, white and blue.
    try testing.expectEqual(3, m.panels.items[plate].fab.layers.len);
    try testing.expectEqual(3, m.panels.items[keys].fab.layers.len);
    try testing.expectEqualStrings("f", m.panels.items[plate].fab.layers[2].source.text);
    // Both made with the one 0.2 mm FDM profile the file keeps.
    try testing.expectEqual(1, m.processes.items.len);
    for ([_]usize{ plate, keys }) |p| {
        const pr = m.processOf(p).?;
        try testing.expectEqualStrings("Generic FDM, 0.2 mm nozzle", pr.name);
        try testing.expectEqual(0.2, pr.params.fdm.nozzle);
    }
    // Its legends as a sheet: a row a key, white, blue and gold.
    const id = try m.makeSheet("Legends", kg.id);
    const sh = m.sheets.items[m.sheetIndex(id).?];
    try testing.expectEqual(39, sh.rows.items.len);
    try testing.expectEqualStrings("$\\sqrt{x}$", sh.rows.items[0].cells.items[0]);
    try testing.expectEqualStrings("A", sh.rows.items[0].cells.items[2]);
    var labels: layout.Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    for ([_]usize{ plate, keys }) |p| {
        var placed = try layout.solve(testing.allocator, m, p, &labels);
        defer placed.deinit();
        for (placed.issues) |i| try testing.expect(i.kind != .row_overflow);
    }
}

test "a key sized outside the key prototype's rules is flagged, not refused" {
    var o = try open(@embedFile("pc-keyboard.graven"));
    defer close(&o);
    const m = &o.model;
    const p = try panelNamed(m, "PC keyboard (ANSI 104)");
    var labels: layout.Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    // K38 is Tab, 1.5 u wide.
    const tab = m.findTile("K38").?;
    for ([_]struct { w: f64, flagged: bool }{ .{ .w = 1.3, .flagged = true }, .{ .w = 1.25, .flagged = false } }) |c| {
        try m.setTileSize(tab, c.w, 1);
        var placed = try layout.solve(testing.allocator, m, p, &labels);
        defer placed.deinit();
        var flagged = false;
        for (placed.issues) |i| if (i.kind == .tile_size) {
            try testing.expectEqual(tab, i.tile.?);
            flagged = true;
        };
        try testing.expectEqual(c.flagged, flagged);
    }
}

test "the keyboard saved and read back lays out and exports exactly the same" {
    const gpa = testing.allocator;
    var o = try open(@embedFile("pc-keyboard.graven"));
    defer close(&o);
    const m = &o.model;
    const p = try panelNamed(m, "PC keyboard (ANSI 104)");
    const bytes = try layout.native.encode(gpa, m);
    defer gpa.free(bytes);
    var back = try layout.native.decode(gpa, bytes);
    defer back.deinit();
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var a = try layout.solve(gpa, m, p, &labels);
    defer a.deinit();
    var labels2: layout.Labels = .init(gpa, &.{});
    defer labels2.deinit();
    var b = try layout.solve(gpa, &back, p, &labels2);
    defer b.deinit();
    try testing.expectEqual(a.tiles.len, b.tiles.len);
    const svg_a = try layout.output.panelSvg(gpa, &a, &.{}, .{});
    defer gpa.free(svg_a);
    const svg_b = try layout.output.panelSvg(gpa, &b, &.{}, .{});
    defer gpa.free(svg_b);
    try testing.expectEqualStrings(svg_a, svg_b);
}
