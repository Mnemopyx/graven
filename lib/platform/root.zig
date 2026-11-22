//! What differs between the systems Graven runs on, chosen by the build
//! target, in one place (decided 2026-11-20): constants, and the few
//! functions that find things (environment, home, host name, Graven's own
//! folders, font folders, absolute paths). Code elsewhere uses these and
//! does not switch on the OS itself.
//!
//! Folders, by system:
//!
//! | `appDir`   | Linux and others                 | macOS                                  | Windows                    |
//! |------------|----------------------------------|----------------------------------------|----------------------------|
//! | `.config`  | $XDG_CONFIG_HOME/graven, ~/.config/graven | ~/Library/Application Support/Graven | %APPDATA%\Graven (roams) |
//! | `.machine` | as `.config`                     | as `.config`                           | %LOCALAPPDATA%\Graven      |
//! | `.data`    | $XDG_DATA_HOME/graven, ~/.local/share/graven | ~/Library/Application Support/Graven | %LOCALAPPDATA%\Graven |
//! | `.cache`   | $XDG_CACHE_HOME/graven, ~/.cache/graven | ~/Library/Caches/Graven          | %LOCALAPPDATA%\Graven      |

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The system built for.
pub const os = builtin.os.tag;
pub const is_windows = os == .windows;
pub const is_macos = os == .macos;
/// A short name for the system: "linux", "macos", "windows" ….
pub const name: []const u8 = @tagName(os);
/// The separator between a path's parts.
pub const path_sep = std.fs.path.sep;
/// What an executable's file name ends in.
pub const exe_suffix: []const u8 = if (is_windows) ".exe" else "";
/// The line ending text files written for people use.
pub const newline: []const u8 = if (is_windows) "\r\n" else "\n";
/// Room for a host name.
pub const host_name_max: usize = if (is_windows) 256 else if (@hasDecl(std.posix, "HOST_NAME_MAX")) std.posix.HOST_NAME_MAX else 256;

/// Modifier keys as this system names them, for shortcuts shown.
pub const key_names = struct {
    /// The modifiers as symbols, written straight before the key (the
    /// owner, 2026-11-22): ⌃ Ctrl, ⇧ Shift, ⌥ Alt or Option, ⌘ Cmd (the
    /// Super or Windows key elsewhere).
    pub const cmd: []const u8 = "\u{2318}";
    pub const alt: []const u8 = "\u{2325}";
    pub const ctrl: []const u8 = "\u{2303}";
    pub const shift: []const u8 = "\u{21E7}";
};

