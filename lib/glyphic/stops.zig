//! Stops: where Tab goes. Field order is the object model's, not an entry
//! syntax's: depth first, each structure's head (its own symbol) before
//! its slots, each kind's slots in its fixed order (Kind.slots).
//!
//! A head takes no caret: keys on it style its symbol and its structure.
//! A field (a row) takes the caret. Rows that only hold one structure are
//! not stops of their own (the structure's stops stand for them), nor is
//! the expression's top row. Optional slots that do not exist, or are
//! hidden, are skipped; heads never are.

const std = @import("std");
const param = @import("param.zig");
const ex = @import("expr.zig");
const cascade = @import("cascade.zig");

const Allocator = std.mem.Allocator;
const Expr = ex.Expr;
const Id = ex.Id;
const Slot = ex.Slot;
const Resolver = cascade.Resolver;

pub const Stop = union(enum) {
    head: Id,
    field: Id,

    pub fn eql(a: Stop, b: Stop) bool {
        return std.meta.eql(a, b);
    }
};

/// Whether a structure's optional slot is shown: its show parameter, or
/// (auto) whether it exists.
pub fn shown(r: *const Resolver, id: Id, s: Slot) bool {
    const row = r.e.slot(id, s);
    const p = s.showParam() orelse return row != .none;
    return switch (param.as(param.SlotShow, r.get(id, p))) {
        .auto => row != .none,
        .shown => true,
        .hidden => false,
    } and row != .none;
}

/// Every stop, in field order.
pub fn list(gpa: Allocator, r: *const Resolver) Allocator.Error![]Stop {
    var out: std.ArrayList(Stop) = .empty;
    errdefer out.deinit(gpa);
    try visitRow(gpa, r, r.e.root, true, &out);
    return out.toOwnedSlice(gpa);
}

fn visitRow(gpa: Allocator, r: *const Resolver, row: Id, top: bool, out: *std.ArrayList(Stop)) Allocator.Error!void {
    const items = r.e.node(row).items.items;
    const lone_structure = items.len == 1 and r.e.node(items[0]).kind.isStructure();
    if (!top and !lone_structure) try out.append(gpa, .{ .field = row });
    for (items) |it| if (r.e.node(it).kind.isStructure()) try visitStructure(gpa, r, it, out);
}

fn visitStructure(gpa: Allocator, r: *const Resolver, id: Id, out: *std.ArrayList(Stop)) Allocator.Error!void {
    const n = r.e.node(id);
    if (n.kind.hasHead()) try out.append(gpa, .{ .head = id });
    for (n.kind.slots()) |s| {
        if (s.optional(n.kind) and !shown(r, id, s)) continue;
        const row = r.e.slot(id, s);
        if (row == .none) continue;
        try visitRow(gpa, r, row, false, out);
    }
}

/// The stop after `from` (before it when `back`), wrapping at the ends;
/// the first (or last) when `from` is not a stop.
pub fn next(stops: []const Stop, from: ?Stop, back: bool) ?Stop {
    if (stops.len == 0) return null;
    var at: ?usize = null;
    if (from) |f| {
        for (stops, 0..) |s, k| if (s.eql(f)) {
            at = k;
            break;
        };
    }
    const k = at orelse return if (back) stops[stops.len - 1] else stops[0];
    return if (back) stops[(k + stops.len - 1) % stops.len] else stops[(k + 1) % stops.len];
}

/// Toggles a structure's optional slot from its head: a closed slot is
/// opened (an empty field, shown); a shown one is hidden, its contents
/// kept; a hidden one shown again. Returns the slot's row when it is now
/// shown (where the caret goes), else null.
pub fn toggle(e: *Expr, r: *const Resolver, id: Id, s: Slot) ex.Error!?Id {
    const k = e.node(id).kind;
    if (!s.optional(k)) return error.NoSuchSlot;
    const p = s.showParam().?;
    if (e.slot(id, s) == .none) {
        const row = try e.openSlot(id, s);
        e.clear(id, p);
        return row;
    }
    if (shown(r, id, s)) {
        try e.set(id, p, param.of(param.SlotShow.hidden));
        return null;
    }
    try e.set(id, p, param.of(param.SlotShow.shown));
    return e.slot(id, s);
}

