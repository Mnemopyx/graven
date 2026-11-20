//! LaTeX as KaTeX takes it, to objects and back.
//!
//! Math: letters are variables, digit runs numbers, `+ - * = < > , ; ! /`
//! and Unicode symbols by the symbol table; `\frac`, `\sqrt[n]{}`, `^`
//! and `_` (scripts, or a large operator's limits), `\left…\right`, plain
//! `( )` and `[ ]` (fences at their natural size, so scripts attach to the
//! group), `{ }` groups, accents, `\mathrm`/`\text`/`\operatorname` words,
//! `\limits`/`\nolimits`; spacing commands are dropped.
//!
//! A legend: text, with math between dollars, as v1's markup has it; the
//! text becomes upright words, `\%` and the like unescaped.
//!
//! Parsing never fails (see entry.zig): every prefix gives a whole tree.

const std = @import("std");
const param = @import("param.zig");
const ex = @import("expr.zig");
const entry = @import("entry.zig");
const symbols = @import("symbols.zig");

const Allocator = std.mem.Allocator;
const Expr = ex.Expr;
const Id = ex.Id;
const Kind = ex.Kind;
const Variant = ex.Variant;
const Span = entry.Span;
const Spans = entry.Spans;

pub const Mode = enum {
    /// All math.
    math,
    /// Text with math between dollars.
    legend,
};

/// Parses `src` into `e`'s (empty) top row, recording spans.
pub fn parse(e: *Expr, spans: *Spans, src: []const u8, mode: Mode) ex.Error!void {
    var p: Parser = .{ .e = e, .spans = spans, .src = src };
    switch (mode) {
        .math => try p.row(e.root, .{}),
        .legend => try p.legend(),
    }
}

const Stop = struct {
    brace: bool = false,
    bracket: bool = false,
    right: bool = false,
    dollar: bool = false,
    /// A plain fence's closing character.
    close: ?u8 = null,
};

