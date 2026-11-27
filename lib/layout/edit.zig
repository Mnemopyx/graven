//! Editing the source of a run in place, character by character, without
//! breaking it.
//!
//! A run is source: a legend (text, with math between dollars) or, for an
//! equation, all math. Editing works on its characters as glyphic's parse
//! finds them: each character of a text word or a math leaf (and each
//! space) has a range of source bytes. Deleting removes only those bytes,
//! so commands, braces and arguments stay whole (an emptied \textbf{} is
//! harmless). Splitting a run in two closes the emphasis groups open at
//! the split in the first part and opens them again in the second.

const std = @import("std");
const glyphic = @import("graven_glyphic");
const rt = @import("graven_richtext");

const Allocator = std.mem.Allocator;
const Id = glyphic.Id;

/// One character of a run's source: its source bytes, and what it reads
/// as (for copying as plain text).
pub const Char = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

const Parsed = struct { e: glyphic.Expr, spans: glyphic.entry.Spans };

fn parse(a: Allocator, src: []const u8, math: bool) Allocator.Error!Parsed {
    var p: Parsed = .{ .e = try glyphic.Expr.init(a), .spans = .{} };
    glyphic.latex.parse(&p.e, &p.spans, src, if (math) .math else .legend) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The parsers never fail but for memory; anything else leaves
        // what was made so far.
        else => {},
    };
    return p;
}

/// The characters of source `src` (all math when `math`), in source
/// order. Allocated from `a`.
pub fn chars(a: Allocator, src: []const u8, math: bool) Allocator.Error![]Char {
    const p = try parse(a, src, math);
    var out: std.ArrayList(Char) = .empty;
    try walk(a, &p, src, p.e.root, &out);
    std.mem.sort(Char, out.items, {}, struct {
        fn lt(_: void, x: Char, y: Char) bool {
            return x.start < y.start;
        }
    }.lt);
    return out.items;
}

fn walk(a: Allocator, p: *const Parsed, src: []const u8, id: Id, out: *std.ArrayList(Char)) Allocator.Error!void {
    const e = &p.e;
    const n = e.node(id);
    if (!n.live) return;
    if (n.kind == .row) {
        for (n.items.items) |c| try walk(a, p, src, c, out);
        return;
    }
    if (n.kind.isStructure()) {
        for (n.kind.slots()) |sl| {
            const row = e.slot(id, sl);
            if (row != .none) try walk(a, p, src, row, out);
        }
        return;
    }
    const sp = p.spans.get(id);
    if (sp.start == glyphic.entry.Span.none.start or sp.end <= sp.start or sp.end > src.len) return;
    switch (n.kind) {
        .soft_hyphen => try out.append(a, .{ .start = sp.start, .end = sp.end, .text = "" }),
        .space => for (sp.start..sp.end) |i| try out.append(a, .{ .start = @intCast(i), .end = @intCast(i + 1), .text = " " }),
        else => if (glyphic.entry.isText(e, id) or std.mem.eql(u8, src[sp.start..sp.end], n.text)) {
            // Text as it stands in the source: a character at a time, an
            // escape (\%) or a named character (\textbackslash) as one.
            var i: u32 = sp.start;
            while (i < sp.end) {
                const end = @min(sourceEnd(src, i), sp.end);
                try out.append(a, .{ .start = i, .end = end, .text = readsAs(src[i..end]) });
                i = end;
            }
        } else {
            // A leaf written as a command (\pi, -): one character.
            try out.append(a, .{ .start = sp.start, .end = sp.end, .text = n.text });
        },
    }
}

/// What a character's source reads as.
fn readsAs(s: []const u8) []const u8 {
    if (s.len < 2 or s[0] != '\\') return s;
    if (std.mem.startsWith(u8, s, "\\textbackslash")) return "\\";
    if (!std.ascii.isAlphabetic(s[1])) return s[1..];
    return s;
}

/// Where the source of the character starting at byte `start` ends: past
/// an escape (\%) or a named character (\alpha, \textbackslash{}), else
/// past its UTF-8 bytes.
fn sourceEnd(src: []const u8, start: u32) u32 {
    if (start >= src.len) return start;
    if (src[start] != '\\') {
        const len = std.unicode.utf8ByteSequenceLength(src[start]) catch 1;
        return @intCast(@min(src.len, start + len));
    }
    var e: usize = start + 1;
    if (e < src.len and std.ascii.isAlphabetic(src[e])) {
        while (e < src.len and std.ascii.isAlphabetic(src[e])) e += 1;
        if (e + 1 < src.len and src[e] == '{' and src[e + 1] == '}') e += 2;
    } else if (e < src.len) {
        e += std.unicode.utf8ByteSequenceLength(src[e]) catch 1;
    }
    return @intCast(@min(e, src.len));
}

