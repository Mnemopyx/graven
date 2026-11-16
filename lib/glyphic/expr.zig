//! An expression as conceptual objects: the stored form of a legend's math,
//! not markup. Every object has a stable identity, a kind (and a role
//! where it matters), named slots holding its parts, the parameters set on
//! it (overrides) and tags recording where it came from. Entry syntaxes
//! (LaTeX, Typst) translate to and from it.
//!
//! A slot holds a row: a field, an ordered list of objects, which is where
//! a caret goes. A structure (fraction, scripts, large operator, radical,
//! fence, accent, group) has slots; most have a head, their own symbol
//! (the rule, Σ, √, the delimiters, the accent mark), which is a stop of
//! its own. Leaves (numbers, variables, operators…) sit in rows.

const std = @import("std");
const param = @import("param.zig");

const Allocator = std.mem.Allocator;
const Param = param.Param;
const Value = param.Value;

/// An object's identity: stable for its whole life (ids are never reused),
/// so overrides and tags stay with it through edits.
pub const Id = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn index(id: Id) usize {
        return @intFromEnum(id);
    }
};

pub const Kind = enum {
    /// A field: an ordered list of objects.
    row,
    // Leaves.
    number,
    variable,
    /// A named constant (π, e): upright by convention.
    constant,
    /// An ordinary symbol (∞, ∂).
    symbol,
    operator,
    relation,
    punct,
    /// Upright text inside math (a function name, a word).
    word,
    ellipsis,
    // Structures.
    fraction,
    /// A base with scripts.
    scripts,
    /// Σ, ∏, ∫: its glyph is its head; its limits are its scripts.
    large_op,
    radical,
    /// Delimiters around a body: ( ), [ ], | |.
    fence,
    accent,
    /// Contents kept together (never broken inside), with no symbol of its own.
    group,

    pub fn isStructure(k: Kind) bool {
        return @intFromEnum(k) >= @intFromEnum(Kind.fraction);
    }

    /// Whether it has a symbol of its own, a stop before its fields.
    pub fn hasHead(k: Kind) bool {
        return switch (k) {
            .fraction, .large_op, .radical, .fence, .accent => true,
            else => false,
        };
    }

    /// Its slots, in field order (the order Tab visits them, after the head).
    pub fn slots(k: Kind) []const Slot {
        return switch (k) {
            .fraction => &.{ .num, .den },
            .scripts => &.{ .base, .sub, .sup },
            .large_op => &.{ .sub, .sup },
            .radical => &.{ .index, .body },
            .fence, .accent, .group => &.{.body},
            else => &.{},
        };
    }
};

/// What an operator does where it stands.
pub const Role = enum { none, unary, binary };

pub const Slot = enum {
    num,
    den,
    base,
    sub,
    sup,
    index,
    body,

    /// Whether a structure of `k` may lack it (it is made when opened).
    pub fn optional(s: Slot, k: Kind) bool {
        return switch (k) {
            .scripts, .large_op => s == .sub or s == .sup,
            .radical => s == .index,
            else => false,
        };
    }

    /// The parameter that shows or hides it, for optional slots.
    pub fn showParam(s: Slot) ?Param {
        return switch (s) {
            .sub => .show_sub,
            .sup => .show_sup,
            .index => .show_index,
            else => null,
        };
    }
};

/// TeX's atom classes, recorded for export.
pub const Atom = enum { ord, op, bin, rel, open, close, punct, inner };
pub const Syntax = enum { none, latex, typst };

/// Where an object came from, for writing it back out.
pub const Tags = struct {
    /// The command or construct that made it ("\\frac", "/", "sum").
    source: []const u8 = "",
    atom: ?Atom = null,
    syntax: Syntax = .none,
};

pub const Override = struct { param: Param, value: Value };

pub const Node = struct {
    kind: Kind,
    role: Role = .none,
    /// A leaf's characters; a structure's head glyph (Σ, √, an accent
    /// mark, an opening delimiter).
    text: []const u8 = "",
    /// A fence's closing delimiter.
    close: []const u8 = "",
    /// A variable's name, shared by its occurrences ("every n").
    symbol: []const u8 = "",
    parent: Id = .none,
    /// Which slot of its parent it fills (a row in a structure); null for
    /// an object in a row.
    in_slot: ?Slot = null,
    /// A row's objects.
    items: std.ArrayList(Id) = .empty,
    /// A structure's rows.
    slots: std.EnumArray(Slot, Id) = .initFill(.none),
    overrides: std.ArrayList(Override) = .empty,
    tags: Tags = .{},
    live: bool = true,
};

