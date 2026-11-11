//! The fonts window: find, compare and choose fonts, and compose them into
//! the document's composed fonts. A window of its own, apart from the
//! canvas and its panes; Text › Fonts… opens it.
//!
//! Search criteria on the left, results in the middle, the comparison of
//! pinned fonts on the right, and the composition being built at the far
//! right. Fonts come from the local source's index (installed fonts);
//! remote sources come later through the same API.

const std = @import("std");
const dvui = @import("dvui");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const fs = @import("graven_fontsearch");
const local = @import("graven_fonts_local");

const geom = engine.geom;
const model = layout.model;
const Allocator = std.mem.Allocator;
const ObjectId = model.ObjectId;

/// Whether the window is open; closing it clears this.
pub var open = false;

/// What the window needs from the editor: the document, and the actions it
/// takes on it (each undoable there).
pub const Host = struct {
    model: *const layout.Model,
    addFont: *const fn (name: []const u8, main: model.FontName) ?ObjectId,
    setFontMain: *const fn (id: ObjectId, main: model.FontName, italic: ?model.FontName) void,
    addFontMember: *const fn (id: ObjectId, member: model.FontMember) void,
    moveFontMember: *const fn (id: ObjectId, index: usize, up: bool) void,
    removeFontMember: *const fn (id: ObjectId, index: usize) void,
    setStyleFont: *const fn (style: model.StyleId, id: ObjectId) void,
};

// The index ---------------------------------------------------------------------

var gpa: Allocator = undefined;
var index_arena: ?std.heap.ArenaAllocator = null;
/// The local source's records, loaded when first needed.
var records: []fs.Record = &.{};
var report: local.Report = .{};
var status: []const u8 = "";
var status_buf: [200]u8 = undefined;
/// Faces loaded from records, by record index.
var faces: std.AutoHashMapUnmanaged(usize, *engine.Face) = .empty;

/// The installed fonts' records: the saved index, or a fresh scan when
/// there is none. `rescan` scans again (describing only what changed).
pub fn indexRecords(allocator: Allocator, rescan: bool) []fs.Record {
    gpa = allocator;
    if (index_arena != null and !rescan) return records;
    if (index_arena) |*a| a.deinit();
    index_arena = .init(gpa);
    const a = index_arena.?.allocator();
    dropFaces();
    records = if (rescan) &.{} else local.load(dvui.io, a);
    if (records.len == 0) {
        records = local.build(dvui.io, gpa, a, &report) catch &.{};
        status = std.fmt.bufPrint(&status_buf, "{d} fonts: {d} described, {d} unchanged, {d} unreadable.", .{ records.len, report.described, report.kept, report.failed }) catch "";
    } else status = std.fmt.bufPrint(&status_buf, "{d} fonts, from the saved index.", .{records.len}) catch "";
    return records;
}

fn dropFaces() void {
    var it = faces.valueIterator();
    while (it.next()) |f| f.*.deinit();
    faces.clearAndFree(gpa);
}

/// The face record `i` describes, loaded once and kept.
pub fn faceOf(i: usize) ?*engine.Face {
    if (faces.get(i)) |f| return f;
    const r = &records[i];
    const bytes = local.read(dvui.io, gpa, r) catch return null;
    defer gpa.free(bytes);
    const f = engine.Face.init(gpa, bytes, r.index) catch return null;
    faces.put(gpa, i, f) catch {
        f.deinit();
        return null;
    };
    return f;
}

/// The catalog the document's composed fonts are resolved against: the
/// installed fonts by family and style.
pub fn catalog(a: Allocator) ?layout.fonts.Catalog {
    if (records.len == 0) return null;
    const names = a.alloc(model.FontName, records.len) catch return null;
    for (records, names) |r, *n| n.* = .{ .family = r.family, .style = r.style };
    return .{ .names = names, .ctx = undefined, .load = struct {
        fn load(_: *anyopaque, i: usize) ?*engine.Face {
            return faceOf(i);
        }
    }.load };
}

// The window's state -----------------------------------------------------------

var words: [128]u8 = undefined;
var words_len: usize = 0;
var covers: [256]u8 = undefined;
var covers_len: usize = 0;
var sample: [256]u8 = undefined;
var sample_len: usize = 0;
var sample_set = false;
var allow_missing = false;
var serif_choice: usize = 0;
var slant_choice: usize = 0;
var embed_choice: usize = 0;
var mono = false;
var math = false;
var variable = false;
var licences: [6]bool = @splat(false);
const licence_kinds = [_]fs.Licence{ .ofl, .apache, .ufl, .gpl, .other, .unstated };
const licence_names = [_][]const u8{ "OFL", "Apache", "UFL", "GPL", "Other", "Not stated" };

