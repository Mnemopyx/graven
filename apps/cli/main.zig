//! graven command-line tool: batch runs, stage dumps and production jobs.
//! Applications own files and console output; the libraries never do.

const std = @import("std");
const builtin = @import("builtin");
const layout = @import("graven_layout");
const fontsearch = @import("graven_fontsearch");
const richtext = @import("graven_richtext");
const glyphic = @import("graven_glyphic");
const folders = @import("graven_fonts_folders");
const local_fonts = @import("graven_fonts_local");

const usage =
    \\usage: graven svg <font file> <text> <cap height mm> <out.svg>
    \\         Renders one run of text in one face and writes its outlines as SVG.
    \\       graven msdf <font file> <text> <texels per cap height> <out.pgm>
    \\         Makes each glyph's multi-channel signed distance field and draws it back
    \\         at several sizes, plain and grown, into a greyscale sheet; reports each
    \\         field's time and its drawn area against the outline's.
    \\       graven parse <legend>
    \\         Parses a legend (text, math between dollars) and prints its objects.
    \\       graven rtf <file.rtf>
    \\         Reads an RTF file as an import would: each paragraph's settings and its
    \\         text as Graven markup, then what was left out.
    \\       graven label [--width mm] [--centre] [--bold font] [--bold-italic font] <upright font> <italic font|-> <cap height mm> <legend> <out.svg> [fallback font ...]
    \\         Sets a legend with engine v2; with an italic font, math's variables are italic.
    \\         --width breaks it into lines that wide; --centre centres each line.
    \\         --bold and --bold-italic give the family's bolds, for \\textbf and \\mathbf.
    \\       graven v2 <text font> <math font> <out.svg> [italic font]
    \\         Engine v2: sets the Leibniz series (built as objects) on three grounds: one
    \\         long row in display style, narrow rows it must break across, and a dial.
    \\       graven export [--font <file>] [--panel <name>] [--parts colours|bands] [--bed bottom|top] <document> <out.svg|out.3mf>
    \\         Writes a document's panels (or the one named) as SVG, or as 3MF from their
    \\         fabrication layers; with several panels, each to <out>-<panel name>.<ext>.
    \\         Fonts are found as the GUI finds them: a fonts folder beside the document,
    \\         then $GRAVEN_FONTS or fonts/, then the installed fonts. --font sets every
    \\         style in that one font file instead. For 3MF, --parts colours (the default)
    \\         gives one part per colour, bands one per colour and height band; --bed
    \\         bottom (the default) stands each part on its lowest face, top on its top.
    \\         The examples: graven export examples/hp15c.graven hp15c.3mf
    \\       graven check [--font f] [--panel name] [--svg out.svg] <document>
    \\         Checks each panel made with a process profile against its limits (stroke,
    \\         gap, cap height, depths, colours, size): pass, marginal or fail, and where.
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
    if (args.len == 6 and std.mem.eql(u8, args[1], "msdf")) return msdfSheet(init, args[2], args[3], args[4], args[5]);
    if (args.len == 6 and std.mem.eql(u8, args[1], "svg")) {
        return svg(init, args[2], args[3], args[4], args[5]);
    }
    if (args.len >= 3 and (std.mem.eql(u8, args[1], "export") or std.mem.eql(u8, args[1], "check"))) {
        const checking = std.mem.eql(u8, args[1], "check");
        var opts: ExportOptions = .{ .check = checking };
        var k: usize = 2;
        while (k + 1 < args.len and std.mem.startsWith(u8, args[k], "--")) : (k += 2) {
            if (std.mem.eql(u8, args[k], "--font")) {
                opts.font = args[k + 1];
            } else if (checking and std.mem.eql(u8, args[k], "--svg")) {
                opts.svg = args[k + 1];
            } else if (std.mem.eql(u8, args[k], "--panel")) {
                opts.panel = args[k + 1];
            } else if (std.mem.eql(u8, args[k], "--parts")) {
                opts.threemf.grouping = std.meta.stringToEnum(layout.threemf.Grouping, args[k + 1]) orelse break;
            } else if (std.mem.eql(u8, args[k], "--bed")) {
                opts.threemf.bed = std.meta.stringToEnum(layout.threemf.Bed, args[k + 1]) orelse break;
            } else break;
        }
        if (!checking and args.len - k == 2) return exportDocument(init, args[k], args[k + 1], opts);
        if (checking and args.len - k == 1) return exportDocument(init, args[k], "", opts);
    }
    if ((args.len == 5 or args.len == 6) and std.mem.eql(u8, args[1], "v2")) {
        return v2(init, args[2], args[3], args[4], if (args.len == 6) args[5] else null);
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "dump")) {
        if (args.len == 3) return dump(init, args[2], false);
        if (args.len == 4 and std.mem.eql(u8, args[2], "--log")) return dump(init, args[3], true);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "compact")) {
        return compact(init, args[2]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "rtf")) {
        return rtfShow(init, args[2]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "parse")) {
        return parse(init, args[2]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "label")) {
        var flags: LabelFlags = .{};
        var k: usize = 2;
        while (k < args.len and std.mem.startsWith(u8, args[k], "--")) : (k += 1) {
            if (std.mem.eql(u8, args[k], "--centre")) {
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
    const face = try layout.Face.init(gpa, bytes, 0);
    defer face.deinit();
    const faces = [_]*layout.Face{face};

    var r = try layout.render.run(gpa, &faces, 0, text, cap);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("warning: {s} at byte {d}\n", .{ @tagName(d.kind), d.offset });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const outlines = try r.outlines(arena.allocator(), &faces);
    const doc = try layout.output.svg(arena.allocator(), outlines, r.design.join(r.ink), .{});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = doc });
    std.debug.print("{s}: {d} glyphs, ink {d:.3} x {d:.3} mm\n", .{ out_path, r.items.len, r.ink.width(), r.ink.height() });
}

