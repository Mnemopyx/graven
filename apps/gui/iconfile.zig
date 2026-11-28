//! Icon files: Graven's own (`icons/graven.png` and `.json`, built by
//! `scripts/icons.py`), then the user's, read into rasters per size.
//!
//! The format (blueprint, "Icon files"; scripts/icons.py says it in full):
//! a PNG and its JSON in msdf-atlas-gen's layout, type "graven-ink". Each
//! icon is a cell, the whole of its button. RGB is the icon's ground, a
//! plain raster: the JSON's `transparent` colour lets what is behind show,
//! its `overrides` name colours that may be replaced. Alpha is one ink:
//! 0.5 - d / distanceRange, d the distance to the ink's edge in pixels at
//! the made size, positive inside (255 no ink, 128 the edge).
//!
//! The user's icons are the files in `<data>/icons` (`platform.appDir`):
//! every `name.json` with its `name.png` beside it. An icon there replaces
//! Graven's of the same name; files are read in name order, a later one
//! winning.
//!
//! Drawing: each texel's colour is resolved first (the key transparent, an
//! override its colour), premultiplied, then filtered, so no key shows as
//! a fringe. The ink is sharpened to one pixel at the size drawn: shrunk
//! by half or more, worked out per texel and averaged (thin ink keeps its
//! weight); otherwise from the field, bilinear. Rasters are cached per
//! icon, size in device pixels and ink colour.
//!
//! Hinted cells: a glyph with `px` is its icon hinted for a button exactly
//! that many device pixels square (its horizontal and vertical lines on
//! that size's pixel grid; scripts/icons.py, "Hinting"), its cell a whole
//! multiple of px. Drawn at that size, the icon comes from it; at any
//! other, from the free cell. A hinted cell is only used with the free
//! cell of its own file, so a user's icon replacing Graven's is never
//! drawn as Graven's hinted one.

const std = @import("std");
const dvui = @import("dvui");
const platform = @import("graven_platform");

pub const Rgb = [3]u8;

const Override = struct { key: Rgb, name: []const u8 };

/// One file: its pixels (straight RGBA) and what the JSON says of them.
pub const Sheet = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
    size: f32,
    range: f32,
    ink: Rgb,
    transparent: Rgb,
    overrides: []const Override,
    /// The dark scheme: its ink, and each slot's colour (by name; `key`
    /// holding the colour).
    dark_ink: ?Rgb = null,
    dark_slots: []const Override = &.{},
};

/// An icon: its file, its cell's top left there and its side (texels).
pub const Cell = struct { sheet: *const Sheet, x: u32, y: u32, size: u32 };

var arena_state: ?std.heap.ArenaAllocator = null;
var cells: std.StringHashMapUnmanaged(Cell) = .empty;
var loaded = false;

const Cached = struct { name: []const u8, px: u32, ink: u32, scheme: Scheme, tex: dvui.Texture };

/// The colours an icon's override slots take: its file's own (the keys are
/// their slots' default colours), or its file's scheme for a dark ground
/// (`schemes.dark` in the JSON: a light ink, deeper slots), where light
/// fills would glare under light ink.
pub const Scheme = enum {
    own,
    dark,

    fn colour(s: Scheme, sheet: *const Sheet, slot: []const u8) ?Rgb {
        if (s == .own) return null;
        for (sheet.dark_slots) |o| if (std.mem.eql(u8, o.name, slot)) return o.key;
        return null;
    }
};

/// The ink icon cell `c` takes under `scheme`, if its file names one.
pub fn schemeInk(c: Cell, scheme: Scheme) ?dvui.Color {
    const rgb = switch (scheme) {
        .own => c.sheet.ink,
        .dark => c.sheet.dark_ink orelse return null,
    };
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}
var cached: std.ArrayList(Cached) = .empty;

/// Reads Graven's file and the user's (once).
fn load() void {
    if (loaded) return;
    loaded = true;
    const gpa = dvui.currentWindow().gpa;
    arena_state = .init(gpa);
    const a = arena_state.?.allocator();
    add(a, @embedFile("icons/graven.json"), @embedFile("icons/graven.png"), "graven") catch |err|
        std.log.warn("icons: Graven's own icon file: {s}", .{@errorName(err)});
    const dir_path = std.fs.path.join(a, &.{ platform.appDir(a, .data) catch return, "icons" }) catch return;
    addDir(a, dir_path);
}

