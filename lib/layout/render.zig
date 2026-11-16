//! The geometry legends are set into: placed items (a glyph by face and
//! glyph ID with its transform, or a drawn path), the label's boxes, its
//! elements with their source spans, where it may break, and what went
//! wrong, in the label frame: mm, y up, origin on the baseline at the
//! start. Outlines in mm only on request (`Render.outlines`).
//!
//! Glyphic (engine v2) sets legends into it (legend.zig); placement cuts it
//! into pieces at its break opportunities; output, fabrication, DRC and
//! the editor read it. (It was engine v1's render result, kept when v1 was
//! retired.)

const std = @import("std");
const geom = @import("graven_geom");
const font = @import("graven_font");

const Allocator = std.mem.Allocator;
const Affine = geom.Affine;
const Box = geom.Box;
const Outline = geom.Outline;
const Face = font.Face;

/// Index into the faces passed to `render` and `Render.outlines`.
pub const FaceId = u32;

pub const GlyphItem = struct {
    face: FaceId,
    gid: u32,
    /// Font units to the label frame: size, any style transform, placement.
    transform: Affine,
    element: u32,
    /// The source byte its cluster starts at.
    source: u32 = 0,
    /// Preview only: source shown literally because it is not (yet) valid;
    /// not ink.
    faint: bool = false,
    /// How far its outline is grown outward all round, label-frame mm: a
    /// member drawn heavier (`style.Member.weight`).
    grow: f64 = 0,
};

pub const PathItem = struct {
    /// Already in the label frame, mm.
    outline: Outline,
    element: u32,
    /// The source byte of the object it draws (a fraction's rule: the
    /// fraction's).
    source: u32 = 0,
    /// `placeholder` marks an empty slot in a preview: not ink.
    role: enum { ink, placeholder } = .ink,
};

pub const Item = union(enum) {
    glyph: GlyphItem,
    path: PathItem,
};

/// A problem in a legend's source, for the editor to show.
pub const Syntax = struct {
    kind: Kind,
    /// Byte offset in the source.
    offset: u32,

    pub const Kind = enum {
        /// A field left empty: a structure still being typed.
        missing_argument,

        pub fn message(k: Kind) []const u8 {
            return switch (k) {
                .missing_argument => "a field is empty",
            };
        }
    };
};

pub const Diagnostic = struct {
    kind: enum {
        /// No face in the chain has the cluster; the main face's .notdef is drawn.
        missing_glyph,
        /// Parsed but not rendered yet (accents, breaks): the content is
        /// drawn without it.
        not_rendered,
        /// Italic asked for, but the style has no italic face.
        no_italic,
        /// Bold asked for, but the style has no bold face (nor, in math,
        /// mathematical bold characters).
        no_bold,
        /// A math alphabet (\mathbb …) asked for, but no member sets it
        /// and no face has its characters: ordinary letters are drawn.
        no_alphabet,
        /// Content larger than its hard box: a word longer than its line,
        /// or a block wider or taller than the box. Nothing is shrunk.
        overflow,
    },
    /// Byte offset in the source of what is concerned.
    offset: u32,
};

/// A contiguous run sharing one resolved style and face, as placed; or a
/// drawn mark (an overbar), which has no face.
pub const Element = struct {
    face: ?FaceId,
    /// The source bytes it came from.
    start: u32,
    end: u32,
    /// Script depth: 0 for the label's own text, 1 for its scripts, and so on.
    level: u8,
    /// The line it sits on, from 0.
    line: u16 = 0,
    /// Cap height at this element's size, mm.
    cap_height: f64,
    /// Baseline origin in the label frame.
    origin: geom.Point,
    advance: f64,
    ink: Box,
    /// mm per font unit of its face, as set (0 for a drawn mark).
    units: f64 = 0,
};

