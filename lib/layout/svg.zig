//! SVG import: a drawing's geometry, fill and stroke as a figure's paths
//! (`figure.zig`), mm, y up, its origin the drawing's bottom left.
//!
//! Read: `path` (every command, arcs as exact conics), `rect` (rounded
//! corners too), `circle`, `ellipse`, `line`, `polyline`, `polygon`, in
//! `g` and nested `svg` groups; `transform` (matrix, translate, scale,
//! rotate, skewX, skewY); paint from presentation attributes or `style`,
//! inherited: `fill`, `fill-rule`, `stroke`, `stroke-width`,
//! `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit`, `opacity`,
//! `fill-opacity`, `stroke-opacity`, `color` (for `currentColor`),
//! `display`, `visibility`. The drawing's size comes from the root's
//! `width` and `height` in their units (mm, cm, in, pt, pc, px at 96 per
//! inch) mapped onto its `viewBox`, or user units as px.
//!
//! Not read yet, and counted in the report: text, `use`, images, gradients
//! and patterns (painted black), clipping and masks, markers, dashes.

const std = @import("std");
const geom = @import("graven_geom");
const art = @import("art.zig");
const figure = @import("figure.zig");

const Allocator = std.mem.Allocator;
const Point = geom.Point;
const Affine = geom.Affine;
const Segment = geom.Segment;

pub const Error = Allocator.Error || error{NotSvg};

/// What an import could not carry over.
pub const Report = struct {
    shapes: usize = 0,
    text: usize = 0,
    uses: usize = 0,
    images: usize = 0,
    gradients: usize = 0,
    clips: usize = 0,
    dashes: usize = 0,
    other: usize = 0,

    pub fn skipped(r: Report) usize {
        return r.text + r.uses + r.images + r.clips + r.other;
    }
};

pub const Result = struct {
    paths: []const figure.Path,
    /// The drawing's size, mm (its viewport), when the file gives one.
    width: f64,
    height: f64,
    report: Report,
};

const px_mm = 25.4 / 96.0;

const Paint = union(enum) { none, color: art.Color, current, unsupported };

/// The inherited style.
const Style = struct {
    fill: Paint = .{ .color = .{ .r = 0, .g = 0, .b = 0 } },
    fill_rule: figure.FillRule = .nonzero,
    fill_opacity: f64 = 1,
    stroke: Paint = .none,
    stroke_width: f64 = 1,
    stroke_opacity: f64 = 1,
    cap: geom.stroke.Cap = .butt,
    join: geom.stroke.Join = .miter,
    miter_limit: f64 = 4,
    color: art.Color = .{ .r = 0, .g = 0, .b = 0 },
    visible: bool = true,
    dashed: bool = false,
};

const Frame = struct {
    name: []const u8,
    m: Affine,
    style: Style,
    /// Inside something not drawn (defs, clipPath, text …).
    hidden: bool,
};

