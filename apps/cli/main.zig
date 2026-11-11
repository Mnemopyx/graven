//! graven command-line tool: batch runs, stage dumps and production jobs.
//! Applications own files and console output; the libraries never do.

const std = @import("std");
const builtin = @import("builtin");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const samples = @import("graven_samples");

const usage =
    \\usage: graven svg <font file> <text> <cap height mm> <out.svg>
    \\         Renders one run of text in one face and writes its outlines as SVG.
    \\       graven parse <markup>
    \\         Parses label markup and prints its tree, or where it went wrong.
    \\       graven label [--advance] [--width mm] [--centre] [--bold font] [--bold-italic font] <upright font> <italic font|-> <cap height mm> <markup> <out.svg> [fallback font ...]
    \\         Renders label markup; with an italic font, letters default to italic.
    \\         Neighbours are placed by their ink unless --advance is given. --width gives a
    \\         hard box that wide, so lines wrap; --centre centres each line on the anchor.
    \\         --bold and --bold-italic give the family's bolds, for \\textbf and \\mathbf.
    \\       graven keyboard <font> <out.svg>
    \\         Lays out the sample PC keyboard in one font and writes it as SVG.
    \\       graven dump [--log] <document>
    \\         Prints a document's model as text (for reading, or as git's text converter);
    \\         --log adds its history: the file's segments and every logged step.
    \\       graven compact <document>
    \\         Folds a document's history into its model and drops it: a smaller file, with
    \\         no undo history, for example before a commit or before sharing it.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 6 and std.mem.eql(u8, args[1], "svg")) {
        return svg(init, args[2], args[3], args[4], args[5]);
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "keyboard")) {
        return keyboard(init, args[2], args[3]);
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "dump")) {
        if (args.len == 3) return dump(init, args[2], false);
        if (args.len == 4 and std.mem.eql(u8, args[2], "--log")) return dump(init, args[3], true);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "compact")) {
        return compact(init, args[2]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "parse")) {
        return parse(init, args[2]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "label")) {
        var flags: LabelFlags = .{};
        var k: usize = 2;
        while (k < args.len and std.mem.startsWith(u8, args[k], "--")) : (k += 1) {
            if (std.mem.eql(u8, args[k], "--advance")) {
                flags.contact = .advance;
            } else if (std.mem.eql(u8, args[k], "--centre")) {
                flags.centre = true;
            } else if (std.mem.eql(u8, args[k], "--bold") and k + 1 < args.len) {
                k += 1;
                flags.bold = args[k];
            } else if (std.mem.eql(u8, args[k], "--bold-italic") and k + 1 < args.len) {
                k += 1;
                flags.bold_italic = args[k];
            } else if (std.mem.eql(u8, args[k], "--width") and k + 1 < args.len) {
                k += 1;
                flags.width = std.fmt.parseFloat(f64, args[k]) catch null;
            } else break;
        }
        if (args.len - k >= 5) return label(init, args[k..], flags);
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

fn keyboard(init: std.process.Init, font_path: []const u8, out_path: []const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, font_path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const face = try engine.Face.init(gpa, bytes, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};

    var m: layout.Model = .init(gpa);
    defer m.deinit();
    const main_style = try m.addStyle("legend", .{ .upright = 0, .cap_height = 2.6 });
    const small = try m.addStyle("legend words", .{ .upright = 0, .cap_height = 1.6 });
    const p = try samples.pc_keyboard.build(gpa, &m, .{ .main = main_style, .small = small });

    var labels: layout.Labels = .init(gpa, &faces);
    defer labels.deinit();
    const t0: std.Io.Timestamp = .now(io, .awake);
    var placed = try layout.solve(gpa, &m, p, &labels);
    defer placed.deinit();
    const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
    for (placed.issues) |i| {
        const name = if (i.tile) |t| m.tileConst(t).designator else "-";
        std.debug.print("{s}: {s}\n", .{ name, @tagName(i.kind) });
    }
    const doc = try layout.output.panelSvg(gpa, &placed, &faces, .{});
    defer gpa.free(doc);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = doc });
    std.debug.print("{s}: {d} tiles, {d} labels ({d} renders) in {d:.1} ms\n", .{ out_path, placed.tiles.len, placed.labels.len, labels.cache.count(), ms });
}

const LabelFlags = struct {
    contact: @FieldType(engine.style.Spec, "contact") = .ink,
    width: ?f64 = null,
    centre: bool = false,
    bold: ?[]const u8 = null,
    bold_italic: ?[]const u8 = null,
};

