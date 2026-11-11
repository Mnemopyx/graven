//! An RTF reader: RTF 1.x as word processors write it, read into styled
//! text (see root.zig). It keeps text, paragraphs and their settings,
//! fonts, sizes, weight, slant, underline, strikethrough, super- and
//! subscripts, colours, line breaks and tabs; a field keeps its shown text
//! (a link's words). Pictures, footnotes, objects and tables' structure are
//! left out and counted (a table's cells come through as tab-separated
//! paragraphs). Characters outside Unicode escapes are read in code page
//! 1252 (Windows Western), the usual one; others are counted as unmapped.

const std = @import("std");
const rt = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{NotRtf};

/// Twips (1/20 pt) to mm.
fn mm(twips: i32) f64 {
    return @as(f64, @floatFromInt(twips)) / 1440.0 * 25.4;
}

/// What a group is reading into.
const Dest = enum {
    text,
    /// Skipped, with its groups.
    skip,
    font_table,
    color_table,
    /// A field's instruction: skipped; its result is text.
    field_inst,
};

const State = struct {
    dest: Dest = .text,
    look: rt.Look = .{},
    para: rt.Settings = .{},
    /// \ucN: characters standing in for each \u that follow it.
    uc: u32 = 1,
};

const Reader = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,
    stack: std.ArrayList(State) = .empty,
    st: State = .{},
    default_font: ?u16 = null,
    fonts: std.ArrayList(rt.Font) = .empty,
    font_ids: std.ArrayList(i32) = .empty,
    colors: std.ArrayList(?rt.Color) = .empty,
    color: rt.Color = .{ .r = 0, .g = 0, .b = 0 },
    color_set: bool = false,
    /// The font table entry being read.
    font_entry: ?struct { id: i32, kind: @FieldType(rt.Font, "kind") = .any, name: std.ArrayList(u8) = .empty } = null,
    paragraphs: std.ArrayList(rt.Paragraph) = .empty,
    spans: std.ArrayList(rt.Span) = .empty,
    text: std.ArrayList(u8) = .empty,
    text_look: rt.Look = .{},
    skipped: rt.Skipped = .{},
    /// Characters still to skip after a \u.
    skip_chars: u32 = 0,
    /// The high half of a UTF-16 pair from \u.
    high: ?u16 = null,
    /// Set by \*: the group's destination is optional; skip it unless
    /// known.
    star: bool = false,
    /// Whether the group just opened has had its first control word.
    group_start: bool = false,

    fn flushText(r: *Reader) Allocator.Error!void {
        if (r.text.items.len == 0) return;
        try r.spans.append(r.a, .{ .text = try r.text.toOwnedSlice(r.a), .look = r.text_look });
    }

    fn char(r: *Reader, cp: u21) Allocator.Error!void {
        switch (r.st.dest) {
            .skip, .field_inst, .color_table => return,
            .font_table => {
                if (r.font_entry) |*e| {
                    if (cp == ';') return r.endFont();
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return;
                    try e.name.appendSlice(r.a, buf[0..n]);
                }
                return;
            },
            .text => {},
        }
        if (!r.text_look.eql(r.st.look)) {
            try r.flushText();
            r.text_look = r.st.look;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try r.text.appendSlice(r.a, buf[0..n]);
    }

    fn special(r: *Reader, kind: @FieldType(rt.Span, "kind")) Allocator.Error!void {
        if (r.st.dest != .text) return;
        try r.flushText();
        try r.spans.append(r.a, .{ .kind = kind, .look = r.st.look });
    }

    fn endParagraph(r: *Reader) Allocator.Error!void {
        if (r.st.dest != .text) return;
        try r.flushText();
        try r.paragraphs.append(r.a, .{ .settings = r.st.para, .spans = try r.spans.toOwnedSlice(r.a) });
    }

    fn endFont(r: *Reader) Allocator.Error!void {
        const e = r.font_entry orelse return;
        r.font_entry = null;
        const name = std.mem.trim(u8, e.name.items, " ");
        try r.fonts.append(r.a, .{ .name = name, .kind = e.kind });
        try r.font_ids.append(r.a, e.id);
    }

    fn fontIndex(r: *const Reader, id: i32) ?u16 {
        for (r.font_ids.items, 0..) |f, k| if (f == id) return @intCast(k);
        return null;
    }

    /// A character from \'hh, in code page 1252.
    fn byteChar(r: *Reader, b: u8) Allocator.Error!void {
        if (r.skip_chars > 0) {
            r.skip_chars -= 1;
            return;
        }
        try r.char(cp1252(b));
    }

    fn word(r: *Reader, name: []const u8, param: ?i32) Allocator.Error!void {
        const first = r.group_start;
        r.group_start = false;
        const p = param orelse 1;
        const on = param == null or param.? != 0;
        const W = enum {
            // destinations
            fonttbl, colortbl, stylesheet, info, pict, header, headerl, headerr, headerf, footer, footerl, footerr, footerf,
            footnote, object, field, fldinst, fldrslt, listtable, listoverridetable, nonshppict, xmpinfo, themedata, latentstyles,
            // font table
            f, fnil, froman, fswiss, fmodern, fscript, fdecor, ftech, fbidi, deff,
            // colours
            red, green, blue,
            // characters
            plain, b, i, ul, uld, uldb, ulw, uldash, ulth, ulwave, ulnone, strike, striked, super, sub, nosupersub, up, dn, fs, cf, u, uc,
            // paragraphs
            par, pard, line, tab, page, sect, ql, qc, qr, qj, li, ri, fi, sb, sa, sl,
            // tables
            cell, row, trowd,
            // special characters
            emdash, endash, bullet, lquote, rquote, ldblquote, rdblquote, emspace, enspace, qmspace, zwj, zwnj,
        };
        const w = std.meta.stringToEnum(W, name) orelse {
            // An unknown destination after \* goes with its group.
            if (first and r.star) r.st.dest = .skip;
            r.star = false;
            return;
        };
        r.star = false;
        switch (w) {
            .fonttbl => r.st.dest = .font_table,
            .colortbl => r.st.dest = .color_table,
            .stylesheet, .info, .header, .headerl, .headerr, .headerf, .footer, .footerl, .footerr, .footerf, .listtable, .listoverridetable, .nonshppict, .xmpinfo, .themedata, .latentstyles => r.st.dest = .skip,
            .pict => {
                if (r.st.dest == .text) r.skipped.pictures += 1;
                r.st.dest = .skip;
            },
            .footnote => {
                if (r.st.dest == .text) r.skipped.footnotes += 1;
                r.st.dest = .skip;
            },
            .object => {
                if (r.st.dest == .text) r.skipped.objects += 1;
                r.st.dest = .skip;
            },
            .field => if (r.st.dest == .text) {
                r.skipped.fields += 1;
            },
            .fldinst => r.st.dest = .field_inst,
            .fldrslt => {},
            .f => if (r.st.dest == .font_table) {
                if (r.font_entry != null) try r.endFont();
                r.font_entry = .{ .id = p };
            } else {
                r.st.look.font = r.fontIndex(p);
            },
            .fnil, .froman, .fswiss, .fmodern, .fscript, .fdecor, .ftech, .fbidi => if (r.font_entry) |*e| {
                e.kind = switch (w) {
                    .froman => .roman,
                    .fswiss => .swiss,
                    .fmodern => .modern,
                    .fscript => .script,
                    .fdecor => .decor,
                    .ftech => .tech,
                    .fbidi => .bidi,
                    else => .any,
                };
            },
            .deff => r.default_font = @intCast(@max(0, p)),
            .red => r.color.r = @intCast(std.math.clamp(p, 0, 255)),
            .green => r.color.g = @intCast(std.math.clamp(p, 0, 255)),
            .blue => r.color.b = @intCast(std.math.clamp(p, 0, 255)),
            .plain => {
                r.st.look = .{ .font = if (r.default_font) |d| r.fontIndex(d) else null };
            },
            .b => r.st.look.bold = on,
            .i => r.st.look.italic = on,
            .ul, .uld, .uldb, .ulw, .uldash, .ulth, .ulwave => r.st.look.underline = on,
            .ulnone => r.st.look.underline = false,
            .strike, .striked => r.st.look.strike = on,
            .super => r.st.look.script = .sup,
            .sub => r.st.look.script = .sub,
            .nosupersub => r.st.look.script = .none,
            .up => r.st.look.script = if (p > 0) .sup else .none,
            .dn => r.st.look.script = if (p > 0) .sub else .none,
            .fs => r.st.look.size = @as(f64, @floatFromInt(@max(1, p))) / 2,
            .cf => r.st.look.color = if (p > 0) @intCast(p) else null,
            .uc => r.st.uc = @intCast(@max(0, p)),
            .u => {
                // Signed 16-bit; pairs of surrogates make one character.
                const unit: u16 = @bitCast(@as(i16, @truncate(p)));
                r.skip_chars = r.st.uc;
                if (unit >= 0xD800 and unit < 0xDC00) {
                    r.high = unit;
                    return;
                }
                if (unit >= 0xDC00 and unit < 0xE000) {
                    if (r.high) |h| {
                        r.high = null;
                        const cp: u21 = 0x10000 + ((@as(u21, h) - 0xD800) << 10) + (@as(u21, unit) - 0xDC00);
                        return r.char(cp);
                    }
                    return;
                }
                r.high = null;
                try r.char(unit);
            },
            .par, .page, .sect => try r.endParagraph(),
            .pard => r.st.para = .{},
            .line => try r.special(.line_break),
            .tab, .cell => try r.special(.tab),
            .row => {
                r.skipped.table_rows += 1;
                try r.endParagraph();
            },
            .trowd => {},
            .ql => r.st.para.alignment = .start,
            .qc => r.st.para.alignment = .centre,
            .qr => r.st.para.alignment = .end,
            .qj => r.st.para.alignment = .justify,
            .li => r.st.para.indent_start = @max(0, mm(p)),
            .ri => r.st.para.indent_end = @max(0, mm(p)),
            .fi => r.st.para.first = mm(p),
            .sb => r.st.para.space_before = @max(0, mm(p)),
            .sa => r.st.para.space_after = @max(0, mm(p)),
            .sl => r.st.para.line_pitch = if (p == 0) null else @abs(mm(p)),
            .emdash => try r.char(0x2014),
            .endash => try r.char(0x2013),
            .bullet => try r.char(0x2022),
            .lquote => try r.char(0x2018),
            .rquote => try r.char(0x2019),
            .ldblquote => try r.char(0x201C),
            .rdblquote => try r.char(0x201D),
            .emspace => try r.char(0x2003),
            .enspace => try r.char(0x2002),
            .qmspace => try r.char(0x2005),
            .zwj => try r.char(0x200D),
            .zwnj => try r.char(0x200C),
        }
    }

    fn run(r: *Reader) Error!void {
        const s = r.src;
        while (r.i < s.len) {
            const c = s[r.i];
            switch (c) {
                '{' => {
                    r.i += 1;
                    try r.stack.append(r.a, r.st);
                    r.group_start = true;
                },
                '}' => {
                    r.i += 1;
                    // The font table's entries end with their groups too.
                    if (r.st.dest == .font_table and r.font_entry != null) try r.endFont();
                    const was = r.st.dest;
                    r.st = r.stack.pop() orelse r.st;
                    if (was == .color_table and r.st.dest != .color_table and r.color_set) {
                        try r.colors.append(r.a, r.color);
                        r.color_set = false;
                    }
                    r.star = false;
                    r.group_start = false;
                },
                '\\' => {
                    r.i += 1;
                    if (r.i >= s.len) break;
                    const d = s[r.i];
                    if (std.ascii.isAlphabetic(d)) {
                        const start = r.i;
                        while (r.i < s.len and std.ascii.isAlphabetic(s[r.i])) r.i += 1;
                        const name = s[start..r.i];
                        var param: ?i32 = null;
                        const ps = r.i;
                        if (r.i < s.len and (s[r.i] == '-' or std.ascii.isDigit(s[r.i]))) {
                            r.i += 1;
                            while (r.i < s.len and std.ascii.isDigit(s[r.i])) r.i += 1;
                            param = std.fmt.parseInt(i32, s[ps..r.i], 10) catch null;
                        }
                        if (r.i < s.len and s[r.i] == ' ') r.i += 1;
                        // \u's stand-ins are counted from here on.
                        const was_skipping = r.skip_chars;
                        if (r.st.dest == .color_table and (std.mem.eql(u8, name, "red") or std.mem.eql(u8, name, "green") or std.mem.eql(u8, name, "blue"))) r.color_set = true;
                        if (was_skipping > 0 and !std.mem.eql(u8, name, "u")) {
                            // A control word counts as one stand-in.
                            r.skip_chars -= 1;
                            continue;
                        }
                        try r.word(name, param);
                        continue;
                    }
                    r.i += 1;
                    switch (d) {
                        '\'' => {
                            if (r.i + 2 <= s.len) {
                                const b = std.fmt.parseInt(u8, s[r.i .. r.i + 2], 16) catch 0x3F;
                                r.i += 2;
                                try r.byteChar(b);
                            }
                        },
                        '\\', '{', '}' => try r.plainChar(d),
                        '~' => try r.plainChar2(0x00A0),
                        '-' => try r.plainChar2(0x00AD),
                        '_' => try r.plainChar2(0x2011),
                        // \* comes before its group's first word.
                        '*' => {
                            r.star = true;
                            continue;
                        },
                        '\n', '\r' => try r.endParagraph(),
                        else => {},
                    }
                    r.group_start = false;
                },
                '\n', '\r' => r.i += 1,
                ';' => {
                    r.i += 1;
                    if (r.st.dest == .color_table) {
                        try r.colors.append(r.a, if (r.color_set) r.color else null);
                        r.color = .{ .r = 0, .g = 0, .b = 0 };
                        r.color_set = false;
                    } else try r.plainChar(';');
                },
                else => {
                    // UTF-8 text is read as it is (some writers emit it);
                    // plain RTF is ASCII here.
                    const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                    const end = @min(s.len, r.i + len);
                    const cp = std.unicode.utf8Decode(s[r.i..end]) catch c;
                    r.i = end;
                    try r.plainChar2(cp);
                },
            }
        }
        try r.flushText();
        if (r.spans.items.len > 0) try r.paragraphs.append(r.a, .{ .settings = r.st.para, .spans = try r.spans.toOwnedSlice(r.a) });
    }

    fn plainChar(r: *Reader, b: u8) Allocator.Error!void {
        return r.plainChar2(b);
    }

    fn plainChar2(r: *Reader, cp: u21) Allocator.Error!void {
        r.group_start = false;
        if (r.skip_chars > 0) {
            r.skip_chars -= 1;
            return;
        }
        try r.char(cp);
    }
};