/// Reads SVG document `src` into figure paths, allocated from `a` (an
/// arena suits).
pub fn parse(a: Allocator, src: []const u8) Error!Result {
    var paths: std.ArrayList(figure.Path) = .empty;
    var report: Report = .{};
    var stack: std.ArrayList(Frame) = .empty;
    var width: f64 = 0;
    var height: f64 = 0;
    var seen_root = false;
    // The root's map from user units to mm, y down still; the flip to y up
    // comes last, about the height.
    var it: Scanner = .{ .s = src };
    while (it.next()) |tag| {
        if (tag.end) {
            if (stack.items.len > 0 and std.mem.eql(u8, stack.items[stack.items.len - 1].name, tag.name)) _ = stack.pop();
            continue;
        }
        const parent: Frame = if (stack.items.len > 0) stack.items[stack.items.len - 1] else .{ .name = "", .m = .identity, .style = .{}, .hidden = false };
        var fr: Frame = .{ .name = tag.name, .m = parent.m, .style = parent.style, .hidden = parent.hidden };
        const name = localName(tag.name);
        if (!seen_root) {
            if (!std.mem.eql(u8, name, "svg")) return error.NotSvg;
            seen_root = true;
            const vb = viewBox(tag.attr("viewBox"));
            const w_attr = tag.attr("width");
            const h_attr = tag.attr("height");
            const wl = if (w_attr) |w| length(w) else null;
            const hl = if (h_attr) |h| length(h) else null;
            var sx: f64 = px_mm;
            var sy: f64 = px_mm;
            var tx: f64 = 0;
            var ty: f64 = 0;
            if (vb) |v| {
                width = if (wl) |w| w else v[2] * px_mm;
                height = if (hl) |h| h else v[3] * px_mm;
                if (wl == null and hl != null and v[3] > 0) width = v[2] * height / v[3];
                if (hl == null and wl != null and v[2] > 0) height = v[3] * width / v[2];
                if (v[2] > 0 and v[3] > 0) {
                    // preserveAspectRatio's default: uniform, centred.
                    const s = @min(width / v[2], height / v[3]);
                    sx = s;
                    sy = s;
                    tx = (width - v[2] * s) / 2 - v[0] * s;
                    ty = (height - v[3] * s) / 2 - v[1] * s;
                }
            } else {
                width = wl orelse 0;
                height = hl orelse 0;
            }
            fr.m = .{ .a = sx, .d = sy, .e = tx, .f = ty };
        }
        if (tag.attr("transform")) |t| fr.m = transform(t).then(fr.m);
        applyStyle(&fr.style, tag);
        const skipping = std.mem.eql(u8, name, "defs") or std.mem.eql(u8, name, "clipPath") or std.mem.eql(u8, name, "mask") or
            std.mem.eql(u8, name, "symbol") or std.mem.eql(u8, name, "marker") or std.mem.eql(u8, name, "pattern") or
            std.mem.eql(u8, name, "metadata") or std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "desc") or
            std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "linearGradient") or std.mem.eql(u8, name, "radialGradient") or
            std.mem.eql(u8, name, "foreignObject") or std.mem.eql(u8, name, "script");
        if (skipping) fr.hidden = true;
        if (!fr.hidden and fr.style.visible) {
            if (std.mem.eql(u8, name, "text")) {
                report.text += 1;
                fr.hidden = true;
            } else if (std.mem.eql(u8, name, "use")) {
                report.uses += 1;
            } else if (std.mem.eql(u8, name, "image")) {
                report.images += 1;
            } else if (tag.attr("clip-path") != null or tag.attr("mask") != null) {
                report.clips += 1;
            }
            const subs = try shape(a, name, tag, fr.m);
            if (subs) |sp| if (sp.len > 0) {
                report.shapes += 1;
                const st = fr.style;
                if (st.dashed) report.dashes += 1;
                const fill_c = paintColor(st.fill, st.color, st.fill_opacity, &report);
                const stroke_c = paintColor(st.stroke, st.color, st.stroke_opacity, &report);
                // A pen's width scales with the drawing (by the transform's
                // mean scale where it is not uniform).
                const det = @abs(fr.m.a * fr.m.d - fr.m.b * fr.m.c);
                const sw = st.stroke_width * @sqrt(det);
                try paths.append(a, .{
                    .subpaths = sp,
                    .fill = fill_c,
                    .fill_rule = st.fill_rule,
                    .stroke = if (stroke_c != null and sw > 0) .{ .color = stroke_c.?, .width = sw, .cap = st.cap, .join = st.join, .miter_limit = st.miter_limit } else null,
                });
            };
        }
        if (!tag.self_closing) try stack.append(a, fr);
    }
    if (!seen_root) return error.NotSvg;
    // y up: flipped about the drawing's height (or its paths' extent when
    // the file gives none), its bottom left the origin.
    var flip_h = height;
    if (!(flip_h > 0)) {
        var b: geom.Box = .empty;
        for (paths.items) |p| for (p.subpaths) |sp| for (sp.segments) |s| {
            b = b.join(s.bounds());
        };
        flip_h = if (b.isEmpty()) 0 else b.y1;
        if (!(width > 0) and !b.isEmpty()) width = b.x1;
        if (!b.isEmpty()) height = b.y1;
    }
    const flip: Affine = .{ .d = -1, .f = flip_h };
    for (paths.items) |*p| {
        const subs = try a.alloc(figure.Subpath, p.subpaths.len);
        for (p.subpaths, subs) |sp, *o| {
            const segs = try a.alloc(Segment, sp.segments.len);
            for (sp.segments, segs) |s, *t| t.* = s.transformed(flip);
            o.* = .{ .segments = segs, .closed = sp.closed };
        }
        p.subpaths = subs;
    }
    return .{ .paths = paths.items, .width = width, .height = height, .report = report };
}

fn localName(n: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, n, ':')) |i| n[i + 1 ..] else n;
}

fn paintColor(p: Paint, current: art.Color, opacity: f64, report: *Report) ?art.Color {
    var c: art.Color = switch (p) {
        .none => return null,
        .color => |c| c,
        .current => current,
        .unsupported => blk: {
            report.gradients += 1;
            break :blk .{ .r = 0, .g = 0, .b = 0 };
        },
    };
    c.a = @intFromFloat(@round(@as(f64, @floatFromInt(c.a)) * std.math.clamp(opacity, 0, 1)));
    return c;
}

// ---------------------------------------------------------------- style

fn applyStyle(st: *Style, tag: Tag) void {
    // Presentation attributes first, then `style` over them.
    const props = [_][]const u8{ "color", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "display", "visibility", "stroke-dasharray" };
    for (props) |p| if (tag.attr(p)) |v| setProp(st, p, v);
    if (tag.attr("style")) |css| {
        var decls = std.mem.splitScalar(u8, css, ';');
        while (decls.next()) |d| {
            const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            const k = std.mem.trim(u8, d[0..colon], " \t\r\n");
            const v = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n");
            setProp(st, k, v);
        }
    }
}