/// Where a one-line render may break: a space between words, \allowbreak,
/// or \- (whose break would need a hyphen drawn). What comes before it ends
/// at `x0`; what comes after starts at `x1` (label frame, mm); items and
/// elements before it number `item0` and `elem0`, and those after it start
/// at `item1` and `elem1`.
pub const Opportunity = struct {
    /// Its source bytes.
    start: u32,
    end: u32,
    x0: f64,
    x1: f64,
    item0: u32,
    elem0: u32,
    item1: u32,
    elem1: u32,
    hyphen: bool = false,
};

pub const Caret = struct {
    x: f64,
    y0: f64,
    y1: f64,

    fn at(e: Element, x: f64) Caret {
        return .{ .x = x, .y0 = e.origin.y - 0.25 * e.cap_height, .y1 = e.origin.y + 1.15 * e.cap_height };
    }
};

pub const Render = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Item,
    /// Advance by ascender and descender: the box used for alignment.
    design: Box,
    /// The tight box of the ink.
    ink: Box,
    diagnostics: []const Diagnostic,
    elements: []const Element = &.{},
    /// From a preview render: what the lenient parse found wrong. Empty for
    /// valid markup.
    syntax: []const Syntax = &.{},
    /// With a hard box: where the anchor (the label frame's origin) ended up,
    /// in the box's coordinates, after shifting away from its edges.
    anchor_at: ?geom.Point = null,
    /// Source offsets where lines broke, hard and soft, in order.
    breaks: []const u32 = &.{},
    lines: u16 = 1,
    /// Of a render on one line (no hard box, no hard break): where it may
    /// break, in order, so a flow can set it piece by piece (see `piece`).
    opportunities: []const Opportunity = &.{},

    /// Where a text cursor at source byte `offset` goes in the drawing: a
    /// vertical bar at `x`, from `y0` to `y1` (label frame, mm), sized to the
    /// text it sits in. Null for an empty render.
    pub fn caret(self: Render, offset: u32) ?Caret {
        // Stops: the start of each glyph and drawn mark, and the end of each
        // element. The cursor goes to the stop at its offset, else the
        // nearest one before it; a glyph's start wins a tie over an end.
        var best: ?Caret = null;
        var best_source: u32 = 0;
        var best_start = false;
        const consider = struct {
            fn f(b: *?Caret, bs: *u32, bst: *bool, c: Caret, source: u32, is_start: bool, at: u32) void {
                if (source > at) return;
                if (b.* != null) {
                    if (source < bs.*) return;
                    if (source == bs.* and (bst.* or !is_start)) return;
                }
                b.* = c;
                bs.* = source;
                bst.* = is_start;
            }
        }.f;
        for (self.items) |item| switch (item) {
            .glyph => |g| {
                const e = self.elements[g.element];
                consider(&best, &best_source, &best_start, .at(e, g.transform.e), g.source, true, offset);
            },
            .path => |q| {
                const e = self.elements[q.element];
                const bounds = q.outline.bounds();
                // A slot takes the cursor in its middle.
                const x = if (q.role == .placeholder) (bounds.x0 + bounds.x1) / 2 else bounds.x0;
                consider(&best, &best_source, &best_start, .at(e, x), @max(e.start, q.source), true, offset);
            },
        };
        for (self.elements) |e| {
            const x = if (e.face == null) e.ink.x1 else e.origin.x + e.advance;
            consider(&best, &best_source, &best_start, .at(e, x), e.end, false, offset);
        }
        return best;
    }

    pub fn deinit(self: *Render) void {
        self.arena.deinit();
    }

    /// The part of a one-line render between two of its break
    /// opportunities: after `after` (null: from its start) and before
    /// `before` (null: to its end), moved so it starts at x 0. Allocated
    /// from `a`, which owns it: it is never deinit'ed itself. Diagnostics
    /// go with the piece their source is in; syntax with the first piece.
    pub fn piece(self: *const Render, a: Allocator, after: ?u32, before: ?u32) Allocator.Error!Render {
        const ops = self.opportunities;
        // The first piece keeps the render's frame and its design's start.
        return self.slice(a, .{
            .item0 = if (after) |k| ops[k].item1 else 0,
            .elem0 = if (after) |k| ops[k].elem1 else 0,
            .item1 = if (before) |k| ops[k].item0 else @intCast(self.items.len),
            .elem1 = if (before) |k| ops[k].elem0 else @intCast(self.elements.len),
            .x0 = if (after) |k| ops[k].x1 else 0,
            .x1 = if (before) |k| ops[k].x0 else self.design.x1,
            .src0 = if (after) |k| ops[k].end else 0,
            .src1 = if (before) |k| ops[k].start else std.math.maxInt(u32),
            .first = after == null,
        });
    }

    /// The space of break opportunity `k` alone (drawn only where it is
    /// decorated: an underline runs on under it), moved to start at x 0.
    pub fn spacePiece(self: *const Render, a: Allocator, k: u32) Allocator.Error!Render {
        const o = self.opportunities[k];
        return self.slice(a, .{ .item0 = o.item0, .elem0 = o.elem0, .item1 = o.item1, .elem1 = o.elem1, .x0 = o.x0, .x1 = o.x1, .src0 = o.start, .src1 = o.end, .first = false });
    }

    /// A place a one-line render may be cut: at a break opportunity, or
    /// (for a forced wrap) between two glyphs of a word, where one element
    /// is shared by the pieces either side. What comes before it ends at
    /// item `item0` and element `elem0`, at `x0` and source `src0`; what
    /// comes after starts at `item1`, `elem1`, `x1` and `src1`.
    pub const Cut = struct {
        item0: u32,
        elem0: u32,
        x0: f64,
        src0: u32,
        item1: u32,
        elem1: u32,
        x1: f64,
        src1: u32,

        /// At break opportunity `k`, its source and space left out.
        pub fn at(self: *const Render, k: u32) Cut {
            const o = self.opportunities[k];
            return .{ .item0 = o.item0, .elem0 = o.elem0, .x0 = o.x0, .src0 = o.start, .item1 = o.item1, .elem1 = o.elem1, .x1 = o.x1, .src1 = o.end };
        }
    };

    /// Where a word may be cut when it is longer than its line: before
    /// each glyph of a word that follows another glyph on the same
    /// baseline, from later source, further along (so never inside an
    /// equation's structure), with no break opportunity between. In order.
    pub fn forcedCuts(self: *const Render, a: Allocator) Allocator.Error![]Cut {
        var out: std.ArrayList(Cut) = .empty;
        var k: usize = 1;
        var o: usize = 0;
        while (k < self.items.len) : (k += 1) {
            const p = switch (self.items[k - 1]) {
                .glyph => |g| g,
                else => continue,
            };
            const g = switch (self.items[k]) {
                .glyph => |g| g,
                else => continue,
            };
            while (o < self.opportunities.len and self.opportunities[o].item1 <= k) o += 1;
            // An opportunity right here: a break, not a forced cut.
            if (o > 0 and self.opportunities[o - 1].item1 == k) continue;
            if (o < self.opportunities.len and self.opportunities[o].item0 == k) continue;
            const pe = self.elements[p.element];
            const ge = self.elements[g.element];
            if (pe.level != 0 or ge.level != 0 or pe.face == null or ge.face == null) continue;
            if (pe.origin.y != ge.origin.y or g.source <= p.source or !(g.transform.e > p.transform.e)) continue;
            const shared = p.element == g.element;
            try out.append(a, .{
                .item0 = @intCast(k),
                .elem0 = if (shared) g.element + 1 else g.element,
                .x0 = g.transform.e,
                .src0 = g.source,
                .item1 = @intCast(k),
                .elem1 = g.element,
                .x1 = g.transform.e,
                .src1 = g.source,
            });
        }
        return out.items;
    }

    /// The part of a one-line render between two cuts: after `from` (null:
    /// from its start) and before `to` (null: to its end), moved so it
    /// starts at x 0 (see `piece`). An element shared with the piece either
    /// side is trimmed to this one's glyphs.
    pub fn between(self: *const Render, a: Allocator, from: ?Cut, to: ?Cut) Allocator.Error!Render {
        return self.slice(a, .{
            .item0 = if (from) |c| c.item1 else 0,
            .elem0 = if (from) |c| c.elem1 else 0,
            .item1 = if (to) |c| c.item0 else @intCast(self.items.len),
            .elem1 = if (to) |c| c.elem0 else @intCast(self.elements.len),
            .x0 = if (from) |c| c.x1 else 0,
            .x1 = if (to) |c| c.x0 else self.design.x1,
            .src0 = if (from) |c| c.src1 else 0,
            .src1 = if (to) |c| c.src0 else std.math.maxInt(u32),
            .first = from == null,
        });
    }

    const Slice = struct { item0: u32, elem0: u32, item1: u32, elem1: u32, x0: f64, x1: f64, src0: u32, src1: u32, first: bool };

    fn slice(self: *const Render, a: Allocator, sl: Slice) Allocator.Error!Render {
        const item0 = sl.item0;
        const item1 = sl.item1;
        const elem0 = sl.elem0;
        const elem1 = sl.elem1;
        const x0 = sl.x0;
        const x1 = sl.x1;
        const src0 = sl.src0;
        const src1 = sl.src1;
        const after: ?u32 = if (sl.first) null else 0;
        const move = Affine.translate(-x0, 0);

        const items = try a.alloc(Item, item1 - item0);
        for (self.items[item0..item1], items) |from, *to| to.* = switch (from) {
            .glyph => |g| blk: {
                var c = g;
                c.transform = g.transform.then(move);
                c.element -= elem0;
                break :blk .{ .glyph = c };
            },
            .path => |q| blk: {
                var c = q;
                c.outline = try q.outline.transformed(a, move);
                c.element -= elem0;
                break :blk .{ .path = c };
            },
        };
        const elements = try a.alloc(Element, elem1 - elem0);
        var ink = Box.empty;
        for (self.elements[elem0..elem1], elements) |from, *to| {
            to.* = from;
            // Shared with the piece before (a forced cut): from the cut on.
            if (from.start < src0 and from.end > src0) {
                const end_x = from.origin.x + from.advance;
                to.start = src0;
                to.origin.x = x0;
                to.advance = end_x - x0;
                if (!from.ink.isEmpty()) to.ink.x0 = @max(from.ink.x0, x0);
            }
            // Shared with the piece after: up to the cut.
            if (from.start < src1 and from.end > src1) {
                to.end = src1;
                to.advance = x1 - to.origin.x;
                if (!from.ink.isEmpty()) to.ink.x1 = @min(to.ink.x1, x1);
            }
            to.origin.x -= x0;
            if (!to.ink.isEmpty()) to.ink = .{ .x0 = to.ink.x0 - x0, .y0 = to.ink.y0, .x1 = to.ink.x1 - x0, .y1 = to.ink.y1 };
            ink = ink.join(to.ink);
        }
        var diagnostics: std.ArrayList(Diagnostic) = .empty;
        for (self.diagnostics) |d| if (d.offset >= src0 and d.offset < src1) try diagnostics.append(a, d);
        return .{
            .arena = .init(a),
            .items = items,
            .design = .{ .x0 = if (after == null) self.design.x0 else 0, .y0 = self.design.y0, .x1 = x1 - x0, .y1 = self.design.y1 },
            .ink = ink,
            .diagnostics = diagnostics.items,
            .elements = elements,
            .syntax = if (after == null) self.syntax else &.{},
        };
    }

    /// Each item's contours in the label frame (mm), allocated from `gpa`;
    /// an arena suits, since the result is freed as a whole.
    pub fn outlines(self: Render, gpa: Allocator, faces: []const *Face) ![]Outline {
        const out = try gpa.alloc(Outline, self.items.len);
        for (self.items, out) |item, *o| {
            o.* = switch (item) {
                .glyph => |g| try glyphOutline(gpa, faces[g.face], g),
                .path => |p| p.outline,
            };
        }
        return out;
    }
};

