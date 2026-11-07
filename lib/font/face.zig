//! Font faces through HarfBuzz: loading from bytes, glyph outlines, metrics
//! measured from outlines, and glyph lookup.
//!
//! Everything here is in font units. HarfBuzz is the only font parser.

const std = @import("std");
const hb = @import("hb");
const geom = @import("graven_geom");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Segment = geom.Segment;
const Contour = geom.Contour;
const Outline = geom.Outline;

pub const Error = error{ InvalidFont, OutOfMemory };

pub const Face = struct {
    gpa: Allocator,
    bytes: []u8,
    blob: *hb.hb_blob_t,
    face: *hb.hb_face_t,
    font: *hb.hb_font_t,
    draw_funcs: *hb.hb_draw_funcs_t,
    upem: u32,
    /// Outlines by glyph ID, in font units, owned by `arena`.
    outlines: std.AutoHashMapUnmanaged(u32, Outline) = .empty,
    arena: std.heap.ArenaAllocator,

    /// Loads face `index` from a copy of `bytes`; the caller keeps its own.
    pub fn init(gpa: Allocator, bytes: []const u8, index: u32) Error!*Face {
        const self = try gpa.create(Face);
        errdefer gpa.destroy(self);
        const copy = try gpa.dupe(u8, bytes);
        errdefer gpa.free(copy);

        const blob = hb.hb_blob_create(copy.ptr, @intCast(copy.len), hb.HB_MEMORY_MODE_READONLY, null, null) orelse return error.OutOfMemory;
        errdefer hb.hb_blob_destroy(blob);
        const face = hb.hb_face_create(blob, index) orelse return error.OutOfMemory;
        errdefer hb.hb_face_destroy(face);
        if (hb.hb_face_get_glyph_count(face) == 0) return error.InvalidFont;
        const upem = hb.hb_face_get_upem(face);
        if (upem == 0) return error.InvalidFont;

        const font = hb.hb_font_create(face) orelse return error.OutOfMemory;
        errdefer hb.hb_font_destroy(font);
        // Positions and outlines in plain font units.
        hb.hb_font_set_scale(font, @intCast(upem), @intCast(upem));

        const funcs = hb.hb_draw_funcs_create() orelse return error.OutOfMemory;
        hb.hb_draw_funcs_set_move_to_func(funcs, moveTo, null, null);
        hb.hb_draw_funcs_set_line_to_func(funcs, lineTo, null, null);
        hb.hb_draw_funcs_set_quadratic_to_func(funcs, quadTo, null, null);
        hb.hb_draw_funcs_set_cubic_to_func(funcs, cubicTo, null, null);
        hb.hb_draw_funcs_set_close_path_func(funcs, closePath, null, null);
        hb.hb_draw_funcs_make_immutable(funcs);

        self.* = .{
            .gpa = gpa,
            .bytes = copy,
            .blob = blob,
            .face = face,
            .font = font,
            .draw_funcs = funcs,
            .upem = upem,
            .arena = .init(gpa),
        };
        return self;
    }

    pub fn deinit(self: *Face) void {
        hb.hb_draw_funcs_destroy(self.draw_funcs);
        hb.hb_font_destroy(self.font);
        hb.hb_face_destroy(self.face);
        hb.hb_blob_destroy(self.blob);
        self.outlines.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.bytes);
        self.gpa.destroy(self);
    }

    /// The nominal glyph for a codepoint, or null if the face has none.
    pub fn glyph(self: *Face, codepoint: u21) ?u32 {
        var gid: hb.hb_codepoint_t = 0;
        if (hb.hb_font_get_nominal_glyph(self.font, codepoint, &gid) == 0) return null;
        return gid;
    }

    pub fn advance(self: *Face, gid: u32) i32 {
        return hb.hb_font_get_glyph_h_advance(self.font, gid);
    }

    /// Ascender and descender (descender negative), from the font's
    /// horizontal metrics.
    pub fn extents(self: *Face) struct { ascender: f64, descender: f64 } {
        var e: hb.hb_font_extents_t = undefined;
        _ = hb.hb_font_get_h_extents(self.font, &e);
        return .{ .ascender = @floatFromInt(e.ascender), .descender = @floatFromInt(e.descender) };
    }

    /// A glyph's outline in font units, cached. Blank glyphs (space) have no
    /// contours. The outline lives as long as the face.
    pub fn outline(self: *Face, gid: u32) Error!Outline {
        if (self.outlines.get(gid)) |o| return o;
        const a = self.arena.allocator();
        var b: Builder = .{ .gpa = a };
        _ = hb.hb_font_draw_glyph_or_fail(self.font, gid, self.draw_funcs, &b);
        b.close();
        if (b.failed) return error.OutOfMemory;
        const o: Outline = .{ .contours = try b.contours.toOwnedSlice(a) };
        try self.outlines.put(self.gpa, gid, o);
        return o;
    }

    /// Cap height measured from the top of H's outline, not read from OS/2,
    /// whose sCapHeight is often missing or wrong. Null if the face has no H.
    pub fn capHeight(self: *Face) Error!?f64 {
        const gid = self.glyph('H') orelse return null;
        const b = (try self.outline(gid)).bounds();
        return if (b.isEmpty()) null else b.y1;
    }

    /// x-height measured from the top of x's outline, likewise. Null if the
    /// face has no x.
    pub fn xHeight(self: *Face) Error!?f64 {
        const gid = self.glyph('x') orelse return null;
        const b = (try self.outline(gid)).bounds();
        return if (b.isEmpty()) null else b.y1;
    }
};