fn setProp(st: *Style, k: []const u8, v0: []const u8) void {
    const v = std.mem.trim(u8, std.mem.trimEnd(u8, v0, "!important"), " \t\r\n");
    if (std.mem.eql(u8, v, "inherit")) return;
    const eq = std.mem.eql;
    if (eq(u8, k, "fill")) {
        st.fill = paint(v) orelse st.fill;
    } else if (eq(u8, k, "stroke")) {
        st.stroke = paint(v) orelse st.stroke;
    } else if (eq(u8, k, "color")) {
        if (paint(v)) |p| if (p == .color) {
            st.color = p.color;
        };
    } else if (eq(u8, k, "fill-rule")) {
        st.fill_rule = if (eq(u8, v, "evenodd")) .evenodd else .nonzero;
    } else if (eq(u8, k, "fill-opacity")) {
        st.fill_opacity = number(v) orelse st.fill_opacity;
    } else if (eq(u8, k, "stroke-opacity")) {
        st.stroke_opacity = number(v) orelse st.stroke_opacity;
    } else if (eq(u8, k, "opacity")) {
        // Group opacity is not composited; it scales what is beneath.
        if (number(v)) |o| {
            st.fill_opacity *= o;
            st.stroke_opacity *= o;
        }
    } else if (eq(u8, k, "stroke-width")) {
        st.stroke_width = userLength(v) orelse st.stroke_width;
    } else if (eq(u8, k, "stroke-linecap")) {
        st.cap = if (eq(u8, v, "round")) .round else if (eq(u8, v, "square")) .square else .butt;
    } else if (eq(u8, k, "stroke-linejoin")) {
        st.join = if (eq(u8, v, "round")) .round else if (eq(u8, v, "bevel")) .bevel else .miter;
    } else if (eq(u8, k, "stroke-miterlimit")) {
        st.miter_limit = number(v) orelse st.miter_limit;
    } else if (eq(u8, k, "display")) {
        if (eq(u8, v, "none")) st.visible = false;
    } else if (eq(u8, k, "visibility")) {
        st.visible = !(eq(u8, v, "hidden") or eq(u8, v, "collapse"));
    } else if (eq(u8, k, "stroke-dasharray")) {
        st.dashed = !(eq(u8, v, "none") or eq(u8, v, "0"));
    }
}

fn paint(v: []const u8) ?Paint {
    if (v.len == 0) return null;
    if (std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "transparent")) return .none;
    if (std.mem.eql(u8, v, "currentColor")) return .current;
    if (std.mem.startsWith(u8, v, "url(")) return .unsupported;
    if (colour(v)) |c| return .{ .color = c };
    return null;
}

const named = [_]struct { []const u8, [3]u8 }{
    .{ "black", .{ 0, 0, 0 } },       .{ "white", .{ 255, 255, 255 } },  .{ "red", .{ 255, 0, 0 } },
    .{ "green", .{ 0, 128, 0 } },     .{ "blue", .{ 0, 0, 255 } },       .{ "yellow", .{ 255, 255, 0 } },
    .{ "cyan", .{ 0, 255, 255 } },    .{ "magenta", .{ 255, 0, 255 } },  .{ "gray", .{ 128, 128, 128 } },
    .{ "grey", .{ 128, 128, 128 } },  .{ "silver", .{ 192, 192, 192 } }, .{ "maroon", .{ 128, 0, 0 } },
    .{ "olive", .{ 128, 128, 0 } },   .{ "lime", .{ 0, 255, 0 } },       .{ "aqua", .{ 0, 255, 255 } },
    .{ "teal", .{ 0, 128, 128 } },    .{ "navy", .{ 0, 0, 128 } },       .{ "fuchsia", .{ 255, 0, 255 } },
    .{ "purple", .{ 128, 0, 128 } },  .{ "orange", .{ 255, 165, 0 } },   .{ "brown", .{ 165, 42, 42 } },
    .{ "pink", .{ 255, 192, 203 } },  .{ "gold", .{ 255, 215, 0 } },     .{ "darkgray", .{ 169, 169, 169 } },
    .{ "darkgrey", .{ 169, 169, 169 } }, .{ "lightgray", .{ 211, 211, 211 } }, .{ "lightgrey", .{ 211, 211, 211 } },
};

fn colour(v: []const u8) ?art.Color {
    if (v[0] == '#') {
        const h = v[1..];
        if (h.len == 3) {
            var c: [3]u8 = undefined;
            for (0..3) |i| c[i] = (std.fmt.charToDigit(h[i], 16) catch return null) * 17;
            return .{ .r = c[0], .g = c[1], .b = c[2] };
        }
        if (h.len >= 6) return art.Color.parse(v[0..7]);
        return null;
    }
    if (std.mem.startsWith(u8, v, "rgb")) {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return null;
        const close = std.mem.indexOfScalar(u8, v, ')') orelse return null;
        var parts = std.mem.tokenizeAny(u8, v[open + 1 .. close], ", \t/");
        var c: [4]f64 = .{ 0, 0, 0, 1 };
        var i: usize = 0;
        while (parts.next()) |p| : (i += 1) {
            if (i >= 4) break;
            const pct = std.mem.endsWith(u8, p, "%");
            const x = std.fmt.parseFloat(f64, if (pct) p[0 .. p.len - 1] else p) catch return null;
            c[i] = if (i == 3) (if (pct) x / 100 else x) else if (pct) x * 2.55 else x;
        }
        return .{ .r = clampByte(c[0]), .g = clampByte(c[1]), .b = clampByte(c[2]), .a = clampByte(c[3] * 255) };
    }
    var lower: [24]u8 = undefined;
    if (v.len > lower.len) return null;
    const l = std.ascii.lowerString(&lower, v);
    for (named) |n| if (std.mem.eql(u8, n[0], l)) return .{ .r = n[1][0], .g = n[1][1], .b = n[1][2] };
    return null;
}

