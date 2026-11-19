//! The fonts window: find, compare and choose fonts, and set them as the
//! faces of the document's text styles. A window of its own, apart from the
//! canvas and its panes; Text › Fonts… opens it.
//!
//! Search criteria on the left, results in the middle, the comparison of
//! pinned fonts on the right, and the composition being built at the far
//! right. Fonts come from the local source's index (system and user
//! fonts), grouped by family; remote sources come later through the same
//! API. Font files are installed as user fonts here, and user font files
//! removed, the removal saying first what goes with the file.

const std = @import("std");
const display = @import("display.zig");
const keymap = @import("keymap.zig");
const dvui = @import("dvui");
const layout = @import("graven_layout");
const fs = @import("graven_fontsearch");
const local = @import("graven_fonts_local");
const icons = @import("icons.zig");

const geom = layout.geom;
const model = layout.model;
const Allocator = std.mem.Allocator;
const ObjectId = model.ObjectId;

/// Whether the window is open; closing it clears this.
pub var open = false;

/// What the window needs from the editor: the document, and the actions it
/// takes on it (each undoable there).
pub const Host = struct {
    model: *const layout.Model,
    /// Sets the font style `style` sets role `role` in (null: none).
    setStyleFace: *const fn (style: model.StyleId, role: []const u8, font: ?model.FontName) void,
    /// A family's regular as the text face and its italic and bolds, as
    /// one change.
    setStyleFamily: *const fn (style: model.StyleId, main: model.FontName, variants: Variants) void,
};

