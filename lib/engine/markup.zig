//! Label markup: a KaTeX-style subset parsed into a neutral tree.
//!
//! The parser records what the source says and nothing more. Which letters
//! are italic, which minus sign a hyphen becomes, and how far apart things
//! sit are style and layout decisions, made later by the engine.
//!
//! Differences from KaTeX, by design:
//! - Spaces are significant: "CAPS LOCK" keeps its space. A space is a
//!   break opportunity; ~ is a non-breaking space.
//! - \\ is a hard break, \allowbreak a soft one and \- a soft hyphen, not a backslash
//!   (write \textbackslash).
//! - A script attaches to the grapheme cluster before it ("CLEAR^2" puts
//!   the 2 on the R), or to the group, command or accent before it.
//! - Constructs not yet adopted (\frac, ...) are errors, as are
//!   unknown commands: nothing passes through unparsed.
//!
//! A preview parse (`parsePreview`) never fails, for showing text while it
//! is typed: each problem is recorded and recovered from locally. A missing
//! argument becomes a placeholder, an unknown or unfinished command (\sq)
//! faint literal text, an unclosed '{' is closed at the end, and a stray
//! '}' is literal. Valid input gives the same tree either way.
//!
//! Every node records the byte range of source it came from, and every
//! byte of resolved text records the source byte it came from, so a
//! problem found later (a missing glyph) can be reported in the source.

const std = @import("std");
const entities = @import("entities.zig");

const Allocator = std.mem.Allocator;

/// Letters' slant as asked for. `default` leaves it to the style.
pub const Script = enum { none, sup, sub };

pub const Shape = enum { default, upright, italic };

/// A math alphabet: letters (and some digits) of a particular design,
/// as \mathbb, \mathfrak and the like ask for. `normal` is the font's own.
pub const Alphabet = enum { normal, double_struck, fraktur, script, calligraphic, sans_serif, monospace };

/// How letters were asked to look: their slant, weight and alphabet, and
/// whether they are text rather than math. Commands change one part and
/// keep the rest, so \textbf{\textit{x}} is bold italic.
pub const Variant = struct {
    shape: Shape = .default,
    bold: bool = false,
    alphabet: Alphabet = .normal,
    /// Text, not math: letters upright unless asked otherwise, and no
    /// math spacing.
    text: bool = false,
    /// Decorations, drawn under each element they cover.
    underline: bool = false,
    strike: bool = false,
    /// Raised or lowered in its line, smaller: text superscript and
    /// subscript (\textsuperscript), which break with the words around
    /// them, unlike math scripts.
    script: Script = .none,
    /// Inside $…$: math as KaTeX sets it, letters italic (variables) unless
    /// asked otherwise (\mathrm), whatever the style's default.
    math: bool = false,

    pub fn eql(a: Variant, b: Variant) bool {
        return a.shape == b.shape and a.bold == b.bold and a.alphabet == b.alphabet and a.text == b.text and
            a.underline == b.underline and a.strike == b.strike and a.script == b.script and a.math == b.math;
    }

    fn with(v: Variant, change: anytype) Variant {
        var out = v;
        inline for (@typeInfo(@TypeOf(change)).@"struct".field_names) |f| @field(out, f) = @field(change, f);
        return out;
    }
};

pub const Span = struct { start: u32, end: u32 };

pub const Node = union(enum) {
    text: Text,
    group: Group,
    scripts: Scripts,
    accent: Accent,
    space: Space,
    line_break: Break,
    /// Preview only: an empty slot where an argument is still to come.
    placeholder: Placeholder,
    /// \sqrt: a radical over its body.
    radical: Radical,
    /// \frac, \tfrac, \dfrac: a numerator over a denominator.
    fraction: Fraction,

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
    /// Preview only: source shown literally because it is not (yet) valid,
    /// an unfinished command say; drawn faint.
    faint: bool = false,
    span: Span,
};

pub const Placeholder = struct {
    span: Span,
};

pub const Radical = struct {
    body: *const Node,
    span: Span,
};

pub const Fraction = struct {
    num: *const Node,
    den: *const Node,
    /// \frac and \tfrac set their parts at script size, \dfrac at full size.
    size: enum { text, display },
    span: Span,
};

