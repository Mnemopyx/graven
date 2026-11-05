//! Rendering a label: markup, parsed, laid out in a style context, as the
//! engine's two-level geometry (render.zig).
//!
//! This version lays out one left-to-right line on the baseline: text,
//! groups, superscripts and subscripts (nested to any depth) and math
//! spaces. Accents and breaks parse but are not rendered yet; the content is
//! drawn without them and a diagnostic says so. Contact profiles, the hard
//! box, breaks and bidi come later.

const std = @import("std");
const geom = @import("graven_geom");
const font = @import("graven_font");
const render = @import("render.zig");
const style = @import("style.zig");
const markup = @import("markup.zig");
const entities = @import("entities.zig");
const shaping = @import("shape.zig");

const Allocator = std.mem.Allocator;
const Affine = geom.Affine;
const Box = geom.Box;
const FaceId = render.FaceId;
const Render = render.Render;

pub const Options = struct {
    anchor: render.Anchor = .start,
    names: *const entities.Table = &entities.Table.builtin,
};

pub const Error = style.Context.Error || markup.Error || error{InvalidTension};

/// Renders `src` in style context `ctx`. On error.Syntax, `syntax` says what
/// and where in the source.
pub fn renderLabel(gpa: Allocator, ctx: *const style.Context, src: []const u8, opts: Options, syntax: *markup.Diagnostic) Error!Render {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const tree = try markup.parseWith(a, src, opts.names, syntax);
    var b: Builder = .{ .a = a, .ctx = ctx };
    const width = try b.nodes(tree.items, ctx.spec.cap_height, 0, 0, 0);

    // The origin goes to the anchor on the baseline.
    const shift = -(try opts.anchor.offset(width));
    const move = Affine.translate(shift, 0);
    for (b.items.items) |*item| switch (item.*) {
        .glyph => |*g| g.transform = g.transform.then(move),
        .path => {},
    };
    var design: Box = .{ .x0 = shift, .y0 = 0, .x1 = shift + width, .y1 = 0 };
    var ink = Box.empty;
    for (b.elements.items) |*e| {
        e.origin.x += shift;
        e.ink = moved(e.ink, shift);
        ink = ink.join(e.ink);
        const ext = ctx.faces[e.face].extents();
        const s = try ctx.scaleFor(e.face, e.cap_height);
        design = design.join(.{
            .x0 = e.origin.x,
            .y0 = e.origin.y + ext.descender * s,
            .x1 = e.origin.x + e.advance,
            .y1 = e.origin.y + ext.ascender * s,
        });
    }

    return .{
        .arena = arena,
        .items = try b.items.toOwnedSlice(a),
        .design = design,
        .ink = ink,
        .diagnostics = try b.diagnostics.toOwnedSlice(a),
        .elements = try b.elements.toOwnedSlice(a),
    };
}

fn moved(b: Box, dx: f64) Box {
    if (b.isEmpty()) return b;
    return .{ .x0 = b.x0 + dx, .y0 = b.y0, .x1 = b.x1 + dx, .y1 = b.y1 };
}