/// A placed glyph's outline in the label frame, mm, grown as it says;
/// allocated from `gpa` (an arena suits).
pub fn glyphOutline(gpa: Allocator, face: *Face, g: GlyphItem) !Outline {
    const o = try (try face.outline(g.gid)).transformed(gpa, g.transform);
    // Flattened to a tenth of the growth: well under the ink's own
    // precision at any size it is grown at.
    return if (g.grow > 0) geom.grow.grow(gpa, o, g.grow, g.grow / 10) else o;
}

/// A placed glyph's ink: its font-unit bounds mapped directly when the
/// transform only scales and moves, else the exact bounds of the
/// transformed outline.
pub fn glyphInk(scratch: Allocator, face: *Face, g: GlyphItem) !Box {
    const b = try glyphInkUngrown(scratch, face, g);
    // Growing by a disc grows the bounds by its radius exactly.
    if (b.isEmpty() or !(g.grow > 0)) return b;
    return .{ .x0 = b.x0 - g.grow, .y0 = b.y0 - g.grow, .x1 = b.x1 + g.grow, .y1 = b.y1 + g.grow };
}

fn glyphInkUngrown(scratch: Allocator, face: *Face, g: GlyphItem) !Box {
    const o = try face.outline(g.gid);
    const m = g.transform;
    if (m.b == 0 and m.c == 0) {
        const b = o.bounds();
        if (b.isEmpty()) return b;
        return Box.empty.addPoint(m.apply(.{ .x = b.x0, .y = b.y0 })).addPoint(m.apply(.{ .x = b.x1, .y = b.y1 }));
    }
    return (try o.transformed(scratch, m)).bounds();
}


