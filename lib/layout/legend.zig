//! Legends set by engine v2 (glyphic). A run's markup is parsed as a
//! legend (text, with math between dollars), laid out on one line, and
//! handed back as a `Render`: placed glyphs and rules in the label frame
//! (mm, y up, the origin on the baseline at the start), with a source span
//! per top-row object and the places it may break, so the flow pass cuts
//! it into pieces as it did v1's renders.
//!
//! Each top-row object (a word, a space, a soft hyphen, a symbol, a
//! fraction…) is one element; its glyphs carry the source bytes they were
//! shaped from. Only a text leaf's glyphs may be cut apart (a word longer
//! than its line); a structure's never are.
//!
//! The model's text styles (stored glyphic contexts, see
//! `model.TextStyle`) become the engine's contexts here (see `contextOf`).

const std = @import("std");
const font = @import("graven_font");
const rendering = @import("render.zig");
const glyphic = @import("graven_glyphic");
const model = @import("model.zig");
const fonts = @import("fonts.zig");

const Allocator = std.mem.Allocator;
const geom = @import("graven_geom");
const Box = geom.Box;
const Affine = geom.Affine;
const Face = font.Face;
const Render = rendering.Render;
const R = rendering;

/// A text style as legends are set in it.
pub const Style = struct {
    /// Its glyphic context.
    id: glyphic.StyleId,
    /// Size, cap height in mm.
    cap_height: f64,
    /// Baseline to baseline, mm.
    line_pitch: f64,
    /// The face whose extents give a line's design box.
    text: *Face,
};

/// A model text style made a glyphic context in `g`: its faces by role
/// (`roles`, from `fonts.resolve`, in `faces`), its rules, and its size.
/// `text` is the face its text is set in (its own, its base's, or the
/// default), for its cap height and line pitch. Its base is set by the
/// caller, once every style has its context.
pub fn contextOf(g: *glyphic.Engine, faces: []const *Face, st: model.TextStyle, roles: []const fonts.RoleFace, text: *Face, name: []const u8) !?Style {
    const id = try g.addStyle(name, .none);
    for (roles) |rf| if (rf.face < faces.len) try g.setFace(id, rf.role, faces[rf.face]);
    // No text face found of its own (none set, or not installed) and no
    // base: the default face.
    const has_text = for (roles) |rf| {
        if (std.mem.eql(u8, rf.role, "text")) break true;
    } else false;
    if (st.base == .none and !has_text) try g.setFace(id, "text", text);
    for (st.rules.items) |r| {
        if (r.kind) |k| try g.setFor(id, .{ .kind = k }, r.param, r.value) else try g.set(id, r.param, r.value);
    }
    const cap_units = glyphic.faces.capUnits(text);
    const cap = if (st.em_size) |em| em * cap_units / @as(f64, @floatFromInt(text.upem)) else st.cap_height;
    if (!(cap > 0)) return null;
    const ext = text.extents();
    const pitch = if (st.line_pitch) |f| f * cap else (ext.ascender - ext.descender) * cap / cap_units;
    return .{ .id = id, .cap_height = cap, .line_pitch = pitch, .text = text };
}

/// A face's cap height, font units.
pub const capUnits = glyphic.faces.capUnits;

/// Whether a top-row object of `kind` is text whose glyphs may be cut
/// apart.
fn cuttable(kind: glyphic.Kind) bool {
    return switch (kind) {
        .word, .number, .variable, .space => true,
        else => false,
    };
}

fn faceId(faces: []const *Face, f: *Face) ?R.FaceId {
    for (faces, 0..) |x, i| if (x == f) return @intCast(i);
    return null;
}