/// The font selected in the results, and the one results are ranked by
/// likeness to.
var selected: ?usize = null;
var like: ?usize = null;
/// Fonts pinned for comparison, in order.
var pinned: std.ArrayList(usize) = .empty;
const max_pinned = 5;
var overlay = false;
/// The composed font being built (in the document).
var target: ?ObjectId = null;
var style_choice: usize = 0;

/// The comparison's ground: Graven's paper.
const paper: dvui.Color = .{ .r = 0xfb, .g = 0xfa, .b = 0xf7 };

const default_sample = "Hamburgefonstiv 0123 AΩ≤";

fn text(buf: []const u8, len: usize) []const u8 {
    return buf[0..len];
}

fn keep(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    len.* = n;
}

fn codepoints(a: Allocator, s: []const u8) []u21 {
    var out: std.ArrayList(u21) = .empty;
    const view = std.unicode.Utf8View.init(s) catch return &.{};
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ') continue;
        if (std.mem.indexOfScalar(u21, out.items, cp) == null) out.append(a, cp) catch break;
    }
    return out.items;
}

/// Inside a scroll area whose bar overlays its content: the content, kept
/// clear of where the bar appears, so nothing moves when it does.
fn keepBarRoom(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    const bar = dvui.ScrollBarWidget.defaults.min_sizeGet().w;
    return dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .w = bar } });
}

fn heading(src: std.builtin.SourceLocation, s: []const u8) void {
    dvui.labelNoFmt(src, s, .{}, .{ .font = dvui.Font.theme(.heading), .margin = .{ .y = 8, .h = 4 } });
}

/// The window, while open. Call once a frame from the editor's frame.
pub fn window(host: Host, allocator: Allocator) void {
    if (!open) return;
    gpa = allocator;
    if (!sample_set) {
        keep(&sample, &sample_len, default_sample);
        sample_set = true;
    }
    var ow = dvui.osWindow(@src(), .{ .title = "Fonts — Graven", .size = .{ .w = 1360, .h = 820 }, .min_size = .{ .w = 900, .h = 560 } }, .{ .open_flag = &open });
    defer ow.deinit();
    if (index_arena == null) _ = indexRecords(allocator, false);

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(6) });
        defer top.deinit();
        dvui.labelNoFmt(@src(), status, .{}, .{ .gravity_y = 0.5 });
        if (dvui.button(@src(), "Close", .{}, .{ .gravity_x = 1 })) open = false;
        if (dvui.button(@src(), "Scan installed fonts again", .{}, .{ .gravity_x = 1 })) {
            _ = indexRecords(allocator, true);
            selected = null;
            like = null;
            pinned.clearRetainingCapacity();
        }
    }
    var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer cols.deinit();
    const a = dvui.currentWindow().arena();
    // Fixed columns for criteria, results and composition; the comparison
    // takes what is left.
    const total = cols.data().contentRect().w;
    const rest = @max(300, total - (250 + 16) - (360 + 16) - (300 + 16) - 16);
    criteria();
    const hits = results(a);
    _ = hits;
    compare(a, rest);
    compose(host);
}

// Search criteria --------------------------------------------------------------

