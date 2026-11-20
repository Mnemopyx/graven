//! Layout: objects into boxes in expression space, flat and straight
//! (mm, y up, the baseline at y = 0, starting at x = 0). Each object's box
//! has a width (its advance), a height above the baseline and a depth
//! below it, its ink, and its items: glyphs (a face, a glyph, a transform
//! from font units, a growth) and rules. Relative rotation is applied
//! here, about each object's pivot; the ground's path is not (setting.zig
//! maps expression space onto it).
//!
//! Sizes come from the cap height of the text the expression stands in:
//! every parameter given in cap heights becomes mm by it, a script level
//! scales it, and an object's `scale` scales it for all it holds.

const std = @import("std");
const geom = @import("graven_geom");
const param = @import("param.zig");
const ex = @import("expr.zig");
const cascade = @import("cascade.zig");
const faces_mod = @import("faces.zig");
const stops = @import("stops.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Box = geom.Box;
const Affine = geom.Affine;
const Id = ex.Id;
const Kind = ex.Kind;
const Resolver = cascade.Resolver;
const Face = faces_mod.Face;

pub const Item = union(enum) {
    /// A glyph: `m` takes its outline (font units) to expression space.
    /// `grow` thickens it all round, mm.
    /// `cluster`: the byte of the object's text it was shaped from.
    glyph: struct { face: *Face, gid: u32, m: Affine, grow: f64, object: Id, cluster: u32 = 0 },
    /// A filled quadrilateral: a fraction's rule, a radical's bar.
    rule: struct { corners: [4]Point, object: Id },
    /// An empty field, shown while editing: its corners.
    hole: struct { corners: [4]Point, object: Id },

    fn moved(it: Item, m: Affine) Item {
        return switch (it) {
            .glyph => |g| .{ .glyph = .{ .face = g.face, .gid = g.gid, .m = g.m.then(m), .grow = g.grow, .object = g.object, .cluster = g.cluster } },
            .rule => |r| .{ .rule = .{ .corners = corners(r.corners, m), .object = r.object } },
            .hole => |h| .{ .hole = .{ .corners = corners(h.corners, m), .object = h.object } },
        };
    }
};

fn corners(c: [4]Point, m: Affine) [4]Point {
    return .{ m.apply(c[0]), m.apply(c[1]), m.apply(c[2]), m.apply(c[3]) };
}

fn rect(x0: f64, y0: f64, x1: f64, y1: f64) [4]Point {
    return .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
}

/// An object's box as laid out: its advance by its height above its
/// baseline and its depth below, the four corners (lower left, lower
/// right, upper right, upper left) and its baseline's two ends, moved and
/// turned as the object was. Recorded for every object, structures, their
/// fields (rows) and leaves alike, so an editor can draw them.
pub const ObjectBox = struct {
    object: Id,
    corners: [4]Point,
    baseline: [2]Point,
    /// How deep it is: 0 for the object laid out first (a top-level object
    /// in a row set alone), 1 for its parts, and so on.
    nest: u8,

    pub fn moved(b: ObjectBox, m: Affine) ObjectBox {
        return .{ .object = b.object, .corners = corners(b.corners, m), .baseline = .{ m.apply(b.baseline[0]), m.apply(b.baseline[1]) }, .nest = b.nest };
    }
};

/// TeX's atom classes, for spacing between neighbours.
pub const Class = enum { ord, op, bin, rel, open, close, punct, inner };

/// An object laid out.
pub const Laid = struct {
    items: std.ArrayList(Item) = .empty,
    width: f64 = 0,
    height: f64 = 0,
    depth: f64 = 0,
    ink: Box = .empty,
    class: Class = .ord,
    /// Every object's box within it, its own last (see `ObjectBox`).
    boxes: std.ArrayList(ObjectBox) = .empty,

    /// `other`'s items, boxes and ink added, moved by (`dx`, `dy`).
    fn put(l: *Laid, a: Allocator, other: Laid, dx: f64, dy: f64) Allocator.Error!void {
        const m = Affine.translate(dx, dy);
        for (other.items.items) |it| try l.items.append(a, it.moved(m));
        for (other.boxes.items) |b| try l.boxes.append(a, b.moved(m));
        if (!other.ink.isEmpty()) l.ink = l.ink.join(.{ .x0 = other.ink.x0 + dx, .x1 = other.ink.x1 + dx, .y0 = other.ink.y0 + dy, .y1 = other.ink.y1 + dy });
    }

    pub fn transform(l: *Laid, m: Affine) void {
        for (l.items.items) |*it| it.* = it.moved(m);
        for (l.boxes.items) |*b| b.* = b.moved(m);
        if (!l.ink.isEmpty()) l.ink = boundsOf(corners(rect(l.ink.x0, l.ink.y0, l.ink.x1, l.ink.y1), m));
    }
};

fn boundsOf(c: [4]Point) Box {
    var b: Box = .empty;
    for (c) |p| b = b.addPoint(p);
    return b;
}

pub const Missing = struct { object: Id, cp: u21 };

/// Lays objects out for one expression.
pub const Layout = struct {
    a: Allocator,
    r: *const Resolver,
    /// Show empty fields as holes.
    editing: bool = false,
    /// Characters no face had.
    missing: std.ArrayList(Missing) = .empty,
    /// How deep the object being laid out is (see `ObjectBox.nest`).
    nest: u8 = 0,
    /// Values the fitter forces while it sets an object again (see `fitted`).
    forced: std.EnumArray(param.Param, ?param.Value) = .initFill(null),

    fn val(l: *const Layout, id: Id, p: param.Param) f64 {
        return l.get(id, p).number;
    }

    /// Parameter `p` of object `id`: as the fitter forces it while it sets
    /// an object again (unless the object sets it itself), else as its
    /// styles and overrides resolve it.
    pub fn get(l: *const Layout, id: Id, p: param.Param) param.Value {
        if (l.forced.get(p)) |v| if (l.r.e.override(id, p) == null) return v;
        return l.r.get(id, p);
    }

    fn levelScale(l: *const Layout, id: Id, level: u2) f64 {
        return switch (level) {
            0 => 1,
            1 => l.val(id, .script_scale),
            else => l.val(id, .scriptscript_scale),
        };
    }

    /// The math axis, mm, for text of cap height `cap`: from the math
    /// face's MATH table, else about a half cap.
    fn axis(l: *const Layout, id: Id, cap: f64) f64 {
        const fs = l.r.faces(l.a, id) catch return 0.36 * cap;
        const f = fs.get("math") orelse return 0.36 * cap;
        const ax = f.mathAxis() orelse return 0.36 * cap;
        return ax / faces_mod.capUnits(f) * cap;
    }

    /// Object `id` laid out, the text around it at cap height `cap0` mm
    /// (before its script level).
    pub fn lay(l: *Layout, id: Id, cap0_in: f64) anyerror!Laid {
        const e = l.r.e;
        const node = e.node(id);
        const ctx = l.r.context(id);
        const cap0 = cap0_in * l.val(id, .scale);
        const cap = cap0 * l.levelScale(id, ctx.script_level);
        const nest = l.nest;
        l.nest +|= 1;
        defer l.nest = nest;
        var out: Laid = switch (node.kind) {
            .row => try l.layRow(id, cap0, cap),
            .number, .variable, .constant, .symbol, .operator, .relation, .punct, .word, .ellipsis, .space => try l.layText(id, node.text, cap, node.kind),
            // Nothing, until a line breaks there (see `hyphen`).
            .soft_hyphen => .{},
            .fraction => try l.layFraction(id, cap0, cap),
            .scripts => try l.layScripts(id, cap0, cap),
            .large_op => try l.layLargeOp(id, cap0, cap, ctx.style),
            .radical => try l.layRadical(id, cap0, cap),
            .fence => try l.layFence(id, cap0, cap),
            .accent => try l.layAccent(id, cap0, cap),
            .group => try l.lay(e.slot(id, .body), cap0),
        };
        out.class = classOf(e, id);
        // Its own box, before its shift and turn, which move it with its ink.
        try out.boxes.append(l.a, .{ .object = id, .corners = rect(0, -out.depth, out.width, out.height), .baseline = .{ .{ .x = 0, .y = 0 }, .{ .x = out.width, .y = 0 } }, .nest = nest });
        // Moved by its own shift, then turned about its pivot.
        const sx = l.val(id, .shift_x) * cap;
        const sy = l.val(id, .shift_y) * cap;
        if (sx != 0 or sy != 0) out.transform(Affine.translate(sx, sy));
        const deg = l.val(id, .rotate);
        if (deg != 0) l.rotate(id, &out, deg);
        return out;
    }

    fn rotate(l: *Layout, id: Id, out: *Laid, deg: f64) void {
        const pivot: Point = switch (param.as(param.Pivot, l.get(id, .rotate_pivot))) {
            .centre => .{ .x = out.width / 2, .y = (out.height - out.depth) / 2 },
            .ink_centre => if (out.ink.isEmpty()) .{ .x = out.width / 2, .y = 0 } else .{ .x = (out.ink.x0 + out.ink.x1) / 2, .y = (out.ink.y0 + out.ink.y1) / 2 },
            .start => .{ .x = 0, .y = (out.height - out.depth) / 2 },
            .baseline_start => .{ .x = 0, .y = 0 },
        };
        const th = deg * std.math.pi / 180;
        const c = @cos(th);
        const s = @sin(th);
        const turn = Affine.translate(-pivot.x, -pivot.y).then(.{ .a = c, .b = s, .c = -s, .d = c }).then(Affine.translate(pivot.x, pivot.y));
        out.transform(turn);
        if (param.as(param.RotateSpace, l.get(id, .rotate_space)) == .box) {
            // Its neighbours make room for its turned box.
            const b = boundsOf(corners(rect(0, -out.depth, out.width, out.height), turn));
            out.transform(Affine.translate(-b.x0, 0));
            out.width = b.width();
            out.height = @max(0, b.y1);
            out.depth = @max(0, -b.y0);
        }
    }

    /// A leaf's characters laid out one by one, for a column: each its own
    /// box (a space as an empty one, `space` set).
    pub fn layEach(l: *Layout, id: Id, cap0: f64) ![]Each {
        const e = l.r.e;
        const node = e.node(id);
        const ctx = l.r.context(id);
        const cap = cap0 * l.val(id, .scale) * l.levelScale(id, ctx.script_level);
        var out: std.ArrayList(Each) = .empty;
        var it = (std.unicode.Utf8View.init(node.text) catch return out.items).iterator();
        while (it.nextCodepointSlice()) |ch| {
            if (std.mem.eql(u8, ch, " ")) {
                try out.append(l.a, .{ .laid = .{}, .space = true });
                continue;
            }
            var one = try l.layText(id, ch, cap, node.kind);
            try one.boxes.append(l.a, .{ .object = id, .corners = rect(0, -one.depth, one.width, one.height), .baseline = .{ .{ .x = 0, .y = 0 }, .{ .x = one.width, .y = 0 } }, .nest = l.nest });
            try out.append(l.a, .{ .laid = one });
        }
        return out.items;
    }

    pub const Each = struct { laid: Laid, space: bool = false };

    /// The hyphen a line broken at soft hyphen `id` ends with.
    pub fn hyphen(l: *Layout, id: Id, cap0: f64) !Laid {
        const ctx = l.r.context(id);
        const cap = cap0 * l.val(id, .scale) * l.levelScale(id, ctx.script_level);
        return l.layText(id, "-", cap, .word);
    }

    // Text --------------------------------------------------------------------------

    /// A leaf's characters, each from the face its kind and shape choose,
    /// runs in one face shaped together.
    fn layText(l: *Layout, id: Id, text: []const u8, cap: f64, kind: Kind) !Laid {
        const a = l.a;
        var out: Laid = .{};
        const variant = l.r.e.node(id).variant;
        const shape: param.Shape = if (variant.isItalic()) .italic else param.as(param.Shape, l.get(id, .shape));
        const named = l.get(id, .face).name;
        const fs = try l.r.faces(l.a, id);
        const grow = @max(0, l.val(id, .weight)) * cap / 2;
        const slant = l.val(id, .slant);
        var x: f64 = 0;
        var it = (std.unicode.Utf8View.init(text) catch return out).iterator();
        // Runs: consecutive characters with the same choice.
        var run: std.ArrayList(u8) = .empty;
        // Each run byte's byte in `text`.
        var run_src: std.ArrayList(u32) = .empty;
        var run_face: ?faces_mod.Choice = null;
        while (true) {
            const at: u32 = @intCast(it.i);
            const cp_opt = it.nextCodepoint();
            var choice: ?faces_mod.Choice = if (cp_opt) |cp| faces_mod.chooseBold(fs, named, kind, shape, variant.isBold(), cp) else null;
            if (cp_opt != null and choice == null) {
                try l.missing.append(a, .{ .object = id, .cp = cp_opt.? });
                // Drawn as the first face's .notdef, so it shows.
                if (fs.members.len > 0) choice = .{ .face = fs.members[0].face, .cp = cp_opt.? };
            }
            const same = if (run_face) |rf| (choice != null and rf.face == choice.?.face and rf.slanted == choice.?.slanted) else false;
            if (run.items.len > 0 and (!same or cp_opt == null)) {
                x = try l.setRun(&out, run_face.?, run.items, run_src.items, x, cap, grow, slant, id);
                run.clearRetainingCapacity();
                run_src.clearRetainingCapacity();
            }
            const cp = cp_opt orelse break;
            if (choice) |c| {
                run_face = c;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.cp, &buf) catch continue;
                try run.appendSlice(a, buf[0..n]);
                for (0..n) |_| try run_src.append(a, at);
            } else {
                // No face at all: its room kept, nothing drawn.
                _ = cp;
                x += 0.6 * cap;
            }
        }
        out.width = x;
        if (!out.ink.isEmpty()) {
            out.height = @max(0, out.ink.y1);
            out.depth = @max(0, -out.ink.y0);
        }
        return out;
    }

    fn setRun(l: *Layout, out: *Laid, c: faces_mod.Choice, text: []const u8, src: []const u32, x0: f64, cap: f64, grow: f64, slant_deg: f64, id: Id) !f64 {
        const k = cap / faces_mod.capUnits(c.face);
        const slant = (slant_deg + if (c.slanted) @as(f64, 12) else 0) * std.math.pi / 180;
        const shear: Affine = .{ .c = @tan(slant) };
        const shaped = try c.face.shape(l.a, text);
        var x = x0;
        for (shaped) |g| {
            const m = Affine.scale(k).then(shear).then(Affine.translate(x + @as(f64, @floatFromInt(g.x_offset)) * k, @as(f64, @floatFromInt(g.y_offset)) * k));
            try out.items.append(l.a, .{ .glyph = .{ .face = c.face, .gid = g.gid, .m = m, .grow = grow, .object = id, .cluster = if (g.cluster < src.len) src[g.cluster] else 0 } });
            const b = (try c.face.outline(g.gid)).bounds();
            if (!b.isEmpty()) {
                const ib = boundsOf(corners(rect(b.x0, b.y0, b.x1, b.y1), m));
                out.ink = out.ink.join(.{ .x0 = ib.x0 - grow, .y0 = ib.y0 - grow, .x1 = ib.x1 + grow, .y1 = ib.y1 + grow });
            }
            x += @as(f64, @floatFromInt(g.advance)) * k;
        }
        return x;
    }

    /// One glyph (a structure's own symbol), as text of its kind.
    fn symbol(l: *Layout, id: Id, text: []const u8, cap: f64, kind: Kind) !Laid {
        return l.layText(id, text, cap, kind);
    }

    // Rows --------------------------------------------------------------------------

    fn layRow(l: *Layout, id: Id, cap0: f64, cap: f64) !Laid {
        const e = l.r.e;
        const items = e.node(id).items.items;
        var out: Laid = .{};
        if (items.len == 0) {
            if (l.editing) {
                const w = 0.6 * cap;
                try out.items.append(l.a, .{ .hole = .{ .corners = rect(0, 0, w, cap), .object = id } });
                out.width = w;
                out.height = cap;
            }
            return out;
        }
        const script = l.r.context(id).script_level > 0;
        var prev: ?Class = null;
        var x: f64 = 0;
        for (items) |c| {
            const laid = try l.lay(c, cap0);
            x += l.gapBefore(c, prev, laid.class, script) * cap;
            try out.put(l.a, laid, x, 0);
            x += laid.width;
            out.height = @max(out.height, laid.height);
            out.depth = @max(out.depth, laid.depth);
            prev = laid.class;
        }
        out.width = x;
        return out;
    }

    /// What fitting did to an object.
    pub const Fitted = struct {
        laid: Laid,
        /// The steps taken (0: it fitted as it was, or fitting is off):
        /// 1 limits beside, 2 fractions slashed, 3 scripts tightened,
        /// 4 delimiters natural, 5 scaled down.
        steps: u8 = 0,
        /// The scale it was set at (1 unless step 5).
        scale: f64 = 1,
        /// Still too tall at the floor.
        overflow: bool = false,
    };

    /// The band fitted math stays in, around the baseline, mm: how far up
    /// and down, for text of cap height `cap`.
    pub fn band(l: *const Layout, id: Id, cap: f64) struct { above: f64, below: f64 } {
        const margin = l.val(id, .fit_margin) * cap;
        if (param.as(param.FitBand, l.get(id, .fit_band)) == .font) {
            if (l.r.faces(l.a, id)) |fs| {
                const f: ?*Face = fs.get("text") orelse (if (fs.members.len > 0) fs.members[0].face else null);
                if (f) |face| {
                    const k = cap / faces_mod.capUnits(face);
                    const ext = face.extents();
                    return .{ .above = ext.ascender * k + margin, .below = -ext.descender * k + margin };
                }
            } else |_| {}
        }
        return .{ .above = cap + margin, .below = margin };
    }

    /// Top-level object `id` laid out at cap height `cap0`, fitted to its
    /// line's band when its style says so (`fit`): each step that is
    /// allowed is taken in turn, only while it is still too tall.
    pub fn fitted(l: *Layout, id: Id, cap0: f64) anyerror!Fitted {
        var out: Fitted = .{ .laid = try l.lay(id, cap0) };
        if (param.as(param.Fit, l.get(id, .fit)) == .off) return out;
        const b = l.band(id, cap0);
        const B = @TypeOf(b);
        const fits = struct {
            fn f(x: Laid, bb: B) bool {
                return x.height <= bb.above + 1e-9 and x.depth <= bb.below + 1e-9;
            }
        };
        if (fits.f(out.laid, b)) return out;
        const saved = l.forced;
        defer l.forced = saved;
        // 1: inline style, limits beside, operators at text size.
        if (l.get(id, .fit_limits).flag) {
            l.forced.set(.math_style, param.of(param.MathStyle.text));
            l.forced.set(.limits, param.of(param.Limits.side));
            l.forced.set(.op_size, param.of(param.OpSize.text));
            out = .{ .laid = try l.lay(id, cap0), .steps = 1 };
            if (fits.f(out.laid, b)) return out;
        }
        // 2: fractions slashed.
        if (param.as(param.FitFractions, l.get(id, .fit_fractions)) == .slashed) {
            l.forced.set(.fraction_form, param.of(param.FractionForm.slashed));
            out = .{ .laid = try l.lay(id, cap0), .steps = 2 };
            if (fits.f(out.laid, b)) return out;
        }
        // 3: scripts closer to the baseline, and smaller.
        if (l.get(id, .fit_scripts).flag) {
            l.forced.set(.sup_raise, param.num(@floatCast(0.6 * l.val(id, .sup_raise))));
            l.forced.set(.sub_drop, param.num(@floatCast(0.6 * l.val(id, .sub_drop))));
            l.forced.set(.script_scale, param.num(@floatCast(@max(0.3, 0.85 * l.val(id, .script_scale)))));
            l.forced.set(.scriptscript_scale, param.num(@floatCast(@max(0.3, 0.85 * l.val(id, .scriptscript_scale)))));
            out = .{ .laid = try l.lay(id, cap0), .steps = 3 };
            if (fits.f(out.laid, b)) return out;
        }
        // 4: delimiters at their natural size, radicals closer.
        if (l.get(id, .fit_fences).flag) {
            l.forced.set(.fence_size, param.of(param.FenceSize.natural));
            l.forced.set(.radical_gap, param.num(@floatCast(0.5 * l.val(id, .radical_gap))));
            out = .{ .laid = try l.lay(id, cap0), .steps = 4 };
            if (fits.f(out.laid, b)) return out;
        }
        // 5: scaled down to fit, not below the floor.
        const need = @min(
            if (out.laid.height > b.above) b.above / out.laid.height else 1,
            if (out.laid.depth > b.below) b.below / out.laid.depth else 1,
        );
        const s = @max(l.val(id, .fit_floor), @min(1, need));
        const scaled = try l.lay(id, cap0 * s);
        return .{ .laid = scaled, .steps = 5, .scale = s, .overflow = !fits.f(scaled, b) };
    }

    /// The gap before object `id` (of class `class`) in its row, in cap
    /// heights: the space its kind and its neighbour's (`prev`, none at a
    /// row's start) give, and its own `space_before`.
    pub fn gapBefore(l: *const Layout, id: Id, prev: ?Class, class: Class, script: bool) f64 {
        const s = if (prev) |p| l.space(id, p, class, script) else 0;
        return s + l.val(id, .space_before);
    }

    /// The space between neighbours of classes `left` and `right`, in cap
    /// heights (TeX's table; in scripts, only the thin spaces it keeps).
    pub fn space(l: *const Layout, at: Id, left: Class, right: Class, script: bool) f64 {
        const v = spacing[@intFromEnum(left)][@intFromEnum(right)];
        if (v == 0) return 0;
        if (v < 0 and script) return 0;
        return switch (@abs(v)) {
            1 => l.val(at, .thin_space),
            2 => l.val(at, .medium_space),
            else => l.val(at, .thick_space),
        };
    }

    // Structures --------------------------------------------------------------------

    fn layFraction(l: *Layout, id: Id, cap0: f64, cap: f64) !Laid {
        const e = l.r.e;
        const a = l.a;
        const num = try l.lay(e.slot(id, .num), cap0);
        const den = try l.lay(e.slot(id, .den), cap0);
        var out: Laid = .{};
        switch (param.as(param.FractionForm, l.get(id, .fraction_form))) {
            .stacked => {
                const ax = l.axis(id, cap);
                const t = l.val(id, .rule_thickness) * cap;
                const over = l.val(id, .rule_overhang) * cap;
                const w = @max(num.width, den.width) + 2 * over;
                const nshift = ax + t / 2 + l.val(id, .num_gap) * cap + num.depth;
                const dshift = ax - t / 2 - l.val(id, .den_gap) * cap - den.height;
                try out.put(a, num, (w - num.width) / 2, nshift);
                try out.put(a, den, (w - den.width) / 2, dshift);
                try out.items.append(a, .{ .rule = .{ .corners = rect(0, ax - t / 2, w, ax + t / 2), .object = id } });
                out.ink = out.ink.join(.{ .x0 = 0, .x1 = w, .y0 = ax - t / 2, .y1 = ax + t / 2 });
                out.width = w;
                out.height = nshift + num.height;
                out.depth = @max(0, -(dshift - den.depth));
            },
            .slashed, .diagonal => |form| {
                const diag = form == .diagonal;
                const slash = try l.symbol(id, if (diag) "⁄" else "/", cap, .punct);
                const gap = 0.04 * cap;
                const up: f64 = if (diag) 0.35 * cap else 0;
                var x: f64 = 0;
                try out.put(a, num, x, up);
                x += num.width + gap;
                try out.put(a, slash, x, 0);
                x += slash.width + gap;
                try out.put(a, den, x, 0);
                x += den.width;
                out.width = x;
                out.height = @max(@max(num.height + up, slash.height), den.height);
                out.depth = @max(@max(num.depth - up, slash.depth), den.depth);
            },
        }
        return out;
    }

    fn layScripts(l: *Layout, id: Id, cap0: f64, cap: f64) !Laid {
        const e = l.r.e;
        const a = l.a;
        const base = try l.lay(e.slot(id, .base), cap0);
        var out: Laid = .{};
        try out.put(a, base, 0, 0);
        out.width = base.width;
        out.height = base.height;
        out.depth = base.depth;
        const x = base.width + 0.04 * cap;
        var reach: f64 = 0;
        if (stops.shown(l.r, id, .sup)) {
            const sup = try l.lay(e.slot(id, .sup), cap0);
            const up = l.val(id, .sup_raise) * cap;
            try out.put(a, sup, x, up);
            reach = @max(reach, sup.width);
            out.height = @max(out.height, up + sup.height);
        }
        if (stops.shown(l.r, id, .sub)) {
            const sub = try l.lay(e.slot(id, .sub), cap0);
            const down = l.val(id, .sub_drop) * cap;
            try out.put(a, sub, x, -down);
            reach = @max(reach, sub.width);
            out.depth = @max(out.depth, down + sub.depth);
        }
        if (reach > 0) out.width = x + reach;
        return out;
    }

    fn layLargeOp(l: *Layout, id: Id, cap0: f64, cap: f64, style: cascade.TexStyle) !Laid {
        const e = l.r.e;
        const a = l.a;
        const display = switch (param.as(param.OpSize, l.get(id, .op_size))) {
            .auto => style == .display,
            .display => true,
            .text => false,
        };
        const size = cap * (if (display) l.val(id, .display_op_scale) else 1);
        var op = try l.symbol(id, e.node(id).text, size, .large_op);
        // Centred on the axis.
        if (!op.ink.isEmpty()) {
            const dy = l.axis(id, cap) - (op.ink.y0 + op.ink.y1) / 2;
            op.transform(Affine.translate(0, dy));
            op.height = @max(0, op.ink.y1);
            op.depth = @max(0, -op.ink.y0);
        }
        const stacked = switch (param.as(param.Limits, l.get(id, .limits))) {
            .auto => display,
            .stacked => true,
            .side => false,
        };
        const sup: ?Laid = if (stops.shown(l.r, id, .sup)) try l.lay(e.slot(id, .sup), cap0) else null;
        const sub: ?Laid = if (stops.shown(l.r, id, .sub)) try l.lay(e.slot(id, .sub), cap0) else null;
        var out: Laid = .{};
        if (stacked) {
            var w = op.width;
            if (sup) |s| w = @max(w, s.width);
            if (sub) |s| w = @max(w, s.width);
            const gap = l.val(id, .limit_gap) * cap;
            try out.put(a, op, (w - op.width) / 2, 0);
            out.height = op.height;
            out.depth = op.depth;
            if (sup) |s| {
                const y = op.height + gap + s.depth;
                try out.put(a, s, (w - s.width) / 2, y);
                out.height = y + s.height;
            }
            if (sub) |s| {
                const y = -op.depth - gap - s.height;
                try out.put(a, s, (w - s.width) / 2, y);
                out.depth = -y + s.depth;
            }
            out.width = w;
        } else {
            try out.put(a, op, 0, 0);
            out.height = op.height;
            out.depth = op.depth;
            const x = op.width + 0.04 * cap;
            var reach: f64 = 0;
            if (sup) |s| {
                const y = op.height - 0.5 * cap;
                try out.put(a, s, x, y);
                out.height = @max(out.height, y + s.height);
                reach = s.width;
            }
            if (sub) |s| {
                const y = -op.depth - 0.1 * cap;
                try out.put(a, s, x, y);
                out.depth = @max(out.depth, -y + s.depth);
                reach = @max(reach, s.width);
            }
            out.width = x + reach;
        }
        return out;
    }

    fn layRadical(l: *Layout, id: Id, cap0: f64, cap: f64) !Laid {
        const e = l.r.e;
        const a = l.a;
        const body = try l.lay(e.slot(id, .body), cap0);
        const gap = l.val(id, .radical_gap) * cap;
        const t = l.val(id, .radical_rule) * cap;
        const top = @max(body.height, cap) + gap + t;
        const bottom = -@max(body.depth, 0.1 * cap) - 0.05 * cap;
        // The sign, scaled so its ink spans the body and meets the bar.
        var sign = try l.symbol(id, e.node(id).text, cap, .radical);
        if (!sign.ink.isEmpty()) {
            const k = (top - bottom) / (sign.ink.y1 - sign.ink.y0);
            sign.transform(Affine.translate(-sign.ink.x0, -sign.ink.y0).then(Affine.scale(k)).then(Affine.translate(0, bottom)));
        }
        const sign_w = if (sign.ink.isEmpty()) 0.6 * cap else sign.ink.x1;
        var out: Laid = .{};
        // The index, tucked into the sign's crook.
        var lead: f64 = 0;
        if (stops.shown(l.r, id, .index)) {
            const idx = try l.lay(e.slot(id, .index), cap0);
            const ix = sign_w * 0.55 - idx.width;
            lead = @max(0, -ix);
            try out.put(a, idx, ix + lead, bottom + (top - bottom) * 0.55 + idx.depth);
            out.height = @max(out.height, bottom + (top - bottom) * 0.55 + idx.depth + idx.height);
        }
        try out.put(a, sign, lead, 0);
        const bx = lead + sign_w + 0.08 * cap;
        try out.put(a, body, bx, 0);
        const over = 0.05 * cap;
        const bar_x0 = lead + sign_w - t;
        const bar_x1 = bx + body.width + over;
        try out.items.append(a, .{ .rule = .{ .corners = rect(bar_x0, top - t, bar_x1, top), .object = id } });
        out.ink = out.ink.join(.{ .x0 = bar_x0, .x1 = bar_x1, .y0 = top - t, .y1 = top });
        out.width = bar_x1;
        out.height = @max(out.height, top);
        out.depth = -bottom;
        return out;
    }

    fn layFence(l: *Layout, id: Id, cap0: f64, cap: f64) !Laid {
        const e = l.r.e;
        const a = l.a;
        const node = e.node(id);
        const body = try l.lay(e.slot(id, .body), cap0);
        const ax = l.axis(id, cap);
        const half = @max(body.height - ax, ax + body.depth) + 0.1 * cap;
        const gap = l.val(id, .fence_gap) * cap;
        const mode = param.as(param.FenceSize, l.get(id, .fence_size));
        var out: Laid = .{};
        var x: f64 = 0;
        for ([_][]const u8{ node.text, node.close }, 0..) |d, k| {
            if (k == 1) {
                x += gap;
                try out.put(a, body, x, 0);
                x += body.width + gap;
            }
            if (d.len == 0) continue;
            var g = try l.symbol(id, d, cap, .fence);
            if (!g.ink.isEmpty()) {
                const natural = g.ink.y1 - g.ink.y0;
                const sy: f64 = switch (mode) {
                    .natural => 1,
                    .grown => @max(1, 2 * half / natural),
                    .step => 1 + 0.25 * l.val(id, .fence_step),
                };
                // Grown vertically about the axis.
                const mid = (g.ink.y0 + g.ink.y1) / 2;
                g.transform(Affine.translate(0, -mid).then(.{ .d = sy }).then(Affine.translate(0, ax)));
            }
            try out.put(a, g, x, 0);
            x += g.width;
            out.height = @max(out.height, @max(0, g.ink.y1));
            out.depth = @max(out.depth, @max(0, -g.ink.y0));
        }
        out.width = x;
        out.height = @max(out.height, body.height);
        out.depth = @max(out.depth, body.depth);
        return out;
    }

    fn layAccent(l: *Layout, id: Id, cap0: f64, cap: f64) !Laid {
        const e = l.r.e;
        const a = l.a;
        const base = try l.lay(e.slot(id, .body), cap0);
        var mark = try l.symbol(id, e.node(id).text, cap, .accent);
        var out: Laid = .{};
        try out.put(a, base, 0, 0);
        out.width = base.width;
        out.height = base.height;
        out.depth = base.depth;
        if (!mark.ink.isEmpty()) {
            const centre = if (base.ink.isEmpty()) base.width / 2 else (base.ink.x0 + base.ink.x1) / 2;
            const y = base.height + 0.08 * cap + l.val(id, .accent_raise) * cap;
            mark.transform(Affine.translate(centre - (mark.ink.x0 + mark.ink.x1) / 2, y - mark.ink.y0));
            try out.put(a, mark, 0, 0);
            out.height = @max(out.height, mark.ink.y1);
        }
        return out;
    }
};

