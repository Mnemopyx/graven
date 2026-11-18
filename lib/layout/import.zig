//! Importing text into a flow, at a position in it (a flow with tracks
//! or an unplaced one): styled text (see the richtext library), or plain
//! text read as styled text with nothing set (`plain`). Styled text comes
//! in so:
//! each paragraph after a paragraph separator, in a paragraph style made
//! for its settings (identical ones shared, existing ones reused); each
//! stretch of one font and size as a run in a style made for them (named
//! by font and size, reused when one of that name exists), set in a
//! composed font of that family; weight, slant, decorations and scripts as
//! markup in the run; line breaks as line breaks. Every change goes
//! through the history, as one undoable step.

const std = @import("std");
const rt = @import("graven_richtext");
const model = @import("model.zig");
const history = @import("history.zig");

const Allocator = std.mem.Allocator;
const Model = model.Model;
const StyleId = model.StyleId;
const ParaId = model.ParaId;

/// What an import made, and what it could not carry over.
pub const FontMade = struct { style: StyleId, family: []const u8 };

pub const Report = struct {
    paragraphs: usize = 0,
    runs: usize = 0,
    line_breaks: usize = 0,
    /// Set as a quad's space: there are no tab stops yet.
    tabs: usize = 0,
    styles_made: usize = 0,
    paragraph_styles_made: usize = 0,
    /// Styles made for a family, set in its regular face; the caller may
    /// fill in its italic and bolds from the installed fonts.
    fonts_made: std.ArrayList(FontMade) = .empty,
    /// Spans in a colour other than black: kept as text, not yet as a
    /// colour tag.
    coloured: usize = 0,
    skipped: rt.Skipped = .{},

    pub fn deinit(r: *Report, gpa: Allocator) void {
        r.fonts_made.deinit(gpa);
    }
};

const mm_per_pt = model.mm_per_pt;

/// Imports `doc` into flow `flow` at item `at`, with `base` the style of
/// text that names no font or size, and `track_pitch` its lines' spacing
/// (mm; a paragraph's wider spacing becomes its line gap). Returns what
/// was done; `gpa` holds the report's list and scratch work.
pub fn rich(gpa: Allocator, h: *history.History, m: *Model, key: u64, flow: model.ObjectId, at: usize, doc: rt.Doc, base: StyleId, track_pitch: f64) !Report {
    var rep: Report = .{ .skipped = doc.skipped };
    errdefer rep.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var index = at;

    for (doc.paragraphs, 0..) |para, pi| {
        const ps = try paragraphStyle(h, m, key, para.settings, track_pitch, &rep);
        if (pi == 0 and index == 0) {
            _ = try h.doMerged(m, key, .setParagraphAtIn, .{ flow, 0, ps });
        } else {
            _ = try h.doMerged(m, key, .placeInFlow, .{ flow, index, .{ .what = .{ .paragraph = ps } } });
            index += 1;
        }
        rep.paragraphs += 1;

        // Stretches of one font and size, cut at line breaks.
        var k: usize = 0;
        const spans = para.spans;
        while (k < spans.len) {
            if (spans[k].kind == .line_break) {
                index += try h.doMerged(m, key, .insertBreakIn, .{ flow, index });
                rep.line_breaks += 1;
                k += 1;
                continue;
            }
            const look = spans[k].look;
            var end = k;
            while (end < spans.len and spans[end].kind != .line_break and spans[end].look.font == look.font and spans[end].look.size == look.size) : (end += 1) {
                if (spans[end].kind == .tab) rep.tabs += 1;
                if (spans[end].look.color) |c| if (c < doc.colors.len) if (doc.colors[c]) |col| if (col.r != 0 or col.g != 0 or col.b != 0) {
                    rep.coloured += 1;
                };
            }
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.writeAll("\\textnormal{");
            try rt.writeMarkup(&out.writer, spans[k..end]);
            try out.writer.writeAll("}");
            const style = try textStyle(gpa, h, m, key, doc, look, base, &rep);
            _ = try h.doMerged(m, key, .placeInFlow, .{ flow, index, .{ .what = .{ .run = .{ .style = style, .content = out.written() } } } });
            index += 1;
            rep.runs += 1;
            k = end;
        }
    }
    return rep;
}