fn criteria() void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 250 }, .max_size_content = .width(250), .expand = .vertical, .padding = .all(8) });
    defer col.deinit();
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    var bar_room = keepBarRoom(@src());
    defer bar_room.deinit();
    heading(@src(), "Search");
    dvui.labelNoFmt(@src(), "Family or style has every word", .{}, .{});
    {
        var te = dvui.textEntry(@src(), .{ .text_initial = text(&words, words_len) }, .{ .expand = .horizontal });
        defer te.deinit();
        keep(&words, &words_len, te.textGet());
    }
    dvui.labelNoFmt(@src(), "Must have these characters", .{}, .{ .margin = .{ .y = 6 } });
    {
        var te = dvui.textEntry(@src(), .{ .text_initial = text(&covers, covers_len) }, .{ .expand = .horizontal });
        defer te.deinit();
        keep(&covers, &covers_len, te.textGet());
    }
    _ = dvui.checkbox(@src(), &allow_missing, "Also fonts missing some", .{});

    dvui.labelNoFmt(@src(), "Like", .{}, .{ .margin = .{ .y = 6 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (like) |l| {
            var buf: [96]u8 = undefined;
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "{s} {s}", .{ records[l].family, records[l].style }) catch "", .{}, .{ .gravity_y = 0.5 });
            if (dvui.button(@src(), "Clear", .{}, .{ .gravity_x = 1 })) like = null;
        } else dvui.labelNoFmt(@src(), "— (any)", .{}, .{ .gravity_y = 0.5 });
    }
    if (selected) |s| if (like == null or like.? != s) {
        if (dvui.button(@src(), "Rank by likeness to selected", .{}, .{ .expand = .horizontal })) like = s;
    };

    heading(@src(), "Style");
    _ = dvui.dropdown(@src(), &.{ "Serif or sans", "Serif", "Sans" }, .{ .choice = &serif_choice }, .{}, .{ .expand = .horizontal });
    _ = dvui.dropdown(@src(), &.{ "Upright or italic", "Upright", "Italic" }, .{ .choice = &slant_choice }, .{}, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
    _ = dvui.checkbox(@src(), &mono, "Monospaced", .{});
    _ = dvui.checkbox(@src(), &math, "Math (has a MATH table)", .{});
    _ = dvui.checkbox(@src(), &variable, "Variable", .{});

    heading(@src(), "Licence terms");
    dvui.labelNoFmt(@src(), "Embedding allowed at least", .{}, .{});
    _ = dvui.dropdown(@src(), &.{ "Any", "Installable", "Editable", "Preview and print" }, .{ .choice = &embed_choice }, .{}, .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), "Licence (none ticked: any)", .{}, .{ .margin = .{ .y = 6 } });
    for (licence_names, 0..) |n, i| _ = dvui.checkbox(@src(), &licences[i], n, .{ .id_extra = i });
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .margin = .{ .y = 8 } });
    tl.addText("Terms are shown as each font states them. Graven does not set them, and does not judge what your own licence allows.", .{ .font = dvui.Font.theme(.body).larger(-2) });
    tl.deinit();
}

fn query(a: Allocator) fs.Query {
    var q: fs.Query = .{ .limit = 500, .words = text(&words, words_len), .allow_missing = allow_missing };
    q.covers = codepoints(a, text(&covers, covers_len));
    if (like) |l| q.like = &records[l];
    q.serif = switch (serif_choice) {
        1 => true,
        2 => false,
        else => null,
    };
    q.italic = switch (slant_choice) {
        1 => false,
        2 => true,
        else => null,
    };
    if (mono) q.monospace = true;
    if (math) q.math = true;
    if (variable) q.variable = true;
    q.embedding = switch (embed_choice) {
        1 => .installable,
        2 => .editable,
        3 => .preview_print,
        else => null,
    };
    var ls: std.ArrayList(fs.Licence) = .empty;
    for (licences, licence_kinds) |on, k| if (on) ls.append(a, k) catch {};
    q.licences = ls.items;
    return q;
}

// Results ----------------------------------------------------------------------

fn isPinned(i: usize) bool {
    return std.mem.indexOfScalar(usize, pinned.items, i) != null;
}

fn togglePin(i: usize) void {
    if (std.mem.indexOfScalar(usize, pinned.items, i)) |k| {
        _ = pinned.orderedRemove(k);
    } else if (pinned.items.len < max_pinned) pinned.append(gpa, i) catch {};
}

fn results(a: Allocator) []const fs.Hit {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 360 }, .max_size_content = .width(360), .expand = .vertical, .padding = .all(8) });
    defer col.deinit();
    const q = query(a);
    const hits = fs.search(a, records, q) catch &.{};
    {
        var buf: [64]u8 = undefined;
        heading(@src(), std.fmt.bufPrint(&buf, "Results ({d})", .{hits.len}) catch "Results");
    }
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    var bar_room = keepBarRoom(@src());
    defer bar_room.deinit();
    for (hits, 0..) |h, k| {
        const r = &records[h.index];
        const is_sel = selected != null and selected.? == h.index;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = k,
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (is_sel) dvui.themeGet().color(.highlight, .fill) else dvui.themeGet().color(.window, .fill) },
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            .margin = .{ .h = 2 },
        });
        defer row.deinit();
        // First, so a long description never squeezes it out.
        if (dvui.button(@src(), if (isPinned(h.index)) "Unpin" else "Pin", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 40 } })) togglePin(h.index);
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer info.deinit();
            var nb: [128]u8 = undefined;
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&nb, "{s} {s}", .{ r.family, r.style }) catch r.family, .{}, .{});
            var db: [160]u8 = undefined;
            var w: std.Io.Writer = .fixed(&db);
            if (h.distance) |d| w.print("like {d:.2} · ", .{d}) catch {};
            if (h.missing > 0) w.print("missing {d} · ", .{h.missing}) catch {};
            w.print("{s}{s}{s}{s} · {s} · embed {s}", .{
                if (r.measures.serif) |s| (if (s) "serif" else "sans") else "?",
                if (r.monospace) ", mono" else "",
                if (r.math) ", math" else "",
                if (r.variable) ", variable" else "",
                licenceName(r.licence),
                embedName(r.embedding),
            }) catch {};
            dvui.labelNoFmt(@src(), w.buffered(), .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
        }
        // A click on the row selects it.
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, row.data())) continue;
            if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
                e.handle(@src(), row.data());
                selected = h.index;
                dvui.refresh(null, @src(), row.data().id);
            }
        }
    }
    return hits;
}

