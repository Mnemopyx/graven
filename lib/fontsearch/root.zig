//! Font search: describing fonts, and searching and comparing them.
//!
//! A search engine over fonts from any number of sources: installed fonts
//! (the local source, in the app) and, through addons, remote repositories.
//! Every source gives the same `Record` per face, so a query and its
//! results look the same whatever the source; each record says where it
//! came from.
//!
//! Proportions are measured from outlines (x-height, stems, contrast,
//! width, roundness, serifs), not taken from metadata, and decide how alike
//! two fonts are. Licence terms are shown as the font states them, with
//! where each came from; this library never decides what a user may do.
//!
//! No file access: sources and apps pass font bytes and index bytes in.

const std = @import("std");
const hb = @import("hb");
const font = @import("graven_font");
const geom = @import("graven_geom");

const Allocator = std.mem.Allocator;
const Face = font.Face;

/// What the rights holder allows for embedding, from the font's OS/2
/// fsType field (most permissive first).
pub const Embedding = enum {
    /// May be embedded and installed with a document.
    installable,
    /// May be embedded, and the document edited.
    editable,
    /// May be embedded for viewing and printing only.
    preview_print,
    /// May not be embedded.
    restricted,
    /// The font does not say (no OS/2 table).
    unknown,

    /// Whether this allows at least what `want` allows.
    pub fn allows(e: Embedding, want: Embedding) bool {
        if (e == .unknown or want == .unknown) return e == want;
        return @intFromEnum(e) <= @intFromEnum(want);
    }
};

/// A licence as the font's own licence fields state it, roughly classified.
pub const Licence = enum { ofl, apache, ufl, gpl, other, unstated };

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Classifies licence text and URL as a font states them.
pub fn classifyLicence(text: []const u8, url: []const u8) Licence {
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return containsIgnoreCase(hay, needle);
        }
    }.f;
    for ([_][]const u8{ text, url }) |s| {
        if (has(s, "open font license") or has(s, "openfontlicense") or has(s, "/ofl")) return .ofl;
        if (has(s, "apache")) return .apache;
        if (has(s, "ubuntu font licen")) return .ufl;
        if (has(s, "general public license") or has(s, "/gpl")) return .gpl;
    }
    if (text.len == 0 and url.len == 0) return .unstated;
    return .other;
}

/// The embedding the OS/2 fsType bits allow.
pub fn embeddingOf(fs_type: u16) Embedding {
    if (fs_type & 0x000E == 0) return .installable;
    if (fs_type & 0x0008 != 0) return .editable;
    if (fs_type & 0x0004 != 0) return .preview_print;
    return .restricted;
}

pub const Range = struct { first: u21, last: u21 };

/// Proportions measured from outlines, as ratios, so fonts compare at any
/// size. Null where the glyphs to measure are missing.
pub const Measures = struct {
    /// Cap height (H) to em.
    cap: ?f32 = null,
    /// x-height (x) to cap height.
    x: ?f32 = null,
    /// Vertical stem (H's left stem, above the crossbar) to cap height.
    stem: ?f32 = null,
    /// Vertical stem to H's crossbar: 1 for even strokes, more for
    /// contrast.
    contrast: ?f32 = null,
    /// Average advance of a–z to cap height.
    width: ?f32 = null,
    /// o's width to its height.
    round: ?f32 = null,
    /// Whether I widens at its foot (serifs).
    serif: ?bool = null,
};

/// Where a face lives, for what may be done to it: system fonts are read
/// only; user fonts are the user's own, installed and removed through
/// Graven or elsewhere; remote faces are in a repository, not on this
/// machine until fetched.
pub const Scope = enum { system, user, remote };

