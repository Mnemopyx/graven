//! The screen's colour profile: which one is in use (the system's, an ICC
//! file chosen for this machine, or none), loading it into the display
//! correction (`display.setProfile`), and following the window when it
//! moves to a screen with another profile.
//!
//! Who converts colours differs by system. On X11 and Windows nobody does:
//! the system only publishes the screen's profile (X11's `_ICC_PROFILE`
//! on the root window, set by colord or a calibration tool), so Graven
//! applies it itself. A Wayland compositor that gives a profile at all
//! (the colour-management protocol) converts every surface that does not
//! say otherwise, as macOS converts windows, so Graven leaves those alone;
//! a compositor that gives none (COSMIC, today) converts nothing, and a
//! profile file chosen by hand is then the way to show colours right.
//! A chosen file is applied with its calibration curves (`vcgt`), since a
//! desktop that manages nothing loads none.

const std = @import("std");
const dvui = @import("dvui");
const platform = @import("graven_platform");
const icc = @import("icc.zig");
const display = @import("display.zig");

pub const Choice = enum { system, none, file };

var choice: Choice = .system;
var file_buf: [1024]u8 = undefined;
var file_len: usize = 0;

/// What happened when the profile was last loaded, for the Display
/// correction window.
var status_buf: [200]u8 = undefined;
var status_len: usize = 0;

pub fn get() Choice {
    return choice;
}

/// The chosen file's path (when the choice is `file`).
pub fn file() []const u8 {
    return file_buf[0..file_len];
}

pub fn status() []const u8 {
    return status_buf[0..status_len];
}

/// Sets the choice; `path` for `file`. Load it with `load`.
pub fn set(c: Choice, path: []const u8) void {
    choice = c;
    if (c == .file) {
        file_len = @min(path.len, file_buf.len);
        @memcpy(file_buf[0..file_len], path[0..file_len]);
    }
}

/// The choice as the config keeps it: "system", "none", or a path.
pub fn configValue() []const u8 {
    return switch (choice) {
        .system => "system",
        .none => "none",
        .file => file(),
    };
}

pub fn fromConfig(v: []const u8) void {
    if (std.mem.eql(u8, v, "system") or v.len == 0) set(.system, "") else if (std.mem.eql(u8, v, "none")) set(.none, "") else set(.file, v);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&status_buf, fmt, args) catch status_buf[0..];
    status_len = s.len;
    std.log.info("screen profile: {s}", .{s});
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.Malformed => "not a colour profile, or a damaged one",
        error.NotRgbDisplay => "not an RGB screen's profile",
        error.TablesOnly => "a profile of lookup tables only, which Graven cannot use yet",
        error.FileNotFound => "not found",
        else => @errorName(err),
    };
}

/// Puts profile bytes `bytes` in use, or says why not.
fn use(bytes: []const u8, source: display.ProfileSource, label: []const u8, calibration: bool) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const p = icc.parse(arena.allocator(), bytes) catch |err| {
        display.setProfile(null, "", source);
        say("{s}: {s}; colours are sent as they are.", .{ label, describe(err) });
        return;
    };
    const cal = calibration and p.calibration != null;
    const t = icc.Transform.init(p, .{ .calibration = cal }) orelse {
        display.setProfile(null, "", source);
        say("{s}: its primaries cannot be inverted; colours are sent as they are.", .{label});
        return;
    };
    const name = if (p.name.len > 0) p.name else label;
    display.setProfile(t, name, source);
    switch (source) {
        .system => say("The system's: {s}.", .{name}),
        .file => say("{s}{s}.", .{ name, if (cal) ", with its calibration curves" else "" }),
    }
}

/// Loads the chosen profile for `window` (an SDL window), or none.
pub fn load(window: anytype) void {
    switch (choice) {
        .none => {
            display.setProfile(null, "", .system);
            say("None: colours are sent as they are, for an sRGB screen.", .{});
        },
        .file => {
            const path = file();
            const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, std.heap.page_allocator, .limited(16 << 20)) catch |err| {
                display.setProfile(null, "", .file);
                say("{s}: {s}; colours are sent as they are.", .{ std.fs.path.basename(path), describe(err) });
                return;
            };
            defer std.heap.page_allocator.free(bytes);
            use(bytes, .file, std.fs.path.basename(path), true);
        },
        .system => {
            if (dvui.backend.kind != .sdl3) {
                display.setProfile(null, "", .system);
                say("No system profile here.", .{});
                return;
            }
            const c = dvui.backend.c;
            const drv = c.SDL_GetCurrentVideoDriver();
            const driver: []const u8 = if (drv != null) std.mem.span(drv) else "";
            var size: usize = 0;
            const data = c.SDL_GetWindowICCProfile(window, &size);
            defer if (data != null) c.SDL_free(data);
            const bytes: []const u8 = if (data) |d| @as([*]const u8, @ptrCast(d))[0..size] else &.{};
            const manages = std.mem.eql(u8, driver, "wayland") and bytes.len > 0 or std.mem.eql(u8, driver, "cocoa");
            if (manages) {
                display.setProfile(null, "", .system);
                say("The desktop converts colours to the screen itself; Graven sends them as they are.", .{});
                return;
            }
            if (bytes.len == 0) {
                display.setProfile(null, "", .system);
                say("The desktop gives no profile for this screen. If colours look wrong, choose the screen's profile file.", .{});
                return;
            }
            use(bytes, .system, "The system's profile", false);
        },
    }
}

var changed = std.atomic.Value(bool).init(false);
var watching = false;

fn watch(_: ?*anyopaque, ev: [*c]dvui.backend.c.SDL_Event) callconv(.c) bool {
    const c = dvui.backend.c;
    const t = ev.*.type;
    if (t == c.SDL_EVENT_WINDOW_ICCPROF_CHANGED or t == c.SDL_EVENT_WINDOW_DISPLAY_CHANGED) changed.store(true, .release);
    return true;
}

/// Watches for the screen's profile changing (or the window moving to
/// another screen); `takeChanged` then says so, once.
pub fn startWatching() void {
    if (watching or dvui.backend.kind != .sdl3) return;
    watching = dvui.backend.c.SDL_AddEventWatch(watch, null);
}

pub fn takeChanged() bool {
    return changed.swap(false, .acq_rel);
}

/// A profile file found in the system's folders: its path and name.
pub const Found = struct { path: []const u8, name: []const u8 };

/// The screen profiles in the system's folders (and one folder down),
/// from `a`; at most 64.
pub fn findProfiles(a: std.mem.Allocator) []const Found {
    var out: std.ArrayList(Found) = .empty;
    const dirs = platform.colourProfileDirs(a) catch return &.{};
    for (dirs) |d| scan(a, &out, d, 1);
    return out.items;
}

fn scan(a: std.mem.Allocator, out: *std.ArrayList(Found), path: []const u8, depth: u8) void {
    const io = dvui.io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (out.items.len >= 64) return;
        const full = std.fs.path.join(a, &.{ path, e.name }) catch return;
        if (e.kind == .directory) {
            if (depth > 0) scan(a, out, full, depth - 1);
            continue;
        }
        const ext = std.fs.path.extension(e.name);
        if (!std.ascii.eqlIgnoreCase(ext, ".icc") and !std.ascii.eqlIgnoreCase(ext, ".icm")) continue;
        const bytes = dir.readFileAlloc(io, e.name, a, .limited(16 << 20)) catch continue;
        // Only RGB screens' profiles of the kind Graven reads.
        const p = icc.parse(a, bytes) catch continue;
        out.append(a, .{ .path = full, .name = if (p.name.len > 0) p.name else e.name }) catch return;
    }
}