fn clampByte(x: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 255)));
}

// ---------------------------------------------------------------- numbers

fn number(v: []const u8) ?f64 {
    var p: NumParser = .{ .s = v };
    return p.num();
}

/// A length in mm (for the root's width and height); px at 96 per inch.
fn length(v: []const u8) ?f64 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    var p: NumParser = .{ .s = t };
    const x = p.num() orelse return null;
    const unit = std.mem.trim(u8, t[p.i..], " ");
    if (unit.len == 0 or std.mem.eql(u8, unit, "px")) return x * px_mm;
    if (std.mem.eql(u8, unit, "mm")) return x;
    if (std.mem.eql(u8, unit, "cm")) return x * 10;
    if (std.mem.eql(u8, unit, "in")) return x * 25.4;
    if (std.mem.eql(u8, unit, "pt")) return x * 25.4 / 72;
    if (std.mem.eql(u8, unit, "pc")) return x * 25.4 / 6;
    return null; // %, em …: unknown here
}

/// A length in user units (px), for attributes within the drawing.
fn userLength(v: []const u8) ?f64 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    var p: NumParser = .{ .s = t };
    const x = p.num() orelse return null;
    const unit = std.mem.trim(u8, t[p.i..], " ");
    if (unit.len == 0 or std.mem.eql(u8, unit, "px")) return x;
    if (length(t)) |mm| return mm / px_mm;
    return x;
}

fn viewBox(v: ?[]const u8) ?[4]f64 {
    const s = v orelse return null;
    var p: NumParser = .{ .s = s };
    var out: [4]f64 = undefined;
    for (&out) |*o| o.* = p.num() orelse return null;
    return out;
}

const NumParser = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(p: *NumParser) void {
        while (p.i < p.s.len and (std.ascii.isWhitespace(p.s[p.i]) or p.s[p.i] == ',')) p.i += 1;
    }

    fn num(p: *NumParser) ?f64 {
        p.skip();
        const start = p.i;
        if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
        var digits = false;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) digits = true;
        if (p.i < p.s.len and p.s[p.i] == '.') {
            p.i += 1;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) digits = true;
        }
        if (!digits) {
            p.i = start;
            return null;
        }
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            const save = p.i;
            p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
            var exp = false;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) exp = true;
            if (!exp) p.i = save;
        }
        return std.fmt.parseFloat(f64, p.s[start..p.i]) catch null;
    }

    /// An arc's flag: a single 0 or 1, with or without separators.
    fn flag(p: *NumParser) ?bool {
        p.skip();
        if (p.i >= p.s.len) return null;
        const c = p.s[p.i];
        if (c != '0' and c != '1') return null;
        p.i += 1;
        return c == '1';
    }
};

// ---------------------------------------------------------------- transforms

fn transform(v: []const u8) Affine {
    var m: Affine = .identity;
    var i: usize = 0;
    while (i < v.len) {
        while (i < v.len and (std.ascii.isWhitespace(v[i]) or v[i] == ',')) i += 1;
        const name_start = i;
        while (i < v.len and std.ascii.isAlphabetic(v[i])) i += 1;
        const name = v[name_start..i];
        if (name.len == 0) break;
        const open = std.mem.indexOfScalarPos(u8, v, i, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, v, open, ')') orelse break;
        var p: NumParser = .{ .s = v[open + 1 .. close] };
        var args: [6]f64 = undefined;
        var n: usize = 0;
        while (n < 6) : (n += 1) args[n] = p.num() orelse break;
        i = close + 1;
        const t: Affine = if (std.mem.eql(u8, name, "matrix") and n == 6)
            .{ .a = args[0], .b = args[1], .c = args[2], .d = args[3], .e = args[4], .f = args[5] }
        else if (std.mem.eql(u8, name, "translate") and n >= 1)
            .{ .e = args[0], .f = if (n >= 2) args[1] else 0 }
        else if (std.mem.eql(u8, name, "scale") and n >= 1)
            .{ .a = args[0], .d = if (n >= 2) args[1] else args[0] }
        else if (std.mem.eql(u8, name, "rotate") and n >= 1) blk: {
            const r = args[0] * std.math.pi / 180;
            const rot: Affine = .{ .a = @cos(r), .b = @sin(r), .c = -@sin(r), .d = @cos(r) };
            if (n >= 3) break :blk Affine.translate(-args[1], -args[2]).then(rot).then(Affine.translate(args[1], args[2]));
            break :blk rot;
        } else if (std.mem.eql(u8, name, "skewX") and n >= 1)
            .{ .c = @tan(args[0] * std.math.pi / 180) }
        else if (std.mem.eql(u8, name, "skewY") and n >= 1)
            .{ .b = @tan(args[0] * std.math.pi / 180) }
        else
            .identity;
        // The list applies right to left: the later functions first.
        m = t.then(m);
    }
    return m;
}

// ---------------------------------------------------------------- shapes