/// The HP-15C keypad as v1 sets it, and with each legend parsed (LaTeX,
/// as a legend) and set by engine v2 where v1 set it: on one row along
/// its box, at its style's cap height, aligned as its track is.
/// Engine v2's sample: the Leibniz series set on three grounds.
fn v2(init: std.process.Init, text_path: []const u8, math_path: []const u8, out_path: []const u8, italic_path: ?[]const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The style context this app configures: the faces given, italic
    // variables, display style.
    var g = glyphic.Engine.init(gpa);
    defer g.deinit();
    const style = try g.addStyle("sample", .none);
    var loaded: std.ArrayList(*layout.Face) = .empty;
    defer for (loaded.items) |f| f.deinit();
    for ([_]?[]const u8{ text_path, math_path, italic_path }, [_][]const u8{ "text", "math", "italic" }) |path, name| {
        const p = path orelse continue;
        const bytes = try cwd.readFileAlloc(io, p, a, .limited(64 << 20));
        const f = try layout.Face.init(gpa, bytes, 0);
        try loaded.append(a, f);
        try g.setFace(style, name, f);
    }
    try g.setFor(style, .{ .kind = .variable }, .shape, glyphic.param.of(glyphic.param.Shape.italic));
    try g.set(style, .math_style, glyphic.param.of(glyphic.param.MathStyle.display));

    var e = try glyphic.Expr.init(gpa);
    defer e.deinit();
    _ = try glyphic.samples.leibniz(&e);
    try g.apply(&e, e.root, style);
    const r = glyphic.Resolver.init(&g, &e, &.{});

    var outs: std.ArrayList(layout.geom.Outline) = .empty;
    var box: layout.geom.Box = .empty;
    // One long row; narrow rows, broken; a dial.
    var long: glyphic.ground.Rows = .{ .a = a, .origin = .{ .x = 0, .y = 0 }, .length = 160, .pitch = 14, .count = 1, .cap = 4 };
    var narrow: glyphic.ground.Rows = .{ .a = a, .origin = .{ .x = 0, .y = -24 }, .length = 75, .pitch = 16, .count = 3, .cap = 4 };
    var dial: glyphic.ground.Dial = .{ .centre = .{ .x = 120, .y = -110 }, .radius = 55, .start = std.math.pi * 0.95, .sweep = std.math.pi * 0.9, .pitch = 12, .count = 2, .cap = 3 };
    const grounds = [_]glyphic.ground.Ground{ long.ground(), narrow.ground(), dial.ground() };
    const names = [_][]const u8{ "row", "narrow rows", "dial" };
    for (grounds, names) |gr, name| {
        const s = try glyphic.setting.set(a, &r, gr, .{});
        const o = try glyphic.setting.outlines(a, s.items, 0.005);
        for (o) |ol| box = box.join(ol.bounds());
        try outs.appendSlice(a, o);
        std.debug.print("{s}: {d} lines{s}\n", .{ name, s.lines.len, if (s.overflow) ", overflow" else "" });
        for (s.missing) |m| std.debug.print("  missing U+{X:0>4}\n", .{m.cp});
    }
    const doc = try layout.output.svg(a, outs.items, box, .{ .margin = 4 });
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = doc });
    std.debug.print("{s}: {d} outlines, {d:.1} x {d:.1} mm\n", .{ out_path, outs.items.len, box.width(), box.height() });
}

