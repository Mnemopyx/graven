//! The message of the day on the start screen: news for this version of
//! Graven, fetched from a URL (by default the repository's
//! `motd/<version>.md`) at most once a day, cached on this machine, and
//! shown from the cache at once. Until there is one, a built-in message.
//!
//! The fetch runs on a thread of its own, through the environment's
//! proxies; the start screen calls `poll` each frame to pick up what it
//! brought. `GRAVEN_MOTD_URL` names another URL (`{version}` in it is
//! replaced), or `none` for no fetching.
//!
//! The cache: `$XDG_CACHE_HOME/graven/motd/<version>.md` (else
//! `~/.cache/graven/…`; on macOS `~/Library/Caches/Graven/motd/`, on
//! Windows `%LOCALAPPDATA%\Graven\motd\`).

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const default_url = "https://raw.githubusercontent.com/mnemopyx/graven/main/motd/{version}.md";

/// What shows before any message has been fetched.
pub const builtin_text =
    \\# Welcome to Graven
    \\
    \\Compose control-panel and keycap legends from Unicode glyphs, and make them as exact vector geometry: SVG, 3MF for colour printing, STEP.
    \\
    \\Start a canvas on the right, in millimetres or inches, or open a document. Legends are typed in LaTeX as KaTeX takes it (math between dollars); Ctrl+\ edits an equation or a key's text in place on the canvas.
    \\
    \\News for this version shows here once it has been fetched.
;

/// Where the message shown came from.
pub const Source = enum { builtin, cache, fetched };

var gpa: Allocator = undefined;
var io: std.Io = undefined;
var text_owned: ?[]u8 = null;
var source: Source = .builtin;
var cache_path: ?[]u8 = null;
var url: ?[]u8 = null;

/// Set by the fetch thread when it is done; `fetched` is then its result
/// (null: it failed), which only the UI thread touches from then on.
var done: std.atomic.Value(bool) = .init(false);
var fetching = false;
var fetched: ?[]u8 = null;
var thread: ?std.Thread = null;

const platform = @import("graven_platform");
const env = platform.env;

fn cacheDir(a: Allocator) ![]u8 {
    return platform.appFile(a, .cache, "motd");
}

/// Shows the cached message for `version`, if there is one, and fetches a
/// newer one when the cache is missing or a day old.
pub fn start(allocator: Allocator, io_: std.Io, version: []const u8) void {
    gpa = allocator;
    io = io_;
    const dir = cacheDir(gpa) catch return;
    defer gpa.free(dir);
    const name = std.fmt.allocPrint(gpa, "{s}.md", .{version}) catch return;
    defer gpa.free(name);
    cache_path = std.fs.path.join(gpa, &.{ dir, name }) catch return;
    var stale = true;
    if (std.Io.Dir.cwd().readFileAlloc(io, cache_path.?, gpa, .limited(64 << 10))) |bytes| {
        text_owned = bytes;
        source = .cache;
        if (std.Io.Dir.cwd().statFile(io, cache_path.?, .{})) |st| {
            const now = std.Io.Clock.real.now(io);
            const age_s = @divTrunc(now.nanoseconds - st.mtime.nanoseconds, std.time.ns_per_s);
            stale = age_s > std.time.s_per_day;
        } else |_| {}
    } else |_| {}
    if (!stale) return;
    const pattern = env("GRAVEN_MOTD_URL") orelse default_url;
    if (std.mem.eql(u8, pattern, "none")) return;
    url = std.mem.replaceOwned(u8, gpa, pattern, "{version}", version) catch return;
    fetching = true;
    thread = std.Thread.spawn(.{}, fetchThread, .{}) catch {
        fetching = false;
        return;
    };
}

fn fetchThread() void {
    defer done.store(true, .release);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The proxies the environment names, as a browser would use them.
    var env_map: std.process.Environ.Map = .init(a);
    for ([_][*:0]const u8{ "https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY" }) |k| {
        if (env(k)) |v| env_map.put(std.mem.span(k), v) catch {};
    }
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    client.initDefaultProxies(a, &env_map) catch {};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = client.fetch(.{ .location = .{ .url = url.? }, .response_writer = &out.writer }) catch return;
    if (res.status != .ok) return;
    const body = out.written();
    if (body.len == 0 or body.len > 64 << 10 or !std.unicode.utf8ValidateSlice(body)) return;
    fetched = gpa.dupe(u8, body) catch return;
    // Kept for next time.
    if (std.fs.path.dirname(cache_path.?)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache_path.?, .data = body }) catch {};
}

/// Takes in what the fetch brought, once it is done. True when it has
/// just finished, either way (redraw).
pub fn poll() bool {
    if (!fetching or !done.load(.acquire)) return false;
    fetching = false;
    if (thread) |t| t.join();
    thread = null;
    // Done either way: what the screen says about it changes.
    const got = fetched orelse return true;
    fetched = null;
    if (text_owned) |old| gpa.free(old);
    text_owned = got;
    source = .fetched;
    return true;
}

/// Whether a fetch is still under way.
pub fn busy() bool {
    return fetching;
}

/// The message to show, Markdown-ish: a `# ` line is a heading, a blank
/// line ends a paragraph.
pub fn text() []const u8 {
    return text_owned orelse builtin_text;
}

pub fn from() Source {
    return if (text_owned == null) .builtin else source;
}

/// Frees what it holds (at exit), waiting for a fetch under way.
pub fn deinit() void {
    if (thread) |t| t.join();
    thread = null;
    if (fetched) |f| gpa.free(f);
    if (text_owned) |t| gpa.free(t);
    if (cache_path) |p| gpa.free(p);
    if (url) |u| gpa.free(u);
    text_owned = null;
    fetched = null;
    cache_path = null;
    url = null;
}
