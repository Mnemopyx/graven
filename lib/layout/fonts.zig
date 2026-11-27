//! Text styles' fonts to faces: the document names fonts by family and
//! style (see `model.TextStyle.faces`); an app knows which fonts it has and
//! how to load them. `resolve` matches the two and gives the face table to
//! set legends with and each style's faces by role in it, with every
//! substitution it had to make, for the dump and for flagging.
//!
//! Packages: ready-made faces and rules for math legends, applied to a
//! style (`applyPackage`).
//!
//! No file access: the app supplies its fonts as a `Catalog`, loading a
//! face only when a style asks for it.

const std = @import("std");
const font = @import("graven_font");
const rendering = @import("render.zig");
const glyphic = @import("graven_glyphic");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const FaceId = rendering.FaceId;
const FontName = model.FontName;
const StyleId = model.StyleId;

/// The fonts an app can supply: their names, and a way to load each.
pub const Catalog = struct {
    names: []const FontName,
    /// What each face is (weight, slant, width) where the app measured it
    /// (fontsearch does); else read from its style name.
    described: ?[]const glyphic.fontspec.Described = null,
    ctx: *anyopaque,
    /// The face for `names[index]`, loaded (and kept by the app, which owns
    /// it), or null when it cannot be.
    load: *const fn (ctx: *anyopaque, index: usize) ?*font.Face,
};

/// Two catalogs as one: `first`'s fonts, then `second`'s, so a font both
/// have is taken from `first` (`find` takes the first match). The names
/// and the pair are allocated from `al`, which must outlive the result.
pub fn join(al: Allocator, first: Catalog, second: Catalog) Allocator.Error!Catalog {
    const names = try al.alloc(FontName, first.names.len + second.names.len);
    @memcpy(names[0..first.names.len], first.names);
    @memcpy(names[first.names.len..], second.names);
    const pair = try al.create([2]Catalog);
    pair.* = .{ first, second };
    return .{ .names = names, .ctx = pair, .load = struct {
        fn load(ctx: *anyopaque, i: usize) ?*font.Face {
            const p: *[2]Catalog = @ptrCast(@alignCast(ctx));
            return if (i < p[0].names.len) p[0].load(p[0].ctx, i) else p[1].load(p[1].ctx, i - p[0].names.len);
        }
    }.load };
}

/// The catalog entry for `want`, as glyphic matches faces (`fontspec`):
/// the same family and style, else the family's face nearest in width,
/// slant and weight, else none. What each face is comes from its name.
pub fn find(names: []const FontName, want: FontName) ?Found {
    return findDescribed(names, null, want);
}

/// A catalog entry found, and whether it is the face named.
pub const Found = struct { index: usize, exact: bool };

/// As `find`, with `described` giving what each face is where the app
/// measured it.
pub fn findDescribed(names: []const FontName, described: ?[]const glyphic.fontspec.Described, want: FontName) ?Found {
    for (names, 0..) |n, i| if (n.eql(want)) return .{ .index = i, .exact = true };
    // Only the family's faces are described (a catalog may be large).
    var buf: [512]glyphic.fontspec.Described = undefined;
    var idx: [512]usize = undefined;
    var n: usize = 0;
    for (names, 0..) |nm, i| {
        if (!std.ascii.eqlIgnoreCase(nm.family, want.family)) continue;
        if (n == buf.len) break;
        buf[n] = if (described) |d| d[i] else glyphic.fontspec.describe(nm.family, nm.style);
        idx[n] = i;
        n += 1;
    }
    const m = glyphic.fontspec.matchName(buf[0..n], want.family, want.style) orelse return null;
    return .{ .index = idx[m.index], .exact = false };
}

/// A font a style asked for and did not get as named.
pub const Substitution = struct {
    /// The style that asked.
    style: StyleId,
    wanted: FontName,
    /// What it got instead: another style of the family; null for none
    /// (the role is then left out).
    got: ?FontName,
};

/// A face of a style, for a role, in the face table.
pub const RoleFace = struct { role: []const u8, face: FaceId };

/// A style resolved: its own faces by role (its base's are its base's).
pub const Style = struct { id: StyleId, faces: []const RoleFace };