/// The paragraph style for `s`: none when it sets nothing (the track's
/// alignment), else an existing one with the same settings, else a new
/// one.
fn paragraphStyle(h: *history.History, m: *Model, key: u64, s: rt.Settings, track_pitch: f64, rep: *Report) !?ParaId {
    if (s.eql(.{})) return null;
    const want: model.ParagraphStyle = .{
        .name = "",
        .alignment = switch (s.alignment) {
            .start => .start,
            .centre => .centre,
            .end => .end,
            .justify => .justify,
        },
        .indent_start = s.indent_start,
        .indent_end = s.indent_end,
        .first = s.first,
        .space_before = s.space_before,
        .space_after = s.space_after,
        // The track's pitch is its lines' spacing; more is a gap.
        .line_gap = if (s.line_pitch) |lp| @max(0, lp - track_pitch) else 0,
    };
    for (m.paragraph_styles.items) |p| {
        var q = p;
        q.name = "";
        q.id = .none;
        if (std.meta.eql(q, want)) return p.id;
    }
    var buf: [32]u8 = undefined;
    var named = want;
    named.name = m.nextParagraphStyleName(&buf);
    rep.paragraph_styles_made += 1;
    return try h.doMerged(m, key, .addParagraphStyle, .{named});
}

/// The style for text that looks like `look`: `base` when it names no
/// font or size, else the style named for them ("Arial 12 pt"), made when
/// there is none: based on `base`, its text face that family's.
fn textStyle(gpa: Allocator, h: *history.History, m: *Model, key: u64, doc: rt.Doc, look: rt.Look, base: StyleId, rep: *Report) !StyleId {
    const family: ?[]const u8 = if (look.font) |f| (if (f < doc.fonts.len and doc.fonts[f].name.len > 0) doc.fonts[f].name else null) else null;
    if (family == null and look.size == null) return base;
    const base_style = m.textStyle(base).*;
    var name_buf: [160]u8 = undefined;
    const name = if (look.size) |pt|
        std.fmt.bufPrint(&name_buf, "{s} {d} pt", .{ family orelse base_style.name, pt }) catch "Imported"
    else
        std.fmt.bufPrint(&name_buf, "{s}", .{family.?}) catch "Imported";
    for (m.styles.items) |st| if (std.mem.eql(u8, st.name, name)) return st.id;

    // A size in points is the em, as the source meant it: the cap height
    // follows from the font once it is resolved.
    var size: model.StyleSize = .{ .cap_height = base_style.cap_height, .em_size = base_style.em_size, .line_pitch = base_style.line_pitch, .base = base };
    if (look.size) |pt| {
        size.em_size = pt * mm_per_pt;
        size.cap_height = pt * mm_per_pt * model.cap_per_em;
    }
    const style = try h.doMerged(m, key, .addStyle, .{ name, size });
    rep.styles_made += 1;
    if (family) |fam| {
        try h.doMerged(m, key, .setStyleFace, .{ style, "text", @as(?model.FontName, .{ .family = fam }) });
        try rep.fonts_made.append(gpa, .{ .style = style, .family = m.textStyle(style).face("text").?.family });
    }
    return style;
}

// Tests ---------------------------------------------------------------------------


/// Plain text as styled text with nothing set: each line a paragraph
/// (CR LF and CR read as LF), tabs as tabs. A byte-order mark is dropped;
/// text that is not UTF-8 is read as Latin-1. In `a`.
pub fn plain(a: Allocator, bytes: []const u8) Allocator.Error!rt.Doc {
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    if (!std.unicode.utf8ValidateSlice(text)) {
        var out: std.ArrayList(u8) = .empty;
        for (text) |c| {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &b) catch unreachable;
            try out.appendSlice(a, b[0..n]);
        }
        text = out.items;
    }
    var paras: std.ArrayList(rt.Paragraph) = .empty;
    var i: usize = 0;
    while (i <= text.len) {
        var end = i;
        while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
        const line = text[i..end];
        var spans: std.ArrayList(rt.Span) = .empty;
        var it = std.mem.splitScalar(u8, line, '\t');
        var first = true;
        while (it.next()) |part| {
            if (!first) try spans.append(a, .{ .kind = .tab });
            first = false;
            if (part.len > 0) try spans.append(a, .{ .text = part });
        }
        // The text's last line break ends it: no empty paragraph after.
        if (!(end == text.len and line.len == 0 and paras.items.len > 0)) try paras.append(a, .{ .spans = spans.items });
        if (end >= text.len) break;
        i = end + 1;
        if (text[end] == '\r' and i < text.len and text[i] == '\n') i += 1;
    }
    return .{ .paragraphs = paras.items };
}

