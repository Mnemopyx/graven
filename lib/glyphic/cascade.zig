//! Where a parameter's value comes from: an element's own override (in
//! the limited ways an element may), else the style contexts reaching it
//! (styles.zig), innermost first, each before its base, else the
//! parameter's default. Within a context, rules may be general or for
//! objects of a kind (by kind, role, script level, symbol, slot): the most
//! specific matching rule wins, and of equals the later one.
//!
//! Also here: the context an object's place gives it, derived from the
//! structure and never stored (math style, cramped, script level), which
//! is what rules for "objects of a kind" match on.

const std = @import("std");
const param = @import("param.zig");
const ex = @import("expr.zig");

const Param = param.Param;
const Value = param.Value;
const Expr = ex.Expr;
const Id = ex.Id;
const Kind = ex.Kind;
const Role = ex.Role;
const Slot = ex.Slot;
const StyleId = ex.StyleId;
const Allocator = std.mem.Allocator;
const Engine = @import("styles.zig").Engine;
const faces_mod = @import("faces.zig");

// Context ------------------------------------------------------------------------

/// TeX's math styles.
pub const TexStyle = enum {
    display,
    text,
    script,
    scriptscript,

    /// 0 in display and text style, 1 in script, 2 in scriptscript.
    pub fn scriptLevel(s: TexStyle) u2 {
        return switch (s) {
            .display, .text => 0,
            .script => 1,
            .scriptscript => 2,
        };
    }

    /// The style a fraction's numerator or denominator is set in.
    fn fractionPart(s: TexStyle) TexStyle {
        return switch (s) {
            .display => .text,
            .text => .script,
            .script, .scriptscript => .scriptscript,
        };
    }

    /// The style a script or a limit is set in.
    fn scriptPart(s: TexStyle) TexStyle {
        return switch (s) {
            .display, .text => .script,
            .script, .scriptscript => .scriptscript,
        };
    }
};

/// What an object's place gives it.
pub const Context = struct {
    id: Id,
    kind: Kind,
    role: Role,
    /// A variable's name.
    symbol: []const u8,
    /// The slot of the structure nearest above it (null at the top).
    slot: ?Slot,
    style: TexStyle,
    /// Set lower (denominators, subscripts, radicands), as TeX does.
    cramped: bool,
    script_level: u2,
};

/// The context of `id`, the expression set in `root` style, every
/// fraction stacked (see `Resolver.context`, which reads their forms).
pub fn contextOf(e: *const Expr, id: Id, root: TexStyle) Context {
    return derive(e, id, root, null);
}

/// The context of `id`; with a resolver, a slashed fraction keeps its
/// parts at its own style, as it sets them inline.
fn derive(e: *const Expr, id: Id, root: TexStyle, r: ?*const Resolver) Context {
    // The structures above, innermost first.
    var path: [64]struct { kind: Kind, slot: Slot, id: Id } = undefined;
    var n: usize = 0;
    var cur = id;
    while (e.holder(cur)) |h| {
        if (n < path.len) {
            path[n] = .{ .kind = e.node(h.structure).kind, .slot = h.slot, .id = h.structure };
            n += 1;
        }
        cur = h.structure;
    }
    var style = root;
    var cramped = false;
    var k = n;
    while (k > 0) {
        k -= 1;
        const p = path[k];
        switch (p.kind) {
            .fraction => {
                const inline_form = if (r) |rr| param.as(param.FractionForm, rr.get(p.id, .fraction_form)) == .slashed else false;
                if (!inline_form) {
                    style = style.fractionPart();
                    if (p.slot == .den) cramped = true;
                }
            },
            .scripts, .large_op => switch (p.slot) {
                .sub, .sup => {
                    style = style.scriptPart();
                    if (p.slot == .sub) cramped = true;
                },
                else => {},
            },
            .radical => switch (p.slot) {
                .index => style = .scriptscript,
                .body => cramped = true,
                else => {},
            },
            else => {},
        }
    }
    const node = e.node(id);
    return .{
        .id = id,
        .kind = node.kind,
        .role = node.role,
        .symbol = node.symbol,
        .slot = if (n > 0) path[0].slot else null,
        .style = style,
        .cramped = cramped,
        .script_level = style.scriptLevel(),
    };
}

// Rules --------------------------------------------------------------------------

/// Which objects a rule is for; a field left null matches anything.
pub const Selector = struct {
    kind: ?Kind = null,
    role: ?Role = null,
    script_level: ?u2 = null,
    symbol: ?[]const u8 = null,
    slot: ?Slot = null,

    pub fn matches(s: Selector, c: Context) bool {
        if (s.kind) |k| if (k != c.kind) return false;
        if (s.role) |r| if (r != c.role) return false;
        if (s.script_level) |l| if (l != c.script_level) return false;
        if (s.symbol) |y| if (!std.mem.eql(u8, y, c.symbol)) return false;
        if (s.slot) |sl| if (c.slot == null or c.slot.? != sl) return false;
        return true;
    }

    /// How many things it names: the more, the more specific.
    pub fn specificity(s: Selector) u8 {
        var n: u8 = 0;
        if (s.kind != null) n += 1;
        if (s.role != null) n += 1;
        if (s.script_level != null) n += 1;
        if (s.symbol != null) n += 1;
        if (s.slot != null) n += 1;
        return n;
    }
};