/// A document's fonts, resolved.
pub const Resolved = struct {
    gpa: Allocator,
    /// The face table: 0 is the default face, the rest as styles need them.
    faces: std.ArrayList(*font.Face) = .empty,
    /// Per style, in the model's order. Roles point into the model.
    styles: std.ArrayList(Style) = .empty,
    /// Every style's faces, in one list the styles' slices point into.
    roles: std.ArrayList(RoleFace) = .empty,
    substitutions: std.ArrayList(Substitution) = .empty,

    pub fn deinit(r: *Resolved) void {
        r.faces.deinit(r.gpa);
        r.styles.deinit(r.gpa);
        r.roles.deinit(r.gpa);
        r.substitutions.deinit(r.gpa);
        r.* = undefined;
    }

    /// Style `id`'s own faces (none for a style it does not have).
    pub fn of(r: *const Resolved, id: StyleId) []const RoleFace {
        for (r.styles.items) |st| if (st.id == id) return st.faces;
        return &.{};
    }
};

const Resolver = struct {
    r: *Resolved,
    catalog: Catalog,
    /// Catalog index → face table index, for faces already loaded.
    loaded: std.AutoHashMapUnmanaged(usize, FaceId) = .empty,

    /// The face for `want`, recording a substitution; null when the
    /// catalog has nothing of its family, or cannot load it.
    fn face(s: *Resolver, style: StyleId, want: FontName) Allocator.Error!?FaceId {
        const hit = findDescribed(s.catalog.names, s.catalog.described, want) orelse {
            try s.note(style, want, null);
            return null;
        };
        const id = (try s.load(hit.index)) orelse {
            try s.note(style, want, null);
            return null;
        };
        if (!hit.exact) try s.note(style, want, s.catalog.names[hit.index]);
        return id;
    }

    /// Catalog face `index` in the face table (loaded once); null when it
    /// cannot be loaded.
    fn load(s: *Resolver, index: usize) Allocator.Error!?FaceId {
        return if (s.loaded.get(index)) |id| id else blk: {
            const f = s.catalog.load(s.catalog.ctx, index) orelse return null;
            // The same face as one in the table (the default, say): its id.
            const id: FaceId = for (s.r.faces.items, 0..) |e, i| {
                if (e == f) break @intCast(i);
            } else id: {
                try s.r.faces.append(s.r.gpa, f);
                break :id @intCast(s.r.faces.items.len - 1);
            };
            try s.loaded.put(s.r.gpa, index, id);
            break :blk id;
        };
    }

    /// The face for treatment `t` (bold, italic, bold italic) when a style
    /// names none: of its text face `text`'s family, as `fontspec` derives
    /// it (bold 700, italic slanted). Null when the family has no face that
    /// is bolder or slanted as asked (glyphic then makes it, or falls back).
    fn derived(s: *Resolver, text: FontName, t: glyphic.fontspec.Treatment) Allocator.Error!?FaceId {
        const names = s.catalog.names;
        var buf: [512]glyphic.fontspec.Described = undefined;
        var idx: [512]usize = undefined;
        var n: usize = 0;
        var text_d: ?glyphic.fontspec.Described = null;
        for (names, 0..) |nm, i| {
            if (!std.ascii.eqlIgnoreCase(nm.family, text.family)) continue;
            if (n == buf.len) break;
            buf[n] = if (s.catalog.described) |d| d[i] else glyphic.fontspec.describe(nm.family, nm.style);
            if (nm.eql(text)) text_d = buf[n];
            idx[n] = i;
            n += 1;
        }
        const td = text_d orelse glyphic.fontspec.describe(text.family, text.style);
        const want = t.derived(.{ .family = text.family, .weight = td.weight, .slant = td.slant, .width = td.width }) orelse return null;
        const m = glyphic.fontspec.match(buf[0..n], want) orelse return null;
        const got = buf[m.index];
        const bold_ok = want.weight <= td.weight or got.weight > td.weight;
        const slant_ok = want.slant == .upright or got.slant != .upright;
        if (!bold_ok or !slant_ok) return null;
        return s.load(idx[m.index]);
    }

    fn note(s: *Resolver, style: StyleId, want: FontName, got: ?FontName) Allocator.Error!void {
        for (s.r.substitutions.items) |e| if (e.style == style and e.wanted.eql(want)) return;
        try s.r.substitutions.append(s.r.gpa, .{ .style = style, .wanted = want, .got = got });
    }
};

