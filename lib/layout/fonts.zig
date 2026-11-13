//! Composed fonts to faces: the document names its fonts by family and
//! style (see `model.ComposedFont`); an app knows which fonts it has and
//! how to load them. `resolve` matches the two and gives the face table to
//! render with and each style's spec in it, with every substitution it had
//! to make, for the dump and for flagging.
//!
//! No file access: the app supplies its fonts as a `Catalog`, loading a
//! face only when a composed font asks for it.

const std = @import("std");
const engine = @import("graven_engine");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const FaceId = engine.render.FaceId;
const FontName = model.FontName;
const ObjectId = model.ObjectId;

/// The fonts an app can supply: their names, and a way to load each.
pub const Catalog = struct {
    names: []const FontName,
    ctx: *anyopaque,
    /// The face for `names[index]`, loaded (and kept by the app, which owns
    /// it), or null when it cannot be.
    load: *const fn (ctx: *anyopaque, index: usize) ?*engine.Face,
};

/// Styles tried, in order, when a family has the font asked for but not in
/// the style asked for.
const plain_styles = [_][]const u8{ "Regular", "Book", "Roman", "Normal", "Medium" };

/// The catalog entry for `want`: the same family and style, else another
/// style of the family (a plain one first), else none.
pub fn find(names: []const FontName, want: FontName) ?struct { index: usize, exact: bool } {
    for (names, 0..) |n, i| if (n.eql(want)) return .{ .index = i, .exact = true };
    for (plain_styles) |style| {
        for (names, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n.family, want.family) and std.ascii.eqlIgnoreCase(n.style, style)) return .{ .index = i, .exact = false };
        }
    }
    for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n.family, want.family)) return .{ .index = i, .exact = false };
    return null;
}

/// A font a composed font asked for and did not get as named.
pub const Substitution = struct {
    /// The composed font that asked.
    font: ObjectId,
    wanted: FontName,
    /// What it got instead: another style of the family; null for none
    /// (the default face for a main font, nothing for a member).
    got: ?FontName,
};

/// A document's fonts, resolved.
pub const Resolved = struct {
    gpa: Allocator,
    /// The face table: 0 is the default face, the rest as composed fonts
    /// need them.
    faces: std.ArrayList(*engine.Face) = .empty,
    /// Per style, in the model's order, its spec with its faces in
    /// `faces`, and the style's ID. A spec's coverage ranges point into the
    /// model.
    specs: std.ArrayList(engine.style.Spec) = .empty,
    ids: std.ArrayList(model.StyleId) = .empty,
    /// The members of each spec, in one list the specs' slices point into.
    members: std.ArrayList(engine.style.Member) = .empty,
    substitutions: std.ArrayList(Substitution) = .empty,

    pub fn deinit(r: *Resolved) void {
        r.faces.deinit(r.gpa);
        r.specs.deinit(r.gpa);
        r.ids.deinit(r.gpa);
        r.members.deinit(r.gpa);
        r.substitutions.deinit(r.gpa);
        r.* = undefined;
    }
};

const Resolver = struct {
    r: *Resolved,
    catalog: Catalog,
    /// Catalog index → face table index, for faces already loaded.
    loaded: std.AutoHashMapUnmanaged(usize, FaceId) = .empty,

    /// The face for `want`, recording a substitution; null when the
    /// catalog has nothing of its family, or cannot load it.
    fn face(s: *Resolver, font: ObjectId, want: FontName) Allocator.Error!?FaceId {
        const hit = find(s.catalog.names, want) orelse {
            try s.note(font, want, null);
            return null;
        };
        const id = if (s.loaded.get(hit.index)) |id| id else blk: {
            const f = s.catalog.load(s.catalog.ctx, hit.index) orelse {
                try s.note(font, want, null);
                return null;
            };
            // The same face as one in the table (the default, say): its id.
            const id: FaceId = for (s.r.faces.items, 0..) |e, i| {
                if (e == f) break @intCast(i);
            } else id: {
                try s.r.faces.append(s.r.gpa, f);
                break :id @intCast(s.r.faces.items.len - 1);
            };
            try s.loaded.put(s.r.gpa, hit.index, id);
            break :blk id;
        };
        if (!hit.exact) try s.note(font, want, s.catalog.names[hit.index]);
        return id;
    }

    fn optFace(s: *Resolver, font: ObjectId, want: ?FontName) Allocator.Error!?FaceId {
        return if (want) |n| try s.face(font, n) else null;
    }

    fn note(s: *Resolver, font: ObjectId, want: FontName, got: ?FontName) Allocator.Error!void {
        for (s.r.substitutions.items) |e| if (e.font == font and e.wanted.eql(want)) return;
        try s.r.substitutions.append(s.r.gpa, .{ .font = font, .wanted = want, .got = got });
    }
};

