//! Label markup: a KaTeX-style subset parsed into a neutral tree.
//!
//! The parser records what the source says and nothing more. Which letters
//! are italic, which minus sign a hyphen becomes, and how far apart things
//! sit are style and layout decisions, made later by the engine.
//!
//! Differences from KaTeX, by design:
//! - Spaces are significant: "CAPS LOCK" keeps its space. A space is a
//!   break opportunity; ~ is a non-breaking space.
//! - \\ is a hard break and \allowbreak a soft one, not a backslash
//!   (write \textbackslash).
//! - A script attaches to the grapheme cluster before it ("CLEAR^2" puts
//!   the 2 on the R), or to the group, command or accent before it.
//! - Constructs not yet adopted (\sqrt, \frac, ...) are errors, as are
//!   unknown commands: nothing passes through unparsed.
//!
//! Every node records the byte range of source it came from, and every
//! byte of resolved text records the source byte it came from, so a
//! problem found later (a missing glyph) can be reported in the source.

const std = @import("std");
const entities = @import("entities.zig");

const Allocator = std.mem.Allocator;

/// How letters were asked to look. `default` leaves it to the style.
pub const Variant = enum { default, upright, italic, text };

pub const Span = struct { start: u32, end: u32 };

pub const Node = union(enum) {
    text: Text,
    group: Group,
    scripts: Scripts,
    accent: Accent,
    space: Space,
    line_break: Break,

    pub fn span(n: Node) Span {
        return switch (n) {
            inline else => |v| v.span,
        };
    }
};

pub const Text = struct {
    /// Resolved characters, UTF-8.
    utf8: []const u8,
    /// For each byte of `utf8`, the source byte it came from.
    source: []const u32,
    variant: Variant,
    /// An operator name such as \ln: upright, and spaced as an operator.
    operator: bool = false,
    span: Span,
};

pub const Group = struct {
    items: []const Node,
    span: Span,
};

pub const Scripts = struct {
    base: *const Node,
    sup: ?*const Node,
    sub: ?*const Node,
    span: Span,
};

pub const Accent = struct {
    kind: enum { bar, overline, hat },
    body: *const Node,
    span: Span,
};

/// An explicit math space; its width is the style's business.
pub const Space = struct {
    kind: enum { thin, medium, thick, negative_thin, quad, qquad },
    span: Span,
};

pub const Break = struct {
    kind: enum { hard, soft },
    span: Span,
};

pub const ErrorKind = enum {
    invalid_utf8,
    control_character,
    unmatched_close,
    missing_close,
    unknown_command,
    not_adopted,
    backslash_at_end,
    expected_brace,
    invalid_codepoint,
    script_without_base,
    script_in_text,
    double_superscript,
    double_subscript,
    missing_argument,

    pub fn message(k: ErrorKind) []const u8 {
        return switch (k) {
            .invalid_utf8 => "the text is not valid UTF-8",
            .control_character => "a control character; use \\\\ for a line break",
            .unmatched_close => "a '}' with no '{' before it",
            .missing_close => "a '{' that is never closed",
            .unknown_command => "an unknown command",
            .not_adopted => "a construct not yet adopted for legends",
            .backslash_at_end => "a backslash at the end",
            .expected_brace => "expected '{'",
            .invalid_codepoint => "not a Unicode scalar value",
            .script_without_base => "a script needs something before it",
            .script_in_text => "scripts are not allowed inside \\text",
            .double_superscript => "two superscripts on one base; use braces",
            .double_subscript => "two subscripts on one base; use braces",
            .missing_argument => "a missing argument",
        };
    }
};

/// Where and what went wrong, as data: the caller decides how to show it.
pub const Diagnostic = struct {
    kind: ErrorKind,
    /// Byte offset in the source.
    offset: u32,
};

pub const Error = error{ Syntax, OutOfMemory };

/// Parses `src` into a tree allocated from `arena`, with the built-in
/// entity table. On error.Syntax, `diag` says what and where.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!Group {
    return parseWith(arena, src, &entities.Table.builtin, diag);
}

