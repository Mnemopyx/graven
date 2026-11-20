//! Typed parameters: every decision the engine makes about how an object
//! looks or where it goes is a parameter with a type, a unit, a range, a
//! description and a default. The default is the bottom of the cascade
//! (the "font defaults" level); packages, styles, legends and objects set
//! values above it (cascade.zig).

const std = @import("std");

/// What a number is measured in.
pub const Unit = enum {
    /// A fraction of the cap height of the text the object sits in.
    cap,
    /// A multiplier.
    scale,
    degrees,
    /// Whole steps (a size variant, a delimiter size).
    steps,
    /// A line-breaking cost: higher is worse.
    cost,
    none,
};

pub const Type = enum { number, choice, flag, name };

/// A parameter's value. A choice is an index into the parameter's choices.
pub const Value = union(Type) {
    number: f32,
    choice: u8,
    flag: bool,
    name: []const u8,

    pub fn eql(a: Value, b: Value) bool {
        if (@as(Type, a) != @as(Type, b)) return false;
        return switch (a) {
            .number => |x| x == b.number,
            .choice => |x| x == b.choice,
            .flag => |x| x == b.flag,
            .name => |x| std.mem.eql(u8, x, b.name),
        };
    }
};

/// A parameter's definition.
pub const Def = struct {
    type: Type,
    unit: Unit = .none,
    /// The range of a number, both ends included.
    min: f32 = 0,
    max: f32 = 0,
    /// A choice's names, in order.
    choices: []const []const u8 = &.{},
    default: Value,
    /// What it decides, in a sentence (shown by the inspector).
    doc: []const u8,
    /// Whether an element may override it. Style contexts set every
    /// parameter; an element only its relative scale and placement and the
    /// structural choices its head offers.
    element: bool = false,
};

fn el(d: Def) Def {
    var x = d;
    x.element = true;
    return x;
}

// Choices, as Zig enums for code and as names for the schema. A choice
// value is the enum's integer.

pub const Shape = enum { upright, italic };
pub const BreakMark = enum { auto, forbid, allow, prefer, force };
pub const OperatorAtBreak = enum { end, start, both };
pub const Continuation = enum { own, indent, relation };
/// An optional slot: shown when it exists (auto), or set shown or hidden.
/// Hidden keeps its contents on the object.
pub const SlotShow = enum { auto, shown, hidden };
pub const Limits = enum { auto, stacked, side };
pub const OpSize = enum { auto, text, display };
pub const FractionForm = enum { stacked, slashed, diagonal };
pub const FenceSize = enum { natural, grown, step };
pub const MathStyle = enum { display, text };
/// What a rotated object turns about.
pub const Pivot = enum { centre, ink_centre, start, baseline_start };
/// Whether a rotated object takes its rotated extent in its row.
pub const RotateSpace = enum { box, none };

fn names(comptime E: type) []const []const u8 {
    const fields = @typeInfo(E).@"enum".field_names;
    const out = comptime blk: {
        var n: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| n[i] = f;
        break :blk n;
    };
    return &out;
}

fn choice(comptime E: type, comptime default: E, comptime doc: []const u8) Def {
    return .{ .type = .choice, .choices = names(E), .default = .{ .choice = @intFromEnum(default) }, .doc = doc };
}

fn number(unit: Unit, min: f32, max: f32, default: f32, doc: []const u8) Def {
    return .{ .type = .number, .unit = unit, .min = min, .max = max, .default = .{ .number = default }, .doc = doc };
}

/// Every parameter. Grouped by what they act on; any object may carry any
/// of them, and those its kind does not use are ignored.
pub const Param = enum {
    // Any glyph or head.
    scale,
    shift_x,
    shift_y,
    // Its gap to the object before it in its row, added to the spacing its
    // kinds give; what follows moves with it.
    space_before,
    weight,
    slant,
    shape,
    face,
    // Rotation relative to the parent's frame (the ground's path frame
    // comes on top, at layout).
    rotate,
    rotate_pivot,
    rotate_space,
    // Spacing between neighbours, by their kinds (TeX's three spaces).
    thin_space,
    medium_space,
    thick_space,
    // Columns.
    column_step,
    column_space,
    // Breaking.
    break_before,
    relation_break_cost,
    binary_break_cost,
    space_break_cost,
    hyphen_break_cost,
    operator_at_break,
    continuation,
    // Scripts and limits.
    script_scale,
    scriptscript_scale,
    sup_raise,
    sub_drop,
    show_sub,
    show_sup,
    limits,
    op_size,
    display_op_scale,
    limit_gap,
    // Fractions.
    fraction_form,
    rule_thickness,
    rule_overhang,
    num_gap,
    den_gap,
    // Radicals.
    show_index,
    radical_gap,
    radical_rule,
    // Fences and accents.
    fence_size,
    fence_step,
    fence_gap,
    accent_raise,
    // The expression as a whole.
    math_style,
};