/// The URI to record for a file at absolute path `path`: relative to
/// `doc_dir` (the document's folder) when it lies in it, else a `file:`
/// URI; percent-encoded (RFC 3986). In `a`.
pub fn sourceUri(a: Allocator, path: []const u8, doc_dir: ?[]const u8) Allocator.Error![]u8 {
    var p: std.ArrayList(u8) = .empty;
    for (path) |c| try p.append(a, if (c == '\\') '/' else c);
    var rest = p.items;
    var out: std.ArrayList(u8) = .empty;
    if (doc_dir) |dir_in| {
        var dir = dir_in;
        while (dir.len > 1 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) dir = dir[0 .. dir.len - 1];
        if (dir.len > 0 and rest.len > dir.len + 1 and std.mem.startsWith(u8, rest, dir) and rest[dir.len] == '/') {
            try percent(a, &out, rest[dir.len + 1 ..]);
            return out.items;
        }
    }
    try out.appendSlice(a, "file://");
    // A drive letter: file:///C:/…
    if (rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') try out.append(a, '/');
    try percent(a, &out, rest);
    _ = &rest;
    return out.items;
}

/// `s` percent-encoded as a URI path: unreserved characters, sub-delims,
/// ':', '@' and '/' kept, every other byte as %XX.
fn percent(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| {
        const keep = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/", c) != null;
        if (keep) try out.append(a, c) else {
            var b: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&b, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(a, &b);
        }
    }
}

/// SHA-256 of `bytes` as 64 lowercase hex digits.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}


// Tables (legend sheets) ------------------------------------------------------

/// A table read from CSV: its rows, each its fields, in `a`.
pub const Table = struct {
    rows: []const []const []const u8,
};

/// The table in `bytes`: comma-separated (RFC 4180: a field in double
/// quotes may hold the separator, line breaks and doubled quotes), or
/// tab- or semicolon-separated when the first line holds more of those
/// than commas outside quotes. A byte-order mark is dropped; text that is
/// not UTF-8 is read as Latin-1. Blank lines are skipped. In `a`.
pub fn parseTable(a: Allocator, bytes: []const u8) Allocator.Error!Table {
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    if (!std.unicode.utf8ValidateSlice(text)) {
        var out: std.ArrayList(u8) = .empty;
        for (text) |c| {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &b) catch unreachable;
            try out.appendSlice(a, b[0..n]);
        }
        text = out.items;
    }
    // The separator: the first line's commonest outside quotes.
    var counts: [3]usize = .{ 0, 0, 0 };
    {
        var quoted = false;
        for (text) |c| {
            if (c == '"') quoted = !quoted;
            if (quoted) continue;
            if (c == '\n' or c == '\r') break;
            switch (c) {
                ',' => counts[0] += 1,
                '\t' => counts[1] += 1,
                ';' => counts[2] += 1,
                else => {},
            }
        }
    }
    const sep: u8 = if (counts[1] > counts[0] and counts[1] >= counts[2]) '\t' else if (counts[2] > counts[0]) ';' else ',';
    var rows: std.ArrayList([]const []const u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var field: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var quoted = false;
    var was_quoted = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quoted) {
            if (c == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    try field.append(a, '"');
                    i += 1;
                } else quoted = false;
            } else try field.append(a, c);
            continue;
        }
        if (c == '"' and field.items.len == 0 and !was_quoted) {
            quoted = true;
            was_quoted = true;
        } else if (c == sep) {
            try fields.append(a, try field.toOwnedSlice(a));
            was_quoted = false;
        } else if (c == '\n' or c == '\r') {
            if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
            try fields.append(a, try field.toOwnedSlice(a));
            was_quoted = false;
            if (!blank(fields.items)) try rows.append(a, try fields.toOwnedSlice(a)) else fields.clearRetainingCapacity();
        } else try field.append(a, c);
    }
    if (field.items.len > 0 or fields.items.len > 0) {
        try fields.append(a, try field.toOwnedSlice(a));
        if (!blank(fields.items)) try rows.append(a, try fields.toOwnedSlice(a));
    }
    return .{ .rows = rows.items };
}

