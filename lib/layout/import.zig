//! Importing styled text (see the richtext library) into a track's flow:
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

/// Imports `doc` into the flow of track (`panel`, `region`) at item
/// `at`, with `base` the style of text that names no font or size. Returns
/// what was done; `gpa` holds the report's list and scratch work.
pub fn rich(gpa: Allocator, h: *history.History, m: *Model, key: u64, panel: usize, region: usize, at: usize, doc: rt.Doc, base: StyleId) !Report {
    var rep: Report = .{ .skipped = doc.skipped };
    errdefer rep.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var index = at;
    const track_pitch = m.panels.items[panel].regions.items[region].pitch;

    for (doc.paragraphs, 0..) |para, pi| {
        const ps = try paragraphStyle(h, m, key, para.settings, track_pitch, &rep);
        if (pi == 0 and index == 0) {
            _ = try h.doMerged(m, key, .setParagraphAt, .{ panel, region, 0, ps });
        } else {
            _ = try h.doMerged(m, key, .insertParagraph, .{ panel, region, index, ps });
            index += 1;
        }
        rep.paragraphs += 1;

        // Stretches of one font and size, cut at line breaks.
        var k: usize = 0;
        const spans = para.spans;
        while (k < spans.len) {
            if (spans[k].kind == .line_break) {
                index += try h.doMerged(m, key, .insertBreak, .{ panel, region, index });
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
            _ = try h.doMerged(m, key, .insertRun, .{ panel, region, index, .{ .style = style, .content = out.written() } });
            index += 1;
            rep.runs += 1;
            k = end;
        }
    }
    return rep;
}

/// The paragraph style for `s`: an existing one with the same settings,
/// else a new one.
fn paragraphStyle(h: *history.History, m: *Model, key: u64, s: rt.Settings, track_pitch: f64, rep: *Report) !ParaId {
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
    return h.doMerged(m, key, .addParagraphStyle, .{named});
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
    var rep = try rich(gpa, &h, &m, 42, p, r, 0, doc, body);
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
    const items = m.panels.items[p].regions.items[r].items.items;
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
    try testing.expectEqual(0, m.panels.items[p].regions.items[r].items.items.len);
    try testing.expectEqual(0, m.paragraph_styles.items.len);
    try testing.expectEqual(1, m.styles.items.len);
}
