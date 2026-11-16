//! What the entry syntaxes (latex.zig, typst.zig) share: source spans,
//! attaching scripts, deciding operators' roles, and comparing trees.
//!
//! Parsers never fail: every prefix of an expression parses to a whole
//! tree, a missing argument left as an empty row (a hole), an unclosed
//! group closed at the end, a command still being typed kept as upright
//! text. So typing builds the expression greedily, rendered as it goes.

const std = @import("std");
const ex = @import("expr.zig");

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
