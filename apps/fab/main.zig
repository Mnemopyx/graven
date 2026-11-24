//! graven-fab: parts as solids for manufacture, through OCCT. Built only
//! with the OCCT bridge (zig build fab -Docct-prebuilt, or -Docct=<prefix>).

const std = @import("std");
const layout = @import("graven_layout");
const folders = @import("graven_fonts_folders");
const c = @import("occt_shim");
const fab = @import("occt_fab");

const usage =
    \\usage: graven-fab [--check] [--font <file>] [--panel <name>] <document> <out.step>
    \\         A document's panels (or the one named) as colour-FDM solids: each panel's
    \\         fabrication layers built into one solid per colour, none overlapping,
    \\         written as STEP (one named, coloured solid per filament) with a report;
    \\         with several panels, each to <out>-<panel name>.step.
    \\         Fonts as the GUI finds them: a fonts folder beside the document, then
    \\         $GRAVEN_FONTS or fonts/; --font sets every style in that one font file.
    \\         --check also runs OCCT's checker and measures the solids' volumes (slower).
    \\         The example: graven-fab examples/hp15c.graven hp15c.step
    \\
;

var check_solids = false;

pub fn main(init: std.process.Init) !void {
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    var font: ?[]const u8 = null;
    var panel: ?[]const u8 = null;
    var k: usize = 1;
    while (k < args.len and std.mem.startsWith(u8, args[k], "--")) : (k += 1) {
        if (std.mem.eql(u8, args[k], "--check")) {
            check_solids = true;
        } else if (std.mem.eql(u8, args[k], "--font") and k + 1 < args.len) {
            k += 1;
            font = args[k];
        } else if (std.mem.eql(u8, args[k], "--panel") and k + 1 < args.len) {
            k += 1;
            panel = args[k];
        } else break;
    }
    if (args.len - k == 2) return document(init, args[k], args[k + 1], font, panel);
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

fn document(init: std.process.Init, doc_path: []const u8, out_path: []const u8, font: ?[]const u8, only: ?[]const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, doc_path, gpa, .limited(1 << 30)) catch |err| {
        std.debug.print("{s}: cannot be read ({s})\n", .{ doc_path, @errorName(err) });
        std.process.exit(1);
    };
    defer gpa.free(bytes);
    var opened = layout.history.openFile(gpa, bytes) catch |err| {
        std.debug.print("{s}: not a Graven document ({s})\n", .{ doc_path, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        opened.model.deinit();
        opened.history.deinit();
    }
    const m = &opened.model;

    // The fonts: one file for every style, or the document's folders.
    var fonts: folders.Folders = .init(gpa);
    defer fonts.deinit(gpa);
    if (font) |f| {
        try fonts.addFile(gpa, io, f);
        for (m.styles.items) |st| for (st.faces.items) |sf| try m.setStyleFace(st.id, sf.role, fonts.names.items[0]);
    } else for (try folders.dirsFor(arena, doc_path)) |d| try fonts.addDir(gpa, io, d);
    if (fonts.faces.items.len == 0) {
        std.debug.print("no fonts: none beside the document or in fonts/ (scripts/fetch-fonts.py), and no --font\n", .{});
        std.process.exit(1);
    }
    var res = try layout.fonts.resolve(gpa, m, fonts.catalog(), fonts.faces.items[0]);
    defer res.deinit();
    for (res.substitutions.items) |sub| std.debug.print("{s} {s}: not found{s}\n", .{ sub.wanted.family, sub.wanted.style, if (sub.got != null) ", another style used" else ", left out" });
    const faces = res.faces.items;
    var labels: layout.Labels = .init(gpa, faces);
    defer labels.deinit();
    try labels.syncResolved(&res);

    var chosen: std.ArrayList(usize) = .empty;
    for (m.panels.items, 0..) |p, pi| {
        if (p.fab.layers.len == 0) continue;
        if (only) |want| if (!std.mem.eql(u8, p.name, want)) continue;
        try chosen.append(arena, pi);
    }
    if (chosen.items.len == 0) {
        std.debug.print("{s}: no panel with fabrication layers{s}{s}\n", .{ doc_path, if (only != null) " named " else "", only orelse "" });
        std.process.exit(1);
    }
    const ext = std.fs.path.extension(out_path);
    const stem = out_path[0 .. out_path.len - ext.len];
    var failed = false;
    for (chosen.items) |pi| {
        const path = if (chosen.items.len == 1) out_path else try std.fmt.allocPrint(arena, "{s}-{s}{s}", .{ stem, m.panels.items[pi].name, if (ext.len > 0) ext else ".step" });
        if (!try onePart(gpa, m, pi, path, &labels, faces)) failed = true;
    }
    if (failed) std.process.exit(1);
}

/// Builds and writes one part; false when its solids are not sound.
fn onePart(gpa: std.mem.Allocator, m: *layout.Model, panel: usize, path: []const u8, labels: *layout.Labels, faces: []const *layout.Face) !bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var placed = try layout.solve(gpa, m, panel, labels);
    defer placed.deinit();
    const p = try layout.fab.plan(a, m, panel, &placed, faces);
    const stack = m.panels.items[panel].fab;
    const names = try a.alloc([]const u8, stack.layers.len);
    for (stack.layers, names) |l, *n| n.* = l.name;
    var clock = fab.Clock.start();
    var total = fab.Clock.start();

    const name = m.panels.items[panel].name;
    std.debug.print("{s}: {d} layers, {d} steps\n", .{ name, stack.layers.len, p.steps.len });
    const layer_h: f64 = if (m.processOf(panel)) |pr| pr.limits().layer orelse 0 else 0;
    for (p.off_layers) |li| std.debug.print("  flag: {s}: depth not a whole number of {d} mm layers\n", .{ names[li], layer_h });
    const slabs = try layout.fab.slabs(a, p.steps);
    std.debug.print("  2D: {d} slabs in {d:.0} ms\n", .{ slabs.len, clock.lap() });
    const r = fab.build(gpa, a, slabs, .{ .trace = true, .check = check_solids }) catch |err| {
        std.debug.print("  OCCT: {s}\n", .{fab.lastError()});
        return err;
    };
    defer r.deinit(gpa);
    for (r.skipped) |s| std.debug.print("  skipped: {s}\n", .{s});
    var sound = true;
    for (r.parts) |part| {
        std.debug.print("  {s}: {d:.3} mm³ (from the 2D regions {d:.3}){s}\n", .{ part.colour.name, part.volume, part.expected, if (part.valid) "" else ", NOT VALID" });
        if (!part.valid or @abs(part.volume - part.expected) > 1e-6 * @max(1, part.expected)) sound = false;
    }

    var doc: ?*c.os_doc = null;
    if (c.os_doc_new(&doc) != c.OS_OK) return error.Occt;
    defer c.os_doc_free(doc);
    try r.addTo(doc.?, name, a);
    const z = try a.dupeSentinel(u8, path, 0);
    _ = clock.lap();
    if (c.os_doc_write_step(doc.?, z.ptr) != c.OS_OK) {
        std.debug.print("  writing {s}: {s}\n", .{ path, fab.lastError() });
        return error.Occt;
    }
    std.debug.print("  wrote {s} in {d:.0} ms ({d:.0} ms in all)\n", .{ path, clock.lap(), total.lap() });
    return sound;
}