pub const Error = Allocator.Error || param.Error || error{ NotARow, NotAStructure, NoSuchSlot, Dead };

/// One expression (a math region of a legend).
pub const Expr = struct {
    gpa: Allocator,
    /// Strings: leaf text, symbols, tags.
    strings: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    root: Id = .none,
    /// The legend level of the cascade: rules for this expression as a
    /// whole, or for its objects of a kind ("every n").
    legend: std.ArrayList(@import("cascade.zig").Rule) = .empty,

    pub fn init(gpa: Allocator) Allocator.Error!Expr {
        var e: Expr = .{ .gpa = gpa, .strings = .init(gpa) };
        e.root = try e.make(.{ .kind = .row });
        return e;
    }

    pub fn deinit(e: *Expr) void {
        for (e.nodes.items) |*n| {
            n.items.deinit(e.gpa);
            n.overrides.deinit(e.gpa);
        }
        e.nodes.deinit(e.gpa);
        e.legend.deinit(e.gpa);
        e.strings.deinit();
    }

    pub fn node(e: *const Expr, id: Id) *Node {
        return &e.nodes.items[id.index()];
    }

    fn make(e: *Expr, n: Node) Allocator.Error!Id {
        const id: Id = @enumFromInt(e.nodes.items.len);
        try e.nodes.append(e.gpa, n);
        return id;
    }

    fn str(e: *Expr, s: []const u8) Allocator.Error![]const u8 {
        return e.strings.allocator().dupe(u8, s);
    }

    /// A new leaf (not yet in a row).
    pub fn leaf(e: *Expr, kind: Kind, text: []const u8) Allocator.Error!Id {
        std.debug.assert(!kind.isStructure() and kind != .row);
        const t = try e.str(text);
        return e.make(.{ .kind = kind, .text = t, .symbol = if (kind == .variable) t else "" });
    }

    /// A new operator, unary or binary.
    pub fn operator(e: *Expr, text: []const u8, role: Role) Allocator.Error!Id {
        const id = try e.leaf(.operator, text);
        e.node(id).role = role;
        return id;
    }

    /// A new structure, its required slots made (as empty rows: holes) and
    /// its optional ones left closed. `head` is its symbol (Σ, √, an
    /// accent, an opening delimiter); `close`, a fence's closing one.
    pub fn structure(e: *Expr, kind: Kind, head: []const u8, close: []const u8) Allocator.Error!Id {
        std.debug.assert(kind.isStructure());
        const id = try e.make(.{ .kind = kind, .text = try e.str(head), .close = try e.str(close) });
        for (kind.slots()) |s| if (!s.optional(kind)) {
            _ = e.openSlot(id, s) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable, // its own kind's slot, on a structure
            };
        };
        return id;
    }

    /// The row in a structure's slot, made (empty) if it has none yet.
    pub fn openSlot(e: *Expr, id: Id, s: Slot) Error!Id {
        const k = e.node(id).kind;
        if (!k.isStructure()) return error.NotAStructure;
        if (std.mem.indexOfScalar(Slot, k.slots(), s) == null) return error.NoSuchSlot;
        const have = e.node(id).slots.get(s);
        if (have != .none) return have;
        const row = try e.make(.{ .kind = .row, .parent = id, .in_slot = s });
        e.node(id).slots.set(s, row);
        return row;
    }

    /// The row in a structure's slot, or .none.
    pub fn slot(e: *const Expr, id: Id, s: Slot) Id {
        return e.node(id).slots.get(s);
    }

    /// Puts `item` (detached) into `row` at `at` (clamped to its end).
    pub fn insert(e: *Expr, row: Id, at: usize, item: Id) Error!void {
        if (e.node(row).kind != .row) return error.NotARow;
        if (!e.node(item).live) return error.Dead;
        std.debug.assert(e.node(item).parent == .none);
        const r = e.node(row);
        try r.items.insert(e.gpa, @min(at, r.items.items.len), item);
        e.node(item).parent = row;
        e.node(item).in_slot = null;
    }

    pub fn append(e: *Expr, row: Id, item: Id) Error!void {
        return e.insert(row, std.math.maxInt(usize), item);
    }

    /// Takes `item` out of its row, keeping it (and its overrides) to be put
    /// back elsewhere.
    pub fn detach(e: *Expr, item: Id) void {
        const p = e.node(item).parent;
        if (p == .none) return;
        const r = e.node(p);
        if (std.mem.indexOfScalar(Id, r.items.items, item)) |k| _ = r.items.orderedRemove(k);
        e.node(item).parent = .none;
    }

    /// Takes `item` out and ends it, with everything it holds. Other ids
    /// are untouched.
    pub fn remove(e: *Expr, item: Id) void {
        e.detach(item);
        e.end(item);
    }

    fn end(e: *Expr, id: Id) void {
        const n = e.node(id);
        n.live = false;
        for (n.items.items) |c| e.end(c);
        var it = n.slots.iterator();
        while (it.next()) |s| if (s.value.* != .none) e.end(s.value.*);
    }

    /// Sets a parameter on an object (its object-level override).
    pub fn set(e: *Expr, id: Id, p: Param, v: Value) Error!void {
        try param.check(p, v);
        const val: Value = if (v == .name) .{ .name = try e.str(v.name) } else v;
        const n = e.node(id);
        for (n.overrides.items) |*o| if (o.param == p) {
            o.value = val;
            return;
        };
        try n.overrides.append(e.gpa, .{ .param = p, .value = val });
    }

    /// Clears an object's override, so the cascade gives the value again.
    pub fn clear(e: *Expr, id: Id, p: Param) void {
        const n = e.node(id);
        for (n.overrides.items, 0..) |o, k| if (o.param == p) {
            _ = n.overrides.orderedRemove(k);
            return;
        };
    }

    /// The value set on the object itself, if any.
    pub fn override(e: *const Expr, id: Id, p: Param) ?Value {
        for (e.node(id).overrides.items) |o| if (o.param == p) return o.value;
        return null;
    }

    /// The structure an object's row belongs to, and which slot: what
    /// holds it, one level up. Null for the root row and what is in it.
    pub fn holder(e: *const Expr, id: Id) ?struct { structure: Id, slot: Slot } {
        const row = if (e.node(id).kind == .row) id else e.node(id).parent;
        if (row == .none) return null;
        const rn = e.node(row);
        if (rn.parent == .none) return null;
        return .{ .structure = rn.parent, .slot = rn.in_slot.? };
    }
};