/// `markup` (a legend, or all math: `mode`) set on one line in style `st` of `g`, its glyphs' faces given
/// by their place in `faces`. The render owns its memory (`deinit`).
pub fn render(gpa: Allocator, g: *const glyphic.Engine, faces: []const *Face, st: Style, markup: []const u8, mode: glyphic.latex.Mode) !Render {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var e = try glyphic.Expr.init(a);
    var spans: glyphic.entry.Spans = .{};
    try glyphic.latex.parse(&e, &spans, markup, mode);
    const outer = try a.dupe(glyphic.StyleId, &.{st.id});
    const r = glyphic.Resolver.init(g, &e, outer);
    // Empty fields are drawn as holes (not ink), so markup being typed
    // shows where it goes on; each is reported as a missing argument.
    var lay: glyphic.layout.Layout = .{ .a = a, .r = &r, .editing = true };
    var syntax: std.ArrayList(rendering.Syntax) = .empty;
    const cap = st.cap_height;

    const top = e.node(e.root).items.items;
    // Each object's start along the line, and its first item; one more
    // for the end.
    const xs = try a.alloc(f64, top.len + 1);
    const ends = try a.alloc(f64, top.len);
    const first_item = try a.alloc(u32, top.len + 1);
    var items: std.ArrayList(R.Item) = .empty;
    var elements: std.ArrayList(R.Element) = .empty;
    var diagnostics: std.ArrayList(R.Diagnostic) = .empty;
    var ink: Box = .empty;
    var x: f64 = 0;
    var prev: ?glyphic.layout.Class = null;
    var boxes: std.ArrayList(R.ObjectBox) = .empty;
    for (top, 0..) |c, k| {
        // Fitted to the line's band when its style asks (`fit`): inline
        // math never makes the line taller.
        const fit = try lay.fitted(c, cap);
        const laid = fit.laid;
        if (fit.overflow) try diagnostics.append(a, .{ .kind = .fit_overflow, .offset = spans.get(c).start });
        x += lay.gapBefore(c, prev, laid.class, false) * cap;
        prev = laid.class;
        xs[k] = x;
        first_item[k] = @intCast(items.items.len);
        const span = spans.get(c);
        const node = e.node(c);
        const move = Affine.translate(x, 0);
        var face: ?R.FaceId = null;
        var units: f64 = 0;
        for (laid.items.items) |it| switch (it) {
            .glyph => |gl| {
                const fid = faceId(faces, gl.face) orelse continue;
                if (face == null) {
                    face = fid;
                    units = cap / glyphic.faces.capUnits(gl.face);
                }
                // A text leaf's glyphs: their own bytes. Inside a structure,
                // the start of the object each draws (its head's: the
                // structure's), so the caret and the editor find it.
                const own = spans.get(gl.object);
                const src = if (cuttable(node.kind)) @min(span.start + gl.cluster, @max(span.end, span.start + 1) - 1) else if (own.start != glyphic.entry.Span.none.start) own.start else span.start;
                try items.append(a, .{ .glyph = .{ .face = fid, .gid = gl.gid, .transform = gl.m.then(move), .element = @intCast(k), .source = src, .grow = gl.grow } });
            },
            .rule, .hole => {
                const o = try glyphic.setting.outlines(a, &.{it}, 0.002);
                const outline = if (o.len > 0) try o[0].transformed(a, move) else blk: {
                    const h = it.hole.corners;
                    const segs = try a.alloc(geom.Segment, 4);
                    for (segs, 0..) |*s, q| s.* = .{ .line = .{ move.apply(h[q]), move.apply(h[(q + 1) % 4]) } };
                    const cs = try a.alloc(geom.Contour, 1);
                    cs[0] = .{ .segments = segs };
                    break :blk geom.Outline{ .contours = cs };
                };
                const object = switch (it) {
                    .rule => |ru| ru.object,
                    .hole => |h| h.object,
                    .glyph => unreachable,
                };
                const own = spans.get(object);
                try items.append(a, .{ .path = .{ .outline = outline, .element = @intCast(k), .source = if (own.start != glyphic.entry.Span.none.start) own.start else span.start, .role = if (it == .hole) .placeholder else .ink } });
                if (it == .hole) try syntax.append(a, .{ .kind = .missing_argument, .offset = span.end });
            },
        };
        for (laid.boxes.items) |b| {
            const kind = e.node(b.object).kind;
            const sp = spans.get(b.object);
            try boxes.append(a, .{
                .corners = .{ move.apply(b.corners[0]), move.apply(b.corners[1]), move.apply(b.corners[2]), move.apply(b.corners[3]) },
                .baseline = .{ move.apply(b.baseline[0]), move.apply(b.baseline[1]) },
                .element = @intCast(k),
                .start = if (sp.start != glyphic.entry.Span.none.start) sp.start else span.start,
                .end = if (sp.start != glyphic.entry.Span.none.start) sp.end else span.end,
                .nest = b.nest,
                .kind = if (kind == .row) .field else if (kind.isStructure()) .structure else .leaf,
            });
        }
        const el_ink: Box = if (laid.ink.isEmpty()) .empty else .{ .x0 = laid.ink.x0 + x, .y0 = laid.ink.y0, .x1 = laid.ink.x1 + x, .y1 = laid.ink.y1 };
        ink = ink.join(el_ink);
        try elements.append(a, .{
            .face = face,
            .start = span.start,
            .end = span.end,
            .level = if (cuttable(node.kind)) 0 else 1,
            .cap_height = cap,
            .origin = .{ .x = x, .y = 0 },
            .advance = laid.width,
            .ink = el_ink,
            .units = units,
        });
        x += laid.width;
        ends[k] = x;
    }
    xs[top.len] = x;
    first_item[top.len] = @intCast(items.items.len);
    for (lay.missing.items) |ms| try diagnostics.append(a, .{ .kind = .missing_glyph, .offset = spans.get(ms.object).start });

    // Where it may break: at a space (left out), after a soft hyphen
    // (where a hyphen is then drawn), and where the kinds allow.
    var opportunities: std.ArrayList(R.Opportunity) = .empty;
    for (try glyphic.breaks.candidates(a, &r)) |cd| {
        const k = cd.index;
        if (cd.skip > 0) {
            const after = @min(k + cd.skip, top.len);
            const sp = spans.get(top[k]);
            try opportunities.append(a, .{ .start = sp.start, .end = spans.get(top[after - 1]).end, .x0 = ends[k - 1], .x1 = xs[after], .item0 = first_item[k], .elem0 = @intCast(k), .item1 = first_item[after], .elem1 = @intCast(after) });
        } else if (cd.hyphen) {
            const sp = spans.get(top[k - 1]);
            try opportunities.append(a, .{ .start = sp.start, .end = sp.end, .x0 = xs[k], .x1 = xs[k], .item0 = first_item[k], .elem0 = @intCast(k - 1), .item1 = first_item[k], .elem1 = @intCast(k), .hyphen = true });
        } else {
            const at = spans.get(top[k]).start;
            try opportunities.append(a, .{ .start = at, .end = at, .x0 = ends[k - 1], .x1 = xs[k], .item0 = first_item[k], .elem0 = @intCast(k), .item1 = first_item[k], .elem1 = @intCast(k) });
        }
    }

    const ext = st.text.extents();
    const k_text = cap / glyphic.faces.capUnits(st.text);
    return .{
        .arena = arena,
        .items = items.items,
        .design = .{ .x0 = 0, .y0 = ext.descender * k_text, .x1 = x, .y1 = ext.ascender * k_text },
        .ink = ink,
        .diagnostics = diagnostics.items,
        .elements = elements.items,
        .boxes = boxes.items,
        .opportunities = opportunities.items,
        .syntax = syntax.items,
    };
}