/// `src` without the characters that start in [`from`, `to`). Allocated
/// from `a`.
pub fn deleteChars(a: Allocator, src: []const u8, from: u32, to: u32, math: bool) Allocator.Error![]u8 {
    const cs = try chars(a, src, math);
    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;
    for (cs) |c| {
        if (c.start < from or c.start >= to or c.start < at) continue;
        try out.appendSlice(a, src[at..c.start]);
        at = c.end;
    }
    try out.appendSlice(a, src[@min(at, src.len)..]);
    return out.items;
}

/// Where the character before byte `offset` starts (null at the start).
pub fn charBefore(a: Allocator, src: []const u8, offset: u32, math: bool) Allocator.Error!?u32 {
    var best: ?u32 = null;
    for (try chars(a, src, math)) |c| {
        if (c.start < offset) best = c.start else break;
    }
    return best;
}

/// Where the character at byte `offset` (or the next after it) ends: the
/// end of the run's text when there is none.
pub fn charAfter(a: Allocator, src: []const u8, offset: u32, math: bool) Allocator.Error!?u32 {
    for (try chars(a, src, math)) |c| {
        if (c.start >= offset) return c.end;
    }
    return null;
}

/// Whether `src` has any characters at all.
pub fn hasChars(a: Allocator, src: []const u8, math: bool) Allocator.Error!bool {
    return (try chars(a, src, math)).len > 0;
}

/// What the characters starting in [`from`, `to`) of `src` read as, as
/// plain text, appended to `out`.
pub fn plainText(a: Allocator, src: []const u8, from: u32, to: u32, math: bool, out: *std.ArrayList(u8)) Allocator.Error!void {
    for (try chars(a, src, math)) |c| {
        if (c.start >= from and c.start < to) try out.appendSlice(a, c.text);
    }
}

/// The emphasis commands a legend's text opens groups with (see
/// glyphic's legend parser), and the bare brace.
const openers = [_][]const u8{ "\\textbf{", "\\textit{", "\\emph{", "\\textrm{", "\\textup{", "\\textnormal{", "{" };

/// Legend `src` split at byte `offset` into two runs that read as it did:
/// the groups (\textbf{…}, braces) open there are closed in the first and
/// opened again in the second. Null where it cannot be split: inside math
/// (between dollars) or inside a command.
pub fn splitAt(a: Allocator, src: []const u8, offset: u32) Allocator.Error!?[2][]u8 {
    var open: std.ArrayList([]const u8) = .empty;
    var math = false;
    var i: usize = 0;
    while (i < offset and i < src.len) {
        const c = src[i];
        if (c == '$') {
            math = !math;
            i += 1;
            continue;
        }
        if (math) {
            i += if (c == '\\' and i + 1 < src.len) 2 else 1;
            continue;
        }
        const opened = for (openers) |o| {
            if (std.mem.startsWith(u8, src[i..], o)) break o;
        } else null;
        if (opened) |o| {
            try open.append(a, o);
            i += o.len;
            continue;
        }
        if (c == '}') {
            if (open.items.len > 0) _ = open.pop();
            i += 1;
            continue;
        }
        if (c == '\\') {
            const end = sourceEnd(src, @intCast(i));
            if (end > offset) return null;
            i = end;
            continue;
        }
        i += 1;
    }
    if (math) return null;
    var first: std.ArrayList(u8) = .empty;
    try first.appendSlice(a, src[0..offset]);
    for (open.items) |_| try first.append(a, '}');
    var second: std.ArrayList(u8) = .empty;
    for (open.items) |o| try second.appendSlice(a, o);
    try second.appendSlice(a, src[offset..]);
    return .{ first.items, second.items };
}