/// Each glyph of `text` as an MSDF `texels` texels per cap height, drawn back
/// at several sizes, plain and grown, into a greyscale PGM sheet; with each
/// field's time and its drawn area against the outline's.
fn msdfSheet(init: std.process.Init, font_path: []const u8, text: []const u8, texels_arg: []const u8, out_path: []const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const texels = std.fmt.parseFloat(f64, texels_arg) catch {
        std.debug.print("texels per cap height must be a number, not {s}\n", .{texels_arg});
        std.process.exit(2);
    };
    const geom = layout.geom;
    const bytes = try cwd.readFileAlloc(io, font_path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const face = try layout.Face.init(gpa, bytes, 0);
    defer face.deinit();
    const cap = (try face.capHeight()) orelse @as(f64, @floatFromInt(face.upem)) * 0.7;
    const faces = [_]*layout.Face{face};
    var r = try layout.render.run(gpa, &faces, 0, text, cap);
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Sizes as cap height in pixels; each drawn plain, then grown by 4 % of
    // the cap height.
    const sizes = [_]f64{ 8, 12, 16, 24, 48, 120 };
    const cell: usize = 160;
    const W: usize = cell * sizes.len;
    const H: usize = cell * 2 * r.items.len;
    const sheet = try a.alloc(u8, W * H);
    @memset(sheet, 255);
    var total_ns: u64 = 0;
    for (r.items, 0..) |item, gi| {
        const g = item.glyph;
        const o = try face.outline(g.gid);
        const t0 = std.Io.Clock.awake.now(io);
        const f = try geom.msdf.generate(a, o, .{ .scale = texels / cap, .range = 4 * texels / 32 });
        const t1 = std.Io.Clock.awake.now(io);
        const ns: u64 = @intCast(t0.durationTo(t1).toNanoseconds());
        total_ns += ns;
        const b = o.bounds();
        for (0..2) |grown| for (sizes, 0..) |size, si| {
            const px = cap / size; // font units per pixel
            const grow = if (grown == 1) 0.04 * cap else 0;
            const n: u32 = @intCast(@min(cell - 4, @as(usize, @intFromFloat(@ceil((@max(b.width(), b.height()) + 2 * grow) / px + 2)))));
            const m: geom.Affine = .{ .a = px, .d = px, .e = b.x0 - grow - px, .f = b.y0 - grow - px };
            // GRAVEN_MSDF_EXACT set: the exact outline (grown by geom.grow),
            // supersampled 4 x 4, in place of the field, to compare.
            const cov = if (std.c.getenv("GRAVEN_MSDF_EXACT") != null) try exactCoverage(a, o, n, m, grow) else try f.rasterize(a, n, n, m, px, grow);
            const ox = si * cell + 2;
            const oy = (gi * 2 + grown) * cell + 2;
            for (0..n) |j| for (0..n) |i| {
                sheet[(oy + (n - 1 - j)) * W + ox + i] = 255 - cov[j * n + i];
            };
            if (si == sizes.len - 1 and grown == 0) {
                var s: f64 = 0;
                for (cov) |c| s += @as(f64, @floatFromInt(c)) / 255;
                const area = s * px * px;
                std.debug.print("glyph {d}: {d}x{d} field in {d:.2} ms; area {d:.1}% of the outline's\n", .{ g.gid, f.w, f.h, @as(f64, @floatFromInt(ns)) / 1e6, 100 * area / @abs(o.signedArea()) });
            }
        };
    }
    std.debug.print("{d} fields in {d:.2} ms\n", .{ r.items.len, @as(f64, @floatFromInt(total_ns)) / 1e6 });
    const header = try std.fmt.allocPrint(a, "P5\n{d} {d}\n255\n", .{ W, H });
    const file = try a.alloc(u8, header.len + sheet.len);
    @memcpy(file[0..header.len], header);
    @memcpy(file[header.len..], sheet);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = file });
}