/// Resolves the styles' fonts of `m` against `catalog`. Face 0 is
/// `default`, the face of a style that names no text face (nor does its
/// base). A font not found leaves its role out. The faces stay the app's;
/// `Resolved` holds pointers to them.
pub fn resolve(gpa: Allocator, m: *const model.Model, catalog: Catalog, default: *font.Face) Allocator.Error!Resolved {
    return resolveWith(gpa, m, catalog, default, null);
}

/// As `resolve`, the default face known by name (`default_name`): a style
/// set in it (one that names no text face and has no base) takes its bold
/// and italic from its family.
pub fn resolveWith(gpa: Allocator, m: *const model.Model, catalog: Catalog, default: *font.Face, default_name: ?FontName) Allocator.Error!Resolved {
    var r: Resolved = .{ .gpa = gpa };
    errdefer r.deinit();
    try r.faces.append(gpa, default);
    var s: Resolver = .{ .r = &r, .catalog = catalog };
    defer s.loaded.deinit(gpa);
    const starts = try gpa.alloc(usize, m.styles.items.len);
    defer gpa.free(starts);
    for (m.styles.items, starts) |st, *start| {
        start.* = r.roles.items.len;
        var text: ?FontName = null;
        for (st.faces.items) |f| {
            if (std.mem.eql(u8, f.role, "text")) text = f.font;
            const id = (try s.face(st.id, f.font)) orelse continue;
            try r.roles.append(gpa, .{ .role = f.role, .face = id });
        }
        // Bold, italic and bold italic the style names none for: from its
        // text face's family.
        // A style with a math face takes its italic from it (variables
        // in the math font's italic), so only bold is derived there.
        const has_math = for (st.faces.items) |f| {
            if (std.mem.eql(u8, f.role, "math")) break true;
        } else false;
        if (text == null and st.base == .none) text = default_name;
        if (text) |tf| for ([_]glyphic.fontspec.Treatment{ .bold, .italic, .bold_italic }) |t| {
            if (has_math and t != .bold) continue;
            const named = for (st.faces.items) |f| {
                if (std.mem.eql(u8, f.role, t.role())) break true;
            } else false;
            if (named) continue;
            const id = (try s.derived(tf, t)) orelse continue;
            try r.roles.append(gpa, .{ .role = t.role(), .face = id });
        };
    }
    for (m.styles.items, starts, 0..) |st, start, i| {
        const end = if (i + 1 < starts.len) starts[i + 1] else r.roles.items.len;
        try r.styles.append(gpa, .{ .id = st.id, .faces = r.roles.items[start..end] });
    }
    return r;
}

// Math font packages -----------------------------------------------------------

/// A math font package: faces by role and the rules that go with them
/// (decided 2026-11-15; after MathJax 4's fonts and EverCalc's HP-15C
/// legends), applied to a style. The faces are fetched, pinned, by
/// scripts/fetch-fonts.py.
pub const Package = struct {
    name: []const u8,
    faces: []const model.StyleFace,
    rules: []const model.StyleRule = &.{},
};

fn num(x: f32) glyphic.Value {
    return .{ .number = x };
}

const italic: glyphic.Value = .{ .choice = @intFromEnum(glyphic.param.Shape.italic) };

/// STIX Two: Geist SemiBold text; STIX Two Math 2.12 for the constants and
/// symbols; TeX Gyre Schola Bold Italic, 1.15 times, for variables
/// (EverCalc's choices, 2026-11-02); STIX Two Text Bold as a fallback
/// (Greek).
pub const stix_two: Package = .{
    .name = "STIX Two",
    .faces = &.{
        .{ .role = "text", .font = .{ .family = "Geist", .style = "SemiBold" } },
        .{ .role = "math", .font = .{ .family = "STIX Two Math", .style = "Regular" } },
        .{ .role = "italic", .font = .{ .family = "TeX Gyre Schola", .style = "Bold Italic" } },
        .{ .role = "greek", .font = .{ .family = "STIX Two Text", .style = "Bold" } },
    },
    .rules = &.{
        .{ .kind = .variable, .param = .shape, .value = italic },
        .{ .kind = .variable, .param = .scale, .value = num(1.15) },
    },
};