/// One face, described.
pub const Record = struct {
    /// The source it came from ("local", or an addon's name).
    source: []const u8,
    scope: Scope = .system,
    /// Where the source keeps it (a path, a URL, a repository ID).
    location: []const u8,
    /// The face's index within its file.
    index: u32 = 0,
    /// The source's token for the file's version (size and time), so an
    /// index knows when to describe it again.
    stamp: u64 = 0,

    family: []const u8,
    style: []const u8,
    full_name: []const u8 = "",
    weight: f32 = 400,
    /// Width as a percentage of normal.
    width: f32 = 100,
    italic: bool = false,
    /// Slant angle, degrees (negative leans right, as fonts state it).
    slant: f32 = 0,
    monospace: bool = false,
    variable: bool = false,
    /// Has an OpenType MATH table, for setting math (radicals, big
    /// operators, script sizes).
    math: bool = false,
    upem: u32 = 1000,
    glyphs: u32 = 0,
    measures: Measures = .{},
    /// The codepoints it maps, as ranges.
    coverage: []const Range = &.{},

    /// Embedding permission, from the font's OS/2 table.
    embedding: Embedding = .unknown,
    no_subsetting: bool = false,
    bitmap_only: bool = false,
    /// Licence as the font's name table states it (name IDs 13 and 14).
    licence: Licence = .unstated,
    licence_text: []const u8 = "",
    licence_url: []const u8 = "",

    pub fn covers(r: *const Record, cp: u21) bool {
        // Ranges are sorted: binary search.
        var lo: usize = 0;
        var hi: usize = r.coverage.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const g = r.coverage[mid];
            if (cp < g.first) hi = mid else if (cp > g.last) lo = mid + 1 else return true;
        }
        return false;
    }

    pub fn same(a: *const Record, b: *const Record) bool {
        return a.index == b.index and std.mem.eql(u8, a.source, b.source) and std.mem.eql(u8, a.location, b.location);
    }
};

// Describing ---------------------------------------------------------------------

fn name(a: Allocator, face: *Face, id: hb.hb_ot_name_id_t) Allocator.Error![]const u8 {
    var len: c_uint = 0;
    len = hb.hb_ot_name_get_utf8(face.face, id, hb.HB_LANGUAGE_INVALID, &len, null);
    if (len == 0) return "";
    const buf = try a.alloc(u8, len + 1);
    var n: c_uint = len + 1;
    _ = hb.hb_ot_name_get_utf8(face.face, id, hb.HB_LANGUAGE_INVALID, &n, buf.ptr);
    return buf[0..n];
}

fn tag(s: *const [4]u8) hb.hb_tag_t {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
}

/// Describes `face`, as `source` keeps it at `location` (face `index`).
/// Strings and lists are allocated from `a` (an arena suits).
pub fn describe(a: Allocator, face: *Face, source: []const u8, location: []const u8, index: u32, stamp: u64) (Allocator.Error || font.Error)!Record {
    var r: Record = .{
        .source = try a.dupe(u8, source),
        .location = try a.dupe(u8, location),
        .index = index,
        .stamp = stamp,
        .family = "",
        .style = "",
        .upem = face.upem,
        .glyphs = hb.hb_face_get_glyph_count(face.face),
    };
    // The typographic names group a family's styles; the legacy ones split
    // weights into families of their own.
    r.family = try name(a, face, hb.HB_OT_NAME_ID_TYPOGRAPHIC_FAMILY);
    if (r.family.len == 0) r.family = try name(a, face, hb.HB_OT_NAME_ID_FONT_FAMILY);
    r.style = try name(a, face, hb.HB_OT_NAME_ID_TYPOGRAPHIC_SUBFAMILY);
    if (r.style.len == 0) r.style = try name(a, face, hb.HB_OT_NAME_ID_FONT_SUBFAMILY);
    r.full_name = try name(a, face, hb.HB_OT_NAME_ID_FULL_NAME);
    r.licence_text = try name(a, face, hb.HB_OT_NAME_ID_LICENSE);
    r.licence_url = try name(a, face, hb.HB_OT_NAME_ID_LICENSE_URL);
    r.licence = classifyLicence(r.licence_text, r.licence_url);

    r.weight = hb.hb_style_get_value(face.font, hb.HB_STYLE_TAG_WEIGHT);
    r.width = hb.hb_style_get_value(face.font, hb.HB_STYLE_TAG_WIDTH);
    r.italic = hb.hb_style_get_value(face.font, hb.HB_STYLE_TAG_ITALIC) > 0.5;
    r.slant = hb.hb_style_get_value(face.font, hb.HB_STYLE_TAG_SLANT_ANGLE);
    r.variable = hb.hb_ot_var_has_data(face.face) != 0;
    r.math = hb.hb_ot_math_has_data(face.face) != 0;

    // fsType is the u16 at offset 8 of OS/2.
    const os2 = hb.hb_face_reference_table(face.face, tag("OS/2"));
    defer hb.hb_blob_destroy(os2);
    var os2_len: c_uint = 0;
    const os2_data = hb.hb_blob_get_data(os2, &os2_len);
    if (os2_data != null and os2_len >= 10) {
        const p: [*]const u8 = @ptrCast(os2_data);
        const fs_type = std.mem.readInt(u16, p[8..10], .big);
        r.embedding = embeddingOf(fs_type);
        r.no_subsetting = fs_type & 0x0100 != 0;
        r.bitmap_only = fs_type & 0x0200 != 0;
    }

    // Coverage as sorted ranges.
    const set = hb.hb_set_create();
    defer hb.hb_set_destroy(set);
    hb.hb_face_collect_unicodes(face.face, set);
    var ranges: std.ArrayList(Range) = .empty;
    var first: hb.hb_codepoint_t = hb.HB_SET_VALUE_INVALID;
    var last: hb.hb_codepoint_t = hb.HB_SET_VALUE_INVALID;
    while (hb.hb_set_next_range(set, &first, &last) != 0) {
        if (first > 0x10FFFF) break;
        try ranges.append(a, .{ .first = @intCast(first), .last = @intCast(@min(last, 0x10FFFF)) });
    }
    r.coverage = try ranges.toOwnedSlice(a);

    if (face.glyph('i')) |gi| if (face.glyph('m')) |gm| {
        r.monospace = face.advance(gi) == face.advance(gm) and face.advance(gi) > 0;
    };
    r.measures = try measure(face);
    return r;
}