/// Coverage of outline `o` grown by `grow`, an `n` × `n` raster whose pixel
/// (i, j) maps by `m`, from 4 x 4 samples a pixel (even-odd on the grown
/// outline's simple loops).
fn exactCoverage(a: std.mem.Allocator, o: layout.geom.Outline, n: u32, m: layout.geom.Affine, grow: f64) ![]u8 {
    const geom = layout.geom;
    const g = try geom.grow.grow(a, o, grow, @max(grow, 1) / 20);
    var loops: std.ArrayList([]geom.Point) = .empty;
    for (g.contours) |c| {
        const pts = try a.alloc(geom.Point, c.segments.len);
        for (c.segments, pts) |seg, *q| q.* = seg.start();
        try loops.append(a, pts);
    }
    const out = try a.alloc(u8, @as(usize, n) * n);
    for (0..n) |j| for (0..n) |i| {
        var hits: u32 = 0;
        for (0..4) |sj| for (0..4) |si| {
            const p = m.apply(.{ .x = @as(f64, @floatFromInt(i)) + (@as(f64, @floatFromInt(si)) + 0.5) / 4, .y = @as(f64, @floatFromInt(j)) + (@as(f64, @floatFromInt(sj)) + 0.5) / 4 });
            var in = false;
            for (loops.items) |l| {
                var k = l.len - 1;
                for (0..l.len) |q| {
                    if ((l[q].y > p.y) != (l[k].y > p.y) and p.x < l[q].x + (p.y - l[q].y) * (l[k].x - l[q].x) / (l[k].y - l[q].y)) in = !in;
                    k = q;
                }
            }
            if (in) hits += 1;
        };
        out[j * n + i] = @intCast(hits * 255 / 16);
    };
    return out;
}

const ThreeMfOptions = struct {
    grouping: layout.threemf.Grouping = .colours,
    bed: layout.threemf.Bed = .bottom,
};

fn monoNow() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn msBetween(a: i128, b: i128) f64 {
    return @as(f64, @floatFromInt(b - a)) / 1e6;
}

const LabelFlags = struct {
    width: ?f64 = null,
    centre: bool = false,
    bold: ?[]const u8 = null,
    bold_italic: ?[]const u8 = null,
};