const Builder = struct {
    a: Allocator,
    ctx: *const style.Context,
    items: std.ArrayList(render.Item) = .empty,
    elements: std.ArrayList(render.Element) = .empty,
    diagnostics: std.ArrayList(render.Diagnostic) = .empty,

    fn diagnose(b: *Builder, kind: @FieldType(render.Diagnostic, "kind"), offset: u32) !void {
        try b.diagnostics.append(b.a, .{ .kind = kind, .offset = offset });
    }

    /// Lays out `list` from pen position `x` on the baseline at `y`, at cap
    /// height `cap`; returns the pen position after it.
    fn nodes(b: *Builder, list: []const markup.Node, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        var pen = x;
        for (list) |n| pen = try b.node(n, cap, level, pen, y);
        return pen;
    }

    fn node(b: *Builder, n: markup.Node, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        switch (n) {
            .text => |t| return b.text(t, cap, level, x, y),
            .group => |g| return b.nodes(g.items, cap, level, x, y),
            .scripts => |s| {
                const base_end = try b.node(s.base.*, cap, level, x, y);
                const script_cap = cap * b.ctx.script_scale;
                const sx = base_end + b.ctx.spec.script_gap * cap;
                var end = base_end;
                if (s.sup) |sup| end = @max(end, try b.node(sup.*, script_cap, level + 1, sx, y + b.ctx.sup_raise * cap));
                if (s.sub) |sub| end = @max(end, try b.node(sub.*, script_cap, level + 1, sx, y - b.ctx.sub_drop * cap));
                return end;
            },
            .space => |sp| {
                const mu = (try b.ctx.em(cap)) / 18;
                const width: f64 = switch (sp.kind) {
                    .thin => 3,
                    .medium => 4,
                    .thick => 5,
                    .negative_thin => -3,
                    .quad => 18,
                    .qquad => 36,
                };
                return x + width * mu;
            },
            .accent => |acc| {
                try b.diagnose(.not_rendered, acc.span.start);
                return b.node(acc.body.*, cap, level, x, y);
            },
            .line_break => |br| {
                try b.diagnose(.not_rendered, br.span.start);
                return x;
            },
        }
    }

    /// Splits a text node into elements by face, cluster by cluster, then
    /// shapes and places each element.
    fn text(b: *Builder, t: markup.Text, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        var pen = x;
        var i: usize = 0;
        var run_start: usize = 0;
        var run_face: ?FaceId = null;
        while (i < t.utf8.len) {
            const end = clusterEnd(t.utf8, i);
            const face = try b.chooseFace(t, t.utf8[i..end]);
            if (run_face != null and run_face.? != face) {
                pen = try b.element(t, run_start, i, run_face.?, cap, level, pen, y);
                run_start = i;
            }
            run_face = face;
            i = end;
        }
        if (run_face) |f| pen = try b.element(t, run_start, t.utf8.len, f, cap, level, pen, y);
        return pen;
    }

    /// The face for one cluster: the one its variant asks for if that face
    /// has the whole cluster, else the first fallback that does, else the
    /// asked-for face (whose .notdef is then drawn and reported).
    fn chooseFace(b: *Builder, t: markup.Text, cluster: []const u8) Error!FaceId {
        const spec = b.ctx.spec;
        const first = firstCodepoint(cluster);
        const italic = isLetter(first) and !t.operator and switch (t.variant) {
            .italic => true,
            .default => spec.letters == .italic,
            .upright, .text => false,
        };
        var wanted = spec.upright;
        if (italic) {
            if (spec.italic) |f| wanted = f;
        }
        if (covers(b.ctx.faces[wanted], cluster)) return wanted;
        for (spec.fallbacks) |f| {
            if (covers(b.ctx.faces[f], cluster)) return f;
        }
        return wanted;
    }

    fn element(b: *Builder, t: markup.Text, start: usize, end: usize, face_id: FaceId, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        const face = b.ctx.faces[face_id];
        const s = try b.ctx.scaleFor(face_id, cap);
        const glyphs = try shaping.shape(b.a, face, t.utf8[start..end]);
        const element_id: u32 = @intCast(b.elements.items.len);

        if (b.ctx.spec.italic == null and t.variant == .italic and isLetter(firstCodepoint(t.utf8[start..end])))
            try b.diagnose(.no_italic, t.source[start]);

        var pen: f64 = 0;
        var ink = Box.empty;
        for (glyphs) |g| {
            if (g.gid == 0) try b.diagnose(.missing_glyph, t.source[start + g.cluster]);
            const gx = x + (pen + @as(f64, @floatFromInt(g.x_offset))) * s;
            const gy = y + @as(f64, @floatFromInt(g.y_offset)) * s;
            const item: render.GlyphItem = .{
                .face = face_id,
                .gid = g.gid,
                .transform = Affine.scale(s).then(Affine.translate(gx, gy)),
                .element = element_id,
            };
            ink = ink.join(try render.glyphInk(b.a, face, item));
            try b.items.append(b.a, .{ .glyph = item });
            pen += @floatFromInt(g.x_advance);
        }
        const advance = pen * s;
        try b.elements.append(b.a, .{
            .face = face_id,
            .start = t.source[start],
            .end = t.source[end - 1] + 1,
            .level = level,
            .cap_height = cap,
            .origin = .{ .x = x, .y = y },
            .advance = advance,
            .ink = ink,
        });
        return x + advance;
    }
};

