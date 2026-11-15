//! The style context: a resolved, immutable style, built once and reused for
//! every label that shares it.
//!
//! It holds the faces (a composed font: a main face and its members), size
//! and script settings. Style inheritance and families with weights come
//! later; they resolve into this same value.

const std = @import("std");
const hb = @import("hb");
const font = @import("graven_font");
const render = @import("render.zig");

const Face = font.Face;

/// Whether `face` has a glyph for every codepoint of `cluster` (joiners and
/// variation selectors aside).
pub fn covers(face: *Face, cluster: []const u8) bool {
    var it = (std.unicode.Utf8View.initUnchecked(cluster)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF)) continue;
        if (face.glyph(cp) == null) return false;
    }
    return true;
}

const FaceId = render.FaceId;
pub const Alphabet = @import("markup.zig").Alphabet;

/// What a cluster asks of the composed font: its slant, its weight, its
/// alphabet (\mathbb …).
pub const Want = struct {
    italic: bool = false,
    bold: bool = false,
    alphabet: Alphabet = .normal,
    /// In math (not \text, not an operator's name): a member for variables
    /// sets its italic letters.
    math: bool = false,
};

/// A family's faces by weight and slant. Missing ones fall back: bold
/// italic to bold, then italic; bold and italic to upright.
pub const Variants = struct {
    upright: FaceId,
    italic: ?FaceId = null,
    bold: ?FaceId = null,
    bold_italic: ?FaceId = null,

    /// The face for `want`'s weight and slant, after fallbacks.
    pub fn pick(v: Variants, want: Want) FaceId {
        if (want.bold and want.italic) if (v.bold_italic) |f| return f;
        if (want.bold) if (v.bold) |f| return f;
        if (want.italic) if (v.italic) |f| return f;
        return v.upright;
    }

    pub fn has(v: Variants, face: FaceId) bool {
        return face == v.upright or v.italic == face or v.bold == face or v.bold_italic == face;
    }

    /// Whether `face` is one of the bold faces.
    pub fn isBold(v: Variants, face: FaceId) bool {
        return v.bold == face or v.bold_italic == face;
    }
};

/// How letters without an explicit variant look.
pub const Letters = enum { upright, italic };

/// How a member face is sized against the main face: by matching its
/// measured cap height or x-height to the main face's, or its em.
pub const Match = enum { cap_height, x_height, em };

/// A range of codepoints, both ends included.
pub const Range = struct {
    first: u21,
    last: u21,

    pub fn has(r: Range, cp: u21) bool {
        return cp >= r.first and cp <= r.last;
    }
};

/// Which characters a member sets.
pub const Coverage = union(enum) {
    /// What the faces before it lack: a fallback.
    fallback,
    /// These codepoints, even where the main face has them (Greek from a
    /// face whose Greek suits better).
    ranges: []const Range,

    pub fn has(c: Coverage, cp: u21) bool {
        return switch (c) {
            .fallback => false,
            .ranges => |rs| for (rs) |r| {
                if (r.has(cp)) break true;
            } else false,
        };
    }
};

/// One face of a composed font besides the main one, and how it is set
/// beside it.
pub const Member = struct {
    upright: FaceId,
    /// Its italic, for letters asked to be italic; else its upright.
    italic: ?FaceId = null,
    bold: ?FaceId = null,
    bold_italic: ?FaceId = null,
    /// The alphabet it sets from ordinary letters (a blackboard face for
    /// \mathbb). Such a member is only used for that alphabet.
    alphabet: Alphabet = .normal,
    coverage: Coverage = .fallback,
    match: Match = .cap_height,
    /// A further size factor after matching.
    scale: f64 = 1,
    /// Baseline shift, a fraction of the cap height, up positive.
    shift: f64 = 0,
    /// What it sets: characters (by its coverage), or variables: the
    /// italic letters of math, from its upright face (a bold italic face
    /// drawn as variables, say), and nothing else.
    role: Role = .characters,

    pub const Role = enum { characters, variables };

    pub fn variants(m: Member) Variants {
        return .{ .upright = m.upright, .italic = m.italic, .bold = m.bold, .bold_italic = m.bold_italic };
    }
};