/// A legend set by glyphic in a style made of the font files given: the
/// upright text face, its italic (variables italic in math), its bolds,
/// then fallbacks; on one line, or broken into lines `--width` wide.
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

    // Faces by role: text, italic if given, the bolds, then fallbacks.
    var faces: std.ArrayList(*layout.Face) = .empty;
    defer for (faces.items) |f| f.deinit();
    var roles: std.ArrayList([]const u8) = .empty;
    const load = struct {
        fn f(al: std.mem.Allocator, g: std.mem.Allocator, i: std.Io, path: []const u8) !*layout.Face {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(i, path, al, .limited(64 << 20));
            return layout.Face.init(g, bytes, 0);
        }
    }.f;
    try faces.append(a, try load(a, gpa, io, args[0]));
    try roles.append(a, "text");
    const has_italic = !std.mem.eql(u8, args[1], "-");
    if (has_italic) {
        try faces.append(a, try load(a, gpa, io, args[1]));
        try roles.append(a, "italic");
    }
    if (flags.bold) |p| {
        try faces.append(a, try load(a, gpa, io, p));
        try roles.append(a, "bold");
    }
    if (flags.bold_italic) |p| {
        try faces.append(a, try load(a, gpa, io, p));
        try roles.append(a, "bold_italic");
    }
    for (args[5..], 0..) |fb, k| {
        try faces.append(a, try load(a, gpa, io, fb));
        try roles.append(a, try std.fmt.allocPrint(a, "fallback{d}", .{k + 1}));
    }
    var g = glyphic.Engine.init(gpa);
    defer g.deinit();
    const style = try g.addStyle("label", .none);
    for (faces.items, roles.items) |f, r| try g.setFace(style, r, f);
    if (has_italic) try g.setFor(style, .{ .kind = .variable }, .shape, glyphic.param.of(glyphic.param.Shape.italic));

    var e = try glyphic.Expr.init(gpa);
    defer e.deinit();
    var spans: glyphic.entry.Spans = .{};
    defer spans.deinit(gpa);
    try glyphic.latex.parse(&e, &spans, src, .legend);
    const r = glyphic.Resolver.init(&g, &e, &.{style});
    const text = faces.items[0];
    const ext = text.extents();
    const pitch = (ext.ascender - ext.descender) * cap / glyphic.faces.capUnits(text);
    var rows: glyphic.ground.Rows = .{ .a = a, .origin = .{ .x = 0, .y = 0 }, .length = flags.width orelse 1e6, .pitch = pitch, .count = 256, .cap = cap, .alignment = if (flags.centre) .centre else .start };
    const set = try glyphic.setting.set(a, &r, rows.ground(), .{});
    const outlines = try glyphic.setting.outlines(a, set.items, cap / 1000);
    var box: layout.geom.Box = .empty;
    for (outlines) |o| box = box.join(o.bounds());
    const doc = try layout.output.svg(a, outlines, box, .{});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = doc });
    for (set.missing) |m| std.debug.print("warning: U+{X:0>4} is in no face\n", .{m.cp});
    if (set.overflow) std.debug.print("warning: wider than {d} mm\n", .{flags.width orelse 0});
    std.debug.print("{s}: {d} lines, {d} items\n", .{ out_path, set.lines.len, set.items.len });
}

fn rtfShow(init: std.process.Init, path: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(64 << 20));
    const doc = richtext.rtf.read(a, bytes) catch |err| {
        std.debug.print("{s}: {s}\n", .{ path, if (err == error.NotRtf) "not an RTF file" else @errorName(err) });
        std.process.exit(1);
    };
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    for (doc.fonts, 0..) |f, k| try w.print("font {d}: {s} ({s})\n", .{ k, f.name, @tagName(f.kind) });
    for (doc.paragraphs, 0..) |p, k| {
        const st = p.settings;
        try w.print("\n¶{d} {s}, indents {d:.2}/{d:.2} first {d:.2}, space {d:.2}/{d:.2} mm\n", .{ k + 1, @tagName(st.alignment), st.indent_start, st.indent_end, st.first, st.space_before, st.space_after });
        var i: usize = 0;
        while (i < p.spans.len) {
            if (p.spans[i].kind == .line_break) {
                try w.writeAll("  (line break)\n");
                i += 1;
                continue;
            }
            const look = p.spans[i].look;
            var e = i;
            while (e < p.spans.len and p.spans[e].kind != .line_break and p.spans[e].look.font == look.font and p.spans[e].look.size == look.size) e += 1;
            try w.print("  [{s} {d} pt] ", .{ if (look.font) |f| doc.fonts[f].name else "-", look.size orelse 0 });
            try richtext.writeMarkup(w, p.spans[i..e]);
            try w.writeAll("\n");
            i = e;
        }
    }
    const sk = doc.skipped;
    try w.print("\nleft out: {d} pictures, {d} footnotes, {d} objects; {d} table rows as tabbed lines; {d} fields as their text\n", .{ sk.pictures, sk.footnotes, sk.objects, sk.table_rows, sk.fields });
    try w.flush();
}