fn licenceName(l: fs.Licence) []const u8 {
    return switch (l) {
        .ofl => "OFL",
        .apache => "Apache",
        .ufl => "UFL",
        .gpl => "GPL",
        .other => "other licence",
        .unstated => "licence not stated",
    };
}

fn embedName(e: fs.Embedding) []const u8 {
    return switch (e) {
        .installable => "installable",
        .editable => "editable",
        .preview_print => "preview & print",
        .restricted => "restricted",
        .unknown => "not stated",
    };
}

// Comparison -------------------------------------------------------------------

/// Colours for compared fonts, told apart also by stroke weight in the
/// overlay.
const compare_colors = [_]dvui.Color{
    .{ .r = 0x1d, .g = 0x1d, .b = 0x1b },
    .{ .r = 0x1f, .g = 0x6f, .b = 0xe0 },
    .{ .r = 0xd9, .g = 0x5f, .b = 0x02 },
    .{ .r = 0x8e, .g = 0x2c, .b = 0xb0 },
    .{ .r = 0x2f, .g = 0x8a, .b = 0x4e },
};

fn compare(a: Allocator, width: f32) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .vertical, .padding = .all(8), .min_size_content = .{ .w = width }, .max_size_content = .width(width) });
    defer col.deinit();
    // Scrolled, so long samples and details never widen the column past
    // what the window has.
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    var bar_room = keepBarRoom(@src());
    defer bar_room.deinit();
    heading(@src(), "Compare");
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Sample", .{}, .{ .gravity_y = 0.5 });
        var te = dvui.textEntry(@src(), .{ .text_initial = text(&sample, sample_len) }, .{ .expand = .horizontal });
        keep(&sample, &sample_len, te.textGet());
        te.deinit();
        if (dvui.button(@src(), if (overlay) "Side by side" else "Overlay", .{}, .{})) overlay = !overlay;
    }
    // The selected font joins the comparison until pinned or replaced.
    var shown: std.ArrayList(usize) = .empty;
    shown.appendSlice(a, pinned.items) catch {};
    if (selected) |s| if (!isPinned(s)) shown.append(a, s) catch {};
    // One cap height for all, the widest sample fitting the column.
    var widest: f64 = 0;
    for (shown.items) |i| if (sampleLines(a, i, 0.01)) |sl| {
        widest = @max(widest, sl.width);
    };
    const room: f64 = @max(50, width - 40);
    if (shown.items.len == 0) {
        dvui.labelNoFmt(@src(), "Select a font, or pin several, to compare them here.", .{}, .{ .margin = .{ .y = 12 } });
    } else if (overlay) {
        drawOverlay(a, shown.items, width);
    } else {
        const cap: f32 = @floatCast(@min(48, if (widest > 0) room / widest else 48));
        for (shown.items, 0..) |i, k| drawRow(a, i, k, cap);
    }
    if (selected) |s| details(s);
}

fn sampleText() []const u8 {
    const s = text(&sample, sample_len);
    return if (s.len == 0) default_sample else s;
}

/// The sample set in record `i`'s face at a cap height of 1 (y up), as
/// flattened polylines per glyph, and its width.
fn sampleLines(a: Allocator, i: usize, tol: f64) ?struct { glyphs: []const []const []const geom.Point, width: f64 } {
    const face = faceOf(i) orelse return null;
    const fl = [_]*engine.Face{face};
    var r = engine.renderRun(gpa, &fl, 0, sampleText(), .{ .cap_height = 1 }) catch return null;
    defer r.deinit();
    const outlines = r.outlines(a, &fl) catch return null;
    const glyphs = a.alloc([]const []const geom.Point, outlines.len) catch return null;
    var width: f64 = 0;
    for (outlines, glyphs) |o, *g| {
        const polys = a.alloc([]const geom.Point, o.contours.len) catch return null;
        for (o.contours, polys) |c, *poly| {
            var pts: std.ArrayList(geom.Point) = .empty;
            for (c.segments) |s| flatten(a, &pts, s, tol) catch return null;
            poly.* = pts.items;
            for (pts.items) |p| width = @max(width, p.x);
        }
        g.* = polys;
    }
    return .{ .glyphs = glyphs, .width = width };
}