pub const Rule = struct {
    selector: Selector = .{},
    param: Param,
    value: Value,
};

/// Where a resolved value came from.
pub const From = enum {
    /// The parameter's default.
    default,
    /// A style context's rule.
    style,
    /// The element's own override.
    element,
};

/// A resolved value and where it came from, for inspection.
pub const Resolved = struct {
    value: Value,
    from: From,
    /// The style context whose rule set it (through its bases, this is
    /// the base that held the rule).
    style: StyleId = .none,
    /// That rule's index in it.
    rule: ?usize = null,
};

/// The winning rule of one style context for `p` in context `c`.
fn best(rules: []const Rule, p: Param, c: Context) ?usize {
    var found: ?usize = null;
    var spec: u8 = 0;
    for (rules, 0..) |r, k| {
        if (r.param != p or !r.selector.matches(c)) continue;
        const s = r.selector.specificity();
        if (found == null or s >= spec) {
            found = k;
            spec = s;
        }
    }
    return found;
}

/// Resolves an expression's parameters and faces: an element's own
/// override (where it may have one), then the style contexts applied to
/// it and to what holds it, innermost first, then those applied to groups
/// outside the expression; each context before its base; else the
/// parameter's default.
pub const Resolver = struct {
    e: *const Expr,
    engine: *const Engine,
    /// Style contexts applied to groups holding the expression (a
    /// document, a panel, a track, a tile), outermost first.
    outer: []const StyleId,
    root: TexStyle,

    pub fn init(engine: *const Engine, e: *const Expr, outer: []const StyleId) Resolver {
        var r: Resolver = .{ .e = e, .engine = engine, .outer = outer, .root = .text };
        // The expression's own style, from the cascade at its root.
        const ms = param.as(param.MathStyle, r.resolveIn(contextOf(e, e.root, .text), .math_style).value);
        r.root = switch (ms) {
            .display => .display,
            .text => .text,
        };
        return r;
    }

    pub fn context(r: *const Resolver, id: Id) Context {
        return derive(r.e, id, r.root, r);
    }

    pub fn resolve(r: *const Resolver, id: Id, p: Param) Resolved {
        return r.resolveIn(r.context(id), p);
    }

    pub fn get(r: *const Resolver, id: Id, p: Param) Value {
        return r.resolve(id, p).value;
    }

    /// The style contexts reaching `id`, innermost first, into `buf`.
    fn chain(r: *const Resolver, id: Id, buf: []StyleId) []StyleId {
        var n: usize = 0;
        var cur = id;
        while (cur != .none) {
            const node = r.e.node(cur);
            if (node.style != .none and n < buf.len) {
                buf[n] = node.style;
                n += 1;
            }
            cur = node.parent;
        }
        var k = r.outer.len;
        while (k > 0 and n < buf.len) {
            k -= 1;
            if (r.outer[k] == .none) continue;
            buf[n] = r.outer[k];
            n += 1;
        }
        return buf[0..n];
    }

    fn resolveIn(r: *const Resolver, c: Context, p: Param) Resolved {
        if (param.def(p).element) if (r.e.override(c.id, p)) |v| return .{ .value = v, .from = .element };
        var buf: [32]StyleId = undefined;
        for (r.chain(c.id, &buf)) |applied| {
            var sid = applied;
            var depth: usize = 0;
            while (sid != .none and depth < 32) : (depth += 1) {
                const st = r.engine.style(sid);
                if (best(st.rules.items, p, c)) |k| return .{ .value = st.rules.items[k].value, .from = .style, .style = sid, .rule = k };
                sid = st.base;
            }
        }
        return .{ .value = param.def(p).default, .from = .default };
    }

    /// The faces reaching `id`: by role, the innermost context naming
    /// each, in that order (the fallback order), from `a`.
    pub fn faces(r: *const Resolver, a: Allocator, id: Id) Allocator.Error!faces_mod.FaceSet {
        var out: std.ArrayList(faces_mod.Member) = .empty;
        var buf: [32]StyleId = undefined;
        for (r.chain(id, &buf)) |applied| {
            var sid = applied;
            var depth: usize = 0;
            while (sid != .none and depth < 32) : (depth += 1) {
                const st = r.engine.style(sid);
                for (st.faces.items) |m| {
                    const have = for (out.items) |o| {
                        if (std.mem.eql(u8, o.name, m.name)) break true;
                    } else false;
                    if (!have) try out.append(a, m);
                }
                sid = st.base;
            }
        }
        // The text face first: the fallback starts there.
        for (out.items, 0..) |m, k| if (std.mem.eql(u8, m.name, "text") and k > 0) {
            std.mem.swap(faces_mod.Member, &out.items[0], &out.items[k]);
            break;
        };
        return .{ .members = out.items };
    }
};