/// True when `face` has a glyph for every codepoint of the cluster, ignoring
/// joiners and variation selectors, which fonts need not map.
fn covers(face: *font.Face, cluster: []const u8) bool {
    var it = (std.unicode.Utf8View.initUnchecked(cluster)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF)) continue;
        if (face.glyph(cp) == null) return false;
    }
    return true;
}

fn firstCodepoint(s: []const u8) u21 {
    var it = (std.unicode.Utf8View.initUnchecked(s)).iterator();
    return it.nextCodepoint() orelse 0;
}

/// The byte offset where the grapheme cluster starting at `i` ends.
fn clusterEnd(s: []const u8, i: usize) usize {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = i };
    _ = it.nextCodepoint();
    while (true) {
        const save = it.i;
        const cp = it.nextCodepoint() orelse return s.len;
        if (!markup.extendsCluster(cp)) return save;
    }
}

/// Latin and Greek letters: the ones a style may set italic.
fn isLetter(cp: u21) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
        (cp >= 0xC0 and cp <= 0x24F and cp != 0xD7 and cp != 0xF7) or
        (cp >= 0x370 and cp <= 0x3FF);
}

const testing = std.testing;
const testdata = @import("graven_testdata");

const Fonts = struct {
    faces: [3]*font.Face,

    fn init() !Fonts {
        var f: Fonts = undefined;
        f.faces[0] = try font.Face.init(testing.allocator, testdata.truetype, 0);
        errdefer f.faces[0].deinit();
        f.faces[1] = try font.Face.init(testing.allocator, testdata.cff, 0);
        errdefer f.faces[1].deinit();
        f.faces[2] = try font.Face.init(testing.allocator, testdata.fallback, 0);
        return f;
    }

    fn deinit(f: *Fonts) void {
        for (f.faces) |face| face.deinit();
    }
};

/// The test fonts have no MATH table, so the defaults apply: scripts at 0.7,
/// superscripts raised 0.55 cap, subscripts dropped 0.25 cap. No gap.
fn testSpec() style.Spec {
    return .{ .upright = 0, .cap_height = 7, .script_gap = 0 };
}

fn renderTest(ctx: *const style.Context, src: []const u8) !Render {
    var diag: markup.Diagnostic = undefined;
    return renderLabel(testing.allocator, ctx, src, .{}, &diag);
}

const eps = 1e-9;

test "a superscript is scaled, raised and placed after its base" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderTest(&ctx, "H^O");
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.elements.len);
    const base = r.elements[0];
    const sup = r.elements[1];
    try testing.expectEqual(@as(u8, 1), sup.level);
    try testing.expectApproxEqAbs(@as(f64, 4.9), sup.cap_height, eps); // 0.7 x 7 mm
    try testing.expectApproxEqAbs(@as(f64, 6), sup.origin.x, eps); // after H's 6 mm advance
    try testing.expectApproxEqAbs(@as(f64, 3.85), sup.origin.y, eps); // 0.55 x 7 mm
    try testing.expectApproxEqAbs(@as(f64, 6), base.advance, eps);
    // O at 0.007 mm per unit: 600 units wide, 700 tall.
    try testing.expectApproxEqAbs(@as(f64, 10.2), r.design.x1, eps);
    try testing.expectApproxEqAbs(@as(f64, 8.75), r.ink.y1, eps);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "subscripts drop, and scripts nest" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());

    var sub = try renderTest(&ctx, "H_O");
    defer sub.deinit();
    try testing.expectApproxEqAbs(@as(f64, -1.75), sub.elements[1].origin.y, eps);

    var nested = try renderTest(&ctx, "H^{H^H}");
    defer nested.deinit();
    const inner = nested.elements[2];
    try testing.expectEqual(@as(u8, 2), inner.level);
    try testing.expectApproxEqAbs(@as(f64, 3.43), inner.cap_height, eps); // 7 x 0.7 x 0.7
    try testing.expectApproxEqAbs(@as(f64, 3.85 + 0.55 * 4.9), inner.origin.y, eps);

    var both = try renderTest(&ctx, "H_O^A");
    defer both.deinit();
    try testing.expectEqual(both.elements[1].origin.x, both.elements[2].origin.x);
}

