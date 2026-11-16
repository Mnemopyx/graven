//! Font containers: the sfnt a font is (TrueType or CFF outlines, or a
//! collection of faces) and the web wrappers around it, WOFF and WOFF2,
//! unwrapped back to sfnt.
//!
//! WOFF compresses each table with zlib: unwrapped, every table comes back
//! byte for byte. WOFF2 compresses the tables as one Brotli stream and may
//! transform `glyf`/`loca` (its own glyph encoding) and `hmtx` (side
//! bearings left out where the glyphs' boxes give them): decoded, the
//! outlines, points, flags and metrics are the same, the bytes need not be.
//! Outline flavour is never converted; `extension` names what a decoded
//! font is (.ttf, .otf, .ttc, .otc).
//!
//! Bytes in, bytes out: no file access.

const std = @import("std");
const brotli = @import("brotli");

const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidFont, OutOfMemory };

/// What a file's bytes hold.
pub const Kind = enum {
    /// sfnt with TrueType outlines, or none (header 0x00010000 or 'true').
    truetype,
    /// sfnt with CFF or CFF2 outlines ('OTTO').
    cff,
    /// An sfnt collection ('ttcf').
    collection,
    woff,
    woff2,
    unknown,

    /// Whether this is a web wrapper around an sfnt.
    pub fn isWeb(k: Kind) bool {
        return k == .woff or k == .woff2;
    }
};

pub fn kindOf(bytes: []const u8) Kind {
    if (bytes.len < 4) return .unknown;
    return switch (std.mem.readInt(u32, bytes[0..4], .big)) {
        0x00010000, tagInt("true") => .truetype,
        tagInt("OTTO") => .cff,
        tagInt("ttcf") => .collection,
        tagInt("wOFF") => .woff,
        tagInt("wOF2") => .woff2,
        else => .unknown,
    };
}

/// How a face's glyphs are drawn.
pub const Outlines = enum {
    /// Quadratic, in `glyf`.
    truetype,
    /// Cubic, in `CFF `.
    cff,
    /// Cubic, in `CFF2` (variable fonts).
    cff2,
    /// None: a bitmap or colour-only font.
    none,
};

/// The outlines of face `index` of an sfnt (single or collection).
pub fn outlinesOf(sfnt: []const u8, index: u32) Outlines {
    const dir = fontDirectory(sfnt, index) orelse return .none;
    var r: Reader = .{ .b = sfnt, .i = dir + 4 };
    const n = r.int(u16) catch return .none;
    r.i = dir + 12;
    var found: Outlines = .none;
    for (0..n) |_| {
        const t = r.int(u32) catch return .none;
        r.i += 12;
        if (t == tagInt("glyf")) return .truetype;
        if (t == tagInt("CFF2")) found = .cff2;
        if (t == tagInt("CFF ") and found == .none) found = .cff;
    }
    return found;
}

/// The extension an sfnt is stored under: .ttf for TrueType outlines (and
/// for bitmap-only fonts, by convention), .otf for CFF and CFF2, .ttc and
/// .otc for collections by their first face's outlines. Null when the bytes
/// are not an sfnt.
pub fn extension(sfnt: []const u8) ?[]const u8 {
    const k = kindOf(sfnt);
    if (k != .truetype and k != .cff and k != .collection) return null;
    const cubic = switch (outlinesOf(sfnt, 0)) {
        .cff, .cff2 => true,
        .truetype, .none => false,
    };
    if (k == .collection) return if (cubic) ".otc" else ".ttc";
    return if (cubic) ".otf" else ".ttf";
}

/// How many faces the bytes hold, whatever the container; 0 when they are
/// not a font this module knows.
pub fn faceCount(bytes: []const u8) u32 {
    return switch (kindOf(bytes)) {
        .truetype, .cff, .woff => 1,
        .collection => if (bytes.len >= 12) std.mem.readInt(u32, bytes[8..12], .big) else 0,
        .woff2 => woff2FaceCount(bytes) catch 0,
        .unknown => 0,
    };
}

/// The font as an sfnt, from `gpa`: a copy when it is one already, and
/// WOFF and WOFF2 unwrapped.
pub fn toSfnt(gpa: Allocator, bytes: []const u8) Error![]u8 {
    return switch (kindOf(bytes)) {
        .truetype, .cff, .collection => gpa.dupe(u8, bytes),
        .woff => decodeWoff(gpa, bytes),
        .woff2 => decodeWoff2(gpa, bytes),
        .unknown => error.InvalidFont,
    };
}

// Reading ------------------------------------------------------------------------