/// An element's subpaths in user units mapped by `m`; null for an element
/// that is not a shape.
fn shape(a: Allocator, name: []const u8, tag: Tag, m: Affine) Allocator.Error!?[]const figure.Subpath {
    var b: Builder = .{ .a = a, .m = m };
    const eq = std.mem.eql;
    const f = struct {
        fn get(t: Tag, k: []const u8) f64 {
            return if (t.attr(k)) |v| userLength(v) orelse 0 else 0;
        }
    }.get;
    if (eq(u8, name, "path")) {
        try b.pathData(tag.attr("d") orelse "");
    } else if (eq(u8, name, "rect")) {
        const x = f(tag, "x");
        const y = f(tag, "y");
        const w = f(tag, "width");
        const h = f(tag, "height");
        if (!(w > 0 and h > 0)) return &.{};
        var rx = f(tag, "rx");
        var ry = f(tag, "ry");
        if (tag.attr("rx") == null) rx = ry;
        if (tag.attr("ry") == null) ry = rx;
        rx = @min(rx, w / 2);
        ry = @min(ry, h / 2);
        if (rx > 0 and ry > 0) {
            try b.moveTo(.{ .x = x + rx, .y = y });
            try b.lineTo(.{ .x = x + w - rx, .y = y });
            try b.arcTo(rx, ry, 0, false, true, .{ .x = x + w, .y = y + ry });
            try b.lineTo(.{ .x = x + w, .y = y + h - ry });
            try b.arcTo(rx, ry, 0, false, true, .{ .x = x + w - rx, .y = y + h });
            try b.lineTo(.{ .x = x + rx, .y = y + h });
            try b.arcTo(rx, ry, 0, false, true, .{ .x = x, .y = y + h - ry });
            try b.lineTo(.{ .x = x, .y = y + ry });
            try b.arcTo(rx, ry, 0, false, true, .{ .x = x + rx, .y = y });
        } else {
            try b.moveTo(.{ .x = x, .y = y });
            try b.lineTo(.{ .x = x + w, .y = y });
            try b.lineTo(.{ .x = x + w, .y = y + h });
            try b.lineTo(.{ .x = x, .y = y + h });
        }
        try b.close();
    } else if (eq(u8, name, "circle") or eq(u8, name, "ellipse")) {
        const cx = f(tag, "cx");
        const cy = f(tag, "cy");
        var rx = if (eq(u8, name, "circle")) f(tag, "r") else f(tag, "rx");
        var ry = if (eq(u8, name, "circle")) rx else f(tag, "ry");
        if (eq(u8, name, "ellipse")) {
            if (tag.attr("rx") == null) rx = ry;
            if (tag.attr("ry") == null) ry = rx;
        }
        if (!(rx > 0 and ry > 0)) return &.{};
        try b.moveTo(.{ .x = cx + rx, .y = cy });
        try b.arcTo(rx, ry, 0, false, true, .{ .x = cx, .y = cy + ry });
        try b.arcTo(rx, ry, 0, false, true, .{ .x = cx - rx, .y = cy });
        try b.arcTo(rx, ry, 0, false, true, .{ .x = cx, .y = cy - ry });
        try b.arcTo(rx, ry, 0, false, true, .{ .x = cx + rx, .y = cy });
        try b.close();
    } else if (eq(u8, name, "line")) {
        try b.moveTo(.{ .x = f(tag, "x1"), .y = f(tag, "y1") });
        try b.lineTo(.{ .x = f(tag, "x2"), .y = f(tag, "y2") });
    } else if (eq(u8, name, "polyline") or eq(u8, name, "polygon")) {
        var p: NumParser = .{ .s = tag.attr("points") orelse "" };
        var first = true;
        while (true) {
            const x = p.num() orelse break;
            const y = p.num() orelse break;
            if (first) try b.moveTo(.{ .x = x, .y = y }) else try b.lineTo(.{ .x = x, .y = y });
            first = false;
        }
        if (eq(u8, name, "polygon")) try b.close();
    } else return null;
    try b.finish();
    return b.subs.items;
}