/// Appends a segment's points after its start, within `tol`.
fn flatten(a: Allocator, pts: *std.ArrayList(geom.Point), s: geom.Segment, tol: f64) !void {
    switch (s) {
        .line => |p| try pts.append(a, p[1]),
        inline .quad, .cubic => |p| {
            var len: f64 = 0;
            for (1..p.len) |k| len += @sqrt((p[k].x - p[k - 1].x) * (p[k].x - p[k - 1].x) + (p[k].y - p[k - 1].y) * (p[k].y - p[k - 1].y));
            const n: usize = @intFromFloat(@min(64, @max(2, @ceil(@sqrt(len / @max(tol, 1e-9))))));
            for (1..n + 1) |k| {
                const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, if (p.len == 3) .{
                    .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x,
                    .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y,
                } else .{
                    .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
                    .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
                });
            }
        },
    }
}

const Place = struct {
    x: f32,
    baseline: f32,
    cap: f32,

    fn px(p: Place, q: geom.Point) dvui.Point.Physical {
        return .{ .x = p.x + @as(f32, @floatCast(q.x)) * p.cap, .y = p.baseline - @as(f32, @floatCast(q.y)) * p.cap };
    }
};

/// Baseline, x-height and cap-height guides across `r` for record `i`.
fn guides(r: dvui.Rect.Physical, place: Place, i: usize, color: dvui.Color) void {
    const x_ratio: f32 = records[i].measures.x orelse 0;
    for ([_]f32{ 0, x_ratio, 1 }) |h| {
        if (h == 0 and x_ratio == 0 and false) continue;
        const y = place.baseline - h * place.cap;
        dvui.Path.stroke(.{ .points = &.{ .{ .x = r.x, .y = y }, .{ .x = r.x + r.w, .y = y } } }, .{ .thickness = 1, .color = .{ .color = color } });
    }
}

fn fillGlyphs(a: Allocator, glyphs: []const []const []const geom.Point, place: Place, color: dvui.Color, tol: f64) void {
    const lifo = dvui.currentWindow().lifo();
    for (glyphs) |polys| {
        const region = geom.fill.nonzero(a, polys, tol * 0.1) catch continue;
        if (region.triangles.len == 0) continue;
        var b = dvui.Triangles.Builder.init(lifo, 3 * region.triangles.len, 3 * region.triangles.len) catch continue;
        defer b.deinit(lifo);
        for (region.triangles, 0..) |t, k| {
            var v: [3]dvui.Point.Physical = undefined;
            for (t, &v) |q, *out| out.* = place.px(q);
            for (v) |pos| b.appendVertex(.{ .pos = pos, .col = .fromColor(color) });
            const idx: dvui.Vertex.Index = @intCast(3 * k);
            const cross = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x);
            b.appendTriangles(&(if (cross <= 0) [3]dvui.Vertex.Index{ idx, idx + 1, idx + 2 } else .{ idx, idx + 2, idx + 1 }));
        }
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
}

fn strokeGlyphs(glyphs: []const []const []const geom.Point, place: Place, color: dvui.Color, width: f32) void {
    const lifo = dvui.currentWindow().lifo();
    for (glyphs) |polys| for (polys) |poly| {
        if (poly.len < 2) continue;
        const pts = lifo.alloc(dvui.Point.Physical, poly.len) catch return;
        defer lifo.free(pts);
        for (poly, pts) |q, *o| o.* = place.px(q);
        dvui.Path.stroke(.{ .points = pts }, .{ .thickness = width, .color = .{ .color = color }, .closed = true });
    };
}