/// Where a horizontal (`across` false: at height `at`) or vertical
/// (`across` true: at x `at`) line crosses a glyph's outline, sorted;
/// curves are flattened finely enough for measuring.
fn crossings(buf: []f64, o: geom.Outline, at: f64, vertical: bool) []f64 {
    var n: usize = 0;
    for (o.contours) |c| for (c.segments) |s| {
        const steps: usize = if (s == .line) 1 else 24;
        var prev = s.start();
        for (1..steps + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
            const p = pointAt(s, t);
            const a0 = if (vertical) prev.x else prev.y;
            const a1 = if (vertical) p.x else p.y;
            if ((a0 <= at and a1 > at) or (a1 <= at and a0 > at)) {
                const f = (at - a0) / (a1 - a0);
                const b0 = if (vertical) prev.y else prev.x;
                const b1 = if (vertical) p.y else p.x;
                if (n < buf.len) {
                    buf[n] = b0 + f * (b1 - b0);
                    n += 1;
                }
            }
            prev = p;
        }
    };
    std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
    return buf[0..n];
}

fn pointAt(s: geom.Segment, t: f64) geom.Point {
    return s.at(t);
}

/// The first ink span along a line: its length.
fn firstSpan(xs: []const f64) ?f64 {
    if (xs.len < 2) return null;
    return xs[1] - xs[0];
}

