//! A TOML subset for Graven's config files: read, changed key by key, and
//! written back.
//!
//! Read: comments, `[table]` headers, bare and quoted keys, dotted keys,
//! basic ("…" with escapes) and literal ('…') strings, integers (decimal,
//! 0x, 0o, 0b, with _ separators), floats (inf and nan too), booleans,
//! arrays of values (across lines, with a trailing comma), and inline
//! tables, which are read as dotted keys. Not read, and reported as such:
//! multi-line strings, dates and times, and arrays of tables.
//!
//! A document is its keys in order, each a full dotted path with its
//! value. Writing groups them by table, root keys first. Comments and
//! layout are not kept: a file Graven rewrites is regenerated, with every
//! key it held, known to Graven or not.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const Value,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .integer => |i| i == b.integer,
            .float => |f| f == b.float or (std.math.isNan(f) and std.math.isNan(b.float)),
            .boolean => |x| x == b.boolean,
            .array => |xs| xs.len == b.array.len and for (xs, b.array) |x, y| {
                if (!x.eql(y)) break false;
            } else true,
        };
    }
};

pub const Entry = struct {
    /// The full dotted path, each part as written in the file, unquoted.
    key: []const u8,
    value: Value,
};

/// Where a parse failed, and why.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = Allocator.Error || error{Invalid};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) Doc {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(d: *Doc) void {
        d.arena.deinit();
        d.* = undefined;
    }

    pub fn get(d: *const Doc, key: []const u8) ?Value {
        for (d.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    pub fn has(d: *const Doc, key: []const u8) bool {
        return d.get(key) != null;
    }

    /// Sets `key` (a dotted path) to `value`, copied: in place when it is
    /// there, else at the end.
    pub fn set(d: *Doc, key: []const u8, value: Value) Allocator.Error!void {
        const a = d.arena.allocator();
        const v = try dupeValue(a, value);
        for (d.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) {
            e.value = v;
            return;
        };
        try d.entries.append(a, .{ .key = try a.dupe(u8, key), .value = v });
    }

    /// Writes the document: its root keys, then each table's keys under
    /// its header, tables in the order their first key appears.
    pub fn write(d: *const Doc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var any_root = false;
        for (d.entries.items) |e| if (tableOf(e.key).len == 0) {
            try writeKey(w, e.key);
            try w.writeAll(" = ");
            try writeValue(w, e.value);
            try w.writeAll("\n");
            any_root = true;
        };
        var first = !any_root;
        for (d.entries.items, 0..) |e, i| {
            const t = tableOf(e.key);
            if (t.len == 0) continue;
            // Each table once, where its first key is.
            const seen = for (d.entries.items[0..i]) |prev| {
                if (std.mem.eql(u8, tableOf(prev.key), t)) break true;
            } else false;
            if (seen) continue;
            if (!first) try w.writeAll("\n");
            first = false;
            try w.writeAll("[");
            try writeKey(w, t);
            try w.writeAll("]\n");
            for (d.entries.items[i..]) |f| {
                if (!std.mem.eql(u8, tableOf(f.key), t)) continue;
                try writeKey(w, f.key[t.len + 1 ..]);
                try w.writeAll(" = ");
                try writeValue(w, f.value);
                try w.writeAll("\n");
            }
        }
    }

    /// The document as text, allocated from `gpa`.
    pub fn toText(d: *const Doc, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        d.write(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

/// The table part of a dotted path: everything before its last part.
fn tableOf(key: []const u8) []const u8 {
    var i = key.len;
    var in_quote = false;
    // Scan from the start so quoted parts with dots are skipped.
    var last: ?usize = null;
    i = 0;
    while (i < key.len) : (i += 1) {
        if (key[i] == '"') in_quote = !in_quote else if (key[i] == '.' and !in_quote) last = i;
    }
    return if (last) |l| key[0..l] else "";
}

fn dupeValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |xs| blk: {
            const out = try a.alloc(Value, xs.len);
            for (xs, out) |x, *o| o.* = try dupeValue(a, x);
            break :blk .{ .array = out };
        },
        else => v,
    };
}

fn bareChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// A dotted path written back: bare parts as they are, others quoted.
/// Parts are stored as written, so a part holding a dot was quoted.
fn writeKey(w: *std.Io.Writer, key: []const u8) !void {
    var parts = splitKey(key);
    var first = true;
    while (parts.next()) |p| {
        if (!first) try w.writeAll(".");
        first = false;
        const bare = p.len > 0 and for (p) |c| {
            if (!bareChar(c)) break false;
        } else true;
        if (bare) try w.writeAll(p) else try writeString(w, p);
    }
}

/// Splits a stored dotted path into its parts (a part with a dot in it is
/// stored quoted).
const KeyParts = struct {
    key: []const u8,
    i: usize = 0,

    fn next(k: *KeyParts) ?[]const u8 {
        if (k.i > k.key.len) return null;
        if (k.i < k.key.len and k.key[k.i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, k.key, k.i + 1, '"') orelse k.key.len;
            const part = k.key[k.i + 1 .. end];
            k.i = end + 2;
            return part;
        }
        const end = std.mem.indexOfScalarPos(u8, k.key, k.i, '.') orelse k.key.len;
        const part = k.key[k.i..end];
        k.i = end + 1;
        return part;
    }
};

fn splitKey(key: []const u8) KeyParts {
    return .{ .key = key };
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...31, 127 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

fn writeValue(w: *std.Io.Writer, v: Value) !void {
    switch (v) {
        .string => |s| try writeString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) return w.writeAll("nan");
            if (std.math.isInf(f)) return w.writeAll(if (f > 0) "inf" else "-inf");
            var buf: [64]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try w.writeAll(t);
            // A float keeps its point, so it reads back as one.
            if (std.mem.indexOfAny(u8, t, ".eE") == null) try w.writeAll(".0");
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .array => |xs| {
            try w.writeAll("[");
            for (xs, 0..) |x, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValue(w, x);
            }
            try w.writeAll("]");
        },
    }
}

// Parsing --------------------------------------------------------------------

/// Reads `text` into a new document. On failure, `diag` (if given) says
/// on which line and why.
pub fn parse(gpa: Allocator, text: []const u8, diag: ?*Diagnostic) ParseError!Doc {
    var d: Doc = .init(gpa);
    errdefer d.deinit();
    var p: Parser = .{ .text = text, .doc = &d, .a = d.arena.allocator() };
    p.run() catch |err| {
        if (diag) |dg| dg.* = .{ .line = p.line, .message = p.message };
        return err;
    };
    return d;
}

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    line: usize = 1,
    doc: *Doc,
    a: Allocator,
    table: []const u8 = "",
    /// Explicitly opened tables, so one opened twice is caught.
    tables: std.ArrayList([]const u8) = .empty,
    message: []const u8 = "",

    fn fail(p: *Parser, message: []const u8) error{Invalid} {
        p.message = message;
        return error.Invalid;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.text.len) p.text[p.i] else null;
    }

    fn skipSpace(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.i += 1;
        }
    }

    /// Skips spaces, comments and newlines (inside arrays).
    fn skipBlank(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                p.i += 1;
            } else if (c == '\n') {
                p.i += 1;
                p.line += 1;
            } else if (c == '#') {
                while (p.peek()) |x| {
                    if (x == '\n') break;
                    p.i += 1;
                }
            } else break;
        }
    }

    /// The rest of the line must be blank or a comment.
    fn endLine(p: *Parser) ParseError!void {
        p.skipSpace();
        if (p.peek()) |c| {
            if (c == '#') {
                while (p.peek()) |x| {
                    if (x == '\n') break;
                    p.i += 1;
                }
            } else if (c != '\n' and c != '\r') return p.fail("unexpected text after a value");
        }
    }

    fn run(p: *Parser) ParseError!void {
        while (true) {
            p.skipBlank();
            const c = p.peek() orelse return;
            if (c == '[') {
                p.i += 1;
                if (p.peek() == '[') return p.fail("arrays of tables are not supported");
                p.skipSpace();
                const t = try p.key();
                p.skipSpace();
                if (p.peek() != ']') return p.fail("expected ] after a table name");
                p.i += 1;
                for (p.tables.items) |seen| if (std.mem.eql(u8, seen, t)) return p.fail("a table is defined twice");
                try p.tables.append(p.a, t);
                p.table = t;
                try p.endLine();
            } else {
                const k = try p.key();
                p.skipSpace();
                if (p.peek() != '=') return p.fail("expected = after a key");
                p.i += 1;
                p.skipSpace();
                const full = if (p.table.len == 0) k else try std.fmt.allocPrint(p.a, "{s}.{s}", .{ p.table, k });
                try p.valueInto(full);
                try p.endLine();
            }
        }
    }

    /// Stores `full = value`, flattening an inline table into dotted keys.
    fn valueInto(p: *Parser, full: []const u8) ParseError!void {
        if (p.peek() == '{') {
            p.i += 1;
            p.skipSpace();
            if (p.peek() == '}') {
                p.i += 1;
                return;
            }
            while (true) {
                p.skipSpace();
                const k = try p.key();
                p.skipSpace();
                if (p.peek() != '=') return p.fail("expected = in an inline table");
                p.i += 1;
                p.skipSpace();
                try p.valueInto(try std.fmt.allocPrint(p.a, "{s}.{s}", .{ full, k }));
                p.skipSpace();
                const c = p.peek() orelse return p.fail("an inline table is not closed");
                p.i += 1;
                if (c == '}') return;
                if (c != ',') return p.fail("expected , or } in an inline table");
            }
        }
        const v = try p.value();
        if (p.doc.has(full)) return p.fail("a key is defined twice");
        try p.doc.entries.append(p.a, .{ .key = full, .value = v });
    }

    /// A key, possibly dotted, stored with bare parts as they are and
    /// parts needing quotes quoted.
    fn key(p: *Parser) ParseError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            p.skipSpace();
            const c = p.peek() orelse return p.fail("expected a key");
            var part: []const u8 = undefined;
            if (c == '"' or c == '\'') {
                part = try p.string();
            } else {
                const start = p.i;
                while (p.peek()) |x| {
                    if (!bareChar(x)) break;
                    p.i += 1;
                }
                if (p.i == start) return p.fail("expected a key");
                part = p.text[start..p.i];
            }
            if (out.items.len > 0) try out.append(p.a, '.');
            const needs_quote = part.len == 0 or for (part) |x| {
                if (!bareChar(x)) break true;
            } else false;
            if (needs_quote) {
                if (std.mem.indexOfScalar(u8, part, '"') != null) return p.fail("a key may not hold a double quote");
                try out.append(p.a, '"');
                try out.appendSlice(p.a, part);
                try out.append(p.a, '"');
            } else try out.appendSlice(p.a, part);
            p.skipSpace();
            if (p.peek() != '.') break;
            p.i += 1;
        }
        return out.items;
    }

    fn value(p: *Parser) ParseError!Value {
        const c = p.peek() orelse return p.fail("expected a value");
        switch (c) {
            '"', '\'' => return .{ .string = try p.string() },
            '[' => {
                p.i += 1;
                var items: std.ArrayList(Value) = .empty;
                while (true) {
                    p.skipBlank();
                    if (p.peek() == ']') {
                        p.i += 1;
                        break;
                    }
                    try items.append(p.a, try p.value());
                    p.skipBlank();
                    const x = p.peek() orelse return p.fail("an array is not closed");
                    if (x == ',') {
                        p.i += 1;
                    } else if (x != ']') return p.fail("expected , or ] in an array");
                }
                return .{ .array = items.items };
            },
            '{' => return p.fail("an inline table belongs directly after a key"),
            else => {},
        }
        const start = p.i;
        while (p.peek()) |x| {
            if (x == ' ' or x == '\t' or x == '\r' or x == '\n' or x == ',' or x == ']' or x == '}' or x == '#') break;
            p.i += 1;
        }
        const t = p.text[start..p.i];
        if (std.mem.eql(u8, t, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, t, "false")) return .{ .boolean = false };
        return p.number(t);
    }

    fn number(p: *Parser, t: []const u8) ParseError!Value {
        if (t.len == 0) return p.fail("expected a value");
        // Dates and times look like numbers with - and :.
        if (std.mem.indexOfScalar(u8, t, ':') != null or (t.len >= 10 and t[4] == '-' and std.ascii.isDigit(t[0]))) return p.fail("dates and times are not supported");
        var clean: std.ArrayList(u8) = .empty;
        for (t, 0..) |c, i| {
            if (c == '_') {
                const ok = i > 0 and i + 1 < t.len and std.ascii.isAlphanumeric(t[i - 1]) and std.ascii.isAlphanumeric(t[i + 1]);
                if (!ok) return p.fail("a _ in a number must sit between digits");
                continue;
            }
            try clean.append(p.a, c);
        }
        const s = clean.items;
        const body = if (s[0] == '+' or s[0] == '-') s[1..] else s;
        const neg = s[0] == '-';
        if (std.mem.eql(u8, body, "inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        if (std.mem.eql(u8, body, "nan")) return .{ .float = std.math.nan(f64) };
        if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'o' or body[1] == 'b')) {
            if (s.len != body.len) return p.fail("a hex, octal or binary number takes no sign");
            const base: u8 = switch (body[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            return .{ .integer = std.fmt.parseInt(i64, body[2..], base) catch return p.fail("not a number") };
        }
        if (body.len > 1 and body[0] == '0' and std.ascii.isDigit(body[1])) return p.fail("a number may not start with 0");
        if (std.mem.indexOfAny(u8, body, ".eE") != null) {
            return .{ .float = std.fmt.parseFloat(f64, s) catch return p.fail("not a number") };
        }
        return .{ .integer = std.fmt.parseInt(i64, s, 10) catch return p.fail("not a number") };
    }

    /// A basic or literal string on one line.
    fn string(p: *Parser) ParseError![]const u8 {
        const q = p.peek().?;
        if (p.i + 2 < p.text.len and p.text[p.i + 1] == q and p.text[p.i + 2] == q) return p.fail("multi-line strings are not supported");
        p.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("a string is not closed");
            if (c == '\n') return p.fail("a string is not closed on its line");
            p.i += 1;
            if (c == q) break;
            if (c != '\\' or q == '\'') {
                try out.append(p.a, c);
                continue;
            }
            const e = p.peek() orelse return p.fail("a string is not closed");
            p.i += 1;
            switch (e) {
                'b' => try out.append(p.a, 8),
                't' => try out.append(p.a, '\t'),
                'n' => try out.append(p.a, '\n'),
                'f' => try out.append(p.a, 12),
                'r' => try out.append(p.a, '\r'),
                '"' => try out.append(p.a, '"'),
                '\\' => try out.append(p.a, '\\'),
                'u', 'U' => {
                    const n: usize = if (e == 'u') 4 else 8;
                    if (p.i + n > p.text.len) return p.fail("a \\u escape is cut short");
                    const cp = std.fmt.parseInt(u21, p.text[p.i .. p.i + n], 16) catch return p.fail("a \\u escape is not hex");
                    p.i += n;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return p.fail("a \\u escape is not a character");
                    try out.appendSlice(p.a, buf[0..len]);
                },
                else => return p.fail("an unknown escape in a string"),
            }
        }
        return out.items;
    }
};