pub const Group = struct {
    items: []const Node,
    span: Span,
    /// Only a change of variant (\textbf{…}, \mathbb{…}): its contents
    /// stand in the list around it, as their own atoms, and a line may
    /// break inside it. Braces and \text make one atom.
    flat: bool = false,
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
    /// \\ ends the line; \allowbreak may; \- may inside a word, a hyphen
    /// then ending the line (a soft hyphen).
    kind: enum { hard, soft, hyphen },
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
    unclosed_math,

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
            .unclosed_math => "a '$' that is never closed",
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

/// Whether `src` has math mode: an unescaped '$' outside comments. A label
/// with none is all one markup, as before; one with any is text with math
/// between dollars, as in KaTeX.
pub fn hasMath(src: []const u8) bool {
    var i: usize = 0;
    while (i < src.len) : (i += 1) switch (src[i]) {
        '\\' => i += 1,
        '%' => while (i < src.len and src[i] != '\n') : (i += 1) {},
        '$' => return true,
        else => {},
    };
    return false;
}

/// Parses `src` into a tree allocated from `arena`, with the built-in
/// entity table. On error.Syntax, `diag` says what and where.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!Group {
    return parseWith(arena, src, &entities.Table.builtin, diag);
}

/// A parse that never fails, for previewing text as it is typed; every
/// problem is appended to `problems` and recovered from. See the file's
/// documentation.
pub fn parsePreview(arena: Allocator, src: []const u8, names: *const entities.Table, problems: *std.ArrayList(Diagnostic)) Allocator.Error!Group {
    if (src.len > std.math.maxInt(u32)) return error.OutOfMemory;
    if (!std.unicode.utf8ValidateSlice(src)) {
        try problems.append(arena, .{ .kind = .invalid_utf8, .offset = 0 });
        return .{ .items = &.{}, .span = .{ .start = 0, .end = @intCast(src.len) } };
    }
    var unused: Diagnostic = undefined;
    var p: Parser = .{ .a = arena, .src = src, .names = names, .diag = &unused, .problems = problems, .dollars = hasMath(src) };
    const items = p.list(p.topVariant(), false, p.dollars) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Every failure is recovered from in preview.
        error.Syntax => unreachable,
    };
    return .{ .items = items, .span = .{ .start = 0, .end = @intCast(src.len) } };
}

/// As `parse`, with a configured entity table.
pub fn parseWith(arena: Allocator, src: []const u8, names: *const entities.Table, diag: *Diagnostic) Error!Group {
    if (src.len > std.math.maxInt(u32)) return error.OutOfMemory;
    if (!std.unicode.utf8ValidateSlice(src)) {
        diag.* = .{ .kind = .invalid_utf8, .offset = 0 };
        return error.Syntax;
    }
    var p: Parser = .{ .a = arena, .src = src, .names = names, .diag = diag, .dollars = hasMath(src) };
    const items = try p.list(p.topVariant(), false, p.dollars);
    return .{ .items = items, .span = .{ .start = 0, .end = @intCast(src.len) } };
}

const operators = std.StaticStringMap(void).initComptime(.{
    .{"ln"},     .{"log"},    .{"lg"},     .{"exp"},  .{"sin"},  .{"cos"},  .{"tan"},
    .{"sec"},    .{"csc"},    .{"cot"},    .{"sinh"}, .{"cosh"}, .{"tanh"}, .{"coth"},
    .{"arcsin"}, .{"arccos"}, .{"arctan"}, .{"min"},  .{"max"},  .{"det"},  .{"deg"},
    .{"lim"},    .{"mod"},    .{"gcd"},    .{"Re"},   .{"Im"},   .{"arg"},
});

const alphabets = std.StaticStringMap(Alphabet).initComptime(.{
    .{ "mathbb", .double_struck },  .{ "mathfrak", .fraktur },  .{ "mathscr", .script },
    .{ "mathcal", .calligraphic },  .{ "mathsf", .sans_serif }, .{ "mathtt", .monospace },
});