/// As `parse`, with a configured entity table.
pub fn parseWith(arena: Allocator, src: []const u8, names: *const entities.Table, diag: *Diagnostic) Error!Group {
    if (src.len > std.math.maxInt(u32)) return error.OutOfMemory;
    if (!std.unicode.utf8ValidateSlice(src)) {
        diag.* = .{ .kind = .invalid_utf8, .offset = 0 };
        return error.Syntax;
    }
    var p: Parser = .{ .a = arena, .src = src, .names = names, .diag = diag };
    const items = try p.list(.default, false, false);
    return .{ .items = items, .span = .{ .start = 0, .end = @intCast(src.len) } };
}

const operators = std.StaticStringMap(void).initComptime(.{
    .{"ln"},     .{"log"},    .{"lg"},     .{"exp"},  .{"sin"},  .{"cos"},  .{"tan"},
    .{"sec"},    .{"csc"},    .{"cot"},    .{"sinh"}, .{"cosh"}, .{"tanh"}, .{"coth"},
    .{"arcsin"}, .{"arccos"}, .{"arctan"}, .{"min"},  .{"max"},  .{"det"},  .{"deg"},
    .{"lim"},    .{"mod"},    .{"gcd"},    .{"Re"},   .{"Im"},   .{"arg"},
});

