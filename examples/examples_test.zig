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

// Manufacturing plans -----------------------------------------------------------

const manufacture = layout.model.manufacture;

test "the HP-15C opens with its fabrication as a plan: both panels, of PLA, one print in the layers' colours, nothing to warn of" {
    var o = try open(@embedFile("hp15c.graven"));
    defer close(&o);
    const m = &o.model;
    try testing.expectEqual(1, m.plans.items.len);
    const plan = m.activePlan().?.*;
    try testing.expectEqual(2, plan.parts.len);
    try testing.expectEqual(1, plan.operations.len);
    try testing.expectEqual(6, plan.operations[0].targets.len);
    const mat = m.materials.items[m.materialIndex(plan.parts[0].material).?].material;
    try testing.expectEqualStrings("PLA", mat.name);
    const plate = try panelNamed(m, "HP-15C plate");
    try testing.expectEqualStrings("gold", m.planColour(plate, "Gold legends").?.name);
    try testing.expectEqual(@as(?manufacture.Finish, null), m.planColour(plate, "Key holes"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try manufacture.warnings(arena.allocator(), m, plan)).len);
}

test "a plan's colour is what the part is made in; one the process cannot give is flagged; undone" {
    var o = try open(@embedFile("hp15c.graven"));
    defer close(&o);
    const m = &o.model;
    const h = &o.history;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plate = try panelNamed(m, "HP-15C plate");
    const plan = m.activePlan().?.*;
    // The plate printed in PLA's grey instead of black (its own layer
    // needs no glyphs, so no faces are loaded here).
    var next = plan;
    const ops = try a.dupe(manufacture.Operation, plan.operations);
    const ts = try a.dupe(manufacture.Target, ops[0].targets);
    for (ts) |*t| if (std.mem.eql(u8, t.layer, "Plate")) {
        t.colour = .{ .name = "grey", .color = .{ .r = 0x80, .g = 0x80, .b = 0x80 } };
    };
    ops[0].targets = ts;
    next.operations = ops;
    try h.do(m, .setPlan, .{ plan.id, next });
    var labels: layout.Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var placed = try layout.solve(testing.allocator, m, plate, &labels);
    defer placed.deinit();
    const steps = (try layout.fab.plan(a, m, plate, &placed, &.{})).steps;
    var grey = false;
    for (steps) |st| switch (st.op) {
        .add => |c| if (std.mem.eql(u8, c.name, "grey")) {
            grey = true;
        },
        .subtract => {},
    };
    try testing.expect(grey);
    try testing.expectEqual(0, (try manufacture.warnings(a, m, m.activePlan().?.*)).len);
    // Purple: not a filament this material comes in.
    for (ts) |*t| if (std.mem.eql(u8, t.layer, "Plate")) {
        t.colour = .{ .name = "purple", .color = .{ .r = 0x80, .g = 0x20, .b = 0x80 } };
    };
    try h.do(m, .setPlan, .{ plan.id, next });
    const w = try manufacture.warnings(a, m, m.activePlan().?.*);
    try testing.expectEqual(1, w.len);
    try testing.expectEqual(.colour_unavailable, w[0].kind);
    // Undone twice: black again.
    _ = try h.undo(m);
    _ = try h.undo(m);
    try testing.expectEqualStrings("black", m.planColour(plate, "Plate").?.name);
}

