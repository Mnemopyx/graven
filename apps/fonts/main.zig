//! graven-fonts: find, compare and choose fonts. A separate tool on the font
//! search library; Graven opens it, and it runs on its own.
//!
//! This is the local source: installed fonts, found in the system's font
//! folders, described once and kept in an index cache, so later runs only
//! describe files that are new or changed. Remote repositories come as
//! addons through the same `Source` interface.

const std = @import("std");
const fs = @import("graven_fontsearch");
const local = @import("local.zig");

const Record = fs.Record;

const usage =
    \\usage: graven-fonts index
    \\         Finds installed fonts, describes new and changed ones, and saves the index.
    \\       graven-fonts search [words] [options]
    \\         Lists fonts whose family or style holds every word, best first.
    \\         --like "Family" [--style "Style"]  rank by likeness to that font
    \\         --covers TEXT        must have every character of TEXT
    \\         --some               ... or let fonts lacking some through, ranked by how many
    \\         --math | --italic | --upright | --mono | --serif | --sans | --variable
    \\         --weight MIN-MAX     e.g. 300-500
    \\         --embed installable|editable|print   at least this embedding permission
    \\         --licence ofl|apache|ufl|gpl|other|unstated   (repeatable)
    \\         --limit N            (default 25)
    \\       graven-fonts show "Family" [--style "Style"]
    \\         Everything known about a font, with where each fact came from.
    \\
    \\Licence terms are shown as each font states them. Graven does not set
    \\them, and does not judge what your own licence allows.
    \\
;

/// Scans and saves the index, saying what it did unless `quiet`.
fn buildIndex(init: std.process.Init, a: std.mem.Allocator, quiet: bool) ![]Record {
    const t0: std.Io.Timestamp = .now(init.io, .awake);
    var rep: local.Report = .{};
    const recs = try local.build(init.io, init.gpa, a, &rep);
    if (!quiet) {
        const ms = @as(f64, @floatFromInt(t0.untilNow(init.io, .awake).toNanoseconds())) / 1e6;
        std.debug.print("{d} faces: {d} described, {d} unchanged, {d} unreadable, in {d:.0} ms\nindex: {s}\n", .{ recs.len, rep.described, rep.kept, rep.failed, ms, rep.path });
    }
    return recs;
}

/// The index, built first if there is none.
fn indexedRecords(init: std.process.Init, a: std.mem.Allocator) ![]Record {
    const r = local.load(init.io, a);
    if (r.len > 0) return r;
    std.debug.print("No font index yet: building it.\n", .{});
    return buildIndex(init, a, false);
}

fn utf8Codepoints(a: std.mem.Allocator, s: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return error.BadText).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ') continue;
        if (std.mem.indexOfScalar(u21, out.items, cp) == null) try out.append(a, cp);
    }
    return out.items;
}