/// Commands reserved for constructs to be adopted one at a time.
const not_adopted = std.StaticStringMap(void).initComptime(.{
    .{"sqrt"}, .{"frac"}, .{"dfrac"}, .{"tfrac"}, .{"sfrac"}, .{"overlay"},
    .{"rlap"}, .{"llap"}, .{"vec"},   .{"dot"},   .{"ddot"},  .{"tilde"},
});

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: u32 = 0,
    names: *const entities.Table,
    diag: *Diagnostic,

    fn fail(p: *Parser, kind: ErrorKind, at: u32) Error {
        p.diag.* = .{ .kind = kind, .offset = at };
        return error.Syntax;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    /// Items up to the end of input, or up to a '}' when `closing`.
    fn list(p: *Parser, variant: Variant, closing: bool, text_mode: bool) Error![]const Node {
        const open_at = if (p.i > 0) p.i - 1 else 0;
        var items: std.ArrayList(Node) = .empty;
        var run: Run = .{};
        while (true) {
            const c = p.peek() orelse {
                if (closing) return p.fail(.missing_close, open_at);
                break;
            };
            switch (c) {
                '}' => {
                    if (!closing) return p.fail(.unmatched_close, p.i);
                    p.i += 1;
                    break;
                },
                '{' => {
                    try run.flush(p.a, &items, variant);
                    try items.append(p.a, .{ .group = try p.group(variant, text_mode) });
                },
                '^', '_' => {
                    if (text_mode) return p.fail(.script_in_text, p.i);
                    try run.flush(p.a, &items, variant);
                    try p.attach(&items, variant);
                },
                '%' => while (p.peek()) |d| : (p.i += 1) {
                    if (d == '\n') break;
                },
                '~' => {
                    try run.add(p.a, 0x00A0, p.i);
                    p.i += 1;
                },
                '\\' => try p.command(&items, &run, variant, text_mode),
                else => {
                    const at = p.i;
                    const cp = p.char() orelse return p.fail(.invalid_utf8, at);
                    if (cp < 0x20 or cp == 0x7F) return p.fail(.control_character, at);
                    try run.add(p.a, cp, at);
                },
            }
        }
        try run.flush(p.a, &items, variant);
        return items.toOwnedSlice(p.a);
    }

    /// Decodes one codepoint and advances past it.
    fn char(p: *Parser) ?u21 {
        const n = std.unicode.utf8ByteSequenceLength(p.src[p.i]) catch return null;
        if (p.i + n > p.src.len) return null;
        const cp = std.unicode.utf8Decode(p.src[p.i..][0..n]) catch return null;
        p.i += n;
        return cp;
    }

    fn group(p: *Parser, variant: Variant, text_mode: bool) Error!Group {
        const start = p.i;
        p.i += 1; // '{'
        const items = try p.list(variant, true, text_mode);
        return .{ .items = items, .span = .{ .start = start, .end = p.i } };
    }

    fn braced(p: *Parser, variant: Variant, text_mode: bool) Error!Group {
        if (p.peek() != '{') return p.fail(.expected_brace, p.i);
        return p.group(variant, text_mode);
    }

    fn command(p: *Parser, items: *std.ArrayList(Node), run: *Run, variant: Variant, text_mode: bool) Error!void {
        const at = p.i;
        p.i += 1; // the backslash
        const first = p.peek() orelse return p.fail(.backslash_at_end, at);
        var name: []const u8 = undefined;
        if (std.ascii.isAlphabetic(first)) {
            const s = p.i;
            while (p.peek()) |d| : (p.i += 1) {
                if (!std.ascii.isAlphabetic(d)) break;
            }
            name = p.src[s..p.i];
            // As in TeX, spaces after a command word only end its name.
            while (p.peek() == ' ') p.i += 1;
        } else {
            name = p.src[p.i .. p.i + 1];
            p.i += 1;
        }
        const span: Span = .{ .start = at, .end = @intCast(@min(p.i, at + 1 + name.len)) };

        if (p.names.get(name)) |ent| return run.add(p.a, ent.cp, at);
        if (name.len == 1) {
            if (entities.escaped(name[0])) |cp| return run.add(p.a, cp, at);
            if (name[0] == ' ') return run.add(p.a, ' ', at);
        }

        if (std.mem.eql(u8, name, "u")) return run.add(p.a, try p.codepoint(at), at);

        try run.flush(p.a, items, variant);
        const node: Node = blk: {
            if (name.len == 1 and !std.ascii.isAlphabetic(name[0])) {
                const kind: ?@FieldType(Space, "kind") = switch (name[0]) {
                    ',' => .thin,
                    ':', '>' => .medium,
                    ';' => .thick,
                    '!' => .negative_thin,
                    else => null,
                };
                if (kind) |k| break :blk .{ .space = .{ .kind = k, .span = span } };
                if (name[0] == '\\') break :blk .{ .line_break = .{ .kind = .hard, .span = span } };
                return p.fail(.unknown_command, at);
            }
            if (std.mem.eql(u8, name, "quad")) break :blk .{ .space = .{ .kind = .quad, .span = span } };
            if (std.mem.eql(u8, name, "qquad")) break :blk .{ .space = .{ .kind = .qquad, .span = span } };
            if (std.mem.eql(u8, name, "allowbreak")) break :blk .{ .line_break = .{ .kind = .soft, .span = span } };
            if (operators.has(name)) break :blk try p.operatorText(name, at, span);
            if (std.mem.eql(u8, name, "operatorname")) {
                const g = try p.braced(.upright, true);
                break :blk .{ .group = g };
            }
            if (std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "mathup"))
                break :blk .{ .group = try p.braced(.upright, text_mode) };
            if (std.mem.eql(u8, name, "mathit"))
                break :blk .{ .group = try p.braced(.italic, text_mode) };
            if (std.mem.eql(u8, name, "text"))
                break :blk .{ .group = try p.braced(.text, true) };
            const accent: ?@FieldType(Accent, "kind") = if (std.mem.eql(u8, name, "bar"))
                .bar
            else if (std.mem.eql(u8, name, "overline"))
                .overline
            else if (std.mem.eql(u8, name, "hat"))
                .hat
            else
                null;
            if (accent) |k| {
                const body = try p.one(try p.argument(variant, text_mode, at));
                break :blk .{ .accent = .{ .kind = k, .body = body, .span = .{ .start = at, .end = p.i } } };
            }
            if (not_adopted.has(name)) return p.fail(.not_adopted, at);
            return p.fail(.unknown_command, at);
        };
        try items.append(p.a, node);
    }

    /// \u{hex}: a raw codepoint.
    fn codepoint(p: *Parser, at: u32) Error!u21 {
        if (p.peek() != '{') return p.fail(.expected_brace, p.i);
        p.i += 1;
        const s = p.i;
        while (p.peek()) |d| : (p.i += 1) {
            if (!std.ascii.isHex(d)) break;
        }
        const hex = p.src[s..p.i];
        if (p.peek() != '}') return p.fail(.missing_close, s - 1);
        p.i += 1;
        if (hex.len == 0 or hex.len > 6) return p.fail(.invalid_codepoint, at);
        const v = std.fmt.parseInt(u32, hex, 16) catch return p.fail(.invalid_codepoint, at);
        if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return p.fail(.invalid_codepoint, at);
        return @intCast(v);
    }

    fn operatorText(p: *Parser, name: []const u8, at: u32, span: Span) Error!Node {
        const source = try p.a.alloc(u32, name.len);
        for (source, 0..) |*s, k| s.* = at + 1 + @as(u32, @intCast(k));
        return .{ .text = .{ .utf8 = name, .source = source, .variant = .upright, .operator = true, .span = span } };
    }

    fn one(p: *Parser, n: Node) Error!*const Node {
        const ptr = try p.a.create(Node);
        ptr.* = n;
        return ptr;
    }

    /// A script's or accent's argument: a braced group, one command, or one
    /// grapheme cluster.
    fn argument(p: *Parser, variant: Variant, text_mode: bool, owner: u32) Error!Node {
        const c = p.peek() orelse return p.fail(.missing_argument, owner);
        switch (c) {
            '{' => return .{ .group = try p.group(variant, text_mode) },
            '}', '^', '_', ' ', '~', '%' => return p.fail(.missing_argument, p.i),
            '\\' => {
                var items: std.ArrayList(Node) = .empty;
                var run: Run = .{};
                const at = p.i;
                try p.command(&items, &run, variant, text_mode);
                try run.flush(p.a, &items, variant);
                if (items.items.len != 1) return p.fail(.missing_argument, at);
                return items.items[0];
            },
            else => {
                var run: Run = .{};
                const at = p.i;
                const cp = p.char() orelse return p.fail(.invalid_utf8, at);
                if (cp < 0x20 or cp == 0x7F) return p.fail(.control_character, at);
                try run.add(p.a, cp, at);
                // Keep combining marks and joiners with their base.
                while (p.i < p.src.len) {
                    const save = p.i;
                    const next = p.char() orelse break;
                    if (!extendsCluster(next)) {
                        p.i = save;
                        break;
                    }
                    try run.add(p.a, next, save);
                }
                var items: std.ArrayList(Node) = .empty;
                try run.flush(p.a, &items, variant);
                return items.items[0];
            },
        }
    }

    /// Turns the last item into a base with scripts.
    fn attach(p: *Parser, items: *std.ArrayList(Node), variant: Variant) Error!void {
        const at = p.i;
        if (items.items.len == 0) return p.fail(.script_without_base, at);
        var base = items.items[items.items.len - 1];
        switch (base) {
            .text => |t| {
                // The base is the last grapheme cluster of a run.
                const cut = lastCluster(t.utf8);
                if (isSpace(t.utf8[cut..])) return p.fail(.script_without_base, at);
                if (cut > 0) {
                    items.items[items.items.len - 1] = .{ .text = .{
                        .utf8 = t.utf8[0..cut],
                        .source = t.source[0..cut],
                        .variant = t.variant,
                        .operator = t.operator,
                        .span = .{ .start = t.span.start, .end = t.source[cut] },
                    } };
                    try items.append(p.a, undefined);
                    base = .{ .text = .{
                        .utf8 = t.utf8[cut..],
                        .source = t.source[cut..],
                        .variant = t.variant,
                        .operator = t.operator,
                        .span = .{ .start = t.source[cut], .end = t.span.end },
                    } };
                }
            },
            .space, .line_break => return p.fail(.script_without_base, at),
            .scripts => {},
            else => {},
        }
        var sup: ?*const Node = null;
        var sub: ?*const Node = null;
        var start = base.span().start;
        if (base == .scripts) {
            sup = base.scripts.sup;
            sub = base.scripts.sub;
            start = base.scripts.span.start;
            base = base.scripts.base.*;
        }
        while (p.peek()) |c| {
            if (c != '^' and c != '_') break;
            const mark = p.i;
            p.i += 1;
            const arg = try p.one(try p.argument(variant, false, mark));
            if (c == '^') {
                if (sup != null) return p.fail(.double_superscript, mark);
                sup = arg;
            } else {
                if (sub != null) return p.fail(.double_subscript, mark);
                sub = arg;
            }
        }
        items.items[items.items.len - 1] = .{ .scripts = .{
            .base = try p.one(base),
            .sup = sup,
            .sub = sub,
            .span = .{ .start = start, .end = p.i },
        } };
    }
};

