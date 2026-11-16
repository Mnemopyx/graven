//! Glyphs drawn from multi-channel signed distance fields (see
//! `geom.msdf`): the canvas's display path for text.
//!
//! Each glyph's field is made once (per face and glyph). For the size it is
//! shown at and the weight it is grown by, the field is sampled into an
//! ordinary coverage raster, packed into an atlas page (a texture); every
//! occurrence of that glyph at that size and weight is a textured quad with
//! its own transform, rotation included. Sizes go in quarter octaves and
//! growth in eighths of a pixel, so neighbouring zooms and weights share
//! rasters; the quad is drawn at the exact size, the texture stretched by
//! at most a few percent.
//!
//! Exact outlines stay the truth: export and design-rule checks never use
//! this. Glyphs shown larger than `max_px` are drawn from their outlines.

const std = @import("std");
const dvui = @import("dvui");
const layout = @import("graven_layout");
const geom = layout.geom;

const Allocator = std.mem.Allocator;

/// Texels per cap height in a glyph's field, and its range in texels, at
/// resolution level 0; each level doubles both (the range stays an eighth
/// of the cap height, so growth up to that can be drawn). A field must
/// have at least a texel for every two pixels it is drawn at, or details
/// thinner than a texel (a gap a grown stroke nearly closes) break up:
/// level 0 to a 64 px cap height, 1 to 128, 2 past that.
const field_texels = 32.0;
const field_range = 4.0;
const max_level = 2;

fn levelFor(cap_px: f64) u2 {
    var level: u2 = 0;
    while (level < max_level and cap_px > field_texels * 2 * @as(f64, @floatFromInt(@as(u32, 1) << level))) level += 1;
    return level;
}
/// An atlas page's side, pixels, and how many pages before the atlas starts
/// again.
const page_side = 1024;
const max_pages = 8;
/// Glyphs drawn larger than this (raster height, pixels) are drawn exactly.
pub const max_px = 256.0;

const FieldKey = struct { face: *layout.Face, gid: u32, level: u2 };
const SlotKey = struct {
    face: *layout.Face,
    gid: u32,
    /// The field level it was made from: a coarser one stands in while the
    /// right one is made.
    level: u2 = 0,
    size: i16,
    grow: i16,
    /// Upright on the pixel grid (see `Atlas.alignedSlot`): its horizontal
    /// phase in quarter pixels; else 255.
    phase: u8 = 255,
};

/// Coverage is raised to 1/gamma before it is stored: above 1 darkens the
/// antialiased edge pixels, as text renderers do so small text holds its
/// weight. GRAVEN_TEXT_GAMMA overrides it.
pub var gamma: f64 = 2.2;

/// Stem darkening, as FreeType and macOS do for small text: strokes grown by
/// up to this many pixels at small sizes, fading to none at a cap height of
/// `darken_until` pixels. Display only. GRAVEN_TEXT_DARKEN overrides it
/// (0: none).
pub var darken: f64 = 0;
pub const darken_until = 32.0;

fn darkening(cap_px: f64) f64 {
    return darken * std.math.clamp(1 - cap_px / darken_until, 0, 1);
}

/// Where a raster lies in the atlas, and what it covers.
pub const Slot = struct {
    page: u16,
    /// Its pixels in the page.
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// The font-unit point at its bottom-left corner, and font units per
    /// pixel.
    origin: geom.Point,
    unit: f64,
    /// An upright raster made on the pixel grid: its bottom-left corner in
    /// whole pixels from the pixel holding the glyph's origin (right, and
    /// down from the baseline's row: positive below).
    aligned: ?struct { left: i32, bottom: i32 } = null,
};

const Page = struct {
    pixels: []dvui.Color.PMA,
    texture: ?dvui.Texture = null,
    /// Shelf packing: the current shelf's top and height, and the next x.
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    next_x: u32 = 0,
    dirty: bool = false,
};