/// One run of UTF-8 text in one face (`faces[face_id]`), its cap height
/// `cap` mm, from the origin: no markup, no fallback (a character the face
/// lacks is its .notdef, and reported). For font samples.
pub fn run(gpa: Allocator, faces: []const *Face, face_id: FaceId, text: []const u8, cap: f64) !Render {
    if (!(cap > 0)) return error.InvalidSize;
    const face = faces[face_id];
    const cap_units = (try face.capHeight()) orelse return error.NoCapHeight;
    const s = cap / cap_units;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(Item) = .empty;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var ink = Box.empty;
    var pen: f64 = 0;
    for (try face.shape(a, text)) |g| {
        if (g.gid == 0) try diagnostics.append(a, .{ .kind = .missing_glyph, .offset = g.cluster });
        const x: f64 = pen + @as(f64, @floatFromInt(g.x_offset));
        const y: f64 = @floatFromInt(g.y_offset);
        const gi: GlyphItem = .{ .face = face_id, .gid = g.gid, .transform = Affine.scale(s).then(Affine.translate(x * s, y * s)), .element = 0, .source = g.cluster };
        try items.append(a, .{ .glyph = gi });
        ink = ink.join(try glyphInk(a, face, gi));
        pen += @floatFromInt(g.advance);
    }
    const ext = face.extents();
    return .{
        .arena = arena,
        .items = items.items,
        .design = .{ .x0 = 0, .y0 = ext.descender * s, .x1 = pen * s, .y1 = ext.ascender * s },
        .ink = ink,
        .diagnostics = diagnostics.items,
    };
}

const testing = std.testing;

test "a run in one face: cap height from H, ink and design box" {
    const face = try Face.init(testing.allocator, @import("graven_testdata").truetype, 0);
    defer face.deinit();
    var r = try run(testing.allocator, &.{face}, 0, "HO", 4);
    defer r.deinit();
    try testing.expectEqual(2, r.items.len);
    try testing.expectApproxEqAbs(4, r.ink.y1, 0.05);
    try testing.expect(r.design.x1 > r.ink.x1 - 1e-9);
    try testing.expectEqual(0, r.diagnostics.len);
}