fn tagInt(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// A bounded big-endian reader; running off the end is an invalid font.
const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.b.len - r.i) return error.InvalidFont;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const s = try r.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .big);
    }

    /// WOFF2's UIntBase128: up to five bytes of seven bits, high first.
    fn base128(r: *Reader) Error!u32 {
        var v: u32 = 0;
        for (0..5) |k| {
            const c = try r.int(u8);
            if (k == 0 and c == 0x80) return error.InvalidFont; // a leading zero
            if (v & 0xFE00_0000 != 0) return error.InvalidFont; // would overflow
            v = (v << 7) | (c & 0x7F);
            if (c & 0x80 == 0) return v;
        }
        return error.InvalidFont;
    }

    /// WOFF2's 255UInt16.
    fn uint255(r: *Reader) Error!u16 {
        const c = try r.int(u8);
        return switch (c) {
            253 => r.int(u16),
            254 => @as(u16, try r.int(u8)) + 506,
            255 => @as(u16, try r.int(u8)) + 253,
            else => c,
        };
    }
};

/// Where face `index`'s table directory starts in an sfnt.
fn fontDirectory(sfnt: []const u8, index: u32) ?usize {
    switch (kindOf(sfnt)) {
        .truetype, .cff => return if (index == 0) 0 else null,
        .collection => {
            var r: Reader = .{ .b = sfnt, .i = 8 };
            const n = r.int(u32) catch return null;
            if (index >= n) return null;
            r.i = 12 + 4 * @as(usize, index);
            const off = r.int(u32) catch return null;
            return if (off + 12 <= sfnt.len) off else null;
        },
        else => return null,
    }
}

// Writing sfnt -------------------------------------------------------------------

const Table = struct {
    tag: u32,
    data: []const u8,
    /// Tables with the same id are one table, written once (collections).
    id: usize,
};

fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) sum +%= std.mem.readInt(u32, data[i..][0..4], .big);
    if (i < data.len) {
        var last: [4]u8 = @splat(0);
        @memcpy(last[0 .. data.len - i], data[i..]);
        sum +%= std.mem.readInt(u32, &last, .big);
    }
    return sum;
}

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn lessByTag(_: void, a: Table, b: Table) bool {
    return a.tag < b.tag;
}

/// Writes an sfnt (one face) or a collection (several), from `gpa`. Each
/// face's directory is sorted by tag; table data is laid out in the order
/// given (the first face's tables, then each later face's new ones). With
/// `fix_head`, a single face's head.checkSumAdjustment is computed afresh.
fn writeSfnt(gpa: Allocator, flavors: []const u32, faces: []const []Table, fix_head: bool) Error![]u8 {
    std.debug.assert(faces.len == flavors.len and faces.len > 0);
    const collection = faces.len > 1 or flavors[0] == tagInt("ttcf");
    var size: usize = if (collection) 12 + 4 * faces.len else 0;
    for (faces) |f| size += 12 + 16 * f.len;
    const dirs_end = size;
    // Data order, and each table's offset by id.
    var offsets: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    defer offsets.deinit(gpa);
    for (faces) |f| for (f) |t| {
        const e = try offsets.getOrPut(gpa, t.id);
        if (e.found_existing) continue;
        e.value_ptr.* = @intCast(size);
        size += pad4(t.data.len);
    };
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    @memset(out, 0);
    // Table data.
    var written: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer written.deinit(gpa);
    for (faces) |f| for (f) |t| {
        if ((try written.getOrPut(gpa, t.id)).found_existing) continue;
        const off = offsets.get(t.id).?;
        @memcpy(out[off..][0..t.data.len], t.data);
    };
    // Directories.
    var at: usize = 0;
    if (collection) {
        std.mem.writeInt(u32, out[0..4], tagInt("ttcf"), .big);
        std.mem.writeInt(u32, out[4..8], 0x00010000, .big);
        std.mem.writeInt(u32, out[8..12], @intCast(faces.len), .big);
        at = 12 + 4 * faces.len;
    }
    var head_off: ?usize = null;
    for (faces, flavors, 0..) |f, flavor, k| {
        if (collection) std.mem.writeInt(u32, out[12 + 4 * k ..][0..4], @intCast(at), .big);
        const sorted = try gpa.dupe(Table, f);
        defer gpa.free(sorted);
        std.mem.sort(Table, sorted, {}, lessByTag);
        const n: u16 = @intCast(f.len);
        var entry_selector: u16 = 0;
        while ((@as(u32, 2) << @intCast(entry_selector)) <= n) entry_selector += 1;
        const search_range: u16 = @intCast((@as(u32, 1) << @intCast(entry_selector)) * 16);
        std.mem.writeInt(u32, out[at..][0..4], flavor, .big);
        std.mem.writeInt(u16, out[at + 4 ..][0..2], n, .big);
        std.mem.writeInt(u16, out[at + 6 ..][0..2], search_range, .big);
        std.mem.writeInt(u16, out[at + 8 ..][0..2], entry_selector, .big);
        std.mem.writeInt(u16, out[at + 10 ..][0..2], n * 16 - search_range, .big);
        at += 12;
        for (sorted) |t| {
            const off = offsets.get(t.id).?;
            if (t.tag == tagInt("head") and !collection and fix_head and t.data.len >= 12) {
                head_off = off;
                @memset(out[off + 8 ..][0..4], 0);
            }
            std.mem.writeInt(u32, out[at..][0..4], t.tag, .big);
            // head's checksum is taken with its adjustment as zero.
            const table = out[off..][0..t.data.len];
            const adjust = if (t.tag == tagInt("head") and table.len >= 12) std.mem.readInt(u32, table[8..12], .big) else 0;
            std.mem.writeInt(u32, out[at + 4 ..][0..4], checksum(table) -% adjust, .big);
            std.mem.writeInt(u32, out[at + 8 ..][0..4], off, .big);
            std.mem.writeInt(u32, out[at + 12 ..][0..4], @intCast(t.data.len), .big);
            at += 16;
        }
    }
    std.debug.assert(at == dirs_end);
    if (head_off) |off| std.mem.writeInt(u32, out[off + 8 ..][0..4], 0xB1B0AFBA -% checksum(out), .big);
    return out;
}

