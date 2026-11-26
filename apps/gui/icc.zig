//! ICC display profiles: enough of ICC.1 (v2 and v4) to show sRGB colours
//! right on a screen that has a profile, without a colour management
//! library.
//!
//! A display profile of the common kind (matrix and curves, "matrix/TRC")
//! says how the screen's own values become light: each channel's value
//! through its tone curve (`rTRC`, `gTRC`, `bTRC`) to linear light, then a
//! 3 × 3 matrix whose columns are the primaries (`rXYZ`, `gXYZ`, `bXYZ`)
//! to CIE XYZ under D50 (the profile connection space). Showing an sRGB
//! colour is that path run backwards from the colour's own XYZ:
//!
//!   sRGB value → linear sRGB → XYZ (D50) → the screen's linear values
//!   → its tone curves inverted → the value sent to the screen
//!
//! Out-of-gamut colours are clipped channel by channel (relative
//! colorimetric, without black point compensation). Profiles made only of
//! lookup tables (`A2B0` with no matrix) are not read: `parse` says so.
//!
//! A profile may also carry calibration curves (`vcgt`), meant for the
//! video card's gamma ramp; the profile describes the screen with them
//! loaded. Desktops that publish a profile also load its calibration, so
//! they are applied only when asked (`Options.calibration`), for a profile
//! file chosen by hand on a desktop that loads nothing (COSMIC, say).

const std = @import("std");

pub const Error = error{
    /// Not an ICC profile, or cut short.
    Malformed,
    /// Not an RGB display profile (a printer's, or greyscale).
    NotRgbDisplay,
    /// Lookup tables only: no matrix and curves to use.
    TablesOnly,
};

/// A tone curve: a value (0 to 1) to linear light (0 to 1).
pub const Curve = union(enum) {
    gamma: f64,
    /// ICC parametric function types 0 to 4: g, a, b, c, d, e, f.
    parametric: struct { kind: u16, p: [7]f64 },
    /// Evenly spaced samples, 0 to 1 each.
    table: []const f64,

    pub fn eval(c: Curve, x0: f64) f64 {
        const x = std.math.clamp(x0, 0, 1);
        return switch (c) {
            .gamma => |g| std.math.pow(f64, x, g),
            .parametric => |pc| param(pc.kind, pc.p, x),
            .table => |t| blk: {
                if (t.len == 0) break :blk x;
                if (t.len == 1) break :blk t[0];
                const f = x * @as(f64, @floatFromInt(t.len - 1));
                const i: usize = @min(t.len - 2, @as(usize, @intFromFloat(@floor(f))));
                const u = f - @as(f64, @floatFromInt(i));
                break :blk t[i] + (t[i + 1] - t[i]) * u;
            },
        };
    }

    fn param(kind: u16, p: [7]f64, x: f64) f64 {
        const g = p[0];
        const a = p[1];
        const b = p[2];
        const c = p[3];
        const d = p[4];
        const e = p[5];
        const f = p[6];
        return switch (kind) {
            0 => std.math.pow(f64, x, g),
            1 => if (a != 0 and x >= -b / a) std.math.pow(f64, @max(0, a * x + b), g) else 0,
            2 => if (a != 0 and x >= -b / a) std.math.pow(f64, @max(0, a * x + b), g) + c else c,
            3 => if (x >= d) std.math.pow(f64, @max(0, a * x + b), g) else c * x,
            4 => if (x >= d) std.math.pow(f64, @max(0, a * x + b), g) + e else c * x + f,
            else => x,
        };
    }

    /// The value whose light is `y` (curves are taken to rise; a flat or
    /// falling stretch gives its first value).
    pub fn inverse(c: Curve, y: f64) f64 {
        if (c == .gamma and c.gamma > 0) return std.math.pow(f64, std.math.clamp(y, 0, 1), 1 / c.gamma);
        var lo: f64 = 0;
        var hi: f64 = 1;
        for (0..40) |_| {
            const mid = (lo + hi) / 2;
            if (c.eval(mid) < y) lo = mid else hi = mid;
        }
        return (lo + hi) / 2;
    }
};

/// Calibration curves (`vcgt`): per channel, a value to the value loaded.
pub const Calibration = struct {
    curves: [3]Curve,
};

pub const Profile = struct {
    /// Its description (`desc`), as ASCII; may be empty.
    name: []const u8,
    /// Columns: the red, green and blue primaries, XYZ under D50.
    matrix: [3][3]f64,
    trc: [3]Curve,
    calibration: ?Calibration = null,
};