/// A legend's objects as glyphic parses it (text, math between dollars).
fn parse(init: std.process.Init, src: []const u8) !void {
    const gpa = init.gpa;
    var e = try glyphic.Expr.init(gpa);
    defer e.deinit();
    var spans: glyphic.entry.Spans = .{};
    defer spans.deinit(gpa);
    try glyphic.latex.parse(&e, &spans, src, .legend);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try glyphic.entry.dump(&out.writer, &e, e.root);
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

// Documents ------------------------------------------------------------------

/// The installed fonts, from the font index the GUI keeps (built here when
/// there is none yet), loaded only as a style asks for one.
const InstalledFonts = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    records: []const local_fonts.Record = &.{},
    names: []layout.model.FontName = &.{},
    faces: std.AutoHashMapUnmanaged(usize, *layout.Face) = .empty,

    fn load(f: *InstalledFonts) !void {
        const a = f.arena.allocator();
        f.records = local_fonts.load(f.io, a);
        if (f.records.len == 0) f.records = local_fonts.build(f.io, f.gpa, a, null) catch &.{};
        f.names = try a.alloc(layout.model.FontName, f.records.len);
        for (f.records, f.names) |r, *n| n.* = .{ .family = r.family, .style = r.style };
    }

    fn catalog(f: *InstalledFonts) layout.fonts.Catalog {
        return .{ .names = f.names, .ctx = f, .load = struct {
            fn get(ctx: *anyopaque, i: usize) ?*layout.Face {
                const self: *InstalledFonts = @ptrCast(@alignCast(ctx));
                if (self.faces.get(i)) |face| return face;
                const r = &self.records[i];
                const bytes = local_fonts.read(self.io, self.gpa, r) catch return null;
                defer self.gpa.free(bytes);
                const face = layout.Face.init(self.gpa, bytes, r.index) catch return null;
                self.faces.put(self.gpa, i, face) catch {
                    face.deinit();
                    return null;
                };
                return face;
            }
        }.get };
    }

    fn deinit(f: *InstalledFonts) void {
        var it = f.faces.valueIterator();
        while (it.next()) |face| face.*.deinit();
        f.faces.deinit(f.gpa);
        f.arena.deinit();
    }
};

const ExportOptions = struct {
    font: ?[]const u8 = null,
    panel: ?[]const u8 = null,
    threemf: ThreeMfOptions = .{},
    /// graven check: the panels checked, nothing written; with `svg`, each
    /// panel drawn with its findings over it.
    check: bool = false,
    svg: ?[]const u8 = null,
};

