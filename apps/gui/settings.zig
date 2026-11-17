//! Where Graven's config files live, and reading and writing them.
//!
//! Two TOML files: `shared.toml`, preferences that may follow the user
//! between machines, and `local.toml`, what belongs to this machine (its
//! screen, its window layout). A key in the local file overrides the same
//! key in the shared one. They live in:
//!
//! * Linux and other Unix: `$XDG_CONFIG_HOME/graven/` (else
//!   `~/.config/graven/`), both files;
//! * macOS: `~/Library/Application Support/Graven/`, both files;
//! * Windows: `%APPDATA%\Graven\shared.toml` (roaming) and
//!   `%LOCALAPPDATA%\Graven\local.toml`;
//! * anywhere: `$GRAVEN_CONFIG_DIR/`, both files, when it is set.
//!
//! The local file may name another folder for the shared one, a synced or
//! version-controlled folder, say:
//!
//!     [config]
//!     shared_dir = "~/Sync/graven"
//!
//! `~` is the home folder; a relative path is taken from the local file's
//! folder. When that folder is missing (a drive not mounted), shared
//! settings are neither read nor written, and the user is told: Graven
//! does not make the folder, which would split the settings in two.
//!
//! A file that cannot be read as TOML is reported and left untouched for
//! the session: Graven never writes over what it could not read.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("graven_config");
const toml = config.toml;
pub const Value = toml.Value;

pub const Store = struct {
    gpa: std.mem.Allocator,
    files: config.Layered,
    shared_path: ?[]const u8 = null,
    local_path: ?[]const u8 = null,
    /// Each file's text as last read or written, so an unchanged file is
    /// not rewritten.
    shared_text: []const u8 = "",
    local_text: []const u8 = "",
    /// A file that could not be read: why, and it is not written.
    shared_problem: ?[]const u8 = null,
    local_problem: ?[]const u8 = null,

    pub fn deinit(s: *Store) void {
        s.files.deinit();
        for ([_]?[]const u8{ s.shared_path, s.local_path, s.shared_problem, s.local_problem }) |p| if (p) |x| s.gpa.free(x);
        s.gpa.free(s.shared_text);
        s.gpa.free(s.local_text);
    }

    pub fn get(s: *const Store, key: []const u8) ?toml.Value {
        return s.files.get(key);
    }

    pub fn put(s: *Store, key: []const u8, value: toml.Value, home: config.Home) void {
        s.files.put(key, value, home) catch {};
    }

    /// Every key either file holds (each may appear twice).
    pub fn keys(s: *const Store, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for ([_]*const config.toml.Doc{ &s.files.shared, &s.files.local }) |d| {
            for (d.entries.items) |e| try out.append(a, e.key);
        }
        return out.items;
    }

    /// Drops the local file's keys under `prefix` (its overrides), so the
    /// shared file's values are in force again. How many went.
    pub fn dropLocal(s: *Store, prefix: []const u8) usize {
        return s.files.local.removePrefix(prefix);
    }

    /// Writes each file whose text has changed (and that was readable).
    /// Returns a problem to show, if any.
    pub fn save(s: *Store, io: std.Io) ?[]const u8 {
        var trouble: ?[]const u8 = null;
        if (s.shared_problem == null) if (s.shared_path) |p| {
            if (writeIfChanged(s.gpa, io, p, &s.files.shared, &s.shared_text)) |msg| trouble = msg;
        };
        if (s.local_problem == null) if (s.local_path) |p| {
            if (writeIfChanged(s.gpa, io, p, &s.files.local, &s.local_text)) |msg| trouble = msg;
        };
        return trouble;
    }

    /// What to tell the user about the files, if anything went wrong
    /// reading them.
    pub fn problem(s: *const Store) ?[]const u8 {
        return s.local_problem orelse s.shared_problem;
    }
};

/// Finds and reads both files. Missing files are simply empty.
pub fn load(gpa: std.mem.Allocator, io: std.Io) Store {
    var s: Store = .{ .gpa = gpa, .files = .init(gpa) };
    const paths = filePaths(gpa) catch return s;
    s.shared_path = paths.shared;
    s.local_path = paths.local;
    // The local file first: it may say where the shared one is.
    readInto(gpa, io, paths.local, &s.files.local, &s.local_text, &s.local_problem);
    if (s.files.local.get("config.shared_dir")) |v| {
        const dir = if (v == .string) resolveDir(gpa, v.string, std.fs.path.dirname(paths.local) orelse ".") catch null else null;
        if (dir == null) {
            s.shared_problem = gpa.dupe(u8, "config.shared_dir in local.toml is not a folder name; shared settings are not used.") catch null;
            return s;
        }
        defer gpa.free(dir.?);
        std.Io.Dir.cwd().access(io, dir.?, .{}) catch {
            s.shared_problem = std.fmt.allocPrint(gpa, "Shared settings folder \"{s}\" (local.toml) is not there: shared settings unused.", .{v.string}) catch null;
            return s;
        };
        const p = std.fs.path.join(gpa, &.{ dir.?, "shared.toml" }) catch return s;
        gpa.free(paths.shared);
        s.shared_path = p;
    }
    readInto(gpa, io, s.shared_path.?, &s.files.shared, &s.shared_text, &s.shared_problem);
    return s;
}