// WOFF ---------------------------------------------------------------------------

fn decodeWoff(gpa: Allocator, bytes: []const u8) Error![]u8 {
    var r: Reader = .{ .b = bytes, .i = 4 };
    const flavor = try r.int(u32);
    if (flavor == tagInt("ttcf")) return error.InvalidFont; // WOFF 1 holds one face
    if (try r.int(u32) != bytes.len) return error.InvalidFont;
    const n = try r.int(u16);
    r.i = 44;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tables = try a.alloc(Table, n);
    const order = try a.alloc(struct { off: u32, k: usize }, n);
    for (tables, order, 0..) |*t, *o, k| {
        const tag = try r.int(u32);
        const off = try r.int(u32);
        const comp_len = try r.int(u32);
        const orig_len = try r.int(u32);
        _ = try r.int(u32); // the original checksum: recomputed when written
        if (off > bytes.len or comp_len > bytes.len - off or comp_len > orig_len) return error.InvalidFont;
        const src = bytes[off..][0..comp_len];
        const data = if (comp_len == orig_len) src else try inflate(a, src, orig_len);
        t.* = .{ .tag = tag, .data = data, .id = k };
        o.* = .{ .off = off, .k = k };
    }
    // Table data in the order the WOFF holds it, which is the order the
    // original font held it: the sfnt usually comes back byte for byte.
    std.mem.sort(@TypeOf(order[0]), order, {}, struct {
        fn f(_: void, x: @TypeOf(order[0]), y: @TypeOf(order[0])) bool {
            return x.off < y.off;
        }
    }.f);
    const laid = try a.alloc(Table, n);
    for (order, laid) |o, *t| t.* = tables[o.k];
    return writeSfnt(gpa, &.{flavor}, &.{laid}, false);
}

fn inflate(a: Allocator, src: []const u8, len: usize) Error![]u8 {
    const flate = std.compress.flate;
    var in: std.Io.Reader = .fixed(src);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &window);
    const out = try a.alloc(u8, len);
    d.reader.readSliceAll(out) catch return error.InvalidFont;
    return out;
}

// WOFF2 --------------------------------------------------------------------------

/// The tags WOFF2's table directory names by index.
const known_tags = [63]*const [4]u8{
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
};

const Entry = struct {
    tag: u32,
    transformed: bool,
    orig_len: u32,
    /// Its length in the decompressed stream.
    len: u32,
    /// Its offset in the decompressed stream.
    off: usize = 0,
};

const Woff2 = struct {
    flavor: u32,
    entries: []Entry,
    /// Per face: its flavor and its tables, as entry numbers.
    faces: []const Woff2.FaceEntry,
    /// The Brotli stream.
    stream: []const u8,
    /// The decompressed stream's length.
    total: usize,

    const FaceEntry = struct { flavor: u32, tables: []const u16 };
};

