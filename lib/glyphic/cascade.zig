//! Where a parameter's value comes from. Levels, lowest first: the
//! parameter's default (the font defaults), the package, the style, the
//! legend (the expression's own rules), the object itself. A later level
//! wins. Within a level, rules may be general or for objects of a kind
//! (by kind, role, script level, symbol, slot): the most specific
//! matching rule wins, and of equals the later one.
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

// Context ------------------------------------------------------------------------

/// TeX's math styles.
pub const Style = enum {
    display,
    text,
    script,
    scriptscript,

    /// 0 in display and text style, 1 in script, 2 in scriptscript.
    pub fn scriptLevel(s: Style) u2 {
        return switch (s) {
            .display, .text => 0,
            .script => 1,
            .scriptscript => 2,
        };
    }

    /// The style a fraction's numerator or denominator is set in.
    fn fractionPart(s: Style) Style {
        return switch (s) {
            .display => .text,
            .text => .script,
            .script, .scriptscript => .scriptscript,
        };
    }

    /// The style a script or a limit is set in.
    fn scriptPart(s: Style) Style {
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
    style: Style,
    /// Set lower (denominators, subscripts, radicands), as TeX does.
    cramped: bool,
    script_level: u2,
};

/// The context of `id`, the expression set in `root` style.
pub fn contextOf(e: *const Expr, id: Id, root: Style) Context {
    // The structures above, innermost first.
    var path: [64]struct { kind: Kind, slot: Slot } = undefined;
    var n: usize = 0;
    var cur = id;
    while (e.holder(cur)) |h| {
        if (n < path.len) {
            path[n] = .{ .kind = e.node(h.structure).kind, .slot = h.slot };
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
                style = style.fractionPart();
                if (p.slot == .den) cramped = true;
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

pub const Level = enum { font, package, style, legend, object };

/// The package's and the style's rules (the legend's are the expression's
/// own, the object's on the object).
pub const Sheets = struct {
    package: []const Rule = &.{},
    style: []const Rule = &.{},
};

/// A resolved value and where it came from, for inspection.
pub const Resolved = struct {
    value: Value,
    level: Level,
    /// The rule that set it, within its level.
    rule: ?usize = null,
};

/// The winning rule of one level for `p` in context `c`.
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

/// Resolves parameters for one expression under a package and a style.
pub const Resolver = struct {
    e: *const Expr,
    sheets: Sheets,
    root: Style,

    pub fn init(e: *const Expr, sheets: Sheets) Resolver {
        var r: Resolver = .{ .e = e, .sheets = sheets, .root = .text };
        // The expression's own style, from the cascade at its root.
        const ms = param.as(param.MathStyle, r.resolveIn(contextOf(e, e.root, .text), .math_style).value);
        r.root = switch (ms) {
            .display => .display,
            .text => .text,
        };
        return r;
    }

    pub fn context(r: *const Resolver, id: Id) Context {
        return contextOf(r.e, id, r.root);
    }

    pub fn resolve(r: *const Resolver, id: Id, p: Param) Resolved {
        return r.resolveIn(r.context(id), p);
    }

    pub fn get(r: *const Resolver, id: Id, p: Param) Value {
        return r.resolve(id, p).value;
    }

    fn resolveIn(r: *const Resolver, c: Context, p: Param) Resolved {
        if (r.e.override(c.id, p)) |v| return .{ .value = v, .level = .object };
        const levels = [_]struct { level: Level, rules: []const Rule }{
            .{ .level = .legend, .rules = r.e.legend.items },
            .{ .level = .style, .rules = r.sheets.style },
            .{ .level = .package, .rules = r.sheets.package },
        };
        for (levels) |l| if (best(l.rules, p, c)) |k| return .{ .value = l.rules[k].value, .level = l.level, .rule = k };
        return .{ .value = param.def(p).default, .level = .font };
    }
};