/// The math region of legend `src` holding byte `at`: what lies between a
/// pair of dollars (its ends included, so a caret just inside either
/// dollar is in it). Null in text. A math region still open at the end
/// runs to it.
pub fn mathAt(src: []const u8, at: usize) ?[2]u32 {
    var i: usize = 0;
    var open: ?usize = null;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '$') {
            if (open) |o| {
                if (at >= o and at <= i) return .{ @intCast(o), @intCast(i) };
                open = null;
            } else open = i + 1;
        }
        i += 1;
    }
    if (open) |o| if (at >= o) return .{ @intCast(o), @intCast(src.len) };
    return null;
}

/// The anchor points of equation `src` (all math): where each field of
/// its structures starts (just inside its brace, or at an empty one): a
/// fraction's parts, a root's body and index, an accent's body, a script,
/// a limit, in source order. Allocated from `a`.
pub fn slots(a: Allocator, src: []const u8) Allocator.Error![]u32 {
    const p = try parse(a, src, true);
    var out: std.ArrayList(u32) = .empty;
    for (p.e.nodes.items, 0..) |n, k| {
        if (!n.live or !n.kind.isStructure()) continue;
        const id: Id = @enumFromInt(k);
        for (n.kind.slots()) |sl| {
            const row = p.e.slot(id, sl);
            if (row == .none) continue;
            const sp = p.spans.get(row);
            if (sp.start == glyphic.entry.Span.none.start) continue;
            try out.append(a, sp.start);
        }
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    var w: usize = 0;
    for (out.items) |x| {
        if (w > 0 and out.items[w - 1] == x) continue;
        out.items[w] = x;
        w += 1;
    }
    return out.items[0..w];
}

/// Plain `text` as markup that reads back as it (see `rt.escape`).
pub fn escape(a: Allocator, text: []const u8) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    rt.escape(&w.writer, text) catch return error.OutOfMemory;
    return w.written();
}

// Emphasis: bold and italic over a range ------------------------------------
//
// A run's text may be tagged bold or italic: \textbf{…} and \textit{…} (or
// \emph{…}) in its source. To tag a range, or take a tag off it, the
// source is read as a list of atoms, each a character (or a piece kept
// whole: math between dollars, an escape, a command and what it holds)
// with the groups open around it; the atoms in the range have the group
// added or taken out; and the source is written again, opening and
// closing groups only where what is open changes. So the text reads as
// it did, but for the change; empty groups go, and groups of one kind
// side by side become one.

pub const Emphasis = enum {
    bold,
    italic,

    fn opener(e: Emphasis) []const u8 {
        return switch (e) {
            .bold => "\\textbf{",
            .italic => "\\textit{",
        };
    }

    /// Whether group opener `o` gives this emphasis.
    fn given(e: Emphasis, o: []const u8) bool {
        return switch (e) {
            .bold => std.mem.eql(u8, o, "\\textbf{"),
            .italic => std.mem.eql(u8, o, "\\textit{") or std.mem.eql(u8, o, "\\emph{"),
        };
    }
};

/// A piece of a legend's source with the groups open around it (their
/// openers, outermost first). A caret (`start` = `end`, `caret`) is a
/// place, not a piece.
const Atom = struct {
    start: u32,
    end: u32,
    open: []const []const u8,
    caret: bool = false,
};

const Atoms = struct {
    atoms: []Atom,
    /// Where an emphasis group's opener starts and where its closing brace
    /// is: the places either side of a change of emphasis.
    edges: []u32,
};

/// Where the group opened by the `{` at `at` closes (its `}`), past
/// escapes; the end when it does not.
fn groupEnd(src: []const u8, at: usize) usize {
    var level: usize = 0;
    var i = at;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\\' => i += 1,
            '{' => level += 1,
            '}' => {
                level -= 1;
                if (level == 0) return i;
            },
            else => {},
        }
    }
    return src.len;
}