/// Measures the face's proportions from its outlines.
pub fn measure(face: *Face) font.Error!Measures {
    var m: Measures = .{};
    var buf: [64]f64 = undefined;
    const cap = (try face.capHeight()) orelse return m;
    m.cap = @floatCast(cap / @as(f64, @floatFromInt(face.upem)));
    if (try face.xHeight()) |x| m.x = @floatCast(x / cap);

    const h = (try face.outline(face.glyph('H').?));
    const hb_box = h.bounds();
    // Stems are measured above the crossbar, which sits near half height.
    const stem_at = cap * 0.78;
    if (firstSpan(crossings(&buf, h, stem_at, false))) |stem| {
        m.stem = @floatCast(stem / cap);
        // The crossbar: the span nearest half height, down the middle.
        const ys = crossings(&buf, h, (hb_box.x0 + hb_box.x1) / 2, true);
        var bar: ?f64 = null;
        var k: usize = 0;
        while (k + 1 < ys.len) : (k += 2) {
            const mid = (ys[k] + ys[k + 1]) / 2;
            if (bar == null or @abs(mid - cap / 2) < @abs(bar.? - cap / 2)) bar = ys[k + 1] - ys[k];
        }
        if (bar) |b| if (b > 0) {
            m.contrast = @floatCast(stem / b);
        };
        // Serifs: H's left foot much wider than its stem. (Not I, whose
        // feet a monospaced sans widens to fill its cell.) The foot is all
        // the ink left of the gap between the stems, so a serif drawn as a
        // contour of its own over the stem still counts.
        const mid = crossings(&buf, h, stem_at, false);
        if (mid.len >= 4) {
            const gap = (mid[1] + mid[2]) / 2;
            // Where the stem's left edge would reach the foot, allowing for
            // its lean (italic, oblique), measured below the crossbar too.
            var low_buf: [64]f64 = undefined;
            const low_at = cap * 0.22;
            const low = crossings(&low_buf, h, low_at, false);
            const lean = if (low.len >= 2) (mid[0] - low[0]) / (stem_at - low_at) else 0;
            const left = mid[0] - lean * (stem_at - cap * 0.03);
            var foot_buf: [64]f64 = undefined;
            const foot = crossings(&foot_buf, h, cap * 0.03, false);
            var lo: ?f64 = null;
            var hi: ?f64 = null;
            for (foot) |x| if (x < gap) {
                lo = if (lo) |v| @min(v, x) else x;
                hi = if (hi) |v| @max(v, x) else x;
            };
            if (lo != null and hi != null) m.serif = (hi.? - lo.?) > 1.5 * stem and lo.? < left - 0.1 * stem;
        }
    }
    var total: f64 = 0;
    var count: f64 = 0;
    for ('a'..'z' + 1) |c| if (face.glyph(@intCast(c))) |g| {
        total += @floatFromInt(face.advance(g));
        count += 1;
    };
    if (count > 0) m.width = @floatCast(total / count / cap);
    if (face.glyph('o')) |g| {
        const b = (try face.outline(g)).bounds();
        if (!b.isEmpty() and b.y1 > b.y0) m.round = @floatCast((b.x1 - b.x0) / (b.y1 - b.y0));
    }
    return m;
}

// Likeness ---------------------------------------------------------------------

/// How unlike two fonts are, from their measured proportions and style: 0
/// for alike, growing with each difference. Each term is a difference
/// divided by what reads as a clear difference, weighted.
pub fn distance(a: *const Record, b: *const Record) f64 {
    var sum: f64 = 0;
    const term = struct {
        fn f(s: *f64, x: ?f32, y: ?f32, scale: f64, weight: f64) void {
            if (x == null or y == null) {
                // Unknown on one side (a symbol or emoji font has no H to
                // measure): as unlike as a clear difference, twice over.
                if ((x == null) != (y == null)) s.* += weight * 4;
                return;
            }
            const d = (@as(f64, x.?) - @as(f64, y.?)) / scale;
            s.* += weight * d * d;
        }
    }.f;
    const ma = a.measures;
    const mb = b.measures;
    term(&sum, ma.x, mb.x, 0.05, 3);
    term(&sum, ma.stem, mb.stem, 0.03, 3);
    term(&sum, if (ma.contrast) |c| @log(c) else null, if (mb.contrast) |c| @log(c) else null, 0.3, 1.5);
    term(&sum, ma.width, mb.width, 0.08, 2);
    term(&sum, ma.round, mb.round, 0.08, 1);
    if (ma.serif != null and mb.serif != null and ma.serif.? != mb.serif.?) sum += 2;
    if (a.monospace != b.monospace) sum += 2;
    if (a.italic != b.italic) sum += 1.5;
    const ds = (a.slant - b.slant) / 6;
    sum += ds * ds;
    return @sqrt(sum);
}

// Searching --------------------------------------------------------------------