fn addDir(a: std.mem.Allocator, path: []const u8) void {
    const io = dvui.io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".json")) continue;
        names.append(a, a.dupe(u8, entry.name) catch continue) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (names.items) |name| {
        const stem = name[0 .. name.len - 5];
        const png_name = std.fmt.allocPrint(a, "{s}.png", .{stem}) catch continue;
        const json = dir.readFileAlloc(io, name, a, .limited(16 << 20)) catch continue;
        const png = dir.readFileAlloc(io, png_name, a, .limited(64 << 20)) catch {
            std.log.warn("icons: {s} has no {s} beside it", .{ name, png_name });
            continue;
        };
        add(a, json, png, name) catch |err| std.log.warn("icons: {s}: {s}", .{ name, @errorName(err) });
    }
}

const Json = struct {
    atlas: struct {
        type: []const u8,
        distanceRange: f32,
        size: f32,
        yOrigin: []const u8 = "top",
    },
    graven: struct {
        ink: []const u8 = "#2a2530",
        transparent: []const u8 = "#ff00ff",
        overrides: []const struct { key: []const u8, name: []const u8 } = &.{},
        schemes: struct {
            dark: ?struct { ink: []const u8, slots: std.json.ArrayHashMap([]const u8) = .{} } = null,
        } = .{},
    } = .{},
    glyphs: []const struct {
        icon: ?[]const u8 = null,
        px: ?u32 = null,
        atlasBounds: ?struct { left: f32, top: f32, right: f32, bottom: f32 } = null,
    },
};

/// Adds file `json` + `png`; its icons replace any of the same name.
fn add(a: std.mem.Allocator, json: []const u8, png: []const u8, what: []const u8) !void {
    const j = try std.json.parseFromSliceLeaky(Json, a, json, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, j.atlas.type, "graven-ink")) return error.NotAGravenInkFile;
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const data = dvui.c.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &ch, 4) orelse return error.BadPng;
    defer dvui.c.stbi_image_free(data);
    const n: usize = @intCast(w * h * 4);
    const sheet = try a.create(Sheet);
    var ov: std.ArrayList(Override) = .empty;
    for (j.graven.overrides) |o| try ov.append(a, .{ .key = try hex(o.key), .name = o.name });
    var dark_slots: std.ArrayList(Override) = .empty;
    var dark_ink: ?Rgb = null;
    if (j.graven.schemes.dark) |d| {
        dark_ink = try hex(d.ink);
        var it = d.slots.map.iterator();
        while (it.next()) |e| try dark_slots.append(a, .{ .key = try hex(e.value_ptr.*), .name = e.key_ptr.* });
    }
    sheet.* = .{
        .width = @intCast(w),
        .height = @intCast(h),
        .rgba = try a.dupe(u8, data[0..n]),
        .size = j.atlas.size,
        .range = j.atlas.distanceRange,
        .ink = try hex(j.graven.ink),
        .transparent = try hex(j.graven.transparent),
        .overrides = ov.items,
        .dark_ink = dark_ink,
        .dark_slots = dark_slots.items,
    };
    const bottom = std.mem.eql(u8, j.atlas.yOrigin, "bottom");
    for (j.glyphs) |g| {
        const name = g.icon orelse continue;
        const b = g.atlasBounds orelse continue;
        const side = if (g.px != null) @abs(b.right - b.left) else j.atlas.size;
        const top = if (bottom) @as(f32, @floatFromInt(h)) - b.top else b.top;
        if (side < 1 or b.left < 0 or top < 0 or b.left + side > @as(f32, @floatFromInt(w)) or top + side > @as(f32, @floatFromInt(h))) {
            std.log.warn("icons: {s}: {s} lies outside its image", .{ what, name });
            continue;
        }
        const key = if (g.px) |px| try std.fmt.allocPrint(a, "{s}@{d}", .{ name, px }) else try a.dupe(u8, name);
        try cells.put(a, key, .{ .sheet = sheet, .x = @intFromFloat(b.left), .y = @intFromFloat(top), .size = @intFromFloat(side) });
    }
}

fn hex(s: []const u8) !Rgb {
    const t = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (t.len != 6) return error.BadColour;
    return .{
        try std.fmt.parseInt(u8, t[0..2], 16),
        try std.fmt.parseInt(u8, t[2..4], 16),
        try std.fmt.parseInt(u8, t[4..6], 16),
    };
}