/// graven export: each panel of a document (or the one named) as SVG or
/// 3MF, by the output's extension; with several panels, each to
/// `<stem>-<panel name><ext>`. Fonts as the GUI finds them: the document's
/// folders first (folders.zig), then the installed ones; or, with --font,
/// every style in that one font.
/// A panel's checks, printed: each check's verdict, then every finding.
fn printChecks(init: std.process.Init, m: *const layout.Model, pi: usize, placed: *const layout.place.Placed, faces: []const *layout.Face, svg_path: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const name = m.panels.items[pi].name;
    const t0 = std.Io.Clock.awake.now(init.io);
    var cache: layout.check.Cache = .init(init.gpa);
    defer cache.deinit();
    const r = try layout.check.run(a, m, pi, placed, faces, &cache);
    const t1 = std.Io.Clock.awake.now(init.io);
    const ms = @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / 1e6;
    // Again, with what the first run measured: as the GUI runs it after an
    // edit.
    var again_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer again_arena.deinit();
    _ = try layout.check.run(again_arena.allocator(), m, pi, placed, faces, &cache);
    const warm = @as(f64, @floatFromInt(t1.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds)) / 1e6;
    std.debug.print("  again, with its shapes measured: {d:.1} ms\n", .{warm});
    const pr = r.profile orelse {
        std.debug.print("{s}: no process profile chosen: nothing to check against\n", .{name});
        return;
    };
    std.debug.print("{s}: {s}, {s} ({d:.0} ms)\n", .{ name, pr.name, @tagName(r.overall()), ms });
    std.debug.print("  {d} simulated paths\n", .{r.paths.len});
    std.debug.print("  part {d:.2} x {d:.2} x {d:.2} mm, {d} colour(s); {d} faces, {d} alike, {d} unmeasured\n", .{ r.extent[0], r.extent[1], r.extent[2], r.colours, r.faces, r.cached, r.unmeasured });
    for (std.enums.values(layout.check.Kind)) |k| {
        std.debug.print("  {s}: {s}", .{ k.label(), @tagName(r.worst.get(k)) });
        const mg = r.count(k, .marginal);
        const fl = r.count(k, .fail);
        if (mg + fl > 0) std.debug.print(" ({d} marginal, {d} failing)", .{ mg, fl });
        std.debug.print("\n", .{});
    }
    if (svg_path) |path| {
        // The panel, and over it each finding's area: marginal amber,
        // failing red; a box round one with no area.
        const base = try layout.output.panelSvg(a, placed, faces, .{});
        const g = std.mem.indexOf(u8, base, "<g transform=\"").?;
        const g_end = std.mem.indexOfScalarPos(u8, base, g, '>').? + 1;
        const end = std.mem.lastIndexOf(u8, base, "</svg>").?;
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll(base[0..end]);
        try w.writer.writeAll(base[g..g_end]);
        for (r.paths) |pth| {
            try w.writer.print("<path fill=\"none\" stroke=\"#{x:0>2}{x:0>2}{x:0>2}\" stroke-opacity=\"0.55\" stroke-width=\"{d:.3}\" stroke-linejoin=\"round\" d=\"", .{ pth.colour.color.r, pth.colour.color.g, pth.colour.color.b, pth.width });
            for (pth.points, 0..) |q, k| try w.writer.print("{s}{d:.4} {d:.4}", .{ if (k == 0) "M" else "L", q.x, q.y });
            try w.writer.writeAll("Z\"/>\n");
        }
        for (r.findings) |f| {
            const colour = if (f.verdict == .fail) "#e0201b" else "#e000d0";
            if (f.area) |o| {
                try w.writer.print("<path fill=\"{s}\" fill-opacity=\"0.85\" d=\"", .{colour});
                for (o.contours) |cn| {
                    for (cn.segments, 0..) |sg, k| {
                        const p0 = sg.start();
                        if (k == 0) try w.writer.print("M{d:.4} {d:.4}", .{ p0.x, p0.y });
                        const p1 = sg.end();
                        try w.writer.print("L{d:.4} {d:.4}", .{ p1.x, p1.y });
                    }
                    try w.writer.writeAll("Z");
                }
                try w.writer.writeAll("\"/>\n");
            } else try w.writer.print("<rect x=\"{d:.3}\" y=\"{d:.3}\" width=\"{d:.3}\" height=\"{d:.3}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"0.1\"/>\n", .{ f.box.x0, f.box.y0, f.box.width(), f.box.height(), colour });
        }
        try w.writer.writeAll("</g>\n</svg>\n");
        const safe = try a.dupe(u8, name);
        for (safe) |*ch| if (ch.* == '/' or ch.* == ' ') {
            ch.* = '-';
        };
        const ext = std.fs.path.extension(path);
        const out = try std.fmt.allocPrint(a, "{s}-{s}{s}", .{ path[0 .. path.len - ext.len], safe, ext });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out, .data = w.written() });
        std.debug.print("  drawn: {s}\n", .{out});
    }
    for (r.findings) |f| {
        std.debug.print("    {s} {s} at ({d:.2}, {d:.2})-({d:.2}, {d:.2})", .{ f.kind.label(), @tagName(f.verdict), f.box.x0, f.box.y0, f.box.x1, f.box.y1 });
        switch (f.kind) {
            .stroke, .gap => std.debug.print(" z {d:.2}-{d:.2}{s}{s}", .{ f.z[0], f.z[1], if (f.colour != null) " " else "", f.colour orelse "" }),
            .cap, .depth => std.debug.print(" {d:.3} mm", .{f.value}),
            .colours => std.debug.print(" {d}", .{f.value}),
            .size => std.debug.print(" {d:.1} x {d:.1} x {d:.1}", .{ f.extent[0], f.extent[1], f.extent[2] }),
        }
        std.debug.print("\n", .{});
    }
}