/// Subpaths built in user units, each point mapped by `m` as it is added.
const Builder = struct {
    a: Allocator,
    m: Affine,
    subs: std.ArrayList(figure.Subpath) = .empty,
    segs: std.ArrayList(Segment) = .empty,
    /// The pen and the subpath's start, user units.
    at: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    open: bool = false,

    fn map(b: *Builder, p: Point) Point {
        return b.m.apply(p);
    }

    fn finish(b: *Builder) Allocator.Error!void {
        if (b.segs.items.len > 0) try b.subs.append(b.a, .{ .segments = try b.segs.toOwnedSlice(b.a), .closed = false });
        b.segs = .empty;
        b.open = false;
    }

    fn moveTo(b: *Builder, p: Point) Allocator.Error!void {
        try b.finish();
        b.at = p;
        b.start = p;
        b.open = true;
    }

    fn lineTo(b: *Builder, p: Point) Allocator.Error!void {
        if (!b.open) try b.moveTo(b.at);
        if (!(p.x == b.at.x and p.y == b.at.y)) try b.segs.append(b.a, .{ .line = .{ b.map(b.at), b.map(p) } });
        b.at = p;
    }

    fn quadTo(b: *Builder, c: Point, p: Point) Allocator.Error!void {
        if (!b.open) try b.moveTo(b.at);
        try b.segs.append(b.a, .{ .quad = .{ b.map(b.at), b.map(c), b.map(p) } });
        b.at = p;
    }

    fn cubicTo(b: *Builder, c1: Point, c2: Point, p: Point) Allocator.Error!void {
        if (!b.open) try b.moveTo(b.at);
        try b.segs.append(b.a, .{ .cubic = .{ b.map(b.at), b.map(c1), b.map(c2), b.map(p) } });
        b.at = p;
    }

    fn close(b: *Builder) Allocator.Error!void {
        if (!b.open) return;
        if (!(b.at.x == b.start.x and b.at.y == b.start.y)) try b.segs.append(b.a, .{ .line = .{ b.map(b.at), b.map(b.start) } });
        if (b.segs.items.len > 0) try b.subs.append(b.a, .{ .segments = try b.segs.toOwnedSlice(b.a), .closed = true });
        b.segs = .empty;
        b.at = b.start;
        b.open = false;
    }

    /// An elliptical arc to `p` (SVG's endpoint form), as conics of at most
    /// a quarter turn each: exact, and exact under any affine map.
    fn arcTo(b: *Builder, rx0: f64, ry0: f64, phi_deg: f64, large: bool, sweep: bool, p: Point) Allocator.Error!void {
        const p0 = b.at;
        if (p0.x == p.x and p0.y == p.y) return;
        var rx = @abs(rx0);
        var ry = @abs(ry0);
        if (rx == 0 or ry == 0) return b.lineTo(p);
        const phi = phi_deg * std.math.pi / 180;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx = (p0.x - p.x) / 2;
        const dy = (p0.y - p.y) / 2;
        const x1 = cp * dx + sp * dy;
        const y1 = -sp * dx + cp * dy;
        // Radii too small for the chord grow until it fits.
        const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lam > 1) {
            rx *= @sqrt(lam);
            ry *= @sqrt(lam);
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var co = @sqrt(@max(0, num / den));
        if (large == sweep) co = -co;
        const cx1 = co * rx * y1 / ry;
        const cy1 = -co * ry * x1 / rx;
        const cx = cp * cx1 - sp * cy1 + (p0.x + p.x) / 2;
        const cy = sp * cx1 + cp * cy1 + (p0.y + p.y) / 2;
        const ang = struct {
            fn f(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
                return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
            }
        }.f;
        const t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry);
        var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry);
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(dt) / (std.math.pi / 2.0) - 1e-9))));
        const step = dt / @as(f64, @floatFromInt(n));
        // The unit circle mapped onto the ellipse.
        const e: Affine = .{ .a = rx * cp, .b = rx * sp, .c = -ry * sp, .d = ry * cp, .e = cx, .f = cy };
        if (!b.open) try b.moveTo(b.at);
        for (0..n) |k| {
            const a0 = t1 + step * @as(f64, @floatFromInt(k));
            const a1 = a0 + step;
            const mid = (a0 + a1) / 2;
            const w = @cos(step / 2);
            const q0 = if (k == 0) p0 else e.apply(.{ .x = @cos(a0), .y = @sin(a0) });
            const q2 = if (k == n - 1) p else e.apply(.{ .x = @cos(a1), .y = @sin(a1) });
            const q1 = e.apply(.{ .x = @cos(mid) / w, .y = @sin(mid) / w });
            try b.segs.append(b.a, .{ .conic = .{ .p = .{ b.map(q0), b.map(q1), b.map(q2) }, .w = w } });
        }
        b.at = p;
    }

    fn pathData(b: *Builder, d: []const u8) Allocator.Error!void {
        var p: NumParser = .{ .s = d };
        var cmd: u8 = 0;
        var last_ctrl: ?Point = null; // the last curve's second control point
        var last_kind: u8 = 0;
        while (true) {
            p.skip();
            if (p.i >= p.s.len) break;
            const c = p.s[p.i];
            if (std.ascii.isAlphabetic(c)) {
                cmd = c;
                p.i += 1;
            } else if (cmd == 0) break;
            const rel = std.ascii.isLower(cmd);
            const o: Point = if (rel) b.at else .{ .x = 0, .y = 0 };
            const up = std.ascii.toUpper(cmd);
            switch (up) {
                'Z' => {
                    try b.close();
                    last_ctrl = null;
                    last_kind = 'Z';
                    // A Z takes no numbers: the next must be a command.
                    p.skip();
                    if (p.i < p.s.len and !std.ascii.isAlphabetic(p.s[p.i])) break;
                    continue;
                },
                'M' => {
                    const x = p.num() orelse break;
                    const y = p.num() orelse break;
                    try b.moveTo(.{ .x = o.x + x, .y = o.y + y });
                    // Pairs after a moveto are linetos.
                    cmd = if (rel) 'l' else 'L';
                    last_kind = 'M';
                },
                'L' => {
                    const x = p.num() orelse break;
                    const y = p.num() orelse break;
                    try b.lineTo(.{ .x = o.x + x, .y = o.y + y });
                    last_kind = 'L';
                },
                'H' => {
                    const x = p.num() orelse break;
                    try b.lineTo(.{ .x = (if (rel) b.at.x else 0) + x, .y = b.at.y });
                    last_kind = 'L';
                },
                'V' => {
                    const y = p.num() orelse break;
                    try b.lineTo(.{ .x = b.at.x, .y = (if (rel) b.at.y else 0) + y });
                    last_kind = 'L';
                },
                'C' => {
                    var v: [6]f64 = undefined;
                    for (&v) |*x| x.* = p.num() orelse return b.finish();
                    const c1: Point = .{ .x = o.x + v[0], .y = o.y + v[1] };
                    const c2: Point = .{ .x = o.x + v[2], .y = o.y + v[3] };
                    try b.cubicTo(c1, c2, .{ .x = o.x + v[4], .y = o.y + v[5] });
                    last_ctrl = c2;
                    last_kind = 'C';
                    continue;
                },
                'S' => {
                    var v: [4]f64 = undefined;
                    for (&v) |*x| x.* = p.num() orelse return b.finish();
                    const c1: Point = if (last_kind == 'C' and last_ctrl != null) .{ .x = 2 * b.at.x - last_ctrl.?.x, .y = 2 * b.at.y - last_ctrl.?.y } else b.at;
                    const c2: Point = .{ .x = o.x + v[0], .y = o.y + v[1] };
                    try b.cubicTo(c1, c2, .{ .x = o.x + v[2], .y = o.y + v[3] });
                    last_ctrl = c2;
                    last_kind = 'C';
                    continue;
                },
                'Q' => {
                    var v: [4]f64 = undefined;
                    for (&v) |*x| x.* = p.num() orelse return b.finish();
                    const c1: Point = .{ .x = o.x + v[0], .y = o.y + v[1] };
                    try b.quadTo(c1, .{ .x = o.x + v[2], .y = o.y + v[3] });
                    last_ctrl = c1;
                    last_kind = 'Q';
                    continue;
                },
                'T' => {
                    var v: [2]f64 = undefined;
                    for (&v) |*x| x.* = p.num() orelse return b.finish();
                    const c1: Point = if (last_kind == 'Q' and last_ctrl != null) .{ .x = 2 * b.at.x - last_ctrl.?.x, .y = 2 * b.at.y - last_ctrl.?.y } else b.at;
                    try b.quadTo(c1, .{ .x = o.x + v[0], .y = o.y + v[1] });
                    last_ctrl = c1;
                    last_kind = 'Q';
                    continue;
                },
                'A' => {
                    const rx = p.num() orelse break;
                    const ry = p.num() orelse break;
                    const rot = p.num() orelse break;
                    const large = p.flag() orelse break;
                    const sw = p.flag() orelse break;
                    const x = p.num() orelse break;
                    const y = p.num() orelse break;
                    try b.arcTo(rx, ry, rot, large, sw, .{ .x = o.x + x, .y = o.y + y });
                    last_kind = 'A';
                },
                else => break,
            }
            last_ctrl = null;
        }
        try b.finish();
    }
};