fn atomsOf(a: Allocator, src: []const u8) Allocator.Error!Atoms {
    var out: std.ArrayList(Atom) = .empty;
    var edges: std.ArrayList(u32) = .empty;
    var open: std.ArrayList([]const u8) = .empty;
    // Where each open group's opener started.
    var starts: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        const here = try a.dupe([]const u8, open.items);
        const opened = for (openers) |o| {
            if (std.mem.startsWith(u8, src[i..], o)) break o;
        } else null;
        if (opened) |o| {
            try open.append(a, o);
            try starts.append(a, @intCast(i));
            if (o.len > 1) try edges.append(a, @intCast(i));
            i += o.len;
            continue;
        }
        if (c == '}' and open.items.len > 0) {
            const o = open.pop().?;
            _ = starts.pop();
            if (o.len > 1) try edges.append(a, @intCast(i));
            i += 1;
            continue;
        }
        var end: usize = i + 1;
        if (c == '$') {
            // Math, kept whole: to its closing dollar (or the end).
            const two = i + 1 < src.len and src[i + 1] == '$';
            const close = if (two) "$$" else "$";
            var j = i + close.len;
            end = src.len;
            while (j < src.len) : (j += 1) {
                if (src[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, src[j..], close)) {
                    end = j + close.len;
                    break;
                }
            }
        } else if (c == '\\') {
            end = sourceEnd(src, @intCast(i));
            // A command with arguments (\set(…){…}, \textsc{…}) is kept
            // whole with them.
            if (end < src.len and src[end] == '(') {
                var level: usize = 0;
                var j = end;
                while (j < src.len) : (j += 1) {
                    if (src[j] == '(') level += 1;
                    if (src[j] == ')') {
                        level -= 1;
                        if (level == 0) break;
                    }
                }
                end = @min(src.len, j + 1);
            }
            while (end < src.len and src[end] == '{') end = @min(src.len, groupEnd(src, end) + 1);
        } else {
            end = sourceEnd(src, @intCast(i));
        }
        try out.append(a, .{ .start = @intCast(i), .end = @intCast(@max(end, i + 1)), .open = here });
        i = @max(end, i + 1);
    }
    return .{ .atoms = out.items, .edges = edges.items };
}

/// The groups open at byte `at` of `src`.
fn openAt(a: Allocator, src: []const u8, at: u32) Allocator.Error![]const []const u8 {
    var open: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var math = false;
    while (i < at and i < src.len) {
        const c = src[i];
        if (c == '$') math = !math;
        if (math or c == '$') {
            i += if (c == '\\') 2 else 1;
            continue;
        }
        const opened = for (openers) |o| {
            if (std.mem.startsWith(u8, src[i..], o)) break o;
        } else null;
        if (opened) |o| {
            if (i + o.len > at) break;
            try open.append(a, o);
            i += o.len;
            continue;
        }
        if (c == '}') {
            if (open.items.len > 0) _ = open.pop();
            i += 1;
            continue;
        }
        i = @max(sourceEnd(src, @intCast(i)), i + 1);
    }
    return open.items;
}

fn has(open: []const []const u8, e: Emphasis) bool {
    for (open) |o| if (e.given(o)) return true;
    return false;
}

/// The places in legend `src` either side of each change of emphasis: an
/// emphasis group's opener's start (just outside it) and its closing
/// brace (just inside it). In order.
pub fn emphasisEdges(a: Allocator, src: []const u8) Allocator.Error![]u32 {
    const e = (try atomsOf(a, src)).edges;
    std.mem.sort(u32, e, {}, std.sort.asc(u32));
    return e;
}

/// Whether text at byte `at` of legend `src` (typed there, say) is set
/// with emphasis `e`.
pub fn emphasisAt(a: Allocator, src: []const u8, at: u32, e: Emphasis) Allocator.Error!bool {
    return has(try openAt(a, src, at), e);
}

/// Whether every character starting in [`from`, `to`) of legend `src` has
/// emphasis `e`; with none there, false.
pub fn emphasisAll(a: Allocator, src: []const u8, from: u32, to: u32, e: Emphasis) Allocator.Error!bool {
    var any = false;
    for ((try atomsOf(a, src)).atoms) |at| {
        if (at.start < from or at.start >= to or src[at.start] == '$') continue;
        if (!has(at.open, e)) return false;
        any = true;
    }
    return any;
}

pub const Emphasized = struct {
    src: []u8,
    /// Where the range now starts and ends (with an empty range: where the
    /// caret goes, inside the groups it set).
    from: u32,
    to: u32,
};

