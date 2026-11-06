//! graven command-line tool: batch runs, stage dumps and production jobs.
//! Applications own files and console output; the libraries never do.

const std = @import("std");
const layout = @import("graven_layout");
const engine = @import("graven_engine");

const usage =
    \\usage: graven svg <font file> <text> <cap height mm> <out.svg>
    \\         Renders one run of text in one face and writes its outlines as SVG.
    \\       graven parse <markup>
    \\         Parses label markup and prints its tree, or where it went wrong.
    \\       graven label [--advance] <upright font> <italic font|-> <cap height mm> <markup> <out.svg> [fallback font ...]
    \\         Renders label markup; with an italic font, letters default to italic.
    \\         Neighbours are placed by their ink unless --advance is given.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 6 and std.mem.eql(u8, args[1], "svg")) {
        return svg(init, args[2], args[3], args[4], args[5]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "parse")) {
        return parse(init, args[2]);
    }
    if (args.len >= 8 and std.mem.eql(u8, args[1], "label") and std.mem.eql(u8, args[2], "--advance")) {
        return label(init, args[3..], .advance);
    }
    if (args.len >= 7 and std.mem.eql(u8, args[1], "label")) {
        return label(init, args[2..], .ink);
    }
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

fn svg(init: std.process.Init, font_path: []const u8, text: []const u8, cap_arg: []const u8, out_path: []const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const cap = std.fmt.parseFloat(f64, cap_arg) catch {
        std.debug.print("cap height must be a number of mm, not {s}\n", .{cap_arg});
        std.process.exit(2);
    };

    const bytes = try cwd.readFileAlloc(io, font_path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const face = try engine.Face.init(gpa, bytes, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};

    var r = try engine.renderRun(gpa, &faces, 0, text, .{ .cap_height = cap });
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("warning: {s} at byte {d}\n", .{ @tagName(d.kind), d.offset });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const outlines = try r.outlines(arena.allocator(), &faces);
    const doc = try layout.output.svg(arena.allocator(), outlines, r.design.join(r.ink), .{});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = doc });
    std.debug.print("{s}: {d} glyphs, ink {d:.3} x {d:.3} mm\n", .{ out_path, r.items.len, r.ink.width(), r.ink.height() });
}

fn label(init: std.process.Init, args: []const [:0]const u8, contact: @FieldType(engine.style.Spec, "contact")) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cap = std.fmt.parseFloat(f64, args[2]) catch {
        std.debug.print("cap height must be a number of mm, not {s}\n", .{args[2]});
        std.process.exit(2);
    };
    const src = args[3];
    const out_path = args[4];

    // Faces: upright, then italic if given, then fallbacks.
    var faces: std.ArrayList(*engine.Face) = .empty;
    defer for (faces.items) |f| f.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(a, args[0]);
    const has_italic = !std.mem.eql(u8, args[1], "-");
    if (has_italic) try paths.append(a, args[1]);
    for (args[5..]) |fb| try paths.append(a, fb);
    for (paths.items) |path| {
        const bytes = try cwd.readFileAlloc(io, path, a, .limited(64 << 20));
        try faces.append(a, try engine.Face.init(gpa, bytes, 0));
    }
    var fallbacks: std.ArrayList(engine.render.FaceId) = .empty;
    const first_fallback: u32 = if (has_italic) 2 else 1;
    for (first_fallback..faces.items.len) |k| try fallbacks.append(a, @intCast(k));

    const ctx = try engine.style.Context.init(faces.items, .{
        .upright = 0,
        .italic = if (has_italic) 1 else null,
        .fallbacks = fallbacks.items,
        .cap_height = cap,
        .letters = if (has_italic) .italic else .upright,
        .contact = contact,
    });
    var diag: engine.markup.Diagnostic = undefined;
    var r = engine.renderLabel(gpa, &ctx, src, .{}, &diag) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("{s}\n{s} at byte {d}\n", .{ src, diag.kind.message(), diag.offset });
            std.process.exit(1);
        },
        else => return err,
    };
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("warning: {s} at byte {d}\n", .{ @tagName(d.kind), d.offset });

    const outlines = try r.outlines(a, faces.items);
    const doc = try layout.output.svg(a, outlines, r.design.join(r.ink), .{});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = doc });
    std.debug.print("{s}: {d} elements, script scale {d:.3}, raise {d:.3}, drop {d:.3}\n", .{
        out_path, r.elements.len, ctx.script_scale, ctx.sup_raise, ctx.sub_drop,
    });
}

fn parse(init: std.process.Init, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var diag: engine.markup.Diagnostic = undefined;
    const tree = engine.markup.parse(arena.allocator(), src, &diag) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("{s}\n{s}\n", .{ src, diag.kind.message() });
            std.debug.print("at byte {d}: {s}\u{25B8}{s}\n", .{ diag.offset, src[0..diag.offset], src[diag.offset..] });
            std.process.exit(1);
        },
        else => return err,
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try engine.markup.dump(&out.writer, tree.items);
    std.debug.print("{s}\n", .{out.written()});
}
