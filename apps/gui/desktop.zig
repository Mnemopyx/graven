//! The desktop's appearance settings, so Graven's own title bar and chrome
//! match the desktop the way GTK apps do: dark or light, the accent colour,
//! and the window buttons' order and side.
//!
//! Read from the XDG desktop portal's Settings interface (COSMIC, GNOME and
//! KDE all answer it) through `gdbus`, with `gsettings` as a fallback for
//! the button layout. Anything missing keeps a neutral default, so a bare
//! X11 session still works.

const std = @import("std");

pub const Scheme = enum { none, dark, light };

pub const Button = enum { minimize, maximize, close };

/// Which window buttons go on each side, in order.
pub const Layout = struct {
    left: [3]Button = undefined,
    left_len: usize = 0,
    right: [3]Button = .{ .minimize, .maximize, .close },
    right_len: usize = 3,

    pub fn leftSide(l: *const Layout) []const Button {
        return l.left[0..l.left_len];
    }

    pub fn rightSide(l: *const Layout) []const Button {
        return l.right[0..l.right_len];
    }

    /// Parses GNOME's "left:right" form, as in "appmenu:minimize,maximize,close";
    /// entries other than the three buttons (appmenu, icon, spacer) are skipped.
    pub fn parse(text: []const u8) Layout {
        var l: Layout = .{ .right_len = 0 };
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse text.len;
        fill(text[0..colon], &l.left, &l.left_len);
        if (colon < text.len) fill(text[colon + 1 ..], &l.right, &l.right_len);
        return l;
    }

    fn fill(list: []const u8, out: *[3]Button, len: *usize) void {
        var it = std.mem.tokenizeAny(u8, list, ", ");
        while (it.next()) |name| {
            const b: Button = if (std.mem.eql(u8, name, "minimize"))
                .minimize
            else if (std.mem.eql(u8, name, "maximize"))
                .maximize
            else if (std.mem.eql(u8, name, "close"))
                .close
            else
                continue;
            if (len.* < out.len) {
                out[len.*] = b;
                len.* += 1;
            }
        }
    }
};

pub const Settings = struct {
    scheme: Scheme = .none,
    /// sRGB, 0 to 1.
    accent: ?[3]f32 = null,
    layout: Layout = .{},

    pub fn eql(a: Settings, b: Settings) bool {
        return std.meta.eql(a, b);
    }
};

/// Reads the settings now. Slow-ish (it starts processes): call it at
/// start-up, then from `watch`'s thread.
pub fn read(gpa: std.mem.Allocator, io: std.Io) Settings {
    var s: Settings = .{};
    if (portal(gpa, io, "org.freedesktop.appearance", "color-scheme")) |out| {
        defer gpa.free(out);
        // 1 prefers dark, 2 prefers light, 0 has no preference.
        if (std.mem.indexOf(u8, out, "uint32 ")) |i| {
            s.scheme = switch (out[i + 7]) {
                '1' => .dark,
                '2' => .light,
                else => .none,
            };
        }
    }
    if (portal(gpa, io, "org.freedesktop.appearance", "accent-color")) |out| {
        defer gpa.free(out);
        s.accent = parseAccent(out);
    }
    const layout_text = portal(gpa, io, "org.gnome.desktop.wm.preferences", "button-layout") orelse
        run(gpa, io, &.{ "gsettings", "get", "org.gnome.desktop.wm.preferences", "button-layout" });
    if (layout_text) |out| {
        defer gpa.free(out);
        if (quoted(out)) |text| s.layout = .parse(text);
    }
    return s;
}

/// The accent from gdbus's "(<(0.2, 0.5, 0.9)>,)"; values outside 0..1
/// mean the desktop has none.
fn parseAccent(out: []const u8) ?[3]f32 {
    var nums: [3]f32 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, out, "()<>, \n");
    while (it.next()) |tok| {
        const v = std.fmt.parseFloat(f32, tok) catch continue;
        if (n == 3) return null;
        nums[n] = v;
        n += 1;
    }
    if (n != 3) return null;
    for (nums) |v| if (!(v >= 0 and v <= 1)) return null;
    return nums;
}

fn quoted(out: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, out, '\'') orelse return null;
    const b = std.mem.lastIndexOfScalar(u8, out, '\'') orelse return null;
    return if (b > a) out[a + 1 .. b] else null;
}

/// One portal setting, as gdbus prints it; ReadOne first, then the older
/// Read for portals that lack it.
fn portal(gpa: std.mem.Allocator, io: std.Io, namespace: []const u8, key: []const u8) ?[]u8 {
    for ([_][]const u8{ "org.freedesktop.portal.Settings.ReadOne", "org.freedesktop.portal.Settings.Read" }) |method| {
        if (run(gpa, io, &.{ "gdbus", "call", "--session", "--timeout", "2", "--dest", "org.freedesktop.portal.Desktop", "--object-path", "/org/freedesktop/portal/desktop", "--method", method, namespace, key })) |out| return out;
    }
    return null;
}

/// A command's output, or null when it fails or cannot start.
fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    gpa.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

/// Settings read by the watch thread and not yet taken by the GUI.
var pending: Settings = .{};
var has_pending: std.atomic.Value(bool) = .init(false);

/// Re-reads the settings every few seconds on a thread of its own, calling
/// `wake` when they change; the GUI takes them with `take`.
pub fn watch(io: std.Io, current: Settings, wake: *const fn () void) void {
    const thread = std.Thread.spawn(.{}, loop, .{ io, current, wake }) catch return;
    thread.detach();
}

fn loop(io: std.Io, start: Settings, wake: *const fn () void) void {
    var last = start;
    while (true) {
        io.sleep(.fromSeconds(3), .awake) catch return;
        const s = read(std.heap.smp_allocator, io);
        if (s.eql(last) or has_pending.load(.acquire)) continue;
        pending = s;
        has_pending.store(true, .release);
        last = s;
        wake();
    }
}

/// Settings that changed since the last call, if any.
pub fn take() ?Settings {
    if (!has_pending.load(.acquire)) return null;
    const s = pending;
    has_pending.store(false, .release);
    return s;
}

test "button layouts parse to sides" {
    const l = Layout.parse("appmenu:minimize,maximize,close");
    try std.testing.expectEqual(0, l.leftSide().len);
    try std.testing.expectEqualSlices(Button, &.{ .minimize, .maximize, .close }, l.rightSide());
    const mac = Layout.parse("close,minimize,maximize:");
    try std.testing.expectEqualSlices(Button, &.{ .close, .minimize, .maximize }, mac.leftSide());
    try std.testing.expectEqual(0, mac.rightSide().len);
    try std.testing.expect(parseAccent("(<(0.2, 0.5, 0.9)>,)") != null);
    try std.testing.expect(parseAccent("(<(-1.0, -1.0, -1.0)>,)") == null);
}