// Stops in the source -------------------------------------------------------------
//
// An entry line edits the source; Tab moves its caret from stop to stop in
// field order, through the spans the parser recorded.

const entry = @import("entry.zig");
const Spans = entry.Spans;

/// Where the caret goes for stop `s`: a head before its structure; a field
/// at the end of what it holds (between the braces of an empty one). Null
/// for a stop the source has no place for.
pub fn offset(spans: Spans, s: Stop) ?usize {
    const sp = switch (s) {
        .head => |id| spans.get(id),
        .field => |row| spans.get(row),
    };
    if (sp.start == entry.Span.none.start) return null;
    return switch (s) {
        .head => sp.start,
        .field => sp.end,
    };
}

/// The field holding byte `at` (its ends included): the narrowest.
pub fn fieldAt(spans: Spans, stops: []const Stop, at: usize) ?Stop {
    var best: ?Stop = null;
    var width: usize = std.math.maxInt(usize);
    for (stops) |s| {
        if (s != .field) continue;
        const sp = spans.get(s.field);
        if (sp.start == entry.Span.none.start) continue;
        if (at >= sp.start and at <= sp.end and sp.end - sp.start <= width) {
            best = s;
            width = sp.end - sp.start;
        }
    }
    return best;
}

/// Where Tab (Shift+Tab: `back`) takes a caret at byte `at`: from the
/// field it is in to the next stop (wrapping); outside every field, to the
/// first stop after it (before it, going back). Null when there is none.
pub fn tab(gpa: Allocator, r: *const Resolver, spans: Spans, at: usize, back: bool) Allocator.Error!?usize {
    const all = try list(gpa, r);
    defer gpa.free(all);
    // Only stops with a place in the source.
    var placed: std.ArrayList(Stop) = .empty;
    defer placed.deinit(gpa);
    for (all) |s| if (offset(spans, s) != null) try placed.append(gpa, s);
    const ss = placed.items;
    if (ss.len == 0) return null;
    if (fieldAt(spans, ss, at)) |cur| return offset(spans, next(ss, cur, back).?);
    if (back) {
        var k = ss.len;
        while (k > 0) : (k -= 1) if (offset(spans, ss[k - 1]).? < at) return offset(spans, ss[k - 1]);
        return offset(spans, ss[ss.len - 1]);
    }
    for (ss) |s| if (offset(spans, s).? > at) return offset(spans, s);
    return offset(spans, ss[0]);
}

test "Tab in the source: field to field in field order, heads before their structures" {
    const latex = @import("latex.zig");
    const styles = @import("styles.zig");
    const gpa = std.testing.allocator;
    var e = try Expr.init(gpa);
    defer e.deinit();
    var spans: Spans = .{};
    defer spans.deinit(gpa);
    //          0123456789012345678
    const src = "\\frac{a}{}+\\sqrt{x}";
    try latex.parse(&e, &spans, src, .math);
    var g = styles.Engine.init(gpa);
    defer g.deinit();
    const r = Resolver.init(&g, &e, &.{});
    // At the start (the fraction's head): on to its numerator; back from
    // there to the head; on to the empty denominator, between its braces.
    try std.testing.expectEqual(@as(?usize, 7), try tab(gpa, &r, spans, 0, false));
    try std.testing.expectEqual(@as(?usize, 0), try tab(gpa, &r, spans, 6, true));
    try std.testing.expectEqual(@as(?usize, 9), try tab(gpa, &r, spans, 7, false));
    // On to the root's head, then its body; and round again.
    try std.testing.expectEqual(@as(?usize, 11), try tab(gpa, &r, spans, 9, false));
    try std.testing.expectEqual(@as(?usize, 18), try tab(gpa, &r, spans, 11, false));
    try std.testing.expectEqual(@as(?usize, 0), try tab(gpa, &r, spans, 18, false));
}