fn parseWoff2(a: Allocator, bytes: []const u8) Error!Woff2 {
    var r: Reader = .{ .b = bytes, .i = 4 };
    const flavor = try r.int(u32);
    if (try r.int(u32) != bytes.len) return error.InvalidFont;
    const n = try r.int(u16);
    if (n == 0) return error.InvalidFont;
    _ = try r.int(u16); // reserved
    _ = try r.int(u32); // totalSfntSize
    const comp_len = try r.int(u32);
    r.i = 48;
    const entries = try a.alloc(Entry, n);
    var total: usize = 0;
    for (entries) |*e| {
        const flags = try r.int(u8);
        const tag = if (flags & 63 == 63) try r.int(u32) else tagInt(known_tags[flags & 63]);
        const version = flags >> 6;
        const glyf_loca = tag == tagInt("glyf") or tag == tagInt("loca");
        // glyf and loca are transformed at version 0 (3 is none); any other
        // table at a version other than 0.
        const transformed = if (glyf_loca) version == 0 else version != 0;
        if (transformed and !glyf_loca and tag != tagInt("hmtx")) return error.InvalidFont;
        const orig_len = try r.base128();
        const len = if (transformed) try r.base128() else orig_len;
        if (tag == tagInt("loca") and transformed and len != 0) return error.InvalidFont;
        e.* = .{ .tag = tag, .transformed = transformed, .orig_len = orig_len, .len = len, .off = total };
        total += len;
    }
    var faces: []Woff2.FaceEntry = undefined;
    if (flavor == tagInt("ttcf")) {
        _ = try r.int(u32); // the collection's version
        const nf = try r.uint255();
        if (nf == 0) return error.InvalidFont;
        faces = try a.alloc(Woff2.FaceEntry, nf);
        for (faces) |*f| {
            const nt = try r.uint255();
            const fl = try r.int(u32);
            const ids = try a.alloc(u16, nt);
            for (ids) |*id| {
                id.* = try r.uint255();
                if (id.* >= n) return error.InvalidFont;
            }
            f.* = .{ .flavor = fl, .tables = ids };
        }
    } else {
        const ids = try a.alloc(u16, n);
        for (ids, 0..) |*id, k| id.* = @intCast(k);
        faces = try a.alloc(Woff2.FaceEntry, 1);
        faces[0] = .{ .flavor = flavor, .tables = ids };
    }
    const stream = try r.take(comp_len);
    return .{ .flavor = flavor, .entries = entries, .faces = faces, .stream = stream, .total = total };
}

fn woff2FaceCount(bytes: []const u8) Error!u32 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const w = try parseWoff2(arena.allocator(), bytes);
    return @intCast(w.faces.len);
}

fn decodeWoff2(gpa: Allocator, bytes: []const u8) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parseWoff2(a, bytes);

    const data = try a.alloc(u8, w.total);
    var out_len: usize = w.total;
    if (brotli.BrotliDecoderDecompress(w.stream.len, w.stream.ptr, &out_len, data.ptr) != brotli.BROTLI_DECODER_RESULT_SUCCESS or out_len != w.total)
        return error.InvalidFont;

    // Each face's tables, transforms reversed. A transformed glyf makes its
    // loca too; faces sharing a glyf share what it makes.
    var glyfs: std.AutoHashMapUnmanaged(u16, Glyf) = .empty;
    var hmtxs: std.AutoHashMapUnmanaged(u16, []const u8) = .empty;
    const flavors = try a.alloc(u32, w.faces.len);
    const faces = try a.alloc([]Table, w.faces.len);
    // Ids for made tables, past the entries'.
    const loca_id_base = w.entries.len;
    for (w.faces, flavors, faces) |f, *fl, *tables| {
        fl.* = f.flavor;
        tables.* = try a.alloc(Table, f.tables.len);
        var glyf_id: ?u16 = null;
        var loca_id: ?u16 = null;
        var hhea: ?[]const u8 = null;
        var maxp: ?[]const u8 = null;
        for (f.tables) |id| {
            const e = w.entries[id];
            if (e.tag == tagInt("glyf")) glyf_id = id;
            if (e.tag == tagInt("loca")) loca_id = id;
            if (e.tag == tagInt("hhea")) hhea = data[e.off..][0..e.len];
            if (e.tag == tagInt("maxp")) maxp = data[e.off..][0..e.len];
        }
        for (f.tables, tables.*) |id, *t| {
            const e = w.entries[id];
            const raw = data[e.off..][0..e.len];
            t.* = .{ .tag = e.tag, .data = raw, .id = id };
            if (!e.transformed) continue;
            if (e.tag == tagInt("glyf") or e.tag == tagInt("loca")) {
                const gid = glyf_id orelse return error.InvalidFont;
                const lid = loca_id orelse return error.InvalidFont;
                if (!w.entries[gid].transformed or !w.entries[lid].transformed) return error.InvalidFont;
                const g = try glyfFor(a, &glyfs, gid, data[w.entries[gid].off..][0..w.entries[gid].len]);
                if (e.tag == tagInt("glyf")) {
                    t.data = g.glyf;
                } else {
                    if (g.loca.len != e.orig_len) return error.InvalidFont;
                    t.data = g.loca;
                    t.id = loca_id_base + gid; // made from the glyf, so shared with it
                }
            } else if (e.tag == tagInt("hmtx")) {
                const gid = glyf_id orelse return error.InvalidFont;
                if (!w.entries[gid].transformed) return error.InvalidFont;
                const g = try glyfFor(a, &glyfs, gid, data[w.entries[gid].off..][0..w.entries[gid].len]);
                const e2 = try hmtxs.getOrPut(a, id);
                if (!e2.found_existing) e2.value_ptr.* = try reconstructHmtx(a, raw, g.x_mins, hhea orelse return error.InvalidFont, maxp orelse return error.InvalidFont);
                t.data = e2.value_ptr.*;
                if (t.data.len != e.orig_len) return error.InvalidFont;
            }
        }
    }
    return writeSfnt(gpa, flavors, faces, true);
}