/// Resolves the composed fonts of `m` against `catalog`. Face 0 is
/// `default`, the face a style set in no composed font names as 0 (and the
/// one a composed font's missing main font falls back to). The faces stay
/// the app's; `Resolved` holds pointers to them.
pub fn resolve(gpa: Allocator, m: *const model.Model, catalog: Catalog, default: *engine.Face) Allocator.Error!Resolved {
    var r: Resolved = .{ .gpa = gpa };
    errdefer r.deinit();
    try r.faces.append(gpa, default);
    var s: Resolver = .{ .r = &r, .catalog = catalog };
    defer s.loaded.deinit(gpa);

    // Members first, into one list, so the specs' slices into it stay put.
    const Span = struct { start: usize, len: usize };
    const spans = try gpa.alloc(Span, m.styles.items.len);
    defer gpa.free(spans);
    for (m.styles.items, spans) |st, *span| {
        span.* = .{ .start = r.members.items.len, .len = 0 };
        const i = m.fontIndex(st.font) orelse continue;
        const cf = m.fonts.items[i];
        for (cf.members.items) |mb| {
            // A member that cannot be found is left out: its characters
            // fall to the faces after it, and are reported if none has them.
            const up = (try s.face(cf.id, mb.font)) orelse continue;
            try r.members.append(gpa, .{
                .upright = up,
                .italic = try s.optFace(cf.id, mb.italic),
                .bold = try s.optFace(cf.id, mb.bold),
                .bold_italic = try s.optFace(cf.id, mb.bold_italic),
                .alphabet = mb.alphabet,
                .coverage = mb.coverage,
                .match = mb.match,
                .scale = mb.scale,
                .shift = mb.shift,
            });
            span.len += 1;
        }
    }
    for (m.styles.items, spans) |st, span| {
        var spec = st.spec;
        if (m.fontIndex(st.font)) |i| {
            const cf = m.fonts.items[i];
            spec.upright = (try s.face(cf.id, cf.main)) orelse 0;
            spec.italic = try s.optFace(cf.id, cf.italic);
            spec.bold = try s.optFace(cf.id, cf.bold);
            spec.bold_italic = try s.optFace(cf.id, cf.bold_italic);
            // A variant found only as the regular face is no variant: the
            // engine then reports what it lacks.
            if (spec.italic == spec.upright) spec.italic = null;
            if (spec.bold == spec.upright) spec.bold = null;
            if (spec.bold_italic == spec.upright) spec.bold_italic = null;
            spec.members = r.members.items[span.start..][0..span.len];
        }
        try r.specs.append(gpa, spec);
        try r.ids.append(gpa, st.id);
    }
    return r;
}

// Tests --------------------------------------------------------------------------

const testing = std.testing;
const testdata = @import("graven_testdata");

const TestFonts = struct {
    faces: [3]*engine.Face,
    loads: usize = 0,

    const names = [_]FontName{
        .{ .family = "Graven Test", .style = "Regular" },
        .{ .family = "Graven Test", .style = "Bold" },
        .{ .family = "Graven Fallback", .style = "Regular" },
    };

    fn init() !TestFonts {
        return .{ .faces = .{
            try engine.Face.init(testing.allocator, testdata.truetype, 0),
            try engine.Face.init(testing.allocator, testdata.cff, 0),
            try engine.Face.init(testing.allocator, testdata.fallback, 0),
        } };
    }

    fn deinit(t: *TestFonts) void {
        for (t.faces) |f| f.deinit();
    }

    fn load(ctx: *anyopaque, index: usize) ?*engine.Face {
        const t: *TestFonts = @ptrCast(@alignCast(ctx));
        t.loads += 1;
        return t.faces[index];
    }

    fn catalog(t: *TestFonts) Catalog {
        return .{ .names = &names, .ctx = t, .load = load };
    }
};

test "a style set in a composed font gets its faces, members and all" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const plain = try m.addStyle("Plain", .{ .upright = 0, .cap_height = 3 });
    const legend = try m.addStyle("Legend", .{ .upright = 0, .cap_height = 7 });
    const f = try m.addFont("Legend", .{ .family = "Graven Test" });
    _ = try m.addFontMember(f, 0, .{ .font = .{ .family = "Graven Fallback" }, .shift = 0.1 });
    try m.setStyleFont(legend, f);

    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();
    // The main font is the default face itself: one face for both, and the
    // fallback beside it.
    try testing.expectEqual(2, r.faces.items.len);
    try testing.expectEqual(0, r.specs.items[m.styleIndex(plain).?].upright);
    const spec = r.specs.items[m.styleIndex(legend).?];
    try testing.expectEqual(0, spec.upright);
    try testing.expectEqual(7, spec.cap_height);
    try testing.expectEqual(1, spec.members.len);
    try testing.expectEqual(t.faces[2], r.faces.items[spec.members[0].upright]);
    try testing.expectEqual(0.1, spec.members[0].shift);
    try testing.expectEqual(0, r.substitutions.items.len);

    // It renders: x, which the main face lacks, from the member.
    const ctx = try engine.style.Context.init(r.faces.items, spec);
    var diag: engine.markup.Diagnostic = undefined;
    var render = try engine.renderLabel(testing.allocator, &ctx, "HxH", .{}, &diag);
    defer render.deinit();
    try testing.expectEqual(@as(?FaceId, spec.members[0].upright), render.elements[1].face);
}