/// A family's other weights and slants beside its regular face.
pub const Variants = struct {
    italic: ?model.FontName = null,
    bold: ?model.FontName = null,
    bold_italic: ?model.FontName = null,
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
var faces: std.AutoHashMapUnmanaged(usize, *layout.Face) = .empty;

/// The index's generation: each scan makes a new one. The editor resolves
/// its fonts again when it changes; faces of an earlier generation, which
/// it may still hold, are kept (retired) until it has (`releaseRetired`).
pub var generation: u32 = 0;
var retired: std.ArrayList(*layout.Face) = .empty;

/// What a font file holds: its faces (all of them, by width, weight and
/// slope), and for a variable face its ranges and named styles. Made when
/// first shown, in the index's arena, for the current generation.
const FileInfo = struct {
    faces: []const usize,
    wght: ?[2]f32 = null,
    wdth: ?[2]f32 = null,
    named: []const []const u8 = &.{},
};
var file_info: std.StringHashMapUnmanaged(FileInfo) = .empty;
var file_info_gen: u32 = 0;

fn fileInfo(loc: []const u8) ?FileInfo {
    const a = (index_arena orelse return null).allocator();
    if (file_info_gen != generation) {
        // The last generation's lived in the arena that went with it.
        file_info = .empty;
        file_info_gen = generation;
    }
    if (file_info.get(loc)) |fi| return fi;
    const in_file = local.facesInFile(a, records, loc) catch return null;
    std.mem.sort(usize, in_file, {}, byShape);
    var fi: FileInfo = .{ .faces = in_file };
    for (in_file) |j| {
        if (!records[j].variable) continue;
        const face = faceOf(j) orelse continue;
        if (face.axis("wght")) |ax| fi.wght = .{ ax.min, ax.max };
        if (face.axis("wdth")) |ax| fi.wdth = .{ ax.min, ax.max };
        fi.named = face.namedInstances(a) catch &.{};
        break;
    }
    file_info.put(a, loc, fi) catch return fi;
    return fi;
}

/// Frees the faces of earlier generations. The editor calls it once its
/// fonts are resolved against the current one.
pub fn releaseRetired() void {
    for (retired.items) |f| f.deinit();
    retired.clearAndFree(gpa);
}

/// The installed fonts' records: the saved index, or a fresh scan when
/// there is none. `rescan` scans again (describing only what changed).
pub fn indexRecords(allocator: Allocator, rescan: bool) []fs.Record {
    gpa = allocator;
    if (index_arena != null and !rescan) return records;
    // Faces first: the arena holds the records they were loaded from.
    dropFaces();
    if (index_arena) |*a| a.deinit();
    index_arena = .init(gpa);
    generation +%= 1;
    const a = index_arena.?.allocator();
    records = if (rescan) &.{} else local.load(dvui.io, a);
    if (records.len == 0) {
        records = local.build(dvui.io, gpa, a, &report) catch &.{};
        status = std.fmt.bufPrint(&status_buf, "{d} fonts: {d} described, {d} unchanged, {d} unreadable.", .{ records.len, report.described, report.kept, report.failed }) catch "";
    } else status = std.fmt.bufPrint(&status_buf, "{d} fonts, from the saved index.", .{records.len}) catch "";
    return records;
}

/// Everything the window holds: the faces loaded, retired or not, and the
/// index (records, file infos). At exit, or before starting again.
pub fn deinit() void {
    if (index_arena == null) return;
    dropFaces();
    releaseRetired();
    retired.deinit(gpa);
    retired = .empty;
    if (index_arena) |*a| a.deinit();
    index_arena = null;
    records = &.{};
}

fn dropFaces() void {
    var it = faces.valueIterator();
    while (it.next()) |f| retired.append(gpa, f.*) catch f.*.deinit();
    faces.clearAndFree(gpa);
}

/// Scans again, keeping the selection, the likeness reference and the pins
/// where their fonts still are.
fn reindex(allocator: Allocator) void {
    const Key = struct { loc: []u8, index: u32 };
    const keyOf = struct {
        fn f(i: ?usize) ?Key {
            const k = i orelse return null;
            return .{ .loc = gpa.dupe(u8, records[k].location) catch return null, .index = records[k].index };
        }
    }.f;
    const find = struct {
        fn f(key: ?Key) ?usize {
            const k = key orelse return null;
            for (records, 0..) |r, i| if (r.index == k.index and std.mem.eql(u8, r.location, k.loc)) return i;
            return null;
        }
    }.f;
    const sel = keyOf(selected);
    const lk = keyOf(like);
    var pins: [max_pinned]?Key = @splat(null);
    for (pinned.items, 0..) |p, k| pins[k] = keyOf(p);
    defer for ([_]?Key{ sel, lk } ++ pins) |k| if (k) |kk| gpa.free(kk.loc);
    _ = indexRecords(allocator, true);
    selected = find(sel);
    like = find(lk);
    pinned.clearRetainingCapacity();
    for (pins) |p| if (find(p)) |i| pinned.append(gpa, i) catch {};
}

/// The face record `i` describes, loaded once and kept.
pub fn faceOf(i: usize) ?*layout.Face {
    if (faces.get(i)) |f| return f;
    const r = &records[i];
    const bytes = local.read(dvui.io, gpa, r) catch return null;
    defer gpa.free(bytes);
    const f = layout.Face.init(gpa, bytes, r.index) catch return null;
    faces.put(gpa, i, f) catch {
        f.deinit();
        return null;
    };
    return f;
}

/// The catalog the document's styles' fonts are resolved against: the
/// installed fonts by family and style.
pub fn catalog(a: Allocator) ?layout.fonts.Catalog {
    if (records.len == 0) return null;
    const names = a.alloc(model.FontName, records.len) catch return null;
    for (records, names) |r, *n| n.* = .{ .family = r.family, .style = r.style };
    return .{ .names = names, .ctx = undefined, .load = struct {
        fn load(_: *anyopaque, i: usize) ?*layout.Face {
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
/// The style whose faces are being set.
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
    var ow = dvui.osWindow(@src(), .{ .title = "Fonts — Graven", .size = .{ .w = 1560, .h = 860 }, .min_size = .{ .w = 900, .h = 560 } }, .{ .open_flag = &open });
    defer ow.deinit();
    if (index_arena == null) _ = indexRecords(allocator, false);

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(6) });
        defer top.deinit();
        dvui.labelNoFmt(@src(), status, .{}, .{ .gravity_y = 0.5 });
        if (icons.button(@src(), .x, "Close the fonts window", .{ .opts = .{ .gravity_x = 1 } })) open = false;
        if (icons.button(@src(), .arrows_clockwise, "Scan system and user fonts again", .{ .opts = .{ .gravity_x = 1 } })) reindex(allocator);
        if (icons.button(@src(), .download_simple, "Install font files as user fonts…", .{ .opts = .{ .gravity_x = 1 } })) {
            install_open = true;
            install_new = true;
            install_report.clearRetainingCapacity();
        }
    }
    // Search across the top; below it, the results tree and the comparison
    // side by side, and the composition beside them.
    criteria();
    var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer cols.deinit();
    const a = dvui.currentWindow().arena();
    const total = cols.data().contentRect().w;
    const results_w = @max(520, (total - (300 + 16)) * 0.6);
    const rest = @max(300, total - (results_w + 16) - (300 + 16) - 16);
    const hits = results(a, results_w);
    _ = hits;
    compare(a, rest);
    compose(host);
    if (install_open) installPrompt(allocator, root.data().rect);
    if (removing) |i| removePrompt(host, allocator, i, root.data().rect);
}

// Search criteria --------------------------------------------------------------

fn criteria() void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 8, .w = 8, .h = 6 }, .background = true, .style = .control });
    defer strip.deinit();
    {
        // What to find: words, characters, likeness.
        var g = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 330 }, .max_size_content = .width(330), .padding = .{ .w = 16 } });
        defer g.deinit();
        heading(@src(), "Search");
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Words", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 82 } });
            var te = dvui.textEntry(@src(), .{ .text_initial = text(&words, words_len), .placeholder = "in the family or style name" }, .{ .expand = .horizontal });
            defer te.deinit();
            keep(&words, &words_len, te.textGet());
        }
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Characters", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 82 } });
            var te = dvui.textEntry(@src(), .{ .text_initial = text(&covers, covers_len), .placeholder = "it must have" }, .{ .expand = .horizontal });
            defer te.deinit();
            keep(&covers, &covers_len, te.textGet());
        }
        _ = dvui.checkbox(@src(), &allow_missing, "Also fonts missing some", .{});
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Like", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 82 } });
            if (like) |l| {
                var buf: [96]u8 = undefined;
                dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "{s} {s}", .{ records[l].family, records[l].style }) catch "", .{}, .{ .gravity_y = 0.5 });
                if (icons.button(@src(), .x_circle, "Stop ranking by likeness", .{ .opts = .{ .gravity_x = 1 } })) like = null;
            } else dvui.labelNoFmt(@src(), "any", .{}, .{ .gravity_y = 0.5 });
            if (selected) |sl| if (like == null or like.? != sl) {
                if (icons.button(@src(), .magnet, "Rank by likeness to the selected font", .{ .opts = .{ .gravity_x = 1 } })) like = sl;
            };
        }
    }
    {
        var g = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 260 }, .max_size_content = .width(260), .padding = .{ .w = 16 } });
        defer g.deinit();
        heading(@src(), "Style");
        _ = dvui.dropdown(@src(), &.{ "Serif or sans", "Serif", "Sans" }, .{ .choice = &serif_choice }, .{}, .{ .expand = .horizontal });
        _ = dvui.dropdown(@src(), &.{ "Upright or italic", "Upright", "Italic" }, .{ .choice = &slant_choice }, .{}, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer row.deinit();
            _ = dvui.checkbox(@src(), &mono, "Mono", .{});
            _ = dvui.checkbox(@src(), &math, "Math", .{});
            _ = dvui.checkbox(@src(), &variable, "Variable", .{});
        }
    }
    {
        var g = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer g.deinit();
        heading(@src(), "Licence terms");
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Embedding at least", .{}, .{ .gravity_y = 0.5 });
            _ = dvui.dropdown(@src(), &.{ "Any", "Installable", "Editable", "Preview and print" }, .{ .choice = &embed_choice }, .{}, .{ .min_size_content = .{ .w = 150 } });
        }
        {
            // Licences in a row (none ticked: any).
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 4 } });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Licence", .{}, .{ .gravity_y = 0.5 });
            for (licence_names, 0..) |n, i| _ = dvui.checkbox(@src(), &licences[i], n, .{ .id_extra = i });
        }
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .margin = .{ .y = 2 } });
        tl.addText("None ticked: any. Terms are shown as each font states them; Graven does not set them, or judge what your own licence allows.", .{ .font = dvui.Font.theme(.body).larger(-2) });
        tl.deinit();
    }
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

/// Families shown open or closed by the user, by name in lower case
/// (others follow the default: open when the results are few).
var family_open: std.StringHashMapUnmanaged(bool) = .empty;
/// At most this many faces in the results, and families start open.
const open_by_default = 60;

fn familyIsOpen(name: []const u8, default: bool) bool {
    var buf: [256]u8 = undefined;
    const key = std.ascii.lowerString(buf[0..@min(name.len, buf.len)], name[0..@min(name.len, buf.len)]);
    return family_open.get(key) orelse default;
}

fn setFamilyOpen(name: []const u8, v: bool) void {
    const key = std.ascii.allocLowerString(gpa, name) catch return;
    const e = family_open.getOrPut(gpa, key) catch return gpa.free(key);
    if (e.found_existing) gpa.free(key);
    e.value_ptr.* = v;
}

