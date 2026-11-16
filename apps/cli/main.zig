//! graven command-line tool: batch runs, stage dumps and production jobs.
//! Applications own files and console output; the libraries never do.

const std = @import("std");
const builtin = @import("builtin");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const fontsearch = @import("graven_fontsearch");
const richtext = @import("graven_richtext");
const samples = @import("graven_samples");
const glyphic = @import("graven_glyphic");

const usage =
    \\usage: graven svg <font file> <text> <cap height mm> <out.svg>
    \\         Renders one run of text in one face and writes its outlines as SVG.
    \\       graven msdf <font file> <text> <texels per cap height> <out.pgm>
    \\         Makes each glyph's multi-channel signed distance field and draws it back
    \\         at several sizes, plain and grown, into a greyscale sheet; reports each
    \\         field's time and its drawn area against the outline's.
    \\       graven parse <markup>
    \\         Parses label markup and prints its tree, or where it went wrong.
    \\       graven rtf <file.rtf>
    \\         Reads an RTF file as an import would: each paragraph's settings and its
    \\         text as Graven markup, then what was left out.
    \\       graven label [--advance] [--width mm] [--centre] [--bold font] [--bold-italic font] <upright font> <italic font|-> <cap height mm> <markup> <out.svg> [fallback font ...]
    \\         Renders label markup; with an italic font, letters default to italic.
    \\         Neighbours are placed by their ink unless --advance is given. --width gives a
    \\         hard box that wide, so lines wrap; --centre centres each line on the anchor.
    \\         --bold and --bold-italic give the family's bolds, for \\textbf and \\mathbf.
    \\       graven keyboard <font> <out.svg>
    \\         Lays out the sample PC keyboard in one font and writes it as SVG.
    \\       graven hp15c <font|package> <plate.svg> <keys.svg> [fallback font ...]
    \\         Lays out the rough HP-15C keypad: the plate with its holes and gold legends,
    \\         and the keys, each written as SVG. Fallback fonts set what the font lacks.
    \\         A math font package (stix-two, libertinus) instead of a font sets the legends in its
    \\         faces, from $GRAVEN_FONTS or fonts/ (fill it with scripts/fetch-fonts.py).
    \\       graven 3mf [--parts colours|bands] [--bed bottom|top] hp15c <font> <plate.3mf> <keys.3mf> [fallback font ...]
    \\         The HP-15C keypad's plate and keys for multi-colour 3D printing, each part's
    \\         stack of layer operations as closed meshes, parts of one object, colours as
    \\         materials, written as 3MF. --parts colours (the default) gives one part per
    \\         colour; bands, one per colour and height band. --bed bottom (the default)
    \\         stands each part on its lowest face; top turns it over onto its top face.
    \\       graven v2 hp15c <folder>
    \\         Engine v2 against v1: the HP-15C keypad (libertinus) as v1 sets it, and with every
    \\         legend parsed from its markup and set by v2 in the same place (column tracks
    \\         too): v1-plate.svg,
    \\         v1-keys.svg, v2-plate.svg, v2-keys.svg in <folder>.
    \\       graven v2 <text font> <math font> <out.svg> [italic font]
    \\         Engine v2: sets the Leibniz series (built as objects) on three grounds: one
    \\         long row in display style, narrow rows it must break across, and a dial.
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
    if (args.len == 4 and std.mem.eql(u8, args[1], "keyboard")) {
        return keyboard(init, args[2], args[3]);
    }
    if (args.len >= 5 and std.mem.eql(u8, args[1], "hp15c")) {
        return hp15c(init, args[2], args[3], args[4], args[5..]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "3mf")) {
        var opts: ThreeMfOptions = .{};
        var k: usize = 2;
        while (k + 1 < args.len and std.mem.startsWith(u8, args[k], "--")) : (k += 2) {
            if (std.mem.eql(u8, args[k], "--parts")) {
                opts.grouping = std.meta.stringToEnum(layout.threemf.Grouping, args[k + 1]) orelse break;
            } else if (std.mem.eql(u8, args[k], "--bed")) {
                opts.bed = std.meta.stringToEnum(layout.threemf.Bed, args[k + 1]) orelse break;
            } else break;
        }
        if (args.len - k >= 4 and std.mem.eql(u8, args[k], "hp15c")) return hp15c3mf(init, args[k + 1], args[k + 2], args[k + 3], args[k + 4 ..], opts);
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
    var loaded: std.ArrayList(*engine.Face) = .empty;
    defer for (loaded.items) |f| f.deinit();
    for ([_]?[]const u8{ text_path, math_path, italic_path }, [_][]const u8{ "text", "math", "italic" }) |path, name| {
        const p = path orelse continue;
        const bytes = try cwd.readFileAlloc(io, p, a, .limited(64 << 20));
        const f = try engine.Face.init(gpa, bytes, 0);
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

    var outs: std.ArrayList(engine.geom.Outline) = .empty;
    var box: engine.geom.Box = .empty;
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
    const geom = engine.geom;
    const bytes = try cwd.readFileAlloc(io, font_path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const face = try engine.Face.init(gpa, bytes, 0);
    defer face.deinit();
    const cap = (try face.capHeight()) orelse @as(f64, @floatFromInt(face.upem)) * 0.7;
    const faces = [_]*engine.Face{face};
    var r = try engine.renderRun(gpa, &faces, 0, text, .{ .cap_height = cap });
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
fn exactCoverage(a: std.mem.Allocator, o: engine.geom.Outline, n: u32, m: engine.geom.Affine, grow: f64) ![]u8 {
    const geom = engine.geom;
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
    const main_style = try m.addStyle("legend", .{ .cap_height = 2.6 });
    const small = try m.addStyle("legend words", .{ .cap_height = 1.6 });
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

/// The legends' fonts: font files (the first the text face, the rest
/// fallbacks), or a math font package by name (see layout.fonts.Package),
/// its faces found by name in the fonts directory ($GRAVEN_FONTS, else
/// fonts/; scripts/fetch-fonts.py fills it). Either way the fonts are a
/// catalog, the legends' base style names them, and resolving gives the
/// faces.
const LegendFonts = struct {
    package: ?*const layout.fonts.Package = null,
    dir: DirFonts,
    resolved: ?layout.fonts.Resolved = null,

    fn init(gpa: std.mem.Allocator, io: std.Io, font: []const u8, fallbacks: []const [:0]const u8) !LegendFonts {
        if (layout.fonts.package(font)) |pkg| {
            const set = if (std.c.getenv("GRAVEN_FONTS")) |v| std.mem.span(v) else "";
            const dir = if (set.len > 0) set else "fonts";
            return .{ .package = pkg, .dir = try DirFonts.load(gpa, io, dir) };
        }
        const paths = try gpa.alloc([]const u8, fallbacks.len + 1);
        defer gpa.free(paths);
        paths[0] = font;
        for (fallbacks, paths[1..]) |fb, *p| p.* = fb;
        return .{ .dir = try DirFonts.loadFiles(gpa, io, paths) };
    }

    /// The legends' base style: the package's, or the files' (the first as
    /// the text face, the rest as fallbacks).
    fn base(f: *const LegendFonts, m: *layout.Model) !layout.model.StyleId {
        if (f.package) |pkg| return layout.fonts.addPackage(m, pkg, "Legends");
        const id = try m.addStyle("Legends", .{});
        var buf: [32]u8 = undefined;
        for (f.dir.names.items, 0..) |n, k| {
            const role = if (k == 0) "text" else try std.fmt.bufPrint(&buf, "fallback{d}", .{k});
            try m.setStyleFace(id, role, n);
        }
        return id;
    }

    /// Resolves the styles' fonts against these.
    fn resolve(f: *LegendFonts, gpa: std.mem.Allocator, m: *const layout.Model) !void {
        if (f.dir.faces.items.len == 0) {
            std.debug.print("no fonts in the fonts directory: run scripts/fetch-fonts.py\n", .{});
            return error.NoFonts;
        }
        f.resolved = try layout.fonts.resolve(gpa, m, f.dir.catalog(), f.dir.faces.items[0]);
        for (f.resolved.?.substitutions.items) |sub| {
            if (sub.got) |got| {
                std.debug.print("{s} {s}: not found, {s} {s} used\n", .{ sub.wanted.family, sub.wanted.style, got.family, got.style });
            } else std.debug.print("{s} {s}: not found (run scripts/fetch-fonts.py)\n", .{ sub.wanted.family, sub.wanted.style });
        }
    }

    fn faces(f: *const LegendFonts) []const *engine.Face {
        return f.resolved.?.faces.items;
    }

    fn sync(f: *LegendFonts, labels: *layout.Labels) !void {
        if (f.resolved) |*r| try labels.syncResolved(r);
    }

    fn deinit(f: *LegendFonts, gpa: std.mem.Allocator) void {
        if (f.resolved) |*r| r.deinit();
        f.dir.deinit(gpa);
    }
};

/// Fonts loaded and named, as a catalog: every font in a directory, or
/// the font files given.
const DirFonts = struct {
    arena: std.heap.ArenaAllocator,
    faces: std.ArrayList(*engine.Face) = .empty,
    bytes: std.ArrayList([]u8) = .empty,
    names: std.ArrayList(layout.model.FontName) = .empty,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !DirFonts {
        var d: DirFonts = .{ .arena = .init(gpa) };
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return d;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const ext = std.fs.path.extension(entry.name);
            if (!std.ascii.eqlIgnoreCase(ext, ".ttf") and !std.ascii.eqlIgnoreCase(ext, ".otf")) continue;
            const bytes = try dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20));
            d.add(gpa, bytes, entry.name) catch continue;
        }
        return d;
    }

    /// The files at `paths`, in order; one that cannot be read is an error.
    fn loadFiles(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) !DirFonts {
        var d: DirFonts = .{ .arena = .init(gpa) };
        errdefer d.deinit(gpa);
        for (paths) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
            try d.add(gpa, bytes, std.fs.path.basename(path));
        }
        return d;
    }

    fn add(d: *DirFonts, gpa: std.mem.Allocator, bytes: []u8, file: []const u8) !void {
        const a = d.arena.allocator();
        const face = engine.Face.init(gpa, bytes, 0) catch |err| {
            gpa.free(bytes);
            return err;
        };
        const r = try fontsearch.describe(a, face, "", file, 0, 0);
        try d.faces.append(a, face);
        try d.bytes.append(a, bytes);
        try d.names.append(a, .{ .family = r.family, .style = r.style });
    }

    fn catalog(d: *DirFonts) layout.fonts.Catalog {
        return .{ .names = d.names.items, .ctx = d, .load = struct {
            fn f(ctx: *anyopaque, index: usize) ?*engine.Face {
                const self: *DirFonts = @ptrCast(@alignCast(ctx));
                return self.faces.items[index];
            }
        }.f };
    }

    fn deinit(d: *DirFonts, gpa: std.mem.Allocator) void {
        for (d.faces.items) |f| f.deinit();
        for (d.bytes.items) |b| gpa.free(b);
        d.arena.deinit();
    }
};