pub const Query = struct {
    /// Words that must all appear in the family or style (any case).
    words: []const u8 = "",
    /// Rank by likeness to this font (it is left out of the results).
    like: ?*const Record = null,
    /// Characters the font must have.
    covers: []const u21 = &.{},
    /// Let fonts missing some of `covers` through (ranked by how many).
    allow_missing: bool = false,
    math: ?bool = null,
    italic: ?bool = null,
    monospace: ?bool = null,
    serif: ?bool = null,
    variable: ?bool = null,
    weight: ?[2]f32 = null,
    /// At least this embedding permission.
    embedding: ?Embedding = null,
    /// Any of these licences (none: any).
    licences: []const Licence = &.{},
    limit: usize = 50,
};

pub const Hit = struct {
    /// Into the records searched.
    index: usize,
    /// Likeness to the query's font, when it has one.
    distance: ?f64 = null,
    /// How many of the query's characters it lacks.
    missing: usize = 0,
};

fn wordsMatch(r: *const Record, words: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, words, " \t");
    while (it.next()) |w| {
        if (!containsIgnoreCase(r.family, w) and !containsIgnoreCase(r.style, w)) return false;
    }
    return true;
}

/// The records matching `q`, best first: by likeness when the query has a
/// font to be like, else by how few characters they miss, then by name.
/// Allocated from `gpa`.
pub fn search(gpa: Allocator, records: []const Record, q: Query) Allocator.Error![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    for (records, 0..) |*r, i| {
        if (q.like) |like| if (r.same(like)) continue;
        if (!wordsMatch(r, q.words)) continue;
        if (q.math) |v| if (r.math != v) continue;
        if (q.italic) |v| if (r.italic != v) continue;
        if (q.monospace) |v| if (r.monospace != v) continue;
        if (q.variable) |v| if (r.variable != v) continue;
        if (q.serif) |v| if (r.measures.serif != v) continue;
        if (q.weight) |w| if (r.weight < w[0] or r.weight > w[1]) continue;
        if (q.embedding) |e| if (!r.embedding.allows(e)) continue;
        if (q.licences.len > 0 and std.mem.indexOfScalar(Licence, q.licences, r.licence) == null) continue;
        var missing: usize = 0;
        for (q.covers) |cp| if (!r.covers(cp)) {
            missing += 1;
        };
        if (missing > 0 and !q.allow_missing) continue;
        try hits.append(gpa, .{ .index = i, .distance = if (q.like) |like| distance(like, r) else null, .missing = missing });
    }
    const Ctx = struct { records: []const Record };
    std.mem.sort(Hit, hits.items, Ctx{ .records = records }, struct {
        fn less(c: Ctx, x: Hit, y: Hit) bool {
            if (x.missing != y.missing) return x.missing < y.missing;
            if (x.distance != null and y.distance != null and x.distance.? != y.distance.?) return x.distance.? < y.distance.?;
            const a = &c.records[x.index];
            const b = &c.records[y.index];
            const fam = std.ascii.orderIgnoreCase(a.family, b.family);
            if (fam != .eq) return fam == .lt;
            return std.ascii.orderIgnoreCase(a.style, b.style) == .lt;
        }
    }.less);
    if (hits.items.len > q.limit) hits.shrinkRetainingCapacity(q.limit);
    return hits.toOwnedSlice(gpa);
}

/// The record named `family` (and `style`, when given), any case.
pub fn find(records: []const Record, family: []const u8, style: ?[]const u8) ?usize {
    for (records, 0..) |r, i| {
        if (!std.ascii.eqlIgnoreCase(r.family, family)) continue;
        if (style) |s| if (!std.ascii.eqlIgnoreCase(r.style, s)) continue;
        return i;
    }
    return null;
}

/// A typeface family: the faces that share a typographic family name.
pub const Family = struct {
    /// The family's name, as its first face gives it.
    name: []const u8,
    /// Its faces, as indexes into the records: by width, then weight, then
    /// upright before italic.
    faces: []const usize,
    /// How many of its faces are of each scope.
    system: u32 = 0,
    user: u32 = 0,
    remote: u32 = 0,
};

/// How families are ordered: by name, or by where each first appears in
/// the subset (a ranked search's order, families by their best face).
pub const FamilyOrder = enum { name, first };