/// The installed records of each family, by name (all of them, not only
/// those a search finds): made once per index.
var family_index: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
var family_index_of: ?[*]fs.Record = null;
/// Each record's sample letter for the style icons, flattened at a cap
/// height of 1: made once per index.
var icon_glyphs: std.AutoHashMapUnmanaged(usize, ?Glyphs) = .empty;
var icon_arena: ?std.heap.ArenaAllocator = null;
const Glyphs = struct { lines: []const []const []const geom.Point, x0: f64, x1: f64 };

/// The letter the style icons show.
const icon_letter = "a";
/// A style icon's side and its letter's cap height, logical pixels.
const icon_side = 22;
const icon_cap = 11;

fn familyMembers(family: []const u8) []const usize {
    if (family_index_of != records.ptr) {
        var it = family_index.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        family_index.clearRetainingCapacity();
        for (records, 0..) |r, i| {
            const e = family_index.getOrPut(gpa, r.family) catch continue;
            if (!e.found_existing) e.value_ptr.* = .empty;
            e.value_ptr.append(gpa, i) catch {};
        }
        if (icon_arena) |*ia| ia.deinit();
        icon_arena = .init(gpa);
        icon_glyphs.clearRetainingCapacity();
        family_index_of = records.ptr;
    }
    return if (family_index.get(family)) |l| l.items else &.{};
}

/// The member that stands for a style: upright or italic, regular (weight
/// 300 to 500, nearest 400) or bold (600 and up, nearest 700).
fn styleMember(members: []const usize, italic: bool, bold: bool) ?usize {
    var best: ?usize = null;
    var best_d: f32 = std.math.inf(f32);
    for (members) |i| {
        const r = &records[i];
        if (r.italic != italic) continue;
        const ok = if (bold) r.weight >= 600 else (r.weight >= 300 and r.weight <= 500) or r.variable;
        if (!ok) continue;
        const d = @abs(r.weight - @as(f32, if (bold) 700 else 400));
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

fn iconGlyphs(i: usize) ?Glyphs {
    if (icon_glyphs.get(i)) |g| return g;
    const a = icon_arena.?.allocator();
    const g: ?Glyphs = if (glyphLines(a, i, icon_letter, 0.4 / @as(f64, icon_cap))) |gl| .{ .lines = gl.lines, .x0 = gl.x0, .x1 = gl.x1 } else null;
    icon_glyphs.put(gpa, i, g) catch {};
    return g;
}

/// Whether a press landed on `data` this frame (and takes it).
fn pressed(data: *dvui.WidgetData) bool {
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, data)) continue;
        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            e.handle(@src(), data);
            dvui.refresh(null, @src(), data.id);
            return true;
        }
    }
    return false;
}

/// A style icon: the sample letter in record `rec`'s face, or an empty box
/// when the family has no such style. A click selects the record.
fn styleIcon(id: usize, rec: ?usize, name: []const u8, visible: bool) void {
    const t = dvui.themeGet();
    const sel = rec != null and selected != null and selected.? == rec.?;
    var box = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = icon_side, .h = icon_side },
        .max_size_content = .size(.{ .w = icon_side, .h = icon_side }),
        .background = true,
        .border = .all(1),
        .color_border = .{ .color = if (sel) t.focus else t.color(.control, .border) },
        .color_fill = .{ .color = if (rec != null) display.fix(paper) else t.color(.window, .fill) },
        .margin = .{ .w = 2 },
        .gravity_y = 0.5,
        .label = .{ .text = name },
    });
    defer box.deinit();
    const r = rec orelse return;
    if (pressed(box.data())) selected = r;
    if (!visible) return;
    const g = iconGlyphs(r) orelse return;
    const rs = box.data().contentRectScale();
    const cap: f32 = icon_cap * rs.s;
    const cx = rs.r.x + rs.r.w / 2;
    const place: Place = .{ .x = cx - @as(f32, @floatCast((g.x0 + g.x1) / 2)) * cap, .baseline = rs.r.y + rs.r.h * 0.78, .cap = cap };
    fillGlyphs(dvui.currentWindow().arena(), g.lines, place, compare_colors[0], 0.4 / @as(f64, cap));
}

/// A weight box: the weight's number (VF for a variable font); a click
/// selects the record.
fn weightBox(id: usize, rec: usize) void {
    const t = dvui.themeGet();
    const r = &records[rec];
    const sel = selected != null and selected.? == rec;
    var buf: [8]u8 = undefined;
    const label = if (r.variable) "VF" else std.fmt.bufPrint(&buf, "{d:.0}", .{r.weight}) catch "?";
    var box = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 26, .h = icon_side },
        .max_size_content = .size(.{ .w = 26, .h = icon_side }),
        .background = true,
        .border = .all(1),
        .color_border = .{ .color = if (sel) t.focus else t.color(.control, .border) },
        .color_fill = .{ .color = t.color(.control, .fill) },
        .margin = .{ .w = 2 },
        .gravity_y = 0.5,
    });
    defer box.deinit();
    if (pressed(box.data())) selected = rec;
    dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = id, .gravity_x = 0.5, .gravity_y = 0.5, .padding = .{}, .font = dvui.Font.theme(.body).larger(-3) });
}

/// Weights of `members` with the slant asked for, ascending, one record
/// each.
fn weightsOf(a: Allocator, members: []const usize, italic: bool) []const usize {
    var out: std.ArrayList(usize) = .empty;
    for (members) |i| {
        const r = &records[i];
        if (r.italic != italic) continue;
        const dup = for (out.items) |j| {
            if (records[j].weight == r.weight and records[j].variable == r.variable) break true;
        } else false;
        if (!dup) out.append(a, i) catch {};
    }
    std.mem.sort(usize, out.items, {}, struct {
        fn lt(_: void, x: usize, y: usize) bool {
            return records[x].weight < records[y].weight;
        }
    }.lt);
    return out.items;
}

/// Room before a family's style groups: its disclosure and its name.
const name_room = 18 + 150;

/// A style group's width: two style icons and `n` weight boxes, and a gap.
fn groupWidth(n: usize) f64 {
    return 2 * (icon_side + 2) + @as(f64, @floatFromInt(n)) * 30 + 10;
}

/// One slant's group: its regular and bold icons, then its weights.
/// Returns where it starts in its row, logical pixels.
fn styleGroup(fk: usize, si: usize, members: []const usize, italic: bool, weights: []const usize, visible: bool) f32 {
    var g = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = fk * 2 + si, .gravity_y = 0.5, .min_size_content = .{ .w = @floatCast(groupWidth(weights.len)) } });
    defer g.deinit();
    const x = g.data().rect.x;
    styleIcon(fk * 8 + si * 2, styleMember(members, italic, false), if (italic) "Italic" else "Regular", visible);
    styleIcon(fk * 8 + si * 2 + 1, styleMember(members, italic, true), if (italic) "Bold Italic" else "Bold", visible);
    for (weights, 0..) |w, wk| weightBox((fk * 2 + si) * 64 + wk, w);
    return x;
}