/// Characters gathered into one text node, with their source offsets.
const Run = struct {
    utf8: std.ArrayList(u8) = .empty,
    source: std.ArrayList(u32) = .empty,
    start: u32 = 0,
    end: u32 = 0,

    fn add(r: *Run, a: Allocator, cp: u21, at: u32) Error!void {
        if (r.utf8.items.len == 0) r.start = at;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try r.utf8.appendSlice(a, buf[0..n]);
        try r.source.appendNTimes(a, at, n);
        r.end = at + 1;
    }

    fn flush(r: *Run, a: Allocator, items: *std.ArrayList(Node), variant: Variant) Error!void {
        if (r.utf8.items.len == 0) return;
        const last = r.source.items[r.source.items.len - 1];
        try items.append(a, .{ .text = .{
            .utf8 = try r.utf8.toOwnedSlice(a),
            .source = try r.source.toOwnedSlice(a),
            .variant = variant,
            .span = .{ .start = r.start, .end = @max(r.end, last + 1) },
        } });
        r.* = .{};
    }
};

/// Combining marks, variation selectors and joiners: they belong to the
/// cluster before them. (Full UAX #29 segmentation comes with the text stage.)
fn extendsCluster(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F) or (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xE0100 and cp <= 0xE01EF) or cp == 0x200D;
}