// Tests ---------------------------------------------------------------------------

const testing = std.testing;

test "a structure is made with its required slots as holes" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const f = try e.structure(.fraction, "", "");
    try testing.expect(e.slot(f, .num) != .none);
    try testing.expectEqual(@as(usize, 0), e.node(e.slot(f, .den)).items.items.len);
    const r = try e.structure(.radical, "√", "");
    try testing.expectEqual(Id.none, e.slot(r, .index));
    const idx = try e.openSlot(r, .index);
    try testing.expectEqual(idx, try e.openSlot(r, .index));
    try testing.expectError(error.NoSuchSlot, e.openSlot(f, .index));
}

test "ids are stable: removing or moving one leaves the rest, overrides travel" {
    var e = try Expr.init(testing.allocator);
    defer e.deinit();
    const a = try e.leaf(.variable, "a");
    const b = try e.leaf(.variable, "b");
    const c = try e.leaf(.variable, "c");
    for ([_]Id{ a, b, c }) |x| try e.append(e.root, x);
    try e.set(c, .weight, param.num(0.02));
    e.remove(b);
    try testing.expect(!e.node(b).live);
    try testing.expectEqualSlices(Id, &.{ a, c }, e.node(e.root).items.items);
    // Moved into a fraction's numerator, c keeps its weight.
    const f = try e.structure(.fraction, "", "");
    try e.append(e.root, f);
    e.detach(c);
    try e.append(e.slot(f, .num), c);
    try testing.expectEqual(@as(f32, 0.02), e.override(c, .weight).?.number);
    try testing.expectEqual(f, e.holder(c).?.structure);
    try testing.expectEqual(Slot.num, e.holder(c).?.slot);
    try testing.expectError(param.Error.OutOfRange, e.set(c, .weight, param.num(3)));
    e.clear(c, .weight);
    try testing.expectEqual(null, e.override(c, .weight));
}