/// Legend `src` with emphasis `e` set (`on`) or taken off the characters
/// starting in [`from`, `to`). An empty range marks the caret: typing
/// there then has the emphasis (or not). Allocated from `a`.
pub fn setEmphasis(a: Allocator, src: []const u8, from: u32, to: u32, e: Emphasis, on: bool) Allocator.Error!Emphasized {
    const parsed = try atomsOf(a, src);
    var atoms: std.ArrayList(Atom) = .empty;
    try atoms.appendSlice(a, parsed.atoms);
    const change = struct {
        fn f(al: Allocator, open: []const []const u8, em: Emphasis, set: bool) Allocator.Error![]const []const u8 {
            if (set) {
                if (has(open, em)) return open;
                const out = try al.alloc([]const u8, open.len + 1);
                @memcpy(out[0..open.len], open);
                out[open.len] = em.opener();
                return out;
            }
            var out: std.ArrayList([]const u8) = .empty;
            for (open) |o| if (!em.given(o)) try out.append(al, o);
            return out.items;
        }
    }.f;
    if (from == to) {
        var k: usize = 0;
        while (k < atoms.items.len and atoms.items[k].start < from) k += 1;
        try atoms.insert(a, k, .{ .start = from, .end = from, .caret = true, .open = try change(a, try openAt(a, src, from), e, on) });
    } else for (atoms.items) |*at| {
        if (at.start >= from and at.start < to) at.open = try change(a, at.open, e, on);
    }
    // Written again: groups opened and closed where what is open changes.
    var out: std.ArrayList(u8) = .empty;
    var cur: []const []const u8 = &.{};
    var r_from: ?u32 = null;
    var r_to: u32 = 0;
    for (atoms.items) |at| {
        var common: usize = 0;
        while (common < cur.len and common < at.open.len and std.mem.eql(u8, cur[common], at.open[common])) common += 1;
        for (cur[common..]) |_| try out.append(a, '}');
        for (at.open[common..]) |o| try out.appendSlice(a, o);
        cur = at.open;
        const in = if (from == to) at.caret else at.start >= from and at.start < to;
        if (in and r_from == null) r_from = @intCast(out.items.len);
        try out.appendSlice(a, src[at.start..at.end]);
        if (in) r_to = @intCast(out.items.len);
    }
    for (cur) |_| try out.append(a, '}');
    const f = r_from orelse @as(u32, @intCast(out.items.len));
    return .{ .src = out.items, .from = f, .to = @max(f, r_to) };
}

/// The characters starting in [`from`, `to`) of legend `src` as markup
/// that reads as they do there: with the emphasis groups open around them
/// (for copying with emphasis). Allocated from `a`.
pub fn slice(a: Allocator, src: []const u8, from: u32, to: u32) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var cur: []const []const u8 = &.{};
    for ((try atomsOf(a, src)).atoms) |at| {
        if (at.start < from or at.start >= to) continue;
        var common: usize = 0;
        while (common < cur.len and common < at.open.len and std.mem.eql(u8, cur[common], at.open[common])) common += 1;
        for (cur[common..]) |_| try out.append(a, '}');
        for (at.open[common..]) |o| try out.appendSlice(a, o);
        cur = at.open;
        try out.appendSlice(a, src[at.start..at.end]);
    }
    for (cur) |_| try out.append(a, '}');
    return out.items;
}

// Letter case --------------------------------------------------------------

pub const Case = enum { upper, lower, title };

/// `cp` in upper or lower case: ASCII, Latin-1, Latin Extended-A, Greek and
/// Cyrillic by their regular offsets; anything else as it is.
fn caseOf(cp: u21, upper: bool) u21 {
    if (upper) {
        return switch (cp) {
            'a'...'z' => cp - 32,
            0xE0...0xFE => if (cp == 0xF7) cp else cp - 32,
            0x100...0x17F => if (cp % 2 == 1 and cp != 0x131 and cp != 0x138 and cp != 0x149 and !(cp >= 0x139 and cp <= 0x148) and !(cp >= 0x179)) cp - 1 else if ((cp >= 0x139 and cp <= 0x148) or cp >= 0x179) (if (cp % 2 == 0) cp - 1 else cp) else cp,
            0x3B1...0x3C9 => if (cp == 0x3C2) 0x3A3 else cp - 32,
            0x430...0x44F => cp - 32,
            0x450...0x45F => cp - 80,
            else => cp,
        };
    }
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xDE => if (cp == 0xD7) cp else cp + 32,
        0x100...0x17F => if (cp % 2 == 0 and cp != 0x130 and cp != 0x138 and !(cp >= 0x139 and cp <= 0x148) and !(cp >= 0x179)) cp + 1 else if ((cp >= 0x139 and cp <= 0x148) or cp >= 0x179) (if (cp % 2 == 1 and cp != 0x149 and cp != 0x17F) cp + 1 else cp) else cp,
        0x391...0x3A9 => if (cp == 0x3A2) cp else cp + 32,
        0x410...0x42F => cp + 32,
        0x400...0x40F => cp + 80,
        else => cp,
    };
}