pub const defs: std.enums.EnumArray(Param, Def) = .init(.{
    .scale = el(number(.scale, 0.1, 10, 1, "Size, relative to what its place in the structure gives it.")),
    .shift_x = el(number(.cap, -4, 4, 0, "Moved right (negative: left).")),
    .shift_y = el(number(.cap, -4, 4, 0, "Moved up (negative: down).")),
    .space_before = el(number(.cap, -4, 4, 0, "Further from the object before it (negative: closer); what follows moves with it. First on a line: the line moves.")),
    .weight = number(.cap, -0.1, 0.25, 0, "Strokes grown by this in all (half on each side); negative thins them."),
    .slant = number(.degrees, -30, 30, 0, "Leaned right by this angle (negative: left), on top of its face's own slant."),
    .shape = choice(Shape, .upright, "Upright or italic."),
    .rotate = el(number(.degrees, -180, 180, 0, "Turned by this angle (anticlockwise) relative to what holds it; on a curved track it turns with the path.")),
    .rotate_pivot = el(choice(Pivot, .ink_centre, "What it turns about: its box's centre, its ink's centre, its start, or where its baseline starts.")),
    .rotate_space = el(choice(RotateSpace, .box, "Whether its neighbours make room for its rotated extent, or it turns in its unrotated place.")),
    .face = .{ .type = .name, .default = .{ .name = "" }, .doc = "The composed font member that sets it (empty: the one its kind and style choose)." },
    .thin_space = number(.cap, 0, 2, 0.24, "The thin space: after a large operator, around punctuation."),
    .medium_space = number(.cap, 0, 2, 0.32, "The medium space: around a binary operator (not in scripts)."),
    .thick_space = number(.cap, 0, 2, 0.40, "The thick space: around a relation (not in scripts)."),
    .column_step = number(.cap, 0.5, 5, 1.5, "In a column, how far down each character is from the one before (a taller object takes more)."),
    .column_space = number(.cap, 0, 5, 0.5, "In a column, how far down a space between words goes."),
    .break_before = el(choice(BreakMark, .auto, "Whether the line may break before it: as its neighbours' kinds decide, never, allowed, preferred, or always.")),
    .relation_break_cost = number(.cost, 0, 10000, 500, "What a break after a relation costs."),
    .binary_break_cost = number(.cost, 0, 10000, 700, "What a break after a binary operator costs."),
    .space_break_cost = number(.cost, 0, 10000, 50, "What a break at a space between words costs."),
    .hyphen_break_cost = number(.cost, 0, 10000, 300, "What a break at a soft hyphen costs (the line then ends with a hyphen)."),
    .operator_at_break = choice(OperatorAtBreak, .end, "Where the operator goes at a break: ending the line, starting the next, or both."),
    .continuation = choice(Continuation, .relation, "How a continued piece lines up: as its segment aligns, indented, or under the first relation (when both pieces share a column; with no relation, as its segment aligns)."),
    .script_scale = number(.scale, 0.3, 1, 0.7, "Size of a first-level script or limit, relative to its base."),
    .scriptscript_scale = number(.scale, 0.3, 1, 0.5, "Size of a second-level script, relative to text."),
    .sup_raise = number(.cap, 0, 2, 0.5, "How far a superscript's baseline sits above its base's."),
    .sub_drop = number(.cap, 0, 2, 0.24, "How far a subscript's baseline sits below its base's."),
    .show_sub = el(choice(SlotShow, .auto, "The subscript or lower limit: shown when it exists, or set shown or hidden.")),
    .show_sup = el(choice(SlotShow, .auto, "The superscript or upper limit: shown when it exists, or set shown or hidden.")),
    .limits = el(choice(Limits, .auto, "A large operator's limits: above and below, or beside (auto: above and below in display style).")),
    .op_size = el(choice(OpSize, .auto, "A large operator's size variant (auto: display size in display style).")),
    .display_op_scale = number(.scale, 1, 3, 1.5, "How much larger a large operator is set in display size."),
    .limit_gap = number(.cap, 0, 2, 0.15, "Gap between a large operator and its stacked limits."),
    .fraction_form = el(choice(FractionForm, .stacked, "Numerator over denominator, with a slash between, or on a diagonal.")),
    .rule_thickness = number(.cap, 0, 0.5, 0.06, "Thickness of a fraction's rule."),
    .rule_overhang = number(.cap, 0, 1, 0.05, "How far a fraction's rule reaches past the wider of its parts."),
    .num_gap = number(.cap, 0, 2, 0.15, "Gap between a numerator and the rule."),
    .den_gap = number(.cap, 0, 2, 0.15, "Gap between the rule and a denominator."),
    .show_index = el(choice(SlotShow, .auto, "A radical's index: shown when it exists, or set shown or hidden.")),
    .radical_gap = number(.cap, 0, 1, 0.12, "Gap between a radical's bar and what it covers."),
    .radical_rule = number(.cap, 0, 0.5, 0.06, "Thickness of a radical's bar."),
    .fence_size = el(choice(FenceSize, .grown, "Delimiters at their natural size, grown to what they hold, or at a set step.")),
    .fence_step = el(number(.steps, 0, 4, 0, "The size step of delimiters set to a step.")),
    .fence_gap = number(.cap, 0, 1, 0, "Gap inside each delimiter."),
    .accent_raise = number(.cap, -1, 1, 0, "An accent moved up from where it sits on its base."),
    .math_style = choice(MathStyle, .text, "The expression set in display style (large operators, stacked limits) or text style."),
});