/// The byte offset where the last grapheme cluster of `s` starts.
fn lastCluster(s: []const u8) usize {
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    var cut: usize = 0;
    while (true) {
        const pos = it.i;
        const cp = it.nextCodepoint() orelse break;
        if (!extendsCluster(cp)) cut = pos;
    }
    return cut;
}

fn isSpace(s: []const u8) bool {
    return std.mem.eql(u8, s, " ") or std.mem.eql(u8, s, "\u{00A0}") or std.mem.eql(u8, s, "\u{202F}");
}

/// The tree as an S-expression, for tests and stage dumps.
pub fn dump(w: *std.Io.Writer, items: []const Node) std.Io.Writer.Error!void {
    for (items, 0..) |n, k| {
        if (k > 0) try w.writeByte(' ');
        try dumpNode(w, n);
    }
}

fn dumpNode(w: *std.Io.Writer, n: Node) std.Io.Writer.Error!void {
    switch (n) {
        .text => |t| {
            try w.writeAll(if (t.operator) "(op " else "(text ");
            if (t.variant != .default) try w.print("{s} ", .{@tagName(t.variant)});
            try w.print("\"{s}\")", .{t.utf8});
        },
        .group => |g| {
            try w.writeAll("{");
            try dump(w, g.items);
            try w.writeAll("}");
        },
        .scripts => |s| {
            try w.writeAll("(scripts ");
            try dumpNode(w, s.base.*);
            if (s.sup) |x| {
                try w.writeAll(" ^");
                try dumpNode(w, x.*);
            }
            if (s.sub) |x| {
                try w.writeAll(" _");
                try dumpNode(w, x.*);
            }
            try w.writeAll(")");
        },
        .accent => |acc| {
            try w.print("({s} ", .{@tagName(acc.kind)});
            try dumpNode(w, acc.body.*);
            try w.writeAll(")");
        },
        .space => |s| try w.print("(space {s})", .{@tagName(s.kind)}),
        .line_break => |b| try w.print("(break {s})", .{@tagName(b.kind)}),
    }
}

const testing = std.testing;

