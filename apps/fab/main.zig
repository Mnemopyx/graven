//! graven-fab: parts as solids for manufacture, through OCCT. Built only
//! with the OCCT bridge (zig build fab -Docct-prebuilt, or -Docct=<prefix>).

const std = @import("std");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const samples = @import("graven_samples");
const c = @import("occt_shim");
const fab = @import("occt_fab");

const usage =
    \\usage: graven-fab [--check] hp15c <font> <plate.step> <keys.step>
    \\         The rough HP-15C keypad's plate and keys as colour-FDM solids: each part's
    \\         stack of layer operations built into one solid per colour, none overlapping,
    \\         written as STEP (one named, coloured solid per filament) with a report.
    \\         --check also runs OCCT's checker and measures the solids' volumes (slower).
    \\
;

var check_solids = false;

pub fn main(init: std.process.Init) !void {
    var args: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--check")) {
        check_solids = true;
        args = args[1..];
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "hp15c")) return hp15c(init, args[2], args[3], args[4]);
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

fn hp15c(init: std.process.Init, font_path: []const u8, plate_path: []const u8, keys_path: []const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, font_path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const face = try engine.Face.init(gpa, bytes, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};

    var m: layout.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const b = try samples.hp15c.build(&m, try samples.hp15c.addStyles(&m, &.{}), 0, .{ .x = 0, .y = 0 });

    var labels: layout.Labels = .init(gpa, &faces);
    defer labels.deinit();
    var failed = false;
    for ([_]struct { p: usize, path: []const u8 }{ .{ .p = b.plate, .path = plate_path }, .{ .p = b.keys, .path = keys_path } }) |part| {
        if (!try onePart(gpa, &m, part.p, part.path, &labels, &faces)) failed = true;
    }
    if (failed) std.process.exit(1);
}

/// Builds and writes one part; false when its solids are not sound.
fn onePart(gpa: std.mem.Allocator, m: *layout.Model, panel: usize, path: []const u8, labels: *layout.Labels, faces: []const *engine.Face) !bool {
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
    for (p.off_layers) |li| std.debug.print("  flag: {s}: depth not a whole number of {d} mm layers\n", .{ names[li], stack.layer_height });
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