const testing = std.testing;
const testdata = @import("graven_testdata");

test "a legend set by glyphic: words, the spaces between them, and its source" {
    const gpa = testing.allocator;
    const face = try Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    var g = glyphic.Engine.init(gpa);
    defer g.deinit();
    const st = (try contextOf(&g, &faces, .{ .name = "s", .cap_height = 3 }, &.{}, face, "s")).?;
    try testing.expectApproxEqAbs(3, st.cap_height, 1e-9);
    var r = try render(gpa, &g, &faces, st, "HO DA", .legend);
    defer r.deinit();
    // Words and a space: three elements, one break between the words.
    try testing.expectEqual(3, r.elements.len);
    try testing.expectEqual(1, r.opportunities.len);
    const o = r.opportunities[0];
    try testing.expectEqual(2, o.start);
    try testing.expectEqual(3, o.end);
    try testing.expect(o.x1 > o.x0);
    // Cap height: the ink of capitals reaches about 3 mm up.
    try testing.expectApproxEqAbs(3, r.ink.y1, 0.1);
    // Glyphs carry their source bytes, so a long word may be cut.
    try testing.expectEqual(1, r.items[1].glyph.source);
    try testing.expectEqual(3, r.items[r.items.len - 2].glyph.source);
    // A box per object: the three top objects.
    try testing.expectEqual(3, r.boxes.len);
    try testing.expectEqual(0, r.boxes[2].start - 3);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const cuts = try r.forcedCuts(scratch.allocator());
    try testing.expectEqual(2, cuts.len);
    // The caret sits after the first word at its end.
    try testing.expectApproxEqAbs(o.x0, r.caret(2).?.x, 1e-9);
}