/// The families of `records` (or of those `subset` names, in its terms),
/// named without regard to case. Lists from `gpa`; free with
/// `freeFamilies`.
pub fn families(gpa: Allocator, records: []const Record, subset: ?[]const usize, order: FamilyOrder) Allocator.Error![]Family {
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    defer {
        var it = by_name.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        by_name.deinit(gpa);
    }
    var lists: std.ArrayList(std.ArrayList(usize)) = .empty;
    defer lists.deinit(gpa);
    errdefer for (lists.items) |*l| l.deinit(gpa);
    var out: std.ArrayList(Family) = .empty;
    defer out.deinit(gpa);
    const count = if (subset) |s| s.len else records.len;
    for (0..count) |j| {
        const i = if (subset) |s| s[j] else j;
        const r = &records[i];
        const key = try std.ascii.allocLowerString(gpa, r.family);
        const e = try by_name.getOrPut(gpa, key);
        if (e.found_existing) gpa.free(key) else {
            e.value_ptr.* = out.items.len;
            try out.append(gpa, .{ .name = r.family, .faces = &.{} });
            try lists.append(gpa, .empty);
        }
        const f = &out.items[e.value_ptr.*];
        try lists.items[e.value_ptr.*].append(gpa, i);
        switch (r.scope) {
            .system => f.system += 1,
            .user => f.user += 1,
            .remote => f.remote += 1,
        }
    }
    const Order = struct {
        recs: []const Record,
        fn face(o: @This(), a: usize, b: usize) bool {
            const x = o.recs[a];
            const y = o.recs[b];
            if (x.width != y.width) return x.width < y.width;
            if (x.weight != y.weight) return x.weight < y.weight;
            if (x.italic != y.italic) return !x.italic;
            return std.ascii.lessThanIgnoreCase(x.style, y.style);
        }
        fn family(_: void, a: Family, b: Family) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    };
    for (out.items, lists.items) |*f, *l| {
        std.mem.sort(usize, l.items, Order{ .recs = records }, Order.face);
        f.faces = try l.toOwnedSlice(gpa);
    }
    if (order == .name) std.mem.sort(Family, out.items, {}, Order.family);
    return out.toOwnedSlice(gpa);
}

pub fn freeFamilies(gpa: Allocator, list: []Family) void {
    for (list) |f| gpa.free(f.faces);
    gpa.free(list);
}

/// A face's family companions: its italic, bold and bold italic, as
/// indexes into `records`.
pub const Variants = struct {
    italic: ?usize = null,
    bold: ?usize = null,
    bold_italic: ?usize = null,
};

/// The italic, bold and bold italic of the family of `records[k]`: faces
/// of its family and width, the italic nearest its weight, the bolds
/// nearest 300 heavier (at least 100 heavier, and at least semibold, 600).
pub fn variantsOf(records: []const Record, k: usize) Variants {
    const base = records[k];
    const bold_target = base.weight + 300;
    const bold_min = @max(600, base.weight + 100);
    var out: Variants = .{};
    var best: [3]f32 = @splat(std.math.inf(f32));
    for (records, 0..) |r, i| {
        if (i == k or !std.ascii.eqlIgnoreCase(r.family, base.family)) continue;
        if (@abs(r.width - base.width) > 5) continue;
        const slot: usize, const d: f32 = if (r.weight >= bold_min)
            .{ if (r.italic) 2 else 1, @abs(r.weight - bold_target) }
        else if (r.italic and !base.italic)
            .{ 0, @abs(r.weight - base.weight) }
        else
            continue;
        if (d < best[slot]) {
            best[slot] = d;
            switch (slot) {
                0 => out.italic = i,
                1 => out.bold = i,
                else => out.bold_italic = i,
            }
        }
    }
    return out;
}

// Sources and the index ----------------------------------------------------------

/// Where fonts come from: installed fonts (the local source, in the app),
/// or a remote repository through an addon. Every source describes its
/// fonts as records and hands over a font's bytes when asked.
pub const Source = struct {
    name: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Every font the source has, described; strings from `arena`.
        list: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]Record,
        /// A font file's bytes, for loading its outlines; from `gpa`.
        fetch: *const fn (ctx: *anyopaque, gpa: Allocator, record: *const Record) anyerror![]u8,
    };

    pub fn list(s: Source, arena: Allocator) ![]Record {
        return s.vtable.list(s.ctx, arena);
    }

    pub fn fetch(s: Source, gpa: Allocator, record: *const Record) ![]u8 {
        return s.vtable.fetch(s.ctx, gpa, record);
    }
};