const testing = std.testing;

test "reads tables, dotted and quoted keys, inline tables and every value kind" {
    const text =
        \\# Graven settings
        \\title = "Graven \"test\" \u00e9"
        \\path = 'C:\no\escapes'
        \\[canvas]
        \\units = "mm"   # the default
        \\scale = 1_000
        \\hex = 0xff
        \\ratio = 2.5e-1
        \\on = true
        \\list = [1, 2,
        \\  3, ] # trailing comma
        \\[panes.tree]
        \\mode = "ghost"
        \\size = { w = 240, h = 600 }
        \\"odd key.with dot" = -inf
    ;
    var diag: Diagnostic = .{};
    var d = try parse(testing.allocator, text, &diag);
    defer d.deinit();
    try testing.expectEqualStrings("Graven \"test\" é", d.get("title").?.string);
    try testing.expectEqualStrings("C:\\no\\escapes", d.get("path").?.string);
    try testing.expectEqualStrings("mm", d.get("canvas.units").?.string);
    try testing.expectEqual(1000, d.get("canvas.scale").?.integer);
    try testing.expectEqual(255, d.get("canvas.hex").?.integer);
    try testing.expectEqual(0.25, d.get("canvas.ratio").?.float);
    try testing.expect(d.get("canvas.on").?.boolean);
    try testing.expectEqual(3, d.get("canvas.list").?.array.len);
    try testing.expectEqualStrings("ghost", d.get("panes.tree.mode").?.string);
    try testing.expectEqual(240, d.get("panes.tree.size.w").?.integer);
    try testing.expect(std.math.isInf(d.get("panes.tree.\"odd key.with dot\"").?.float));
}