fn results(a: Allocator, width: f32) []const fs.Hit {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = width }, .max_size_content = .width(width), .expand = .vertical, .padding = .all(8) });
    defer col.deinit();
    const q = query(a);
    const hits = fs.search(a, records, q) catch &.{};
    // Families in the order of their best-ranked face, faces in each by
    // width, weight and slope.
    const by_record = a.alloc(?fs.Hit, records.len) catch return hits;
    @memset(by_record, null);
    const subset = a.alloc(usize, hits.len) catch return hits;
    for (hits, subset) |h, *i| {
        i.* = h.index;
        by_record[h.index] = h;
    }
    const fams = fs.families(a, records, subset, .first) catch &.{};
    {
        var buf: [96]u8 = undefined;
        heading(@src(), std.fmt.bufPrint(&buf, "Results ({d} famil{s}, {d} face{s})", .{ fams.len, if (fams.len == 1) "y" else "ies", hits.len, if (hits.len == 1) "" else "s" }) catch "Results");
    }
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    var bar_room = keepBarRoom(@src());
    defer bar_room.deinit();
    const default_open = hits.len <= open_by_default;
    // The italic style groups line up in a column: after the widest
    // upright group that leaves room for its family's italic one.
    const avail: f64 = width - 16 - name_room - 8;
    var slot: f64 = groupWidth(0);
    for (fams) |f| {
        const members = familyMembers(f.name);
        const u = groupWidth(weightsOf(a, members, false).len);
        const i = groupWidth(weightsOf(a, members, true).len);
        if (u + i <= avail) slot = @max(slot, u);
    }
    const clip = dvui.clipGet();
    for (fams, 0..) |f, fk| {
        // The family's files, in the order of their first face found.
        var files: std.ArrayList([]const u8) = .empty;
        for (f.faces) |i| {
            const loc = records[i].location;
            const seen = for (files.items) |l| {
                if (std.mem.eql(u8, l, loc)) break true;
            } else false;
            if (!seen) files.append(a, loc) catch {};
        }
        const is_open = familyIsOpen(f.name, default_open);
        familyRow(a, f, fk, files.items.len, is_open, slot, avail, clip);
        if (!is_open) continue;
        // A line for each file, with every face it holds: those the
        // search left out shown faintly, so a file always shows all it
        // carries.
        for (files.items, 0..) |loc, k| {
            const info = fileInfo(loc) orelse continue;
            fileRow(loc, info, by_record, fk * 4096 + k, clip);
        }
    }
    return hits;
}

/// A family's heading: open or close it, its name, its style icons
/// (Regular, Bold, Italic, Bold Italic: a letter in each face, empty where
/// the family has none) each slant's pair followed by its weights in small
/// boxes, and how many faces and whose (system, user). The italic group
/// sits in a column at `slot`, or on a line under the upright one when
/// the row has no room for it.
fn familyRow(a: Allocator, f: fs.Family, fk: usize, n_files: usize, is_open: bool, slot: f64, avail: f64, clip: dvui.Rect.Physical) void {
    const members = familyMembers(f.name);
    const up = weightsOf(a, members, false);
    const it = weightsOf(a, members, true);
    const pad = slot - groupWidth(up.len);
    const wrap = pad < 0 or slot + groupWidth(it.len) > avail;
    var buf: [96]u8 = undefined;
    const whose: []const u8 = if (f.user > 0 and f.system > 0) "system and user" else if (f.user > 0) "user" else "system";
    const summary = std.fmt.bufPrint(&buf, "{d} face{s} in {d} file{s} · {s}", .{ f.faces.len, if (f.faces.len == 1) "" else "s", n_files, if (n_files == 1) "" else "s", whose }) catch "";
    var clicked = false;
    var group_x: f32 = 0;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = fk, .expand = .horizontal, .margin = .{ .y = 3, .h = 1 } });
        defer row.deinit();
        const rect = row.data().rectScale().r;
        const visible = rect.y < clip.y + clip.h + 40 and rect.y + 60 > clip.y;
        var tb: [160]u8 = undefined;
        const toggle = if (is_open)
            icons.button(@src(), .caret_down, std.fmt.bufPrint(&tb, "Close {s}", .{f.name}) catch "Close", .{ .id_extra = fk, .size = 14, .opts = .{ .gravity_y = 0.5 } })
        else
            icons.button(@src(), .caret_right, std.fmt.bufPrint(&tb, "Open {s}", .{f.name}) catch "Open", .{ .id_extra = fk, .size = 14, .opts = .{ .gravity_y = 0.5 } });
        clicked = toggle;
        dvui.labelNoFmt(@src(), f.name, .{}, .{ .id_extra = fk, .font = dvui.Font.theme(.body).withWeight(.bold), .gravity_y = 0.5, .min_size_content = .{ .w = 150 }, .max_size_content = .width(150) });
        group_x = styleGroup(fk, 0, members, false, up, visible);
        if (!wrap) {
            dvui.labelNoFmt(@src(), "", .{}, .{ .id_extra = fk, .min_size_content = .{ .w = @floatCast(pad) }, .padding = .{} });
            _ = styleGroup(fk, 1, members, true, it, visible);
            dvui.labelNoFmt(@src(), summary, .{}, .{ .id_extra = fk, .gravity_y = 0.5, .margin = .{ .x = 8 }, .font = dvui.Font.theme(.body).larger(-2) });
        }
        // A click elsewhere on the heading opens or closes it (the icons
        // and weight boxes take their own).
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, row.data())) continue;
            if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
                e.handle(@src(), row.data());
                clicked = true;
            }
        }
        if (clicked) {
            setFamilyOpen(f.name, !is_open);
            dvui.refresh(null, @src(), row.data().id);
        }
    }
    if (wrap) {
        // Under the upright group, where it starts.
        var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = fk, .expand = .horizontal, .margin = .{ .h = 1 } });
        defer row2.deinit();
        const rect = row2.data().rectScale().r;
        const visible = rect.y < clip.y + clip.h + 40 and rect.y + 60 > clip.y;
        dvui.labelNoFmt(@src(), "", .{}, .{ .id_extra = fk, .min_size_content = .{ .w = group_x }, .padding = .{}, .margin = .{} });
        _ = styleGroup(fk, 1, members, true, it, visible);
        dvui.labelNoFmt(@src(), summary, .{}, .{ .id_extra = fk, .gravity_y = 0.5, .margin = .{ .x = 8 }, .font = dvui.Font.theme(.body).larger(-2) });
    }
}