pub const Spec = struct {
    upright: FaceId,
    /// The family's italic; letters asked to be italic fall back to upright
    /// (and are reported) when there is none.
    italic: ?FaceId = null,
    /// Its bold and bold italic, for \textbf and \mathbf; bold falls back
    /// to the upright weight (and is reported) when there is none.
    bold: ?FaceId = null,
    bold_italic: ?FaceId = null,
    /// The composed font's other faces, in order: members with explicit
    /// coverage take their characters first; fallbacks are tried, in order,
    /// for clusters the chosen face lacks.
    members: []const Member = &.{},
    /// The math face: the one whose OpenType MATH table gives the math
    /// constants (script size and shifts, rule thickness, axis height)
    /// when it has one; null for the upright face's. A text face rarely
    /// has a MATH table: a package's math face supplies it.
    math: ?FaceId = null,
    /// Size as cap height, mm. With `em_size` set, an estimate until the
    /// context is made, which sets it from the main face.
    cap_height: f64,
    /// Size as the em, mm, as point sizes are given elsewhere (12 pt is an
    /// em of 12/72 in): the cap height then follows from the main face's
    /// own cap height and units per em. Null to size by cap height.
    em_size: ?f64 = null,
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
    /// Height of the math axis above the baseline, where fraction rules
    /// sit, as a fraction of cap height; null for the upright face's MATH
    /// table (AxisHeight), or 0.4 without one.
    axis_height: ?f64 = null,
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
    /// Baseline-to-baseline distance between lines, as a fraction of cap
    /// height; null for the upright face's ascender to descender.
    line_pitch: ?f64 = null,
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
pub const default_axis_height = 0.4;

pub const Context = struct {
    faces: []const *Face,
    spec: Spec,
    script_scale: f64,
    sup_raise: f64,
    sub_drop: f64,
    accent_gap: f64,
    rule_thickness: f64,
    axis_height: f64,

    pub const Error = font.Error || error{ NoCapHeight, InvalidSize };

    /// Resolves `spec` against `faces`, which must outlive the context.
    pub fn init(faces: []const *Face, spec_in: Spec) Error!Context {
        const main = faces[spec_in.upright];
        const cap = (try main.capHeight()) orelse return error.NoCapHeight;
        var spec = spec_in;
        if (spec_in.em_size) |em_mm| {
            if (!(em_mm > 0)) return error.InvalidSize;
            spec.cap_height = em_mm * cap / @as(f64, @floatFromInt(main.upem));
        }
        if (!(spec.cap_height > 0)) return error.InvalidSize;
        // The math constants: from the math face's MATH table if it has
        // one, else the upright face's; heights relative to that face's
        // own cap height.
        const math_face = if (spec_in.math) |m| faces[m] else main;
        const mf = if (hb.hb_ot_math_has_data(math_face.face) != 0) math_face else main;
        const has_math = hb.hb_ot_math_has_data(mf.face) != 0;
        const mcap = if (mf == main) cap else (try mf.capHeight()) orelse cap;
        const k = struct {
            fn constant(f: *Face, c: hb.hb_ot_math_constant_t) f64 {
                return @floatFromInt(hb.hb_ot_math_get_constant(f.font, c));
            }
        };
        return .{
            .faces = faces,
            .spec = spec,
            .script_scale = spec.script_scale orelse if (has_math)
                k.constant(mf, hb.HB_OT_MATH_CONSTANT_SCRIPT_PERCENT_SCALE_DOWN) / 100
            else
                default_script_scale,
            .sup_raise = spec.sup_raise orelse if (has_math)
                k.constant(mf, hb.HB_OT_MATH_CONSTANT_SUPERSCRIPT_SHIFT_UP) / mcap
            else
                default_sup_raise,
            .sub_drop = spec.sub_drop orelse if (has_math)
                k.constant(mf, hb.HB_OT_MATH_CONSTANT_SUBSCRIPT_SHIFT_DOWN) / mcap
            else
                default_sub_drop,
            .accent_gap = spec.accent_gap orelse if (has_math)
                k.constant(mf, hb.HB_OT_MATH_CONSTANT_OVERBAR_VERTICAL_GAP) / mcap
            else
                default_accent_gap,
            .rule_thickness = spec.rule_thickness orelse if (has_math)
                k.constant(mf, hb.HB_OT_MATH_CONSTANT_OVERBAR_RULE_THICKNESS) / mcap
            else
                default_rule_thickness,
            .axis_height = spec.axis_height orelse if (has_math)
                k.constant(mf, hb.HB_OT_MATH_CONSTANT_AXIS_HEIGHT) / mcap
            else
                default_axis_height,
        };
    }

    /// The member `face` belongs to, if it is a member's.
    pub fn memberOf(c: *const Context, face: FaceId) ?*const Member {
        if (c.mainVariants().has(face)) return null;
        for (c.spec.members) |*m| if (m.variants().has(face)) return m;
        return null;
    }

    /// The main family's faces.
    pub fn mainVariants(c: *const Context) Variants {
        const s = c.spec;
        return .{ .upright = s.upright, .italic = s.italic, .bold = s.bold, .bold_italic = s.bold_italic };
    }

    /// Whether `face` is a bold face of the main family or of a member.
    pub fn isBold(c: *const Context, face: FaceId) bool {
        if (c.mainVariants().isBold(face)) return true;
        for (c.spec.members) |m| if (m.variants().isBold(face)) return true;
        return false;
    }

    /// Whether a member sets `alphabet` from ordinary letters.
    pub fn hasAlphabet(c: *const Context, alphabet: Alphabet) bool {
        for (c.spec.members) |m| if (m.alphabet == alphabet) return true;
        return false;
    }

    /// Whether a member sets math's variables.
    pub fn hasVariables(c: *const Context) bool {
        for (c.spec.members) |m| if (m.role == .variables) return true;
        return false;
    }

    /// mm per font unit for `face` at cap height `cap_mm`. The main faces
    /// are sized by their measured cap height; a member is matched to the
    /// main face as it says (cap height, x-height or em), then scaled. A
    /// face without the measure asked for (a symbol font has no H) is
    /// matched by em.
    pub fn scaleFor(c: *const Context, face: FaceId, cap_mm: f64) font.Error!f64 {
        const f = c.faces[face];
        const member = c.memberOf(face);
        const match: Match = if (member) |m| m.match else .cap_height;
        const factor: f64 = if (member) |m| m.scale else 1;
        const main = c.faces[c.spec.upright];
        const main_cap = (try main.capHeight()).?;
        switch (match) {
            .cap_height => if (try f.capHeight()) |units| return factor * cap_mm / units,
            .x_height => if (try main.xHeight()) |main_x| if (try f.xHeight()) |units| {
                return factor * (cap_mm * main_x / main_cap) / units;
            },
            .em => {},
        }
        const em_mm = cap_mm / main_cap * @as(f64, @floatFromInt(main.upem));
        return factor * em_mm / @as(f64, @floatFromInt(f.upem));
    }

    /// The baseline shift for `face` at cap height `cap_mm`, mm, up.
    pub fn shiftFor(c: *const Context, face: FaceId, cap_mm: f64) f64 {
        const m = c.memberOf(face) orelse return 0;
        return m.shift * cap_mm;
    }

    /// The face to set `cluster` in: a member setting the alphabet asked
    /// for, else a member whose coverage takes it, else the main family's
    /// face for the weight and slant asked for, else the first fallback
    /// member that has it, else that main face (whose .notdef is then
    /// drawn). Null when no face has it and `strict`.
    pub fn faceFor(c: *const Context, cluster: []const u8, want: Want, strict: bool) ?FaceId {
        var it = (std.unicode.Utf8View.initUnchecked(cluster)).iterator();
        const cp = it.nextCodepoint() orelse 0;
        if (want.math and want.italic and want.alphabet == .normal) for (c.spec.members) |m| {
            if (m.role != .variables) continue;
            if (covers(c.faces[m.upright], cluster)) return m.upright;
        };
        if (want.alphabet != .normal) for (c.spec.members) |m| {
            if (m.alphabet != want.alphabet or m.role != .characters) continue;
            const f = m.variants().pick(want);
            if (covers(c.faces[f], cluster)) return f;
        };
        for (c.spec.members) |m| {
            if (m.alphabet != .normal or m.role != .characters or !m.coverage.has(cp)) continue;
            const f = m.variants().pick(want);
            if (covers(c.faces[f], cluster)) return f;
        }
        const wanted = c.mainVariants().pick(want);
        if (covers(c.faces[wanted], cluster)) return wanted;
        for (c.spec.members) |m| {
            if (m.alphabet != .normal or m.role != .characters or m.coverage != .fallback) continue;
            const f = m.variants().pick(want);
            if (covers(c.faces[f], cluster)) return f;
        }
        return if (strict) null else wanted;
    }

    /// Baseline-to-baseline distance between lines, mm.
    pub fn linePitch(c: *const Context) font.Error!f64 {
        if (c.spec.line_pitch) |f| return f * c.spec.cap_height;
        const ext = c.faces[c.spec.upright].extents();
        return (ext.ascender - ext.descender) * try c.scaleFor(c.spec.upright, c.spec.cap_height);
    }

    /// The upright face's em at cap height `cap_mm`, for math spaces (mu).
    pub fn em(c: *const Context, cap_mm: f64) font.Error!f64 {
        const main = c.faces[c.spec.upright];
        return (try c.scaleFor(c.spec.upright, cap_mm)) * @as(f64, @floatFromInt(main.upem));
    }
};