/// Makes glyph fields on threads of its own, so the drawing thread never
/// waits on one: requests go in a queue, finished fields come back to be
/// collected at the start of a frame, and `wake` asks for the frame that
/// shows them.
pub const FieldMaker = struct {
    gpa: Allocator,
    io: std.Io,
    wake: *const fn () void,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    threads: [4]?std.Thread = .{ null, null, null, null },
    queue: std.ArrayList(Request) = .empty,
    done: std.ArrayList(Done) = .empty,
    stop: bool = false,

    const Request = struct {
        key: FieldKey,
        generation: u32,
        /// Its own copy of the outline (the face's cache is the drawing
        /// thread's), freed with it.
        arena: std.heap.ArenaAllocator,
        outline: geom.Outline,
        opts: geom.msdf.Options,
    };
    const Done = struct { key: FieldKey, generation: u32, field: ?geom.msdf.Field };

    fn submit(fm: *FieldMaker, r: Request) void {
        fm.mutex.lockUncancelable(fm.io);
        defer fm.mutex.unlock(fm.io);
        fm.queue.append(fm.gpa, r) catch {
            var rr = r;
            rr.arena.deinit();
            return;
        };
        if (fm.threads[0] == null) {
            const n = @min(fm.threads.len, @max(1, (std.Thread.getCpuCount() catch 2) -| 1));
            for (fm.threads[0..n]) |*t| t.* = std.Thread.spawn(.{}, loop, .{fm}) catch null;
        }
        fm.cond.signal(fm.io);
    }

    fn loop(fm: *FieldMaker) void {
        while (true) {
            fm.mutex.lockUncancelable(fm.io);
            while (fm.queue.items.len == 0 and !fm.stop) fm.cond.waitUncancelable(fm.io, &fm.mutex);
            if (fm.stop) {
                fm.mutex.unlock(fm.io);
                return;
            }
            // The newest first: what was asked for last is most likely
            // still in view.
            var r = fm.queue.pop().?;
            fm.mutex.unlock(fm.io);

            const f = geom.msdf.generate(fm.gpa, r.outline, r.opts) catch null;
            r.arena.deinit();

            fm.mutex.lockUncancelable(fm.io);
            fm.done.append(fm.gpa, .{ .key = r.key, .generation = r.generation, .field = f }) catch {
                if (f) |ff| ff.deinit(fm.gpa);
            };
            fm.mutex.unlock(fm.io);
            fm.wake();
        }
    }

    /// Stops the threads (each finishes the field it is making) and frees
    /// what is queued or done.
    fn deinit(fm: *FieldMaker) void {
        fm.mutex.lockUncancelable(fm.io);
        fm.stop = true;
        fm.cond.broadcast(fm.io);
        fm.mutex.unlock(fm.io);
        for (&fm.threads) |*t| if (t.*) |th| {
            th.join();
            t.* = null;
        };
        for (fm.queue.items) |*r| r.arena.deinit();
        fm.queue.deinit(fm.gpa);
        for (fm.done.items) |d| if (d.field) |f| f.deinit(fm.gpa);
        fm.done.deinit(fm.gpa);
    }
};

