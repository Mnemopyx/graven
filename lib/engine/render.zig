//! The engine's native geometry: a render result of placed items, with
//! outlines expanded only on request.
//!
//! Level 1, `Render`: placed items (a glyph by face and glyph ID with its
//! transform, or a drawn path), the label's boxes and diagnostics, in the
//! label frame: mm, y up, origin at the anchor on the baseline.
//! Level 2, `Render.outlines`: each item's closed contours in mm, stamped out
//! from the face's cached font-unit outlines only when needed.

const std = @import("std");
const hb = @import("hb");
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
};

pub const PathItem = struct {
    /// Already in the label frame, mm.
    outline: Outline,
    element: u32,
};

pub const Item = union(enum) {
    glyph: GlyphItem,
    path: PathItem,
};

/// Where the label frame's origin sits on the baseline: the soft box's start
/// edge, its end edge, or between them, held by two springs. The stiffer
/// spring pulls the anchor closer to its edge; equal tensions centre it.
pub const Anchor = union(enum) {
    start,
    end,
    between: struct { to_start: f64, to_end: f64 },

    pub const centre: Anchor = .{ .between = .{ .to_start = 1, .to_end = 1 } };

    /// The anchor's distance from the start edge of a box `width` wide.
    pub fn offset(a: Anchor, width: f64) error{InvalidTension}!f64 {
        return switch (a) {
            .start => 0,
            .end => width,
            .between => |t| {
                if (!(t.to_start > 0 and t.to_end > 0)) return error.InvalidTension;
                return width * t.to_end / (t.to_start + t.to_end);
            },
        };
    }
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
    /// Cap height at this element's size, mm.
    cap_height: f64,
    /// Baseline origin in the label frame.
    origin: geom.Point,
    advance: f64,
    ink: Box,
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

    pub fn deinit(self: *Render) void {
        self.arena.deinit();
    }

    /// Each item's contours in the label frame (mm), allocated from `gpa`;
    /// an arena suits, since the result is freed as a whole.
    pub fn outlines(self: Render, gpa: Allocator, faces: []const *Face) ![]Outline {
        const out = try gpa.alloc(Outline, self.items.len);
        for (self.items, out) |item, *o| {
            o.* = switch (item) {
                .glyph => |g| try (try faces[g.face].outline(g.gid)).transformed(gpa, g.transform),
                .path => |p| p.outline,
            };
        }
        return out;
    }
};

pub const RunOptions = struct {
    /// Size as cap height in mm, measured from the face's H.
    cap_height: f64,
    anchor: Anchor = .start,
};

pub const RenderError = font.Error || error{ NoCapHeight, InvalidTension, InvalidSize };

/// Renders one run of UTF-8 text in one face: the first engine step, before
/// markup, styles and containers.
pub fn renderRun(gpa: Allocator, faces: []const *Face, face_id: FaceId, text: []const u8, opts: RunOptions) RenderError!Render {
    if (!(opts.cap_height > 0)) return error.InvalidSize;
    const face = faces[face_id];
    const cap_units = (try face.capHeight()) orelse return error.NoCapHeight;
    const s = opts.cap_height / cap_units;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const buf = hb.hb_buffer_create() orelse return error.OutOfMemory;
    defer hb.hb_buffer_destroy(buf);
    hb.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    hb.hb_buffer_guess_segment_properties(buf);
    hb.hb_shape(face.font, buf, null, 0);
    if (hb.hb_buffer_allocation_successful(buf) == 0) return error.OutOfMemory;

    var n: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buf, &n);
    const positions = hb.hb_buffer_get_glyph_positions(buf, &n);

    var items: std.ArrayList(Item) = .empty;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var pen: f64 = 0;
    for (infos[0..n], positions[0..n]) |info, pos| {
        if (info.codepoint == 0) try diagnostics.append(a, .{ .kind = .missing_glyph, .offset = info.cluster });
        const x: f64 = pen + @as(f64, @floatFromInt(pos.x_offset));
        const y: f64 = @floatFromInt(pos.y_offset);
        try items.append(a, .{ .glyph = .{
            .face = face_id,
            .gid = info.codepoint,
            .transform = Affine.scale(s).then(Affine.translate(x * s, y * s)),
            .element = 0,
        } });
        pen += @floatFromInt(pos.x_advance);
    }

    // Place the origin at the anchor, then measure.
    const ext = face.extents();
    const width = pen * s;
    const shift = -(try opts.anchor.offset(width));
    var ink = Box.empty;
    for (items.items) |*item| {
        const g = &item.glyph;
        g.transform = g.transform.then(Affine.translate(shift, 0));
        ink = ink.join(try glyphInk(a, face, g.*));
    }

    return .{
        .arena = arena,
        .items = try items.toOwnedSlice(a),
        .design = .{ .x0 = shift, .y0 = ext.descender * s, .x1 = shift + width, .y1 = ext.ascender * s },
        .ink = ink,
        .diagnostics = try diagnostics.toOwnedSlice(a),
    };
}