fn expectTree(src: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = undefined;
    const tree = parse(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("{s}: {s} at {d}\n", .{ src, diag.kind.message(), diag.offset });
        return err;
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try dump(&out.writer, tree.items);
    try testing.expectEqualStrings(expected, out.written());
}

fn expectError(src: []const u8, kind: ErrorKind, offset: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = undefined;
    try testing.expectError(error.Syntax, parse(arena.allocator(), src, &diag));
    try testing.expectEqual(kind, diag.kind);
    try testing.expectEqual(offset, diag.offset);
}

test "plain text keeps its spaces" {
    try expectTree("CAPS LOCK", "(text \"CAPS LOCK\")");
    try expectTree("ENTER", "(text \"ENTER\")");
    try expectTree("", "");
}

test "scripts attach to the cluster, group or command before them" {
    try expectTree("x^2", "(scripts (text \"x\") ^(text \"2\"))");
    try expectTree("e^{x}", "(scripts (text \"e\") ^{(text \"x\")})");
    try expectTree("x_i^2", "(scripts (text \"x\") ^(text \"2\") _(text \"i\"))");
    try expectTree("10^x", "(text \"1\") (scripts (text \"0\") ^(text \"x\"))");
    try expectTree("{10}^x", "(scripts {(text \"10\")} ^(text \"x\"))");
    try expectTree("y^x + 1", "(scripts (text \"y\") ^(text \"x\")) (text \" + 1\")");
    // A base with a combining mark stays one cluster.
    try expectTree("ex\\u{304}^2", "(text \"e\") (scripts (text \"x\u{0304}\") ^(text \"2\"))");
}

test "named characters, raw codepoints, units and escapes" {
    try expectTree("\\Sigma+", "(text \"Σ+\")");
    try expectTree("\\alpha\\beta", "(text \"αβ\")");
    try expectTree("10 k\\ohm", "(text \"10 kΩ\")");
    try expectTree("\\u{3A9}", "(text \"Ω\")");
    try expectTree("50\\%", "(text \"50%\")");
    try expectTree("\\{x\\}", "(text \"{x}\")");
    try expectTree("\\textbackslash", "(text \"\\\")");
}

test "operators, variants and text" {
    try expectTree("\\ln x", "(op upright \"ln\") (text \"x\")");
    try expectTree("\\ln\\ x", "(op upright \"ln\") (text \" x\")");
    try expectTree("\\mathrm{H.MS}", "{(text upright \"H.MS\")}");
    try expectTree("\\mathit{x}y", "{(text italic \"x\")} (text \"y\")");
    try expectTree("\\text{R/S}", "{(text text \"R/S\")}");
    try expectTree("\\operatorname{sgn}", "{(text upright \"sgn\")}");
}

test "accents, spaces and breaks" {
    try expectTree("\\bar{x}", "(bar {(text \"x\")})");
    try expectTree("\\hat y", "(hat (text \"y\"))");
    try expectTree("\\hat{y},r", "(hat {(text \"y\")}) (text \",r\")");
    try expectTree("a\\,b", "(text \"a\") (space thin) (text \"b\")");
    try expectTree("CAPS\\allowbreak LOCK", "(text \"CAPS\") (break soft) (text \"LOCK\")");
    try expectTree("ON\\\\OFF", "(text \"ON\") (break hard) (text \"OFF\")");
    try expectTree("220~V", "(text \"220\u{00A0}V\")");
    try expectTree("AB% a note", "(text \"AB\")");
}

test "source offsets survive resolution" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = undefined;
    const tree = try parse(arena.allocator(), "\\alpha{} x", &diag);
    // α (2 bytes) from offset 0; then an empty group; the space from 8, x from 9.
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, tree.items[0].text.source);
    try testing.expectEqualSlices(u32, &.{ 8, 9 }, tree.items[2].text.source);
}

test "errors are data, with the offset of the problem" {
    try expectError("^2", .script_without_base, 0);
    try expectError("x ^2", .script_without_base, 2);
    try expectError("x^2^3", .double_superscript, 3);
    try expectError("x^", .missing_argument, 1);
    try expectError("x^ 2", .missing_argument, 2);
    try expectError("{a", .missing_close, 0);
    try expectError("a}", .unmatched_close, 1);
    try expectError("\\foo", .unknown_command, 0);
    try expectError("1/\\sqrt{x}", .not_adopted, 2);
    try expectError("\\u{D800}", .invalid_codepoint, 0);
    try expectError("\\text{x^2}", .script_in_text, 7);
    try expectError("a\tb", .control_character, 1);
    try expectError("ab\\", .backslash_at_end, 2);
    try expectError("\xff", .invalid_utf8, 0);
}

test "a configured entity table changes what a name resolves to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var names: entities.Table = .{};
    try names.set(arena.allocator(), "micro", .{ .cp = 0x00B5, .class = .unit });
    var diag: Diagnostic = undefined;
    const tree = try parseWith(arena.allocator(), "5\\micro F", &names, &diag);
    try testing.expectEqualStrings("5\u{00B5}F", tree.items[0].text.utf8);
    const default = try parse(arena.allocator(), "5\\micro F", &diag);
    try testing.expectEqualStrings("5\u{03BC}F", default.items[0].text.utf8);
}