fn blank(fields: []const []const u8) bool {
    for (fields) |f| if (std.mem.trim(u8, f, " ").len > 0) return false;
    return true;
}

/// What a table's import did to a sheet.
pub const SheetReport = struct {
    sheet: model.ObjectId = .none,
    rows_matched: usize = 0,
    rows_added: usize = 0,
    columns_added: usize = 0,
    cells_set: usize = 0,
    /// Rows whose name appeared again further down (the later one stands).
    repeated: usize = 0,
};

/// Where a table goes: into sheet `id`, or a new sheet named `name` over
/// scope `scope` (a grid's, a track's or a panel's ID).
pub const SheetTarget = union(enum) {
    into: model.ObjectId,
    new: struct { name: []const u8, scope: model.ObjectId },
};

/// Fills a legend sheet from `table`: its first row the header (its first
/// field naming the key column, which is not used; the others slots), each
/// further row a key by its name and its cells. Into an existing sheet, a
/// row matches by name and its cells in the table's columns are set; a
/// column it lacks is added, a row it lacks appended; what the table does
/// not name is kept. Cells are markup as written. All as one step
/// (`key`).
pub fn sheetFromTable(gpa: Allocator, h: *history.History, m: *Model, key: u64, target: SheetTarget, table: Table) !SheetReport {
    var rep: SheetReport = .{};
    if (table.rows.len == 0) return error.EmptyTable;
    const header = table.rows[0];
    const id = switch (target) {
        .into => |id| id,
        .new => |n| try h.doMerged(m, key, .addSheet, .{ n.name, n.scope, &[_][]const u8{} }),
    };
    rep.sheet = id;
    if (m.sheetIndex(id) == null) return error.NoSuchObject;
    // Each table column's sheet column (from 1), added where missing.
    var cols = try gpa.alloc(?usize, header.len);
    defer gpa.free(cols);
    for (header, 0..) |hname, k| {
        cols[k] = null;
        if (k == 0) continue;
        const name = std.mem.trim(u8, hname, " ");
        if (name.len == 0) continue;
        const sh = &m.sheets.items[m.sheetIndex(id).?];
        cols[k] = for (sh.columns.items, 0..) |c, ci| {
            if (std.mem.eql(u8, c, name)) break ci + 1;
        } else blk: {
            _ = try h.doMerged(m, key, .addSheetColumn, .{ id, null, name });
            rep.columns_added += 1;
            break :blk m.sheets.items[m.sheetIndex(id).?].columns.items.len;
        };
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (table.rows[1..]) |row| {
        if (row.len == 0) continue;
        const name = std.mem.trim(u8, row[0], " ");
        if (name.len == 0) continue;
        if ((try seen.getOrPut(gpa, name)).found_existing) rep.repeated += 1;
        const sh = &m.sheets.items[m.sheetIndex(id).?];
        const r = for (sh.rows.items, 0..) |sr, ri| {
            if (std.mem.eql(u8, sr.key, name)) break ri;
        } else blk: {
            _ = try h.doMerged(m, key, .addSheetRow, .{ id, null, name });
            rep.rows_added += 1;
            break :blk m.sheets.items[m.sheetIndex(id).?].rows.items.len - 1;
        };
        for (row[1..], 1..) |cell, k| {
            if (k >= cols.len) break;
            const c = cols[k] orelse continue;
            const now = m.sheets.items[m.sheetIndex(id).?].rows.items[r];
            if (c - 1 < now.cells.items.len and std.mem.eql(u8, now.cells.items[c - 1], cell)) continue;
            _ = try h.doMerged(m, key, .setSheetCell, .{ id, r, c, cell });
            rep.cells_set += 1;
        }
    }
    rep.rows_matched = seen.count() - rep.rows_added;
    return rep;
}


/// Sheet `id` as CSV (RFC 4180): a header (`name`, then its columns), then
/// a row per key, its name and its cells as they are. A field holding the
/// separator, a quote, a line break or leading or trailing spaces is
/// quoted, its quotes doubled. Lines end in CR LF; UTF-8, no byte-order
/// mark. `parseTable` reads it back as it was. In `a`.
pub fn sheetToCsv(a: Allocator, m: *const Model, id: model.ObjectId) Allocator.Error![]u8 {
    const si = m.sheetIndex(id) orelse return a.dupe(u8, "");
    const sh = m.sheets.items[si];
    var out: std.ArrayList(u8) = .empty;
    try csvField(a, &out, "name");
    for (sh.columns.items) |c| {
        try out.append(a, ',');
        try csvField(a, &out, c);
    }
    try out.appendSlice(a, "\r\n");
    for (sh.rows.items) |row| {
        try csvField(a, &out, row.key);
        for (0..sh.columns.items.len) |k| {
            try out.append(a, ',');
            try csvField(a, &out, if (k < row.cells.items.len) row.cells.items[k] else "");
        }
        try out.appendSlice(a, "\r\n");
    }
    return out.toOwnedSlice(a);
}

fn csvField(a: Allocator, out: *std.ArrayList(u8), f: []const u8) Allocator.Error!void {
    const quote = std.mem.indexOfAny(u8, f, ",\"\r\n") != null or (f.len > 0 and (f[0] == ' ' or f[f.len - 1] == ' '));
    if (!quote) return out.appendSlice(a, f);
    try out.append(a, '"');
    for (f) |c| {
        if (c == '"') try out.append(a, '"');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

const testing = std.testing;

test "an RTF document comes in as paragraphs, styles and runs, undone as one step" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const p = try m.startCanvas(.mm);
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 100 }, .style = body, .count = 10, .length = 10, .pitch = 6 });
    try h.reset(&m);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const doc = try rt.rtf.read(arena.allocator(),
        \\{\rtf1\ansi\deff0{\fonttbl{\f0 Caladea;}{\f1 Carlito;}}{\colortbl;\red200\green0\blue0;}
        \\\pard\qj\sa120 Some \b bold\b0  text, {\cf1 red}.\line More.\par
        \\\pard\qj\sa120\f1\fs24 Second\tab one.\par
        \\\pard\qc Third.{\pict x}\par}
    );
    var rep = try rich(gpa, &h, &m, 42, m.trackFlow(p, r).?.id, 0, doc, body, 6);
    defer rep.deinit(gpa);
    try testing.expectEqual(3, rep.paragraphs);
    try testing.expectEqual(1, rep.line_breaks);
    try testing.expectEqual(1, rep.tabs);
    try testing.expectEqual(1, rep.coloured);
    try testing.expectEqual(1, rep.skipped.pictures);
    // Justified and centred: two paragraph styles, the first shared.
    try testing.expectEqual(2, rep.paragraph_styles_made);
    // "Caladea" (no size) and "Carlito 12 pt": two styles, two fonts.
    try testing.expectEqual(2, rep.styles_made);
    try testing.expectEqual(2, rep.fonts_made.items.len);
    const items = m.flowItems(p, r);
    // Run, break, run; separator, run; separator, run.
    try testing.expectEqual(7, items.len);
    try testing.expectEqualStrings("\\textnormal{Some \\textbf{bold} text, red.}", items[0].what.run.content);
    try testing.expect(items[1].what == .hard_break);
    try testing.expect(items[3].what == .paragraph);
    try testing.expectEqualStrings("\\textnormal{Second\\quad{}one.}", items[4].what.run.content);
    const carlito = m.textStyle(items[4].what.run.style).*;
    try testing.expectEqualStrings("Carlito 12 pt", carlito.name);
    try testing.expectApproxEqAbs(12 * mm_per_pt, carlito.em_size.?, 1e-9);
    try testing.expectEqual(m.paragraph_styles.items[0].alignment, .justify);
    try testing.expectEqual(m.paragraphStyleAt(p, r, 0), m.paragraphStyleAt(p, r, 4));

    // One undo takes it all back.
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.flowItems(p, r).len);
    try testing.expectEqual(0, m.paragraph_styles.items.len);
    try testing.expectEqual(1, m.styles.items.len);
}