fn be16(d: []const u8, at: usize) Error!u16 {
    if (at + 2 > d.len) return error.Malformed;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

fn be32(d: []const u8, at: usize) Error!u32 {
    if (at + 4 > d.len) return error.Malformed;
    return std.mem.readInt(u32, d[at..][0..4], .big);
}

fn s15(d: []const u8, at: usize) Error!f64 {
    const v: i32 = @bitCast(try be32(d, at));
    return @as(f64, @floatFromInt(v)) / 65536;
}

fn sig(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// The tag `name`'s bytes, or null.
fn tag(d: []const u8, name: u32) Error!?[]const u8 {
    const n = try be32(d, 128);
    if (n > 1000) return error.Malformed;
    for (0..n) |i| {
        const e = 132 + i * 12;
        if (try be32(d, e) != name) continue;
        const off = try be32(d, e + 4);
        const len = try be32(d, e + 8);
        if (@as(u64, off) + len > d.len or len < 8) return error.Malformed;
        return d[off..][0..len];
    }
    return null;
}

fn xyz(t: []const u8) Error![3]f64 {
    if (try be32(t, 0) != sig("XYZ ")) return error.Malformed;
    return .{ try s15(t, 8), try s15(t, 12), try s15(t, 16) };
}

fn curve(a: std.mem.Allocator, t: []const u8) (Error || std.mem.Allocator.Error)!Curve {
    const kind = try be32(t, 0);
    if (kind == sig("curv")) {
        const n = try be32(t, 8);
        if (n == 0) return .{ .gamma = 1 };
        if (n == 1) return .{ .gamma = @as(f64, @floatFromInt(try be16(t, 12))) / 256 };
        if (12 + @as(u64, n) * 2 > t.len) return error.Malformed;
        const s = try a.alloc(f64, n);
        for (s, 0..) |*v, i| v.* = @as(f64, @floatFromInt(try be16(t, 12 + i * 2))) / 65535;
        return .{ .table = s };
    }
    if (kind == sig("para")) {
        const fk = try be16(t, 8);
        const counts = [_]usize{ 1, 3, 4, 5, 7 };
        if (fk >= counts.len) return error.Malformed;
        var p = [_]f64{ 1, 1, 0, 0, 0, 0, 0 };
        for (0..counts[fk]) |i| p[i] = try s15(t, 12 + i * 4);
        return .{ .parametric = .{ .kind = fk, .p = p } };
    }
    return error.Malformed;
}

fn description(a: std.mem.Allocator, d: []const u8) (Error || std.mem.Allocator.Error)![]const u8 {
    const t = (try tag(d, sig("desc"))) orelse return "";
    const kind = try be32(t, 0);
    var out: std.ArrayList(u8) = .empty;
    if (kind == sig("desc")) {
        const n = try be32(t, 8);
        if (12 + @as(u64, n) > t.len) return error.Malformed;
        for (t[12..][0..n]) |ch| {
            if (ch == 0) break;
            try out.append(a, if (ch < 0x20 or ch > 0x7e) '?' else ch);
        }
    } else if (kind == sig("mluc")) {
        // The first record (usually en-US), UTF-16BE, kept as ASCII.
        if (try be32(t, 8) == 0) return "";
        const len = try be32(t, 20);
        const off = try be32(t, 24);
        if (@as(u64, off) + len > t.len) return error.Malformed;
        var i: usize = 0;
        while (i + 1 < len) : (i += 2) {
            const u = try be16(t, off + i);
            if (u == 0) break;
            try out.append(a, if (u < 0x20 or u > 0x7e) '?' else @intCast(u));
        }
    }
    return std.mem.trim(u8, out.items, " ");
}

fn calibration(a: std.mem.Allocator, d: []const u8) (Error || std.mem.Allocator.Error)!?Calibration {
    const t = (try tag(d, sig("vcgt"))) orelse return null;
    if (try be32(t, 0) != sig("vcgt")) return null;
    const kind = try be32(t, 8);
    var cal: Calibration = undefined;
    if (kind == 0) {
        const channels = try be16(t, 12);
        const entries = try be16(t, 14);
        const size = try be16(t, 16);
        if ((channels != 1 and channels != 3) or entries < 2 or (size != 1 and size != 2)) return null;
        for (0..3) |ch| {
            const src = if (channels == 1) 0 else ch;
            const s = try a.alloc(f64, entries);
            for (s, 0..) |*v, i| {
                const at = 18 + (src * entries + i) * size;
                v.* = if (size == 2) @as(f64, @floatFromInt(try be16(t, at))) / 65535 else @as(f64, @floatFromInt(if (at < t.len) t[at] else return error.Malformed)) / 255;
            }
            cal.curves[ch] = .{ .table = s };
        }
        return cal;
    }
    if (kind == 1) {
        // Per channel gamma, min, max: min + (max - min) · x^gamma, as a
        // parametric curve of type 2 would not quite say; sampled instead.
        for (0..3) |ch| {
            const g = try s15(t, 12 + ch * 12);
            const lo = try s15(t, 16 + ch * 12);
            const hi = try s15(t, 20 + ch * 12);
            const s = try a.alloc(f64, 256);
            for (s, 0..) |*v, i| v.* = lo + (hi - lo) * std.math.pow(f64, @as(f64, @floatFromInt(i)) / 255, g);
            cal.curves[ch] = .{ .table = s };
        }
        return cal;
    }
    return null;
}

/// Reads a profile; its curves and name are allocated with `a` (an arena
/// suits).
pub fn parse(a: std.mem.Allocator, d: []const u8) (Error || std.mem.Allocator.Error)!Profile {
    if (d.len < 132 or try be32(d, 36) != sig("acsp")) return error.Malformed;
    if (try be32(d, 12) != sig("mntr") or try be32(d, 16) != sig("RGB ")) return error.NotRgbDisplay;
    const r = (try tag(d, sig("rXYZ"))) orelse return if (try tag(d, sig("A2B0")) != null) error.TablesOnly else error.Malformed;
    const g = (try tag(d, sig("gXYZ"))) orelse return error.Malformed;
    const b = (try tag(d, sig("bXYZ"))) orelse return error.Malformed;
    const rt = (try tag(d, sig("rTRC"))) orelse return error.TablesOnly;
    const gt = (try tag(d, sig("gTRC"))) orelse return error.TablesOnly;
    const bt = (try tag(d, sig("bTRC"))) orelse return error.TablesOnly;
    const cr = try xyz(r);
    const cg = try xyz(g);
    const cb = try xyz(b);
    return .{
        .name = try description(a, d),
        .matrix = .{
            .{ cr[0], cg[0], cb[0] },
            .{ cr[1], cg[1], cb[1] },
            .{ cr[2], cg[2], cb[2] },
        },
        .trc = .{ try curve(a, rt), try curve(a, gt), try curve(a, bt) },
        .calibration = try calibration(a, d),
    };
}

/// sRGB's primaries as XYZ under D50 (Bradford-adapted; the matrix of the
/// sRGB profile ICC distributes).
pub const srgb_to_d50: [3][3]f64 = .{
    .{ 0.4360747, 0.3850649, 0.1430804 },
    .{ 0.2225045, 0.7168786, 0.0606169 },
    .{ 0.0139322, 0.0971045, 0.7141733 },
};

fn mul(a: [3][3]f64, b: [3][3]f64) [3][3]f64 {
    var m: [3][3]f64 = undefined;
    for (0..3) |i| for (0..3) |j| {
        m[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    };
    return m;
}

fn invert(m: [3][3]f64) ?[3][3]f64 {
    const a = m[0][0];
    const b = m[0][1];
    const c = m[0][2];
    const d = m[1][0];
    const e = m[1][1];
    const f = m[1][2];
    const g = m[2][0];
    const h = m[2][1];
    const i = m[2][2];
    const det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (@abs(det) < 1e-12) return null;
    return .{
        .{ (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det },
        .{ (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det },
        .{ (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det },
    };
}

/// sRGB's tone curve: a value to linear light.
pub fn srgbToLinear(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

pub const Options = struct {
    /// Apply the profile's calibration curves (`vcgt`), when it has them.
    calibration: bool = false,
};

/// Entries in the table from linear light to the screen's values; indexed
/// by the square root of the light, so the darks get their share.
const out_n = 4096;

/// sRGB colours to the screen's values, as tables: fast enough to run on
/// every colour drawn.
pub const Transform = struct {
    /// An sRGB channel value to linear light.
    lin: [256]f32,
    /// Linear sRGB to the screen's linear values.
    m: [3][3]f32,
    /// Per channel: the light (by its square root, `out_n` steps) to the
    /// value sent, 0 to 255.
    out: [3][out_n]u8,

    pub fn init(p: Profile, o: Options) ?Transform {
        const inv = invert(p.matrix) orelse return null;
        const m = mul(inv, srgb_to_d50);
        var t: Transform = undefined;
        for (&t.lin, 0..) |*e, i| e.* = @floatCast(srgbToLinear(@as(f64, @floatFromInt(i)) / 255));
        for (0..3) |i| for (0..3) |j| {
            t.m[i][j] = @floatCast(m[i][j]);
        };
        for (0..3) |ch| for (&t.out[ch], 0..) |*e, k| {
            const s = @as(f64, @floatFromInt(k)) / (out_n - 1);
            var v = p.trc[ch].inverse(s * s);
            if (o.calibration) if (p.calibration) |cal| {
                v = cal.curves[ch].eval(v);
            };
            e.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        };
        return t;
    }

    /// The value to send for sRGB colour `rgb`.
    pub fn apply(t: *const Transform, rgb: [3]u8) [3]u8 {
        const l = [3]f32{ t.lin[rgb[0]], t.lin[rgb[1]], t.lin[rgb[2]] };
        var out: [3]u8 = undefined;
        for (0..3) |ch| {
            const v = t.m[ch][0] * l[0] + t.m[ch][1] * l[1] + t.m[ch][2] * l[2];
            const s = @sqrt(std.math.clamp(v, 0, 1));
            out[ch] = t.out[ch][@intFromFloat(@round(s * (out_n - 1)))];
        }
        return out;
    }
};

// Building profiles, for the tests (and for a profile made from a screen's
// reported primaries, later).

/// A v2 matrix/TRC display profile with the given primaries (columns of
/// XYZ under D50), one gamma for all three channels, and calibration
/// curves (per channel, `n` 16-bit entries) when given.
pub fn build(a: std.mem.Allocator, name: []const u8, matrix: [3][3]f64, gamma: f64, vcgt: ?[3][]const u16) ![]u8 {
    var tags: std.ArrayList(struct { sig: u32, data: []const u8 }) = .empty;
    defer tags.deinit(a);
    var bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (bufs.items) |b| a.free(b);
        bufs.deinit(a);
    }
    const Put = struct {
        fn u32be(b: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, b[at..][0..4], v, .big);
        }
        fn s15f(b: []u8, at: usize, v: f64) void {
            std.mem.writeInt(i32, b[at..][0..4], @intFromFloat(@round(v * 65536)), .big);
        }
    };
    {
        const d = try a.alloc(u8, 12 + name.len + 1 + 12 + 67);
        @memset(d, 0);
        Put.u32be(d, 0, sig("desc"));
        Put.u32be(d, 8, @intCast(name.len + 1));
        @memcpy(d[12..][0..name.len], name);
        try bufs.append(a, d);
        try tags.append(a, .{ .sig = sig("desc"), .data = d });
    }
    for ([_]*const [4]u8{ "rXYZ", "gXYZ", "bXYZ" }, 0..) |s, col| {
        const d = try a.alloc(u8, 20);
        @memset(d, 0);
        Put.u32be(d, 0, sig("XYZ "));
        for (0..3) |row| Put.s15f(d, 8 + row * 4, matrix[row][col]);
        try bufs.append(a, d);
        try tags.append(a, .{ .sig = sig(s), .data = d });
    }
    {
        const d = try a.alloc(u8, 14);
        @memset(d, 0);
        Put.u32be(d, 0, sig("curv"));
        Put.u32be(d, 8, 1);
        std.mem.writeInt(u16, d[12..14], @intFromFloat(@round(gamma * 256)), .big);
        try bufs.append(a, d);
        for ([_]*const [4]u8{ "rTRC", "gTRC", "bTRC" }) |s| try tags.append(a, .{ .sig = sig(s), .data = d });
    }
    if (vcgt) |v| {
        const n = v[0].len;
        const d = try a.alloc(u8, 18 + 3 * n * 2);
        @memset(d, 0);
        Put.u32be(d, 0, sig("vcgt"));
        std.mem.writeInt(u16, d[12..14], 3, .big);
        std.mem.writeInt(u16, d[14..16], @intCast(n), .big);
        std.mem.writeInt(u16, d[16..18], 2, .big);
        for (0..3) |ch| for (v[ch], 0..) |e, i| std.mem.writeInt(u16, d[18 + (ch * n + i) * 2 ..][0..2], e, .big);
        try bufs.append(a, d);
        try tags.append(a, .{ .sig = sig("vcgt"), .data = d });
    }
    const table_end = 132 + tags.items.len * 12;
    var size = table_end;
    for (tags.items) |t| size = std.mem.alignForward(usize, size, 4) + t.data.len;
    const out = try a.alloc(u8, size);
    @memset(out, 0);
    Put.u32be(out, 0, @intCast(size));
    Put.u32be(out, 8, 0x02100000);
    Put.u32be(out, 12, sig("mntr"));
    Put.u32be(out, 16, sig("RGB "));
    Put.u32be(out, 20, sig("XYZ "));
    Put.u32be(out, 36, sig("acsp"));
    Put.u32be(out, 128, @intCast(tags.items.len));
    var at = table_end;
    for (tags.items, 0..) |t, i| {
        at = std.mem.alignForward(usize, at, 4);
        @memcpy(out[at..][0..t.data.len], t.data);
        Put.u32be(out, 132 + i * 12, t.sig);
        Put.u32be(out, 132 + i * 12 + 4, @intCast(at));
        Put.u32be(out, 132 + i * 12 + 8, @intCast(t.data.len));
        at += t.data.len;
    }
    return out[0..at];
}

const testing = std.testing;

/// Display P3's primaries under D50 (D65 white, Bradford-adapted).
const p3_d50: [3][3]f64 = .{
    .{ 0.5151, 0.2920, 0.1571 },
    .{ 0.2412, 0.6922, 0.0666 },
    .{ -0.0011, 0.0419, 0.7841 },
};

test "an sRGB-like profile leaves colours as they are" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try build(a, "sRGB-like", srgb_to_d50, 2.2, null);
    const p = try parse(a, bytes);
    try testing.expectEqualStrings("sRGB-like", p.name);
    try testing.expectApproxEqAbs(0.4360747, p.matrix[0][0], 1e-4);
    const t = Transform.init(p, .{}).?;
    // Black and white stay put; greys stay grey, re-encoded from sRGB's
    // curve to gamma 2.2.
    try testing.expectEqual([3]u8{ 0, 0, 0 }, t.apply(.{ 0, 0, 0 }));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, t.apply(.{ 255, 255, 255 }));
    for ([_]u8{ 32, 64, 128, 200 }) |v| {
        const o = t.apply(.{ v, v, v });
        const want = @round(255 * std.math.pow(f64, srgbToLinear(@as(f64, @floatFromInt(v)) / 255), 1.0 / 2.2));
        try testing.expectApproxEqAbs(want, @as(f64, @floatFromInt(o[0])), 1);
        try testing.expectEqual(o[0], o[1]);
        try testing.expectEqual(o[1], o[2]);
    }
}

test "a wide-gamut screen gets sRGB's red less saturated, its white unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, try build(a, "P3", p3_d50, 2.2, null));
    const t = Transform.init(p, .{}).?;
    const red = t.apply(.{ 255, 0, 0 });
    // Pure sRGB red sits inside P3: some green and blue are needed.
    try testing.expect(red[0] < 255 and red[0] > 200);
    try testing.expect(red[1] > 0);
    const w = t.apply(.{ 255, 255, 255 });
    for (w) |c| try testing.expect(c >= 253);
}

test "calibration curves are applied only when asked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A calibration that halves every value.
    var half: [256]u16 = undefined;
    for (&half, 0..) |*e, i| e.* = @intCast(i * 65535 / 255 / 2);
    const p = try parse(a, try build(a, "cal", srgb_to_d50, 2.2, .{ &half, &half, &half }));
    try testing.expect(p.calibration != null);
    const plain = Transform.init(p, .{}).?;
    const cal = Transform.init(p, .{ .calibration = true }).?;
    try testing.expectEqual(255, plain.apply(.{ 255, 255, 255 })[0]);
    try testing.expectApproxEqAbs(127.5, @as(f64, @floatFromInt(cal.apply(.{ 255, 255, 255 })[0])), 1);
}

test "parametric and table curves, and what is not read" {
    const c3: Curve = .{ .parametric = .{ .kind = 3, .p = .{ 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045, 0, 0 } } };
    for ([_]f64{ 0, 0.02, 0.2, 0.5, 1 }) |x| try testing.expectApproxEqAbs(srgbToLinear(x), c3.eval(x), 1e-9);
    try testing.expectApproxEqAbs(0.5, c3.eval(c3.inverse(0.5)), 1e-9);
    const tab: Curve = .{ .table = &.{ 0, 0.25, 1 } };
    try testing.expectApproxEqAbs(0.125, tab.eval(0.25), 1e-12);
    try testing.expectError(error.Malformed, parse(testing.allocator, "not a profile"));
}

test "a real sRGB profile (Little CMS's, v4: parametric curves, mluc)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, @embedFile("testdata/srgb-lcms.icc"));
    try testing.expect(p.name.len > 0);
    const t = Transform.init(p, .{}).?;
    // sRGB on an sRGB screen: every colour as it was, to within a step.
    var worst: i32 = 0;
    var v: u32 = 0;
    while (v < 256) : (v += 15) {
        const c = [3]u8{ @intCast(v), @intCast(255 - v), @intCast((v * 7) % 256) };
        const o = t.apply(c);
        for (0..3) |i| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, o[i]) - c[i]))));
    }
    try testing.expect(worst <= 1);
}
