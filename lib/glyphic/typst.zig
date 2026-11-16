//! Typst-style math, to objects and back.
//!
//! As Typst's math: single letters are variables; longer names are
//! symbols (`pi`, `oo`, `sum`, `arrow.r`, `dots.c`) or functions
//! (`frac(a, b)`, `sqrt(x)`, `root(n, x)`, `hat(x)`, `abs(x)`,
//! `attach(x, t: a, b: b)`, `upright("…")`); quoted text is upright;
//! shorthands (`->`, `<=`, `!=`, `...`) stand for their symbols. `/` makes
//! a fraction of the unit before and the unit after; `^` and `_` attach
//! scripts. Parentheses around a fraction's part or a script's argument
//! group without showing; elsewhere they show (a fence). `slash` is an
//! inline slash. Graven is lenient where Typst is strict: an unknown name
//! is upright text (so "LN" needs no quotes).
//!
//! A legend: text, with math between dollars, as in Typst's markup.
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
const Span = entry.Span;
const Spans = entry.Spans;

pub const Mode = enum { math, legend };

pub fn parse(e: *Expr, spans: *Spans, src: []const u8, mode: Mode) ex.Error!void {
    var p: Parser = .{ .e = e, .spans = spans, .src = src };
    switch (mode) {
        .math => try p.row(e.root, .{}),
        .legend => try p.legend(),
    }
}

const Stop = struct {
    dollar: bool = false,
    /// A group's closing character.
    close: ?u8 = null,
    /// A function argument: a comma ends it too.
    comma: bool = false,
};

