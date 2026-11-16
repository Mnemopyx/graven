//! What the entry syntaxes (latex.zig, typst.zig) share: source spans,
//! attaching scripts, deciding operators' roles, and comparing trees.
//!
//! Parsers never fail: every prefix of an expression parses to a whole
//! tree, a missing argument left as an empty row (a hole), an unclosed
//! group closed at the end, a command still being typed kept as upright
//! text. So typing builds the expression greedily, rendered as it goes.

const std = @import("std");
const ex = @import("expr.zig");
const param = @import("param.zig");

const Allocator = std.mem.Allocator;
const Expr = ex.Expr;
const Id = ex.Id;
const Kind = ex.Kind;
const Slot = ex.Slot;

/// Which bytes of the source made an object.
pub const Span = struct {
    start: u32,
    end: u32,
    pub const none: Span = .{ .start = std.math.maxInt(u32), .end = 0 };
};

/// Spans by object, alongside an expression's nodes.
pub const Spans = struct {
    list: std.ArrayList(Span) = .empty,

    pub fn deinit(s: *Spans, gpa: Allocator) void {
        s.list.deinit(gpa);
    }

    pub fn set(s: *Spans, gpa: Allocator, id: Id, span: Span) Allocator.Error!void {
        while (s.list.items.len <= id.index()) try s.list.append(gpa, .none);
        s.list.items[id.index()] = span;
    }

    pub fn get(s: Spans, id: Id) Span {
        return if (id.index() < s.list.items.len) s.list.items[id.index()] else .none;
    }

    /// Widens an object's span to end at `end`.
    pub fn extend(s: *Spans, gpa: Allocator, id: Id, end: usize) Allocator.Error!void {
        var sp = s.get(id);
        if (sp.start == Span.none.start) return;
        sp.end = @max(sp.end, @as(u32, @intCast(end)));
        try s.set(gpa, id, sp);
    }

    /// The innermost object whose span holds byte `at`.
    pub fn at(s: Spans, at_byte: usize) ?Id {
        var best: ?Id = null;
        var width: u32 = std.math.maxInt(u32);
        for (s.list.items, 0..) |sp, k| {
            if (sp.start == Span.none.start) continue;
            if (at_byte >= sp.start and at_byte < sp.end and sp.end - sp.start <= width) {
                best = @enumFromInt(k);
                width = sp.end - sp.start;
            }
        }
        return best;
    }
};

/// The marker the legend parsers put in text for a break allowed there
/// (`\allowbreak`): a zero-width space.
pub const allow_mark = "\u{200B}";
pub const soft_hyphen = "\u{AD}";

/// A legend's text as a parser collects it: its bytes (escapes undone,
/// break marks put in) and, for each, the source byte it came from.
pub const Text = struct {
    bytes: std.ArrayList(u8) = .empty,
    src: std.ArrayList(u32) = .empty,
    /// The letterforms of what is collected.
    variant: ex.Variant = .normal,

    pub fn deinit(t: *Text, gpa: Allocator) void {
        t.bytes.deinit(gpa);
        t.src.deinit(gpa);
    }

    /// `bytes`, from the source at `at`.
    pub fn add(t: *Text, gpa: Allocator, bytes: []const u8, at: usize) Allocator.Error!void {
        try t.bytes.appendSlice(gpa, bytes);
        for (bytes) |_| try t.src.append(gpa, @intCast(at));
    }

    /// Its objects into `row` (see `textObjects`), the text ending at
    /// source byte `end`; then empty.
    pub fn flush(t: *Text, e: *Expr, spans: *Spans, row: Id, end: usize) ex.Error!void {
        if (t.bytes.items.len == 0) return;
        try t.src.append(e.gpa, @intCast(end));
        try textObjects(e, spans, row, t.bytes.items, t.src.items, t.variant);
        t.bytes.clearRetainingCapacity();
        t.src.clearRetainingCapacity();
    }
};

