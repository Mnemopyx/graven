//! Style contexts: part of glyphic's object system. The library defines
//! none: an application configures one or more through the engine (faces
//! by role, values, rules for objects of a kind), then applies them to
//! elements or to groups of elements.
//!
//! A style context has a name, may build on a base context, names faces
//! by role ("text", "math", "italic"…), and holds rules: a parameter's
//! value, for every object it reaches or for objects of a kind (by kind,
//! role, script level, symbol or slot; the most specific rule wins, of
//! equals the later). Elements override it only in a limited way (see
//! `param.Def.element`), mostly their relative scale.

const std = @import("std");
const param = @import("param.zig");
const ex = @import("expr.zig");
const cascade = @import("cascade.zig");
const faces_mod = @import("faces.zig");

const Allocator = std.mem.Allocator;
const Param = param.Param;
const Value = param.Value;
pub const StyleId = ex.StyleId;
pub const Rule = cascade.Rule;
pub const Selector = cascade.Selector;

pub const StyleContext = struct {
    name: []const u8,
    /// The context it builds on: what it does not set, its base does.
    base: StyleId = .none,
    /// Faces by role; a role it does not name comes from its base.
    faces: std.ArrayList(faces_mod.Member) = .empty,
    rules: std.ArrayList(Rule) = .empty,
};

pub const Error = Allocator.Error || param.Error || error{NoSuchStyle};

/// Glyphic's engine: the style contexts an application has configured.
pub const Engine = struct {
    gpa: Allocator,
    strings: std.heap.ArenaAllocator,
    contexts: std.ArrayList(StyleContext) = .empty,

    pub fn init(gpa: Allocator) Engine {
        return .{ .gpa = gpa, .strings = .init(gpa) };
    }

    pub fn deinit(g: *Engine) void {
        for (g.contexts.items) |*c| {
            c.faces.deinit(g.gpa);
            c.rules.deinit(g.gpa);
        }
        g.contexts.deinit(g.gpa);
        g.strings.deinit();
    }

    /// A new style context named `name`, building on `base` (.none for none).
    pub fn addStyle(g: *Engine, name: []const u8, base: StyleId) Error!StyleId {
        if (base != .none and base.index() >= g.contexts.items.len) return error.NoSuchStyle;
        const id: StyleId = @enumFromInt(g.contexts.items.len);
        try g.contexts.append(g.gpa, .{ .name = try g.strings.allocator().dupe(u8, name), .base = base });
        return id;
    }

    pub fn style(g: *const Engine, id: StyleId) *StyleContext {
        return &g.contexts.items[id.index()];
    }

    pub fn find(g: *const Engine, name: []const u8) ?StyleId {
        for (g.contexts.items, 0..) |c, k| if (std.mem.eql(u8, c.name, name)) return @enumFromInt(k);
        return null;
    }

    /// Names the face that plays `role` in context `id`.
    pub fn setFace(g: *Engine, id: StyleId, role: []const u8, face: *faces_mod.Face) Error!void {
        const c = g.style(id);
        for (c.faces.items) |*m| if (std.mem.eql(u8, m.name, role)) {
            m.face = face;
            return;
        };
        try c.faces.append(g.gpa, .{ .name = try g.strings.allocator().dupe(u8, role), .face = face });
    }

    /// Sets a parameter for every object context `id` reaches.
    pub fn set(g: *Engine, id: StyleId, p: Param, v: Value) Error!void {
        return g.setFor(id, .{}, p, v);
    }

    /// Sets a parameter for the objects `sel` names, where context `id`
    /// reaches. A rule with the same selector and parameter is replaced.
    pub fn setFor(g: *Engine, id: StyleId, sel: Selector, p: Param, v: Value) Error!void {
        try param.check(p, v);
        var s = sel;
        if (s.symbol) |y| s.symbol = try g.strings.allocator().dupe(u8, y);
        const val: Value = if (v == .name) .{ .name = try g.strings.allocator().dupe(u8, v.name) } else v;
        const c = g.style(id);
        for (c.rules.items) |*r| if (r.param == p and sameSelector(r.selector, s)) {
            r.value = val;
            return;
        };
        try c.rules.append(g.gpa, .{ .selector = s, .param = p, .value = val });
    }

    /// Applies context `id` to element `obj` of `e` (or the whole
    /// expression, at its top row): what it holds takes the context, inside
    /// any applied further out.
    pub fn apply(g: *const Engine, e: *ex.Expr, obj: ex.Id, id: StyleId) Error!void {
        if (id != .none and id.index() >= g.contexts.items.len) return error.NoSuchStyle;
        e.node(obj).style = id;
    }
};

fn sameSelector(a: Selector, b: Selector) bool {
    if (a.kind != b.kind or a.role != b.role or a.script_level != b.script_level or a.slot != b.slot) return false;
    if ((a.symbol == null) != (b.symbol == null)) return false;
    if (a.symbol) |x| return std.mem.eql(u8, x, b.symbol.?);
    return true;
}