fn hp15c(init: std.process.Init, font_path: []const u8, plate_path: []const u8, keys_path: []const u8, fallbacks: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var fonts = try LegendFonts.init(gpa, io, font_path, fallbacks);
    defer fonts.deinit(gpa);

    var m: layout.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const styles = try samples.hp15c.addStyles(&m, try fonts.base(&m));
    const b = try samples.hp15c.build(&m, styles, 0, .{ .x = 0, .y = 0 });
    try fonts.resolve(gpa, &m);
    const faces = fonts.faces();

    var labels: layout.Labels = .init(gpa, faces);
    defer labels.deinit();
    try fonts.sync(&labels);
    for ([_]struct { p: usize, path: []const u8 }{ .{ .p = b.plate, .path = plate_path }, .{ .p = b.keys, .path = keys_path } }) |part| {
        var placed = try layout.solve(gpa, &m, part.p, &labels);
        defer placed.deinit();
        for (placed.issues) |i| {
            const name = if (i.tile) |t| m.tileConst(t).designator else "-";
            std.debug.print("{s}: {s}\n", .{ name, @tagName(i.kind) });
        }
        const doc = try layout.output.panelSvg(gpa, &placed, faces, .{});
        defer gpa.free(doc);
        try cwd.writeFile(io, .{ .sub_path = part.path, .data = doc });
        std.debug.print("{s}: {d} tiles, {d} labels\n", .{ part.path, placed.tiles.len, placed.labels.len });
    }
}