pub fn def(p: Param) Def {
    return defs.get(p);
}

pub const Error = error{ WrongType, OutOfRange, NoSuchChoice };

/// Whether `v` is a value `p` can take.
pub fn check(p: Param, v: Value) Error!void {
    const d = def(p);
    if (@as(Type, v) != d.type) return error.WrongType;
    switch (v) {
        .number => |x| if (!(x >= d.min and x <= d.max)) return error.OutOfRange,
        .choice => |c| if (c >= d.choices.len) return error.NoSuchChoice,
        .flag, .name => {},
    }
}

/// A choice value from its name.
pub fn choiceNamed(p: Param, name: []const u8) ?Value {
    for (def(p).choices, 0..) |c, i| if (std.mem.eql(u8, c, name)) return .{ .choice = @intCast(i) };
    return null;
}

/// A choice value as its Zig enum.
pub fn as(comptime E: type, v: Value) E {
    return @enumFromInt(v.choice);
}

/// A Zig enum as a choice value.
pub fn of(e: anytype) Value {
    return .{ .choice = @intFromEnum(e) };
}

pub fn num(x: f32) Value {
    return .{ .number = x };
}

const testing = std.testing;

test "every default is a value its parameter takes, with a description" {
    for (std.enums.values(Param)) |p| {
        try check(p, def(p).default);
        try testing.expect(def(p).doc.len > 0);
    }
}

test "values are checked against type, range and choices" {
    try check(.scale, num(1.2));
    try testing.expectError(error.OutOfRange, check(.scale, num(20)));
    try testing.expectError(error.OutOfRange, check(.scale, num(std.math.nan(f32))));
    try testing.expectError(error.WrongType, check(.scale, of(Shape.italic)));
    try testing.expectError(error.NoSuchChoice, check(.shape, .{ .choice = 9 }));
    try testing.expect(choiceNamed(.fraction_form, "slashed").?.eql(of(FractionForm.slashed)));
    try testing.expectEqual(FractionForm.diagonal, as(FractionForm, choiceNamed(.fraction_form, "diagonal").?));
    try testing.expectEqual(null, choiceNamed(.fraction_form, "sideways"));
}