/// An installed font file in a family, on one line: pin, a style icon and
/// weight box for each face it holds, its name, what it is (whose; a
/// collection's count; a variable font's ranges and named styles; the
/// first face's look, licence and embedding), and for a user font,
/// removing it. A click on the line selects its first face found.
fn fileRow(loc: []const u8, info: FileInfo, by_record: []const ?fs.Hit, id: usize, clip: dvui.Rect.Physical) void {
    const t = dvui.themeGet();
    const first = info.faces[0];
    const scope = records[first].scope;
    // The face the line stands for: the selected one if it is in this
    // file, else the first the search found, else the first.
    var hit_face: ?usize = null;
    var sel_here = false;
    for (info.faces) |j| {
        if (selected != null and selected.? == j) sel_here = true;
        if (hit_face == null and by_record[j] != null) hit_face = j;
    }
    const lead = if (sel_here) selected.? else hit_face orelse first;
    const faint = hit_face == null;
    const tc: dvui.Options = if (faint) .{ .color_text = .{ .color = t.color(.window, .text).opacity(0.45) } } else .{};
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = if (sel_here) t.color(.highlight, .fill).opacity(0.35) else t.color(.window, .fill) },
        .padding = .{ .x = 2, .y = 1, .w = 4, .h = 1 },
        .margin = .{ .x = 18, .h = 1 },
    });
    defer row.deinit();
    const rect = row.data().rectScale().r;
    const visible = rect.y < clip.y + clip.h + 40 and rect.y + 60 > clip.y;
    const pin = if (isPinned(lead))
        icons.button(@src(), .push_pin_slash, "Unpin: take out of the comparison", .{ .id_extra = id, .size = 14, .opts = .{ .gravity_y = 0.5 } })
    else
        icons.button(@src(), .push_pin, "Pin: keep in the comparison", .{ .id_extra = id, .size = 14, .opts = .{ .gravity_y = 0.5 } });
    if (pin) togglePin(lead);
    for (info.faces, 0..) |j, k| {
        styleIcon(id * 64 + k, j, records[j].style, visible);
        weightBox(id * 64 + k, j);
    }
    dvui.labelNoFmt(@src(), std.fs.path.basename(loc), .{}, tc.override(.{ .id_extra = id, .gravity_y = 0.5, .margin = .{ .x = 6 }, .font = dvui.Font.theme(.mono).larger(-2) }));
    const r = &records[lead];
    var db: [600]u8 = undefined;
    var w: std.Io.Writer = .fixed(&db);
    if (by_record[lead]) |h| {
        if (h.distance) |d| w.print("like {d:.2} · ", .{d}) catch {};
        if (h.missing > 0) w.print("missing {d} · ", .{h.missing}) catch {};
    }
    w.print("{s}", .{@tagName(scope)}) catch {};
    if (info.wght != null or info.named.len > 0) {
        w.writeAll(" · variable") catch {};
        if (info.wght) |v| w.print(" {d:.0}–{d:.0}", .{ v[0], v[1] }) catch {};
        if (info.wdth) |v| w.print(", width {d:.0}–{d:.0}%", .{ v[0], v[1] }) catch {};
        if (info.named.len > 0) w.print(", {d} named", .{info.named.len}) catch {};
    } else if (info.faces.len > 1) {
        w.print(" · collection of {d}", .{info.faces.len}) catch {};
    }
    w.print(" · {s}{s}{s} · {s} · embed {s}", .{
        if (r.measures.serif) |sf| (if (sf) "serif" else "sans") else "?",
        if (r.monospace) ", mono" else "",
        if (r.math) ", math" else "",
        licenceName(r.licence),
        embedName(r.embedding),
    }) catch {};
    if (faint) w.writeAll(" · not in these results") catch {};
    dvui.labelNoFmt(@src(), w.buffered(), .{}, tc.override(.{ .id_extra = id, .gravity_y = 0.5, .margin = .{ .x = 8 }, .font = dvui.Font.theme(.body).larger(-3) }));
    if (scope == .user) {
        if (icons.button(@src(), .trash, "Remove this user font file…", .{ .id_extra = id, .size = 14, .opts = .{ .gravity_x = 1, .gravity_y = 0.5 } })) removing = first;
    }
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, row.data())) continue;
        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            e.handle(@src(), row.data());
            selected = lead;
            dvui.refresh(null, @src(), row.data().id);
        }
    }
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

// Installing and removing ------------------------------------------------------

/// The install prompt is open; it was opened this frame (to focus it).
var install_open = false;
var install_new = false;
var install_replace = false;
/// Paths chosen with Browse, added to the entry on the next frame.
var install_chosen: ?[]u8 = null;
/// What the last install did, a line per file (from `report_arena`).
var install_report: std.ArrayList([]const u8) = .empty;
var report_arena: ?std.heap.ArenaAllocator = null;
/// The record whose file is to be removed, while its prompt is open.
var removing: ?usize = null;

fn centered(area: dvui.Rect, w: f32, h: f32) dvui.Rect {
    return .{ .x = area.x + @max(0, (area.w - w) / 2), .y = area.y + @max(0, (area.h - h) / 3), .w = @min(w, area.w), .h = @min(h, area.h) };
}

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    status = std.fmt.bufPrint(&status_buf, fmt, args) catch status;
}