/// The version of the index's layout; a cache of another is described
/// afresh.
pub const index_version: u32 = 6;

const IndexFile = struct {
    version: u32,
    records: []const Record,
};

/// Records as an index file's bytes (JSON), allocated from `gpa`.
pub fn saveIndex(gpa: Allocator, records: []const Record) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, IndexFile{ .version = index_version, .records = records }, .{});
}

/// Records from an index file's bytes, allocated from `arena`; null when
/// the bytes are not an index of this version.
pub fn loadIndex(arena: Allocator, bytes: []const u8) ?[]Record {
    const f = std.json.parseFromSliceLeaky(IndexFile, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (f.version != index_version) return null;
    return @constCast(f.records);
}

// Tests --------------------------------------------------------------------------

const testing = std.testing;
const testdata = @import("graven_testdata");

test "embedding follows fsType, most permissive bit first" {
    try testing.expectEqual(.installable, embeddingOf(0));
    try testing.expectEqual(.restricted, embeddingOf(0x0002));
    try testing.expectEqual(.preview_print, embeddingOf(0x0004));
    try testing.expectEqual(.editable, embeddingOf(0x000C));
    try testing.expect(Embedding.installable.allows(.editable));
    try testing.expect(!Embedding.preview_print.allows(.editable));
    try testing.expect(!Embedding.unknown.allows(.restricted));
}

test "licences are classified from the font's own words" {
    try testing.expectEqual(.ofl, classifyLicence("This Font Software is licensed under the SIL Open Font License, Version 1.1.", ""));
    try testing.expectEqual(.ofl, classifyLicence("", "https://openfontlicense.org"));
    try testing.expectEqual(.apache, classifyLicence("Licensed under the Apache License, Version 2.0", ""));
    try testing.expectEqual(.other, classifyLicence("All rights reserved. Contact us.", ""));
    try testing.expectEqual(.unstated, classifyLicence("", ""));
}

test "a face is described: names, coverage, measures" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tt = try Face.init(testing.allocator, testdata.truetype, 0);
    defer tt.deinit();
    const r = try describe(a, tt, "local", "/fonts/test.ttf", 0, 42);
    try testing.expect(r.family.len > 0);
    try testing.expect(r.covers('H'));
    try testing.expect(!r.covers('x'));
    try testing.expect(r.measures.cap != null);
    try testing.expect(r.measures.stem.? > 0);
    try testing.expectEqual(42, r.stamp);

    // An index round-trips its records.
    const bytes = try saveIndex(testing.allocator, &.{r});
    defer testing.allocator.free(bytes);
    const back = loadIndex(a, bytes).?;
    try testing.expectEqualStrings(r.family, back[0].family);
    try testing.expectEqual(r.coverage.len, back[0].coverage.len);
    try testing.expectEqual(r.measures.stem, back[0].measures.stem);
    try testing.expectEqual(null, loadIndex(a, "{\"version\":0,\"records\":[]}"));
}