/// Text of a legend into `row`: words, spaces (a run of them one object)
/// and soft hyphens, each its own object, so text breaks between words
/// and at soft hyphens; an allowed-break mark sets the next object's
/// break mark. All are tagged as text (source ""). `src` gives each
/// byte's source offset, and one more for the end.
pub fn textObjects(e: *Expr, spans: *Spans, row: Id, text: []const u8, src: []const u32, variant: ex.Variant) ex.Error!void {
    var allow = false;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const ch = text[i..@min(text.len, i + n)];
        var kind: Kind = .word;
        var j = i;
        if (std.mem.eql(u8, ch, allow_mark)) {
            allow = true;
            i += ch.len;
            continue;
        } else if (std.mem.eql(u8, ch, soft_hyphen)) {
            kind = .soft_hyphen;
            j = i + ch.len;
        } else if (ch[0] == ' ') {
            kind = .space;
            while (j < text.len and text[j] == ' ') j += 1;
        } else {
            // A word: up to a space, a soft hyphen or a break mark.
            while (j < text.len) {
                if (text[j] == ' ') break;
                if (std.mem.startsWith(u8, text[j..], soft_hyphen) or std.mem.startsWith(u8, text[j..], allow_mark)) break;
                j += std.unicode.utf8ByteSequenceLength(text[j]) catch 1;
            }
        }
        const id = try e.leaf(kind, text[i..@min(j, text.len)]);
        e.node(id).variant = variant;
        try e.append(row, id);
        try spans.set(e.gpa, id, .{ .start = src[i], .end = src[@min(j, text.len)] });
        if (allow) {
            try e.set(id, .break_before, param.of(param.BreakMark.allow));
            allow = false;
        }
        i = j;
    }
}

/// `v`'s weight and slant added to every object under `id`.
pub fn setVariant(e: *Expr, id: Id, v: ex.Variant) void {
    const n = e.node(id);
    n.variant = n.variant.with(v);
    for (n.items.items) |c| setVariant(e, c, v);
    for (std.enums.values(ex.Slot)) |sl| {
        const c = n.slots.get(sl);
        if (c != .none) setVariant(e, c, v);
    }
}

// Overrides in the source: Graven's call form ----------------------------------
//
// An element's overrides are written around it in Typst's call form with
// named arguments, in both syntaxes (decided 2026-11-16): LaTeX
// `\set(scale: 1.2, shift_y: 0.1){x}`, Typst `set(scale: 1.2)[x]`. Values
// are numbers, a choice's name, true or false, or a quoted name. An
// override the syntax already says another way (`\limits`, a plain
// fence's natural size, `\allowbreak`) is not written again.

/// Whether override `p` of `id` is written by the syntax itself.
pub fn implied(e: *const Expr, id: Id, p: param.Param) bool {
    const n = e.node(id);
    return switch (p) {
        .limits => n.kind == .large_op,
        .fence_size => n.kind == .fence and (std.mem.eql(u8, n.tags.source, "(") or std.mem.eql(u8, n.tags.source, "[")),
        .break_before => if (e.override(id, .break_before)) |v| param.as(param.BreakMark, v) == .allow else false,
        else => false,
    };
}

/// Whether `id` has overrides to write in the call form.
pub fn hasCall(e: *const Expr, id: Id) bool {
    for (e.node(id).overrides.items) |o| if (!implied(e, id, o.param)) return true;
    return false;
}

/// `(name: value, …)` for `id`'s overrides the syntax does not imply.
pub fn writeArgs(w: *std.Io.Writer, e: *const Expr, id: Id) std.Io.Writer.Error!void {
    try w.writeByte('(');
    var first = true;
    for (e.node(id).overrides.items) |o| {
        if (implied(e, id, o.param)) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{s}: ", .{@tagName(o.param)});
        switch (o.value) {
            .number => |x| try w.print("{d}", .{x}),
            .choice => |c| try w.writeAll(param.def(o.param).choices[c]),
            .flag => |f| try w.writeAll(if (f) "true" else "false"),
            .name => |t| try w.print("\"{s}\"", .{t}),
        }
    }
    try w.writeByte(')');
}