/// Install font files (or every font file in folders) as user fonts.
fn installPrompt(allocator: Allocator, area: dvui.Rect) void {
    var r = centered(area, 600, 470);
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none, .modal = true }, .{});
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    heading(@src(), "Install fonts as user fonts");
    const fa = dvui.currentWindow().arena();
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        defer tl.deinit();
        var buf: [600]u8 = undefined;
        tl.addText(std.fmt.bufPrint(&buf, "Into {s}, where every application finds them. WOFF and WOFF2 are converted to .ttf or .otf; files are named by family and style, and where each came from is recorded.", .{local.userDir(fa) catch "the user's font folder"}) catch "", .{ .font = dvui.Font.theme(.body).larger(-1) });
    }
    var cancel = false;
    for (dvui.events()) |*e| {
        const inv = keymap.match1(e, keymap.mode("dialog")) orelse continue;
        if (inv.action == keymap.act("dialog.cancel")) {
            cancel = true;
            e.handle(@src(), fw.data());
        }
    }
    if (install_report.items.len > 0) {
        // What happened, file by file.
        {
            // Room kept below for the buttons.
            var sc = dvui.scrollArea(@src(), .{ .vertical_bar = .auto, .horizontal_bar = .hide }, .{ .expand = .horizontal, .min_size_content = .{ .h = 230 }, .max_size_content = .height(230), .margin = .{ .y = 8 } });
            defer sc.deinit();
            for (install_report.items, 0..) |line, k| {
                var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = k, .expand = .horizontal, .background = false, .margin = .{ .h = 3 } });
                tl.addText(line, .{ .font = dvui.Font.theme(.body).larger(-1) });
                tl.deinit();
            }
        }
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 8 } });
        defer row.deinit();
        if (dvui.button(@src(), "Install more", .{}, .{})) {
            install_report.clearRetainingCapacity();
            install_new = true;
        }
        if (dvui.button(@src(), "Done", .{}, .{}) or cancel) install_open = false;
        return;
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Font files or folders, one per line", .{}, .{ .gravity_y = 0.5 });
        if (dvui.useTinyFileDialogs) {
            if (icons.button(@src(), .folder_open, "Choose font files…", .{ .opts = .{ .gravity_x = 1 } })) {
                const chosen = dvui.dialogNativeFileOpenMultiple(fa, .{
                    .title = "Install fonts",
                    .filters = &.{ "*.ttf", "*.otf", "*.ttc", "*.otc", "*.woff", "*.woff2" },
                    .filter_description = "font files",
                }) catch null;
                if (chosen) |files| {
                    var joined: std.ArrayList(u8) = .empty;
                    for (files, 0..) |f, k| {
                        if (k > 0) joined.append(gpa, '\n') catch {};
                        joined.appendSlice(gpa, f) catch {};
                    }
                    if (install_chosen) |old| gpa.free(old);
                    install_chosen = joined.toOwnedSlice(gpa) catch null;
                }
            }
        }
    }
    var te = dvui.textEntry(@src(), .{ .multiline = true, .break_lines = false, .placeholder = "~/Downloads/SomeFont.woff2" }, .{ .expand = .horizontal, .min_size_content = .{ .h = 96 } });
    if (install_new) {
        dvui.focusSubwindow(fw.data().id, null);
        dvui.focusWidget(te.data().id, fw.data().id, null);
        install_new = false;
    }
    if (install_chosen) |c| {
        const cur = std.mem.trimEnd(u8, te.textGet(), "\n ");
        const next = std.mem.concat(fa, u8, &.{ cur, if (cur.len > 0) "\n" else "", c }) catch c;
        te.textSet(next, false);
        gpa.free(c);
        install_chosen = null;
    }
    const entered = fa.dupe(u8, te.textGet()) catch "";
    te.deinit();
    _ = dvui.checkbox(@src(), &install_replace, "Install over a user font of the same family and style", .{ .margin = .{ .y = 6 } });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 8 } });
    defer row.deinit();
    if (dvui.button(@src(), "Cancel", .{}, .{}) or cancel) {
        install_open = false;
        return;
    }
    if (dvui.button(@src(), "Install", .{}, .{})) runInstall(allocator, entered);
}

/// The font files `entered` names (folders searched), installed one by
/// one, a report line for each.
fn runInstall(allocator: Allocator, entered: []const u8) void {
    if (report_arena) |*ra| ra.deinit();
    report_arena = .init(gpa);
    const ra = report_arena.?.allocator();
    install_report.clearRetainingCapacity();
    const io = dvui.io;
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, entered, "\n\r");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\"'");
        if (line.len == 0) continue;
        const path = expandHome(ra, line);
        if (cwd.openDir(io, path, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(io);
            var walker = dir.walk(gpa) catch continue;
            defer walker.deinit();
            const before = files.items.len;
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file or !local.isFontFile(entry.basename)) continue;
                files.append(ra, std.fs.path.join(ra, &.{ path, entry.path }) catch continue) catch {};
            }
            if (files.items.len == before) addReport(ra, "{s}: no font files in this folder", .{path});
        } else |_| files.append(ra, path) catch {};
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.f);
    if (files.items.len == 0) {
        addReport(ra, "Nothing to install: name font files, or folders holding them.", .{});
        return;
    }
    var installed: usize = 0;
    var kept: usize = 0;
    var failed: usize = 0;
    for (files.items) |path| {
        const name = std.fs.path.basename(path);
        const bytes = cwd.readFileAlloc(io, path, ra, .limited(256 << 20)) catch |e| {
            addReport(ra, "{s}: cannot be read ({s})", .{ name, @errorName(e) });
            failed += 1;
            continue;
        };
        const from = cwd.realPathFileAlloc(io, path, ra) catch path;
        const res = local.install(io, gpa, ra, bytes, records, .{ .from = from, .replace = install_replace }) catch |e| {
            switch (e) {
                error.NotAFont => addReport(ra, "{s}: not a font Graven can read", .{name}),
                error.Conflict => addReport(ra, "{s}: a different user font of the same family and style is installed; tick \"Install over\" to replace it", .{name}),
                else => addReport(ra, "{s}: not installed ({s})", .{ name, @errorName(e) }),
            }
            failed += 1;
            continue;
        };
        switch (res.outcome) {
            .installed, .replaced => installed += 1,
            .already_installed => kept += 1,
        }
        var desc_buf: [400]u8 = undefined;
        addReport(ra, "{s}: {s}{s}{s}", .{
            local.describeInstalled(&desc_buf, res),
            switch (res.outcome) {
                .installed => "installed",
                .replaced => "installed over the earlier one",
                .already_installed => "already installed",
            },
            if (res.container.isWeb() and res.outcome != .already_installed) ", converted from a web font" else "",
            if (res.shadows_system) "; a system font has the same name, and applications may take either" else "",
        });
    }
    if (installed > 0) reindex(allocator);
    setStatus("Installed {d} font file{s}{s}{s}.", .{
        installed,
        if (installed == 1) "" else "s",
        if (kept > 0) std.fmt.bufPrint(&status_extra, ", {d} already installed", .{kept}) catch "" else "",
        if (failed > 0) std.fmt.bufPrint(status_extra[64..], ", {d} not installed", .{failed}) catch "" else "",
    });
}
var status_extra: [128]u8 = undefined;

fn addReport(ra: Allocator, comptime fmt: []const u8, args: anytype) void {
    install_report.append(gpa, std.fmt.allocPrint(ra, fmt, args) catch return) catch {};
}

fn expandHome(a: Allocator, path: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home = std.mem.span(std.c.getenv("HOME") orelse return path);
    return std.fs.path.join(a, &.{ home, path[2..] }) catch path;
}

/// Faces by width, weight and slope, as families list them.
fn byShape(_: void, a: usize, b: usize) bool {
    const x = records[a];
    const y = records[b];
    if (x.width != y.width) return x.width < y.width;
    if (x.weight != y.weight) return x.weight < y.weight;
    return !x.italic and y.italic;
}