test "search filters, covers characters, and ranks by likeness" {
    const base: Record = .{ .source = "local", .location = "a", .family = "Alpha Sans", .style = "Regular", .coverage = &.{.{ .first = 'A', .last = 'z' }}, .measures = .{ .x = 0.7, .stem = 0.12, .width = 0.75, .serif = false } };
    var near = base;
    near.location = "b";
    near.family = "Beta Sans";
    near.measures.x = 0.71;
    var far = base;
    far.location = "c";
    far.family = "Gamma Serif";
    far.measures = .{ .x = 0.6, .stem = 0.2, .width = 0.6, .serif = true };
    far.licence = .ofl;
    var greek = base;
    greek.location = "d";
    greek.family = "Delta Greek";
    greek.coverage = &.{ .{ .first = 'A', .last = 'z' }, .{ .first = 0x391, .last = 0x3C9 } };
    greek.measures.x = 0.8;
    const records = [_]Record{ far, near, base, greek };

    const like = try search(testing.allocator, &records, .{ .like = &records[2] });
    defer testing.allocator.free(like);
    try testing.expectEqual(3, like.len);
    try testing.expectEqualStrings("Beta Sans", records[like[0].index].family);
    try testing.expectEqualStrings("Gamma Serif", records[like[2].index].family);

    const alpha = [_]u21{0x3B1};
    const cov = try search(testing.allocator, &records, .{ .covers = &alpha });
    defer testing.allocator.free(cov);
    try testing.expectEqual(1, cov.len);
    try testing.expectEqualStrings("Delta Greek", records[cov[0].index].family);

    const ofl = try search(testing.allocator, &records, .{ .licences = &.{.ofl}, .words = "serif" });
    defer testing.allocator.free(ofl);
    try testing.expectEqual(1, ofl.len);
    try testing.expectEqual(2, find(&records, "alpha sans", "regular").?);
}

test "faces group into families, by width, weight and slope" {
    const recs = [_]Record{
        .{ .source = "", .location = "", .family = "Serif", .style = "Bold", .weight = 700 },
        .{ .source = "", .location = "", .family = "Mono", .style = "Regular", .scope = .user },
        .{ .source = "", .location = "", .family = "serif", .style = "Italic", .weight = 400, .italic = true, .scope = .user },
        .{ .source = "", .location = "", .family = "Serif", .style = "Regular", .weight = 400 },
        .{ .source = "", .location = "", .family = "Serif", .style = "Condensed", .weight = 400, .width = 75 },
    };
    const fams = try families(testing.allocator, &recs, null, .name);
    defer freeFamilies(testing.allocator, fams);
    try testing.expectEqual(2, fams.len);
    try testing.expectEqualStrings("Mono", fams[0].name);
    try testing.expectEqual(1, fams[0].user);
    try testing.expectEqualStrings("Serif", fams[1].name);
    try testing.expectEqualSlices(usize, &.{ 4, 3, 2, 0 }, fams[1].faces);
    try testing.expectEqual(3, fams[1].system);
    try testing.expectEqual(1, fams[1].user);
    // A subset: only the faces a search found; in its order, a family where
    // its first face is.
    const some = try families(testing.allocator, &recs, &.{ 0, 1, 3 }, .first);
    defer freeFamilies(testing.allocator, some);
    try testing.expectEqual(2, some.len);
    try testing.expectEqualStrings("Serif", some[0].name);
    try testing.expectEqualSlices(usize, &.{ 3, 0 }, some[0].faces);
}

test "a face's italic and bolds are found in its family" {
    const recs = [_]Record{
        .{ .source = "", .location = "", .family = "Serif", .style = "Regular", .weight = 400 },
        .{ .source = "", .location = "", .family = "Serif", .style = "Italic", .weight = 400, .italic = true },
        .{ .source = "", .location = "", .family = "Serif", .style = "Semibold", .weight = 600 },
        .{ .source = "", .location = "", .family = "Serif", .style = "Bold", .weight = 700 },
        .{ .source = "", .location = "", .family = "Serif", .style = "Bold Italic", .weight = 700, .italic = true },
        .{ .source = "", .location = "", .family = "Serif", .style = "Medium Italic", .weight = 500, .italic = true },
        .{ .source = "", .location = "", .family = "Serif Condensed", .style = "Bold", .weight = 700 },
        .{ .source = "", .location = "", .family = "Serif", .style = "Condensed Bold", .weight = 700, .width = 75 },
    };
    const v = variantsOf(&recs, 0);
    try std.testing.expectEqual(1, v.italic);
    try std.testing.expectEqual(3, v.bold);
    try std.testing.expectEqual(4, v.bold_italic);
    // From the semibold, bold is 300 heavier at best: the bold.
    const w = variantsOf(&recs, 2);
    try std.testing.expectEqual(3, w.bold);
    // Nothing else in a family of one.
    const c = variantsOf(&recs, 6);
    try std.testing.expectEqual(Variants{}, c);
}