test "plain text: a paragraph a line, tabs kept, line ends of any kind, Latin-1 read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try plain(a, "\xEF\xBB\xBFOne\ttwo\r\n\r\nThree $5 {x}\n");
    try testing.expectEqual(3, d.paragraphs.len);
    try testing.expectEqual(3, d.paragraphs[0].spans.len);
    try testing.expectEqualStrings("One", d.paragraphs[0].spans[0].text);
    try testing.expectEqual(0, d.paragraphs[1].spans.len);
    try testing.expectEqualStrings("Three $5 {x}", d.paragraphs[2].spans[0].text);
    const l1 = try plain(a, "caf\xe9");
    try testing.expectEqualStrings("caf\u{e9}", l1.paragraphs[0].spans[0].text);
}

test "a source's URI: relative in the document's folder, else file:, percent-encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("notes/chapter%202.md", try sourceUri(a, "/home/me/book/notes/chapter 2.md", "/home/me/book/"));
    try testing.expectEqualStrings("file:///home/me/other/caf%C3%A9%23.txt", try sourceUri(a, "/home/me/other/caf\u{e9}#.txt", "/home/me/book"));
    try testing.expectEqualStrings("file:///C:/Users/me/a.rtf", try sourceUri(a, "C:\\Users\\me\\a.rtf", null));
    // A folder of the same name's start is not the document's.
    try testing.expectEqualStrings("file:///home/me/bookends/x.txt", try sourceUri(a, "/home/me/bookends/x.txt", "/home/me/book"));
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha256Hex(""));
}

