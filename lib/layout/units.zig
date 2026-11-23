//! Units for property values (decided 2026-11-23, the owner): one path for
//! every value a person types with a unit. A quantity is kept as typed (its
//! value, its unit, and whether it is relative to a reference) and turned
//! into Graven's base units (mm for lengths, degrees for angles) when it is
//! needed, not once on entry. Every field that takes a length or an angle
//! reads it here, so every such field takes every unit of its kind; a new
//! unit is one entry in `table`.
//!
//! Units supported (docs/units.md):
//! - lengths: mm, cm, in (also ″ and "), pt (1/72 in), pc (pica, 12 pt);
//! - relative lengths, where the property has a reference (a text
//!   spacing's is its font size): "+2pt" or "-1mm" (added to it), "+10%"
//!   (added as a share of it), "120%" (a share of it);
//! - angles: deg (also °).
//! A bare number is in the field's own unit (the one its label names).

const std = @import("std");

pub const Dimension = enum { length, angle };

pub const Unit = enum {
    mm,
    cm,
    in,
    pt,
    pc,
    percent,
    deg,

    pub fn def(u: Unit) UnitDef {
        for (table) |d| if (d.unit == u) return d;
        unreachable;
    }
    /// How it is written after a number.
    pub fn symbol(u: Unit) []const u8 {
        return u.def().symbols[0];
    }
};

pub const UnitDef = struct {
    unit: Unit,
    /// `null` for a share of the reference (percent), which is of any
    /// dimension.
    dimension: ?Dimension,
    /// What it may be typed as (the first is how it is written).
    symbols: []const []const u8,
    /// Base units (mm, degrees) in one of it; for a share, the reference
    /// in one: 1/100.
    base: f64,
};

pub const mm_per_in = 25.4;
pub const mm_per_pt = mm_per_in / 72.0;

/// Every unit Graven reads. Add one here and every field of its dimension
/// takes it.
pub const table = [_]UnitDef{
    .{ .unit = .mm, .dimension = .length, .symbols = &.{"mm"}, .base = 1 },
    .{ .unit = .cm, .dimension = .length, .symbols = &.{"cm"}, .base = 10 },
    .{ .unit = .in, .dimension = .length, .symbols = &.{ "in", "″", "\"" }, .base = mm_per_in },
    .{ .unit = .pt, .dimension = .length, .symbols = &.{"pt"}, .base = mm_per_pt },
    .{ .unit = .pc, .dimension = .length, .symbols = &.{"pc"}, .base = 12 * mm_per_pt },
    .{ .unit = .percent, .dimension = null, .symbols = &.{"%"}, .base = 0.01 },
    .{ .unit = .deg, .dimension = .angle, .symbols = &.{ "deg", "°" }, .base = 1 },
};

/// The unit a field's label names after its comma ("Width, mm" → mm), if
/// one in `table` is.
pub fn ofLabel(label: []const u8) ?Unit {
    const comma = std.mem.lastIndexOfScalar(u8, label, ',') orelse return null;
    const sym = std.mem.trim(u8, label[comma + 1 ..], " ");
    return bySymbol(sym);
}

fn bySymbol(sym: []const u8) ?Unit {
    for (table) |d| for (d.symbols) |s| if (std.ascii.eqlIgnoreCase(s, sym)) return d.unit;
    return null;
}

/// A value as typed: an amount in a unit, absolute or relative to the
/// property's reference (a sign typed in front).
pub const Quantity = struct {
    value: f64,
    unit: Unit,
    /// Added to the reference: typed with a sign.
    relative: bool = false,

    /// Reads "12", "12pt", "+2 pt", "-1mm", "+10%", "120%", "1.5in",
    /// "45°". A bare number is in `default`. Null when it does not read
    /// as one, or its unit is of another dimension than `default`'s.
    pub fn parse(text: []const u8, default: Unit) ?Quantity {
        var t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return null;
        const relative = t[0] == '+' or t[0] == '-';
        var unit = default;
        // The longest symbol at the end names the unit.
        var best: usize = 0;
        for (table) |d| for (d.symbols) |s| {
            if (s.len > best and t.len > s.len and std.ascii.endsWithIgnoreCase(t, s)) {
                best = s.len;
                unit = d.unit;
            }
        };
        t = std.mem.trim(u8, t[0 .. t.len - best], " \t");
        const v = std.fmt.parseFloat(f64, t) catch return null;
        if (!std.math.isFinite(v)) return null;
        const dim = unit.def().dimension;
        if (dim != null and dim != default.def().dimension) return null;
        return .{ .value = v, .unit = unit, .relative = relative };
    }

    /// Whether it needs the property's reference to be resolved.
    pub fn needsReference(q: Quantity) bool {
        return q.relative or q.unit == .percent;
    }

    /// In base units (mm, degrees), against `reference` (base units) for a
    /// relative or percent value; null when it needs one and there is
    /// none.
    pub fn resolve(q: Quantity, reference: ?f64) ?f64 {
        const d = q.unit.def();
        const amount = if (d.dimension == null) (reference orelse return null) * q.value * d.base else q.value * d.base;
        if (q.relative) return (reference orelse return null) + amount;
        return amount;
    }

    /// As typed: "+2pt", "12pt", "120%", "25.4mm".
    pub fn format(q: Quantity, buf: []u8) []const u8 {
        const sign: []const u8 = if (q.relative and q.value >= 0) "+" else "";
        return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ sign, q.value, q.unit.symbol() }) catch "?";
    }
};

/// `base` (mm, degrees) in `unit`.
pub fn fromBase(base: f64, unit: Unit) f64 {
    return base / unit.def().base;
}

test "quantities: units, relative values and shares" {
    const em = 10 * mm_per_pt;
    const t = std.testing;
    try t.expectApproxEqAbs(12 * mm_per_pt, Quantity.parse("12pt", .mm).?.resolve(null).?, 1e-12);
    try t.expectApproxEqAbs(12 * mm_per_pt, Quantity.parse("+2pt", .mm).?.resolve(em).?, 1e-12);
    try t.expectApproxEqAbs(em + 3, Quantity.parse("+3 mm", .pt).?.resolve(em).?, 1e-12);
    try t.expectApproxEqAbs(em * 1.1, Quantity.parse("+10%", .pt).?.resolve(em).?, 1e-12);
    try t.expectApproxEqAbs(em * 1.2, Quantity.parse("120%", .pt).?.resolve(em).?, 1e-12);
    try t.expectApproxEqAbs(25.4, Quantity.parse("1in", .mm).?.resolve(null).?, 1e-12);
    try t.expectApproxEqAbs(25.4, Quantity.parse("1\"", .mm).?.resolve(null).?, 1e-12);
    try t.expectApproxEqAbs(4 * mm_per_pt * 12, Quantity.parse("4pc", .mm).?.resolve(null).?, 1e-12);
    try t.expectApproxEqAbs(7, Quantity.parse("7", .mm).?.resolve(null).?, 1e-12);
    try t.expectApproxEqAbs(45, Quantity.parse("45°", .deg).?.resolve(null).?, 1e-12);
    // No reference: a relative value cannot be resolved.
    try t.expect(Quantity.parse("+2pt", .mm).?.resolve(null) == null);
    // A length is not an angle.
    try t.expect(Quantity.parse("3mm", .deg) == null);
    try t.expect(Quantity.parse("abc", .mm) == null);
    try t.expectEqual(Unit.mm, ofLabel("Width, mm").?);
    try t.expectEqual(Unit.deg, ofLabel("Angle, °").?);
    try t.expect(ofLabel("Rows") == null);
}