/// Libertinus: Geist SemiBold text with Libertinus Math 7.051 for the rest
/// (chosen 2026-11-15 for the HP-15C keypad): its operators and arrows, its
/// mathematical italic for variables and its MATH table; variables and
/// constants (π) 1.2 times, set beside Geist's capitals.
pub const libertinus: Package = .{
    .name = "Libertinus",
    .faces = &.{
        .{ .role = "text", .font = .{ .family = "Geist", .style = "SemiBold" } },
        .{ .role = "math", .font = .{ .family = "Libertinus Math", .style = "Regular" } },
    },
    .rules = &.{
        .{ .kind = .variable, .param = .shape, .value = italic },
        .{ .kind = .variable, .param = .scale, .value = num(1.2) },
        .{ .kind = .constant, .param = .scale, .value = num(1.2) },
    },
};

/// The packages Graven knows, by name.
pub const packages = [_]*const Package{ &stix_two, &libertinus };

/// The package named `name` (any case; spaces or hyphens alike), or null.
pub fn package(name: []const u8) ?*const Package {
    for (packages) |p| {
        if (p.name.len != name.len) continue;
        const same = for (p.name, name) |x, y| {
            const xx = if (x == ' ') '-' else std.ascii.toLower(x);
            const yy = if (y == ' ') '-' else std.ascii.toLower(y);
            if (xx != yy) break false;
        } else true;
        if (same) return p;
    }
    return null;
}

/// Sets `pkg`'s faces and rules in style `style`.
pub fn applyPackage(m: *model.Model, style: StyleId, pkg: *const Package) model.Model.Error!void {
    for (pkg.faces) |f| try m.setStyleFace(style, f.role, f.font);
    for (pkg.rules) |r| try m.setStyleRule(style, r.kind, r.param, r.value);
}

/// A new style named `name` set in `pkg`, for other styles to take as
/// their base; returns its ID.
pub fn addPackage(m: *model.Model, pkg: *const Package, name: []const u8) model.Model.Error!StyleId {
    const id = try m.addStyle(name, .{});
    try applyPackage(m, id, pkg);
    return id;
}

const testing = std.testing;
const testdata = @import("graven_testdata");
const place = @import("place.zig");

const TestFonts = struct {
    faces: [3]*font.Face,
    loads: usize = 0,

    const names = [_]FontName{
        .{ .family = "Graven Test", .style = "Regular" },
        .{ .family = "Graven Test", .style = "Bold" },
        .{ .family = "Graven Fallback", .style = "Regular" },
    };

    fn init() !TestFonts {
        return .{ .faces = .{
            try font.Face.init(testing.allocator, testdata.truetype, 0),
            try font.Face.init(testing.allocator, testdata.cff, 0),
            try font.Face.init(testing.allocator, testdata.fallback, 0),
        } };
    }

    fn deinit(t: *TestFonts) void {
        for (t.faces) |f| f.deinit();
    }

    fn load(ctx: *anyopaque, index: usize) ?*font.Face {
        const t: *TestFonts = @ptrCast(@alignCast(ctx));
        t.loads += 1;
        return t.faces[index];
    }

    fn catalog(t: *TestFonts) Catalog {
        return .{ .names = &names, .ctx = t, .load = load };
    }
};

test "a style's faces resolve by role; one it lacks falls back to the default face" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const plain = try m.addStyle("Plain", .{ .cap_height = 3 });
    const legend = try m.addStyle("Legend", .{ .cap_height = 7 });
    try m.setStyleFace(legend, "text", .{ .family = "Graven Test" });
    try m.setStyleFace(legend, "bold", .{ .family = "Graven Test", .style = "Bold" });
    try m.setStyleFace(legend, "fallback", .{ .family = "Graven Fallback" });

    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();
    // The text font is the default face itself: one face for both.
    try testing.expectEqual(3, r.faces.items.len);
    try testing.expectEqual(0, r.of(plain).len);
    const fs = r.of(legend);
    try testing.expectEqual(3, fs.len);
    try testing.expectEqual(0, fs[0].face);
    try testing.expectEqualStrings("bold", fs[1].role);
    try testing.expectEqual(t.faces[1], r.faces.items[fs[1].face]);
    try testing.expectEqual(t.faces[2], r.faces.items[fs[2].face]);
    try testing.expectEqual(0, r.substitutions.items.len);
}

