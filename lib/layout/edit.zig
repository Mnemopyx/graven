//! Editing the markup of a run in place, character by character, without
//! breaking it.
//!
//! A run is markup: text with commands (\textbf{…}, \frac{…}{…}, escapes
//! such as \%). Editing works on its characters, as the parse finds them:
//! each character of the text (and each explicit space or break) has a
//! range of source bytes. Deleting removes only those bytes, so commands,
//! braces and arguments stay whole (an emptied \textbf{} is harmless).
//! Splitting a run in two closes the variant groups open at the split in
//! the first part and opens them again in the second.

const std = @import("std");
const engine = @import("graven_engine");
const rt = @import("graven_richtext");

const Allocator = std.mem.Allocator;
const markup = engine.markup;

/// One character of a run's markup: its source bytes, and what it reads as
/// (for copying as plain text).
pub const Char = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

/// The characters of markup `src`, in source order. Allocated from `a`.
pub fn chars(a: Allocator, src: []const u8) Allocator.Error![]Char {
    var problems: std.ArrayList(markup.Diagnostic) = .empty;
    const root = try markup.parsePreview(a, src, &engine.entities.Table.builtin, &problems);
    var out: std.ArrayList(Char) = .empty;
    for (root.items) |n| try walk(a, src, n, &out);
    std.mem.sort(Char, out.items, {}, struct {
        fn lt(_: void, x: Char, y: Char) bool {
            return x.start < y.start;
        }
    }.lt);
    return out.items;
}

fn walk(a: Allocator, src: []const u8, n: markup.Node, out: *std.ArrayList(Char)) Allocator.Error!void {
    switch (n) {
        .text => |t| {
            // Faint text is source shown literally while it is not valid
            // markup: its bytes are characters as they stand.
            var i: usize = 0;
            while (i < t.utf8.len) {
                const len = std.unicode.utf8ByteSequenceLength(t.utf8[i]) catch 1;
                const next = @min(i + len, t.utf8.len);
                const start = t.source[i];
                const end = if (next < t.utf8.len and t.source[next] > start) t.source[next] else sourceEnd(src, start);
                if (end > start) try out.append(a, .{ .start = start, .end = end, .text = t.utf8[i..next] });
                i = next;
            }
        },
        .group => |g| for (g.items) |it| try walk(a, src, it, out),
        .scripts => |s| {
            try walk(a, src, s.base.*, out);
            if (s.sup) |x| try walk(a, src, x.*, out);
            if (s.sub) |x| try walk(a, src, x.*, out);
        },
        .accent => |x| try walk(a, src, x.body.*, out),
        .radical => |x| try walk(a, src, x.body.*, out),
        .fraction => |x| {
            try walk(a, src, x.num.*, out);
            try walk(a, src, x.den.*, out);
        },
        .space => |x| try out.append(a, .{ .start = x.span.start, .end = x.span.end, .text = " " }),
        .line_break => |x| try out.append(a, .{ .start = x.span.start, .end = x.span.end, .text = if (x.kind == .hard) "\n" else "" }),
        .placeholder => {},
    }
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
pub fn deleteChars(a: Allocator, src: []const u8, from: u32, to: u32) Allocator.Error![]u8 {
    const cs = try chars(a, src);
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
pub fn charBefore(a: Allocator, src: []const u8, offset: u32) Allocator.Error!?u32 {
    var best: ?u32 = null;
    for (try chars(a, src)) |c| {
        if (c.start < offset) best = c.start else break;
    }
    return best;
}

/// Where the character at byte `offset` (or the next after it) ends: the
/// end of the run's text when there is none.
pub fn charAfter(a: Allocator, src: []const u8, offset: u32) Allocator.Error!?u32 {
    for (try chars(a, src)) |c| {
        if (c.start >= offset) return c.end;
    }
    return null;
}

/// Whether `src` has any characters at all.
pub fn hasChars(a: Allocator, src: []const u8) Allocator.Error!bool {
    return (try chars(a, src)).len > 0;
}

/// What the characters starting in [`from`, `to`) of `src` read as, as
/// plain text, appended to `out`.
pub fn plainText(a: Allocator, src: []const u8, from: u32, to: u32, out: *std.ArrayList(u8)) Allocator.Error!void {
    for (try chars(a, src)) |c| {
        if (c.start >= from and c.start < to) try out.appendSlice(a, c.text);
    }
}

/// `src` split at byte `offset` into two runs that read as it did: the
/// variant groups (\textbf{…}, braces) open there are closed in the first
/// and opened again in the second. Null where it cannot be split, inside
/// an equation's structure (a fraction, a root, scripts, an accent).
pub fn splitAt(a: Allocator, src: []const u8, offset: u32) Allocator.Error!?[2][]u8 {
    var problems: std.ArrayList(markup.Diagnostic) = .empty;
    const root = try markup.parsePreview(a, src, &engine.entities.Table.builtin, &problems);
    var openers: std.ArrayList([]const u8) = .empty;
    var items: []const markup.Node = root.items;
    outer: while (true) {
        for (items) |n| {
            const sp = n.span();
            if (!(sp.start < offset and offset < sp.end)) continue;
            switch (n) {
                .text, .space, .line_break, .placeholder => break :outer,
                .group => |g| {
                    // Its opening: up to its first item, or its brace.
                    const inner = if (g.items.len > 0) g.items[0].span().start else (std.mem.indexOfScalarPos(u8, src, sp.start, '{') orelse sp.start) + 1;
                    if (inner > offset or src[sp.end - 1] != '}') return null;
                    // The command it belongs to (\textbf), before its brace.
                    var open = sp.start;
                    if (src[open] == '{') {
                        var b = open;
                        while (b > 0 and std.ascii.isAlphabetic(src[b - 1])) b -= 1;
                        if (b > 0 and b < open and src[b - 1] == '\\') open = b - 1;
                    }
                    try openers.append(a, src[open..inner]);
                    items = g.items;
                    continue :outer;
                },
                else => return null,
            }
        }
        break;
    }
    var first: std.ArrayList(u8) = .empty;
    try first.appendSlice(a, src[0..offset]);
    for (openers.items) |_| try first.append(a, '}');
    var second: std.ArrayList(u8) = .empty;
    for (openers.items) |o| try second.appendSlice(a, o);
    try second.appendSlice(a, src[offset..]);
    return .{ first.items, second.items };
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
    const cs = try chars(a, "a\\%\\textbf{b}c");
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
    try testing.expectEqualStrings("ab \\textbf{c}", try deleteChars(a, "ab \\textbf{cd} ef", 12, 17));
    // An escape goes as one character.
    try testing.expectEqualStrings("ab", try deleteChars(a, "a\\%b", 1, 3));
    var t: std.ArrayList(u8) = .empty;
    try plainText(a, "a\\%\\textbf{b}c", 0, 14, &t);
    try testing.expectEqualStrings("a%bc", t.items);
}

test "a run splits inside bold text into two that read as it did" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = (try splitAt(a, "x \\textbf{ab} y", 11)).?;
    try testing.expectEqualStrings("x \\textbf{a}", parts[0]);
    try testing.expectEqualStrings("\\textbf{b} y", parts[1]);
    // Inside a fraction it does not split.
    try testing.expect(try splitAt(a, "\\frac{ab}{c}", 7) == null);
    try testing.expectEqualStrings("a\\{b\\}", try escape(a, "a{b}"));
}