/// Collects HarfBuzz draw calls into closed contours. Degenerate segments
/// are dropped, and each contour ends exactly on its start.
const Builder = struct {
    gpa: Allocator,
    contours: std.ArrayList(Contour) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    start: Point = .{ .x = 0, .y = 0 },
    last: Point = .{ .x = 0, .y = 0 },
    failed: bool = false,

    fn push(b: *Builder, s: Segment) void {
        const degenerate = switch (s) {
            inline else => |p| for (p[1..]) |q| {
                if (!q.eql(p[0])) break false;
            } else true,
        };
        if (degenerate) return;
        b.segments.append(b.gpa, s) catch {
            b.failed = true;
        };
        b.last = s.end();
    }

    fn close(b: *Builder) void {
        if (b.segments.items.len == 0) return;
        if (!b.last.eql(b.start)) b.push(.{ .line = .{ b.last, b.start } });
        const segs = b.segments.toOwnedSlice(b.gpa) catch {
            b.failed = true;
            return;
        };
        // A lone line closed back on itself encloses nothing.
        const encloses = segs.len >= 2 or segs[0] != .line;
        if (encloses) b.contours.append(b.gpa, .{ .segments = segs }) catch {
            b.failed = true;
        };
    }
};

fn pt(x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}

fn builder(data: ?*anyopaque) *Builder {
    return @ptrCast(@alignCast(data.?));
}

fn moveTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
    const b = builder(data);
    b.close();
    b.start = pt(x, y);
    b.last = b.start;
}

fn lineTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
    const b = builder(data);
    b.push(.{ .line = .{ b.last, pt(x, y) } });
}

fn quadTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, cx: f32, cy: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
    const b = builder(data);
    b.push(.{ .quad = .{ b.last, pt(cx, cy), pt(x, y) } });
}

fn cubicTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
    const b = builder(data);
    b.push(.{ .cubic = .{ b.last, pt(c1x, c1y), pt(c2x, c2y), pt(x, y) } });
}

fn closePath(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, _: ?*anyopaque) callconv(.c) void {
    builder(data).close();
}

const testing = std.testing;
const tt_font = @import("graven_testdata").truetype;
const cff_font = @import("graven_testdata").cff;

fn expectGlyphArea(face: *Face, ch: u21, expected: f64) !void {
    const o = try face.outline(face.glyph(ch).?);
    for (o.contours) |c| try testing.expect(c.isClosed());
    try testing.expectEqual(expected, @abs(o.signedArea()));
}

test "glyph outlines from TrueType (quadratic) and CFF (cubic) have exact areas" {
    for ([_][]const u8{ tt_font, cff_font }) |bytes| {
        const face = try Face.init(testing.allocator, bytes, 0);
        defer face.deinit();
        try testing.expectEqual(@as(u32, 1000), face.upem);
        try expectGlyphArea(face, 'H', 350000);
        try expectGlyphArea(face, 'O', 200000); // hole wound opposite its outer contour
        try expectGlyphArea(face, 'D', 120000);
        // Two overlapping rectangles: the raw sum, before any union.
        try expectGlyphArea(face, 'A', 420000);
        try testing.expectEqual(@as(usize, 0), (try face.outline(face.glyph(' ').?)).contours.len);
    }
}

test "TrueType keeps quadratics native; CFF has cubics" {
    const tt = try Face.init(testing.allocator, tt_font, 0);
    defer tt.deinit();
    const cff = try Face.init(testing.allocator, cff_font, 0);
    defer cff.deinit();
    const d_tt = try tt.outline(tt.glyph('D').?);
    const d_cff = try cff.outline(cff.glyph('D').?);
    var quads: usize = 0;
    for (d_tt.contours[0].segments) |s| quads += @intFromBool(s == .quad);
    var cubics: usize = 0;
    for (d_cff.contours[0].segments) |s| cubics += @intFromBool(s == .cubic);
    try testing.expectEqual(@as(usize, 1), quads);
    try testing.expectEqual(@as(usize, 1), cubics);
}

test "cap height is measured from H, not read from OS/2" {
    // The test fonts' OS/2 sCapHeight is 650; H is 700 tall.
    const face = try Face.init(testing.allocator, tt_font, 0);
    defer face.deinit();
    try testing.expectEqual(@as(?f64, 700), try face.capHeight());
}

test "invalid data is refused" {
    try testing.expectError(error.InvalidFont, Face.init(testing.allocator, "not a font", 0));
}
