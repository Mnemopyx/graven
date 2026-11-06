//! The style context: a resolved, immutable style, built once and reused for
//! every label that shares it.
//!
//! This first version holds the faces, size and script settings. Style
//! inheritance, families with weights and the per-pairing adjustments from
//! typeface definitions come later; they resolve into this same value.

const std = @import("std");
const hb = @import("hb");
const font = @import("graven_font");
const render = @import("render.zig");

const Face = font.Face;
const FaceId = render.FaceId;

/// How letters without an explicit variant look.
pub const Letters = enum { upright, italic };

pub const Spec = struct {
    upright: FaceId,
    /// The family's italic; letters asked to be italic fall back to upright
    /// (and are reported) when there is none.
    italic: ?FaceId = null,
    /// Tried in order for clusters the chosen face lacks.
    fallbacks: []const FaceId = &.{},
    /// Size as cap height, mm.
    cap_height: f64,
    letters: Letters = .upright,
    /// Scripts' size relative to their base; null for the upright face's
    /// MATH table (ScriptPercentScaleDown), or 0.7 without one.
    script_scale: ?f64 = null,
    /// Superscript baseline raise and subscript baseline drop, as fractions
    /// of the base's cap height; null for the MATH table or the defaults.
    sup_raise: ?f64 = null,
    sub_drop: ?f64 = null,
    /// Space between a base and its scripts, as a fraction of cap height.
    script_gap: f64 = 0.08,
    /// Space between atoms by their classes, in mu (1/18 of the upright
    /// face's em). Inside scripts only operator spacing applies.
    spacing: Spacing = .{},
    /// How \bar is drawn: a rule over the ink, or a combining macron on a
    /// single character when the face has one.
    bar: enum { rule, combining } = .rule,
    /// Clearance between a body's ink and an accent or overbar, and the
    /// overbar's thickness, as fractions of cap height; null for the upright
    /// face's MATH table (OverbarVerticalGap, OverbarRuleThickness), or 0.1
    /// and 0.08 without one.
    accent_gap: ?f64 = null,
    rule_thickness: ?f64 = null,
    /// How neighbours are placed: by their ink (contact profiles), or by the
    /// fonts' advances. Hand spacing (a literal or explicit space) always
    /// keeps advances.
    contact: enum { ink, advance } = .ink,
    /// The ink-to-ink gap between neighbouring atoms, before any operator
    /// spacing, as a fraction of cap height. (Scripts use script_gap.)
    contact_gap: f64 = 0.12,
    /// How far up and down a neighbour's ink still counts when measuring
    /// clearance, as a fraction of cap height: concavities narrower than
    /// about twice this are bridged, so nothing tucks into the middle of a
    /// Sigma, while ink further away (a raised superscript) can still be
    /// tucked under.
    contact_reach: f64 = 0.25,
    /// Contact profile band height, as a fraction of cap height: the
    /// placement tolerance.
    contact_band: f64 = 0.02,
};

/// Automatic space beside operators, in mu. Tighter than TeX's 3, 4, 5 and 3
/// by default, so legends read as one shape; set TeX's values for typeset math.
pub const Spacing = struct {
    /// Beside operator names (\ln) and large operators.
    operator: f64 = 3,
    /// Beside binary operators (+, ×).
    binary: f64 = 2,
    /// Beside relations (=, \to).
    relation: f64 = 3,
    /// After punctuation (, ;).
    punctuation: f64 = 0,
};

pub const default_script_scale = 0.7;
pub const default_sup_raise = 0.55;
pub const default_sub_drop = 0.25;
pub const default_accent_gap = 0.1;
pub const default_rule_thickness = 0.08;

pub const Context = struct {
    faces: []const *Face,
    spec: Spec,
    script_scale: f64,
    sup_raise: f64,
    sub_drop: f64,
    accent_gap: f64,
    rule_thickness: f64,

    pub const Error = font.Error || error{ NoCapHeight, InvalidSize };

    /// Resolves `spec` against `faces`, which must outlive the context.
    pub fn init(faces: []const *Face, spec: Spec) Error!Context {
        if (!(spec.cap_height > 0)) return error.InvalidSize;
        const main = faces[spec.upright];
        const cap = (try main.capHeight()) orelse return error.NoCapHeight;
        const has_math = hb.hb_ot_math_has_data(main.face) != 0;
        const k = struct {
            fn constant(f: *Face, c: hb.hb_ot_math_constant_t) f64 {
                return @floatFromInt(hb.hb_ot_math_get_constant(f.font, c));
            }
        };
        return .{
            .faces = faces,
            .spec = spec,
            .script_scale = spec.script_scale orelse if (has_math)
                k.constant(main, hb.HB_OT_MATH_CONSTANT_SCRIPT_PERCENT_SCALE_DOWN) / 100
            else
                default_script_scale,
            .sup_raise = spec.sup_raise orelse if (has_math)
                k.constant(main, hb.HB_OT_MATH_CONSTANT_SUPERSCRIPT_SHIFT_UP) / cap
            else
                default_sup_raise,
            .sub_drop = spec.sub_drop orelse if (has_math)
                k.constant(main, hb.HB_OT_MATH_CONSTANT_SUBSCRIPT_SHIFT_DOWN) / cap
            else
                default_sub_drop,
            .accent_gap = spec.accent_gap orelse if (has_math)
                k.constant(main, hb.HB_OT_MATH_CONSTANT_OVERBAR_VERTICAL_GAP) / cap
            else
                default_accent_gap,
            .rule_thickness = spec.rule_thickness orelse if (has_math)
                k.constant(main, hb.HB_OT_MATH_CONSTANT_OVERBAR_RULE_THICKNESS) / cap
            else
                default_rule_thickness,
        };
    }

    /// mm per font unit for `face` at cap height `cap_mm`: its measured cap
    /// height is matched to the main face's. A face with no H (a symbol
    /// font) is matched by em instead.
    pub fn scaleFor(c: *const Context, face: FaceId, cap_mm: f64) font.Error!f64 {
        const f = c.faces[face];
        if (try f.capHeight()) |units| return cap_mm / units;
        const main = c.faces[c.spec.upright];
        const main_cap = (try main.capHeight()).?;
        const em_mm = cap_mm / main_cap * @as(f64, @floatFromInt(main.upem));
        return em_mm / @as(f64, @floatFromInt(f.upem));
    }

    /// The upright face's em at cap height `cap_mm`, for math spaces (mu).
    pub fn em(c: *const Context, cap_mm: f64) font.Error!f64 {
        const main = c.faces[c.spec.upright];
        return (try c.scaleFor(c.spec.upright, cap_mm)) * @as(f64, @floatFromInt(main.upem));
    }
};