// ---------------------------------------------------------------- XML

const Tag = struct {
    name: []const u8,
    /// The attributes' text, between the name and the tag's end.
    attrs: []const u8,
    end: bool = false,
    self_closing: bool = false,

    fn attr(t: Tag, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        const s = t.attrs;
        while (i < s.len) {
            while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
            const ks = i;
            while (i < s.len and s[i] != '=' and !std.ascii.isWhitespace(s[i])) i += 1;
            const k = s[ks..i];
            while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
            if (i >= s.len or s[i] != '=') {
                if (k.len == 0) i += 1;
                continue;
            }
            i += 1;
            while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
            if (i >= s.len) break;
            const q = s[i];
            if (q != '"' and q != '\'') continue;
            const vs = i + 1;
            const ve = std.mem.indexOfScalarPos(u8, s, vs, q) orelse break;
            i = ve + 1;
            if (std.mem.eql(u8, k, key)) return s[vs..ve];
        }
        return null;
    }
};

const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn next(sc: *Scanner) ?Tag {
        const s = sc.s;
        while (true) {
            const lt = std.mem.indexOfScalarPos(u8, s, sc.i, '<') orelse return null;
            sc.i = lt + 1;
            if (std.mem.startsWith(u8, s[lt..], "<!--")) {
                sc.i = if (std.mem.indexOfPos(u8, s, lt + 4, "-->")) |e| e + 3 else s.len;
                continue;
            }
            if (std.mem.startsWith(u8, s[lt..], "<![CDATA[")) {
                sc.i = if (std.mem.indexOfPos(u8, s, lt, "]]>")) |e| e + 3 else s.len;
                continue;
            }
            if (std.mem.startsWith(u8, s[lt..], "<?")) {
                sc.i = if (std.mem.indexOfPos(u8, s, lt, "?>")) |e| e + 2 else s.len;
                continue;
            }
            if (std.mem.startsWith(u8, s[lt..], "<!")) {
                // A declaration (DOCTYPE), with an internal subset maybe.
                var depth: usize = 0;
                var j = lt + 2;
                while (j < s.len) : (j += 1) {
                    if (s[j] == '[') depth += 1 else if (s[j] == ']' and depth > 0) depth -= 1 else if (s[j] == '>' and depth == 0) break;
                }
                sc.i = @min(s.len, j + 1);
                continue;
            }
            // The tag's end: the first '>' outside quotes.
            var j = lt + 1;
            var q: u8 = 0;
            while (j < s.len) : (j += 1) {
                const c = s[j];
                if (q != 0) {
                    if (c == q) q = 0;
                } else if (c == '"' or c == '\'') q = c else if (c == '>') break;
            }
            if (j >= s.len) return null;
            sc.i = j + 1;
            var body = s[lt + 1 .. j];
            var t: Tag = .{ .name = "", .attrs = "" };
            if (body.len > 0 and body[0] == '/') {
                t.end = true;
                body = body[1..];
            }
            if (body.len > 0 and body[body.len - 1] == '/') {
                t.self_closing = true;
                body = body[0 .. body.len - 1];
            }
            var k: usize = 0;
            while (k < body.len and !std.ascii.isWhitespace(body[k])) k += 1;
            t.name = body[0..k];
            t.attrs = body[k..];
            if (t.name.len == 0) continue;
            return t;
        }
    }
};