fn label(init: std.process.Init, args: []const [:0]const u8, flags: LabelFlags) !void {
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

    // Faces: upright, then italic if given, then the bolds, then fallbacks.
    var faces: std.ArrayList(*engine.Face) = .empty;
    defer for (faces.items) |f| f.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(a, args[0]);
    const has_italic = !std.mem.eql(u8, args[1], "-");
    if (has_italic) try paths.append(a, args[1]);
    const bold_at: u32 = @intCast(paths.items.len);
    if (flags.bold) |p| try paths.append(a, p);
    const bold_italic_at: u32 = @intCast(paths.items.len);
    if (flags.bold_italic) |p| try paths.append(a, p);
    const first_fallback: u32 = @intCast(paths.items.len);
    for (args[5..]) |fb| try paths.append(a, fb);
    for (paths.items) |path| {
        const bytes = try cwd.readFileAlloc(io, path, a, .limited(64 << 20));
        try faces.append(a, try engine.Face.init(gpa, bytes, 0));
    }
    var members: std.ArrayList(engine.style.Member) = .empty;
    for (first_fallback..faces.items.len) |k| try members.append(a, .{ .upright = @intCast(k) });

    const ctx = try engine.style.Context.init(faces.items, .{
        .upright = 0,
        .italic = if (has_italic) 1 else null,
        .bold = if (flags.bold != null) bold_at else null,
        .bold_italic = if (flags.bold_italic != null) bold_italic_at else null,
        .members = members.items,
        .cap_height = cap,
        .letters = if (has_italic) .italic else .upright,
        .contact = flags.contact,
    });
    var diag: engine.markup.Diagnostic = undefined;
    const opts: engine.label.Options = .{
        .anchor = if (flags.centre) engine.Anchor.centre else .start,
        .hard_box = if (flags.width) |w| .{ .x0 = if (flags.centre) -w / 2 else 0, .y0 = -1e6, .x1 = if (flags.centre) w / 2 else w, .y1 = 1e6 } else null,
    };
    var r = engine.renderLabel(gpa, &ctx, src, opts, &diag) catch |err| switch (err) {
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

/// Opens document `path`, or says why it cannot and exits.
fn openDocument(init: std.process.Init, path: []const u8) !struct { bytes: []u8, opened: layout.history.Opened } {
    const gpa = init.gpa;
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 30)) catch |err| {
        std.debug.print("{s}: cannot be read ({s})\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    const opened = layout.history.openFile(gpa, bytes) catch |err| {
        std.debug.print("{s}: {s}\n", .{ path, switch (err) {
            error.BadFile, error.NoModel => "not a Graven document",
            error.TooNew => "from a newer Graven",
            error.BadChecksum, error.Truncated => "damaged where its model is stored",
            else => @errorName(err),
        } });
        std.process.exit(1);
    };
    if (opened.damaged) std.debug.print("{s}: the end of the file is damaged; what it held is left out\n", .{path});
    return .{ .bytes = bytes, .opened = opened };
}

fn printWriter(w: *std.Io.Writer, id: [16]u8) !void {
    for (id[0..4]) |b| try w.print("{x:0>2}", .{b});
}

fn dump(init: std.process.Init, path: []const u8, with_log: bool) !void {
    const gpa = init.gpa;
    var doc = try openDocument(init, path);
    defer gpa.free(doc.bytes);
    defer doc.opened.model.deinit();
    defer doc.opened.history.deinit();
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    // The document as it opens, unsaved steps included.
    try layout.native.dump(w, layout.Model, doc.opened.model);
    if (with_log) {
        const h = &doc.opened.history;
        try w.print("\nhistory: {d} steps after the checkpoint, the save at entry {d} of {d}\n", .{ h.stepCount(), h.saved.?.len, h.log.items.len });
        // The segments, as the file holds them.
        var i: usize = layout.native.magic.len;
        while (i < doc.bytes.len) {
            const b = layout.native.readBlock(doc.bytes, i) catch break;
            if (std.mem.eql(u8, &b.kind, &layout.history.segment_block) and b.version >= 2) {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                if (layout.native.decodeValue(arena.allocator(), layout.history.Segment, b.payload)) |seg| {
                    try w.writeAll("segment: writer ");
                    try printWriter(w, seg.writer);
                    try w.print(" on \"{s}\" at {d} ({s}): entries {d} to {d}\n", .{ seg.device, seg.time, seg.tool, seg.first, seg.first + seg.entries.len });
                } else |_| try w.writeAll("segment: unreadable\n");
            }
            i = b.end;
        }
        for (h.log.items, 0..) |e, k| {
            try w.print("entry {d}, step {d}:", .{ k, e.step });
            try layout.native.dump(w, layout.history.Op, e.op);
        }
        if (doc.opened.unsaved) |u| try w.print("unsaved: {d} entries after the save, by a run on \"{s}\"\n", .{ u.entries, u.device });
    }
    try w.flush();
}

fn deviceName(buf: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    if (builtin.os.tag == .windows) return "";
    return std.posix.gethostname(buf) catch "";
}

fn compact(init: std.process.Init, path: []const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    var doc = try openDocument(init, path);
    defer gpa.free(doc.bytes);
    defer doc.opened.model.deinit();
    defer doc.opened.history.deinit();
    const h = &doc.opened.history;
    if (doc.opened.unsaved) |u| std.debug.print("{s}: {d} unsaved entries (by a run on \"{s}\") are kept and folded in\n", .{ path, u.entries, u.device });
    const steps = h.stepCount();
    try h.compact();
    var random: [16]u8 = undefined;
    io.random(&random);
    var host: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const who: layout.history.Writer = .{ .id = layout.history.writerId(random), .device = deviceName(&host), .tool = layout.history.tool_version };
    const now = std.Io.Clock.real.now(io).toSeconds();
    const bytes = try layout.history.fileBytes(h, gpa, who, now);
    defer gpa.free(bytes);
    // Written beside it, then renamed over it: never half a file.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.compacting", .{path});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try cwd.rename(tmp, cwd, path, io);
    std.debug.print("{s}: {d} steps of history folded in; {d} bytes, was {d}\n", .{ path, steps, bytes.len, doc.bytes.len });
}