/// Commands that take arguments or shape the label, with what follows their
/// name when completed: "{}" for each braced argument.
const structural = [_]struct { name: []const u8, args: []const u8, note: []const u8 }{
    .{ .name = "text", .args = "{}", .note = "text, not math" },
    .{ .name = "mathrm", .args = "{}", .note = "upright" },
    .{ .name = "mathup", .args = "{}", .note = "upright" },
    .{ .name = "mathit", .args = "{}", .note = "italic" },
    .{ .name = "mathbf", .args = "{}", .note = "bold, upright" },
    .{ .name = "boldsymbol", .args = "{}", .note = "bold" },
    .{ .name = "textbf", .args = "{}", .note = "bold text" },
    .{ .name = "textit", .args = "{}", .note = "italic text" },
    .{ .name = "emph", .args = "{}", .note = "emphasis (italic, or upright in italic)" },
    .{ .name = "textup", .args = "{}", .note = "upright text" },
    .{ .name = "textmd", .args = "{}", .note = "regular weight" },
    .{ .name = "textnormal", .args = "{}", .note = "plain text" },
    .{ .name = "mathbb", .args = "{}", .note = "double-struck" },
    .{ .name = "mathfrak", .args = "{}", .note = "fraktur" },
    .{ .name = "mathscr", .args = "{}", .note = "script" },
    .{ .name = "mathcal", .args = "{}", .note = "calligraphic" },
    .{ .name = "mathsf", .args = "{}", .note = "sans-serif" },
    .{ .name = "mathtt", .args = "{}", .note = "monospace" },
    .{ .name = "textsf", .args = "{}", .note = "sans-serif text" },
    .{ .name = "texttt", .args = "{}", .note = "monospace text" },
    .{ .name = "underline", .args = "{}", .note = "underlined" },
    .{ .name = "sout", .args = "{}", .note = "struck through" },
    .{ .name = "textsuperscript", .args = "{}", .note = "raised text" },
    .{ .name = "textsubscript", .args = "{}", .note = "lowered text" },
    .{ .name = "operatorname", .args = "{}", .note = "operator name" },
    .{ .name = "hat", .args = "{}", .note = "circumflex accent" },
    .{ .name = "bar", .args = "{}", .note = "bar accent" },
    .{ .name = "overline", .args = "{}", .note = "overline" },
    .{ .name = "sqrt", .args = "{}", .note = "square root" },
    .{ .name = "frac", .args = "{}{}", .note = "fraction" },
    .{ .name = "tfrac", .args = "{}{}", .note = "fraction" },
    .{ .name = "dfrac", .args = "{}{}", .note = "fraction, full size" },
    .{ .name = "u", .args = "{}", .note = "code point, hex" },
    .{ .name = "quad", .args = "", .note = "space, 1 em" },
    .{ .name = "qquad", .args = "", .note = "space, 2 em" },
    .{ .name = "allowbreak", .args = "", .note = "break here if needed" },
};

pub const Completion = struct {
    /// The command's name, without the backslash.
    name: []const u8,
    /// What completing it inserts after the name: "{}" per argument.
    args: []const u8 = "",
    /// The character it stands for, for a named character.
    cp: ?u21 = null,
    /// A short description, for anything else.
    note: []const u8 = "",
};