/// The arguments at `src[i..]`, which starts after the call's '(': up to
/// the matching ')' (quoted names may hold one), whose index it returns
/// (or the end). Each known parameter an element may take is set on
/// `id`; the rest are ignored.
pub fn parseArgs(e: *Expr, id: Id, src: []const u8, from: usize) ex.Error!usize {
    var i = from;
    while (i < src.len and src[i] != ')') {
        // name
        while (i < src.len and (src[i] == ' ' or src[i] == ',')) i += 1;
        const n0 = i;
        while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
        const name = src[n0..i];
        while (i < src.len and src[i] == ' ') i += 1;
        if (i < src.len and src[i] == ':') i += 1;
        while (i < src.len and src[i] == ' ') i += 1;
        // value
        const v0 = i;
        if (i < src.len and src[i] == '"') {
            i += 1;
            while (i < src.len and src[i] != '"') i += 1;
            if (i < src.len) i += 1;
        } else while (i < src.len and src[i] != ',' and src[i] != ')') i += 1;
        const raw = std.mem.trim(u8, src[v0..i], " ");
        if (name.len == 0 and raw.len == 0) {
            // Nothing parsed: step on, so a stray character cannot stall.
            if (i < src.len and src[i] != ')') i += 1;
            continue;
        }
        const p = std.meta.stringToEnum(param.Param, name) orelse continue;
        const d = param.def(p);
        const v: ?param.Value = switch (d.type) {
            .number => if (std.fmt.parseFloat(f32, raw)) |x| param.num(x) else |_| null,
            .choice => param.choiceNamed(p, raw),
            .flag => if (std.mem.eql(u8, raw, "true")) .{ .flag = true } else if (std.mem.eql(u8, raw, "false")) .{ .flag = false } else null,
            .name => .{ .name = try e.strings.allocator().dupe(u8, std.mem.trim(u8, raw, "\"")) },
        };
        if (v) |val| e.set(id, p, val) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Not an element's to set, or out of range: left out.
            else => {},
        };
    }
    return i;
}

/// After a call's body was parsed into group `g` (in row `r`): one object
/// in it takes the group's place and its overrides; more stay grouped,
/// the overrides on the group. Returns what holds them.
pub fn unwrapCall(e: *Expr, g: Id) ex.Error!Id {
    const body = e.slot(g, .body);
    const items = e.node(body).items.items;
    if (items.len != 1) return g;
    const only = items[0];
    const row = e.node(g).parent;
    const at = std.mem.indexOfScalar(Id, e.node(row).items.items, g).?;
    e.detach(only);
    try e.insert(row, at, only);
    for (e.node(g).overrides.items) |o| try e.set(only, o.param, o.value);
    e.remove(g);
    return only;
}

