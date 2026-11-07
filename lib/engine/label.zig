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
const Profile = @import("profile.zig").Profile;

const Allocator = std.mem.Allocator;
const Affine = geom.Affine;
const Box = geom.Box;
const FaceId = render.FaceId;
const Render = render.Render;

pub const Options = struct {
    anchor: render.Anchor = .start,
    names: *const entities.Table = &entities.Table.builtin,
    /// The most space the label may use, in the slot's coordinates; null
    /// for no limit. Lines wrap at its width, and the block shifts away from
    /// its edges before anything overflows.
    hard_box: ?Box = null,
    /// Where the anchor starts, in the hard box's coordinates.
    anchor_at: geom.Point = .{ .x = 0, .y = 0 },
    /// Parse leniently, for showing markup as it is typed: problems become
    /// placeholders and faint text, listed in the render's `syntax`, and
    /// the render never fails on syntax.
    preview: bool = false,
};

pub const Error = style.Context.Error || markup.Error || error{InvalidTension};

/// Renders `src` in style context `ctx`. On error.Syntax, `syntax` says what
/// and where in the source.
pub fn renderLabel(gpa: Allocator, ctx: *const style.Context, src: []const u8, opts: Options, syntax: *markup.Diagnostic) Error!Render {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var problems: std.ArrayList(markup.Diagnostic) = .empty;
    const tree = if (opts.preview)
        try markup.parsePreview(a, src, opts.names, &problems)
    else
        try markup.parseWith(a, src, opts.names, syntax);
    var b: Builder = .{ .a = a, .ctx = ctx, .band = ctx.spec.cap_height * ctx.spec.contact_band };
    const cap = ctx.spec.cap_height;
    const pitch = try ctx.linePitch();
    var design = Box.empty;
    var breaks: std.ArrayList(u32) = .empty;

    // Hard breaks at the top level split the label into paragraphs; each
    // fills lines greedily within the hard box's width.
    var rest = tree.items;
    while (true) {
        const cut = for (rest, 0..) |n, k| {
            if (n == .line_break and n.line_break.kind == .hard) break k;
        } else rest.len;
        var atoms: std.ArrayList(Atom) = .empty;
        for (rest[0..cut]) |n| try atomsOf(a, n, &atoms);
        applyTexRules(atoms.items);

        var start: usize = 0;
        while (true) {
            const line = atoms.items[start..];
            var overflow = false;
            const take = if (opts.hard_box) |hb| try b.fit(line, cap, hb.width(), &overflow) else line.len;
            if (overflow) try b.diagnose(.overflow, atomOffset(line[0]));
            const item0 = b.items.items.len;
            const elem0 = b.elements.items.len;
            const y = -@as(f64, @floatFromInt(b.line)) * pitch;
            const width = try b.atomsLine(line[0..take], cap, 0, 0, y);
            // Each line sits on the anchor by its own width.
            const dx = -(try opts.anchor.offset(width));
            try b.shiftSince(item0, elem0, dx);
            design = design.join(.{ .x0 = dx, .y0 = y, .x1 = dx + width, .y1 = y });
            b.line += 1;
            if (take >= line.len) break;
            try breaks.append(a, atomOffset(line[take]));
            start += take + 1; // the break opportunity itself is dropped
            if (start >= atoms.items.len) break;
        }
        if (cut >= rest.len) break;
        try breaks.append(a, rest[cut].span().start);
        rest = rest[cut + 1 ..];
    }

    var ink = Box.empty;
    for (b.elements.items) |*e| {
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

    // Fit the block in the hard box: shift away from an edge first; only
    // a block larger than the box overflows. Geometry stays in the label
    // frame; what moves is the anchor's place in the box.
    var anchor_at: ?geom.Point = null;
    if (opts.hard_box) |hb| {
        var at = opts.anchor_at;
        if (!ink.isEmpty()) {
            if (ink.width() > hb.width()) {
                // A line that overflowed has said so already.
                const said = for (b.diagnostics.items) |d| {
                    if (d.kind == .overflow) break true;
                } else false;
                if (!said) try b.diagnose(.overflow, if (b.elements.items.len > 0) b.elements.items[0].start else 0);
                const lean = try opts.anchor.offset(1);
                at.x = hb.x0 + (hb.width() - ink.width()) * lean - ink.x0;
            } else if (ink.x0 + at.x < hb.x0) {
                at.x = hb.x0 - ink.x0;
            } else if (ink.x1 + at.x > hb.x1) {
                at.x = hb.x1 - ink.x1;
            }
            if (ink.height() > hb.height()) {
                try b.diagnose(.overflow, if (b.elements.items.len > 0) b.elements.items[0].start else 0);
                at.y = hb.y1 - ink.y1; // keep the first line in the box
            } else if (ink.y0 + at.y < hb.y0) {
                at.y = hb.y0 - ink.y0;
            } else if (ink.y1 + at.y > hb.y1) {
                at.y = hb.y1 - ink.y1;
            }
        }
        anchor_at = at;
    }
    if (design.isEmpty()) design = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    return .{
        .arena = arena,
        .items = try b.items.toOwnedSlice(a),
        .design = design,
        .ink = ink,
        .diagnostics = try b.diagnostics.toOwnedSlice(a),
        .elements = try b.elements.toOwnedSlice(a),
        .anchor_at = anchor_at,
        .breaks = try breaks.toOwnedSlice(a),
        .lines = b.line,
        .syntax = try problems.toOwnedSlice(a),
    };
}

/// The source offset an atom starts at.
fn atomOffset(atom: Atom) u32 {
    return switch (atom.node) {
        .text => |t| t.source[atom.start],
        else => |n| n.span().start,
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
    /// A line may break here: a breaking space (U+0020) or \allowbreak.
    /// The atom is dropped when the line breaks at it.
    breakable: bool = false,
};

const Builder = struct {
    a: Allocator,
    ctx: *const style.Context,
    items: std.ArrayList(render.Item) = .empty,
    elements: std.ArrayList(render.Element) = .empty,
    /// Each element's contact profile, by element index.
    profiles: std.ArrayList(Profile) = .empty,
    diagnostics: std.ArrayList(render.Diagnostic) = .empty,
    /// Profile band height for the whole label, mm.
    band: f64,
    /// The line being laid out, from 0.
    line: u16 = 0,

    /// How many of `atoms` fit on one line `width` wide (by ink), breaking
    /// at the last opportunity that fits. If none fits, the first
    /// opportunity is taken (or none, when there is none) and `overflow` is
    /// set: a word longer than its line is reported, never shrunk.
    fn fit(b: *Builder, atoms: []const Atom, cap: f64, width: f64, overflow: *bool) Error!usize {
        if (try b.measure(atoms, cap) <= width) return atoms.len;
        var best: ?usize = null;
        var first: ?usize = null;
        for (atoms, 0..) |atom, k| {
            if (!atom.breakable or k == 0) continue;
            if (first == null) first = k;
            if (try b.measure(atoms[0..k], cap) <= width) best = k else break;
        }
        if (best) |k| return k;
        overflow.* = true;
        return first orelse atoms.len;
    }

    /// The ink width of `atoms` laid out as one line, leaving nothing behind.
    fn measure(b: *Builder, atoms: []const Atom, cap: f64) Error!f64 {
        const items0 = b.items.items.len;
        const elem0 = b.elements.items.len;
        const diag0 = b.diagnostics.items.len;
        defer {
            b.items.shrinkRetainingCapacity(items0);
            b.elements.shrinkRetainingCapacity(elem0);
            b.profiles.shrinkRetainingCapacity(elem0);
            b.diagnostics.shrinkRetainingCapacity(diag0);
        }
        _ = try b.atomsLine(atoms, cap, 0, 0, 0);
        var ink = Box.empty;
        for (b.elements.items[elem0..]) |e| ink = ink.join(e.ink);
        return ink.width();
    }

    fn inkContact(b: *const Builder) bool {
        return b.ctx.spec.contact == .ink;
    }

    /// The profile of items `from..` (one element's), appended to `profiles`.
    fn addProfile(b: *Builder, from: usize) !void {
        var p = Profile.empty;
        for (b.items.items[from..]) |item| {
            const outline = switch (item) {
                .glyph => |g| try (try b.ctx.faces[g.face].outline(g.gid)).transformed(b.a, g.transform),
                .path => |q| q.outline,
            };
            p = try Profile.join(b.a, p, try Profile.fromOutline(b.a, outline, b.band));
        }
        try b.profiles.append(b.a, p);
    }

    /// Moves everything laid out since item `item0` and element `elem0`
    /// right by `dx`.
    fn shiftSince(b: *Builder, item0: usize, elem0: usize, dx: f64) !void {
        const move = Affine.translate(dx, 0);
        for (b.items.items[item0..]) |*item| switch (item.*) {
            .glyph => |*g| g.transform = g.transform.then(move),
            .path => |*q| q.outline = try q.outline.transformed(b.a, move),
        };
        for (b.elements.items[elem0..], b.profiles.items[elem0..]) |*e, *p| {
            e.origin.x += dx;
            e.ink = moved(e.ink, dx);
            p.shift(dx);
        }
    }

    /// How far to move elements `next0..next1` right (or left, if negative)
    /// so their ink clears elements `prev0..prev1` by exactly `gap`, at the
    /// heights both have ink. Where they share no height, their ink boxes
    /// decide. Null when either side has no ink.
    fn contactShift(b: *Builder, prev0: usize, prev1: usize, next0: usize, next1: usize, gap: f64) !?f64 {
        var prev = Profile.empty;
        var prev_ink = Box.empty;
        for (b.profiles.items[prev0..prev1], b.elements.items[prev0..prev1]) |p, e| {
            prev = try Profile.join(b.a, prev, p);
            prev_ink = prev_ink.join(e.ink);
        }
        var next = Profile.empty;
        var next_ink = Box.empty;
        for (b.profiles.items[next0..next1], b.elements.items[next0..next1]) |p, e| {
            next = try Profile.join(b.a, next, p);
            next_ink = next_ink.join(e.ink);
        }
        if (prev_ink.isEmpty() or next_ink.isEmpty()) return null;
        const reach: usize = @intFromFloat(@round(b.ctx.spec.contact_reach * b.ctx.spec.cap_height / b.band));
        prev = try Profile.reached(b.a, prev, reach);
        if (Profile.clearance(prev, next)) |c| return gap - c;
        return gap - (next_ink.x0 - prev_ink.x1);
    }

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
        return b.atomsLine(atoms.items, cap, level, x, y);
    }

    /// Lays out atoms as one line; see `nodes`.
    fn atomsLine(b: *Builder, atoms: []const Atom, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        const mu = (try b.ctx.em(cap)) / 18;
        const line0 = b.elements.items.len;
        var pen = x;
        var prev: ?Class = null;
        for (atoms) |atom| {
            var space: f64 = 0;
            if (prev) |p| {
                if (spacing(b.ctx.spec.spacing, p, atom.class, level)) |amount| space = amount * mu;
            }
            pen += space;
            const item0 = b.items.items.len;
            const elem0 = b.elements.items.len;
            var end = switch (atom.node) {
                .text => |t| try b.text(t, atom.start, atom.end, cap, level, pen, y),
                else => try b.node(atom.node, cap, level, pen, y),
            };
            // By ink: clear everything earlier on this line by the target
            // gap, unless hand spacing comes between.
            const touching = prev != null and prev.? != .space and atom.class != .space;
            if (b.inkContact() and touching and elem0 > line0 and b.elements.items.len > elem0) {
                const target = space + b.ctx.spec.contact_gap * cap;
                if (try b.contactShift(line0, elem0, elem0, b.elements.items.len, target)) |d| {
                    try b.shiftSince(item0, elem0, d);
                    end += d;
                }
            }
            pen = end;
            prev = atom.class;
        }
        return pen;
    }

    fn node(b: *Builder, n: markup.Node, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        switch (n) {
            .text => |t| return b.text(t, 0, t.utf8.len, cap, level, x, y),
            .group => |g| return b.nodes(g.items, cap, level, x, y),
            .scripts => |s| {
                const base0 = b.elements.items.len;
                const base_end = try b.node(s.base.*, cap, level, x, y);
                const base1 = b.elements.items.len;
                const script_cap = cap * b.ctx.script_scale;
                const gap = b.ctx.spec.script_gap * cap;
                var end = base_end;
                for ([_]?*const markup.Node{ s.sup, s.sub }, [_]f64{ b.ctx.sup_raise, -b.ctx.sub_drop }) |script, rise| {
                    const node_ = script orelse continue;
                    const item0 = b.items.items.len;
                    const elem0 = b.elements.items.len;
                    var script_end = try b.node(node_.*, script_cap, level + 1, base_end + gap, y + rise * cap);
                    // By ink: each script clears its base's ink by the gap.
                    if (b.inkContact() and base1 > base0 and b.elements.items.len > elem0) {
                        if (try b.contactShift(base0, base1, elem0, b.elements.items.len, gap)) |d| {
                            try b.shiftSince(item0, elem0, d);
                            script_end += d;
                        }
                    }
                    end = @max(end, script_end);
                }
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
            .placeholder => |ph| return b.placeholder(ph, cap, level, x, y),
            .radical => |r| return b.radical(r, cap, level, x, y),
            .line_break => |br| {
                // A soft break not taken is nothing. A hard break inside a
                // group or script cannot start a line there.
                if (br.kind == .hard) try b.diagnose(.not_rendered, br.span.start);
                return x;
            },
        }
    }

    /// \sqrt: the body, then a radical sign drawn as strokes (a short tick,
    /// a downstroke below the baseline, a long upstroke) running into a
    /// vinculum over the body. Stroke weight and the gap above the body are
    /// the overbar's (the MATH table's when the face has one), so the sign
    /// keeps one weight at any height and its geometry is exact for DRC.
    fn radical(b: *Builder, r: markup.Radical, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        const t = b.ctx.rule_thickness * cap;
        const gap = b.ctx.accent_gap * cap;
        // The body first, after room for the sign; its ink sets the height.
        const sign_w = 0.55 * cap;
        const body_x = x + sign_w + 0.12 * cap;
        const first = b.elements.items.len;
        const body_end = try b.node(r.body.*, cap, level, body_x, y);
        var body = Box.empty;
        for (b.elements.items[first..]) |e| body = body.join(e.ink);
        // An empty body still gets a sign a capital high.
        const top_ink = if (body.isEmpty()) y + cap else @max(body.y1, y + 0.7 * cap);
        const low_ink = if (body.isEmpty()) y else @min(body.y0, y);
        const right = if (body.isEmpty()) body_end else @max(body_end, body.x1);

        // The centreline: tick, down, up, across.
        const top = top_ink + gap + t / 2;
        const bottom = low_ink - 0.08 * cap;
        const pts = [_]geom.Point{
            .{ .x = x, .y = y + 0.42 * cap },
            .{ .x = x + 0.14 * sign_w, .y = y + 0.5 * cap },
            .{ .x = x + 0.45 * sign_w, .y = bottom + t / 2 },
            .{ .x = x + sign_w, .y = top },
            .{ .x = right + 0.08 * cap, .y = top },
        };
        const outline = try strokePolyline(b.a, &pts, t);
        const item0 = b.items.items.len;
        try b.items.append(b.a, .{ .path = .{ .outline = outline, .element = @intCast(b.elements.items.len) } });
        try b.addProfile(item0);
        try b.elements.append(b.a, .{
            .face = null,
            .start = r.span.start,
            .end = r.span.end,
            .level = level,
            .line = b.line,
            .cap_height = cap,
            .origin = .{ .x = x, .y = y },
            .advance = 0,
            .ink = outline.bounds(),
        });
        return right + 0.08 * cap + t / 2;
    }

    /// An empty slot in a preview: a frame the size of a capital, on the
    /// baseline, so where the next character goes shows.
    fn placeholder(b: *Builder, ph: markup.Placeholder, cap: f64, level: u8, x: f64, y: f64) Error!f64 {
        const w = 0.6 * cap;
        const t = 0.07 * cap;
        const outer: Box = .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + cap };
        const inner: Box = .{ .x0 = x + t, .y0 = y + t, .x1 = x + w - t, .y1 = y + cap - t };
        const a = try rectangle(b.a, outer);
        const hole = try rectangle(b.a, inner);
        // The hole runs the other way, so the frame fills nonzero.
        const segs = try b.a.alloc(geom.Segment, 4);
        const hs = hole.contours[0].segments;
        for (segs, 0..) |*seg, k| {
            const sg = hs[3 - k].line;
            seg.* = .{ .line = .{ sg[1], sg[0] } };
        }
        const contours = try b.a.alloc(geom.Contour, 2);
        contours[0] = a.contours[0];
        contours[1] = .{ .segments = segs };
        const item0 = b.items.items.len;
        try b.items.append(b.a, .{ .path = .{
            .outline = .{ .contours = contours },
            .element = @intCast(b.elements.items.len),
            .role = .placeholder,
        } });
        // Every element has a contact profile, so neighbours clear it.
        try b.addProfile(item0);
        try b.elements.append(b.a, .{
            .face = null,
            .start = ph.span.start,
            .end = ph.span.end,
            .level = level,
            .line = b.line,
            .cap_height = cap,
            .origin = .{ .x = x, .y = y },
            .advance = w,
            .ink = outer,
        });
        return x + w;
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
                const item0 = b.items.items.len;
                try b.items.append(b.a, .{ .path = .{
                    .outline = try rectangle(b.a, bar),
                    .element = @intCast(b.elements.items.len),
                } });
                try b.addProfile(item0);
                try b.elements.append(b.a, .{
                    .face = null,
                    .start = acc.span.start,
                    .end = acc.span.end,
                    .level = level,
                    .line = b.line,
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
        const item0 = b.items.items.len;
        try b.items.append(b.a, .{ .glyph = item });
        try b.addProfile(item0);
        try b.elements.append(b.a, .{
            .face = face_id,
            .start = span.start,
            .end = span.end,
            .level = level,
            .line = b.line,
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
        const item0 = b.items.items.len;
        for (glyphs) |g| {
            if (g.gid == 0) try b.diagnose(.missing_glyph, t.source[start + g.cluster]);
            const gx = x + (pen + @as(f64, @floatFromInt(g.x_offset))) * s;
            const gy = y + @as(f64, @floatFromInt(g.y_offset)) * s;
            const item: render.GlyphItem = .{
                .face = face_id,
                .gid = g.gid,
                .transform = Affine.scale(s).then(Affine.translate(gx, gy)),
                .element = element_id,
                .faint = t.faint,
            };
            ink = ink.join(try render.glyphInk(b.a, face, item));
            try b.items.append(b.a, .{ .glyph = item });
            pen += @floatFromInt(g.x_advance);
        }
        const advance = pen * s;
        try b.addProfile(item0);
        try b.elements.append(b.a, .{
            .face = face_id,
            .start = t.source[start],
            .end = t.source[end - 1] + 1,
            .level = level,
            .line = b.line,
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
                const cp = firstCodepoint(t.utf8[i..next]);
                const class = clusterClass(cp);
                const breakable = cp == ' ';
                const last = if (out.items.len > 0) &out.items[out.items.len - 1] else null;
                const joins = last != null and last.?.node == .text and last.?.node.text.utf8.ptr == t.utf8.ptr and
                    last.?.end == i and last.?.class == class and last.?.breakable == breakable and
                    (class == .ord or class == .space);
                if (joins) {
                    last.?.end = next;
                } else {
                    try out.append(a, .{ .node = n, .start = i, .end = next, .class = class, .breakable = breakable });
                }
                i = next;
            }
        },
        .scripts => |s| try out.append(a, .{ .node = n, .class = nucleusClass(s.base.*) }),
        .group, .accent, .placeholder, .radical => try out.append(a, .{ .node = n, .class = .ord }),
        .space => try out.append(a, .{ .node = n, .class = .space }),
        .line_break => |br| try out.append(a, .{ .node = n, .class = .space, .breakable = br.kind == .soft }),
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
/// An open polyline stroked `width` wide with mitred joins and square ends,
/// as one closed contour: down one side and back up the other.
fn strokePolyline(a: Allocator, pts: []const geom.Point, width: f64) !geom.Outline {
    const h = width / 2;
    const n = pts.len;
    const left = try a.alloc(geom.Point, n);
    const right = try a.alloc(geom.Point, n);
    for (pts, 0..) |p, k| {
        // The offset direction: the segment's normal at the ends, the
        // mitre (the sum of the two normals, scaled) between.
        const n0 = if (k > 0) normal(pts[k - 1], p) else normal(p, pts[k + 1]);
        const n1 = if (k + 1 < n) normal(p, pts[k + 1]) else n0;
        var m: geom.Point = .{ .x = n0.x + n1.x, .y = n0.y + n1.y };
        const len = @sqrt(m.x * m.x + m.y * m.y);
        m = .{ .x = m.x / len, .y = m.y / len };
        const cos = m.x * n0.x + m.y * n0.y;
        const s = h / @max(cos, 0.25); // a limited mitre
        left[k] = .{ .x = p.x + m.x * s, .y = p.y + m.y * s };
        right[k] = .{ .x = p.x - m.x * s, .y = p.y - m.y * s };
    }
    var ring = try a.alloc(geom.Point, 2 * n);
    for (0..n) |k| ring[k] = right[k];
    for (0..n) |k| ring[n + k] = left[n - 1 - k];
    const segs = try a.alloc(geom.Segment, ring.len);
    for (segs, 0..) |*seg, k| seg.* = .{ .line = .{ ring[k], ring[(k + 1) % ring.len] } };
    const contours = try a.alloc(geom.Contour, 1);
    contours[0] = .{ .segments = segs };
    var o: geom.Outline = .{ .contours = contours };
    // Counter-clockwise, as glyph ink is, so it fills with them nonzero.
    if (o.signedArea() < 0) {
        std.mem.reverse(geom.Point, ring);
        for (segs, 0..) |*seg, k| seg.* = .{ .line = .{ ring[k], ring[(k + 1) % ring.len] } };
        o = .{ .contours = contours };
    }
    return o;
}

/// The unit normal to the left of the direction from `p` to `q`.
fn normal(p: geom.Point, q: geom.Point) geom.Point {
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const len = @sqrt(dx * dx + dy * dy);
    return .{ .x = -dy / len, .y = dx / len };
}

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
/// Placement by advances, so positions follow from the fonts' metrics alone.
fn testSpec() style.Spec {
    return .{ .upright = 0, .cap_height = 7, .script_gap = 0, .contact = .advance };
}

/// Placement by ink, with no gaps, so positions follow from the ink alone.
fn inkSpec() style.Spec {
    return .{ .upright = 0, .cap_height = 7, .script_gap = 0, .contact = .ink, .contact_gap = 0, .contact_reach = 0 };
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

    // A hard break inside a script cannot start a line there.
    var br = try renderTest(&ctx, "H^{H\\\\H}");
    defer br.deinit();
    try testing.expect(br.diagnostics[0].kind == .not_rendered);
    try testing.expectEqual(@as(usize, 3), br.items.len); // the text is still drawn
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

test "by ink, a superscript clears its base's ink where they share height" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, inkSpec());

    // H's ink ends at 5.5 mm; the raised O (3.85 to 8.75 mm) overlaps it from
    // 3.85 to 7 mm, so O's ink (0.35 mm into it) starts at 5.5.
    var r = try renderTest(&ctx, "H^O");
    defer r.deinit();
    try testing.expectApproxEqAbs(@as(f64, 5.15), r.elements[1].origin.x, eps);
    try testing.expectApproxEqAbs(@as(f64, 5.5), r.elements[1].ink.x0, eps);

    // D is 3 mm tall, wholly below the raised O: their ink boxes decide.
    var low = try renderTest(&ctx, "D^O");
    defer low.deinit();
    try testing.expectApproxEqAbs(@as(f64, 6.5), low.elements[1].ink.x0, eps);
}

test "by ink, a neighbour clears what it overlaps and tucks under what it does not" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, inkSpec());

    // The next H (0 to 7 mm) overlaps the raised O, so it clears O's ink.
    var high = try renderTest(&ctx, "H^OH");
    defer high.deinit();
    try testing.expectApproxEqAbs(high.elements[1].ink.x1, high.elements[2].ink.x0, eps);

    // D (0 to 3 mm) shares no height with the raised O: it tucks under it and
    // only clears the base H.
    var tuck = try renderTest(&ctx, "H^OD");
    defer tuck.deinit();
    try testing.expectApproxEqAbs(@as(f64, 5.5), tuck.elements[2].ink.x0, eps);
    try testing.expect(tuck.elements[2].ink.x0 < tuck.elements[1].ink.x1);
}

test "by ink, operator spacing is added to the ink gap; hand spacing keeps advances" {
    var f = try Fonts.init();
    defer f.deinit();
    var spec = inkSpec();
    spec.contact_gap = 0.1; // 0.7 mm
    const ctx = try style.Context.init(&f.faces, spec);
    const mu = 10.0 / 18.0;

    var bin = try renderTest(&ctx, "H+H");
    defer bin.deinit();
    try testing.expectApproxEqAbs(bin.elements[0].ink.x1 + 0.7 + 2 * mu, bin.elements[1].ink.x0, eps);
    try testing.expectApproxEqAbs(bin.elements[1].ink.x1 + 0.7 + 2 * mu, bin.elements[2].ink.x0, eps);

    var hand = try renderTest(&ctx, "H H");
    defer hand.deinit();
    try testing.expectApproxEqAbs(@as(f64, 8.5), hand.elements[hand.elements.len - 1].origin.x, eps);
}

fn renderBox(ctx: *const style.Context, src: []const u8, opts: Options) !Render {
    var diag: markup.Diagnostic = undefined;
    return renderLabel(testing.allocator, ctx, src, opts, &diag);
}

fn hasOverflow(r: Render) bool {
    for (r.diagnostics) |d| {
        if (d.kind == .overflow) return true;
    }
    return false;
}

test "a hard break starts a new line one pitch down" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderTest(&ctx, "H\\\\H");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 2), r.lines);
    try testing.expectEqual(@as(u16, 1), r.elements[1].line);
    try testing.expectApproxEqAbs(@as(f64, 0), r.elements[1].origin.x, eps);
    try testing.expectApproxEqAbs(@as(f64, -10), r.elements[1].origin.y, eps); // ascender 800 to descender -200
    try testing.expectEqualSlices(u32, &.{1}, r.breaks);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "lines wrap at a breaking space or \\allowbreak when the hard box is too narrow" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    const box: Box = .{ .x0 = 0, .y0 = -20, .x1 = 13, .y1 = 10 };

    // "HH HH" is 25.5 mm of ink; "HH" alone is 11 mm, so it breaks at the space.
    var r = try renderBox(&ctx, "HH HH", .{ .hard_box = box });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 2), r.lines);
    try testing.expectEqualSlices(u32, &.{2}, r.breaks);
    try testing.expectApproxEqAbs(@as(f64, 0), r.elements[1].origin.x, eps); // the space is dropped
    try testing.expectApproxEqAbs(@as(f64, -10), r.elements[1].origin.y, eps);
    try testing.expect(!hasOverflow(r));

    var soft = try renderBox(&ctx, "HH\\allowbreak HH", .{ .hard_box = box });
    defer soft.deinit();
    try testing.expectEqual(@as(u16, 2), soft.lines);

    // Without a hard box, nothing wraps.
    var free = try renderTest(&ctx, "HH HH");
    defer free.deinit();
    try testing.expectEqual(@as(u16, 1), free.lines);
}