const ThreeMfOptions = struct {
    grouping: layout.threemf.Grouping = .colours,
    bed: layout.threemf.Bed = .bottom,
};

fn hp15c3mf(init: std.process.Init, font_path: []const u8, plate_path: []const u8, keys_path: []const u8, fallbacks: []const [:0]const u8, opts: ThreeMfOptions) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var fonts = try LegendFonts.init(gpa, io, font_path, fallbacks);
    defer fonts.deinit(gpa);

    var m: layout.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const styles = try samples.hp15c.addStyles(&m, try fonts.base(&m));
    const b = try samples.hp15c.build(&m, styles, 0, .{ .x = 0, .y = 0 });
    try fonts.resolve(gpa, &m);
    const faces = fonts.faces();

    var labels: layout.Labels = .init(gpa, faces);
    defer labels.deinit();
    try fonts.sync(&labels);
    var sound = true;
    for ([_]struct { p: usize, path: []const u8 }{ .{ .p = b.plate, .path = plate_path }, .{ .p = b.keys, .path = keys_path } }) |part| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const t0 = monoNow();
        var placed = try layout.solve(gpa, &m, part.p, &labels);
        defer placed.deinit();
        const p = try layout.fab.plan(a, &m, part.p, &placed, faces);
        const slabs = try layout.fab.slabs(a, p.steps);
        const t1 = monoNow();
        const ps = try layout.threemf.orient(a, try layout.threemf.parts(a, slabs, layout.threemf.default_tolerance, opts.grouping), opts.bed);
        const t2 = monoNow();
        const zip = try layout.threemf.package(a, m.panels.items[part.p].name, ps);
        try cwd.writeFile(io, .{ .sub_path = part.path, .data = zip });
        const t3 = monoNow();
        const stack = m.panels.items[part.p].fab;
        std.debug.print("{s}: layout and 2D regions {d:.0} ms, meshes {d:.0} ms, 3MF {d:.0} ms\n", .{ m.panels.items[part.p].name, msBetween(t0, t1), msBetween(t1, t2), msBetween(t2, t3) });
        for (p.off_layers) |li| std.debug.print("  flag: {s}: depth not a whole number of {d} mm layers\n", .{ stack.layers[li].name, stack.layer_height });
        // Per colour: the meshes' volume against the regions' exact one.
        var tris: usize = 0;
        var names: std.ArrayList([]const u8) = .empty;
        for (ps) |pt| {
            tris += pt.mesh.triangles.len;
            if (!try layout.threemf.closed(a, pt.mesh)) {
                std.debug.print("  NOT CLOSED: {s}\n", .{pt.name});
                sound = false;
            }
            for (names.items) |n| {
                if (std.mem.eql(u8, n, pt.colour)) break;
            } else try names.append(a, pt.colour);
        }
        for (names.items) |n| {
            var mv: f64 = 0;
            var ev: f64 = 0;
            for (ps) |pt| if (std.mem.eql(u8, pt.colour, n)) {
                mv += layout.threemf.volume(pt.mesh);
            };
            for (slabs) |sl| for (sl.regions) |reg| if (std.mem.eql(u8, reg.colour.name, n)) {
                ev += reg.outline.signedArea() * (sl.z1 - sl.z0);
            };
            std.debug.print("  {s}: {d:.3} mm³ meshed, {d:.3} mm³ exact\n", .{ n, mv, ev });
        }
        std.debug.print("  {d} parts, {d} triangles, {d} KB: wrote {s}\n", .{ ps.len, tris, zip.len / 1024, part.path });
    }
    if (!sound) std.process.exit(1);
}

fn monoNow() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn msBetween(a: i128, b: i128) f64 {
    return @as(f64, @floatFromInt(b - a)) / 1e6;
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