test "plain text into a new, unplaced flow: escaped, one undo step, its source kept" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: history.History = .init(gpa);
    defer h.deinit();
    const body = try m.addStyle("Body", .{ .cap_height = 2.5 });
    try h.reset(&m);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const doc = try plain(arena.allocator(), "First line costs $5\nSecond\n");
    const f = try h.doMerged(&m, 7, .addFlow, .{"notes"});
    var rep = try rich(gpa, &h, &m, 7, f, 0, doc, body, 4);
    defer rep.deinit(gpa);
    _ = try h.doMerged(&m, 7, .addFlowSource, .{ f, .{ .uri = "notes.txt", .sha256 = &sha256Hex("x"), .imported = 1763424000 } });
    const fl = m.flows.items[m.flowIndex(f).?];
    try testing.expectEqual(0, fl.tracks.items.len);
    // Run; separator, run.
    try testing.expectEqual(3, fl.items.items.len);
    try testing.expectEqualStrings("\\textnormal{First line costs \\$5}", fl.items.items[0].what.run.content);
    try testing.expectEqualStrings("notes.txt", fl.sources.items[0].uri);
    // Paragraphs that set nothing take no paragraph style.
    try testing.expectEqual(0, m.paragraph_styles.items.len);
    try testing.expect(fl.items.items[1].what.paragraph == null);
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.flows.items.len);
}


test "a table: quoted fields with separators, quotes and line breaks; tabs and semicolons found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try parseTable(a, "\xEF\xBB\xBFname,top,g\r\nK1,\"$x^2$, squared\",\"say \"\"hi\"\"\"\n\nK2,\"two\nlines\",\n");
    try testing.expectEqual(3, t.rows.len);
    try testing.expectEqualStrings("$x^2$, squared", t.rows[1][1]);
    try testing.expectEqualStrings("say \"hi\"", t.rows[1][2]);
    try testing.expectEqualStrings("two\nlines", t.rows[2][1]);
    try testing.expectEqualStrings("", t.rows[2][2]);
    const tabs = try parseTable(a, "name\ttop\nK1\ta,b\n");
    try testing.expectEqualStrings("a,b", tabs.rows[1][1]);
    const semi = try parseTable(a, "name;top;g\nK1;x;y\n");
    try testing.expectEqual(3, semi.rows[1].len);
}