/// A folder named in a config file: `~` is the home folder, and a relative
/// path is taken from `base`.
pub fn resolveDir(gpa: std.mem.Allocator, name: []const u8, base: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, name, " \t");
    if (t.len == 0) return error.Empty;
    if (t[0] == '~' and (t.len == 1 or t[1] == '/' or t[1] == '\\')) {
        const home = env(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse return error.NoHome;
        return std.fs.path.join(gpa, &.{ home, if (t.len > 2) t[2..] else "" });
    }
    if (std.fs.path.isAbsolute(t)) return gpa.dupe(u8, t);
    return std.fs.path.join(gpa, &.{ base, t });
}

fn readInto(gpa: std.mem.Allocator, io: std.Io, path: []const u8, doc: *toml.Doc, text: *[]const u8, problem: *?[]const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        if (err != error.FileNotFound) problem.* = std.fmt.allocPrint(gpa, "{s} could not be read ({s}); it is left as it is.", .{ std.fs.path.basename(path), @errorName(err) }) catch null;
        return;
    };
    var diag: toml.Diagnostic = .{};
    const parsed = toml.parse(gpa, bytes, &diag) catch {
        problem.* = std.fmt.allocPrint(gpa, "{s}, line {d}: {s}; it is left as it is.", .{ std.fs.path.basename(path), diag.line, diag.message }) catch null;
        gpa.free(bytes);
        return;
    };
    doc.deinit();
    doc.* = parsed;
    text.* = bytes;
}

const header =
    \\# Graven settings. Graven rewrites this file when a setting changes:
    \\# keys it does not know are kept, comments are not.
    \\
;

fn writeIfChanged(gpa: std.mem.Allocator, io: std.Io, path: []const u8, doc: *const toml.Doc, last: *[]const u8) ?[]const u8 {
    const body = doc.toText(gpa) catch return null;
    defer gpa.free(body);
    if (body.len == 0 and last.len == 0) return null;
    const text = std.mem.concat(gpa, u8, &.{ header, body }) catch return null;
    if (std.mem.eql(u8, text, last.*) or std.mem.eql(u8, body, last.*)) {
        gpa.free(text);
        return null;
    }
    const dir = std.fs.path.dirname(path) orelse ".";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {
        gpa.free(text);
        return "The settings folder could not be made.";
    };
    // Written beside it, then renamed over it, so a crash never leaves half
    // a file.
    const tmp = std.fmt.allocPrint(gpa, "{s}.new", .{path}) catch {
        gpa.free(text);
        return null;
    };
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch {
        gpa.free(text);
        return "The settings could not be written.";
    };
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io) catch {
        gpa.free(text);
        return "The settings could not be written.";
    };
    gpa.free(last.*);
    last.* = text;
    return null;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

const Paths = struct { shared: []const u8, local: []const u8 };

/// Where the two files are on this system.
pub fn filePaths(gpa: std.mem.Allocator) !Paths {
    if (env("GRAVEN_CONFIG_DIR")) |d| return both(gpa, d);
    switch (builtin.os.tag) {
        .windows => {
            const roaming = env("APPDATA") orelse return error.NoHome;
            const local = env("LOCALAPPDATA") orelse roaming;
            return .{
                .shared = try std.fs.path.join(gpa, &.{ roaming, "Graven", "shared.toml" }),
                .local = try std.fs.path.join(gpa, &.{ local, "Graven", "local.toml" }),
            };
        },
        .macos => {
            const home = env("HOME") orelse return error.NoHome;
            const d = try std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "Graven" });
            defer gpa.free(d);
            return both(gpa, d);
        },
        else => {
            if (env("XDG_CONFIG_HOME")) |x| {
                const d = try std.fs.path.join(gpa, &.{ x, "graven" });
                defer gpa.free(d);
                return both(gpa, d);
            }
            const home = env("HOME") orelse return error.NoHome;
            const d = try std.fs.path.join(gpa, &.{ home, ".config", "graven" });
            defer gpa.free(d);
            return both(gpa, d);
        },
    }
}

fn both(gpa: std.mem.Allocator, dir: []const u8) !Paths {
    return .{
        .shared = try std.fs.path.join(gpa, &.{ dir, "shared.toml" }),
        .local = try std.fs.path.join(gpa, &.{ dir, "local.toml" }),
    };
}