fn isLetter(cp: u21) bool {
    return caseOf(cp, true) != cp or caseOf(cp, false) != cp;
}

/// Legend `src` with the plain characters starting in [`from`, `to`) put
/// in upper case, lower case, or title case (a word's first letter upper,
/// the rest lower). Escapes, commands and math are left as they are.
/// Returns the source and where the range now ends. Allocated from `a`.
pub fn changeCase(a: Allocator, src: []const u8, from: u32, to: u32, how: Case) Allocator.Error!struct { src: []u8, to: u32 } {
    const cs = try chars(a, src, false);
    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;
    var new_to: ?u32 = null;
    var after_letter = false;
    for (cs) |c| {
        const s = src[c.start..c.end];
        const plain = s.len > 0 and s[0] != '\\' and mathAt(src, c.start) == null;
        const cp: ?u21 = if (plain) std.unicode.utf8Decode(s) catch null else null;
        if (c.start >= to and new_to == null) new_to = @intCast(out.items.len + (c.start - at));
        if (c.start >= from and c.start < to and cp != null and c.start >= at) {
            const upper = switch (how) {
                .upper => true,
                .lower => false,
                .title => !after_letter,
            };
            const mapped = caseOf(cp.?, upper);
            try out.appendSlice(a, src[at..c.start]);
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(mapped, &buf) catch 0;
            try out.appendSlice(a, if (n > 0) buf[0..n] else s);
            at = c.end;
        }
        after_letter = if (cp) |p| isLetter(p) or (p >= '0' and p <= '9') or p == '\'' else plain;
    }
    try out.appendSlice(a, src[@min(at, src.len)..]);
    const tail: u32 = @intCast(src.len - @min(src.len, @max(to, at)));
    const t = new_to orelse @as(u32, @intCast(out.items.len)) - tail;
    return .{ .src = out.items, .to = @min(t, @as(u32, @intCast(out.items.len))) };
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "characters map to their source bytes, escapes and commands apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try chars(a, "a\\%\\textbf{b}c", false);
    try testing.expectEqual(4, cs.len);
    try testing.expectEqual(@as(u32, 1), cs[1].start);
    try testing.expectEqual(@as(u32, 3), cs[1].end);
    try testing.expectEqualStrings("%", cs[1].text);
    try testing.expectEqualStrings("b", cs[2].text);
    try testing.expectEqual(@as(u32, 11), cs[2].start);
}

test "deleting removes characters only, leaving commands whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // From inside the bold word to the end: its brace stays.
    try testing.expectEqualStrings("ab \\textbf{c}", try deleteChars(a, "ab \\textbf{cd} ef", 12, 17, false));
    // An escape goes as one character.
    try testing.expectEqualStrings("ab", try deleteChars(a, "a\\%b", 1, 3, false));
    var t: std.ArrayList(u8) = .empty;
    try plainText(a, "a\\%\\textbf{b}c", 0, 14, false, &t);
    try testing.expectEqualStrings("a%bc", t.items);
}

test "a run splits inside bold text into two that read as it did" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = (try splitAt(a, "x \\textbf{ab} y", 11)).?;
    try testing.expectEqualStrings("x \\textbf{a}", parts[0]);
    try testing.expectEqualStrings("\\textbf{b} y", parts[1]);
    // Inside math it does not split.
    try testing.expect(try splitAt(a, "$\\frac{ab}{c}$", 8) == null);
    try testing.expectEqualStrings("a\\{b\\}", try escape(a, "a{b}"));
}

test "an equation's anchor points are its argument slots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // \frac{a}{} : inside each brace; x^2 : at the script.
    const s = try slots(a, "\\frac{a}{}+x^2");
    try testing.expectEqualSlices(u32, &.{ 6, 9, 13 }, s);
    try testing.expectEqual(0, (try slots(a, "plain words")).len);
    // Nested: the root inside the numerator has its own slot.
    try testing.expectEqualSlices(u32, &.{ 6, 12, 15 }, try slots(a, "\\frac{\\sqrt{}}{b}"));
}