fn search(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    var q: fs.Query = .{ .limit = 25 };
    var words: std.ArrayList(u8) = .empty;
    var like_family: ?[]const u8 = null;
    var like_style: ?[]const u8 = null;
    var licences: std.ArrayList(fs.Licence) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, arg, "--like")) {
            like_family = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--style")) {
            like_style = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--covers")) {
            q.covers = try utf8Codepoints(a, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--some")) {
            q.allow_missing = true;
        } else if (std.mem.eql(u8, arg, "--math")) {
            q.math = true;
        } else if (std.mem.eql(u8, arg, "--italic")) {
            q.italic = true;
        } else if (std.mem.eql(u8, arg, "--upright")) {
            q.italic = false;
        } else if (std.mem.eql(u8, arg, "--mono")) {
            q.monospace = true;
        } else if (std.mem.eql(u8, arg, "--serif")) {
            q.serif = true;
        } else if (std.mem.eql(u8, arg, "--sans")) {
            q.serif = false;
        } else if (std.mem.eql(u8, arg, "--variable")) {
            q.variable = true;
        } else if (std.mem.eql(u8, arg, "--weight")) {
            const dash = std.mem.indexOfScalar(u8, next, '-') orelse return error.BadWeight;
            q.weight = .{ try std.fmt.parseFloat(f32, next[0..dash]), try std.fmt.parseFloat(f32, next[dash + 1 ..]) };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--embed")) {
            q.embedding = if (std.mem.eql(u8, next, "print")) .preview_print else std.meta.stringToEnum(fs.Embedding, next) orelse return error.BadEmbedding;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--licence") or std.mem.eql(u8, arg, "--license")) {
            try licences.append(a, std.meta.stringToEnum(fs.Licence, next) orelse return error.BadLicence);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            q.limit = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else {
            if (words.items.len > 0) try words.append(a, ' ');
            try words.appendSlice(a, arg);
        }
    }
    q.words = words.items;
    q.licences = licences.items;
    const all = try indexedRecords(init, a);
    if (like_family) |fam| {
        const k = fs.find(all, fam, like_style) orelse {
            std.debug.print("No installed font is called \"{s}\"{s}{s}.\n", .{ fam, if (like_style != null) " " else "", like_style orelse "" });
            std.process.exit(1);
        };
        q.like = &all[k];
        std.debug.print("Like {s} {s}:\n", .{ all[k].family, all[k].style });
    }
    const hits = try fs.search(a, all, q);
    if (hits.len == 0) {
        std.debug.print("No fonts match.\n", .{});
        return;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    for (hits) |h| {
        const r = &all[h.index];
        var label_buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s} {s}", .{ r.family, r.style }) catch r.family;
        try w.print("{s:<44}", .{label});
        if (h.distance) |d| try w.print("  {d:>5.2}", .{d});
        if (q.covers.len > 0 and h.missing > 0) try w.print("  missing {d}", .{h.missing});
        try w.print("  {s}{s}{s}{s}  {s}, embed {s}\n", .{
            if (r.measures.serif) |s| (if (s) "serif" else "sans") else "?",
            if (r.monospace) " mono" else "",
            if (r.math) " math" else "",
            if (r.variable) " variable" else "",
            @tagName(r.licence),
            @tagName(r.embedding),
        });
    }
    try w.flush();
}

fn show(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) return error.Usage;
    var style: ?[]const u8 = null;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--style")) style = args[2];
    const all = try indexedRecords(init, a);
    const k = fs.find(all, args[0], style) orelse {
        std.debug.print("No installed font is called \"{s}\".\n", .{args[0]});
        std.process.exit(1);
    };
    const r = &all[k];
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    try w.print("{s} {s}  ({s})\n", .{ r.family, r.style, r.full_name });
    try w.print("  source: {s}, {s} (face {d})\n", .{ r.source, r.location, r.index });
    try w.print("  weight {d:.0}, width {d:.0}%, {s}, slant {d:.1}°{s}{s}{s}\n", .{ r.weight, r.width, if (r.italic) "italic" else "upright", r.slant, if (r.monospace) ", monospaced" else "", if (r.variable) ", variable" else "", if (r.math) ", MATH table" else "" });
    try w.print("  {d} glyphs, {d} codepoint ranges, units per em {d}\n", .{ r.glyphs, r.coverage.len, r.upem });
    const m = r.measures;
    try w.writeAll("  measured from outlines:");
    if (m.cap) |v| try w.print(" cap/em {d:.3}", .{v});
    if (m.x) |v| try w.print(", x/cap {d:.3}", .{v});
    if (m.stem) |v| try w.print(", stem/cap {d:.3}", .{v});
    if (m.contrast) |v| try w.print(", contrast {d:.2}", .{v});
    if (m.width) |v| try w.print(", width/cap {d:.3}", .{v});
    if (m.round) |v| try w.print(", o w/h {d:.3}", .{v});
    if (m.serif) |v| try w.print(", {s}", .{if (v) "serifs" else "no serifs"});
    try w.writeAll("\n");
    try w.print("  embedding (the font's OS/2 fsType): {s}{s}{s}\n", .{ @tagName(r.embedding), if (r.no_subsetting) ", no subsetting" else "", if (r.bitmap_only) ", bitmap only" else "" });
    try w.print("  licence (the font's name table): {s}\n", .{@tagName(r.licence)});
    if (r.licence_text.len > 0) try w.print("    \"{s}\"\n", .{r.licence_text});
    if (r.licence_url.len > 0) try w.print("    {s}\n", .{r.licence_url});
    try w.writeAll("  These are the terms as the font states them. Graven does not set them,\n  and does not judge what your own licence allows.\n");
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2) {
        const cmd = args[1];
        const rest = args[2..];
        if (std.mem.eql(u8, cmd, "index") and rest.len == 0) {
            _ = try buildIndex(init, a, false);
            return;
        }
        if (std.mem.eql(u8, cmd, "search")) return search(init, a, rest);
        if (std.mem.eql(u8, cmd, "show") and rest.len >= 1) return show(init, a, rest);
    }
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