fn glyfFor(a: Allocator, cache: *std.AutoHashMapUnmanaged(u16, Glyf), id: u16, data: []const u8) Error!Glyf {
    const e = try cache.getOrPut(a, id);
    if (!e.found_existing) e.value_ptr.* = try reconstructGlyf(a, data);
    return e.value_ptr.*;
}

const Glyf = struct {
    glyf: []const u8,
    loca: []const u8,
    /// Each glyph's xMin (0 for an empty glyph), for hmtx's side bearings.
    x_mins: []const i16,
};

/// Rebuilds glyf and loca from WOFF2's transformed glyf.
fn reconstructGlyf(a: Allocator, data: []const u8) Error!Glyf {
    var h: Reader = .{ .b = data };
    _ = try h.int(u16); // reserved
    const options = try h.int(u16);
    const num_glyphs = try h.int(u16);
    const index_format = try h.int(u16);
    if (index_format > 1) return error.InvalidFont;
    var sizes: [7]u32 = undefined;
    for (&sizes) |*s| s.* = try h.int(u32);
    var streams: [7]Reader = undefined;
    for (&streams, sizes) |*s, n| s.* = .{ .b = try h.take(n) };
    var n_contours = streams[0];
    var n_points = streams[1];
    var flag_s = streams[2];
    var glyph_s = streams[3];
    var composite_s = streams[4];
    var bbox_s = streams[5];
    var instr_s = streams[6];
    const bbox_bitmap = try bbox_s.take(4 * ((@as(usize, num_glyphs) + 31) / 32));
    const overlap_bitmap: ?[]const u8 = if (options & 1 != 0) try h.take((@as(usize, num_glyphs) + 7) / 8) else null;

    var glyf: std.ArrayList(u8) = .empty;
    const offsets = try a.alloc(u32, @as(usize, num_glyphs) + 1);
    const x_mins = try a.alloc(i16, num_glyphs);
    var points: std.ArrayList(Point) = .empty;
    for (0..num_glyphs) |g| {
        offsets[g] = @intCast(glyf.items.len);
        const has_bbox = bbox_bitmap[g >> 3] & (@as(u8, 0x80) >> @intCast(g & 7)) != 0;
        const nc = try n_contours.int(i16);
        x_mins[g] = 0;
        if (nc == 0) {
            if (has_bbox) return error.InvalidFont;
            continue;
        }
        if (nc == -1) {
            // Composite: its components as they are, its box given.
            if (!has_bbox) return error.InvalidFont;
            const start = composite_s.i;
            var have_instructions = false;
            while (true) {
                const flags = try composite_s.int(u16);
                _ = try composite_s.int(u16); // the component's glyph
                var skip: usize = if (flags & 0x0001 != 0) 4 else 2; // its arguments
                if (flags & 0x0008 != 0) skip += 2 else if (flags & 0x0040 != 0) skip += 4 else if (flags & 0x0080 != 0) skip += 8;
                _ = try composite_s.take(skip);
                if (flags & 0x0100 != 0) have_instructions = true;
                if (flags & 0x0020 == 0) break;
            }
            const components = composite_s.b[start..composite_s.i];
            var box: [4]i16 = undefined;
            for (&box) |*v| v.* = try bbox_s.int(i16);
            x_mins[g] = box[0];
            try putInt(a, &glyf, i16, -1);
            for (box) |v| try putInt(a, &glyf, i16, v);
            try glyf.appendSlice(a, components);
            if (have_instructions) {
                const n = try glyph_s.uint255();
                try putInt(a, &glyf, u16, n);
                try glyf.appendSlice(a, try instr_s.take(n));
            }
        } else if (nc > 0) {
            const ends = try a.alloc(u16, @intCast(nc));
            var total: u32 = 0;
            for (ends) |*end| {
                total += try n_points.uint255();
                if (total == 0 or total > 0xFFFF) return error.InvalidFont;
                end.* = @intCast(total - 1);
            }
            const flags = try flag_s.take(total);
            points.clearRetainingCapacity();
            try decodeTriplets(a, flags, &glyph_s, &points);
            const n_instr = try glyph_s.uint255();
            const instructions = try instr_s.take(n_instr);
            var box: [4]i16 = undefined;
            if (has_bbox) {
                for (&box) |*v| v.* = try bbox_s.int(i16);
            } else {
                box = .{ std.math.maxInt(i16), std.math.maxInt(i16), std.math.minInt(i16), std.math.minInt(i16) };
                for (points.items) |p| {
                    box[0] = @min(box[0], p.x);
                    box[1] = @min(box[1], p.y);
                    box[2] = @max(box[2], p.x);
                    box[3] = @max(box[3], p.y);
                }
            }
            x_mins[g] = box[0];
            try putInt(a, &glyf, i16, nc);
            for (box) |v| try putInt(a, &glyf, i16, v);
            for (ends) |end| try putInt(a, &glyf, u16, end);
            try putInt(a, &glyf, u16, n_instr);
            try glyf.appendSlice(a, instructions);
            const overlap = if (overlap_bitmap) |bm| bm[g >> 3] & (@as(u8, 0x80) >> @intCast(g & 7)) != 0 else false;
            try encodePoints(a, &glyf, points.items, overlap);
        } else return error.InvalidFont;
        while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
    }
    offsets[num_glyphs] = @intCast(glyf.items.len);

    var loca: std.ArrayList(u8) = .empty;
    for (offsets) |off| {
        if (index_format == 0) {
            if (off / 2 > 0xFFFF) return error.InvalidFont;
            try putInt(a, &loca, u16, @intCast(off / 2));
        } else try putInt(a, &loca, u32, off);
    }
    return .{ .glyf = glyf.items, .loca = loca.items, .x_mins = x_mins };
}