/// A placed glyph's ink: its font-unit bounds mapped directly when the
/// transform only scales and moves, else the exact bounds of the
/// transformed outline.
pub fn glyphInk(scratch: Allocator, face: *Face, g: GlyphItem) !Box {
    const o = try face.outline(g.gid);
    const m = g.transform;
    if (m.b == 0 and m.c == 0) {
        const b = o.bounds();
        if (b.isEmpty()) return b;
        return Box.empty.addPoint(m.apply(.{ .x = b.x0, .y = b.y0 })).addPoint(m.apply(.{ .x = b.x1, .y = b.y1 }));
    }
    return (try o.transformed(scratch, m)).bounds();
}

const testing = std.testing;
const tt_font = @import("graven_testdata").truetype;
const cff_font = @import("graven_testdata").cff;

test "a run renders as items; outlines are stamped out only on request" {
    const face = try Face.init(testing.allocator, tt_font, 0);
    defer face.deinit();
    const faces = [_]*Face{face};

    // Cap height 7 mm on a 700-unit H: 0.01 mm per font unit.
    var r = try renderRun(testing.allocator, &faces, 0, "HOD", .{ .cap_height = 7 });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.items.len);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);

    // Advances 600 + 600 + 700 units = 19 mm; ink from H's left side bearing
    // (0.5 mm) to D's right edge (12 + 6.5 mm), baseline to cap height.
    try testing.expectApproxEqAbs(@as(f64, 19), r.design.width(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), r.ink.x0, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 18.5), r.ink.x1, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 7), r.ink.y1, 1e-12);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const outlines = try r.outlines(arena.allocator(), &faces);
    // Areas scale by 0.01^2: 35 + 20 + 12 mm^2.
    var total: f64 = 0;
    for (outlines) |o| total += @abs(o.signedArea());
    try testing.expectApproxEqAbs(@as(f64, 67), total, 1e-9);
}

test "the anchor sets the origin: start, end or held between by springs" {
    const face = try Face.init(testing.allocator, tt_font, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    const cases = [_]struct { anchor: Anchor, x0: f64 }{
        .{ .anchor = .start, .x0 = 0 },
        .{ .anchor = .end, .x0 = -12 }, // "HH" is 12 mm wide at 7 mm cap height
        .{ .anchor = Anchor.centre, .x0 = -6 },
        // A spring three times stiffer to the start pulls the anchor to 1/4.
        .{ .anchor = .{ .between = .{ .to_start = 3, .to_end = 1 } }, .x0 = -3 },
    };
    for (cases) |c| {
        var r = try renderRun(testing.allocator, &faces, 0, "HH", .{ .cap_height = 7, .anchor = c.anchor });
        defer r.deinit();
        try testing.expectApproxEqAbs(c.x0, r.design.x0, 1e-12);
    }
    try testing.expectError(error.InvalidTension, renderRun(testing.allocator, &faces, 0, "H", .{
        .cap_height = 7,
        .anchor = .{ .between = .{ .to_start = 0, .to_end = 1 } },
    }));
}

test "a character the face lacks is reported, not dropped" {
    const face = try Face.init(testing.allocator, cff_font, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    var r = try renderRun(testing.allocator, &faces, 0, "HxO", .{ .cap_height = 7 });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(@as(u32, 1), r.diagnostics[0].offset);
}

test "rendering is deterministic, bit for bit" {
    const face = try Face.init(testing.allocator, cff_font, 0);
    defer face.deinit();
    const faces = [_]*Face{face};
    var r1 = try renderRun(testing.allocator, &faces, 0, "DOH A", .{ .cap_height = 3.175, .anchor = Anchor.centre });
    defer r1.deinit();
    var r2 = try renderRun(testing.allocator, &faces, 0, "DOH A", .{ .cap_height = 3.175, .anchor = Anchor.centre });
    defer r2.deinit();
    try testing.expectEqualDeep(r1.items, r2.items);
    try testing.expectEqual(r1.ink, r2.ink);
}