// ---------------------------------------------------------------- tests

fn area(o: geom.Outline) f64 {
    return @abs(o.signedArea());
}

test "a 10 mm square, filled, from a document in mm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a,
        \\<?xml version="1.0"?>
        \\<!-- a comment -->
        \\<svg xmlns="http://www.w3.org/2000/svg" width="20mm" height="20mm" viewBox="0 0 20 20">
        \\  <rect x="5" y="2" width="10" height="10" fill="#ff0000"/>
        \\</svg>
    );
    try std.testing.expectEqual(1, r.paths.len);
    try std.testing.expectApproxEqAbs(20, r.height, 1e-12);
    const p = r.paths[0];
    try std.testing.expectEqual(255, p.fill.?.r);
    try std.testing.expect(p.stroke == null);
    const shapes = try figure.ink(a, .{ .name = "t", .paths = r.paths }, 1e-3);
    const b = figure.inkBounds(shapes);
    // y flipped: the square's top (y 2 in SVG) is 18 mm up.
    try std.testing.expectApproxEqAbs(18, b.y1, 1e-9);
    try std.testing.expectApproxEqAbs(8, b.y0, 1e-9);
    try std.testing.expectApproxEqAbs(100, area(shapes[0].outline), 1e-9);
}

test "path commands, relative and absolute, and a stroke with round caps from style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a,
        \\<svg viewBox="0 0 100 100" width="100mm" height="100mm">
        \\ <g transform="translate(10,0)">
        \\  <path d="M0,50 h20 v-10 l10-10 L 40,30" style="fill:none;stroke:black;stroke-width:2;stroke-linecap:round;stroke-linejoin:bevel"/>
        \\ </g>
        \\</svg>
    );
    try std.testing.expectEqual(1, r.paths.len);
    const p = r.paths[0];
    try std.testing.expect(p.fill == null);
    try std.testing.expectEqual(geom.stroke.Cap.round, p.stroke.?.cap);
    try std.testing.expectEqual(geom.stroke.Join.bevel, p.stroke.?.join);
    try std.testing.expectApproxEqAbs(2, p.stroke.?.width, 1e-12);
    const segs = p.subpaths[0].segments;
    try std.testing.expectEqual(4, segs.len);
    // The last point: (40 + 10, 100 - 30).
    try std.testing.expectApproxEqAbs(50, segs[3].end().x, 1e-12);
    try std.testing.expectApproxEqAbs(70, segs[3].end().y, 1e-12);
}

test "a circle is four exact conics; its area is a circle's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a,
        \\<svg width="40mm" height="40mm" viewBox="0 0 40 40"><circle cx="20" cy="20" r="10"/></svg>
    );
    const segs = r.paths[0].subpaths[0].segments;
    try std.testing.expectEqual(4, segs.len);
    try std.testing.expect(segs[0] == .conic);
    const shapes = try figure.ink(a, .{ .name = "c", .paths = r.paths }, 1e-3);
    try std.testing.expectApproxEqAbs(std.math.pi * 100, area(shapes[0].outline), 1e-6);
}

test "arcs in a path; px sized documents; nested styles; skipped text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a,
        \\<svg width="96" height="96"><g fill="none" stroke="#00f" stroke-width="4">
        \\ <path d="M10 48a38 38 0 1 0 76 0A38 38 0 1 0 10 48z"/>
        \\ <text x="0" y="10">Hi</text>
        \\</g></svg>
    );
    try std.testing.expectEqual(1, r.paths.len);
    try std.testing.expectEqual(1, r.report.text);
    try std.testing.expectApproxEqAbs(25.4, r.width, 1e-12);
    const st = r.paths[0].stroke.?;
    try std.testing.expectEqual(255, st.color.b);
    // 4 px is 4 × 25.4 / 96 mm.
    try std.testing.expectApproxEqAbs(4 * 25.4 / 96.0, st.width, 1e-12);
    const shapes = try figure.ink(a, .{ .name = "ring", .paths = r.paths }, 1e-4);
    // A ring 38 ± 2 px: π (40² − 36²) px².
    const s: f64 = 25.4 / 96.0;
    try std.testing.expectApproxEqAbs(std.math.pi * (40 * 40 - 36 * 36) * s * s, area(shapes[0].outline), 1e-2);
}

test "not SVG" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotSvg, parse(arena.allocator(), "<html><body/></html>"));
}