const Point = struct { x: i16, y: i16, on: bool };

fn withSign(flag: u8, base: i32) i32 {
    return if (flag & 1 != 0) base else -base;
}

/// WOFF2's point triplets: a flag per point (on or off the curve, and how
/// its delta is packed) and one to four bytes of delta.
fn decodeTriplets(a: Allocator, flags: []const u8, in: *Reader, out: *std.ArrayList(Point)) Error!void {
    var x: i32 = 0;
    var y: i32 = 0;
    for (flags) |flag_byte| {
        const on = flag_byte >> 7 == 0;
        const flag = flag_byte & 0x7F;
        const n: usize = if (flag < 84) 1 else if (flag < 120) 2 else if (flag < 124) 3 else 4;
        const d = try in.take(n);
        var dx: i32 = 0;
        var dy: i32 = 0;
        if (flag < 10) {
            dy = withSign(flag, (@as(i32, flag & 14) << 7) + d[0]);
        } else if (flag < 20) {
            dx = withSign(flag, (@as(i32, (flag - 10) & 14) << 7) + d[0]);
        } else if (flag < 84) {
            const b0: i32 = flag - 20;
            const b1: i32 = d[0];
            dx = withSign(flag, 1 + (b0 & 0x30) + (b1 >> 4));
            dy = withSign(flag >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f));
        } else if (flag < 120) {
            const b0: i32 = flag - 84;
            dx = withSign(flag, 1 + (@divTrunc(b0, 12) << 8) + d[0]);
            dy = withSign(flag >> 1, 1 + ((@rem(b0, 12) >> 2) << 8) + d[1]);
        } else if (flag < 124) {
            const b2: i32 = d[1];
            dx = withSign(flag, (@as(i32, d[0]) << 4) + (b2 >> 4));
            dy = withSign(flag >> 1, ((b2 & 0x0f) << 8) + d[2]);
        } else {
            dx = withSign(flag, (@as(i32, d[0]) << 8) + d[1]);
            dy = withSign(flag >> 1, (@as(i32, d[2]) << 8) + d[3]);
        }
        x += dx;
        y += dy;
        if (x < std.math.minInt(i16) or x > std.math.maxInt(i16) or y < std.math.minInt(i16) or y > std.math.maxInt(i16)) return error.InvalidFont;
        try out.append(a, .{ .x = @intCast(x), .y = @intCast(y), .on = on });
    }
}

/// A simple glyph's flags and coordinates, in glyf's own packing (short
/// deltas where they fit, repeated flags run together).
fn encodePoints(a: Allocator, out: *std.ArrayList(u8), points: []const Point, overlap: bool) Error!void {
    var flags: std.ArrayList(u8) = .empty;
    var xs: std.ArrayList(u8) = .empty;
    var ys: std.ArrayList(u8) = .empty;
    var last_x: i32 = 0;
    var last_y: i32 = 0;
    for (points, 0..) |p, k| {
        var flag: u8 = if (p.on) 0x01 else 0;
        if (k == 0 and overlap) flag |= 0x40;
        const dx = @as(i32, p.x) - last_x;
        const dy = @as(i32, p.y) - last_y;
        last_x = p.x;
        last_y = p.y;
        if (dx == 0) {
            flag |= 0x10;
        } else if (@abs(dx) < 256) {
            flag |= 0x02 | @as(u8, if (dx > 0) 0x10 else 0);
            try xs.append(a, @intCast(@abs(dx)));
        } else try putInt(a, &xs, i16, @intCast(dx));
        if (dy == 0) {
            flag |= 0x20;
        } else if (@abs(dy) < 256) {
            flag |= 0x04 | @as(u8, if (dy > 0) 0x20 else 0);
            try ys.append(a, @intCast(@abs(dy)));
        } else try putInt(a, &ys, i16, @intCast(dy));
        try flags.append(a, flag);
    }
    var k: usize = 0;
    while (k < flags.items.len) {
        const f = flags.items[k];
        var run: usize = 1;
        while (k + run < flags.items.len and flags.items[k + run] == f and run < 256) run += 1;
        if (run > 1) {
            try out.append(a, f | 0x08);
            try out.append(a, @intCast(run - 1));
        } else try out.append(a, f);
        k += run;
    }
    try out.appendSlice(a, xs.items);
    try out.appendSlice(a, ys.items);
}