/// One font's sample on its own row, over its guides.
fn drawRow(a: Allocator, i: usize, k: usize, cap: f32) void {
    var nb: [128]u8 = undefined;
    const r = &records[i];
    dvui.labelNoFmt(@src(), std.fmt.bufPrint(&nb, "{s} {s}{s}", .{ r.family, r.style, if (isPinned(i)) "" else "  (selected)" }) catch r.family, .{}, .{ .id_extra = k, .margin = .{ .y = 6 } });
    var box = dvui.box(@src(), .{}, .{ .id_extra = k, .expand = .horizontal, .min_size_content = .{ .h = cap * 2 }, .background = true, .color_fill = .{ .color = paper } });
    defer box.deinit();
    const rect = box.data().contentRectScale().r;
    const place: Place = .{ .x = rect.x + 8, .baseline = rect.y + rect.h * 0.72, .cap = cap * box.data().contentRectScale().s };
    const tol = 0.4 / @as(f64, place.cap);
    guides(rect, place, i, .{ .r = 0x2f, .g = 0x8a, .b = 0x4e, .a = 0x60 });
    const s = sampleLines(a, i, tol) orelse {
        dvui.labelNoFmt(@src(), "This font could not be loaded.", .{}, .{ .id_extra = k });
        return;
    };
    fillGlyphs(a, s.glyphs, place, compare_colors[0], tol);
}

/// The compared fonts overlaid glyph by glyph: each character of the sample
/// in a cell of its own, every font's glyph centred in it on one baseline
/// and cap height, outlined in its own colour and weight (heavier first),
/// so shapes compare directly whatever the fonts' spacing.
fn drawOverlay(a: Allocator, shown: []const usize, width: f32) void {
    {
        var key = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
        defer key.deinit();
        for (shown, 0..) |i, k| {
            const c = compare_colors[k % compare_colors.len];
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = k });
            defer line.deinit();
            var sw = dvui.box(@src(), .{}, .{ .id_extra = k, .min_size_content = .{ .w = 22, .h = overlayWidth(shown.len, k) + 1 }, .background = true, .color_fill = .{ .color = c }, .gravity_y = 0.5, .margin = .{ .w = 4 } });
            sw.deinit();
            var nb: [128]u8 = undefined;
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&nb, "{s} {s}", .{ records[i].family, records[i].style }) catch "", .{}, .{ .id_extra = k, .color_text = .{ .color = c }, .margin = .{ .w = 14 } });
        }
    }
    const chars = codepoints(a, sampleText());
    const n_chars = @min(chars.len, 32);
    if (n_chars == 0) return;
    const cap_lp: f32 = 44;
    const cell_w: f32 = cap_lp * 1.6;
    const cell_h: f32 = cap_lp * 2.1;
    const per_row: usize = @max(1, @as(usize, @intFromFloat(@floor((width - 24) / cell_w))));
    const rows = (n_chars + per_row - 1) / per_row;
    var box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = cell_h * @as(f32, @floatFromInt(rows)) }, .background = true, .color_fill = .{ .color = paper } });
    defer box.deinit();
    const rs = box.data().contentRectScale();
    const s = rs.s;
    const cap = cap_lp * s;
    const tol = 0.4 / @as(f64, cap);
    const guide: dvui.Color = .{ .r = 0x2f, .g = 0x8a, .b = 0x4e, .a = 0x50 };
    const x_ratio: f32 = records[shown[0]].measures.x orelse 0;
    for (chars[0..n_chars], 0..) |cp, ci| {
        const col: f32 = @floatFromInt(ci % per_row);
        const row: f32 = @floatFromInt(ci / per_row);
        const cx = rs.r.x + (12 + col * cell_w + cell_w / 2) * s;
        const top = rs.r.y + row * cell_h * s;
        const baseline = top + cap * 1.55;
        // The cell's guides: baseline, x-height (of the first font), cap.
        for ([_]f32{ 0, x_ratio, 1 }) |h| {
            const y = baseline - h * cap;
            dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - cell_w * s * 0.45, .y = y }, .{ .x = cx + cell_w * s * 0.45, .y = y } } }, .{ .thickness = 1, .color = .{ .color = guide } });
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        for (shown, 0..) |fi, k| {
            const g = glyphLines(a, fi, buf[0..len], tol) orelse continue;
            const place: Place = .{ .x = cx - @as(f32, @floatCast((g.x0 + g.x1) / 2)) * cap, .baseline = baseline, .cap = cap };
            if (k == 0) fillGlyphs(a, g.lines, place, compare_colors[0].opacity(0.10), tol);
            strokeGlyphs(g.lines, place, compare_colors[k % compare_colors.len], overlayWidth(shown.len, k) * s);
        }
    }
}

/// Stroke weight of the `k`th of `n` overlaid fonts: the first heaviest.
fn overlayWidth(n: usize, k: usize) f32 {
    return 1.0 + 0.5 * @as(f32, @floatFromInt(n - 1 - k));
}

