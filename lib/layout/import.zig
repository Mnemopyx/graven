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