test "an equation run is all math: its fraction is a fraction, not text" {
    const gpa = testing.allocator;
    const face = try Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    var g = glyphic.Engine.init(gpa);
    defer g.deinit();
    const st = (try contextOf(&g, &faces, .{ .name = "s", .cap_height = 3 }, &.{}, face, "s")).?;
    var math = try render(gpa, &g, &faces, st, "\\frac{H}{D}", .math);
    defer math.deinit();
    var text = try render(gpa, &g, &faces, st, "\\frac{H}{D}", .legend);
    defer text.deinit();
    // Stacked: H, a rule, D (scripts' size in text style), standing
    // above the capitals and below the baseline; as text, eleven glyphs.
    try testing.expectEqual(3, math.items.len);
    var rules: usize = 0;
    for (math.items) |it| if (it == .path) {
        rules += 1;
    };
    try testing.expectEqual(1, rules);
    try testing.expect(math.ink.y1 > 3 and math.ink.y0 < 0);
    try testing.expect(math.items.len < text.items.len);
}

test "inside a structure, glyphs carry their own objects' sources; a rule its fraction's" {
    const gpa = testing.allocator;
    const face = try Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    var g = glyphic.Engine.init(gpa);
    defer g.deinit();
    const st = (try contextOf(&g, &faces, .{ .name = "s", .cap_height = 3 }, &.{}, face, "s")).?;
    // 0123456789012
    // H+\frac{H}{D}
    var r = try render(gpa, &g, &faces, st, "H+\\frac{H}{D}", .math);
    defer r.deinit();
    var sources: [8]u32 = undefined;
    var n: usize = 0;
    for (r.items) |it| {
        sources[n] = switch (it) {
            .glyph => |gl| gl.source,
            .path => |p| p.source,
        };
        n += 1;
    }
    std.mem.sort(u32, sources[0..n], {}, std.sort.asc(u32));
    // H, +, the rule (the fraction's start), its H, its D.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 8, 11 }, sources[0..n]);
}

test "a legend's boxes: each object's, nested in its structure's, kept with their pieces" {
    const gpa = testing.allocator;
    const face = try Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    var g = glyphic.Engine.init(gpa);
    defer g.deinit();
    const st = (try contextOf(&g, &faces, .{ .name = "s", .cap_height = 3 }, &.{}, face, "s")).?;
    var r = try render(gpa, &g, &faces, st, "HO $\\frac{D}{A}$", .legend);
    defer r.deinit();
    var leaves: usize = 0;
    var structures: usize = 0;
    var fields: usize = 0;
    for (r.boxes) |b| switch (b.kind) {
        .leaf => leaves += 1,
        .structure => structures += 1,
        .field => fields += 1,
    };
    // HO, the space, D and A; the fraction; its two fields.
    try testing.expectEqual(4, leaves);
    try testing.expectEqual(1, structures);
    try testing.expectEqual(2, fields);
    // The pieces after the space: the fraction's boxes only, from x 0.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const second = try r.piece(scratch.allocator(), 0, null);
    try testing.expectEqual(5, second.boxes.len);
    var x0: f64 = std.math.inf(f64);
    for (second.boxes) |b| x0 = @min(x0, b.corners[0].x);
    try testing.expectApproxEqAbs(0, x0, 1e-9);
}