const Parser = struct {
    e: *Expr,
    spans: *Spans,
    src: []const u8,
    i: usize = 0,

    fn gpa(p: *Parser) Allocator {
        return p.e.gpa;
    }

    fn eof(p: *Parser) bool {
        return p.i >= p.src.len;
    }

    fn skip(p: *Parser) void {
        while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t' or p.src[p.i] == '\n' or p.src[p.i] == '\r')) p.i += 1;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.i..], s);
    }

    fn mark(p: *Parser, id: Id, start: usize) ex.Error!void {
        try p.spans.set(p.gpa(), id, .{ .start = @intCast(start), .end = @intCast(p.i) });
    }

    fn tag(p: *Parser, id: Id, source: []const u8) void {
        p.e.node(id).tags = .{ .source = source, .syntax = .latex };
    }

    // Legends --------------------------------------------------------------------

    fn legend(p: *Parser) ex.Error!void {
        const root = p.e.root;
        var text: entry.Text = .{};
        defer text.deinit(p.gpa());
        // Groups open in the text: the letterforms outside each.
        var outside: [32]ex.Variant = undefined;
        var depth: usize = 0;
        while (!p.eof()) {
            const c = p.src[p.i];
            // Emphasis: \textbf{…}, \textit{…}, \emph{…}; a bare group
            // keeps what it is in.
            const opens: ?ex.Variant = for ([_]struct { []const u8, ex.Variant }{
                .{ "\\textbf{", .bold },
                .{ "\\textit{", .italic },
                .{ "\\emph{", .italic },
                .{ "\\textrm{", .normal },
                .{ "\\textup{", .normal },
                .{ "\\textnormal{", .normal },
                .{ "{", .normal },
            }) |o| {
                if (p.startsWith(o[0])) break o[1];
            } else null;
            if (opens) |v| if (depth < outside.len) {
                try text.flush(p.e, p.spans, p.e.root, p.i);
                p.i = std.mem.indexOfScalarPos(u8, p.src, p.i, '{').? + 1;
                outside[depth] = text.variant;
                depth += 1;
                text.variant = text.variant.with(v);
                continue;
            };
            if (c == '}' and depth > 0) {
                try text.flush(p.e, p.spans, p.e.root, p.i);
                p.i += 1;
                depth -= 1;
                text.variant = outside[depth];
                continue;
            }
            if (c == '$') {
                try text.flush(p.e, p.spans, p.e.root, p.i);
                p.i += 1;
                try p.row(root, .{ .dollar = true });
                if (!p.eof() and p.src[p.i] == '$') p.i += 1;
                continue;
            }
            // Graven's call form in text: overrides on the text the braces
            // hold (one word: the word itself carries them).
            if (p.startsWith("\\set(")) {
                try text.flush(p.e, p.spans, p.e.root, p.i);
                const start = p.i;
                const g = try p.e.structure(.group, "", "");
                try p.e.append(root, g);
                p.tag(g, "\\set");
                p.i = try entry.parseArgs(p.e, g, p.src, p.i + "\\set(".len);
                if (!p.eof() and p.src[p.i] == ')') p.i += 1;
                if (!p.eof() and p.src[p.i] == '{') {
                    p.i += 1;
                    var inner: entry.Text = .{ .variant = text.variant };
                    defer inner.deinit(p.gpa());
                    var level: usize = 1;
                    while (!p.eof()) : (p.i += 1) {
                        const ch = p.src[p.i];
                        if (ch == '{') level += 1;
                        if (ch == '}') {
                            level -= 1;
                            if (level == 0) break;
                        }
                        try inner.add(p.gpa(), p.src[p.i .. p.i + 1], p.i);
                    }
                    try inner.flush(p.e, p.spans, p.e.slot(g, .body), p.i);
                    if (!p.eof()) p.i += 1;
                }
                try p.mark(try entry.unwrapCall(p.e, g), start);
                continue;
            }
            if (p.startsWith("\\-")) {
                try text.add(p.gpa(), entry.soft_hyphen, p.i);
                p.i += 2;
                continue;
            }
            if (p.startsWith("\\allowbreak")) {
                try text.add(p.gpa(), entry.allow_mark, p.i);
                p.i += "\\allowbreak".len;
                if (p.startsWith("{}")) p.i += 2 else if (p.startsWith(" ")) p.i += 1;
                continue;
            }
            // A quad (an imported tab): a space, a place to break.
            if (p.startsWith("\\qquad") or p.startsWith("\\quad")) {
                try text.add(p.gpa(), " ", p.i);
                p.i += if (p.startsWith("\\qquad")) "\\qquad".len else "\\quad".len;
                if (p.startsWith("{}")) p.i += 2;
                continue;
            }
            if (p.startsWith("\\textbackslash")) {
                try text.add(p.gpa(), "\\", p.i);
                p.i += "\\textbackslash".len;
                if (p.startsWith("{}")) p.i += 2;
                continue;
            }
            if (c == '\\' and p.i + 1 < p.src.len and !std.ascii.isAlphabetic(p.src[p.i + 1])) {
                try text.add(p.gpa(), p.src[p.i + 1 .. p.i + 2], p.i);
                p.i += 2;
                continue;
            }
            try text.add(p.gpa(), p.src[p.i .. p.i + 1], p.i);
            p.i += 1;
        }
        try text.flush(p.e, p.spans, p.e.root, p.i);
    }


    // Math -----------------------------------------------------------------------

    fn stops(p: *Parser, s: Stop) bool {
        if (p.eof()) return true;
        const c = p.src[p.i];
        if (s.brace and c == '}') return true;
        if (s.bracket and c == ']') return true;
        if (s.dollar and c == '$') return true;
        if (s.close) |cl| if (c == cl) return true;
        if (s.right and p.startsWith("\\right")) return true;
        return false;
    }

    fn row(p: *Parser, r: Id, s: Stop) ex.Error!void {
        while (true) {
            p.skip();
            if (p.stops(s)) break;
            const c = p.src[p.i];
            if (c == '^' or c == '_') {
                const start = p.i;
                p.i += 1;
                const t = try entry.scriptTarget(p.e, r, if (c == '^') .sup else .sub);
                if (p.spans.get(t.structure).start == Span.none.start) try p.mark(t.structure, start);
                try p.arg(t.row);
                try p.spans.extend(p.gpa(), t.structure, p.i);
                continue;
            }
            if (c == '\'') {
                // A prime: a superscript ′.
                p.i += 1;
                const t = try entry.scriptTarget(p.e, r, .sup);
                const pr = try p.e.leaf(.symbol, "′");
                try p.e.append(t.row, pr);
                try p.mark(pr, p.i - 1);
                continue;
            }
            // A closer that is not ours (a stray } or ]) stands as itself.
            if (c == '}' or c == ']' or c == ')') {
                const start = p.i;
                p.i += 1;
                try p.add(r, .symbol, p.src[start..p.i], start, "");
                continue;
            }
            try p.one(r, false);
        }
        entry.fixRoles(p.e, r);
    }

    /// An argument: a braced row, or one token (one digit, one letter, one
    /// command), or nothing (a hole) at the end.
    fn arg(p: *Parser, dest: Id) ex.Error!void {
        p.skip();
        if (p.eof()) return;
        const c = p.src[p.i];
        if (c == '{') {
            p.i += 1;
            const s0 = p.i;
            try p.row(dest, .{ .brace = true });
            // The field: what the braces hold.
            try p.spans.set(p.gpa(), dest, .{ .start = @intCast(s0), .end = @intCast(p.i) });
            if (!p.eof() and p.src[p.i] == '}') p.i += 1;
            return;
        }
        if (c == '}' or c == ']' or c == '$' or c == '^' or c == '_') return;
        const s0 = p.i;
        try p.one(dest, true);
        try p.spans.set(p.gpa(), dest, .{ .start = @intCast(s0), .end = @intCast(p.i) });
        entry.fixRoles(p.e, dest);
    }

    fn add(p: *Parser, r: Id, kind: Kind, text: []const u8, start: usize, source: []const u8) ex.Error!void {
        const id = if (kind == .large_op) try p.e.structure(.large_op, text, "") else if (kind == .operator) try p.e.operator(text, .binary) else try p.e.leaf(kind, text);
        try p.e.append(r, id);
        p.tag(id, source);
        try p.mark(id, start);
    }

    /// One token's object into `r`; `single` for an argument (one digit).
    fn one(p: *Parser, r: Id, single: bool) ex.Error!void {
        const start = p.i;
        const c = p.src[p.i];
        if (std.ascii.isDigit(c) or (c == '.' and p.i + 1 < p.src.len and std.ascii.isDigit(p.src[p.i + 1]))) {
            p.i += 1;
            if (!single) while (!p.eof() and (std.ascii.isDigit(p.src[p.i]) or (p.src[p.i] == '.' and p.i + 1 < p.src.len and std.ascii.isDigit(p.src[p.i + 1])))) {
                p.i += 1;
            };
            return p.add(r, .number, p.src[start..p.i], start, "");
        }
        if (std.ascii.isAlphabetic(c)) {
            p.i += 1;
            return p.add(r, .variable, p.src[start..p.i], start, "");
        }
        switch (c) {
            '{' => {
                p.i += 1;
                const g = try p.e.structure(.group, "", "");
                try p.e.append(r, g);
                p.tag(g, "{");
                try p.row(p.e.slot(g, .body), .{ .brace = true });
                if (!p.eof() and p.src[p.i] == '}') p.i += 1;
                return p.mark(g, start);
            },
            '(', '[' => {
                p.i += 1;
                const close: u8 = if (c == '(') ')' else ']';
                const f = try p.e.structure(.fence, p.src[start..p.i], &.{close});
                try p.e.set(f, .fence_size, param.of(param.FenceSize.natural));
                try p.e.append(r, f);
                p.tag(f, p.src[start..p.i]);
                try p.row(p.e.slot(f, .body), .{ .close = close });
                if (!p.eof() and p.src[p.i] == close) p.i += 1;
                return p.mark(f, start);
            },
            '\\' => return p.command(r),
            '-' => {
                p.i += 1;
                return p.add(r, .operator, "−", start, "");
            },
            '*' => {
                p.i += 1;
                return p.add(r, .operator, "∗", start, "");
            },
            else => {},
        }
        // One character, by the table.
        const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
        p.i = @min(p.src.len, p.i + n);
        const ch = p.src[start..p.i];
        return p.add(r, symbols.kindOfChar(ch), ch, start, "");
    }

    fn name(p: *Parser) []const u8 {
        // After the backslash: letters, or one other character.
        const s = p.i;
        if (p.eof()) return p.src[s - 1 .. s];
        if (std.ascii.isAlphabetic(p.src[p.i])) {
            while (!p.eof() and std.ascii.isAlphabetic(p.src[p.i])) p.i += 1;
        } else p.i += 1;
        return p.src[s - 1 .. p.i];
    }

    /// A delimiter after \left or \right: a character, or a command (\{,
    /// \langle…); "." is none.
    fn delimiter(p: *Parser) []const u8 {
        p.skip();
        if (p.eof()) return "";
        if (p.src[p.i] == '\\') {
            p.i += 1;
            const cmd = p.name();
            if (std.mem.eql(u8, cmd, "\\{")) return "{";
            if (std.mem.eql(u8, cmd, "\\}")) return "}";
            if (std.mem.eql(u8, cmd, "\\langle")) return "⟨";
            if (std.mem.eql(u8, cmd, "\\rangle")) return "⟩";
            if (std.mem.eql(u8, cmd, "\\|")) return "‖";
            return "";
        }
        const n = std.unicode.utf8ByteSequenceLength(p.src[p.i]) catch 1;
        const s = p.src[p.i..@min(p.src.len, p.i + n)];
        p.i += s.len;
        return if (std.mem.eql(u8, s, ".")) "" else s;
    }

    fn command(p: *Parser, r: Id) ex.Error!void {
        const start = p.i;
        p.i += 1;
        const cmd = p.name();
        const is = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (is(cmd, "\\frac") or is(cmd, "\\dfrac") or is(cmd, "\\tfrac")) {
            const f = try p.e.structure(.fraction, "", "");
            try p.e.append(r, f);
            p.tag(f, cmd);
            try p.arg(p.e.slot(f, .num));
            try p.arg(p.e.slot(f, .den));
            return p.mark(f, start);
        }
        if (is(cmd, "\\sqrt")) {
            const rad = try p.e.structure(.radical, "√", "");
            try p.e.append(r, rad);
            p.tag(rad, cmd);
            p.skip();
            if (!p.eof() and p.src[p.i] == '[') {
                p.i += 1;
                const s0 = p.i;
                const ix = try p.e.openSlot(rad, .index);
                try p.row(ix, .{ .bracket = true });
                try p.spans.set(p.gpa(), ix, .{ .start = @intCast(s0), .end = @intCast(p.i) });
                if (!p.eof() and p.src[p.i] == ']') p.i += 1;
            }
            try p.arg(p.e.slot(rad, .body));
            return p.mark(rad, start);
        }
        if (symbols.accentByLatex(cmd)) |acc| {
            const a = try p.e.structure(.accent, acc.mark, "");
            try p.e.append(r, a);
            p.tag(a, cmd);
            try p.arg(p.e.slot(a, .body));
            return p.mark(a, start);
        }
        if (is(cmd, "\\left")) {
            const open = p.delimiter();
            const f = try p.e.structure(.fence, open, "");
            try p.e.append(r, f);
            p.tag(f, cmd);
            try p.row(p.e.slot(f, .body), .{ .right = true });
            if (p.startsWith("\\right")) {
                p.i += "\\right".len;
                p.e.node(f).close = try p.e.strings.allocator().dupe(u8, p.delimiter());
            }
            return p.mark(f, start);
        }
        if (is(cmd, "\\set") and !p.eof() and p.src[p.i] == '(') {
            // Graven's call form: overrides on what the braces hold.
            const g = try p.e.structure(.group, "", "");
            try p.e.append(r, g);
            p.tag(g, cmd);
            p.i = try entry.parseArgs(p.e, g, p.src, p.i + 1);
            if (!p.eof() and p.src[p.i] == ')') p.i += 1;
            try p.arg(p.e.slot(g, .body));
            return p.mark(try entry.unwrapCall(p.e, g), start);
        }
        if (is(cmd, "\\mathbf") or is(cmd, "\\boldsymbol") or is(cmd, "\\bm")) {
            // Bold letterforms: what it holds, kept as a group.
            const g = try p.e.structure(.group, "", "");
            try p.e.append(r, g);
            p.tag(g, cmd);
            try p.arg(p.e.slot(g, .body));
            entry.setVariant(p.e, p.e.slot(g, .body), .bold);
            return p.mark(g, start);
        }
        if (is(cmd, "\\mathrm") or is(cmd, "\\text") or is(cmd, "\\operatorname") or is(cmd, "\\textrm") or is(cmd, "\\mathrm")) {
            p.skip();
            var text: []const u8 = "";
            if (!p.eof() and p.src[p.i] == '{') {
                const s = p.i + 1;
                var depth: usize = 1;
                p.i += 1;
                while (!p.eof()) : (p.i += 1) {
                    if (p.src[p.i] == '{') depth += 1;
                    if (p.src[p.i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                text = p.src[s..p.i];
                if (!p.eof()) p.i += 1;
            }
            return p.add(r, .word, text, start, "\\mathrm");
        }
        if (is(cmd, "\\limits") or is(cmd, "\\nolimits")) {
            const items = p.e.node(r).items.items;
            if (items.len > 0 and p.e.node(items[items.len - 1]).kind == .large_op)
                try p.e.set(items[items.len - 1], .limits, param.of(if (is(cmd, "\\limits")) param.Limits.stacked else param.Limits.side));
            return;
        }
        for ([_][]const u8{ "\\,", "\\;", "\\:", "\\!", "\\quad", "\\qquad", "\\ " }) |sp| if (is(cmd, sp)) return;
        if (cmd.len == 2 and !std.ascii.isAlphabetic(cmd[1])) {
            // \% \$ \{ \} \_ \& \#: the character itself.
            return p.add(r, symbols.kindOfChar(cmd[1..]), cmd[1..], start, cmd);
        }
        if (symbols.byLatex(cmd)) |s| return p.add(r, s.kind, s.char, start, cmd);
        // An operator name: an upright word, written back as its command.
        if (symbols.isOperatorName(cmd[1..])) return p.add(r, .word, cmd[1..], start, cmd);
        // Not known (or still being typed): kept as upright text.
        return p.add(r, .word, cmd, start, "?");
    }
};

// Writing --------------------------------------------------------------------------

/// Writes the expression back as LaTeX: math, or a legend (text, with math
/// between dollars).
pub fn write(w: *std.Io.Writer, e: *const Expr, mode: Mode) std.Io.Writer.Error!void {
    var wr: Writer = .{ .w = w, .e = e };
    const items = e.node(e.root).items.items;
    if (mode == .math) {
        try wr.items(items);
        return;
    }
    // Text runs as they are; the rest between dollars.
    var k: usize = 0;
    // Emphasis open, closed and opened again where it changes.
    var open: Variant = .normal;
    while (k < items.len) {
        const n = e.node(items[k]);
        const want: Variant = if (entry.isText(e, items[k])) n.variant else .normal;
        if (want != open) {
            try w.writeAll(switch (open) {
                .normal => "",
                .bold, .italic => "}",
                .bold_italic => "}}",
            });
            try w.writeAll(switch (want) {
                .normal => "",
                .bold => "\\textbf{",
                .italic => "\\textit{",
                .bold_italic => "\\textbf{\\textit{",
            });
            open = want;
        }
        if (entry.isText(e, items[k])) {
            if (e.override(items[k], .break_before)) |v| if (param.as(param.BreakMark, v) == .allow) try w.writeAll("\\allowbreak ");
            if (n.kind == .soft_hyphen) {
                try w.writeAll("\\-");
            } else for (n.text) |ch| {
                if (ch == '%' or ch == '$' or ch == '#' or ch == '&' or ch == '_') try w.writeByte('\\');
                try w.writeByte(ch);
            }
            k += 1;
            continue;
        }
        var end = k;
        while (end < items.len and !entry.isText(e, items[end])) end += 1;
        try w.writeByte('$');
        wr.word_end = false;
        try wr.items(items[k..end]);
        try w.writeByte('$');
        k = end;
    }
    try w.writeAll(switch (open) {
        .normal => "",
        .bold, .italic => "}",
        .bold_italic => "}}",
    });
}

const Writer = struct {
    w: *std.Io.Writer,
    e: *const Expr,
    /// The last thing written ends a command's name: a letter next needs a space.
    word_end: bool = false,

    fn raw(wr: *Writer, s: []const u8) !void {
        if (s.len == 0) return;
        if (wr.word_end and std.ascii.isAlphabetic(s[0])) try wr.w.writeByte(' ');
        try wr.w.writeAll(s);
        wr.word_end = s[0] == '\\' and std.ascii.isAlphabetic(s[s.len - 1]);
    }

    fn items(wr: *Writer, ids: []const Id) std.Io.Writer.Error!void {
        for (ids) |id| try wr.obj(id);
    }

    /// A row as an argument: braced unless it is one character.
    fn arg(wr: *Writer, row: Id) !void {
        const ids = if (row == .none) &[_]Id{} else wr.e.node(row).items.items;
        if (ids.len == 1 and !wr.e.node(ids[0]).kind.isStructure() and wr.e.node(ids[0]).kind != .word) {
            const t = wr.e.node(ids[0]).text;
            const s = symbols.byChar(t);
            const one_char = (std.unicode.utf8CountCodepoints(t) catch 2) == 1 and (s == null or s.?.latex.len == 0);
            if (one_char and wr.e.node(ids[0]).kind != .operator) {
                try wr.obj(ids[0]);
                return;
            }
        }
        try wr.w.writeByte('{');
        wr.word_end = false;
        try wr.items(ids);
        try wr.w.writeByte('}');
        wr.word_end = false;
    }

    fn braced(wr: *Writer, row: Id) !void {
        try wr.w.writeByte('{');
        wr.word_end = false;
        try wr.items(if (row == .none) &.{} else wr.e.node(row).items.items);
        try wr.w.writeByte('}');
        wr.word_end = false;
    }

    fn leafText(t: []const u8) []const u8 {
        if (std.mem.eql(u8, t, "−")) return "-";
        if (std.mem.eql(u8, t, "∗")) return "*";
        if (symbols.byChar(t)) |s| if (s.latex.len > 0) return s.latex;
        return t;
    }

    fn obj(wr: *Writer, id: Id) std.Io.Writer.Error!void {
        const e = wr.e;
        if (!entry.hasCall(e, id)) return wr.uncalled(id);
        // Its overrides in Graven's call form around it; a group made by
        // the call writes only what it holds.
        try wr.raw("\\set");
        try entry.writeArgs(wr.w, e, id);
        try wr.w.writeByte('{');
        wr.word_end = false;
        const n = e.node(id);
        if (n.kind == .group and std.mem.eql(u8, n.tags.source, "\\set")) try wr.items(e.node(e.slot(id, .body)).items.items) else try wr.uncalled(id);
        try wr.w.writeByte('}');
        wr.word_end = false;
    }

    fn uncalled(wr: *Writer, id: Id) std.Io.Writer.Error!void {
        const e = wr.e;
        const n = e.node(id);
        switch (n.kind) {
            .row => try wr.items(n.items.items),
            .space => try wr.raw(n.text),
            .soft_hyphen => try wr.raw("\\-"),
            .word => {
                if (std.mem.eql(u8, n.tags.source, "?")) return wr.raw(n.text);
                if (n.tags.source.len > 1 and n.tags.source[0] == '\\' and symbols.isOperatorName(n.tags.source[1..])) return wr.raw(n.tags.source);
                try wr.raw("\\mathrm");
                try wr.w.writeByte('{');
                try wr.w.writeAll(n.text);
                try wr.w.writeByte('}');
                wr.word_end = false;
            },
            .number, .variable, .constant, .symbol, .operator, .relation, .punct, .ellipsis => {
                if (n.tags.source.len == 2 and n.tags.source[0] == '\\') return wr.raw(n.tags.source);
                try wr.raw(leafText(n.text));
            },
            .fraction => {
                try wr.raw("\\frac");
                try wr.braced(e.slot(id, .num));
                try wr.braced(e.slot(id, .den));
            },
            .scripts => {
                const base = e.node(e.slot(id, .base)).items.items;
                if (base.len == 1) try wr.obj(base[0]) else try wr.arg(e.slot(id, .base));
                try wr.scripts(id);
            },
            .large_op => {
                try wr.raw(leafText(n.text));
                if (e.override(id, .limits)) |v| try wr.raw(if (param.as(param.Limits, v) == .side) "\\nolimits" else "\\limits");
                try wr.scripts(id);
            },
            .radical => {
                try wr.raw("\\sqrt");
                const idx = e.slot(id, .index);
                if (idx != .none and e.node(idx).items.items.len > 0) {
                    try wr.w.writeByte('[');
                    wr.word_end = false;
                    try wr.items(e.node(idx).items.items);
                    try wr.w.writeByte(']');
                }
                try wr.braced(e.slot(id, .body));
            },
            .fence => {
                const plain = if (e.override(id, .fence_size)) |v| param.as(param.FenceSize, v) == .natural else false;
                if (plain) {
                    try wr.raw(n.text);
                    try wr.items(e.node(e.slot(id, .body)).items.items);
                    try wr.raw(n.close);
                } else {
                    try wr.raw("\\left");
                    try wr.raw(delim(n.text));
                    try wr.items(e.node(e.slot(id, .body)).items.items);
                    try wr.raw("\\right");
                    try wr.raw(delim(n.close));
                }
            },
            .accent => {
                const acc = symbols.accentByMark(n.text);
                try wr.raw(if (acc) |a| a.latex else "\\hat");
                try wr.braced(e.slot(id, .body));
            },
            .group => if (n.tags.source.len > 1 and n.tags.source[0] == '\\') {
                try wr.raw(n.tags.source);
                try wr.braced(e.slot(id, .body));
            } else {
                try wr.w.writeByte('{');
                wr.word_end = false;
                try wr.items(e.node(e.slot(id, .body)).items.items);
                try wr.w.writeByte('}');
                wr.word_end = false;
            },
        }
    }

    fn delim(d: []const u8) []const u8 {
        if (d.len == 0) return ".";
        if (std.mem.eql(u8, d, "{")) return "\\{";
        if (std.mem.eql(u8, d, "}")) return "\\}";
        if (std.mem.eql(u8, d, "⟨")) return "\\langle";
        if (std.mem.eql(u8, d, "⟩")) return "\\rangle";
        return d;
    }

    fn scripts(wr: *Writer, id: Id) !void {
        const e = wr.e;
        const sub = e.slot(id, .sub);
        const sup = e.slot(id, .sup);
        if (sub != .none and e.node(sub).items.items.len > 0) {
            try wr.w.writeByte('_');
            wr.word_end = false;
            try wr.arg(sub);
        }
        if (sup != .none and e.node(sup).items.items.len > 0) {
            try wr.w.writeByte('^');
            wr.word_end = false;
            try wr.arg(sup);
        }
    }
};