/// LaTeX source `src` with object `id`'s call form brought up to date with
/// its overrides in `e`: `src[span]` (the object's source, as parsed)
/// wrapped in `\set(…){…}`, its arguments rewritten, or unwrapped when it
/// has none left. Everything else in `src` is kept as typed. Allocated
/// from `a`.
pub fn rewriteCall(a: Allocator, src: []const u8, span: Span, e: *const Expr, id: Id) Allocator.Error![]u8 {
    const piece = src[span.start..span.end];
    // What the call (if any) holds.
    var body = piece;
    if (std.mem.startsWith(u8, piece, "\\set(")) {
        var i: usize = "\\set(".len;
        var quoted = false;
        while (i < piece.len and (quoted or piece[i] != ')')) : (i += 1) {
            if (piece[i] == '"') quoted = !quoted;
        }
        i += 1;
        if (i < piece.len and piece[i] == '{') {
            const inner = piece[i + 1 ..];
            body = if (std.mem.endsWith(u8, inner, "}")) inner[0 .. inner.len - 1] else inner;
        } else body = piece[@min(i, piece.len)..];
    }
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(src[0..span.start]) catch return error.OutOfMemory;
    if (hasCall(e, id)) {
        w.writeAll("\\set") catch return error.OutOfMemory;
        writeArgs(w, e, id) catch return error.OutOfMemory;
        w.print("{{{s}}}", .{body}) catch return error.OutOfMemory;
    } else w.writeAll(body) catch return error.OutOfMemory;
    w.writeAll(src[span.end..]) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The object the caret at byte `at` is on, for the inspector: the
/// innermost object whose source holds it (or the byte before it), past
/// rows and the expression's top row. Null when there is none.
pub fn objectAt(e: *const Expr, spans: Spans, at: usize) ?Id {
    const id = spans.at(at) orelse (if (at > 0) spans.at(at - 1) else null) orelse return null;
    var cur = id;
    while (cur != .none and e.node(cur).kind == .row) cur = e.node(cur).parent;
    if (cur == .none or cur == e.root) return null;
    return cur;
}

/// Whether a top-row object is a legend's text (not math).
pub fn isText(e: *const Expr, id: Id) bool {
    const n = e.node(id);
    return switch (n.kind) {
        .space, .soft_hyphen => true,
        .word => n.tags.source.len == 0,
        else => false,
    };
}

/// The row a script goes into: the `which` slot of the last object in
/// `row` (a large operator's limits, a scripts' free slot), or of a new
/// scripts made around it (with an empty base when there is none). The
/// structure it belongs to is returned too.
pub fn scriptTarget(e: *Expr, row: Id, which: Slot) ex.Error!struct { structure: Id, row: Id } {
    const items = e.node(row).items.items;
    if (items.len > 0) {
        const last = items[items.len - 1];
        const k = e.node(last).kind;
        if (k == .large_op) return .{ .structure = last, .row = try e.openSlot(last, which) };
        if (k == .scripts and e.slot(last, which) == .none) return .{ .structure = last, .row = try e.openSlot(last, which) };
        e.detach(last);
        const s = try e.structure(.scripts, "", "");
        try e.append(e.slot(s, .base), last);
        try e.append(row, s);
        return .{ .structure = s, .row = try e.openSlot(s, which) };
    }
    const s = try e.structure(.scripts, "", "");
    try e.append(row, s);
    return .{ .structure = s, .row = try e.openSlot(s, which) };
}

/// Sets + and − (and ±, ∓) unary where nothing they could combine stands
/// before them: at a row's start, or after an operator, a relation,
/// punctuation or a large operator.
pub fn fixRoles(e: *Expr, row: Id) void {
    const items = e.node(row).items.items;
    for (items, 0..) |id, k| {
        const n = e.node(id);
        if (n.kind != .operator) continue;
        const signed = std.mem.eql(u8, n.text, "+") or std.mem.eql(u8, n.text, "−") or std.mem.eql(u8, n.text, "±") or std.mem.eql(u8, n.text, "∓");
        if (!signed) {
            n.role = .binary;
            continue;
        }
        const prev: ?Kind = if (k == 0) null else e.node(items[k - 1]).kind;
        const unary = if (prev) |p| (p == .operator or p == .relation or p == .punct or p == .large_op) else true;
        n.role = if (unary) .unary else .binary;
    }
}

/// Whether two subtrees are the same objects (kinds, roles, texts, slots
/// and rows), whatever their ids, overrides and tags.
pub fn sameTree(ea: *const Expr, a: Id, eb: *const Expr, b: Id) bool {
    const na = ea.node(a);
    const nb = eb.node(b);
    if (na.kind != nb.kind or na.role != nb.role) return false;
    if (!std.mem.eql(u8, na.text, nb.text) or !std.mem.eql(u8, na.close, nb.close)) return false;
    if (na.items.items.len != nb.items.items.len) return false;
    for (na.items.items, nb.items.items) |x, y| if (!sameTree(ea, x, eb, y)) return false;
    for (std.enums.values(Slot)) |s| {
        const sa = na.slots.get(s);
        const sb = nb.slots.get(s);
        // An empty optional slot is the same as none.
        const ea_empty = sa == .none or ea.node(sa).items.items.len == 0;
        const eb_empty = sb == .none or eb.node(sb).items.items.len == 0;
        if (ea_empty and eb_empty) continue;
        if (sa == .none or sb == .none) return false;
        if (!sameTree(ea, sa, eb, sb)) return false;
    }
    return true;
}

/// A tree as text, for test failures: kinds, texts and slots, nested.
pub fn dump(w: *std.Io.Writer, e: *const Expr, id: Id) std.Io.Writer.Error!void {
    const n = e.node(id);
    switch (n.kind) {
        .row => {
            try w.writeAll("[");
            for (n.items.items, 0..) |c, k| {
                if (k > 0) try w.writeAll(" ");
                try dump(w, e, c);
            }
            try w.writeAll("]");
        },
        else => if (!n.kind.isStructure()) {
            try w.print("{s}:{s}{s}", .{ @tagName(n.kind)[0..3], n.text, if (n.role == .unary) "(u)" else "" });
        } else {
            try w.print("{s}{s}{s}(", .{ @tagName(n.kind), if (n.text.len > 0) " " else "", n.text });
            var first = true;
            for (n.kind.slots()) |s| {
                const r = n.slots.get(s);
                if (r == .none) continue;
                if (!first) try w.writeAll(", ");
                first = false;
                try w.print("{s}=", .{@tagName(s)});
                try dump(w, e, r);
            }
            try w.writeAll(")");
        },
    }
}