const shorthands = [_][]const u8{ "<=>", "<->", "|->", "...", "->", "<-", "=>", "<=", ">=", "!=", "*", "'" };

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

    fn peek(p: *Parser) u8 {
        return if (p.eof()) 0 else p.src[p.i];
    }

    fn mark(p: *Parser, id: Id, start: usize) ex.Error!void {
        try p.spans.set(p.gpa(), id, .{ .start = @intCast(start), .end = @intCast(p.i) });
    }

    fn tag(p: *Parser, id: Id, source: []const u8) void {
        p.e.node(id).tags = .{ .source = source, .syntax = .typst };
    }

    fn legend(p: *Parser) ex.Error!void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(p.gpa());
        var start = p.i;
        while (!p.eof()) {
            const c = p.src[p.i];
            if (c == '$') {
                try p.flushText(&text, start);
                p.i += 1;
                try p.row(p.e.root, .{ .dollar = true });
                if (p.peek() == '$') p.i += 1;
                start = p.i;
                continue;
            }
            if (c == '\\' and p.i + 1 < p.src.len) {
                try text.append(p.gpa(), p.src[p.i + 1]);
                p.i += 2;
                continue;
            }
            try text.append(p.gpa(), c);
            p.i += 1;
        }
        try p.flushText(&text, start);
    }

    fn flushText(p: *Parser, text: *std.ArrayList(u8), start: usize) ex.Error!void {
        if (text.items.len == 0) return;
        const w = try p.e.leaf(.word, text.items);
        try p.e.append(p.e.root, w);
        try p.mark(w, start);
        text.clearRetainingCapacity();
    }

    fn stops(p: *Parser, s: Stop) bool {
        if (p.eof()) return true;
        const c = p.src[p.i];
        if (s.dollar and c == '$') return true;
        if (s.close) |cl| if (c == cl) return true;
        if (s.comma and c == ',') return true;
        return false;
    }

    fn row(p: *Parser, r: Id, s: Stop) ex.Error!void {
        while (true) {
            p.skip();
            if (p.stops(s)) break;
            if (p.peek() == '/') {
                try p.fraction(r);
                continue;
            }
            const before = p.e.node(r).items.items.len;
            try p.unit(r);
            // Nothing made (a stray closer): take it as itself.
            if (p.e.node(r).items.items.len == before and !p.eof() and p.i < p.src.len) {
                const c = p.src[p.i];
                if (c == ')' or c == ']' or c == '}' or c == ',') {
                    const start = p.i;
                    p.i += 1;
                    try p.add(r, symbols.kindOfChar(p.src[start..p.i]), p.src[start..p.i], start, "");
                }
            }
        }
        entry.fixRoles(p.e, r);
    }

    /// `/`: a fraction of the last unit made and the next one.
    fn fraction(p: *Parser, r: Id) ex.Error!void {
        const start = p.i;
        p.i += 1;
        const f = try p.e.structure(.fraction, "", "");
        p.tag(f, "/");
        const items = p.e.node(r).items.items;
        var fstart = start;
        if (items.len > 0) {
            const left = items[items.len - 1];
            fstart = @min(fstart, p.spans.get(left).start);
            p.e.detach(left);
            try p.operand(p.e.slot(f, .num), left);
        }
        try p.e.append(r, f);
        p.skip();
        const tmp = try p.e.structure(.group, "", "");
        try p.unit(p.e.slot(tmp, .body));
        const got = p.e.node(p.e.slot(tmp, .body)).items.items;
        if (got.len > 0) {
            const right = got[0];
            p.e.detach(right);
            try p.operand(p.e.slot(f, .den), right);
        }
        p.e.remove(tmp);
        try p.mark(f, fstart);
    }

    /// Puts `x` into `dest`, a fraction's part or a script's argument:
    /// a parenthesised group's contents without its parentheses.
    fn operand(p: *Parser, dest: Id, x: Id) ex.Error!void {
        const n = p.e.node(x);
        if (n.kind == .fence and std.mem.eql(u8, n.text, "(") and std.mem.eql(u8, n.close, ")") and std.mem.eql(u8, n.tags.source, "(")) {
            const body = p.e.slot(x, .body);
            const inner = try p.gpa().dupe(Id, p.e.node(body).items.items);
            defer p.gpa().free(inner);
            for (inner) |c| {
                p.e.detach(c);
                try p.e.append(dest, c);
            }
            p.e.remove(x);
            entry.fixRoles(p.e, dest);
            return;
        }
        try p.e.append(dest, x);
    }

    /// One unit: an atom, then its scripts.
    fn unit(p: *Parser, r: Id) ex.Error!void {
        const before = p.e.node(r).items.items.len;
        try p.atom(r);
        if (p.e.node(r).items.items.len == before) return;
        while (true) {
            const save = p.i;
            p.skip();
            const c = p.peek();
            if (c != '^' and c != '_') {
                p.i = save;
                return;
            }
            const start = p.i;
            p.i += 1;
            const t = try entry.scriptTarget(p.e, r, if (c == '^') .sup else .sub);
            if (p.spans.get(t.structure).start == Span.none.start) try p.mark(t.structure, start);
            p.skip();
            const tmp = try p.e.structure(.group, "", "");
            try p.atom(p.e.slot(tmp, .body));
            const got = p.e.node(p.e.slot(tmp, .body)).items.items;
            if (got.len > 0) {
                const x = got[0];
                p.e.detach(x);
                try p.operand(t.row, x);
            }
            p.e.remove(tmp);
            try p.spans.extend(p.gpa(), t.structure, p.i);
        }
    }

    fn add(p: *Parser, r: Id, kind: Kind, text: []const u8, start: usize, source: []const u8) ex.Error!void {
        const id = if (kind == .large_op) try p.e.structure(.large_op, text, "") else if (kind == .operator) try p.e.operator(text, .binary) else try p.e.leaf(kind, text);
        try p.e.append(r, id);
        p.tag(id, source);
        try p.mark(id, start);
    }

    fn atom(p: *Parser, r: Id) ex.Error!void {
        p.skip();
        if (p.eof()) return;
        const start = p.i;
        const c = p.src[p.i];
        // Shorthands first, longest first.
        for (shorthands) |sh| if (std.mem.startsWith(u8, p.src[p.i..], sh)) {
            for (symbols.table) |s| if (std.mem.eql(u8, s.shorthand, sh)) {
                p.i += sh.len;
                if (std.mem.eql(u8, sh, "'")) {
                    // A prime: a superscript ′ on what came before.
                    const t = try entry.scriptTarget(p.e, r, .sup);
                    const pr = try p.e.leaf(.symbol, "′");
                    try p.e.append(t.row, pr);
                    return p.mark(pr, start);
                }
                return p.add(r, s.kind, s.char, start, sh);
            };
        };
        if (std.ascii.isDigit(c)) {
            while (!p.eof() and (std.ascii.isDigit(p.src[p.i]) or (p.src[p.i] == '.' and p.i + 1 < p.src.len and std.ascii.isDigit(p.src[p.i + 1])))) p.i += 1;
            return p.add(r, .number, p.src[start..p.i], start, "");
        }
        if (std.ascii.isAlphabetic(c)) return p.name(r);
        switch (c) {
            '"' => {
                p.i += 1;
                const s = p.i;
                while (!p.eof() and p.src[p.i] != '"') p.i += 1;
                const text = p.src[s..p.i];
                if (!p.eof()) p.i += 1;
                return p.add(r, .word, text, start, "\"");
            },
            '(', '[', '{' => {
                p.i += 1;
                const close: u8 = switch (c) {
                    '(' => ')',
                    '[' => ']',
                    else => '}',
                };
                const f = try p.e.structure(.fence, p.src[start..p.i], &.{close});
                try p.e.append(r, f);
                p.tag(f, p.src[start..p.i]);
                try p.row(p.e.slot(f, .body), .{ .close = close });
                if (p.peek() == close) p.i += 1;
                return p.mark(f, start);
            },
            ')', ']', '}', ',', '$', '^', '_', '/' => return,
            '\\' => {
                p.i += 1;
                if (p.eof()) return;
                const n = std.unicode.utf8ByteSequenceLength(p.src[p.i]) catch 1;
                const s = p.i;
                p.i = @min(p.src.len, p.i + n);
                return p.add(r, symbols.kindOfChar(p.src[s..p.i]), p.src[s..p.i], start, "\\");
            },
            '-' => {
                p.i += 1;
                return p.add(r, .operator, "−", start, "");
            },
            else => {},
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
        p.i = @min(p.src.len, p.i + n);
        const ch = p.src[start..p.i];
        return p.add(r, symbols.kindOfChar(ch), ch, start, "");
    }

    /// A name: a single letter is a variable; a longer one a symbol, a
    /// function (when "(" follows), or upright text.
    fn name(p: *Parser, r: Id) ex.Error!void {
        const start = p.i;
        while (!p.eof() and (std.ascii.isAlphanumeric(p.src[p.i]) or (p.src[p.i] == '.' and p.i + 1 < p.src.len and std.ascii.isAlphabetic(p.src[p.i + 1])))) p.i += 1;
        const n = p.src[start..p.i];
        if (n.len == 1) return p.add(r, .variable, n, start, "");
        if (p.peek() == '(') if (try p.call(r, n, start)) return;
        if (symbols.byTypst(n)) |s| return p.add(r, s.kind, s.char, start, n);
        return p.add(r, .word, n, start, "?");
    }

    /// The arguments of a call, each into a row of `group`s made here: up
    /// to `max` positional ones, and named ones (`t:`, `b:`) by name.
    const Args = struct { pos: [3]Id = @splat(.none), n: usize = 0, t: Id = .none, b: Id = .none };

    fn args(p: *Parser) ex.Error!Args {
        var out: Args = .{};
        p.i += 1; // (
        while (true) {
            p.skip();
            if (p.eof() or p.peek() == ')') break;
            // A named argument?
            var dest_slot: ?*Id = null;
            const save = p.i;
            if (std.ascii.isAlphabetic(p.peek())) {
                const s = p.i;
                while (!p.eof() and std.ascii.isAlphabetic(p.src[p.i])) p.i += 1;
                const nm = p.src[s..p.i];
                p.skip();
                if (p.peek() == ':') {
                    p.i += 1;
                    if (std.mem.eql(u8, nm, "t")) dest_slot = &out.t;
                    if (std.mem.eql(u8, nm, "b")) dest_slot = &out.b;
                } else p.i = save;
            }
            const g = try p.e.structure(.group, "", "");
            try p.row(p.e.slot(g, .body), .{ .close = ')', .comma = true });
            if (dest_slot) |d| d.* = g else if (out.n < out.pos.len) {
                out.pos[out.n] = g;
                out.n += 1;
            } else p.e.remove(g);
            if (p.peek() == ',') p.i += 1;
        }
        if (p.peek() == ')') p.i += 1;
        return out;
    }

    /// Moves a call argument's contents into `dest` and ends the argument.
    fn take(p: *Parser, arg: Id, dest: Id) ex.Error!void {
        if (arg == .none) return;
        const body = p.e.slot(arg, .body);
        const inner = try p.gpa().dupe(Id, p.e.node(body).items.items);
        defer p.gpa().free(inner);
        for (inner) |c| {
            p.e.detach(c);
            try p.e.append(dest, c);
        }
        p.e.remove(arg);
        entry.fixRoles(p.e, dest);
    }

    fn call(p: *Parser, r: Id, f: []const u8, start: usize) ex.Error!bool {
        const is = struct {
            fn g(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.g;
        if (is(f, "frac")) {
            const a = try p.args();
            const fr = try p.e.structure(.fraction, "", "");
            p.tag(fr, f);
            try p.take(a.pos[0], p.e.slot(fr, .num));
            try p.take(a.pos[1], p.e.slot(fr, .den));
            try p.e.append(r, fr);
            try p.mark(fr, start);
            return true;
        }
        if (is(f, "sqrt") or is(f, "root")) {
            const a = try p.args();
            const rad = try p.e.structure(.radical, "√", "");
            p.tag(rad, f);
            if (is(f, "root") and a.n >= 2) {
                try p.take(a.pos[0], try p.e.openSlot(rad, .index));
                try p.take(a.pos[1], p.e.slot(rad, .body));
            } else {
                try p.take(a.pos[0], p.e.slot(rad, .body));
                if (a.n > 1) p.e.remove(a.pos[1]);
            }
            try p.e.append(r, rad);
            try p.mark(rad, start);
            return true;
        }
        if (symbols.accentByTypst(f)) |acc| {
            const a = try p.args();
            const ac = try p.e.structure(.accent, acc.mark, "");
            p.tag(ac, f);
            try p.take(a.pos[0], p.e.slot(ac, .body));
            try p.e.append(r, ac);
            try p.mark(ac, start);
            return true;
        }
        if (is(f, "abs") or is(f, "norm") or is(f, "floor") or is(f, "ceil")) {
            const a = try p.args();
            const d: [2][]const u8 = if (is(f, "abs")) .{ "|", "|" } else if (is(f, "norm")) .{ "‖", "‖" } else if (is(f, "floor")) .{ "⌊", "⌋" } else .{ "⌈", "⌉" };
            const fe = try p.e.structure(.fence, d[0], d[1]);
            p.tag(fe, f);
            try p.take(a.pos[0], p.e.slot(fe, .body));
            try p.e.append(r, fe);
            try p.mark(fe, start);
            return true;
        }
        if (is(f, "attach")) {
            const a = try p.args();
            const s = try p.e.structure(.scripts, "", "");
            p.tag(s, f);
            try p.take(a.pos[0], p.e.slot(s, .base));
            if (a.b != .none) try p.take(a.b, try p.e.openSlot(s, .sub));
            if (a.t != .none) try p.take(a.t, try p.e.openSlot(s, .sup));
            try p.e.append(r, s);
            try p.mark(s, start);
            return true;
        }
        if (is(f, "upright") or is(f, "op")) {
            // A word: its quoted text, or what the argument spells.
            p.i += 1;
            p.skip();
            var text: []const u8 = "";
            if (p.peek() == '"') {
                p.i += 1;
                const s = p.i;
                while (!p.eof() and p.src[p.i] != '"') p.i += 1;
                text = p.src[s..p.i];
                if (!p.eof()) p.i += 1;
            }
            while (!p.eof() and p.src[p.i] != ')') p.i += 1;
            if (!p.eof()) p.i += 1;
            try p.add(r, .word, text, start, "\"");
            return true;
        }
        return false;
    }
};

// Writing --------------------------------------------------------------------------

pub fn write(w: *std.Io.Writer, e: *const Expr, mode: Mode) std.Io.Writer.Error!void {
    var wr: Writer = .{ .w = w, .e = e };
    const items = e.node(e.root).items.items;
    if (mode == .math) return wr.items(items);
    var k: usize = 0;
    while (k < items.len) {
        const n = e.node(items[k]);
        if (n.kind == .word and n.tags.source.len == 0) {
            for (n.text) |ch| {
                if (ch == '$' or ch == '#' or ch == '\\' or ch == '*' or ch == '_') try w.writeByte('\\');
                try w.writeByte(ch);
            }
            k += 1;
            continue;
        }
        var end = k;
        while (end < items.len and !(e.node(items[end]).kind == .word and e.node(items[end]).tags.source.len == 0)) end += 1;
        try w.writeByte('$');
        try wr.items(items[k..end]);
        try w.writeByte('$');
        k = end;
    }
}

const Writer = struct {
    w: *std.Io.Writer,
    e: *const Expr,

    fn items(wr: *Writer, ids: []const Id) std.Io.Writer.Error!void {
        for (ids, 0..) |id, k| {
            // A space between neighbours, but none after a sign.
            if (k > 0 and wr.e.node(ids[k - 1]).role != .unary) try wr.w.writeByte(' ');
            try wr.obj(id);
        }
    }

    fn rowItems(wr: *Writer, row: Id) []const Id {
        return if (row == .none) &.{} else wr.e.node(row).items.items;
    }

    /// A fraction's part or a script's argument: bare when it is one unit
    /// that cannot be misread, else in parentheses (which do not show).
    fn operand(wr: *Writer, row: Id, script: bool) !void {
        const ids = wr.rowItems(row);
        if (ids.len == 1) {
            const n = wr.e.node(ids[0]);
            const bare = switch (n.kind) {
                .fraction, .group => false,
                .operator => false,
                // A fence written bare would lose its parentheses as an operand.
                .fence => false,
                .scripts, .large_op => !script,
                else => true,
            };
            if (bare) return wr.obj(ids[0]);
        }
        try wr.w.writeByte('(');
        try wr.items(ids);
        try wr.w.writeByte(')');
    }

    fn leaf(wr: *Writer, n: *const ex.Node) !void {
        const t = n.text;
        if (std.mem.eql(u8, t, "−")) return wr.w.writeByte('-');
        if (std.mem.eql(u8, t, "/")) return wr.w.writeAll("slash");
        if (t.len == 1 and t[0] < 0x80 and t[0] != '\'') return wr.w.writeAll(t);
        if (symbols.byChar(t)) |s| {
            if (s.shorthand.len > 0) return wr.w.writeAll(s.shorthand);
            if (s.typst.len > 0) return wr.w.writeAll(s.typst);
        }
        try wr.w.writeAll(t);
    }

    fn obj(wr: *Writer, id: Id) std.Io.Writer.Error!void {
        const e = wr.e;
        const n = e.node(id);
        switch (n.kind) {
            .row => try wr.items(n.items.items),
            .word => {
                if (std.mem.eql(u8, n.tags.source, "?")) return wr.w.writeAll(n.text);
                try wr.w.print("\"{s}\"", .{n.text});
            },
            .number, .variable, .constant, .symbol, .operator, .relation, .punct, .ellipsis => try wr.leaf(n),
            .fraction => {
                try wr.operand(e.slot(id, .num), false);
                try wr.w.writeByte('/');
                try wr.operand(e.slot(id, .den), false);
            },
            .scripts => {
                const base = wr.rowItems(e.slot(id, .base));
                if (base.len == 1) try wr.obj(base[0]) else {
                    try wr.w.writeAll("attach(");
                    try wr.items(base);
                    try wr.w.writeAll(")");
                }
                try wr.scripts(id);
            },
            .large_op => {
                try wr.leaf(n);
                try wr.scripts(id);
            },
            .radical => {
                const idx = e.slot(id, .index);
                if (idx != .none and e.node(idx).items.items.len > 0) {
                    try wr.w.writeAll("root(");
                    try wr.items(e.node(idx).items.items);
                    try wr.w.writeAll(", ");
                } else try wr.w.writeAll("sqrt(");
                try wr.items(wr.rowItems(e.slot(id, .body)));
                try wr.w.writeByte(')');
            },
            .fence => {
                const fname: ?[]const u8 = if (std.mem.eql(u8, n.text, "|")) "abs" else if (std.mem.eql(u8, n.text, "‖")) "norm" else if (std.mem.eql(u8, n.text, "⌊")) "floor" else if (std.mem.eql(u8, n.text, "⌈")) "ceil" else null;
                if (fname) |f| {
                    try wr.w.print("{s}(", .{f});
                    try wr.items(wr.rowItems(e.slot(id, .body)));
                    return wr.w.writeByte(')');
                }
                try wr.w.writeAll(n.text);
                try wr.items(wr.rowItems(e.slot(id, .body)));
                try wr.w.writeAll(n.close);
            },
            .accent => {
                const acc = symbols.accentByMark(n.text);
                try wr.w.print("{s}(", .{if (acc) |a| a.typst else "hat"});
                try wr.items(wr.rowItems(e.slot(id, .body)));
                try wr.w.writeByte(')');
            },
            .group => try wr.items(wr.rowItems(e.slot(id, .body))),
        }
    }

    fn scripts(wr: *Writer, id: Id) !void {
        const e = wr.e;
        const sub = e.slot(id, .sub);
        const sup = e.slot(id, .sup);
        if (sub != .none and e.node(sub).items.items.len > 0) {
            try wr.w.writeByte('_');
            try wr.operand(sub, true);
        }
        if (sup != .none and e.node(sup).items.items.len > 0) {
            try wr.w.writeByte('^');
            try wr.operand(sup, true);
        }
    }
};