fn classOf(e: *const ex.Expr, id: Id) Class {
    const n = e.node(id);
    return switch (n.kind) {
        .operator => if (n.role == .binary) .bin else .ord,
        .relation => .rel,
        .punct => .punct,
        .large_op => .op,
        .fence, .fraction => .inner,
        .scripts => blk: {
            const base = e.node(e.slot(id, .base)).items.items;
            break :blk if (base.len > 0) classOf(e, base[0]) else .ord;
        },
        else => .ord,
    };
}

/// TeX's spacing between classes (rows: the left one, in Class order):
/// 1 thin, 2 medium, 3 thick; negative where scripts set none.
const spacing = [8][8]i8{
    //  ord op  bin rel open close punct inner
    .{ 0, 1, -2, -3, 0, 0, 0, -1 }, // ord
    .{ 1, 1, 0, -3, 0, 0, 0, -1 }, // op
    .{ -2, -2, 0, 0, -2, 0, 0, -2 }, // bin
    .{ -3, -3, 0, 0, -3, 0, 0, -3 }, // rel
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // open
    .{ 0, 1, -2, -3, 0, 0, 0, -1 }, // close
    .{ -1, -1, 0, -1, -1, -1, -1, -1 }, // punct
    .{ -1, 1, -2, -3, -1, 0, -1, -1 }, // inner
};
