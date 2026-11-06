//! Rendering a label: markup, parsed, laid out in a style context, as the
//! engine's two-level geometry (render.zig).
//!
//! This version lays out one left-to-right line on the baseline: text,
//! groups, superscripts and subscripts (nested to any depth), accents, math
//! spaces, and automatic space between atoms by their classes. Breaks parse
//! but are not rendered yet; the content is drawn without them and a
//! diagnostic says so. Contact profiles, the hard box, breaks and bidi come
//! later.
//!
//! Atom classes and the rules that turn a binary operator into an ordinary
//! atom follow TeX; the amounts of space come from the style. A literal space
//! means the user is spacing by hand, so no automatic space is added beside it.

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
        .path => |*p| p.outline = try p.outline.transformed(a, move),
    };
    var design: Box = .{ .x0 = shift, .y0 = 0, .x1 = shift + width, .y1 = 0 };
    var ink = Box.empty;
    for (b.elements.items) |*e| {
        e.origin.x += shift;
        e.ink = moved(e.ink, shift);
        ink = ink.join(e.ink);
        const face = e.face orelse {
            design = design.join(e.ink);
            continue;
        };
        const ext = ctx.faces[face].extents();
        const s = try ctx.scaleFor(face, e.cap_height);
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

/// TeX's atom classes, plus `space` for anything that spaces by itself (a
/// literal space, an explicit math space, a break).
const Class = enum { ord, op, bin, rel, open, close, punct, space };

/// One atom of a list: a node, or for text a byte range of it.
const Atom = struct {
    node: markup.Node,
    start: usize = 0,
    end: usize = 0,
    class: Class,
};

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
    /// height `cap`, with automatic space between its atoms; returns the pen
    /// position after it.
    fn nodes(b: *Builder, list: []const markup.Node, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        var atoms: std.ArrayList(Atom) = .empty;
        for (list) |n| try atomsOf(b.a, n, &atoms);
        applyTexRules(atoms.items);

        const mu = (try b.ctx.em(cap)) / 18;
        var pen = x;
        var prev: ?Class = null;
        for (atoms.items) |atom| {
            if (prev) |p| {
                if (spacing(b.ctx.spec.spacing, p, atom.class, level)) |amount| pen += amount * mu;
            }
            pen = switch (atom.node) {
                .text => |t| try b.text(t, atom.start, atom.end, cap, level, pen, y),
                else => try b.node(atom.node, cap, level, pen, y),
            };
            prev = atom.class;
        }
        return pen;
    }

    fn node(b: *Builder, n: markup.Node, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        switch (n) {
            .text => |t| return b.text(t, 0, t.utf8.len, cap, level, x, y),
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
            .accent => |acc| return b.accent(acc, cap, level, x, y),
            .line_break => |br| {
                try b.diagnose(.not_rendered, br.span.start);
                return x;
            },
        }
    }

    /// An accent over its body. A circumflex (or, by the style, a bar) on a
    /// single cluster becomes a combining mark in the same cluster, which the
    /// font positions or composes (y + U+0302 is often a precomposed ŷ). Over
    /// anything longer, or where no face has the mark, the accent is drawn
    /// above the body's ink: a circumflex glyph centred on it, or a rule
    /// across it.
    fn accent(b: *Builder, acc: markup.Accent, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        const mark: ?u21 = switch (acc.kind) {
            .hat => 0x0302,
            .bar => if (b.ctx.spec.bar == .combining) 0x0304 else null,
            .overline => null,
        };
        if (mark) |m| {
            if (singleCluster(acc.body.*)) |t| {
                const combined = try withMark(b.a, t, m, acc.span.start);
                const face = try b.chooseFace(combined, combined.utf8);
                if (covers(b.ctx.faces[face], combined.utf8))
                    return b.text(combined, 0, combined.utf8.len, cap, level, x, y);
            }
        }

        const first = b.elements.items.len;
        const end = try b.node(acc.body.*, cap, level, x, y);
        var body = Box.empty;
        for (b.elements.items[first..]) |e| body = body.join(e.ink);
        if (body.isEmpty()) return end;
        const gap = b.ctx.accent_gap * cap;

        switch (acc.kind) {
            .bar, .overline => {
                const thick = b.ctx.rule_thickness * cap;
                const bar: Box = .{ .x0 = body.x0, .y0 = body.y1 + gap, .x1 = body.x1, .y1 = body.y1 + gap + thick };
                try b.items.append(b.a, .{ .path = .{
                    .outline = try rectangle(b.a, bar),
                    .element = @intCast(b.elements.items.len),
                } });
                try b.elements.append(b.a, .{
                    .face = null,
                    .start = acc.span.start,
                    .end = acc.span.end,
                    .level = level,
                    .cap_height = cap,
                    .origin = .{ .x = bar.x0, .y = bar.y0 },
                    .advance = 0,
                    .ink = bar,
                });
            },
            .hat => try b.drawnGlyph(0x02C6, acc.span, body, gap, cap, level),
        }
        return end;
    }

    /// A spacing accent glyph centred over `body`, its ink `gap` above it.
    fn drawnGlyph(b: *Builder, cp: u21, span: markup.Span, body: Box, gap: f64, cap: f64, level: u8) Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        const spec = b.ctx.spec;
        const face_id = blk: {
            if (covers(b.ctx.faces[spec.upright], buf[0..n])) break :blk spec.upright;
            for (spec.fallbacks) |f| {
                if (covers(b.ctx.faces[f], buf[0..n])) break :blk f;
            }
            return b.diagnose(.missing_glyph, span.start);
        };
        const face = b.ctx.faces[face_id];
        const gid = face.glyph(cp).?;
        const s = try b.ctx.scaleFor(face_id, cap);
        const own = (try face.outline(gid)).bounds();
        if (own.isEmpty()) return;
        const dx = (body.x0 + body.x1) / 2 - (own.x0 + own.x1) / 2 * s;
        const dy = body.y1 + gap - own.y0 * s;
        const item: render.GlyphItem = .{
            .face = face_id,
            .gid = gid,
            .transform = Affine.scale(s).then(Affine.translate(dx, dy)),
            .element = @intCast(b.elements.items.len),
        };
        try b.items.append(b.a, .{ .glyph = item });
        try b.elements.append(b.a, .{
            .face = face_id,
            .start = span.start,
            .end = span.end,
            .level = level,
            .cap_height = cap,
            .origin = .{ .x = dx, .y = dy },
            .advance = 0,
            .ink = try render.glyphInk(b.a, face, item),
        });
    }

    /// Splits bytes `start..end` of a text node into elements by face,
    /// cluster by cluster, then shapes and places each element.
    fn text(b: *Builder, t: markup.Text, start: usize, end: usize, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        var pen = x;
        var i = start;
        var run_start = start;
        var run_face: ?FaceId = null;
        while (i < end) {
            const next = @min(clusterEnd(t.utf8, i), end);
            const face = try b.chooseFace(t, t.utf8[i..next]);
            if (run_face != null and run_face.? != face) {
                pen = try b.element(t, run_start, i, run_face.?, cap, level, pen, y);
                run_start = i;
            }
            run_face = face;
            i = next;
        }
        if (run_face) |f| pen = try b.element(t, run_start, end, f, cap, level, pen, y);
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

/// The atoms of one node, appended to `out`. Text splits by cluster: runs of
/// ordinary clusters stay together; every other cluster is its own atom.
/// \text stays one ordinary atom: it is text, not math.
fn atomsOf(a: Allocator, n: markup.Node, out: *std.ArrayList(Atom)) !void {
    switch (n) {
        .text => |t| {
            if (t.operator) return out.append(a, .{ .node = n, .end = t.utf8.len, .class = .op });
            if (t.variant == .text) return out.append(a, .{ .node = n, .end = t.utf8.len, .class = .ord });
            var i: usize = 0;
            while (i < t.utf8.len) {
                const next = clusterEnd(t.utf8, i);
                const class = clusterClass(firstCodepoint(t.utf8[i..next]));
                const last = if (out.items.len > 0) &out.items[out.items.len - 1] else null;
                const joins = last != null and last.?.node == .text and last.?.node.text.utf8.ptr == t.utf8.ptr and
                    last.?.end == i and last.?.class == class and (class == .ord or class == .space);
                if (joins) {
                    last.?.end = next;
                } else {
                    try out.append(a, .{ .node = n, .start = i, .end = next, .class = class });
                }
                i = next;
            }
        },
        .scripts => |s| try out.append(a, .{ .node = n, .class = nucleusClass(s.base.*) }),
        .group, .accent => try out.append(a, .{ .node = n, .class = .ord }),
        .space, .line_break => try out.append(a, .{ .node = n, .class = .space }),
    }
}

/// A script's atom takes its nucleus's class, as in TeX.
fn nucleusClass(n: markup.Node) Class {
    return switch (n) {
        .text => |t| if (t.operator)
            .op
        else if (t.variant != .text and clusterEnd(t.utf8, 0) == t.utf8.len)
            clusterClass(firstCodepoint(t.utf8))
        else
            .ord,
        else => .ord,
    };
}

fn clusterClass(cp: u21) Class {
    return switch (cp) {
        ' ', 0x00A0, 0x202F => .space,
        // The hyphen-minus stays ordinary: legends use it as a hyphen
        // (ON-OFF). \minus or U+2212 is the binary minus.
        '+', 0x2212, 0x00B1, 0x2213, 0x00D7, 0x00F7, 0x22C5, 0x2217, 0x2218 => .bin,
        // The colon stays ordinary too (1:2).
        '=', '<', '>', 0x2264, 0x2265, 0x2260, 0x2248, 0x2261, 0x223C, 0x221D, 0x2190...0x2199, 0x21D0...0x21D5, 0x21A6 => .rel,
        // Large operators space like operator names.
        0x2211, 0x220F, 0x2210, 0x222B...0x2233 => .op,
        '(', '[', 0x27E8 => .open,
        ')', ']', 0x27E9 => .close,
        ',', ';' => .punct,
        else => .ord,
    };
}

/// TeX's rules: a binary operator with nothing to operate on, before or
/// after, is ordinary ("+H", "a=-b", "Σ+"). Spaces do not count as atoms.
fn applyTexRules(atoms: []Atom) void {
    var prev: ?usize = null;
    for (atoms, 0..) |*atom, k| {
        if (atom.class == .space) continue;
        if (atom.class == .bin) {
            const before = if (prev) |p| atoms[p].class else null;
            if (before == null or before.? == .bin or before.? == .op or before.? == .rel or
                before.? == .open or before.? == .punct) atom.class = .ord;
        }
        if (atom.class == .rel or atom.class == .close or atom.class == .punct) {
            if (prev) |p| {
                if (atoms[p].class == .bin) atoms[p].class = .ord;
            }
        }
        prev = k;
    }
    if (prev) |p| {
        if (atoms[p].class == .bin) atoms[p].class = .ord;
    }
}

/// The automatic space between two adjacent atoms, in mu, or null. Inside
/// scripts only operator spacing applies, as in TeX.
fn spacing(s: style.Spacing, prev: Class, cur: Class, level: u8) ?f64 {
    if (prev == .space or cur == .space) return null;
    if (prev == .bin or cur == .bin) return if (level == 0) s.binary else null;
    if (prev == .rel or cur == .rel) {
        if (prev == .open or cur == .close or cur == .punct) return null;
        return if (level == 0) s.relation else null;
    }
    if (prev == .punct) return if (level == 0) s.punctuation else null;
    if (prev == .op or cur == .op) {
        if (prev == .open or cur == .close or cur == .punct) return null;
        return s.operator;
    }
    return null;
}

/// The text of a node that is one grapheme cluster (or a group holding only
/// one), or null.
fn singleCluster(n: markup.Node) ?markup.Text {
    return switch (n) {
        .text => |t| if (t.utf8.len > 0 and clusterEnd(t.utf8, 0) == t.utf8.len) t else null,
        .group => |g| if (g.items.len == 1) singleCluster(g.items[0]) else null,
        else => null,
    };
}

/// `t` with combining mark `m` appended, its bytes credited to `at`.
fn withMark(a: Allocator, t: markup.Text, m: u21, at: u32) !markup.Text {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(m, &buf) catch unreachable;
    const utf8 = try std.mem.concat(a, u8, &.{ t.utf8, buf[0..n] });
    const source = try a.alloc(u32, utf8.len);
    @memcpy(source[0..t.source.len], t.source);
    @memset(source[t.source.len..], at);
    var out = t;
    out.utf8 = utf8;
    out.source = source;
    return out;
}

/// A rectangle as a counter-clockwise outline, mm.
fn rectangle(a: Allocator, r: Box) !geom.Outline {
    const p = [4]geom.Point{
        .{ .x = r.x0, .y = r.y0 }, .{ .x = r.x1, .y = r.y0 },
        .{ .x = r.x1, .y = r.y1 }, .{ .x = r.x0, .y = r.y1 },
    };
    const segs = try a.alloc(geom.Segment, 4);
    for (segs, 0..) |*seg, k| seg.* = .{ .line = .{ p[k], p[(k + 1) % 4] } };
    const contours = try a.alloc(geom.Contour, 1);
    contours[0] = .{ .segments = segs };
    return .{ .contours = contours };
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
    try testing.expectEqual(@as(?FaceId, 2), r.elements[1].face);
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
    try testing.expectEqual(@as(?FaceId, 1), r.elements[0].face);
    try testing.expectEqual(@as(?FaceId, 0), r.elements[1].face);

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

    var br = try renderTest(&ctx, "H\\\\H");
    defer br.deinit();
    try testing.expect(br.diagnostics[0].kind == .not_rendered);
    try testing.expectEqual(@as(usize, 2), br.items.len); // both lines' text is still drawn
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

test "binary operators and relations get the style's space; unary ones do not" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    const mu = 10.0 / 18.0; // an em is 1000 units at 0.01 mm per unit

    var bin = try renderTest(&ctx, "H+H");
    defer bin.deinit();
    try testing.expectApproxEqAbs(6 + 2 * mu, bin.elements[1].origin.x, eps);
    try testing.expectApproxEqAbs(12 + 4 * mu, bin.elements[2].origin.x, eps);

    var rel = try renderTest(&ctx, "H=H");
    defer rel.deinit();
    try testing.expectApproxEqAbs(12 + 6 * mu, rel.elements[2].origin.x, eps);

    // A leading or trailing + operates on nothing, so it is ordinary.
    var unary = try renderTest(&ctx, "+H");
    defer unary.deinit();
    try testing.expectApproxEqAbs(@as(f64, 6), unary.elements[1].origin.x, eps);
    var trailing = try renderTest(&ctx, "H+");
    defer trailing.deinit();
    try testing.expectApproxEqAbs(@as(f64, 12), trailing.design.x1, eps);

    // A literal space means hand spacing: nothing is added beside it.
    var hand = try renderTest(&ctx, "H = H");
    defer hand.deinit();
    try testing.expectApproxEqAbs(@as(f64, 17), hand.elements[hand.elements.len - 1].origin.x, eps);
}

test "operator names are spaced from their operand, even inside scripts" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    const mu = 10.0 / 18.0;

    var op = try renderTest(&ctx, "\\operatorname{HO}H");
    defer op.deinit();
    try testing.expectApproxEqAbs(12 + 3 * mu, op.elements[1].origin.x, eps);

    // Inside a script, binary spacing is dropped.
    var script = try renderTest(&ctx, "H^{H+H}");
    defer script.deinit();
    try testing.expectApproxEqAbs(6 + 4.2, script.elements[2].origin.x, eps);
}