test "a cluster the main face lacks comes from a fallback, matched by cap height" {
    var f = try Fonts.init();
    defer f.deinit();
    var spec = testSpec();
    spec.fallbacks = &.{2};
    const ctx = try style.Context.init(&f.faces, spec);
    var r = try renderTest(&ctx, "HxH");
    defer r.deinit();

    try testing.expectEqual(@as(usize, 3), r.elements.len);
    try testing.expectEqual(@as(FaceId, 2), r.elements[1].face);
    // The fallback's 500-unit cap height is matched to 7 mm: 0.014 mm per
    // unit, so its 300-unit x is 4.2 mm tall.
    try testing.expectApproxEqAbs(@as(f64, 4.2), r.elements[1].ink.height(), eps);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "letters follow the style's italic rule and explicit variants" {
    var f = try Fonts.init();
    defer f.deinit();
    var spec = testSpec();
    spec.letters = .italic;
    spec.italic = 1;
    const ctx = try style.Context.init(&f.faces, spec);
    var r = try renderTest(&ctx, "H\\mathrm{O}");
    defer r.deinit();
    try testing.expectEqual(@as(FaceId, 1), r.elements[0].face);
    try testing.expectEqual(@as(FaceId, 0), r.elements[1].face);

    var plain = try style.Context.init(&f.faces, testSpec());
    _ = &plain;
    var asked = try renderTest(&plain, "\\mathit{H}");
    defer asked.deinit();
    try testing.expectEqual(@as(usize, 1), asked.diagnostics.len);
    try testing.expect(asked.diagnostics[0].kind == .no_italic);
}

test "missing glyphs and unrendered constructs are reported at their source" {
    var f = try Fonts.init();
    defer f.deinit();
    var spec = testSpec();
    spec.fallbacks = &.{2};
    const ctx = try style.Context.init(&f.faces, spec);

    var r = try renderTest(&ctx, "H\\u{5A}");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(r.diagnostics[0].kind == .missing_glyph);
    try testing.expectEqual(@as(u32, 1), r.diagnostics[0].offset);

    var acc = try renderTest(&ctx, "\\bar{H}");
    defer acc.deinit();
    try testing.expect(acc.diagnostics[0].kind == .not_rendered);
    try testing.expectEqual(@as(usize, 1), acc.items.len); // the body is still drawn
}

test "math spaces are sized from the em; the anchor moves the origin" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());

    // A quad is one em: 1000 units at 0.01 mm per unit.
    var r = try renderTest(&ctx, "H\\quad H");
    defer r.deinit();
    try testing.expectApproxEqAbs(@as(f64, 16), r.elements[1].origin.x, eps);

    var diag: markup.Diagnostic = undefined;
    var c = try renderLabel(testing.allocator, &ctx, "H^O", .{ .anchor = render.Anchor.centre }, &diag);
    defer c.deinit();
    try testing.expectApproxEqAbs(@as(f64, -5.1), c.design.x0, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.9), c.elements[1].origin.x, eps);
}

test "syntax errors come back as data" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var diag: markup.Diagnostic = undefined;
    try testing.expectError(error.Syntax, renderLabel(testing.allocator, &ctx, "x^2^3", .{}, &diag));
    try testing.expect(diag.kind == .double_superscript);
}

test "rendering a label is deterministic" {
    var f = try Fonts.init();
    defer f.deinit();
    var spec = testSpec();
    spec.fallbacks = &.{2};
    const ctx = try style.Context.init(&f.faces, spec);
    var r1 = try renderTest(&ctx, "Hx_{O}^{A H}D");
    defer r1.deinit();
    var r2 = try renderTest(&ctx, "Hx_{O}^{A H}D");
    defer r2.deinit();
    try testing.expectEqualDeep(r1.items, r2.items);
    try testing.expectEqualDeep(r1.elements, r2.elements);
}