/// One character in record `i`'s face at cap height 1, flattened, with its
/// ink's horizontal extent.
fn glyphLines(a: Allocator, i: usize, ch: []const u8, tol: f64) ?struct { lines: []const []const []const geom.Point, x0: f64, x1: f64 } {
    const face = faceOf(i) orelse return null;
    const fl = [_]*engine.Face{face};
    var r = engine.renderRun(gpa, &fl, 0, ch, .{ .cap_height = 1 }) catch return null;
    defer r.deinit();
    const outlines = r.outlines(a, &fl) catch return null;
    const glyphs = a.alloc([]const []const geom.Point, outlines.len) catch return null;
    var x0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    for (outlines, glyphs) |o, *g| {
        const polys = a.alloc([]const geom.Point, o.contours.len) catch return null;
        for (o.contours, polys) |c, *poly| {
            var pts: std.ArrayList(geom.Point) = .empty;
            for (c.segments) |seg| flatten(a, &pts, seg, tol) catch return null;
            poly.* = pts.items;
            for (pts.items) |p| {
                x0 = @min(x0, p.x);
                x1 = @max(x1, p.x);
            }
        }
        g.* = polys;
    }
    if (x0 > x1) return null;
    return .{ .lines = glyphs, .x0 = x0, .x1 = x1 };
}