test "a composed font's bold resolves to the family's bold face" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const legend = try m.addStyle("Legend", .{ .upright = 0, .cap_height = 7 });
    const f = try m.addFont("Legend", .{ .family = "Graven Test" });
    // An italic the family lacks becomes its regular: no italic.
    try m.setFontVariants(f, .{ .bold = .{ .family = "Graven Test", .style = "Bold" }, .italic = .{ .family = "Graven Test", .style = "Italic" } });
    _ = try m.addFontMember(f, 0, .{ .font = .{ .family = "Graven Fallback" }, .alphabet = .double_struck });
    try m.setStyleFont(legend, f);
    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();
    const spec = r.specs.items[m.styleIndex(legend).?];
    try testing.expectEqual(t.faces[1], r.faces.items[spec.bold.?]);
    try testing.expectEqual(null, spec.italic);
    try testing.expectEqual(null, spec.bold_italic);
    try testing.expect(spec.members[0].alphabet == .double_struck);

    const ctx = try engine.style.Context.init(r.faces.items, spec);
    var diag: engine.markup.Diagnostic = undefined;
    var render = try engine.renderLabel(testing.allocator, &ctx, "H\\textbf{H}\\mathbb{H}", .{}, &diag);
    defer render.deinit();
    try testing.expectEqual(spec.bold, render.elements[1].face);
    try testing.expectEqual(@as(?FaceId, spec.members[0].upright), render.elements[2].face);
}

test "fonts not found as named are substituted and reported" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const legend = try m.addStyle("Legend", .{ .upright = 0, .cap_height = 7 });
    // A style the family lacks, an italic nobody has, a member family
    // nobody has, and one asked for twice.
    const f = try m.addFont("Legend", .{ .family = "Graven Test", .style = "Light" });
    try m.setFontMain(f, .{ .family = "Graven Test", .style = "Light" }, .{ .family = "Nowhere", .style = "Italic" });
    _ = try m.addFontMember(f, 0, .{ .font = .{ .family = "Missing Sans" } });
    _ = try m.addFontMember(f, 9, .{ .font = .{ .family = "graven fallback", .style = "regular" } });
    _ = try m.addFontMember(f, 9, .{ .font = .{ .family = "Graven Fallback" }, .scale = 2 });
    try m.setStyleFont(legend, f);

    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[1]);
    defer r.deinit();
    const spec = r.specs.items[m.styleIndex(legend).?];
    // Light → Regular of the same family, the plain style first.
    try testing.expectEqual(t.faces[0], r.faces.items[spec.upright]);
    try testing.expectEqual(null, spec.italic);
    // The missing member is left out; the fallback, named in any case,
    // loaded once for both members that ask for it.
    try testing.expectEqual(2, spec.members.len);
    try testing.expectEqual(spec.members[0].upright, spec.members[1].upright);
    try testing.expectEqual(2, t.loads);
    try testing.expectEqual(3, r.substitutions.items.len);
    var nulls: usize = 0;
    for (r.substitutions.items) |sub| {
        if (sub.got) |got| {
            try testing.expectEqualStrings("Light", sub.wanted.style);
            try testing.expectEqualStrings("Regular", got.style);
        } else nulls += 1;
    }
    // Missing Sans and the Nowhere italic: nothing.
    try testing.expectEqual(2, nulls);
}

test "a label cache given resolved fonts keeps them when the model syncs it again" {
    var t = try TestFonts.init();
    defer t.deinit();
    var m: model.Model = .init(testing.allocator);
    defer m.deinit();
    const legend = try m.addStyle("Legend", .{ .upright = 0, .cap_height = 7 });
    const f = try m.addFont("Legend", .{ .family = "Graven Test" });
    _ = try m.addFontMember(f, 0, .{ .font = .{ .family = "Graven Fallback" } });
    try m.setStyleFont(legend, f);
    var r = try resolve(testing.allocator, &m, t.catalog(), t.faces[0]);
    defer r.deinit();

    const place = @import("place.zig");
    var labels: place.Labels = .init(testing.allocator, &.{t.faces[0]});
    defer labels.deinit();
    try labels.syncResolved(&r);
    try testing.expectEqual(1, labels.context(legend).?.spec.members.len);
    // As `solve` does: the resolved specs stay.
    try labels.sync(&m);
    try testing.expectEqual(1, labels.context(legend).?.spec.members.len);
    try testing.expectEqual(2, labels.faces.len);
}