fn sameName(n: model.FontName, r: *const fs.Record) bool {
    return std.ascii.eqlIgnoreCase(n.family, r.family) and std.ascii.eqlIgnoreCase(n.style, r.style);
}

/// Before a user font's file is removed: every face that goes with it
/// (for a variable font, its weights and named instances), what stays of
/// each family, and which of the document's styles use them.
fn removePrompt(host: Host, allocator: Allocator, i: usize, area: dvui.Rect) void {
    if (i >= records.len or records[i].scope != .user) {
        removing = null;
        return;
    }
    const fa = dvui.currentWindow().arena();
    const file = records[i].location;
    const in_file = local.facesInFile(fa, records, file) catch return;
    var r = centered(area, 640, 460);
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none, .modal = true }, .{});
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    heading(@src(), "Remove this font file?");
    dvui.labelNoFmt(@src(), std.fs.path.basename(file), .{}, .{});
    {
        var buf: [600]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "in {s}", .{std.fs.path.dirname(file) orelse ""}) catch "", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
    }
    std.mem.sort(usize, in_file, {}, byShape);
    var w: std.Io.Writer.Allocating = .init(fa);
    const out = &w.writer;
    {
        var sc = dvui.scrollArea(@src(), .{ .vertical_bar = .auto, .horizontal_bar = .hide }, .{ .expand = .both, .margin = .{ .y = 8 } });
        defer sc.deinit();
        // What goes.
        const one_variable = in_file.len == 1 and records[in_file[0]].variable;
        if (one_variable) {
            out.writeAll("It holds one variable face. Removing the file removes every weight and style it draws:\n") catch {};
        } else if (in_file.len == 1) {
            out.writeAll("It holds one face. Removing the file removes it:\n") catch {};
        } else out.print("It holds {d} faces. Removing the file removes all of them:\n", .{in_file.len}) catch {};
        for (in_file) |j| {
            const fr = &records[j];
            out.print("    {s} {s}: weight {d:.0}{s}", .{ fr.family, fr.style, fr.weight, if (fr.italic) ", italic" else "" }) catch {};
            if (fr.width != 100) out.print(", width {d:.0}%", .{fr.width}) catch {};
            out.writeAll("\n") catch {};
            if (fr.variable) if (faceOf(j)) |face| {
                if (face.axis("wght")) |ax| out.print("        variable: every weight from {d:.0} to {d:.0}\n", .{ ax.min, ax.max }) catch {};
                if (face.axis("wdth")) |ax| out.print("        and every width from {d:.0}% to {d:.0}%\n", .{ ax.min, ax.max }) catch {};
                const named = face.namedInstances(fa) catch &.{};
                if (named.len > 0) {
                    out.writeAll("        named styles: ") catch {};
                    for (named, 0..) |n, k| out.print("{s}{s}", .{ if (k > 0) ", " else "", n }) catch {};
                    out.writeAll("\n") catch {};
                }
            };
        }
        // What stays of each family.
        var done: std.ArrayList([]const u8) = .empty;
        for (in_file) |j| {
            const fam = records[j].family;
            const seen = for (done.items) |d| {
                if (std.ascii.eqlIgnoreCase(d, fam)) break true;
            } else false;
            if (seen) continue;
            done.append(fa, fam) catch {};
            var left: std.ArrayList(usize) = .empty;
            for (records, 0..) |o, k| {
                if (std.ascii.eqlIgnoreCase(o.family, fam) and !std.mem.eql(u8, o.location, file)) left.append(fa, k) catch {};
            }
            std.mem.sort(usize, left.items, {}, byShape);
            if (left.items.len == 0) {
                out.print("\nNo other face of {s} is installed: the family goes.\n", .{fam}) catch {};
            } else {
                out.print("\n{s} keeps {d} face{s}:\n", .{ fam, left.items.len, if (left.items.len == 1) "" else "s" }) catch {};
                for (left.items) |k| out.print("    {s} ({s} font)\n", .{ records[k].style, @tagName(records[k].scope) }) catch {};
            }
        }
        // The document's styles that use them.
        var uses: usize = 0;
        for (host.model.styles.items) |st| {
            for (st.faces.items) |sf| {
                const n = sf.font;
                const hit = for (in_file) |j| {
                    if (sameName(n, &records[j])) break true;
                } else false;
                if (!hit) continue;
                if (uses == 0) out.writeAll("\nThis document uses them:\n") catch {};
                uses += 1;
                const other = for (records, 0..) |o, k| {
                    if (sameName(n, &o) and !std.mem.eql(u8, o.location, file)) break k;
                } else null;
                out.print("    {s}: {s} {s}, its {s} face; ", .{ st.name, n.family, n.style, sf.role }) catch {};
                if (other) |k| {
                    out.print("the {s} font of that name will be used instead\n", .{@tagName(records[k].scope)}) catch {};
                } else out.writeAll("its text will fall back to another face, and the canvas will say so\n") catch {};
            }
        }
        out.writeAll("\nThe file is deleted; Graven keeps no copy.") catch {};
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        tl.addText(w.written(), .{ .font = dvui.Font.theme(.body).larger(-1) });
        tl.deinit();
    }
    var cancel = false;
    for (dvui.events()) |*e| {
        const inv = keymap.match1(e, keymap.mode("dialog")) orelse continue;
        if (inv.action == keymap.act("dialog.cancel")) {
            cancel = true;
            e.handle(@src(), fw.data());
        }
    }
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 8 } });
    defer row.deinit();
    if (dvui.button(@src(), "Cancel", .{}, .{}) or cancel) {
        removing = null;
        return;
    }
    var lb: [64]u8 = undefined;
    if (dvui.button(@src(), std.fmt.bufPrint(&lb, "Remove the file ({d} face{s})", .{ in_file.len, if (in_file.len == 1) "" else "s" }) catch "Remove the file", .{}, .{})) {
        removing = null;
        const name = fa.dupe(u8, std.fs.path.basename(file)) catch "the file";
        local.removeFile(dvui.io, gpa, fa, records, file) catch |e| {
            setStatus("{s} was not removed ({s}).", .{ name, @errorName(e) });
            return;
        };
        reindex(allocator);
        setStatus("Removed {s} ({d} face{s}).", .{ name, in_file.len, if (in_file.len == 1) "" else "s" });
    }
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
        const flip = if (overlay)
            icons.button(@src(), .rows, "Show side by side", .{})
        else
            icons.button(@src(), .stack, "Overlay glyph by glyph", .{});
        if (flip) overlay = !overlay;
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
    const fl = [_]*layout.Face{face};
    var r = layout.render.run(gpa, &fl, 0, sampleText(), 1) catch return null;
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
        .conic => |c| {
            for (1..33) |k| try pts.append(a, c.at(@as(f64, @floatFromInt(k)) / 32));
        },
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
    var box = dvui.box(@src(), .{}, .{ .id_extra = k, .expand = .horizontal, .min_size_content = .{ .h = cap * 2 }, .background = true, .color_fill = .{ .color = display.fix(paper) } });
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
    var box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = cell_h * @as(f32, @floatFromInt(rows)) }, .background = true, .color_fill = .{ .color = display.fix(paper) } });
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
    const fl = [_]*layout.Face{face};
    var r = layout.render.run(gpa, &fl, 0, ch, 1) catch return null;
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