pub const Atlas = struct {
    gpa: Allocator,
    /// Made off the drawing thread when set (see `startMaker`); else made
    /// where asked for.
    maker: ?*FieldMaker = null,
    /// Fields asked of the maker and not yet back.
    pending: std.AutoHashMapUnmanaged(FieldKey, void) = .empty,
    /// Bumped when the fields are forgotten: fields made for an older
    /// generation (of faces since freed) are dropped when they come back.
    generation: u32 = 0,
    fields: std.AutoHashMapUnmanaged(FieldKey, ?geom.msdf.Field) = .empty,
    slots: std.AutoHashMapUnmanaged(SlotKey, ?Slot) = .empty,
    pages: std.ArrayList(Page) = .empty,
    /// Counters for the status bar: fields made, rasters made, rebuilds.
    made_fields: usize = 0,
    made_rasters: usize = 0,
    restarts: usize = 0,

    pub fn init(gpa: Allocator) Atlas {
        return .{ .gpa = gpa };
    }

    /// Makes fields off the drawing thread from now on; `wake` is called
    /// when some are ready.
    pub fn startMaker(at: *Atlas, io: std.Io, wake: *const fn () void) void {
        if (at.maker != null) return;
        const fm = at.gpa.create(FieldMaker) catch return;
        fm.* = .{ .gpa = at.gpa, .io = io, .wake = wake };
        at.maker = fm;
    }

    /// Takes in the fields made since the last frame; true if any came.
    pub fn collect(at: *Atlas) bool {
        const fm = at.maker orelse return false;
        fm.mutex.lockUncancelable(fm.io);
        defer fm.mutex.unlock(fm.io);
        const any = fm.done.items.len > 0;
        for (fm.done.items) |d| {
            if (d.generation != at.generation) {
                if (d.field) |f| f.deinit(at.gpa);
                continue;
            }
            _ = at.pending.remove(d.key);
            at.fields.put(at.gpa, d.key, d.field) catch if (d.field) |f| f.deinit(at.gpa);
            at.made_fields += 1;
        }
        fm.done.clearRetainingCapacity();
        return any;
    }

    /// Frees the atlas's memory; its textures go with the window.
    pub fn deinit(at: *Atlas) void {
        if (at.maker) |fm| {
            fm.deinit();
            at.gpa.destroy(fm);
            at.maker = null;
        }
        for (at.pages.items) |*p| p.texture = null;
        at.clear(true);
        at.pending.deinit(at.gpa);
        at.fields.deinit(at.gpa);
        at.slots.deinit(at.gpa);
        at.pages.deinit(at.gpa);
    }

    /// Forgets every raster (and, with `fields`, every field): when the
    /// faces change (their pointers key the cache) or the atlas is full.
    pub fn clear(at: *Atlas, fields: bool) void {
        for (at.pages.items) |p| {
            if (p.texture) |t| dvui.Texture.destroyLater(t);
            at.gpa.free(p.pixels);
        }
        at.pages.clearRetainingCapacity();
        at.slots.clearRetainingCapacity();
        if (fields) {
            var it = at.fields.valueIterator();
            while (it.next()) |f| if (f.*) |ff| ff.deinit(at.gpa);
            at.fields.clearRetainingCapacity();
            at.pending.clearRetainingCapacity();
            at.generation +%= 1;
        }
    }

    /// A field for `gid` at `level`, or the finest coarser one made while
    /// it is being made (the level used is returned); error.Pending when
    /// none is ready yet. Made off the drawing thread when there is a maker.
    fn field(at: *Atlas, face: *layout.Face, gid: u32, level: u2) !struct { field: ?geom.msdf.Field, level: u2 } {
        const key: FieldKey = .{ .face = face, .gid = gid, .level = level };
        if (at.fields.get(key)) |f| return .{ .field = f, .level = level };
        const o = try face.outline(gid);
        const cap = (try face.capHeight()) orelse @as(f64, @floatFromInt(face.upem)) * 0.7;
        const k: f64 = @floatFromInt(@as(u32, 1) << level);
        const opts: geom.msdf.Options = .{ .scale = field_texels * k / cap, .range = field_range * k };
        const fm = at.maker orelse {
            const f: ?geom.msdf.Field = if (o.contours.len == 0) null else try geom.msdf.generate(at.gpa, o, opts);
            try at.fields.put(at.gpa, key, f);
            at.made_fields += 1;
            return .{ .field = f, .level = level };
        };
        if (o.contours.len == 0) {
            try at.fields.put(at.gpa, key, null);
            return .{ .field = null, .level = level };
        }
        if (!at.pending.contains(key)) {
            // The maker's own copy of the outline.
            var arena: std.heap.ArenaAllocator = .init(at.gpa);
            const copy = copyOutline(arena.allocator(), o) catch {
                arena.deinit();
                return error.OutOfMemory;
            };
            try at.pending.put(at.gpa, key, {});
            fm.submit(.{ .key = key, .generation = at.generation, .arena = arena, .outline = copy, .opts = opts });
        }
        // Meanwhile, the finest coarser field made.
        var lv = level;
        while (lv > 0) {
            lv -= 1;
            if (at.fields.get(.{ .face = face, .gid = gid, .level = lv })) |f| return .{ .field = f, .level = lv };
        }
        return error.Pending;
    }

    /// The raster of `gid` in `face` at `px_per_unit` pixels per font unit,
    /// grown by `grow` font units; null for a blank glyph, or one too large
    /// to raster (draw it exactly).
    pub fn slot(at: *Atlas, face: *layout.Face, gid: u32, px_per_unit: f64, grow: f64) !?Slot {
        if (!(px_per_unit > 0)) return null;
        // Quarter octaves of size, eighths of a pixel of growth.
        const size_step: i16 = @intFromFloat(@round(4 * std.math.log2(px_per_unit)));
        const s = std.math.pow(f64, 2, @as(f64, @floatFromInt(size_step)) / 4);
        const cap0 = (try face.capHeight()) orelse @as(f64, @floatFromInt(face.upem)) * 0.7;
        const grow_step: i16 = @intFromFloat(@round((@max(0, grow) * s + darkening(cap0 * s)) * 8));
        const want = levelFor(cap0 * s);
        // A raster made already at the right level: no field needed.
        const want_key: SlotKey = .{ .face = face, .gid = gid, .size = size_step, .grow = grow_step, .level = want };
        if (at.slots.get(want_key)) |sl| return sl;

        const g = @as(f64, @floatFromInt(grow_step)) / 8 / s;
        const b = (try face.outline(gid)).bounds();
        if (b.isEmpty()) {
            try at.slots.put(at.gpa, want_key, null);
            return null;
        }
        const unit = 1 / s;
        // A pixel of margin all round, past the growth.
        const w: u32 = @intFromFloat(@ceil((b.width() + 2 * g) * s + 2));
        const h: u32 = @intFromFloat(@ceil((b.height() + 2 * g) * s + 2));
        if (@as(f64, @floatFromInt(@max(w, h))) > max_px) return null;
        const got = try at.field(face, gid, want);
        var key = want_key;
        key.level = got.level;
        if (at.slots.get(key)) |sl| return sl;
        const f = got.field orelse {
            try at.slots.put(at.gpa, key, null);
            return null;
        };
        const origin: geom.Point = .{ .x = b.x0 - g - unit, .y = b.y0 - g - unit };

        const sl = try at.raster(f, w, h, .{ .a = unit, .d = unit, .e = origin.x, .f = origin.y }, unit, g, origin, unit);
        try at.slots.put(at.gpa, key, sl);
        return sl;
    }

    /// The raster of `gid` for an upright glyph drawn at `px_per_unit`
    /// pixels per font unit, grown by `grow` font units, its origin
    /// `phase` quarter pixels right of a pixel's left edge, its baseline on
    /// a pixel row; made on that pixel grid at its exact size, so it is
    /// drawn texel for pixel, nothing resampled. Its height is fitted too:
    /// the cap height a whole number of pixels, so the baseline and the
    /// cap line both lie on pixel rows. Null as `slot`.
    pub fn alignedSlot(at: *Atlas, face: *layout.Face, gid: u32, px_per_unit: f64, grow: f64, phase: u2) !?Slot {
        if (!(px_per_unit > 0)) return null;
        // Sizes in 64ths of an octave: the quad is stretched by at most a
        // quarter of a percent.
        const size_step: i16 = @intFromFloat(@round(64 * std.math.log2(px_per_unit)));
        const sx = std.math.pow(f64, 2, @as(f64, @floatFromInt(size_step)) / 64);
        const cap0 = (try face.capHeight()) orelse @as(f64, @floatFromInt(face.upem)) * 0.7;
        const grow_step: i16 = @intFromFloat(@round((@max(0, grow) * sx + darkening(cap0 * sx)) * 8));
        const cap = cap0;
        // The cap height on whole pixels (from 4 pixels up).
        const cap_px = cap * sx;
        const want = levelFor(cap_px);
        const want_key: SlotKey = .{ .face = face, .gid = gid, .size = size_step, .grow = grow_step, .phase = phase, .level = want };
        if (at.slots.get(want_key)) |sl| return sl;
        const sy = if (cap_px >= 4) @round(cap_px) / cap else sx;
        const g = @as(f64, @floatFromInt(grow_step)) / 8 / sx;
        const b = (try face.outline(gid)).bounds();
        if (b.isEmpty()) {
            try at.slots.put(at.gpa, want_key, null);
            return null;
        }
        // Too large to raster: drawn exactly (decided before a field is made).
        if (@max(b.width(), b.height()) * sx > max_px) return null;
        const ph = @as(f64, @floatFromInt(phase)) / 4;
        // Pixel edges fall at font x = (k - ph) / sx and y = m / sy.
        const k: i32 = @as(i32, @intFromFloat(@floor((b.x0 - g) * sx + ph))) - 1;
        const m: i32 = @as(i32, @intFromFloat(@floor((b.y0 - g) * sy))) - 1;
        const kr: i32 = @as(i32, @intFromFloat(@ceil((b.x1 + g) * sx + ph))) + 1;
        const mt: i32 = @as(i32, @intFromFloat(@ceil((b.y1 + g) * sy))) + 1;
        const w: u32 = @intCast(kr - k);
        const h: u32 = @intCast(mt - m);
        if (@as(f64, @floatFromInt(@max(w, h))) > max_px) return null;
        const got = try at.field(face, gid, want);
        var key = want_key;
        key.level = got.level;
        if (at.slots.get(key)) |sl| return sl;
        const f = got.field orelse {
            try at.slots.put(at.gpa, key, null);
            return null;
        };
        const origin: geom.Point = .{ .x = (@as(f64, @floatFromInt(k)) - ph) / sx, .y = @as(f64, @floatFromInt(m)) / sy };
        var sl = try at.raster(f, w, h, .{ .a = 1 / sx, .d = 1 / sy, .e = origin.x, .f = origin.y }, 1 / @sqrt(sx * sy), g, origin, 1 / sx);
        sl.aligned = .{ .left = k, .bottom = -m };
        try at.slots.put(at.gpa, key, sl);
        return sl;
    }

    /// Samples field `f` into a `w` × `h` raster (pixel to font units by
    /// `m`, `px` font units a pixel), grown by `g`, with the gamma, and
    /// packs it.
    fn raster(at: *Atlas, f: geom.msdf.Field, w: u32, h: u32, m: geom.Affine, px: f64, g: f64, origin: geom.Point, unit: f64) !Slot {
        const place = try at.pack(w, h);
        var arena: std.heap.ArenaAllocator = .init(at.gpa);
        defer arena.deinit();
        const cov = try f.rasterize(arena.allocator(), w, h, m, px, g);
        const page = &at.pages.items[place.page];
        const inv = 1 / gamma;
        // Rows from the bottom in the raster, from the top in the page.
        for (0..h) |j| for (0..w) |i| {
            const c0 = cov[j * w + i];
            const c: u8 = if (c0 == 0 or c0 == 255 or gamma == 1) c0 else @intFromFloat(@round(255 * std.math.pow(f64, @as(f64, @floatFromInt(c0)) / 255, inv)));
            page.pixels[(place.y + (h - 1 - j)) * page_side + place.x + i] = .{ .r = c, .g = c, .b = c, .a = c };
        };
        page.dirty = true;
        at.made_rasters += 1;
        return .{ .page = @intCast(place.page), .x = @intCast(place.x), .y = @intCast(place.y), .w = @intCast(w), .h = @intCast(h), .origin = origin, .unit = unit };
    }

    /// Room for a `w` × `h` raster (plus a pixel's gap), on a new shelf or
    /// page if need be; the atlas starts again when it is full.
    fn pack(at: *Atlas, w: u32, h: u32) !struct { page: usize, x: u32, y: u32 } {
        const gw = w + 1;
        const gh = h + 1;
        if (at.pages.items.len > 0) {
            const p = &at.pages.items[at.pages.items.len - 1];
            if (p.next_x + gw > page_side) {
                p.shelf_y += p.shelf_h;
                p.shelf_h = 0;
                p.next_x = 0;
            }
            if (p.shelf_y + gh <= page_side) {
                const x = p.next_x;
                p.next_x += gw;
                p.shelf_h = @max(p.shelf_h, gh);
                return .{ .page = at.pages.items.len - 1, .x = x, .y = p.shelf_y };
            }
        }
        if (at.pages.items.len >= max_pages) {
            // Full: start again (the glyphs in view are rastered anew).
            at.clear(false);
            at.restarts += 1;
        }
        const pixels = try at.gpa.alloc(dvui.Color.PMA, page_side * page_side);
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        try at.pages.append(at.gpa, .{ .pixels = pixels, .next_x = gw, .shelf_h = gh });
        return .{ .page = at.pages.items.len - 1, .x = 0, .y = 0 };
    }

    /// Uploads pages changed since they were last drawn. Call before
    /// drawing quads from them.
    pub fn flush(at: *Atlas) void {
        for (at.pages.items) |*p| {
            if (!p.dirty and p.texture != null) continue;
            if (p.texture) |*t| {
                t.update(p.pixels) catch {};
            } else {
                p.texture = dvui.Texture.create(p.pixels, .{ .width = page_side, .height = page_side, .interpolation = .linear }) catch null;
            }
            p.dirty = false;
        }
    }

    pub fn texture(at: *const Atlas, page: u16) ?dvui.Texture {
        if (page >= at.pages.items.len) return null;
        return at.pages.items[page].texture;
    }
};