/// Icon `name`, if a file has it.
pub fn get(name: []const u8) ?Cell {
    load();
    return cells.get(name);
}

/// Icon `name`'s cell hinted for `px` device pixels, if `free`'s file has
/// one.
fn hinted(free: Cell, name: []const u8, px: u32) ?Cell {
    if (platform.env("GRAVEN_ICON_HINTS")) |v| if (std.mem.eql(u8, v, "0")) return null;
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}@{d}", .{ name, px }) catch return null;
    const h = cells.get(key) orelse return null;
    return if (h.sheet == free.sheet) h else null;
}

/// The ink colour icon `name`'s file asks for.
pub fn inkOf(c: Cell) dvui.Color {
    return .{ .r = c.sheet.ink[0], .g = c.sheet.ink[1], .b = c.sheet.ink[2] };
}

/// Draws icon `name` filling `r` (it is the whole button), its ink `ink`.
/// False when no file has the icon (the caller draws something else).
pub fn draw(name: []const u8, r: dvui.Rect.Physical, ink: dvui.Color, colormod: dvui.Color) bool {
    return drawIn(name, r, ink, colormod, .own);
}

/// `draw`, its override slots coloured by `scheme`.
pub fn drawIn(name: []const u8, r: dvui.Rect.Physical, ink: dvui.Color, colormod: dvui.Color, scheme: Scheme) bool {
    const free = get(name) orelse return false;
    const px: u32 = @intFromFloat(@max(1, @round(@min(r.w, r.h))));
    const c = hinted(free, name, px) orelse free;
    const ink_key: u32 = @bitCast([4]u8{ ink.r, ink.g, ink.b, ink.a });
    const tex = for (cached.items) |e| {
        if (e.px == px and e.ink == ink_key and e.scheme == scheme and std.mem.eql(u8, e.name, name)) break e.tex;
    } else blk: {
        const gpa = dvui.currentWindow().gpa;
        const pma = gpa.alloc(dvui.Color.PMA, px * px) catch return false;
        defer gpa.free(pma);
        raster(c, px, .{ ink.r, ink.g, ink.b }, scheme, pma);
        const t = dvui.textureCreate(pma, .{ .width = px, .height = px, .interpolation = .nearest }) catch return false;
        cached.append(gpa, .{ .name = name, .px = px, .ink = ink_key, .scheme = scheme, .tex = t }) catch {};
        break :blk t;
    };
    const fp: f32 = @floatFromInt(px);
    const at: dvui.Rect.Physical = .{ .x = @round(r.x + (r.w - fp) / 2), .y = @round(r.y + (r.h - fp) / 2), .w = fp, .h = fp };
    dvui.renderTexture(tex, .{ .r = at, .s = 1 }, .{ .colormod = colormod }) catch {};
    return true;
}