test "writes back what it read, grouped by table, and reads the same again" {
    const text =
        \\top = 1
        \\[a]
        \\x = "one"
        \\[b.c]
        \\y = 2.0
        \\z = [true, false]
        \\[a.d]
        \\w = 'q'
    ;
    var d = try parse(testing.allocator, text, null);
    defer d.deinit();
    try d.set("a.new", .{ .integer = 7 });
    try d.set("top", .{ .string = "changed" });
    const out = try d.toText(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\top = "changed"
        \\
        \\[a]
        \\x = "one"
        \\new = 7
        \\
        \\[b.c]
        \\y = 2.0
        \\z = [true, false]
        \\
        \\[a.d]
        \\w = "q"
        \\
    , out);
    var again = try parse(testing.allocator, out, null);
    defer again.deinit();
    try testing.expectEqual(d.entries.items.len, again.entries.items.len);
    for (d.entries.items) |x| try testing.expect(x.value.eql(again.get(x.key).?));
}

test "what it cannot read is reported with its line" {
    const cases = [_]struct { text: []const u8, line: usize }{
        .{ .text = "a = 1\nb = \n", .line = 2 },
        .{ .text = "a = 1\na = 2\n", .line = 2 },
        .{ .text = "[t]\n[t]\n", .line = 2 },
        .{ .text = "[[items]]\n", .line = 1 },
        .{ .text = "d = 1979-05-27\n", .line = 1 },
        .{ .text = "s = \"\"\"long\"\"\"\n", .line = 1 },
        .{ .text = "\n\nx = \"open\n", .line = 3 },
        .{ .text = "n = 012\n", .line = 1 },
        .{ .text = "k = 1 2\n", .line = 1 },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.Invalid, parse(testing.allocator, c.text, &diag));
        try testing.expectEqual(c.line, diag.line);
        try testing.expect(diag.message.len > 0);
    }
}