/// Rebuilds hmtx from WOFF2's transformed hmtx: advances, with left side
/// bearings that equal the glyphs' xMin left out.
fn reconstructHmtx(a: Allocator, data: []const u8, x_mins: []const i16, hhea: []const u8, maxp: []const u8) Error![]const u8 {
    if (hhea.len < 36 or maxp.len < 6) return error.InvalidFont;
    const num_hm = std.mem.readInt(u16, hhea[34..36], .big);
    const num_glyphs = std.mem.readInt(u16, maxp[4..6], .big);
    if (num_hm == 0 or num_hm > num_glyphs or x_mins.len != num_glyphs) return error.InvalidFont;
    var r: Reader = .{ .b = data };
    const flags = try r.int(u8);
    if (flags & 0xFC != 0 or flags & 3 == 0) return error.InvalidFont;
    var adv = try r.take(2 * @as(usize, num_hm));
    var out: std.ArrayList(u8) = .empty;
    for (0..num_glyphs) |g| {
        if (g < num_hm) {
            try out.appendSlice(a, adv[0..2]);
            adv = adv[2..];
            const lsb = if (flags & 1 != 0) x_mins[g] else try r.int(i16);
            try putInt(a, &out, i16, lsb);
        } else {
            const lsb = if (flags & 2 != 0) x_mins[g] else try r.int(i16);
            try putInt(a, &out, i16, lsb);
        }
    }
    return out.items;
}

fn putInt(a: Allocator, list: *std.ArrayList(u8), comptime T: type, v: T) Error!void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    try list.appendSlice(a, &b);
}

// Tests --------------------------------------------------------------------------

const testing = std.testing;
const testdata = @import("graven_testdata");
const FontFace = @import("face.zig").Face;

/// The tables of face `index` of an sfnt, by tag.
fn tablesOf(sfnt: []const u8, index: u32) !std.AutoArrayHashMapUnmanaged(u32, []const u8) {
    var map: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
    const dir = fontDirectory(sfnt, index) orelse return error.InvalidFont;
    var r: Reader = .{ .b = sfnt, .i = dir + 4 };
    const n = try r.int(u16);
    r.i = dir + 12;
    for (0..n) |_| {
        const t = try r.int(u32);
        const sum = try r.int(u32);
        const off = try r.int(u32);
        const len = try r.int(u32);
        const data = sfnt[off..][0..len];
        try testing.expectEqual(checksum(data) -% if (t == tagInt("head")) std.mem.readInt(u32, data[8..12], .big) else 0, sum);
        try map.put(testing.allocator, t, data);
    }
    return map;
}

/// Every glyph's outline and advance the same in both faces.
fn expectSameGlyphs(want: []const u8, got: []const u8, index: u32) !void {
    const a = try FontFace.init(testing.allocator, want, index);
    defer a.deinit();
    const b = try FontFace.init(testing.allocator, got, index);
    defer b.deinit();
    const n = @import("hb").hb_face_get_glyph_count(a.face);
    try testing.expectEqual(n, @import("hb").hb_face_get_glyph_count(b.face));
    for (0..n) |g| {
        const oa = try a.outline(@intCast(g));
        const ob = try b.outline(@intCast(g));
        try testing.expectEqual(oa.contours.len, ob.contours.len);
        for (oa.contours, ob.contours) |ca, cb| {
            try testing.expectEqual(ca.segments.len, cb.segments.len);
            for (ca.segments, cb.segments) |sa, sb| try testing.expectEqualDeep(sa, sb);
        }
        try testing.expectEqual(a.advance(@intCast(g)), b.advance(@intCast(g)));
    }
}

test "containers are told apart, and sfnt outlines named" {
    try testing.expectEqual(Kind.truetype, kindOf(testdata.truetype));
    try testing.expectEqual(Kind.cff, kindOf(testdata.cff));
    try testing.expectEqual(Kind.woff, kindOf(testdata.truetype_woff));
    try testing.expectEqual(Kind.woff2, kindOf(testdata.cff_woff2));
    try testing.expectEqual(Kind.unknown, kindOf("PK\x03\x04"));
    try testing.expectEqual(Outlines.truetype, outlinesOf(testdata.truetype, 0));
    try testing.expectEqual(Outlines.cff, outlinesOf(testdata.cff, 0));
    try testing.expectEqualStrings(".ttf", extension(testdata.truetype).?);
    try testing.expectEqualStrings(".otf", extension(testdata.cff).?);
    try testing.expectEqual(@as(?[]const u8, null), extension(testdata.truetype_woff));
    try testing.expectEqual(@as(u32, 1), faceCount(testdata.truetype_woff2));
    try testing.expectEqual(@as(u32, 2), faceCount(testdata.collection_woff2));
}

