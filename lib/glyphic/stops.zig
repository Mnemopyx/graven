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