test "fonts not found as named are substituted and reported" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const st = try m.addStyle("Legend", .{ .cap_height = 3 });
    // Another style of a family it has; a family it lacks.
    try m.setStyleFace(st, "text", .{ .family = "Graven Test", .style = "Light" });
    try m.setStyleFace(st, "math", .{ .family = "Nowhere Math" });
    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();
    try testing.expectEqual(2, r.substitutions.items.len);
    try testing.expectEqualStrings("Regular", r.substitutions.items[0].got.?.style);
    try testing.expectEqual(null, r.substitutions.items[1].got);
    // The math role is left out (bold is taken from the text face's
    // family: the test family has a Bold).
    for (r.of(st)) |rf| try testing.expect(!std.mem.eql(u8, rf.role, "math"));
}

test "a style that names no bold or italic takes them from its text face's family" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const st = try m.addStyle("Legend", .{ .cap_height = 3 });
    try m.setStyleFace(st, "text", .{ .family = "Graven Test", .style = "Regular" });
    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();
    var bold = false;
    for (r.of(st)) |rf| if (std.mem.eql(u8, rf.role, "bold")) {
        bold = true;
    };
    try testing.expect(bold);
    // Set in the default face, known by name: the same.
    const plain = try m.addStyle("Plain", .{ .cap_height = 3 });
    var r2 = try resolveWith(testing.allocator, &m, t.catalog(), t.faces[0], .{ .family = "Graven Test", .style = "Regular" });
    defer r2.deinit();
    bold = false;
    for (r2.of(plain)) |rf| if (std.mem.eql(u8, rf.role, "bold")) {
        bold = true;
    };
    try testing.expect(bold);
}

test "a label cache given resolved fonts keeps them when the model syncs it again" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const legend = try m.addStyle("Legend", .{ .cap_height = 3 });
    try m.setStyleFace(legend, "fallback", .{ .family = "Graven Fallback" });
    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();
    var labels: place.Labels = .init(testing.allocator, &.{t.faces[0]});
    defer labels.deinit();
    try labels.syncResolved(&r);
    try testing.expectEqual(2, labels.faces.len);
    try labels.sync(&m);
    try testing.expectEqual(2, labels.faces.len);
    try testing.expect(labels.context(legend) != null);
}

test "a package sets a style's faces and rules; styles take it as their base" {
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const base = try addPackage(&m, package("libertinus").?, "Libertinus");
    const key = try m.addStyle("Key", .{ .cap_height = 1.9, .base = base });
    const st = m.textStyle(base);
    try testing.expectEqualStrings("Geist", st.face("text").?.family);
    try testing.expectEqualStrings("Libertinus Math", st.face("math").?.family);
    try testing.expectEqual(3, st.rules.items.len);
    try testing.expectEqual(base, m.textStyle(key).base);
    try testing.expectEqual(null, m.textStyle(key).face("text"));
    try testing.expectEqual(&stix_two, package("stix-two").?);
    try testing.expectError(error.StyleLoop, m.setStyleBase(base, key));
}

test "two catalogs joined: the first's font is taken where both have it" {
    const S = struct {
        fn none(_: *anyopaque, _: usize) ?*font.Face {
            return null;
        }
    };
    var dummy: u8 = 0;
    const a: Catalog = .{ .names = &.{.{ .family = "Inter", .style = "Medium" }}, .ctx = &dummy, .load = S.none };
    const b: Catalog = .{ .names = &.{ .{ .family = "Caladea", .style = "Bold" }, .{ .family = "Inter", .style = "Medium" } }, .ctx = &dummy, .load = S.none };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const j = try join(arena.allocator(), a, b);
    try std.testing.expectEqual(@as(usize, 3), j.names.len);
    try std.testing.expectEqual(@as(usize, 0), find(j.names, .{ .family = "Inter", .style = "Medium" }).?.index);
    try std.testing.expectEqual(@as(usize, 1), find(j.names, .{ .family = "Caladea", .style = "Bold" }).?.index);
}