fn copyOutline(a: Allocator, o: geom.Outline) Allocator.Error!geom.Outline {
    const contours = try a.alloc(geom.Contour, o.contours.len);
    for (o.contours, contours) |c, *d| d.* = .{ .segments = try a.dupe(geom.Segment, c.segments) };
    return .{ .contours = contours };
}

/// A quad to draw: its corners on screen (bottom-left, bottom-right,
/// top-right, top-left of the raster) and its texture coordinates.
pub const Quad = struct {
    page: u16,
    pos: [4]dvui.Point.Physical,
    uv: [4]@Vector(2, f32),
    col: dvui.Color.PMA,
};

/// The quad for slot `sl`, its font units mapped to screen by `to_px`.
pub fn quad(sl: Slot, to_px: anytype, col: dvui.Color.PMA) Quad {
    const wu = @as(f64, @floatFromInt(sl.w)) * sl.unit;
    const hu = @as(f64, @floatFromInt(sl.h)) * sl.unit;
    const o = sl.origin;
    const corners = [4]geom.Point{ o, .{ .x = o.x + wu, .y = o.y }, .{ .x = o.x + wu, .y = o.y + hu }, .{ .x = o.x, .y = o.y + hu } };
    var q: Quad = .{ .page = sl.page, .pos = undefined, .uv = undefined, .col = col };
    for (corners, &q.pos) |c, *p| p.* = to_px.map(c);
    const side: f32 = page_side;
    const ua = @as(f32, @floatFromInt(sl.x)) / side;
    const ub = @as(f32, @floatFromInt(@as(u32, sl.x) + sl.w)) / side;
    // The raster's bottom row is its last in the page.
    const v_top = @as(f32, @floatFromInt(sl.y)) / side;
    const v_bottom = @as(f32, @floatFromInt(@as(u32, sl.y) + sl.h)) / side;
    q.uv = .{ .{ ua, v_bottom }, .{ ub, v_bottom }, .{ ub, v_top }, .{ ua, v_top } };
    return q;
}