test "an aluminium plate waterjet cut, then engraved: unsuited and doubtful orders flagged, never refused" {
    var o = try open(@embedFile("hp15c.graven"));
    defer close(&o);
    const m = &o.model;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plate_id = m.panels.items[try panelNamed(m, "HP-15C plate")].id;
    const alu = try m.addMaterial(manufacture.libraryMaterial("Aluminium 5052, black anodised").?);
    const jet = try m.addProcess(layout.model.process.builtin("Generic waterjet").?);
    const laser = try m.addProcess(layout.model.process.builtin("Generic CO2 laser cutter").?);
    const engraver = try m.addProcess(layout.model.process.builtin("Generic laser engraver").?);
    const bare: manufacture.Finish = .{ .name = "bare aluminium", .color = .{ .r = 0xc8, .g = 0xcc, .b = 0xd0 } };
    const id = try m.addPlan(.{
        .name = "Production",
        .parts = &.{.{ .panel = plate_id, .material = alu }},
        .operations = &.{
            .{ .name = "Cut", .process = jet, .targets = &.{ .{ .panel = plate_id, .layer = "Plate" }, .{ .panel = plate_id, .layer = "Key holes" } } },
            .{ .name = "Engrave", .process = engraver, .targets = &.{.{ .panel = plate_id, .layer = "Gold legends", .colour = bare }} },
            .{ .name = "Trim", .process = laser, .targets = &.{.{ .panel = plate_id, .layer = "Plate" }} },
        },
    });
    const pl = m.plans.items[m.planIndex(id).?];
    const w = try manufacture.warnings(a, m, pl);
    var after_cut = false;
    var unsuited = false;
    for (w) |x| switch (x.kind) {
        .mark_after_cut => after_cut = true,
        .unsuited => unsuited = x.operation.? == 2,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(after_cut and unsuited);
    // The first plan stays the active one; a process or material in use
    // cannot be removed.
    try testing.expect(m.active_plan != id);
    try testing.expectError(error.ProcessInUse, m.removeProcess(jet));
    try testing.expectError(error.MaterialInUse, m.removeMaterial(alu));
    try m.removePlan(id);
    try m.removeProcess(jet);
    try m.removeMaterial(alu);
}

test "plans and materials are saved and read back as they were, not upgraded again" {
    const gpa = testing.allocator;
    var o = try open(@embedFile("hp15c.graven"));
    defer close(&o);
    const m = &o.model;
    const bytes = try layout.native.encode(gpa, m);
    defer gpa.free(bytes);
    var back = try layout.native.decode(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(1, back.plans.items.len);
    try testing.expectEqual(1, back.materials.items.len);
    try testing.expectEqual(m.active_plan, back.active_plan);
    try testing.expectEqualStrings(m.plans.items[0].operations[0].targets[2].layer, back.plans.items[0].operations[0].targets[2].layer);
}

test "an operation checked on its own: the plate waterjet cut, its outline and holes only, a kerf path round each" {
    var o = try open(@embedFile("hp15c.graven"));
    defer close(&o);
    const m = &o.model;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plate = try panelNamed(m, "HP-15C plate");
    const id = m.panels.items[plate].id;
    var labels: layout.Labels = .init(testing.allocator, &.{});
    defer labels.deinit();
    var placed = try layout.solve(testing.allocator, m, plate, &labels);
    defer placed.deinit();
    const jet = layout.model.process.builtin("Generic waterjet").?;
    const r = try layout.check.runWith(a, m, plate, &placed, &.{}, null, .{
        .profile = jet,
        .targets = &.{ .{ .panel = id, .layer = "Plate" }, .{ .panel = id, .layer = "Key holes" } },
    });
    // One cut round the plate, one inside each of its 39 holes, a kerf wide.
    try testing.expectEqual(40, r.paths.len);
    for (r.paths) |p| {
        try testing.expectEqual(0.9, p.width);
        try testing.expectEqualStrings("kerf", p.colour.name);
    }
    // The plate's outline cut outside it: its path's box is half a kerf
    // bigger all round.
    var widest: f64 = 0;
    for (r.paths) |p| {
        var b = layout.geom.Box.empty;
        for (p.points) |q| b = b.addPoint(q);
        widest = @max(widest, b.width());
    }
    try testing.expectApproxEqAbs(128 + 0.9, widest, 0.01);
    // Only cutting: no depths judged, no colours counted.
    for (r.findings) |f| try testing.expect(f.kind != .depth and f.kind != .colours);
}

test "the keyboard as six tracks, one a row, threaded in its flow, lays out and exports exactly the same" {
    const gpa = testing.allocator;
    var o = try open(@embedFile("pc-keyboard.graven"));
    defer close(&o);
    const m = &o.model;
    const p = try panelNamed(m, "PC keyboard (ANSI 104)");
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var a = try layout.solve(gpa, m, p, &labels);
    defer a.deinit();
    const svg_a = try layout.output.panelSvg(gpa, &a, &.{}, .{});
    defer gpa.free(svg_a);

    // Six tracks where its rows were, each one row thick, the first
    // holding the flow and the rest following it: the region split, as
    // the GUI's "Make tracks of its rows" does, through the history.
    var six = try open(@embedFile("pc-keyboard.graven"));
    defer close(&six);
    const s = &six.model;
    try testing.expectEqual(6, a.tracks.len);
    var origins: [6]layout.geom.Point = undefined;
    for (a.tracks, &origins) |t, *q| q.* = .{ .x = t.box.x0, .y = t.box.y1 };
    try testing.expectEqual(6, try six.history.do(s, .splitIntoTracks, .{ p, 0, &origins }));
    try testing.expectEqualStrings("keys1", s.panels.items[p].regions.items[0].name);
    try testing.expectEqualStrings("keys6", s.panels.items[p].regions.items[5].name);
    const regions = s.panels.items[p].regions.items;
    try testing.expectEqual(6, regions.len);
    for (regions) |r| try testing.expectEqual(layout.model.TileRegion.Kind.track, r.kind);
    var labels2: layout.Labels = .init(gpa, &.{});
    defer labels2.deinit();
    var b = try layout.solve(gpa, s, p, &labels2);
    defer b.deinit();
    try testing.expectEqual(a.tiles.len, b.tiles.len);
    // A row a track: each segment in a track of its own.
    try testing.expectEqual(6, b.tracks.len);
    for (b.tracks, 0..) |t, k| {
        try testing.expectEqual(k, t.member);
        try testing.expectEqual(0, t.local);
    }
    for (b.issues) |i| try testing.expect(i.kind != .row_overflow and i.kind != .tile_size and i.kind != .unsupported_direction and i.kind != .past_soft_area);
    const svg_b = try layout.output.panelSvg(gpa, &b, &.{}, .{});
    defer gpa.free(svg_b);
    try testing.expectEqualStrings(svg_a, svg_b);
    // One flow still, and one undo puts the region back.
    try testing.expectEqual(m.flows.items.len, s.flows.items.len);
    try testing.expect(try six.history.undo(s));
    try testing.expectEqual(1, s.panels.items[p].regions.items.len);
    try testing.expectEqual(layout.model.TileRegion.Kind.region, s.panels.items[p].regions.items[0].kind);
}

test "a track at an angle placement cannot set yet is flagged, and placed as the nearest axis" {
    const gpa = testing.allocator;
    var o = try open(@embedFile("pc-keyboard.graven"));
    defer close(&o);
    const m = &o.model;
    const p = try panelNamed(m, "PC keyboard (ANSI 104)");
    m.panels.items[p].regions.items[0].direction = -15;
    var labels: layout.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var placed = try layout.solve(gpa, m, p, &labels);
    defer placed.deinit();
    try testing.expectEqual(104, placed.tiles.len);
    var flagged = false;
    for (placed.issues) |i| flagged = flagged or i.kind == .unsupported_direction;
    try testing.expect(flagged);
}