/// What is known about the selected font, with where each fact came from.
fn details(i: usize) void {
    const r = &records[i];
    heading(@src(), "Selected font");
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
    defer tl.deinit();
    var buf: [1200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const m = r.measures;
    w.print("{s} {s}. Weight {d:.0}, width {d:.0}%, {s}{s}{s}{s}; {d} glyphs.\n", .{
        r.family,                                         r.style,                              r.weight,                           r.width,
        if (r.italic) "italic" else "upright",            if (r.monospace) ", monospaced" else "", if (r.variable) ", variable" else "", if (r.math) ", has a MATH table" else "",
        r.glyphs,
    }) catch {};
    w.writeAll("Measured from its outlines:") catch {};
    if (m.x) |v| w.print(" x-height {d:.2} of cap height,", .{v}) catch {};
    if (m.stem) |v| w.print(" stem {d:.3},", .{v}) catch {};
    if (m.contrast) |v| w.print(" contrast {d:.2},", .{v}) catch {};
    if (m.width) |v| w.print(" width {d:.2},", .{v}) catch {};
    if (m.serif) |v| w.print(" {s}.", .{if (v) "serifs" else "no serifs"}) catch {};
    w.print("\nEmbedding, as the font's OS/2 table states it: {s}. Licence, as its name table states it: {s}.", .{ embedName(r.embedding), licenceName(r.licence) }) catch {};
    if (r.licence_text.len > 0) w.print(" \"{s}\"", .{r.licence_text[0..@min(r.licence_text.len, 300)]}) catch {};
    w.print("\nFrom {s}: {s}", .{ r.source, r.location }) catch {};
    tl.addText(w.buffered(), .{ .font = dvui.Font.theme(.body).larger(-1) });
}

// Composition ------------------------------------------------------------------

fn nameOf(i: usize) model.FontName {
    return .{ .family = records[i].family, .style = records[i].style };
}

/// The characters of `s` as sorted, merged codepoint ranges.
fn rangesOf(a: Allocator, s: []const u8) []engine.style.Range {
    const cps = codepoints(a, s);
    std.mem.sort(u21, cps, {}, std.sort.asc(u21));
    var out: std.ArrayList(engine.style.Range) = .empty;
    for (cps) |cp| {
        if (out.items.len > 0 and out.items[out.items.len - 1].last + 1 == cp) {
            out.items[out.items.len - 1].last = cp;
        } else out.append(a, .{ .first = cp, .last = cp }) catch break;
    }
    return out.items;
}

fn compose(host: Host) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 300 }, .max_size_content = .width(300), .expand = .vertical, .padding = .all(8) });
    defer col.deinit();
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    var bar_room = keepBarRoom(@src());
    defer bar_room.deinit();
    const m = host.model;
    heading(@src(), "Compose");
    // Which composed font: the document's, or a new one.
    if (target) |t| if (m.fontIndex(t) == null) {
        target = null;
    };
    if (target == null and m.fonts.items.len > 0) target = m.fonts.items[0].id;
    const a = dvui.currentWindow().arena();
    if (m.fonts.items.len > 0) {
        const names = a.alloc([]const u8, m.fonts.items.len) catch return;
        var choice: usize = 0;
        for (m.fonts.items, names, 0..) |f, *n, k| {
            n.* = f.name;
            if (target != null and f.id == target.?) choice = k;
        }
        if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) target = m.fonts.items[choice].id;
    } else dvui.labelNoFmt(@src(), "The document has no composed fonts yet.", .{}, .{});
    const sel = selected;
    if (sel) |s| {
        var nb: [128]u8 = undefined;
        if (dvui.button(@src(), std.fmt.bufPrint(&nb, "New composed font from {s} {s}", .{ records[s].family, records[s].style }) catch "New composed font", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4 } })) {
            if (host.addFont(records[s].family, nameOf(s))) |id| target = id;
        }
    }
    const t = target orelse {
        dvui.labelNoFmt(@src(), "Select a font to start one.", .{}, .{});
        return;
    };
    const cf = m.fonts.items[m.fontIndex(t).?];
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .margin = .{ .y = 6 } });
        defer tl.deinit();
        var buf: [256]u8 = undefined;
        tl.addText(std.fmt.bufPrint(&buf, "Main: {s} {s}\nItalic: ", .{ cf.main.family, cf.main.style }) catch "", .{});
        if (cf.italic) |it| tl.addText(std.fmt.bufPrint(&buf, "{s} {s}", .{ it.family, it.style }) catch "", .{}) else tl.addText("none", .{});
    }
    if (sel) |s| {
        if (dvui.button(@src(), "Use selected as main", .{}, .{ .expand = .horizontal })) host.setFontMain(t, nameOf(s), cf.italic);
        if (dvui.button(@src(), "Use selected as italic", .{}, .{ .expand = .horizontal })) host.setFontMain(t, cf.main, nameOf(s));
    }
    heading(@src(), "Members, in order tried");
    if (cf.members.items.len == 0) dvui.labelNoFmt(@src(), "None yet.", .{}, .{});
    for (cf.members.items, 0..) |mb, k| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = k, .expand = .horizontal, .margin = .{ .h = 2 } });
        defer row.deinit();
        var buf: [160]u8 = undefined;
        const what = switch (mb.coverage) {
            .fallback => "fallback",
            .ranges => |rs| std.fmt.bufPrint(buf[100..], "{d} range{s}", .{ rs.len, if (rs.len == 1) "" else "s" }) catch "ranges",
        };
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(buf[0..100], "{s} {s} ({s})", .{ mb.font.family, mb.font.style, what }) catch "", .{}, .{ .expand = .horizontal, .gravity_y = 0.5 });
        // Icons: the interface font has no arrows.
        if (dvui.buttonIcon(@src(), "Earlier", dvui.entypo.chevron_up, .{}, .{}, .{})) host.moveFontMember(t, k, true);
        if (dvui.buttonIcon(@src(), "Later", dvui.entypo.chevron_down, .{}, .{}, .{})) host.moveFontMember(t, k, false);
        if (dvui.buttonIcon(@src(), "Remove", dvui.entypo.cross, .{}, .{}, .{})) host.removeFontMember(t, k);
    }
    if (sel) |s| {
        if (dvui.button(@src(), "Add selected as a fallback", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4 } })) host.addFontMember(t, .{ .font = nameOf(s) });
        const want = text(&covers, covers_len);
        if (want.len > 0) {
            var buf: [160]u8 = undefined;
            if (dvui.button(@src(), std.fmt.bufPrint(&buf, "Add selected for {s}", .{want[0..@min(want.len, 40)]}) catch "Add selected for these characters", .{}, .{ .expand = .horizontal })) {
                host.addFontMember(t, .{ .font = nameOf(s), .coverage = .{ .ranges = rangesOf(a, want) } });
            }
        } else dvui.labelNoFmt(@src(), "Type characters under Search to add the selected font just for them.", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
    }
    heading(@src(), "Set a style in it");
    if (m.styles.items.len == 0) {
        dvui.labelNoFmt(@src(), "The document has no styles yet.", .{}, .{});
        return;
    }
    const snames = a.alloc([]const u8, m.styles.items.len) catch return;
    for (m.styles.items, snames) |st, *n| n.* = st.name;
    style_choice = @min(style_choice, snames.len - 1);
    _ = dvui.dropdown(@src(), snames, .{ .choice = &style_choice }, .{}, .{ .expand = .horizontal });
    const st = m.styles.items[style_choice];
    if (st.font == t) {
        dvui.labelNoFmt(@src(), "Set in this composed font.", .{}, .{});
    } else if (dvui.button(@src(), "Set the style in this composed font", .{}, .{ .expand = .horizontal })) {
        host.setStyleFont(@intCast(style_choice), t);
    }
}