/// The quad for aligned slot `sl`: texel for pixel, its glyph's origin in
/// the pixel whose top-left corner is (`px`, `py`) (`py` the baseline's
/// row's bottom edge).
pub fn alignedQuad(sl: Slot, px: f32, py: f32, col: dvui.Color.PMA) Quad {
    const al = sl.aligned.?;
    const left = px + @as(f32, @floatFromInt(al.left));
    const bottom = py + @as(f32, @floatFromInt(al.bottom));
    const w: f32 = @floatFromInt(sl.w);
    const h: f32 = @floatFromInt(sl.h);
    var q: Quad = .{ .page = sl.page, .col = col, .pos = .{
        .{ .x = left, .y = bottom },         .{ .x = left + w, .y = bottom },
        .{ .x = left + w, .y = bottom - h }, .{ .x = left, .y = bottom - h },
    }, .uv = undefined };
    const side: f32 = page_side;
    const ua = @as(f32, @floatFromInt(sl.x)) / side;
    const ub = @as(f32, @floatFromInt(@as(u32, sl.x) + sl.w)) / side;
    const v_top = @as(f32, @floatFromInt(sl.y)) / side;
    const v_bottom = @as(f32, @floatFromInt(@as(u32, sl.y) + sl.h)) / side;
    q.uv = .{ .{ ua, v_bottom }, .{ ub, v_bottom }, .{ ub, v_top }, .{ ua, v_top } };
    return q;
}