fn exportDocument(init: std.process.Init, doc_path: []const u8, out_path: []const u8, opts: ExportOptions) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ext = std.fs.path.extension(out_path);
    const as_3mf = std.ascii.eqlIgnoreCase(ext, ".3mf");
    if (!opts.check and !as_3mf and !std.ascii.eqlIgnoreCase(ext, ".svg")) {
        std.debug.print("{s}: the output must end in .svg or .3mf\n", .{out_path});
        std.process.exit(2);
    }
    var doc = try openDocument(init, doc_path);
    defer gpa.free(doc.bytes);
    defer doc.opened.model.deinit();
    defer doc.opened.history.deinit();
    const m = &doc.opened.model;

    var dirs: folders.Folders = .init(gpa);
    defer dirs.deinit(gpa);
    var forced: folders.Folders = .init(gpa);
    defer forced.deinit(gpa);
    var installed: InstalledFonts = .{ .arena = .init(gpa), .gpa = gpa, .io = io };
    defer installed.deinit();
    var cat: layout.fonts.Catalog = undefined;
    if (opts.font) |f| {
        // Every face every style names, in this font.
        try forced.addFile(gpa, io, f);
        const name = forced.names.items[0];
        for (m.styles.items) |st| for (st.faces.items) |sf| try m.setStyleFace(st.id, sf.role, name);
        cat = forced.catalog();
    } else {
        for (try folders.dirsFor(arena, doc_path)) |d| try dirs.addDir(gpa, io, d);
        cat = dirs.catalog();
    }
    const default = if (forced.faces.items.len > 0) forced.faces.items[0] else if (dirs.faces.items.len > 0) dirs.faces.items[0] else blk: {
        try installed.load();
        cat = installed.catalog();
        for (0..cat.names.len) |i| if (cat.load(cat.ctx, i)) |face| break :blk face;
        std.debug.print("no fonts found: none beside the document, in fonts/ or installed\n", .{});
        std.process.exit(1);
    };
    var res = try layout.fonts.resolve(gpa, m, cat, default);
    defer res.deinit();
    if (res.substitutions.items.len > 0 and opts.font == null and dirs.faces.items.len > 0) {
        // Not all in the document's folders: the installed fonts after them.
        try installed.load();
        const joined = try layout.fonts.join(arena, dirs.catalog(), installed.catalog());
        const again = try layout.fonts.resolve(gpa, m, joined, default);
        res.deinit();
        res = again;
    }
    for (res.substitutions.items) |sub| {
        if (sub.got) |got| {
            std.debug.print("{s} {s}: not found, {s} {s} used\n", .{ sub.wanted.family, sub.wanted.style, got.family, got.style });
        } else std.debug.print("{s} {s}: not found, left out\n", .{ sub.wanted.family, sub.wanted.style });
    }
    const faces = res.faces.items;
    var labels: layout.Labels = .init(gpa, faces);
    defer labels.deinit();
    try labels.syncResolved(&res);

    var chosen: std.ArrayList(usize) = .empty;
    for (m.panels.items, 0..) |p, pi| {
        if (p.unbounded) continue;
        if (opts.panel) |want| if (!std.mem.eql(u8, p.name, want)) continue;
        try chosen.append(arena, pi);
    }
    if (chosen.items.len == 0) {
        std.debug.print("{s}: no panel{s}{s}\n", .{ doc_path, if (opts.panel != null) " named " else "", opts.panel orelse "" });
        std.process.exit(1);
    }
    const stem = out_path[0 .. out_path.len - ext.len];
    for (chosen.items) |pi| {
        const name = m.panels.items[pi].name;
        const path = if (chosen.items.len == 1) out_path else blk: {
            const safe = try arena.dupe(u8, name);
            for (safe) |*c| if (c.* == '/' or c.* == '\\') {
                c.* = '-';
            };
            break :blk try std.fmt.allocPrint(arena, "{s}-{s}{s}", .{ stem, safe, ext });
        };
        var placed = try layout.solve(gpa, m, pi, &labels);
        defer placed.deinit();
        if (opts.check) {
            try printChecks(init, m, pi, &placed, faces, opts.svg);
            continue;
        }
        var issues: usize = 0;
        for (placed.issues) |i| if (i.kind == .row_overflow or i.kind == .missing_glyph) {
            issues += 1;
        };
        const data = if (as_3mf) blk: {
            const p = try layout.fab.plan(arena, m, pi, &placed, faces);
            if (m.panels.items[pi].fab.layers.len == 0) std.debug.print("{s}: no fabrication layers: an empty 3MF\n", .{name});
            const slabs = try layout.fab.slabs(arena, p.steps);
            const ps = try layout.threemf.orient(arena, try layout.threemf.parts(arena, slabs, m.exportTolerance(), opts.threemf.grouping), opts.threemf.bed);
            break :blk try layout.threemf.package(arena, name, ps);
        } else try layout.output.panelSvg(arena, &placed, faces, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        std.debug.print("{s}: {s}, {d} tiles, {d} bytes{s}\n", .{ path, name, placed.tiles.len, data.len, if (issues > 0) " (with overflows or missing glyphs)" else "" });
    }
}
