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
    script_gap: f64 = 0.05,
};

pub const default_script_scale = 0.7;
pub const default_sup_raise = 0.55;
pub const default_sub_drop = 0.25;

pub const Context = struct {
    faces: []const *Face,
    spec: Spec,
    script_scale: f64,
    sup_raise: f64,
    sub_drop: f64,

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
