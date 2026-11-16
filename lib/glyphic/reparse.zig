//! Identity across a reparse: when the source of an open expression is
//! edited and parsed again, the new objects are matched to the old ones,
//! so what was set on an object (its overrides) stays with it, and the
//! caller's ids (a selection, a pick) can follow it.
//!
//! Matching is by structure: each row's objects by their longest common
//! subsequence on kind, text and role; matched structures' slots in turn.
//! An object edited (another character) is new; its neighbours keep theirs.

const std = @import("std");
const ex = @import("expr.zig");

const Allocator = std.mem.Allocator;
const Expr = ex.Expr;
const Id = ex.Id;
const Slot = ex.Slot;

/// Old ids to new.
pub const IdMap = std.AutoHashMapUnmanaged(Id, Id);

/// Matches `new`'s objects to `old`'s, copies matched objects' overrides
/// and applied style contexts from `old`, and returns the map of matched
/// ids, from `gpa`.
pub fn carry(gpa: Allocator, old: *const Expr, new: *Expr) !IdMap {
    var map: IdMap = .empty;
    errdefer map.deinit(gpa);
    try match(gpa, old, old.root, new, new.root, &map);
    return map;
}

fn key(e: *const Expr, id: Id, other: *const Expr, oid: Id) bool {
    const a = e.node(id);
    const b = other.node(oid);
    return a.kind == b.kind and a.role == b.role and std.mem.eql(u8, a.text, b.text) and std.mem.eql(u8, a.close, b.close);
}

fn match(gpa: Allocator, old: *const Expr, o: Id, new: *Expr, n: Id, map: *IdMap) !void {
    try pair(old, o, new, n, map, gpa);
    const on = old.node(o);
    if (on.kind == .row) {
        const xs = on.items.items;
        const ys = new.node(n).items.items;
        // Longest common subsequence, by table.
        const w = ys.len + 1;
        const t = try gpa.alloc(u32, (xs.len + 1) * w);
        defer gpa.free(t);
        @memset(t, 0);
        var i = xs.len;
        while (i > 0) {
            i -= 1;
            var j = ys.len;
            while (j > 0) {
                j -= 1;
                t[i * w + j] = if (key(old, xs[i], new, ys[j])) t[(i + 1) * w + j + 1] + 1 else @max(t[(i + 1) * w + j], t[i * w + j + 1]);
            }
        }
        i = 0;
        var j: usize = 0;
        while (i < xs.len and j < ys.len) {
            if (key(old, xs[i], new, ys[j])) {
                try match(gpa, old, xs[i], new, ys[j], map);
                i += 1;
                j += 1;
            } else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) i += 1 else j += 1;
        }
        return;
    }
    // A structure: its slots in turn.
    for (std.enums.values(Slot)) |s| {
        const os = on.slots.get(s);
        const ns = new.node(n).slots.get(s);
        if (os == .none or ns == .none) continue;
        try match(gpa, old, os, new, ns, map);
    }
}

fn pair(old: *const Expr, o: Id, new: *Expr, n: Id, map: *IdMap, gpa: Allocator) !void {
    try map.put(gpa, o, n);
    if (new.node(n).style == .none) new.node(n).style = old.node(o).style;
    for (old.node(o).overrides.items) |ov| {
        if (new.override(n, ov.param) == null) try new.set(n, ov.param, ov.value);
    }
}