test "a hat on one character is a combining mark in its cluster" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderTest(&ctx, "\\hat H");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.elements.len);
    try testing.expectEqual(@as(usize, 2), r.items.len); // H and U+0302, shaped together
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "a hat over several characters is drawn centred above their ink" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderTest(&ctx, "\\hat{HH}");
    defer r.deinit();
    const body = r.elements[0].ink;
    const hat = r.elements[1].ink;
    try testing.expectApproxEqAbs((body.x0 + body.x1) / 2, (hat.x0 + hat.x1) / 2, eps);
    // Its ink starts 0.1 cap height (0.7 mm) above the body's.
    try testing.expectApproxEqAbs(body.y1 + 0.7, hat.y0, eps);
}

test "bars and overlines are rules across the ink" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderTest(&ctx, "\\overline{HO}");
    defer r.deinit();
    const body = r.elements[0].ink;
    const bar = r.elements[1];
    try testing.expectEqual(@as(?FaceId, null), bar.face);
    try testing.expectApproxEqAbs(body.x0, bar.ink.x0, eps);
    try testing.expectApproxEqAbs(body.x1, bar.ink.x1, eps);
    try testing.expectApproxEqAbs(body.y1 + 0.7, bar.ink.y0, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.56), bar.ink.height(), eps); // 0.08 cap

    // The rule is an item, and moves with the anchor.
    var diag: markup.Diagnostic = undefined;
    var c = try renderLabel(testing.allocator, &ctx, "\\bar H", .{ .anchor = .end }, &diag);
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const outlines = try c.outlines(arena.allocator(), &f.faces);
    try testing.expectEqual(@as(usize, 2), outlines.len);
    try testing.expectApproxEqAbs(c.elements[1].ink.x1, outlines[1].bounds().x1, eps);
    try testing.expectApproxEqAbs(@as(f64, -0.5), outlines[1].bounds().x1, eps); // H's ink ends 0.5 mm before its advance
}
