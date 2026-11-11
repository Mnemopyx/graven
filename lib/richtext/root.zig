//! Styled text as readers find it: paragraphs with their settings, and
//! spans of text with their font, size, weight, slant, decorations and
//! colour. Readers (RTF first) produce it; Graven's import turns it into
//! flow items, styles and paragraph styles. It knows nothing of Graven's
//! model, and only `writeMarkup` knows Graven's markup.

const std = @import("std");
pub const rtf = @import("rtf.zig");

pub const Align = enum { start, centre, end, justify };
pub const Script = enum { none, sup, sub };

pub const Font = struct {
    name: []const u8,
    /// The family's kind, as RTF classes it: a fallback's hint.
    kind: enum { any, roman, swiss, modern, script, decor, tech, bidi } = .any,
};

pub const Color = struct { r: u8, g: u8, b: u8 };

/// How one span looks.
pub const Look = struct {
    font: ?u16 = null,
    /// Points.
    size: ?f64 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    script: Script = .none,
    color: ?u16 = null,

    pub fn eql(a: Look, b: Look) bool {
        return std.meta.eql(a, b);
    }
};

pub const Span = struct {
    kind: enum { text, line_break, tab } = .text,
    /// UTF-8. A soft hyphen (U+00AD) marks where a word may break.
    text: []const u8 = "",
    look: Look = .{},
};

/// A paragraph's settings. Lengths in mm.
pub const Settings = struct {
    alignment: Align = .start,
    indent_start: f64 = 0,
    indent_end: f64 = 0,
    /// The first line's further indent; negative for a hanging one.
    first: f64 = 0,
    space_before: f64 = 0,
    space_after: f64 = 0,
    /// Baseline to baseline, when the source sets one.
    line_pitch: ?f64 = null,

    pub fn eql(a: Settings, b: Settings) bool {
        return std.meta.eql(a, b);
    }
};

pub const Paragraph = struct {
    settings: Settings = .{},
    spans: []const Span = &.{},
};

/// What a reader left out, by kind, for the import to list.
pub const Skipped = struct {
    pictures: usize = 0,
    table_rows: usize = 0,
    fields: usize = 0,
    footnotes: usize = 0,
    objects: usize = 0,
    /// Characters in code pages the reader does not map (shown as `?`).
    unmapped: usize = 0,

    pub fn any(s: Skipped) bool {
        return s.pictures + s.table_rows + s.fields + s.footnotes + s.objects + s.unmapped > 0;
    }
};

pub const Doc = struct {
    fonts: []const Font = &.{},
    colors: []const ?Color = &.{},
    paragraphs: []const Paragraph = &.{},
    skipped: Skipped = .{},
};

/// Writes `spans` (text and tabs; line breaks are the import's) as Graven
/// markup: each
/// run of spans that look alike in weight, slant, decorations and script,
/// in the commands for them. Font, size and colour are the import's: they
/// choose a style, not markup.
pub fn writeMarkup(w: *std.Io.Writer, spans: []const Span) std.Io.Writer.Error!void {
    for (spans) |sp| {
        // A tab: a quad's space, for now (tab stops are to come).
        if (sp.kind == .tab) {
            try w.writeAll("\\quad{}");
            continue;
        }
        if (sp.kind != .text or sp.text.len == 0) continue;
        const l = sp.look;
        var open: usize = 0;
        if (l.bold) {
            try w.writeAll("\\textbf{");
            open += 1;
        }
        if (l.italic) {
            try w.writeAll("\\textit{");
            open += 1;
        }
        if (l.underline) {
            try w.writeAll("\\underline{");
            open += 1;
        }
        if (l.strike) {
            try w.writeAll("\\sout{");
            open += 1;
        }
        switch (l.script) {
            .none => {},
            .sup => {
                try w.writeAll("\\textsuperscript{");
                open += 1;
            },
            .sub => {
                try w.writeAll("\\textsubscript{");
                open += 1;
            },
        }
        try escape(w, sp.text);
        for (0..open) |_| try w.writeByte('}');
    }
}

/// `text` as markup that reads back as itself.
pub fn escape(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cs| {
        if (cs.len == 1) switch (cs[0]) {
            '{', '}', '_', '^', '&', '%', '#', '$', '~' => {
                try w.print("\\{c}", .{cs[0]});
                continue;
            },
            '\\' => {
                try w.writeAll("\\textbackslash{}");
                continue;
            },
            '\t', '\n', '\r' => {
                try w.writeByte(' ');
                continue;
            },
            else => {},
        };
        const cp = std.unicode.utf8Decode(cs) catch 0xFFFD;
        switch (cp) {
            0x00A0 => try w.writeByte('~'),
            0x00AD => try w.writeAll("\\-"),
            else => try w.writeAll(cs),
        }
    }
}

test "spans become markup, escaped, in their variants' commands" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMarkup(&out.writer, &.{
        .{ .text = "50% of {x}: " },
        .{ .text = "bold", .look = .{ .bold = true, .italic = true } },
        .{ .kind = .line_break },
        .{ .text = "st", .look = .{ .script = .sup, .underline = true } },
        .{ .text = "a\u{00A0}b\u{00AD}c\\" },
    });
    try std.testing.expectEqualStrings("50\\% of \\{x\\}: \\textbf{\\textit{bold}}\\underline{\\textsuperscript{st}}a~b\\-c\\textbackslash{}", out.written());
}

test {
    _ = rtf;
}