test "a non-breaking space or a long word overflows instead of shrinking" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    const box: Box = .{ .x0 = 0, .y0 = -20, .x1 = 13, .y1 = 10 };

    var nb = try renderBox(&ctx, "HH~HH", .{ .hard_box = box });
    defer nb.deinit();
    try testing.expectEqual(@as(u16, 1), nb.lines);
    try testing.expect(hasOverflow(nb));

    var long = try renderBox(&ctx, "HHH", .{ .hard_box = box });
    defer long.deinit();
    try testing.expect(hasOverflow(long));
    try testing.expectApproxEqAbs(@as(f64, 6), long.elements[0].advance / 3, eps); // full size
}

test "each line sits on the anchor by its own width" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderBox(&ctx, "HH HHH", .{
        .anchor = render.Anchor.centre,
        .hard_box = .{ .x0 = -9, .y0 = -20, .x1 = 9, .y1 = 10 },
    });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 2), r.lines);
    try testing.expectApproxEqAbs(@as(f64, -6), r.elements[0].origin.x, eps); // 12 mm line, centred
    try testing.expectApproxEqAbs(@as(f64, -9), r.elements[1].origin.x, eps); // 18 mm line, centred
}

test "the block shifts away from a hard-box edge before it overflows" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());

    // Started 18 mm in, "HH"'s ink (0.5 to 11.5) would pass the right edge at 20.
    var r = try renderBox(&ctx, "HH", .{
        .hard_box = .{ .x0 = 0, .y0 = -5, .x1 = 20, .y1 = 10 },
        .anchor_at = .{ .x = 18, .y = 0 },
    });
    defer r.deinit();
    try testing.expect(!hasOverflow(r));
    try testing.expectApproxEqAbs(@as(f64, 8.5), r.anchor_at.?.x, eps);

    // Two lines' ink spans -10 to 7 mm; a box from -8 lifts the anchor by 2.
    var two = try renderBox(&ctx, "H\\\\H", .{ .hard_box = .{ .x0 = 0, .y0 = -8, .x1 = 10, .y1 = 12 } });
    defer two.deinit();
    try testing.expect(!hasOverflow(two));
    try testing.expectApproxEqAbs(@as(f64, 2), two.anchor_at.?.y, eps);

    // A box shorter than the block overflows; the first line stays inside.
    var tall = try renderBox(&ctx, "H\\\\H", .{ .hard_box = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 } });
    defer tall.deinit();
    try testing.expect(hasOverflow(tall));
    try testing.expectApproxEqAbs(@as(f64, 3), tall.anchor_at.?.y, eps); // ink top 7 + 3 = box top 10
}

test "a square root's vinculum clears its body by the gap and spans it" {
    var f = try Fonts.init();
    defer f.deinit();
    const ctx = try style.Context.init(&f.faces, testSpec());
    var r = try renderTest(&ctx, "\\sqrt{H}");
    defer r.deinit();
    // The H, then the radical as one stroked path.
    try testing.expectEqual(2, r.elements.len);
    try testing.expectEqual(2, r.items.len);
    const body = r.elements[0].ink;
    const sign = r.elements[1].ink;
    const gap = ctx.accent_gap * 7;
    const t = ctx.rule_thickness * 7;
    // The vinculum's top: the body's top, the gap, the rule.
    try testing.expectApproxEqAbs(body.y1 + gap + t, sign.y1, 1e-9);
    // It covers the body, and the sign runs below the baseline.
    try testing.expect(sign.x0 < body.x0 and sign.x1 > body.x1);
    try testing.expect(sign.y0 < 0);
    // One closed contour, filled counter-clockwise like glyph ink.
    const o = r.items[1].path.outline;
    try testing.expectEqual(1, o.contours.len);
    try testing.expect(o.signedArea() > 0);
}