/// Reads RTF `src` into styled text, allocated from `a` (an arena suits).
pub fn read(a: Allocator, src: []const u8) Error!rt.Doc {
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, src, " \t\r\n"), "{\\rtf")) return error.NotRtf;
    var r: Reader = .{ .a = a, .src = src };
    try r.run();
    // A paragraph's own trailing empty spans aside, drop empty paragraphs
    // at the very end (the closing \par).
    var paras = r.paragraphs.items;
    while (paras.len > 0 and paras[paras.len - 1].spans.len == 0) paras = paras[0 .. paras.len - 1];
    // Text that names no font is in the document's default (\deff).
    if (r.default_font) |d| if (r.fontIndex(d)) |fi| for (paras) |p| {
        for (@constCast(p.spans)) |*sp| if (sp.look.font == null) {
            sp.look.font = fi;
        };
    };
    return .{ .fonts = r.fonts.items, .colors = r.colors.items, .paragraphs = paras, .skipped = r.skipped };
}

/// Code page 1252: Latin-1, with typographic characters in 0x80–0x9F.
fn cp1252(b: u8) u21 {
    const high = [32]u21{
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    };
    return if (b >= 0x80 and b < 0xA0) high[b - 0x80] else b;
}

// Tests ---------------------------------------------------------------------------