/// An installed family's regular face (or its first) and its italic and
/// bolds, as names; null when no installed font is of that family.
pub fn installedFamily(allocator: Allocator, family: []const u8) ?struct { main: model.FontName, variants: Variants } {
    _ = indexRecords(allocator, false);
    const k = fs.find(records, family, "Regular") orelse fs.find(records, family, "Book") orelse fs.find(records, family, null) orelse return null;
    return .{ .main = nameOf(k), .variants = familyVariants(k) };
}

/// The italic, bold and bold italic of record `k`'s family, as names.
fn familyVariants(k: usize) Variants {
    const v = fs.variantsOf(records, k);
    return .{
        .italic = if (v.italic) |i| nameOf(i) else null,
        .bold = if (v.bold) |i| nameOf(i) else null,
        .bold_italic = if (v.bold_italic) |i| nameOf(i) else null,
    };
}

fn nameOf(i: usize) model.FontName {
    return .{ .family = records[i].family, .style = records[i].style };
}

/// The roles a style's faces are set for, besides fallbacks.
const roles = [_]struct { role: []const u8, name: []const u8 }{
    .{ .role = "text", .name = "Text" },
    .{ .role = "italic", .name = "Italic" },
    .{ .role = "bold", .name = "Bold" },
    .{ .role = "bold_italic", .name = "Bold italic" },
    .{ .role = "math", .name = "Math" },
};

fn isFallback(role: []const u8) bool {
    for (roles) |r| if (std.mem.eql(u8, r.role, role)) return false;
    return true;
}

/// A style's faces: each role set from the selected font or cleared, and
/// its fallbacks, in the order tried.
fn compose(host: Host) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 300 }, .max_size_content = .width(300), .expand = .vertical, .padding = .all(8) });
    defer col.deinit();
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    var bar_room = keepBarRoom(@src());
    defer bar_room.deinit();
    const m = host.model;
    heading(@src(), "Style faces");
    if (m.styles.items.len == 0) {
        dvui.labelNoFmt(@src(), "The document has no styles yet.", .{}, .{});
        return;
    }
    const a = dvui.currentWindow().arena();
    const snames = a.alloc([]const u8, m.styles.items.len) catch return;
    for (m.styles.items, snames) |st, *n| n.* = st.name;
    style_choice = @min(style_choice, snames.len - 1);
    _ = dvui.dropdown(@src(), snames, .{ .choice = &style_choice }, .{}, .{ .expand = .horizontal });
    const st = m.styles.items[style_choice];
    const sel = selected;
    var sel_name: [128]u8 = undefined;
    const sel_label: []const u8 = if (sel) |s| std.fmt.bufPrint(&sel_name, "{s} {s}", .{ records[s].family, records[s].style }) catch "the selected font" else "";
    if (st.base != .none) if (m.styleIndex(st.base)) |bi| {
        var buf: [160]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "Based on {s}: what it sets none of comes from there.", .{m.styles.items[bi].name}) catch "", .{}, .{ .font = dvui.Font.theme(.body).larger(-2), .margin = .{ .y = 4 } });
    };
    inline for (roles, 0..) |r, k| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = k, .expand = .horizontal });
        defer row.deinit();
        const cur = st.face(r.role);
        var tb: [200]u8 = undefined;
        if (sel) |s| {
            if (icons.button(@src(), .arrow_square_in, std.fmt.bufPrint(&tb, "Use {s} as the {s} face", .{ sel_label, r.role }) catch "Use the selected font", .{ .id_extra = k, .size = 14 })) host.setStyleFace(st.id, r.role, nameOf(s));
        }
        if (cur == null) {
            // The clear button's room, so the names line up.
            _ = dvui.spacer(@src(), .{ .id_extra = k, .min_size_content = .{ .w = 22 } });
        } else if (icons.button(@src(), .x, "None: from its base, else the default", .{ .id_extra = k, .size = 14 })) host.setStyleFace(st.id, r.role, null);
        var buf: [256]u8 = undefined;
        const shown = if (cur) |n| std.fmt.bufPrint(&buf, "{s}: {s} {s}", .{ r.name, n.family, n.style }) catch "" else std.fmt.bufPrint(&buf, "{s}: none", .{r.name}) catch "";
        dvui.labelNoFmt(@src(), shown, .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .margin = .{ .x = 4 } });
    }
    if (sel) |s| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Selected:", .{}, .{ .gravity_y = 0.5, .margin = .{ .w = 4 } });
        var tb: [200]u8 = undefined;
        if (icons.button(@src(), .text_aa, std.fmt.bufPrint(&tb, "Use {s} as the text face, with its family's italic and bolds", .{sel_label}) catch "Use as the text face", .{})) host.setStyleFamily(st.id, nameOf(s), familyVariants(s));
        if (icons.button(@src(), .list_plus, std.fmt.bufPrint(&tb, "Add {s} as a fallback", .{sel_label}) catch "Add as a fallback", .{})) {
            // The first fallback name the style does not use yet.
            var n: usize = 1;
            var nb: [32]u8 = undefined;
            const role = while (n < 1000) : (n += 1) {
                const r = std.fmt.bufPrint(&nb, "fallback{d}", .{n}) catch break null;
                if (st.face(r) == null) break r;
            } else null;
            if (role) |r| host.setStyleFace(st.id, r, nameOf(s));
        }
    } else dvui.labelNoFmt(@src(), "Select a font to use it here.", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
    heading(@src(), "Fallbacks, in order tried");
    var any = false;
    for (st.faces.items, 0..) |sf, k| {
        if (!isFallback(sf.role)) continue;
        any = true;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = k, .expand = .horizontal, .margin = .{ .h = 2 } });
        defer row.deinit();
        if (icons.button(@src(), .trash, "Remove this fallback", .{ .id_extra = k, .size = 14 })) host.setStyleFace(st.id, sf.role, null);
        var buf: [160]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "{s} {s}", .{ sf.font.family, sf.font.style }) catch "", .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .margin = .{ .x = 4 } });
    }
    if (!any) dvui.labelNoFmt(@src(), "None.", .{}, .{});
}