test "an equation's characters: leaves, commands as one, structures' fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try chars(a, "\\pi r^{2}", true);
    try testing.expectEqual(3, cs.len);
    try testing.expectEqualStrings("π", cs[0].text);
    try testing.expectEqual(@as(u32, 3), cs[0].end);
    // Deleting the 2 leaves its braces.
    try testing.expectEqualStrings("\\pi r^{}", try deleteChars(a, "\\pi r^{2}", 7, 8, true));
}

test "a legend's math regions: between dollars, ends included; escaped dollars are text" {
    // 0123456789012345
    // Area $\pi r$ \$5
    try testing.expectEqual(@as(?[2]u32, .{ 6, 11 }), mathAt("Area $\\pi r$ \\$5", 7));
    try testing.expectEqual(@as(?[2]u32, .{ 6, 11 }), mathAt("Area $\\pi r$ \\$5", 11));
    try testing.expectEqual(@as(?[2]u32, null), mathAt("Area $\\pi r$ \\$5", 3));
    try testing.expectEqual(@as(?[2]u32, null), mathAt("Area $\\pi r$ \\$5", 13));
    // Still being typed: open to the end.
    try testing.expectEqual(@as(?[2]u32, .{ 3, 5 }), mathAt("a $x^", 5));
}

test "bold set over a range and taken off again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "brown" in "the brown fox" made bold.
    const r = try setEmphasis(a, "the brown fox", 4, 9, .bold, true);
    try testing.expectEqualStrings("the \\textbf{brown} fox", r.src);
    try testing.expectEqualStrings("brown", r.src[r.from..r.to]);
    try testing.expect(try emphasisAll(a, r.src, r.from, r.to, .bold));
    try testing.expect(!try emphasisAll(a, r.src, 0, r.to, .bold));
    // Then off its middle: two groups.
    const r2 = try setEmphasis(a, r.src, r.from + 1, r.from + 4, .bold, false);
    try testing.expectEqualStrings("the \\textbf{b}row\\textbf{n} fox", r2.src);
    // And on over the whole: one group again.
    const r3 = try setEmphasis(a, r2.src, 4, @intCast(r2.src.len), .bold, true);
    try testing.expectEqualStrings("the \\textbf{brown fox}", r3.src);
    // Italic inside bold nests; math is kept whole.
    const r4 = try setEmphasis(a, "a \\textbf{bc} $x^2$ d", 11, 21, .italic, true);
    try testing.expectEqualStrings("a \\textbf{b\\textit{c}}\\textit{ $x^2$ d}", r4.src);
    try testing.expect(try emphasisAll(a, r4.src, r4.from, r4.to, .italic));
    // \emph counts as italic, and comes off.
    const r5 = try setEmphasis(a, "\\emph{word}", 0, 11, .italic, false);
    try testing.expectEqualStrings("word", r5.src);
}

test "emphasis at a caret: an empty group to type into" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try setEmphasis(a, "ab", 1, 1, .bold, true);
    try testing.expectEqualStrings("a\\textbf{}b", r.src);
    try testing.expectEqual(@as(u32, 9), r.from);
    // Inside bold, off: the group closed there and opened again.
    const r2 = try setEmphasis(a, "\\textbf{ab}", 9, 9, .bold, false);
    try testing.expectEqualStrings("\\textbf{a}\\textbf{b}", r2.src);
    try testing.expectEqual(@as(u32, 10), r2.from);
    try testing.expect(try emphasisAt(a, "x\\textbf{ab}", 10, .bold));
    try testing.expect(!try emphasisAt(a, "x\\textbf{ab}", 1, .bold));
    try testing.expectEqualSlices(u32, &.{ 1, 11 }, try emphasisEdges(a, "x\\textbf{ab}y"));
    try testing.expectEqualStrings("\\textbf{b}y", try slice(a, "x\\textbf{ab}y", 10, 13));
}

test "letter case of a range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("the BROWN fox", (try changeCase(a, "the brown fox", 4, 9, .upper)).src);
    try testing.expectEqualStrings("The Brown Fox", (try changeCase(a, "the bROWN fox", 0, 13, .title)).src);
    try testing.expectEqualStrings("\\textbf{ÉTÉ} \\% $x$", (try changeCase(a, "\\textbf{été} \\% $x$", 0, 20, .upper)).src);
    try testing.expectEqualStrings("αβγ", (try changeCase(a, "ΑΒΓ", 0, 6, .lower)).src);
}