const testing = std.testing;

fn spanText(p: rt.Paragraph, k: usize) []const u8 {
    return p.spans[k].text;
}

test "text, weights, sizes and fonts, in paragraphs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src =
        \\{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}{\f1\fswiss Arial;}}
        \\{\colortbl;\red255\green0\blue0;}
        \\{\*\generator Some Writer;}
        \\\pard\qj\li720\fi-360\sa120 Plain \b bold\b0  and {\i italic \ul under}\ulnone  back.\par
        \\\pard\qc\f1\fs32 Big \cf1 red\cf0  caf\'e9 \u8364?\line next\tab cell\par
        \\}
    ;
    const doc = try read(arena.allocator(), src);
    try testing.expectEqual(2, doc.fonts.len);
    try testing.expectEqualStrings("Times New Roman", doc.fonts[0].name);
    try testing.expect(doc.fonts[1].kind == .swiss);
    try testing.expectEqual(2, doc.colors.len);
    try testing.expectEqual(null, doc.colors[0]);
    try testing.expectEqual(@as(u8, 255), doc.colors[1].?.r);
    try testing.expectEqual(2, doc.paragraphs.len);

    const p0 = doc.paragraphs[0];
    try testing.expect(p0.settings.alignment == .justify);
    try testing.expectApproxEqAbs(@as(f64, 12.7), p0.settings.indent_start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -6.35), p0.settings.first, 1e-9);
    try testing.expectEqualStrings("Plain ", spanText(p0, 0));
    try testing.expectEqualStrings("bold", spanText(p0, 1));
    try testing.expect(p0.spans[1].look.bold);
    try testing.expectEqualStrings(" and ", spanText(p0, 2));
    try testing.expectEqualStrings("italic ", spanText(p0, 3));
    try testing.expect(p0.spans[3].look.italic and !p0.spans[3].look.underline);
    try testing.expect(p0.spans[4].look.italic and p0.spans[4].look.underline);
    try testing.expectEqualStrings(" back.", spanText(p0, 5));
    try testing.expect(!p0.spans[5].look.italic);

    const p1 = doc.paragraphs[1];
    try testing.expect(p1.settings.alignment == .centre);
    try testing.expectEqual(0, p1.settings.indent_start);
    try testing.expectEqual(@as(?u16, 1), p1.spans[0].look.font);
    try testing.expectEqual(@as(?f64, 16), p1.spans[0].look.size);
    try testing.expectEqual(@as(?u16, 1), p1.spans[1].look.color);
    try testing.expectEqualStrings(" café €", spanText(p1, 2));
    try testing.expect(p1.spans[3].kind == .line_break);
    try testing.expectEqualStrings("next", spanText(p1, 4));
    try testing.expect(p1.spans[5].kind == .tab);
}

test "skipped destinations are counted, fields keep their shown text, and \\u pairs join" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src =
        \\{\rtf1\ansi{\info{\title Not text}}
        \\See {\field{\*\fldinst HYPERLINK "https://x"}{\fldrslt the site}}{\*\unknown gone}
        \\{\pict\pngblip 89504e47}{\footnote A note.}\uc0\u-10179\u-8704  ok\~done\par}
    ;
    const doc = try read(arena.allocator(), src);
    try testing.expectEqual(1, doc.paragraphs.len);
    var all: std.ArrayList(u8) = .empty;
    for (doc.paragraphs[0].spans) |sp| try all.appendSlice(arena.allocator(), sp.text);
    try testing.expectEqualStrings("See the site\u{1F600} ok\u{00A0}done", all.items);
    try testing.expectEqual(1, doc.skipped.fields);
    try testing.expectEqual(1, doc.skipped.pictures);
    try testing.expectEqual(1, doc.skipped.footnotes);
}

test "not RTF is refused" {
    try testing.expectError(error.NotRtf, read(testing.allocator, "hello"));
}