test "a table fills a sheet: rows by name, new columns and rows, one undo step" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.addPanel("Keys", 60, 30);
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{ .{ .name = "top" }, .{ .name = "g" } } });
    const g = try m.addGrid(p, .{ .x = 10, .y = 20 }, .{ .cols = 2, .rows = 1, .pitch_x = 12, .pitch_y = 12 });
    const st = try m.addStamp(p, g, .{ .name = "Keys", .prototype = key, .w = 8, .h = 8 });
    const k1 = try m.addInstance(p, g, st, 0, 0);
    _ = try m.addInstance(p, g, st, 1, 0);
    var h: history.History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const scope = m.panels.items[p].grids.items[g].id;
    const sheet = try h.do(&m, .makeSheet, .{ "Legends", scope });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const names = m.sheets.items[0].rows.items;
    const csv = try std.fmt.allocPrint(arena.allocator(), "key,top,blue\n{s},$\\sqrt{{x}}$,ABS\nK99,new,\n{s},again,\n", .{ names[0].key, names[0].key });
    const t = try parseTable(arena.allocator(), csv);
    const rep = try sheetFromTable(gpa, &h, &m, 9, .{ .into = sheet }, t);
    try testing.expectEqual(1, rep.rows_matched);
    try testing.expectEqual(1, rep.rows_added);
    try testing.expectEqual(1, rep.columns_added);
    try testing.expectEqual(1, rep.repeated);
    // The later row for the first key stands; the key shows it.
    const text = try m.tileTrackText(gpa, k1, m.tileTrackNamed(k1, "top").?);
    defer gpa.free(text);
    try testing.expectEqualStrings("again", text);
    try testing.expectEqual(3, m.sheets.items[0].columns.items.len);
    // One undo: the sheet as made.
    _ = try h.undo(&m);
    try testing.expectEqual(2, m.sheets.items[0].columns.items.len);
    try testing.expectEqual(2, m.sheets.items[0].rows.items.len);
}

test "a table makes a new sheet over a keypad" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.addPanel("Keys", 60, 30);
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{.{ .name = "top" }} });
    const g = try m.addGrid(p, .{ .x = 10, .y = 20 }, .{ .cols = 1, .rows = 1, .pitch_x = 12, .pitch_y = 12 });
    const st = try m.addStamp(p, g, .{ .name = "Keys", .prototype = key, .w = 8, .h = 8 });
    const k = try m.addInstance(p, g, st, 0, 0);
    try m.renameTile(k, "ENTER");
    var h: history.History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = try parseTable(arena.allocator(), "name,top\nENTER,ENTER\n");
    const rep = try sheetFromTable(gpa, &h, &m, 3, .{ .new = .{ .name = "From CSV", .scope = m.panels.items[p].grids.items[g].id } }, t);
    try testing.expectEqual(1, rep.rows_added);
    const text = try m.tileTrackText(gpa, k, m.tileTrackNamed(k, "top").?);
    defer gpa.free(text);
    try testing.expectEqualStrings("ENTER", text);
}


test "a sheet as CSV reads back as it was" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.addPanel("Keys", 60, 30);
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{ .{ .name = "top" }, .{ .name = "g" } } });
    const g = try m.addGrid(p, .{ .x = 10, .y = 20 }, .{ .cols = 1, .rows = 1, .pitch_x = 12, .pitch_y = 12 });
    const st = try m.addStamp(p, g, .{ .name = "Keys", .prototype = key, .w = 8, .h = 8 });
    _ = try m.addInstance(p, g, st, 0, 0);
    const id = try m.addSheet("Legends", m.panels.items[p].grids.items[g].id, &.{ "top", "g" });
    try m.addSheetRow(id, null, "K1");
    try m.addSheetRow(id, null, "R2C3");
    try m.setSheetCell(id, 0, 1, "$x^2$, \"squared\"");
    try m.setSheetCell(id, 0, 2, "ON\nOFF");
    try m.setSheetCell(id, 1, 1, " padded ");
    try m.setSheetCell(id, 1, 2, "√x ⇄ Δ");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const csv = try sheetToCsv(a, &m, id);
    try testing.expect(std.mem.startsWith(u8, csv, "name,top,g\r\nK1,\"$x^2$, \"\"squared\"\"\",\"ON\nOFF\"\r\n"));
    const t = try parseTable(a, csv);
    try testing.expectEqual(3, t.rows.len);
    const sh = m.sheets.items[0];
    for (sh.rows.items, t.rows[1..]) |row, got| {
        try testing.expectEqualStrings(row.key, got[0]);
        for (row.cells.items, got[1..]) |cell, f| try testing.expectEqualStrings(cell, f);
    }
}