/// Commands starting with `prefix` (no backslash), for completing a command
/// as it is typed: named characters (the configured table first, then the
/// built-in), operator names and structural commands, shortest first, then
/// in alphabetical order.
pub fn completions(gpa: Allocator, names: *const entities.Table, prefix: []const u8, out: *std.ArrayList(Completion)) Allocator.Error!void {
    const start = out.items.len;
    var it = names.overrides.iterator();
    while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, prefix)) {
        try out.append(gpa, .{ .name = e.key_ptr.*, .cp = e.value_ptr.cp });
    };
    for (entities.table.keys(), entities.table.values()) |k, v| {
        if (!std.mem.startsWith(u8, k, prefix) or names.overrides.contains(k)) continue;
        try out.append(gpa, .{ .name = k, .cp = v.cp });
    }
    for (operators.keys()) |k| if (std.mem.startsWith(u8, k, prefix)) {
        try out.append(gpa, .{ .name = k, .note = "operator name" });
    };
    for (structural) |c| if (std.mem.startsWith(u8, c.name, prefix)) {
        try out.append(gpa, .{ .name = c.name, .args = c.args, .note = c.note });
    };
    std.mem.sort(Completion, out.items[start..], {}, struct {
        fn less(_: void, x: Completion, y: Completion) bool {
            if (x.name.len != y.name.len) return x.name.len < y.name.len;
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
}

/// Commands reserved for constructs to be adopted one at a time.
const not_adopted = std.StaticStringMap(void).initComptime(.{
    .{"sfrac"}, .{"overlay"},
    .{"rlap"},  .{"llap"},
    .{"vec"},   .{"dot"},
    .{"ddot"},  .{"tilde"},
});

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: u32 = 0,
    names: *const entities.Table,
    diag: *Diagnostic,
    /// Set for a preview parse: problems are recorded here and recovered
    /// from, rather than failing.
    problems: ?*std.ArrayList(Diagnostic) = null,
    /// The label has math mode: text, with math between dollars.
    dollars: bool = false,

    fn fail(p: *Parser, kind: ErrorKind, at: u32) Error {
        p.diag.* = .{ .kind = kind, .offset = at };
        return error.Syntax;
    }

    /// In a strict parse, fails; in a preview, records the problem so the
    /// caller can recover.
    fn problem(p: *Parser, kind: ErrorKind, at: u32) Error!void {
        const found = p.problems orelse return p.fail(kind, at);
        try found.append(p.a, .{ .kind = kind, .offset = at });
    }

    /// Source shown literally and faint (preview only).
    fn faint(p: *Parser, start: u32, end: u32) Error!Node {
        const source = try p.a.alloc(u32, end - start);
        for (source, 0..) |*s, k| s.* = start + @as(u32, @intCast(k));
        return .{ .text = .{
            .utf8 = p.src[start..end],
            .source = source,
            .variant = .{ .shape = .upright },
            .faint = true,
            .span = .{ .start = start, .end = end },
        } };
    }

    fn placeholder(at: u32) Node {
        return .{ .placeholder = .{ .span = .{ .start = at, .end = at } } };
    }

    /// The variant at the top: text, when the label has math mode.
    fn topVariant(p: *const Parser) Variant {
        return if (p.dollars) .{ .text = true } else .{};
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
                // In a preview an unclosed group closes at the end.
                if (closing) try p.problem(.missing_close, open_at);
                break;
            };
            switch (c) {
                '}' => {
                    if (!closing) {
                        try p.problem(.unmatched_close, p.i);
                        try run.flush(p.a, &items, variant);
                        try items.append(p.a, try p.faint(p.i, p.i + 1));
                        p.i += 1;
                        continue;
                    }
                    p.i += 1;
                    break;
                },
                '{' => {
                    try run.flush(p.a, &items, variant);
                    try items.append(p.a, .{ .group = try p.group(variant, text_mode) });
                },
                '^', '_' => {
                    try run.flush(p.a, &items, variant);
                    if (text_mode) {
                        try p.problem(.script_in_text, p.i);
                        try items.append(p.a, try p.faint(p.i, p.i + 1));
                        p.i += 1;
                        continue;
                    }
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
                '$' => {
                    if (!p.dollars) {
                        try run.add(p.a, '$', p.i);
                        p.i += 1;
                        continue;
                    }
                    if (variant.math) {
                        // The end of math: the math list ends here; a group
                        // still open in it closes first.
                        if (closing) try p.problem(.missing_close, open_at);
                        break;
                    }
                    try run.flush(p.a, &items, variant);
                    const start = p.i;
                    p.i += 1;
                    const math = try p.list(variant.with(.{ .math = true, .text = false, .shape = .default, .script = .none }), false, false);
                    if (p.peek() == '$') p.i += 1 else try p.problem(.unclosed_math, start);
                    try items.append(p.a, .{ .group = .{ .items = math, .span = .{ .start = start, .end = p.i } } });
                },
                else => {
                    const at = p.i;
                    const cp = p.char() orelse return p.fail(.invalid_utf8, at);
                    if (cp < 0x20 or cp == 0x7F) {
                        // In a preview the control character is skipped.
                        try p.problem(.control_character, at);
                        continue;
                    }
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
        if (p.peek() != '{') {
            try p.problem(.expected_brace, p.i);
            const items = try p.a.alloc(Node, 1);
            items[0] = placeholder(p.i);
            return .{ .items = items, .span = .{ .start = p.i, .end = p.i } };
        }
        return p.argGroup(variant, text_mode);
    }

    /// The braced argument of a variant command: a flat group.
    fn styled(p: *Parser, variant: Variant, text_mode: bool) Error!Group {
        var g = try p.braced(variant, text_mode);
        g.flat = true;
        return g;
    }

    /// A braced argument. In a preview an empty one holds a slot, so where
    /// its content goes shows while it is typed.
    fn argGroup(p: *Parser, variant: Variant, text_mode: bool) Error!Group {
        var g = try p.group(variant, text_mode);
        if (p.problems != null and g.items.len == 0) {
            const items = try p.a.alloc(Node, 1);
            items[0] = placeholder(g.span.start + 1);
            g.items = items;
        }
        return g;
    }

    fn command(p: *Parser, items: *std.ArrayList(Node), run: *Run, variant: Variant, text_mode: bool) Error!void {
        const at = p.i;
        p.i += 1; // the backslash
        const first = p.peek() orelse {
            try p.problem(.backslash_at_end, at);
            try run.flush(p.a, items, variant);
            return items.append(p.a, try p.faint(at, p.i));
        };
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
                if (name[0] == '-') break :blk .{ .line_break = .{ .kind = .hyphen, .span = span } };
                try p.problem(.unknown_command, at);
                break :blk try p.faint(at, span.end);
            }
            if (std.mem.eql(u8, name, "quad")) break :blk .{ .space = .{ .kind = .quad, .span = span } };
            if (std.mem.eql(u8, name, "qquad")) break :blk .{ .space = .{ .kind = .qquad, .span = span } };
            if (std.mem.eql(u8, name, "allowbreak")) break :blk .{ .line_break = .{ .kind = .soft, .span = span } };
            if (operators.has(name)) break :blk try p.operatorText(name, at, span);
            if (std.mem.eql(u8, name, "operatorname")) {
                // One run of text becomes an operator name, like \ln.
                const g = try p.braced(.{ .shape = .upright }, true);
                if (g.items.len == 1 and g.items[0] == .text) {
                    var t = g.items[0].text;
                    t.operator = true;
                    t.span = .{ .start = at, .end = g.span.end };
                    break :blk .{ .text = t };
                }
                break :blk .{ .group = g };
            }
            if (std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "mathup"))
                break :blk .{ .group = try p.styled(variant.with(.{ .shape = .upright, .alphabet = .normal }), text_mode) };
            if (std.mem.eql(u8, name, "mathit"))
                break :blk .{ .group = try p.styled(variant.with(.{ .shape = .italic, .alphabet = .normal }), text_mode) };
            if (std.mem.eql(u8, name, "text"))
                break :blk .{ .group = try p.braced(variant.with(.{ .text = true, .shape = .default, .alphabet = .normal }), true) };
            // Weight and slant, in text or math.
            if (std.mem.eql(u8, name, "textbf"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .bold = true }), true) };
            if (std.mem.eql(u8, name, "mathbf"))
                break :blk .{ .group = try p.styled(variant.with(.{ .bold = true, .shape = .upright, .alphabet = .normal }), text_mode) };
            if (std.mem.eql(u8, name, "boldsymbol") or std.mem.eql(u8, name, "bm"))
                break :blk .{ .group = try p.styled(variant.with(.{ .bold = true }), text_mode) };
            if (std.mem.eql(u8, name, "textit"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .shape = .italic }), true) };
            if (std.mem.eql(u8, name, "emph"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .shape = if (variant.shape == .italic) Shape.upright else Shape.italic }), true) };
            if (std.mem.eql(u8, name, "textup") or std.mem.eql(u8, name, "textrm"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .shape = .upright, .alphabet = .normal }), true) };
            if (std.mem.eql(u8, name, "textmd"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .bold = false }), true) };
            if (std.mem.eql(u8, name, "textnormal"))
                break :blk .{ .group = try p.styled(.{ .text = true }, true) };
            // Math alphabets, upright; bold carries over (bold fraktur).
            if (alphabets.get(name)) |alpha|
                break :blk .{ .group = try p.styled(variant.with(.{ .alphabet = alpha, .shape = .upright }), text_mode) };
            if (std.mem.eql(u8, name, "textsf"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .alphabet = .sans_serif }), true) };
            if (std.mem.eql(u8, name, "texttt"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .alphabet = .monospace }), true) };
            // Decorations, in text or math.
            if (std.mem.eql(u8, name, "underline") or std.mem.eql(u8, name, "uline"))
                break :blk .{ .group = try p.styled(variant.with(.{ .underline = true }), text_mode) };
            if (std.mem.eql(u8, name, "sout") or std.mem.eql(u8, name, "st"))
                break :blk .{ .group = try p.styled(variant.with(.{ .strike = true }), text_mode) };
            if (std.mem.eql(u8, name, "textsuperscript"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .script = .sup }), true) };
            if (std.mem.eql(u8, name, "textsubscript"))
                break :blk .{ .group = try p.styled(variant.with(.{ .text = true, .script = .sub }), true) };
            const accent: ?@FieldType(Accent, "kind") = if (std.mem.eql(u8, name, "bar"))
                .bar
            else if (std.mem.eql(u8, name, "overline"))
                .overline
            else if (std.mem.eql(u8, name, "hat"))
                .hat
            else
                null;
            const frac_size: ?@FieldType(Fraction, "size") = if (std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "tfrac"))
                .text
            else if (std.mem.eql(u8, name, "dfrac"))
                .display
            else
                null;
            if (frac_size) |size| {
                const num = try p.one(try p.argument(variant, text_mode, at));
                const den = try p.one(try p.argument(variant, text_mode, at));
                break :blk .{ .fraction = .{ .num = num, .den = den, .size = size, .span = .{ .start = at, .end = p.i } } };
            }
            if (std.mem.eql(u8, name, "sqrt")) {
                const body = try p.one(try p.argument(variant, text_mode, at));
                break :blk .{ .radical = .{ .body = body, .span = .{ .start = at, .end = p.i } } };
            }
            if (accent) |k| {
                const body = try p.one(try p.argument(variant, text_mode, at));
                break :blk .{ .accent = .{ .kind = k, .body = body, .span = .{ .start = at, .end = p.i } } };
            }
            // In a preview an unknown or unfinished command shows as typed.
            try p.problem(if (not_adopted.has(name)) .not_adopted else .unknown_command, at);
            break :blk try p.faint(at, span.end);
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
        // In a preview a bad codepoint is the replacement character.
        if (p.peek() != '}') {
            try p.problem(.missing_close, s - 1);
            return 0xFFFD;
        }
        p.i += 1;
        const v = std.fmt.parseInt(u32, hex, 16) catch 0x110000;
        if (hex.len == 0 or hex.len > 6 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) {
            try p.problem(.invalid_codepoint, at);
            return 0xFFFD;
        }
        return @intCast(v);
    }

    fn operatorText(p: *Parser, name: []const u8, at: u32, span: Span) Error!Node {
        const source = try p.a.alloc(u32, name.len);
        for (source, 0..) |*s, k| s.* = at + 1 + @as(u32, @intCast(k));
        return .{ .text = .{ .utf8 = name, .source = source, .variant = .{ .shape = .upright }, .operator = true, .span = span } };
    }

    fn one(p: *Parser, n: Node) Error!*const Node {
        const ptr = try p.a.create(Node);
        ptr.* = n;
        return ptr;
    }

    /// A script's or accent's argument: a braced group, one command, or one
    /// grapheme cluster.
    fn argument(p: *Parser, variant: Variant, text_mode: bool, owner: u32) Error!Node {
        // In a preview a missing argument is a placeholder.
        const c = p.peek() orelse {
            try p.problem(.missing_argument, owner);
            return placeholder(p.i);
        };
        switch (c) {
            '{' => return .{ .group = try p.argGroup(variant, text_mode) },
            '}', '^', '_', ' ', '~', '%' => {
                try p.problem(.missing_argument, p.i);
                return placeholder(p.i);
            },
            '\\' => {
                var items: std.ArrayList(Node) = .empty;
                var run: Run = .{};
                const at = p.i;
                try p.command(&items, &run, variant, text_mode);
                try run.flush(p.a, &items, variant);
                if (items.items.len != 1) {
                    try p.problem(.missing_argument, at);
                    if (items.items.len == 0) return placeholder(p.i);
                    return .{ .group = .{ .items = try items.toOwnedSlice(p.a), .span = .{ .start = at, .end = p.i } } };
                }
                return items.items[0];
            },
            else => {
                var run: Run = .{};
                const at = p.i;
                const cp = p.char() orelse return p.fail(.invalid_utf8, at);
                if (cp < 0x20 or cp == 0x7F) {
                    try p.problem(.control_character, at);
                    return placeholder(at);
                }
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
        if (items.items.len == 0) {
            // In a preview a script with no base gets a placeholder base.
            try p.problem(.script_without_base, at);
            try items.append(p.a, placeholder(at));
        }
        var base = items.items[items.items.len - 1];
        switch (base) {
            .text => |t| if (!t.operator) {
                // The base is the last grapheme cluster of a run; an operator
                // name (\sin) is a base as a whole.
                const cut = lastCluster(t.utf8);
                if (isSpace(t.utf8[cut..])) {
                    try p.problem(.script_without_base, at);
                    try items.append(p.a, placeholder(at));
                    return p.attach(items, variant);
                }
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
            .space, .line_break => {
                try p.problem(.script_without_base, at);
                try items.append(p.a, placeholder(at));
                return p.attach(items, variant);
            },
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
            // In a preview a second script of a kind replaces the first.
            if (c == '^') {
                if (sup != null) try p.problem(.double_superscript, mark);
                sup = arg;
            } else {
                if (sub != null) try p.problem(.double_subscript, mark);
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
pub fn extendsCluster(cp: u21) bool {
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
            try w.writeAll(if (t.operator) "(op " else if (t.faint) "(faint " else "(text ");
            if (t.variant.text) try w.writeAll("text ");
            if (t.variant.math) try w.writeAll("math ");
            if (t.variant.shape != .default) try w.print("{s} ", .{@tagName(t.variant.shape)});
            if (t.variant.bold) try w.writeAll("bold ");
            if (t.variant.alphabet != .normal) try w.print("{s} ", .{@tagName(t.variant.alphabet)});
            if (t.variant.underline) try w.writeAll("underline ");
            if (t.variant.strike) try w.writeAll("strike ");
            if (t.variant.script != .none) try w.print("{s} ", .{@tagName(t.variant.script)});
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
        .placeholder => try w.writeAll("(slot)"),
        .radical => |r| {
            try w.writeAll("(sqrt ");
            try dumpNode(w, r.body.*);
            try w.writeAll(")");
        },
        .fraction => |f| {
            try w.writeAll(if (f.size == .display) "(dfrac " else "(frac ");
            try dumpNode(w, f.num.*);
            try w.writeAll(" ");
            try dumpNode(w, f.den.*);
            try w.writeAll(")");
        },
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

test "math mode: text outside dollars, math inside, as in KaTeX" {
    // No dollars: all one markup, as before.
    try expectTree("LOG", "(text \"LOG\")");
    // Text, then math: the math a group of its own.
    try expectTree("CL$x$", "(text text \"CL\") {(text math \"x\")}");
    try expectTree("$x^2$", "{(scripts (text math \"x\") ^(text math \"2\"))}");
    try expectTree("$\\mathrm{SIN}^{-1}$", "{(scripts {(text math upright \"SIN\")} ^{(text math \"-1\")})}");
    // An escaped dollar is a dollar, and alone it makes no math mode.
    try expectTree("\\$5", "(text \"$5\")");
    try expectTree("\\$$x$", "(text text \"$\") {(text math \"x\")}");
    // Scripts belong in math; a dollar must close.
    try expectError("x^2 $y$", .script_in_text, 1);
    try expectError("a $x", .unclosed_math, 2);
    try expectError("${x$", .missing_close, 1);
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
    try expectTree("\\sin^{\\minus 1}", "(scripts (op upright \"sin\") ^{(text \"−1\")})");
    try expectTree("\\ln\\ x", "(op upright \"ln\") (text \" x\")");
    try expectTree("\\mathrm{H.MS}", "{(text upright \"H.MS\")}");
    try expectTree("\\mathit{x}y", "{(text italic \"x\")} (text \"y\")");
    try expectTree("\\text{R/S}", "{(text text \"R/S\")}");
    try expectTree("\\operatorname{sgn}", "(op upright \"sgn\")");
}

test "weights, slants and math alphabets nest" {
    try expectTree("\\textbf{ab}", "{(text text bold \"ab\")}");
    try expectTree("\\textbf{a\\textit{b}}", "{(text text bold \"a\") {(text text italic bold \"b\")}}");
    try expectTree("\\mathbf{x}", "{(text upright bold \"x\")}");
    try expectTree("\\boldsymbol{\\mathfrak{A}}", "{{(text upright bold fraktur \"A\")}}");
    try expectTree("\\mathbb{R}^2", "(scripts {(text upright double_struck \"R\")} ^(text \"2\"))");
    try expectTree("\\textit{a\\emph{b}}", "{(text text italic \"a\") {(text text upright \"b\")}}");
    try expectTree("\\texttt{ls}", "{(text text monospace \"ls\")}");
}

test "decorations and text scripts" {
    try expectTree("\\underline{a \\textbf{b}}", "{(text underline \"a \") {(text text bold underline \"b\")}}");
    try expectTree("\\sout{x}", "{(text strike \"x\")}");
    try expectTree("1\\textsuperscript{st}", "(text \"1\") {(text text sup \"st\")}");
    try expectTree("H\\textsubscript{2}O", "(text \"H\") {(text text sub \"2\")} (text \"O\")");
}

test "accents, spaces and breaks" {
    try expectTree("\\bar{x}", "(bar {(text \"x\")})");
    try expectTree("\\hat y", "(hat (text \"y\"))");
    try expectTree("\\hat{y},r", "(hat {(text \"y\")}) (text \",r\")");
    try expectTree("a\\,b", "(text \"a\") (space thin) (text \"b\")");
    try expectTree("CAPS\\allowbreak LOCK", "(text \"CAPS\") (break soft) (text \"LOCK\")");
    try expectTree("Back\\-space", "(text \"Back\") (break hyphen) (text \"space\")");
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
    try expectError("1/\\sfrac{x}{y}", .not_adopted, 2);
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

fn previewDump(src: []const u8, problems: *std.ArrayList(Diagnostic), arena: Allocator) ![]const u8 {
    const tree = try parsePreview(arena, src, &entities.Table.builtin, problems);
    var out: std.Io.Writer.Allocating = .init(arena);
    try dump(&out.writer, tree.items);
    return out.written();
}

test "a preview parse never fails and shows what is still to come" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { src: []const u8, tree: []const u8, problem: ?ErrorKind }{
        .{ .src = "x^", .tree = "(scripts (text \"x\") ^(slot))", .problem = .missing_argument },
        .{ .src = "x^{2", .tree = "(scripts (text \"x\") ^{(text \"2\")})", .problem = .missing_close },
        .{ .src = "\\sq", .tree = "(faint upright \"\\sq\")", .problem = .unknown_command },
        .{ .src = "a\\", .tree = "(text \"a\") (faint upright \"\\\")", .problem = .backslash_at_end },
        .{ .src = "a}b", .tree = "(text \"a\") (faint upright \"}\") (text \"b\")", .problem = .unmatched_close },
        .{ .src = "^2", .tree = "(scripts (slot) ^(text \"2\"))", .problem = .script_without_base },
        .{ .src = "\\text", .tree = "{(slot)}", .problem = .expected_brace },
        .{ .src = "x^{2}", .tree = "(scripts (text \"x\") ^{(text \"2\")})", .problem = null },
        .{ .src = "\\sqrt{", .tree = "(sqrt {(slot)})", .problem = .missing_close },
        .{ .src = "\\sqrt", .tree = "(sqrt (slot))", .problem = .missing_argument },
        .{ .src = "\\frac{}{}", .tree = "(frac {(slot)} {(slot)})", .problem = null },
        .{ .src = "\\frac{1}", .tree = "(frac {(text \"1\")} (slot))", .problem = .missing_argument },
    };
    for (cases) |c| {
        var problems: std.ArrayList(Diagnostic) = .empty;
        const got = try previewDump(c.src, &problems, a);
        try testing.expectEqualStrings(c.tree, got);
        if (c.problem) |k| {
            try testing.expect(problems.items.len >= 1);
            try testing.expectEqual(k, problems.items[0].kind);
        } else try testing.expectEqual(0, problems.items.len);
    }
}

test "valid input parses the same strictly and in preview" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "CAPS LOCK", "x_i^2", "\\hat{x} + \\sin^{-1} y", "A\\\\B", "\\text{ab} \\ohm", "\\sqrt{x^2+1}", "\\sqrt2", "\\frac{a}{b}", "\\dfrac12" }) |src| {
        var diag: Diagnostic = undefined;
        const strict = try parse(a, src, &diag);
        var s1: std.Io.Writer.Allocating = .init(a);
        try dump(&s1.writer, strict.items);
        var problems: std.ArrayList(Diagnostic) = .empty;
        try testing.expectEqualStrings(s1.written(), try previewDump(src, &problems, a));
        try testing.expectEqual(0, problems.items.len);
    }
}

test "completions offer named characters, operators and commands with their arguments" {
    var list: std.ArrayList(Completion) = .empty;
    defer list.deinit(testing.allocator);
    try completions(testing.allocator, &entities.Table.builtin, "si", &list);
    var saw_sin = false;
    var saw_sigma = false;
    for (list.items) |c| {
        try testing.expect(std.mem.startsWith(u8, c.name, "si"));
        if (std.mem.eql(u8, c.name, "sin")) saw_sin = true;
        if (std.mem.eql(u8, c.name, "sigma")) saw_sigma = c.cp == 0x03C3;
    }
    try testing.expect(saw_sin and saw_sigma);
    // Shortest first (\\sim and \\sin before \\sigma), then alphabetical.
    try testing.expectEqualStrings("sim", list.items[0].name);
    try testing.expectEqualStrings("sin", list.items[1].name);

    list.clearRetainingCapacity();
    try completions(testing.allocator, &entities.Table.builtin, "tex", &list);
    try testing.expectEqualStrings("text", list.items[0].name);
    try testing.expectEqualStrings("{}", list.items[0].args);
}
