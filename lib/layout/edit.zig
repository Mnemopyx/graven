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