test "WOFF unwraps to the original font, byte for byte" {
    for ([_][2][]const u8{ .{ testdata.truetype, testdata.truetype_woff }, .{ testdata.cff, testdata.cff_woff } }) |pair| {
        const sfnt = try toSfnt(testing.allocator, pair[1]);
        defer testing.allocator.free(sfnt);
        try testing.expectEqualSlices(u8, pair[0], sfnt);
    }
}

test "WOFF2 decodes to the same tables, and the same glyphs where transformed" {
    // CFF: nothing transformed, every table as it was.
    {
        const sfnt = try toSfnt(testing.allocator, testdata.cff_woff2);
        defer testing.allocator.free(sfnt);
        try testing.expectEqualStrings(".otf", extension(sfnt).?);
        var want = try tablesOf(testdata.cff, 0);
        defer want.deinit(testing.allocator);
        var got = try tablesOf(sfnt, 0);
        defer got.deinit(testing.allocator);
        try testing.expectEqual(want.count(), got.count());
        for (want.keys(), want.values()) |t, d| {
            if (t == tagInt("head")) continue; // its checksum adjustment differs
            try testing.expectEqualSlices(u8, d, got.get(t).?);
        }
        try expectSameGlyphs(testdata.cff, sfnt, 0);
    }
    // TrueType: glyf, loca and hmtx transformed; the rest as it was, the
    // glyphs and metrics the same, hmtx byte for byte.
    {
        const sfnt = try toSfnt(testing.allocator, testdata.truetype_woff2);
        defer testing.allocator.free(sfnt);
        try testing.expectEqualStrings(".ttf", extension(sfnt).?);
        var want = try tablesOf(testdata.truetype, 0);
        defer want.deinit(testing.allocator);
        var got = try tablesOf(sfnt, 0);
        defer got.deinit(testing.allocator);
        try testing.expectEqual(want.count(), got.count());
        for (want.keys(), want.values()) |t, d| {
            if (t == tagInt("head") or t == tagInt("glyf") or t == tagInt("loca")) continue;
            try testing.expectEqualSlices(u8, d, got.get(t).?);
        }
        try expectSameGlyphs(testdata.truetype, sfnt, 0);
        // The whole file sums to the magic number head records.
        try testing.expectEqual(@as(u32, 0xB1B0AFBA), checksum(sfnt));
    }
}

test "a WOFF2 collection decodes to a collection, shared tables once" {
    const sfnt = try toSfnt(testing.allocator, testdata.collection_woff2);
    defer testing.allocator.free(sfnt);
    try testing.expectEqual(Kind.collection, kindOf(sfnt));
    try testing.expectEqualStrings(".ttc", extension(sfnt).?);
    try testing.expectEqual(@as(u32, 2), faceCount(sfnt));
    try expectSameGlyphs(testdata.truetype, sfnt, 0);
    try expectSameGlyphs(testdata.fallback, sfnt, 1);
    // OS/2, which the two faces share, is one table at one offset.
    var t0 = try tablesOf(sfnt, 0);
    defer t0.deinit(testing.allocator);
    var t1 = try tablesOf(sfnt, 1);
    defer t1.deinit(testing.allocator);
    try testing.expectEqual(t0.get(tagInt("OS/2")).?.ptr, t1.get(tagInt("OS/2")).?.ptr);
    try testing.expect(t0.get(tagInt("glyf")).?.ptr != t1.get(tagInt("glyf")).?.ptr);
}

test "Face loads WOFF and WOFF2 directly" {
    for ([_][]const u8{ testdata.truetype_woff, testdata.truetype_woff2, testdata.cff_woff, testdata.cff_woff2 }) |bytes| {
        const f = try FontFace.init(testing.allocator, bytes, 0);
        defer f.deinit();
        try testing.expectEqual(@as(?f64, 700), try f.capHeight());
    }
}

test "damaged containers are refused, not trusted" {
    var bad = testdata.truetype_woff2.*;
    // Cut short.
    try testing.expectError(error.InvalidFont, toSfnt(testing.allocator, bad[0 .. bad.len - 9]));
    // The Brotli stream spoilt.
    bad[bad.len - 20] ^= 0xFF;
    try testing.expectError(error.InvalidFont, toSfnt(testing.allocator, &bad));
    var bad1 = testdata.truetype_woff.*;
    bad1[bad1.len - 30] ^= 0xFF;
    if (toSfnt(testing.allocator, &bad1)) |s| testing.allocator.free(s) else |e| try testing.expectEqual(error.InvalidFont, e);
}