/// Icon `c` as `px` x `px` premultiplied pixels, its ink `ink`.
pub fn raster(c: Cell, px: u32, ink: Rgb, scheme: Scheme, out: []dvui.Color.PMA) void {
    const s = c.sheet;
    const k = @as(f32, @floatFromInt(c.size)) / @as(f32, @floatFromInt(px)); // texels a pixel
    const inkf: [3]f32 = .{ @as(f32, @floatFromInt(ink[0])) / 255, @as(f32, @floatFromInt(ink[1])) / 255, @as(f32, @floatFromInt(ink[2])) / 255 };
    const cell_n: i64 = c.size;
    for (0..px) |oy| for (0..px) |ox| {
        var acc: [4]f32 = .{ 0, 0, 0, 0 };
        if (k >= 2) {
            // Shrinking: each texel drawn sharply, then averaged by area.
            const x0 = @as(f32, @floatFromInt(ox)) * k;
            const y0 = @as(f32, @floatFromInt(oy)) * k;
            const x1 = x0 + k;
            const y1 = y0 + k;
            var ty: i64 = @intFromFloat(@floor(y0));
            while (@as(f32, @floatFromInt(ty)) < y1 and ty < cell_n) : (ty += 1) {
                const fy0: f32 = @floatFromInt(ty);
                const wy = @min(y1, fy0 + 1) - @max(y0, fy0);
                var tx: i64 = @intFromFloat(@floor(x0));
                while (@as(f32, @floatFromInt(tx)) < x1 and tx < cell_n) : (tx += 1) {
                    const fx0: f32 = @floatFromInt(tx);
                    const wx = @min(x1, fx0 + 1) - @max(x0, fx0);
                    const col = resolve(c, tx, ty, scheme);
                    const cov = std.math.clamp((0.5 - field(c, tx, ty)) * s.range + 0.5, 0, 1);
                    const p = over(col, inkf, cov);
                    for (0..4) |i| acc[i] += p[i] * wx * wy;
                }
            }
            for (&acc) |*v| v.* /= k * k;
        } else {
            // Enlarging, or shrinking a little: bilinear, the ink's edge one
            // pixel wide.
            const u = (@as(f32, @floatFromInt(ox)) + 0.5) * k - 0.5;
            const v = (@as(f32, @floatFromInt(oy)) + 0.5) * k - 0.5;
            const iu: i64 = @intFromFloat(@floor(u));
            const iv: i64 = @intFromFloat(@floor(v));
            const fu = u - @floor(u);
            const fv = v - @floor(v);
            var col: [4]f32 = .{ 0, 0, 0, 0 };
            var a: f32 = 0;
            const taps = [4]struct { dx: i64, dy: i64, w: f32 }{
                .{ .dx = 0, .dy = 0, .w = (1 - fu) * (1 - fv) },
                .{ .dx = 1, .dy = 0, .w = fu * (1 - fv) },
                .{ .dx = 0, .dy = 1, .w = (1 - fu) * fv },
                .{ .dx = 1, .dy = 1, .w = fu * fv },
            };
            for (taps) |t| {
                const r = resolve(c, iu + t.dx, iv + t.dy, scheme);
                for (0..4) |i| col[i] += r[i] * t.w;
                a += field(c, iu + t.dx, iv + t.dy) * t.w;
            }
            const cov = std.math.clamp((0.5 - a) * s.range / k + 0.5, 0, 1);
            acc = over(col, inkf, cov);
        }
        out[oy * px + ox] = .{
            .r = @intFromFloat(@round(std.math.clamp(acc[0], 0, 1) * 255)),
            .g = @intFromFloat(@round(std.math.clamp(acc[1], 0, 1) * 255)),
            .b = @intFromFloat(@round(std.math.clamp(acc[2], 0, 1) * 255)),
            .a = @intFromFloat(@round(std.math.clamp(acc[3], 0, 1) * 255)),
        };
    };
}

/// Ink at coverage `cov` over premultiplied `col`.
fn over(col: [4]f32, ink: [3]f32, cov: f32) [4]f32 {
    return .{ col[0] * (1 - cov) + ink[0] * cov, col[1] * (1 - cov) + ink[1] * cov, col[2] * (1 - cov) + ink[2] * cov, col[3] * (1 - cov) + cov };
}

/// Texel (x, y) of cell `c` (clamped to the cell), straight RGBA bytes.
fn texel(c: Cell, x: i64, y: i64) [4]u8 {
    const n: i64 = c.size;
    const tx: usize = @intCast(@as(i64, c.x) + std.math.clamp(x, 0, n - 1));
    const ty: usize = @intCast(@as(i64, c.y) + std.math.clamp(y, 0, n - 1));
    const i = (ty * c.sheet.width + tx) * 4;
    return c.sheet.rgba[i..][0..4].*;
}

/// The ink's field at a texel, 0..1.
fn field(c: Cell, x: i64, y: i64) f32 {
    return @as(f32, @floatFromInt(texel(c, x, y)[3])) / 255;
}

/// A texel's ground, resolved and premultiplied: the key transparent, an
/// override key the colour `scheme` gives its slot.
fn resolve(c: Cell, x: i64, y: i64, scheme: Scheme) [4]f32 {
    var t = texel(c, x, y);
    const k = c.sheet.transparent;
    if (t[0] == k[0] and t[1] == k[1] and t[2] == k[2]) return .{ 0, 0, 0, 0 };
    if (scheme != .own) for (c.sheet.overrides) |o| {
        if (t[0] == o.key[0] and t[1] == o.key[1] and t[2] == o.key[2]) {
            if (scheme.colour(c.sheet, o.name)) |rgb| t = .{ rgb[0], rgb[1], rgb[2], t[3] };
            break;
        }
    };
    return .{ @as(f32, @floatFromInt(t[0])) / 255, @as(f32, @floatFromInt(t[1])) / 255, @as(f32, @floatFromInt(t[2])) / 255, 1 };
}