/// A monotonic clock, in nanoseconds from an arbitrary start: for timing,
/// not for dates.
pub fn monotonicNs() i128 {
    if (is_windows) {
        const ntdll = std.os.windows.ntdll;
        var qpc: i64 = 0;
        var qpf: i64 = 0;
        _ = ntdll.RtlQueryPerformanceCounter(@ptrCast(&qpc));
        _ = ntdll.RtlQueryPerformanceFrequency(@ptrCast(&qpf));
        if (qpf == 0) return 0;
        return @divTrunc(@as(i128, qpc) * std.time.ns_per_s, qpf);
    }
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// An environment variable; empty counts as unset.
pub fn env(var_name: [*:0]const u8) ?[]const u8 {
    if (os == .wasi or os == .freestanding) return null;
    const v = std.c.getenv(var_name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// The user's home folder ($HOME; %USERPROFILE% on Windows).
pub fn home() ?[]const u8 {
    return if (is_windows) env("USERPROFILE") orelse env("HOME") else env("HOME");
}

/// `path` with a leading "~/" (or "~\" on Windows) made the home folder;
/// otherwise as it is.
pub fn expandHome(a: Allocator, path: []const u8) []const u8 {
    if (path.len < 2 or path[0] != '~' or !(path[1] == '/' or (is_windows and path[1] == '\\'))) return path;
    const h = home() orelse return path;
    return std.fs.path.join(a, &.{ h, path[2..] }) catch path;
}

/// This machine's name, into `buf`; empty when it cannot be had.
pub fn hostName(buf: *[host_name_max]u8) []const u8 {
    if (is_windows) {
        const n = env("COMPUTERNAME") orelse return "";
        const k = @min(n.len, buf.len);
        @memcpy(buf[0..k], n[0..k]);
        return buf[0..k];
    }
    if (os == .wasi or !@hasDecl(std.posix, "HOST_NAME_MAX")) return "";
    return std.posix.gethostname(buf[0..std.posix.HOST_NAME_MAX]) catch "";
}

/// Graven's own per-user folders (see the table above).
pub const AppDir = enum {
    /// Settings that follow the user (roaming on Windows).
    config,
    /// Settings for this machine only.
    machine,
    /// What Graven keeps that is not settings (installed fonts' records).
    data,
    /// What can be made again (the font index, the message of the day).
    cache,
};

/// The folder of kind `which`, from `a`; error.NoHome when the variables
/// it is found from are unset.
pub fn appDir(a: Allocator, which: AppDir) ![]u8 {
    if (is_windows) {
        const roaming = env("APPDATA");
        const local = env("LOCALAPPDATA") orelse roaming orelse return error.NoHome;
        return std.fs.path.join(a, &.{ if (which == .config) roaming orelse local else local, "Graven" });
    }
    if (is_macos) {
        const h = home() orelse return error.NoHome;
        return switch (which) {
            .cache => std.fs.path.join(a, &.{ h, "Library", "Caches", "Graven" }),
            else => std.fs.path.join(a, &.{ h, "Library", "Application Support", "Graven" }),
        };
    }
    const xdg: [*:0]const u8, const under_home: []const u8 = switch (which) {
        .config, .machine => .{ "XDG_CONFIG_HOME", ".config" },
        .data => .{ "XDG_DATA_HOME", ".local/share" },
        .cache => .{ "XDG_CACHE_HOME", ".cache" },
    };
    if (env(xdg)) |x| return std.fs.path.join(a, &.{ x, "graven" });
    return std.fs.path.join(a, &.{ home() orelse return error.NoHome, under_home, "graven" });
}

/// The path of `file` in Graven's folder of kind `which`.
pub fn appFile(a: Allocator, which: AppDir, file: []const u8) ![]u8 {
    const d = try appDir(a, which);
    defer a.free(d);
    return std.fs.path.join(a, &.{ d, file });
}

/// The OS's per-user font folder, where fonts installed for the user go
/// and every application finds them.
pub fn userFontDir(a: Allocator) ![]u8 {
    if (is_windows) return std.fs.path.join(a, &.{ env("LOCALAPPDATA") orelse return error.NoHome, "Microsoft", "Windows", "Fonts" });
    if (is_macos) return std.fs.path.join(a, &.{ home() orelse return error.NoHome, "Library", "Fonts" });
    if (env("XDG_DATA_HOME")) |x| return std.fs.path.join(a, &.{ x, "fonts" });
    return std.fs.path.join(a, &.{ home() orelse return error.NoHome, ".local", "share", "fonts" });
}

/// A font folder, and whether it is the user's own (else the system's).
pub const FontDir = struct { path: []const u8, user: bool };

/// The font folders of this system, the user's own first.
pub fn fontDirs(a: Allocator) ![]const FontDir {
    var dirs: std.ArrayList(FontDir) = .empty;
    if (userFontDir(a)) |u| try dirs.append(a, .{ .path = u, .user = true }) else |_| {}
    if (is_windows) {
        try dirs.append(a, .{ .path = try std.fs.path.join(a, &.{ env("WINDIR") orelse "C:\\Windows", "Fonts" }), .user = false });
    } else if (is_macos) {
        try dirs.append(a, .{ .path = "/System/Library/Fonts", .user = false });
        try dirs.append(a, .{ .path = "/Library/Fonts", .user = false });
    } else {
        // The older per-user folder, still read by fontconfig.
        if (home()) |h| try dirs.append(a, .{ .path = try std.fs.path.join(a, &.{ h, ".fonts" }), .user = true });
        try dirs.append(a, .{ .path = "/usr/share/fonts", .user = false });
        try dirs.append(a, .{ .path = "/usr/local/share/fonts", .user = false });
    }
    return dirs.items;
}

/// Whether the font file at `path` is in one of the user's font folders
/// (by its path alone; nothing is read).
pub fn isUserFontPath(path: []const u8) bool {
    if (is_windows) return std.ascii.findIgnoreCase(path, "\\Microsoft\\Windows\\Fonts\\") != null;
    if (is_macos) return std.mem.indexOf(u8, path, "/Library/Fonts/") != null and !std.mem.startsWith(u8, path, "/Library/") and !std.mem.startsWith(u8, path, "/System/");
    return std.mem.indexOf(u8, path, "/.local/share/fonts/") != null or std.mem.indexOf(u8, path, "/.fonts/") != null;
}

/// `path` made absolute, its links followed, from `a`; null when it does
/// not lead to a file.
pub fn absolutePath(io: std.Io, a: Allocator, path: []const u8) ?[:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch null;
}

const testing = std.testing;

test "Graven's folders end in its own name" {
    if (home() == null and !is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    inline for (.{ AppDir.config, AppDir.machine, AppDir.data, AppDir.cache }) |w| {
        const d = try appDir(a, w);
        defer a.free(d);
        try testing.expect(std.ascii.endsWithIgnoreCase(d, "graven"));
    }
    const f = try appFile(a, .cache, "motd");
    defer a.free(f);
    try testing.expect(std.mem.endsWith(u8, f, "motd"));
}

test "a path from home" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/abs/x", expandHome(a, "/abs/x"));
    try testing.expectEqualStrings("~x", expandHome(a, "~x"));
    if (home()) |h| try testing.expect(std.mem.startsWith(u8, expandHome(a, "~/fonts"), h));
}

test "user font paths" {
    if (is_windows or is_macos) return error.SkipZigTest;
    try testing.expect(isUserFontPath("/home/u/.local/share/fonts/A.ttf"));
    try testing.expect(isUserFontPath("/home/u/.fonts/A.ttf"));
    try testing.expect(!isUserFontPath("/usr/share/fonts/truetype/A.ttf"));
}

test "the monotonic clock goes forward" {
    const t0 = monotonicNs();
    const t1 = monotonicNs();
    try testing.expect(t1 >= t0);
}

test "an absolute path" {
    const io = std.testing.io;
    const p = absolutePath(io, testing.allocator, "build.zig") orelse return error.SkipZigTest;
    defer testing.allocator.free(p);
    try testing.expect(std.fs.path.isAbsolute(p));
    try testing.expect(absolutePath(io, testing.allocator, "no/such/file") == null);
}

test "a host name, or nothing" {
    var buf: [host_name_max]u8 = undefined;
    _ = hostName(&buf);
}