/// Draws `quads`, a call per atlas page.
pub fn drawQuads(at: *Atlas, lifo: Allocator, quads: []const Quad) void {
    if (quads.len == 0) return;
    at.flush();
    var page: u16 = 0;
    while (page < at.pages.items.len) : (page += 1) {
        const tex = at.texture(page) orelse continue;
        var n: usize = 0;
        for (quads) |q| {
            if (q.page == page) n += 1;
        }
        if (n == 0) continue;
        // Vertex indices may be 16-bit: in batches.
        const batch = 8000;
        var done: usize = 0;
        var it: usize = 0;
        while (done < n) {
            const m = @min(batch, n - done);
            var b = dvui.Triangles.Builder.init(lifo, 4 * m, 6 * m) catch return;
            defer b.deinit(lifo);
            var k: usize = 0;
            while (k < m) : (it += 1) {
                const q = quads[it];
                if (q.page != page) continue;
                for (q.pos, q.uv) |p, uv| b.appendVertex(.{ .pos = p, .col = q.col, .uv = uv });
                const i: dvui.Vertex.Index = @intCast(4 * k);
                // Wound as DVUI wants: a mirrored transform turns the quad
                // over.
                const p0 = q.pos[0];
                const p1 = q.pos[1];
                const p2 = q.pos[2];
                const cross = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x);
                if (cross <= 0) b.appendTriangles(&.{ i, i + 1, i + 2, i, i + 2, i + 3 }) else b.appendTriangles(&.{ i, i + 2, i + 1, i, i + 3, i + 2 });
                k += 1;
            }
            dvui.renderTriangles(b.build_unowned(), tex) catch {};
            done += m;
        }
    }
}
