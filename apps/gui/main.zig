//! Graven GUI editor, on DVUI over SDL3.
//!
//! Immediate mode: the panes are rebuilt from the model every frame, so the
//! model stays the single source of truth. Edits go through the layout
//! library's actions, and the panel is re-solved when the model's revision
//! moves. Legends on the canvas are Graven's own outlines, filled nonzero;
//! DVUI's text is for the interface only.
//!
//! This first slice follows one workflow: open the PC keyboard sample, look
//! around it, select tiles, edit their legends, and try other fonts.

const std = @import("std");
const dvui = @import("dvui");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const samples = @import("graven_samples");
const desktop = @import("desktop.zig");

const geom = engine.geom;
const Model = layout.Model;
const TileId = layout.TileId;

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
/// Runs before SDL starts. SDL 3.4 falls back to XWayland on compositors
/// without the fifo-v1 protocol (COSMIC, for one), where it cannot see the
/// display scale; an editor wants correct scaling over frame pacing, so
/// Wayland comes first. SDL_VIDEO_DRIVER in the environment still wins.
fn start() dvui.App.StartOptions {
    if (dvui.backend.kind == .sdl3) {
        const c = dvui.backend.c;
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");
        // The identifier becomes the Wayland app id, which the desktop uses
        // to find Graven's .desktop file and icon.
        _ = c.SDL_SetAppMetadata("Graven", engine.version, "com.mnemopyx.graven");
    }
    return .{
        .size = .{ .w = 1500, .h = 820 },
        .min_size = .{ .w = 800, .h = 500 },
        .title = "Graven",
        .app = "Graven",
        .org = "com.mnemopyx.graven",
    };
}

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

/// The bundled example font, relative to the repository root. The GUI opens
/// with an installed Inter Medium if fontconfig finds one (system or user
/// fonts), else this file when run from the repository root, else the first
/// font found.
const example_font = "examples/fonts/Inter-Medium.otf";

const Font = struct {
    name: []const u8,
    path: []const u8,
    /// Face index within a collection (.ttc, .otc); 0 for a single font.
    index: u32 = 0,
    family: []const u8 = "",
    style: []const u8 = "",
};

const State = struct {
    gpa: std.mem.Allocator,
    fonts: []Font = &.{},
    font_choice: usize = 0,
    font_loaded: ?usize = null,
    face: ?*engine.Face = null,
    faces: [1]*engine.Face = undefined,
    model: Model,
    labels: ?layout.Labels = null,
    /// One solve per panel, in the panel's own frame.
    placed: std.ArrayList(layout.place.Placed) = .empty,
    placed_rev: u64 = std.math.maxInt(u64),
    /// Labels whose ink reaches into the worksheet's margins.
    intrusions: []layout.drc.MarginIntrusion = &.{},
    /// Panels out of compliance, as sheet and margin changes can leave them.
    panel_issues: []layout.drc.PanelIssue = &.{},
    /// The canvas tool, and a rectangle being dragged out with it.
    tool: Tool = .select,
    drag: ?struct { start: geom.Point, at: geom.Point } = null,
    /// The pointer's position on the worksheet, mm; null off the canvas.
    mouse: ?geom.Point = null,
    /// Where the pointer went down on the canvas, mm.
    press_at: ?geom.Point = null,
    /// A selected panel being dragged to a new place: shown at its preview
    /// position, committed on release.
    moving: ?struct { panel: usize, start: geom.Point, at: geom.Point } = null,
    solve_ms: f64 = 0,
    flat: Flat,
    view: View = .{},
    /// The file's name; a new file is untitled until saved or renamed.
    file_name: []const u8 = "untitled",
    /// Whether the user has given the file name and the legend font. Until
    /// then they are the app's choices, shown in italic.
    file_name_set: bool = false,
    font_set: bool = false,
    /// What the tree, canvas, tools and properties are about.
    context: Context = .worksheet,
    /// Tree nodes the user has opened or closed, by context key.
    expanded: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    status: []const u8 = "",
};

/// What a canvas drag does: pick things, or draw out a new panel.
const Tool = enum { select, add_panel };

/// The current context: a node of the component tree.
const Context = union(enum) {
    /// The file: everything, the worksheet included.
    file,
    worksheet,
    panel: usize,
    region: struct { panel: usize, region: usize },
    row: struct { panel: usize, region: usize, row: usize },
    tile: TileId,

    fn key(c: Context) u64 {
        var h: std.hash.Wyhash = .init(0);
        std.hash.autoHash(&h, c);
        return h.final();
    }

    fn eql(a: Context, b: Context) bool {
        return std.meta.eql(a, b);
    }

    fn kindName(c: Context) []const u8 {
        return switch (c) {
            .file => "File",
            .worksheet => "Worksheet",
            .panel => "Panel",
            .region => "Region",
            .row => "Row",
            .tile => "Tile",
        };
    }
};

/// The canvas view: the mm point at the canvas centre, and physical pixels
/// per mm. While `fit` holds a box, the view keeps that box centred and
/// filling the canvas (through window resizes) until the user zooms or pans.
const View = struct {
    cx: f64 = 0,
    cy: f64 = 0,
    ppm: f64 = 0,
    fit: ?geom.Box = null,

    fn toPx(v: View, area: dvui.Rect.Physical, p: geom.Point) dvui.Point.Physical {
        return .{
            .x = @floatCast(area.x + area.w / 2 + (p.x - v.cx) * v.ppm),
            .y = @floatCast(area.y + area.h / 2 - (p.y - v.cy) * v.ppm),
        };
    }

    fn toMm(v: View, area: dvui.Rect.Physical, p: dvui.Point.Physical) geom.Point {
        return .{
            .x = v.cx + (p.x - area.x - area.w / 2) / v.ppm,
            .y = v.cy - (p.y - area.y - area.h / 2) / v.ppm,
        };
    }

    fn rect(v: View, area: dvui.Rect.Physical, b: geom.Box) dvui.Rect.Physical {
        const tl = v.toPx(area, .{ .x = b.x0, .y = b.y1 });
        const br = v.toPx(area, .{ .x = b.x1, .y = b.y0 });
        return .{ .x = tl.x, .y = tl.y, .w = br.x - tl.x, .h = br.y - tl.y };
    }
};

/// Label outlines flattened to polylines in mm, per render, at a tolerance
/// matched to the zoom. Rebuilt when the zoom changes a lot or the panel is
/// re-solved (renders may be freed then).
const Flat = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(*const engine.Render, []const []const geom.Point) = .empty,
    tol: f64 = 0,

    fn reset(f: *Flat, tol: f64) void {
        f.map = .empty;
        _ = f.arena.reset(.retain_capacity);
        f.tol = tol;
    }

    fn get(f: *Flat, r: *const engine.Render, faces: []const *engine.Face) ![]const []const geom.Point {
        if (f.map.get(r)) |c| return c;
        const a = f.arena.allocator();
        var contours: std.ArrayList([]const geom.Point) = .empty;
        for (try r.outlines(a, faces)) |o| for (o.contours) |c| {
            var pts: std.ArrayList(geom.Point) = .empty;
            for (c.segments) |s| try flatten(a, &pts, s, f.tol);
            try contours.append(a, pts.items);
        };
        const out = contours.items;
        try f.map.put(a, r, out);
        return out;
    }
};

/// Appends a segment's points after its start, within `tol` of the curve.
fn flatten(a: std.mem.Allocator, pts: *std.ArrayList(geom.Point), s: geom.Segment, tol: f64) !void {
    switch (s) {
        .line => |p| try pts.append(a, p[1]),
        .quad => |p| {
            const dev = 0.25 * @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol)))));
            for (1..n + 1) |i| {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, .{
                    .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x,
                    .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y,
                });
            }
        },
        .cubic => |p| {
            const d1 = @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const d2 = @sqrt(sq(p[1].x - 2 * p[2].x + p[3].x) + sq(p[1].y - 2 * p[2].y + p[3].y));
            const dev = 0.75 * @max(d1, d2);
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol)))));
            for (1..n + 1) |i| {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, .{
                    .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
                    .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
                });
            }
        },
    }
}

fn sq(x: f64) f64 {
    return x * x;
}

var state: State = undefined;

fn init(win: *dvui.Window) !void {
    const gpa = win.gpa;
    initWindowFrame(win);
    // Match the desktop now, then follow its changes.
    main_window = win;
    const settings = desktop.read(gpa, dvui.io);
    applyDesktop(win, settings);
    desktop.watch(dvui.io, settings, wakeGui);
    state = .{ .gpa = gpa, .model = .init(gpa), .flat = .{ .arena = .init(gpa) } };
    const installed: []Font = listFonts(gpa) catch &.{};
    if (std.Io.Dir.cwd().access(dvui.io, example_font, .{})) |_| {
        const fonts = try gpa.alloc(Font, installed.len + 1);
        fonts[0] = .{ .name = "Inter Medium (examples)", .path = example_font, .family = "Inter", .style = "Medium" };
        @memcpy(fonts[1..], installed);
        state.fonts = fonts;
    } else |_| {
        state.fonts = installed;
    }
    state.font_choice = defaultFont(state.fonts);
}

/// Adds the sample PC keyboard as a new panel and makes it the context.
fn loadSample() !void {
    const main_style = try state.model.addStyle("legend", .{ .upright = 0, .cap_height = 2.6 });
    const small = try state.model.addStyle("legend words", .{ .upright = 0, .cap_height = 1.6 });
    const pi = try samples.pc_keyboard.build(state.gpa, &state.model, .{ .main = main_style, .small = small });
    // Top-left of the sheet, 20 mm in.
    const panel = state.model.panels.items[pi];
    try state.model.movePanel(pi, .{ .x = 20, .y = state.model.sheet.h - 20 - panel.h });
    state.context = .{ .panel = pi };
    state.view.fit = state.model.panels.items[pi].box();
}

fn deinit(_: *dvui.Window) void {
    clearPlaced();
    state.placed.deinit(state.gpa);
    if (state.labels) |*l| l.deinit();
    if (state.face) |f| f.deinit();
    state.flat.arena.deinit();
    state.expanded.deinit(state.gpa);
    state.model.deinit();
}

/// The best match for Inter Medium, preferring installed fonts (they come
/// after the bundled one) and exact names: Inter Medium, then any Inter
/// family in Medium, then any Inter, then the first font.
fn defaultFont(fonts: []const Font) usize {
    var best: usize = 0;
    var best_score: u8 = 0;
    for (fonts, 0..) |f, i| {
        const inter = std.mem.startsWith(u8, f.family, "Inter") and !std.mem.startsWith(u8, f.family, "Inter Display");
        const medium = std.mem.eql(u8, f.style, "Medium");
        const installed: u8 = if (std.mem.eql(u8, f.path, example_font)) 0 else 1;
        const score: u8 = if (inter and medium and std.mem.eql(u8, f.family, "Inter"))
            6 + installed
        else if (inter and medium)
            4 + installed
        else if (inter)
            2 + installed
        else
            0;
        if (score > best_score) {
            best = i;
            best_score = score;
        }
    }
    return best;
}

/// Installed outline fonts from fontconfig (system and user folders, such
/// as ~/.local/share/fonts), sorted by name. Each face of a collection is
/// listed; a variable font is listed once, at its default instance.
fn listFonts(gpa: std.mem.Allocator) ![]Font {
    const r = try std.process.run(gpa, dvui.io, .{ .argv = &.{ "fc-list", "--format", "%{family[0]}\t%{style[0]}\t%{index}\t%{file}\n" } });
    defer gpa.free(r.stderr);
    var list: std.ArrayList(Font) = .empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const family = fields.next() orelse continue;
        const style = fields.next() orelse continue;
        const index = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const path = fields.rest();
        const ext = std.fs.path.extension(path);
        const known = for ([_][]const u8{ ".otf", ".ttf", ".ttc", ".otc" }) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) break true;
        } else false;
        // Named instances of a variable font carry the instance above bit 16.
        if (!known or index >> 16 != 0) continue;
        const user = std.mem.indexOf(u8, path, "/.local/share/fonts/") != null or std.mem.indexOf(u8, path, "/.fonts/") != null;
        const name = try std.fmt.allocPrint(gpa, "{s} {s}{s}", .{ family, style, if (user) " (user)" else "" });
        try list.append(gpa, .{ .name = name, .path = path, .index = index, .family = family, .style = style });
    }
    std.mem.sort(Font, list.items, {}, struct {
        fn less(_: void, x: Font, y: Font) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return list.toOwnedSlice(gpa);
}

/// Loads the chosen font if it changed, and re-solves when the model or the
/// font changed.
fn update() !void {
    if (state.font_loaded != state.font_choice and state.fonts.len > 0) {
        const f = state.fonts[state.font_choice];
        const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, f.path, state.gpa, .limited(64 << 20));
        defer state.gpa.free(bytes);
        const face = try engine.Face.init(state.gpa, bytes, f.index);
        clearPlaced();
        if (state.labels) |*l| l.deinit();
        if (state.face) |old| old.deinit();
        state.face = face;
        state.faces = .{face};
        state.labels = .init(state.gpa, &state.faces);
        state.font_loaded = state.font_choice;
        state.placed_rev = std.math.maxInt(u64);
    }
    const labels = if (state.labels) |*l| l else return;
    if (state.placed_rev == state.model.revision) return;
    const t0: std.Io.Timestamp = .now(dvui.io, .awake);
    clearPlaced();
    for (0..state.model.panels.items.len) |pi| {
        try state.placed.append(state.gpa, try layout.solve(state.gpa, &state.model, pi, labels));
    }
    state.intrusions = try layout.drc.marginIntrusions(state.gpa, &state.model, state.placed.items);
    state.panel_issues = try layout.drc.panelIssues(state.gpa, &state.model);
    state.solve_ms = @as(f64, @floatFromInt(t0.untilNow(dvui.io, .awake).toNanoseconds())) / 1e6;
    state.placed_rev = state.model.revision;
    state.flat.reset(state.flat.tol);
}

fn clearPlaced() void {
    state.gpa.free(state.intrusions);
    state.intrusions = &.{};
    state.gpa.free(state.panel_issues);
    state.panel_issues = &.{};
    for (state.placed.items) |*p| p.deinit();
    state.placed.clearRetainingCapacity();
    state.placed_rev = std.math.maxInt(u64);
}

/// A placed tile and the panel it is on.
const Found = struct { panel: usize, tile: *const layout.place.PlacedTile };

fn findTile(id: TileId) ?Found {
    for (state.placed.items, 0..) |*p, pi| if (p.findTile(id)) |t| return .{ .panel = pi, .tile = t };
    return null;
}

/// Where panel `pi` sits on the worksheet: its origin, or its preview
/// position while it is being dragged (whole millimetres of travel).
fn panelOrigin(pi: usize) geom.Point {
    const o = state.model.panels.items[pi].origin;
    if (state.moving) |mv| if (mv.panel == pi) return .{ .x = o.x + @round(mv.at.x - mv.start.x), .y = o.y + @round(mv.at.y - mv.start.y) };
    return o;
}

fn panelBox(pi: usize) geom.Box {
    const p = state.model.panels.items[pi];
    const o = panelOrigin(pi);
    return .{ .x0 = o.x, .y0 = o.y, .x1 = o.x + p.w, .y1 = o.y + p.h };
}

/// A box in panel `pi`'s frame, moved onto the worksheet.
fn onSheet(pi: usize, b: geom.Box) geom.Box {
    const o = panelOrigin(pi);
    return .{ .x0 = b.x0 + o.x, .y0 = b.y0 + o.y, .x1 = b.x1 + o.x, .y1 = b.y1 + o.y };
}

fn frame() !dvui.App.Result {
    if (desktop.take()) |s| applyDesktop(dvui.currentWindow(), s);
    try update();

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();

    if (titleBar()) |r| return r;

    {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();
        treePane();
        canvas();
        try propertiesPane();
    }
    statusBar();
    return .ok;
}

// The title bar -----------------------------------------------------------
//
// Like a GTK header bar: the window has no native frame, and Graven draws
// one bar holding its menus, the title, and at the right end the window
// controls in a plain native style. SDL's hit test tells the window manager
// which parts of the bar drag the window and which window edges resize it.

/// The title bar's rectangle and the controls on it, in physical pixels,
/// from the last frame: the hit test reads them.
var frame_bar: dvui.Rect.Physical = .{};
var frame_holes: [16]dvui.Rect.Physical = undefined;
var frame_hole_count: usize = 0;
/// Physical pixels per window coordinate (SDL's hit test gives points).
var frame_density: f32 = 1;

const title_height = 34;
/// Width of the window edges that resize it, window coordinates.
const resize_edge = 6;

fn initWindowFrame(win: *dvui.Window) void {
    if (dvui.backend.kind != .sdl3) return;
    const c = dvui.backend.c;
    const window = win.backend.impl.window;
    _ = c.SDL_SetWindowTitle(window, "untitled — Graven");
    if (std.c.getenv("GRAVEN_NATIVE_FRAME") != null) return;
    _ = c.SDL_SetWindowBordered(window, false);
    _ = c.SDL_SetWindowHitTest(window, hitTest, null);
}

/// Where a point in the window drags or resizes it: resize along the
/// edges (unless maximised), drag on the title bar away from its controls.
fn hitTest(win: ?*dvui.backend.c.SDL_Window, area: [*c]const dvui.backend.c.SDL_Point, _: ?*anyopaque) callconv(.c) dvui.backend.c.SDL_HitTestResult {
    const c = dvui.backend.c;
    const p = area.*;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(win, &w, &h);
    const maximized = (c.SDL_GetWindowFlags(win) & c.SDL_WINDOW_MAXIMIZED) != 0;
    if (!maximized) {
        const l = p.x < resize_edge;
        const r = p.x >= w - resize_edge;
        const t = p.y < resize_edge;
        const b = p.y >= h - resize_edge;
        if (t and l) return c.SDL_HITTEST_RESIZE_TOPLEFT;
        if (t and r) return c.SDL_HITTEST_RESIZE_TOPRIGHT;
        if (b and l) return c.SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if (b and r) return c.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (t) return c.SDL_HITTEST_RESIZE_TOP;
        if (b) return c.SDL_HITTEST_RESIZE_BOTTOM;
        if (l) return c.SDL_HITTEST_RESIZE_LEFT;
        if (r) return c.SDL_HITTEST_RESIZE_RIGHT;
    }
    const pp: dvui.Point.Physical = .{ .x = @as(f32, @floatFromInt(p.x)) * frame_density, .y = @as(f32, @floatFromInt(p.y)) * frame_density };
    if (!frame_bar.contains(pp)) return c.SDL_HITTEST_NORMAL;
    for (frame_holes[0..frame_hole_count]) |hole| if (hole.contains(pp)) return c.SDL_HITTEST_NORMAL;
    return c.SDL_HITTEST_DRAGGABLE;
}

/// Marks a control on the title bar, so pressing it is not a window drag.
fn frameHole(r: dvui.Rect.Physical) void {
    if (frame_hole_count < frame_holes.len) {
        frame_holes[frame_hole_count] = r;
        frame_hole_count += 1;
    }
}

const WindowButton = enum { minimize, maximize, close };

/// A window control: a round button showing only on hover, with a thin
/// glyph, as GTK and COSMIC draw them.
fn windowButton(kind: WindowButton) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = @backingInt(kind),
        .min_size_content = .{ .w = 18, .h = 18 },
        .padding = .all(5),
        .margin = .{ .x = 3, .w = 3 },
        .corners = .round(14),
        .gravity_y = 0.5,
        .background = false,
        .border = .all(0),
    });
    bw.processEvents();
    if (bw.hovered() or bw.pressed()) bw.data().borderRectScale().r.fill(.round(14 * dvui.windowNaturalScale()), .{ .color = .{ .color = dvui.themeGet().color(.control, .text).opacity(if (bw.pressed()) 0.2 else 0.1) } });
    const clicked = bw.clicked();
    const r = bw.data().contentRectScale().r;
    frameHole(bw.data().borderRectScale().r);
    const ns = dvui.windowNaturalScale();
    const ink: dvui.ColorOrGradient = .{ .color = dvui.themeGet().color(.control, .text) };
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const k = 4.5 * ns;
    switch (kind) {
        .minimize => dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - k, .y = cy + k * 0.6 }, .{ .x = cx + k, .y = cy + k * 0.6 } } }, .{ .thickness = 1.3 * ns, .color = ink }),
        .maximize => (dvui.Rect.Physical{ .x = cx - k, .y = cy - k, .w = 2 * k, .h = 2 * k }).stroke(.square, .{ .thickness = 1.3 * ns, .color = ink }),
        .close => {
            dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - k, .y = cy - k }, .{ .x = cx + k, .y = cy + k } } }, .{ .thickness = 1.3 * ns, .color = ink });
            dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - k, .y = cy + k }, .{ .x = cx + k, .y = cy - k } } }, .{ .thickness = 1.3 * ns, .color = ink });
        },
    }
    bw.deinit();
    return clicked;
}

/// The title bar: menus at the left, the file and worksheet in the middle,
/// window controls at the right. Everything that is not a control drags
/// the window.
fn titleBar() ?dvui.App.Result {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = colors.titlebar }, .min_size_content = .{ .h = title_height }, .border = .{ .h = 1 } });
    defer bar.deinit();
    frame_bar = bar.data().borderRectScale().r;
    frame_hole_count = 0;
    const win = dvui.currentWindow();
    const px = win.backend.pixelSize();
    const ws = win.backend.windowSize();
    frame_density = if (ws.w > 0) px.w / ws.w else 1;

    const native_frame = dvui.backend.kind != .sdl3 or std.c.getenv("GRAVEN_NATIVE_FRAME") != null;
    // Window buttons on the left, when the desktop puts them there.
    if (!native_frame) if (windowButtons(desk.layout.leftSide())) |r| return r;

    if (menu()) |r| return r;

    // The title fills the middle and is part of the draggable bar.
    {
        // Each name italic while it is the app's choice.
        // Fills the bar's height too, so the title centres against the
        // menus and window buttons rather than sitting at the top.
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        var title = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        defer title.deinit();
        dvui.labelNoFmt(@src(), state.file_name, .{}, .{ .font = styled(.theme(.body), !state.file_name_set), .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        dvui.labelNoFmt(@src(), "  —  ", .{}, .{ .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        dvui.labelNoFmt(@src(), state.model.sheet.name, .{}, .{ .font = styled(.theme(.body), state.model.sheet.default_name), .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
    }

    if (!native_frame) if (windowButtons(desk.layout.rightSide())) |r| return r;
    return null;
}

/// The window buttons in the desktop's order.
fn windowButtons(buttons: []const desktop.Button) ?dvui.App.Result {
    if (dvui.backend.kind != .sdl3) return null;
    const c = dvui.backend.c;
    const window = dvui.currentWindow().backend.impl.window;
    for (buttons) |b| {
        const kind: WindowButton = switch (b) {
            .minimize => .minimize,
            .maximize => .maximize,
            .close => .close,
        };
        if (!windowButton(kind)) continue;
        switch (kind) {
            .minimize => _ = c.SDL_MinimizeWindow(window),
            .maximize => {
                const maximized = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_MAXIMIZED) != 0;
                _ = if (maximized) c.SDL_RestoreWindow(window) else c.SDL_MaximizeWindow(window);
            },
            .close => return .close,
        }
    }
    return null;
}

fn menu() ?dvui.App.Result {
    var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
    frameHole(m.data().borderRectScale().r);
    defer m.deinit();
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        if (state.model.panels.items.len == 0) {
            if (dvui.menuItemLabel(@src(), "Add sample: PC keyboard", .{}, .{ .expand = .horizontal }) != null) {
                loadSample() catch |err| {
                    state.status = if (err == error.OffSheet) "The sample keyboard does not fit on this sheet. " else "The sample did not load. ";
                };
                m.close();
            }
        }
        if (dvui.menuItemLabel(@src(), "Quit", .{}, .{ .expand = .horizontal }) != null) return .close;
    }
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        if (dvui.menuItemLabel(@src(), "Zoom to context", .{}, .{ .expand = .horizontal }) != null) {
            zoomToContext();
            m.close();
        }
    }
    return null;
}

/// The component tree: file, panels, regions, rows, tiles. Clicking a node
/// makes it the context; its arrow opens or closes it.
fn treePane() void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 240 }, .max_size_content = .width(240), .expand = .vertical, .border = .{ .w = 1 } });
    defer pane.deinit();
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var name_buf: [64]u8 = undefined;
    // The file holds everything; the worksheet is its one child for now.
    if (!treeNode(.file, state.file_name, 0, true, !state.file_name_set)) return;
    const sheet = state.model.sheet;
    if (!treeNode(.worksheet, sheet.name, 1, state.model.panels.items.len > 0, sheet.default_name)) return;
    for (state.model.panels.items, 0..) |panel, pi| {
        if (!treeNode(.{ .panel = pi }, panel.name, 2, panel.regions.items.len > 0, panel.default_name)) continue;
        for (panel.regions.items, 0..) |region, ri| {
            if (!treeNode(.{ .region = .{ .panel = pi, .region = ri } }, region.name, 3, region.rows.items.len > 0, false)) continue;
            for (region.rows.items, 0..) |row, rowi| {
                const title = std.fmt.bufPrint(&name_buf, "Row {d}", .{rowi + 1}) catch "Row";
                if (!treeNode(.{ .row = .{ .panel = pi, .region = ri, .row = rowi } }, title, 4, row.places.items.len > 0, false)) continue;
                for (row.places.items) |p| {
                    const t = state.model.tileConst(p.tile);
                    const legend = if (t.slots.items.len > 0) t.slots.items[0].content else "";
                    const text = std.fmt.bufPrint(&name_buf, "{s}  {s}", .{ t.designator, legend }) catch t.designator;
                    _ = treeNode(.{ .tile = p.tile }, text, 5, false, false);
                }
            }
        }
    }
}

/// One tree row: an open/close arrow when it has children, and its name,
/// highlighted when it is the context and in italic when the app chose it.
/// Returns whether it is open.
fn treeNode(ctx: Context, text: []const u8, depth: usize, has_children: bool, default: bool) bool {
    const key = ctx.key();
    const id: usize = @truncate(key);
    const open = state.expanded.get(key) orelse switch (ctx) {
        .file, .worksheet, .panel, .region => true,
        else => false,
    };
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = id, .margin = .{ .x = @floatFromInt(depth * 14) } });
    defer row.deinit();
    if (has_children) {
        if (dvui.buttonIcon(@src(), if (open) "Close" else "Open", if (open) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{}, .{}, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .padding = .all(1),
            .margin = .all(1),
            .gravity_y = 0.5,
            .background = false,
            .border = .all(0),
        })) {
            state.expanded.put(state.gpa, key, !open) catch {};
        }
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 16 } });
    }
    const selected = state.context.eql(ctx);
    const flagged = switch (ctx) {
        .panel => |pi| panelIssue(pi) != null,
        else => false,
    };
    if (dvui.labelClick(@src(), "{s}", .{text}, .{}, .{
        .color_text = if (flagged) .{ .color = colors.overflow } else null,
        .expand = .horizontal,
        .background = selected,
        .color_fill = if (selected) .{ .color = dvui.themeGet().focus.opacity(0.25) } else null,
        .font = styled(if (depth == 0) .theme(.heading) else .theme(.body), default),
    })) state.context = ctx;
    return open;
}

/// Opens the tree down to `ctx`, so a context chosen on the canvas shows.
fn revealInTree(ctx: Context) void {
    const id = switch (ctx) {
        .tile => |t| t,
        else => return,
    };
    const f = findTile(id) orelse return;
    for ([_]Context{
        .worksheet,
        .{ .panel = f.panel },
        .{ .region = .{ .panel = f.panel, .region = f.tile.region } },
        .{ .row = .{ .panel = f.panel, .region = f.tile.region, .row = f.tile.row } },
    }) |c| state.expanded.put(state.gpa, c.key(), true) catch {};
    state.expanded.put(state.gpa, Context.key(.file), true) catch {};
}

/// Whether a placed tile on panel `pi` belongs to the context, for canvas
/// highlighting.
fn inContext(pi: usize, t: layout.place.PlacedTile) bool {
    return switch (state.context) {
        .tile => |id| t.id == id,
        .row => |r| r.panel == pi and t.region == r.region and t.row == r.row,
        .region => |r| r.panel == pi and t.region == r.region,
        .file, .worksheet, .panel => false,
    };
}

/// The context's extents on the worksheet, mm.
fn contextExtents() geom.Box {
    switch (state.context) {
        .file, .worksheet => return state.model.sheet.box(),
        .panel => |pi| return state.model.panels.items[pi].box(),
        else => {},
    }
    var b: geom.Box = .empty;
    for (state.placed.items, 0..) |*p, pi| for (p.tiles) |t| {
        if (inContext(pi, t)) b = b.join(onSheet(pi, t.pitch_box));
    };
    return if (b.isEmpty()) state.model.sheet.box() else b;
}

/// Centres the context in the canvas and zooms it to fill the canvas.
fn zoomToContext() void {
    state.view.fit = contextExtents();
}

/// Graven's own colours. The artwork (sheet, tiles, legends) keeps light
/// paper colours in either scheme, as drawing apps do; the chrome around it
/// (desk, rulers, title bar) follows the desktop's dark or light setting.
const Palette = struct {
    desk: dvui.Color,
    paper: dvui.Color = .{ .r = 0xfb, .g = 0xfa, .b = 0xf7 },
    panel_edge: dvui.Color = .{ .r = 0x5c, .g = 0x5a, .b = 0x55 },
    margin: dvui.Color = .{ .r = 0x9c, .g = 0x8a, .b = 0x6e },
    ruler: dvui.Color,
    titlebar: dvui.Color,
    ruler_ink: dvui.Color,
    body: dvui.Color = .{ .r = 0xe4, .g = 0xe2, .b = 0xdc },
    edge: dvui.Color = .{ .r = 0x9a, .g = 0x97, .b = 0x8f },
    face: dvui.Color = .{ .r = 0xf6, .g = 0xf5, .b = 0xf1 },
    ink: dvui.Color = .{ .r = 0x1d, .g = 0x1d, .b = 0x1b },
    missing: dvui.Color = .{ .r = 0xf6, .g = 0xd5, .b = 0xcf },
    overflow: dvui.Color = .{ .r = 0xc2, .g = 0x41, .b = 0x2d },
};

const light_palette: Palette = .{
    .desk = .{ .r = 0xd9, .g = 0xd7, .b = 0xd2 },
    .ruler = .{ .r = 0xe9, .g = 0xe7, .b = 0xe2 },
    .titlebar = .{ .r = 0xeb, .g = 0xea, .b = 0xe7 },
    .ruler_ink = .{ .r = 0x4a, .g = 0x48, .b = 0x44 },
};

const dark_palette: Palette = .{
    .desk = .{ .r = 0x2b, .g = 0x2b, .b = 0x2d },
    .ruler = .{ .r = 0x38, .g = 0x38, .b = 0x3b },
    .titlebar = .{ .r = 0x30, .g = 0x30, .b = 0x33 },
    .ruler_ink = .{ .r = 0xc8, .g = 0xc6, .b = 0xc2 },
    .edge = .{ .r = 0x6a, .g = 0x68, .b = 0x64 },
};

var colors: Palette = light_palette;

/// The desktop settings in effect, for the title bar's button layout.
var desk: desktop.Settings = .{};

/// Matches the desktop: DVUI's Adwaita theme in the desktop's scheme with
/// its accent as the focus colour, and Graven's palette to suit.
fn applyDesktop(win: *dvui.Window, s: desktop.Settings) void {
    desk = s;
    const dark = s.scheme == .dark;
    var theme = if (dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light;
    if (s.accent) |a| theme.focus = .{ .r = @intFromFloat(a[0] * 255), .g = @intFromFloat(a[1] * 255), .b = @intFromFloat(a[2] * 255) };
    win.themeSet(theme);
    colors = if (dark) dark_palette else light_palette;
}

var main_window: ?*dvui.Window = null;

fn wakeGui() void {
    if (main_window) |w| dvui.refresh(w, @src(), null);
}

/// The canvas: the worksheet at true proportions, with every panel on it.
/// Wheel zooms about the pointer and dragging pans. With the select tool a
/// click makes a tile, panel or the worksheet the context; with the add
/// panel tool a drag draws out a new panel. The context is outlined.
fn canvas() void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = .{ .color = colors.desk } });
    defer box.deinit();
    const area = box.data().contentRectScale().r;
    const rw: f32 = ruler_size * dvui.windowNaturalScale();
    if (area.w <= 3 * rw or area.h <= 3 * rw) return;
    const sheet = state.model.sheet;

    // The first frame fits the worksheet, leaving room for its rulers.
    if (state.view.ppm == 0 and state.view.fit == null) state.view.fit = sheet.box();
    if (state.view.fit) |b| {
        state.view.cx = (b.x0 + b.x1) / 2;
        state.view.cy = (b.y0 + b.y1) / 2;
        state.view.ppm = 0.96 * @min((area.w - 2.5 * rw) / b.width(), (area.h - 2.5 * rw) / b.height());
    }
    // Drawn last, over everything.
    defer drawRulers(area);
    const clip = dvui.clip(area);
    defer dvui.clipSet(clip);

    canvasEvents(box, area);
    // Work happens on the worksheet: the view's centre stays on the sheet.
    state.view.cx = std.math.clamp(state.view.cx, 0, sheet.w);
    state.view.cy = std.math.clamp(state.view.cy, 0, sheet.h);

    const px = dvui.windowNaturalScale();
    const sheet_rect = state.view.rect(area, sheet.box());
    sheet_rect.fill(.square, .{ .color = .{ .color = colors.paper } });
    drawMargins(area, sheet);
    sheet_rect.stroke(.square, .{ .thickness = px, .color = .{ .color = colors.edge } });

    // Re-flatten label outlines when the zoom has moved more than 2x.
    const tol = 0.2 / state.view.ppm;
    if (state.flat.tol == 0 or tol < state.flat.tol / 2 or tol > state.flat.tol * 2) state.flat.reset(tol);

    for (0..state.model.panels.items.len) |pi| {
        const outline = state.view.rect(area, panelBox(pi));
        const is_context = switch (state.context) {
            .panel => |c| c == pi,
            else => false,
        };
        // While dragged, compliance is shown live for the preview position.
        const off = if (state.moving != null and state.moving.?.panel == pi) !state.model.compliantAt(pi, panelOrigin(pi)) else panelIssue(pi) != null;
        drawPanelMargins(area, pi);
        // A panel past the sheet's edge is outlined in the warning colour.
        const edge = if (is_context) dvui.themeGet().focus else if (off) colors.overflow else colors.panel_edge;
        outline.stroke(.square, .{ .thickness = if (is_context or off) 2 * px else px, .color = .{ .color = edge } });
        if (pi < state.placed.items.len) drawPanel(area, pi, &state.placed.items[pi]);
    }

    // The panel being drawn out: a translucent fill and its outline.
    if (state.drag) |d| {
        const r = state.view.rect(area, dragBox(d.start, d.at));
        r.fill(.square, .{ .color = .{ .color = dvui.themeGet().focus.opacity(0.12) } });
        r.stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = dvui.themeGet().focus } });
    }
    if (state.tool == .add_panel and state.model.panels.items.len == 0 and state.drag == null) {
        dvui.labelNoFmt(@src(), "Drag out the new panel on the sheet. Esc cancels.", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.05,
            .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.6) },
        });
    }
}

/// The margins as translucent bands inside the sheet's edge, and the ink
/// area's boundary as a thin line.
fn drawMargins(area: dvui.Rect.Physical, sheet: layout.model.Sheet) void {
    const px = dvui.windowNaturalScale();
    const s = sheet.box();
    const ink = sheet.inkArea();
    const band: dvui.ColorOrGradient = .{ .color = colors.margin.opacity(0.35) };
    for ([_]geom.Box{
        .{ .x0 = s.x0, .y0 = s.y0, .x1 = ink.x0, .y1 = s.y1 },
        .{ .x0 = ink.x1, .y0 = s.y0, .x1 = s.x1, .y1 = s.y1 },
        .{ .x0 = ink.x0, .y0 = ink.y1, .x1 = ink.x1, .y1 = s.y1 },
        .{ .x0 = ink.x0, .y0 = s.y0, .x1 = ink.x1, .y1 = ink.y0 },
    }) |b| {
        if (b.width() > 0 and b.height() > 0) state.view.rect(area, b).fill(.square, .{ .color = band });
    }
    state.view.rect(area, ink).stroke(.square, .{ .thickness = px, .color = .{ .color = colors.margin } });
}

/// Panel `pi`'s compliance issue, if it has one.
fn panelIssue(pi: usize) ?layout.drc.PanelIssue {
    for (state.panel_issues) |i| if (i.panel == pi) return i;
    return null;
}

/// A panel's margins as a light translucent band inside its outline, and
/// its ink area's boundary as a thin line.
fn drawPanelMargins(area: dvui.Rect.Physical, pi: usize) void {
    const px = dvui.windowNaturalScale();
    const p = state.model.panels.items[pi];
    const b = panelBox(pi);
    const ink = p.margins.inset(b);
    const band: dvui.ColorOrGradient = .{ .color = colors.margin.opacity(0.18) };
    for ([_]geom.Box{
        .{ .x0 = b.x0, .y0 = b.y0, .x1 = ink.x0, .y1 = b.y1 },
        .{ .x0 = ink.x1, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 },
        .{ .x0 = ink.x0, .y0 = ink.y1, .x1 = ink.x1, .y1 = b.y1 },
        .{ .x0 = ink.x0, .y0 = b.y0, .x1 = ink.x1, .y1 = ink.y0 },
    }) |r| {
        if (r.width() > 0 and r.height() > 0) state.view.rect(area, r).fill(.square, .{ .color = band });
    }
    if (ink.width() > 0 and ink.height() > 0) state.view.rect(area, ink).stroke(.square, .{ .thickness = px, .color = .{ .color = colors.margin.opacity(0.6) } });
}

fn inMargin(tile: TileId, slot: usize) bool {
    for (state.intrusions) |i| if (i.tile == tile and i.slot == slot) return true;
    return false;
}

/// Tiles and legends of panel `pi`, moved onto the worksheet.
fn drawPanel(area: dvui.Rect.Physical, pi: usize, placed: *const layout.place.Placed) void {
    const px = dvui.windowNaturalScale();
    const radius: f32 = @floatCast(1.0 * state.view.ppm);
    for (placed.tiles) |t| {
        const flagged = tileFlag(placed, t.id);
        const body = state.view.rect(area, onSheet(pi, t.body));
        const face = state.view.rect(area, onSheet(pi, t.face));
        body.fill(.round(radius), .{ .color = .{ .color = colors.body } });
        const in_context = inContext(pi, t);
        body.stroke(.round(radius), .{ .thickness = px, .color = .{ .color = if (in_context) dvui.themeGet().focus else colors.edge } });
        face.fill(.round(radius), .{ .color = .{ .color = if (flagged.missing) colors.missing else colors.face } });
        if (flagged.overflow) face.stroke(.round(radius), .{ .thickness = 1.5 * px, .color = .{ .color = colors.overflow } });
        if (in_context) body.stroke(.round(radius), .{ .thickness = (if (state.context == .tile) @as(f32, 3) else 2) * px, .color = .{ .color = dvui.themeGet().focus } });
    }
    const o = panelOrigin(pi);
    const lifo = dvui.currentWindow().lifo();
    for (placed.labels) |l| {
        const contours = state.flat.get(l.render, &state.faces) catch continue;
        const paths = lifo.alloc(dvui.Path, contours.len) catch continue;
        defer lifo.free(paths);
        var made: usize = 0;
        defer for (paths[0..made]) |p| lifo.free(p.points);
        for (contours, paths) |c, *p| {
            const pts = lifo.alloc(dvui.Point.Physical, c.len) catch break;
            for (c, pts) |q, *out| out.* = state.view.toPx(area, .{ .x = q.x + l.origin.x + o.x, .y = q.y + l.origin.y + o.y });
            p.* = .{ .points = pts };
            made += 1;
        }
        // Ink in the sheet's margins is drawn in the warning colour.
        dvui.Path.fill(paths[0..made], .{ .color = .{ .color = if (inMargin(l.tile, l.slot)) colors.overflow else colors.ink }, .fade = 1 });
    }
}

/// Ruler depth, logical pixels.
const ruler_size = 24;

/// One kind of ruler tick: every `step` mm, `len` of the ruler's depth
/// long, numbered or not.
const Tick = struct { step: f64, len: f32, label: bool };

/// The ticks for the worksheet's units at the current zoom. Metric: numbered
/// centimetres (thinned out to 2, 5, 10 cm … when crowded), then 5 mm and
/// 1 mm ticks where they fit. Imperial: numbered inches (thinned the same
/// way), then halves, quarters, eighths … to the finest that fits.
fn ticks(buf: []Tick) []Tick {
    const ns = dvui.windowNaturalScale();
    const ppm = state.view.ppm;
    const min_tick = 4 * ns;
    const min_label = 44 * ns;
    var n: usize = 0;
    switch (state.model.sheet.units) {
        .mm => {
            var label: f64 = 10;
            for ([_]f64{ 10, 20, 50, 100, 200, 500, 1000, 2000 }) |st| {
                label = st;
                if (st * ppm >= min_label) break;
            }
            buf[n] = .{ .step = label, .len = 0.7, .label = true };
            n += 1;
            for ([_]Tick{ .{ .step = 10, .len = 0.5, .label = false }, .{ .step = 5, .len = 0.35, .label = false }, .{ .step = 1, .len = 0.2, .label = false } }) |t| {
                if (t.step < label and t.step * ppm >= min_tick and n < buf.len) {
                    buf[n] = t;
                    n += 1;
                }
            }
        },
        .inch => {
            var label: f64 = 1;
            for ([_]f64{ 1, 2, 5, 10, 20, 50, 100 }) |st| {
                label = st;
                if (st * 25.4 * ppm >= min_label) break;
            }
            buf[n] = .{ .step = label * 25.4, .len = 0.7, .label = true };
            n += 1;
            if (label > 1 and 25.4 * ppm >= min_tick) {
                buf[n] = .{ .step = 25.4, .len = 0.5, .label = false };
                n += 1;
            }
            var k: u6 = 1;
            while (n < buf.len) : (k += 1) {
                const step = 25.4 / @as(f64, @floatFromInt(@as(u64, 1) << k));
                if (step * ppm < min_tick) break;
                buf[n] = .{ .step = step, .len = @max(0.14, 0.45 - 0.07 * @as(f32, @floatFromInt(k))), .label = false };
                n += 1;
            }
        },
    }
    return buf[0..n];
}

/// The rulers, fixed to the sheet's edges and spanning only the sheet: the
/// horizontal one on its top edge, the vertical one on the side the ruler
/// origin is on. When an edge scrolls out of view its ruler stays pinned
/// to the canvas edge. Numbers count from the ruler origin in the
/// worksheet's units; the pointer is marked on both.
fn drawRulers(area: dvui.Rect.Physical) void {
    const ns = dvui.windowNaturalScale();
    const rw: f32 = ruler_size * ns;
    const prev = dvui.clip(area);
    defer dvui.clipSet(prev);
    const sheet = state.model.sheet;
    const right = sheet.ruler_origin.fromRight();
    const tl = state.view.toPx(area, .{ .x = 0, .y = sheet.h });
    const br = state.view.toPx(area, .{ .x = sheet.w, .y = 0 });

    const hy = std.math.clamp(tl.y - rw, area.y, area.y + area.h - rw);
    const hx0 = @max(tl.x, area.x);
    const hx1 = @min(br.x, area.x + area.w);
    const vx = std.math.clamp(if (right) br.x else tl.x - rw, area.x, area.x + area.w - rw);
    const vy0 = @max(tl.y, area.y);
    const vy1 = @min(br.y, area.y + area.h);
    const top: dvui.Rect.Physical = .{ .x = hx0, .y = hy, .w = @max(0, hx1 - hx0), .h = rw };
    const side: dvui.Rect.Physical = .{ .x = vx, .y = vy0, .w = rw, .h = @max(0, vy1 - vy0) };
    const corner: dvui.Rect.Physical = .{ .x = vx, .y = hy, .w = rw, .h = rw };

    for ([_]dvui.Rect.Physical{ top, side, corner }) |r| r.fill(.square, .{ .color = .{ .color = colors.ruler } });

    var buf: [12]Tick = undefined;
    const list = ticks(&buf);
    rulerAxis(top, area, list, true);
    rulerAxis(side, area, list, false);

    // Each ruler's edge against the sheet.
    const line: dvui.ColorOrGradient = .{ .color = colors.edge };
    for ([_]dvui.Rect.Physical{ top, side, corner }) |r| r.stroke(.square, .{ .thickness = ns, .color = line });

    if (state.mouse) |m| {
        const p = state.view.toPx(area, m);
        const mark: dvui.ColorOrGradient = .{ .color = dvui.themeGet().focus };
        dvui.Path.stroke(.{ .points = &.{ .{ .x = p.x, .y = top.y }, .{ .x = p.x, .y = top.y + top.h } } }, .{ .thickness = ns, .color = mark });
        dvui.Path.stroke(.{ .points = &.{ .{ .x = side.x, .y = p.y }, .{ .x = side.x + side.w, .y = p.y } } }, .{ .thickness = ns, .color = mark });
    }
}

/// One ruler's ticks and numbers, counted from the ruler origin. Ticks grow
/// from the ruler's edge against the sheet.
fn rulerAxis(r: dvui.Rect.Physical, area: dvui.Rect.Physical, list: []const Tick, horizontal: bool) void {
    if (r.w <= 0 or r.h <= 0) return;
    const ns = dvui.windowNaturalScale();
    const sheet = state.model.sheet;
    const from_far = if (horizontal) sheet.ruler_origin.fromRight() else sheet.ruler_origin.fromTop();
    const length = if (horizontal) sheet.w else sheet.h;
    // The ruler's ends in the worksheet frame, then as the ruler counts.
    const e0 = if (horizontal) state.view.toMm(area, .{ .x = r.x, .y = 0 }).x else state.view.toMm(area, .{ .x = 0, .y = r.y + r.h }).y;
    const e1 = if (horizontal) state.view.toMm(area, .{ .x = r.x + r.w, .y = 0 }).x else state.view.toMm(area, .{ .x = 0, .y = r.y }).y;
    const c0 = if (from_far) length - e0 else e0;
    const c1 = if (from_far) length - e1 else e1;
    // A millimetre of slack each way, so pixel rounding at a sheet edge
    // does not drop the 0 or end tick; still clamped to the sheet.
    const lo = @max(0, @min(c0, c1) - 1);
    const hi = @min(length, @max(c0, c1) + 1);
    if (lo > hi) return;

    // Ticks grow from the edge against the sheet: the horizontal ruler's
    // bottom; the vertical ruler's right side on the left, left side on
    // the right.
    const right_side = !horizontal and sheet.ruler_origin.fromRight();
    const ink: dvui.ColorOrGradient = .{ .color = colors.ruler_ink };
    const font = dvui.Font.theme(.body).withSize(7);
    const depth = if (horizontal) r.h else r.w;
    for (list) |t| {
        var i: f64 = @ceil(lo / t.step - 1e-9);
        while (i * t.step <= hi + 1e-9) : (i += 1) {
            const v = i * t.step;
            const along = if (from_far) length - v else v;
            const p = state.view.toPx(area, if (horizontal) .{ .x = along, .y = 0 } else .{ .x = 0, .y = along });
            const len = depth * t.len;
            const pts: [2]dvui.Point.Physical = if (horizontal)
                .{ .{ .x = p.x, .y = r.y + r.h }, .{ .x = p.x, .y = r.y + r.h - len } }
            else if (right_side)
                .{ .{ .x = r.x, .y = p.y }, .{ .x = r.x + len, .y = p.y } }
            else
                .{ .{ .x = r.x + r.w, .y = p.y }, .{ .x = r.x + r.w - len, .y = p.y } };
            dvui.Path.stroke(.{ .points = &pts }, .{ .thickness = ns, .color = ink });
            if (!t.label) continue;

            var text_buf: [16]u8 = undefined;
            // @round(-0.0) prints as "-0".
            const rounded = @round(v * sheet.units.perMm());
            const text = std.fmt.bufPrint(&text_buf, "{d}", .{if (rounded == 0) 0 else rounded}) catch continue;
            const size = font.textSize(text);
            const tw: f32 = size.w * ns;
            const th: f32 = size.h * ns;
            // Bounds for culling: the canvas, since rotated text is culled by
            // its unrotated extent.
            const rs: dvui.RectScale = .{ .r = area, .s = ns };
            if (horizontal) {
                // Numbers sit on the side of the tick they count toward.
                const x = if (from_far) p.x - 2 * ns - tw else p.x + 2 * ns;
                dvui.renderText(.{ .font = font, .text = text, .rs = rs, .p = .{ .x = x, .y = r.y + ns }, .color = colors.ruler_ink }) catch {};
            } else {
                // Rotated to read bottom to top; on the far side from the sheet.
                const x = if (right_side) r.x + r.w - th - ns else r.x + ns;
                const y = if (from_far) p.y + 2 * ns + tw else p.y - 2 * ns;
                dvui.renderText(.{ .font = font, .text = text, .rs = rs, .p = .{ .x = x, .y = y }, .color = colors.ruler_ink, .rotation = -std.math.pi / 2.0 }) catch {};
            }
        }
    }
}

/// Snaps a worksheet point to the 1 mm grid the add panel tool uses, and
/// keeps it on the sheet: panels may not extend past it.
fn snap(p: geom.Point) geom.Point {
    const s = state.model.sheet.box();
    return .{ .x = std.math.clamp(@round(p.x), s.x0, s.x1), .y = std.math.clamp(@round(p.y), s.y0, s.y1) };
}

fn dragBox(a: geom.Point, b: geom.Point) geom.Box {
    return .{ .x0 = @min(a.x, b.x), .y0 = @min(a.y, b.y), .x1 = @max(a.x, b.x), .y1 = @max(a.y, b.y) };
}

fn canvasEvents(box: *dvui.BoxWidget, area: dvui.Rect.Physical) void {
    const drawing = state.tool == .add_panel;
    for (dvui.events()) |*e| {
        if (e.evt == .key and state.moving != null) {
            const k = e.evt.key;
            if (k.code == .escape and k.action == .down) {
                e.handle(@src(), box.data());
                state.moving = null;
                dvui.refresh(null, @src(), box.data().id);
            }
            continue;
        }
        if (e.evt == .key and drawing) {
            const k = e.evt.key;
            if (k.code == .escape and k.action == .down) {
                e.handle(@src(), box.data());
                state.tool = .select;
                state.drag = null;
                dvui.refresh(null, @src(), box.data().id);
            }
            continue;
        }
        if (!dvui.eventMatchSimple(e, box.data())) continue;
        if (e.evt == .key) {
            // Keys reach the canvas only while it has focus.
            const k = e.evt.key;
            if (k.code == .delete and k.action == .down and state.moving == null) {
                if (state.context == .panel) {
                    e.handle(@src(), box.data());
                    state.model.removePanel(state.context.panel);
                    state.context = .worksheet;
                    dvui.refresh(null, @src(), box.data().id);
                }
            }
            continue;
        }
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            // A press first sends a focus event; taking it gives the canvas
            // keyboard focus, for Delete and the like.
            .focus => {
                e.handle(@src(), box.data());
                dvui.focusWidget(box.data().id, null, e.num);
            },
            .position => {
                // The pointer's worksheet position, for the rulers and readout.
                const at = state.view.toMm(area, me.p);
                state.mouse = if (area.contains(me.p) and contains(state.model.sheet.box(), at)) at else null;
                if (drawing) {
                    dvui.cursorSet(.crosshair);
                } else if (state.moving != null) {
                    dvui.cursorSet(.arrow_all);
                } else if (panelToMove(state.view.toMm(area, me.p)) != null) {
                    // Over a panel a drag would move, show that it can be.
                    dvui.cursorSet(.arrow_all);
                }
            },
            .wheel_y => |dy| {
                e.handle(@src(), box.data());
                const at = state.view.toMm(area, me.p);
                const z = @exp(@log(1.003) * @as(f64, dy));
                state.view.ppm *= z;
                state.view.fit = null;
                // Keep the point under the pointer fixed.
                state.view.cx = at.x - (at.x - state.view.cx) / z;
                state.view.cy = at.y - (at.y - state.view.cy) / z;
                dvui.refresh(null, @src(), box.data().id);
            },
            .press => if ((me.button.pointer() or me.button == .middle) and area.contains(me.p)) {
                e.handle(@src(), box.data());
                dvui.captureMouse(box.data(), e.num);
                if (drawing and me.button.pointer()) {
                    const at = snap(state.view.toMm(area, me.p));
                    state.drag = .{ .start = at, .at = at };
                } else {
                    state.press_at = if (me.button.pointer()) state.view.toMm(area, me.p) else null;
                    dvui.dragPreStart(me.button, me.p, .{});
                }
            },
            .motion => if (dvui.captured(box.data().id)) {
                if (state.drag) |*d| {
                    e.handle(@src(), box.data());
                    d.at = snap(state.view.toMm(area, me.p));
                    dvui.refresh(null, @src(), box.data().id);
                } else if (state.moving) |*mv| {
                    e.handle(@src(), box.data());
                    mv.at = state.view.toMm(area, me.p);
                    dvui.refresh(null, @src(), box.data().id);
                } else if (dvui.dragging(me, null)) |d| {
                    e.handle(@src(), box.data());
                    // Dragging the selected panel moves it; anything else pans.
                    if (grabbedPanel()) |pi| {
                        state.moving = .{ .panel = pi, .start = state.press_at.?, .at = state.view.toMm(area, me.p) };
                    } else {
                        state.view.fit = null;
                        state.view.cx -= d.x / state.view.ppm;
                        state.view.cy += d.y / state.view.ppm;
                    }
                    dvui.refresh(null, @src(), box.data().id);
                }
            },
            .release => if (dvui.captured(box.data().id)) {
                e.handle(@src(), box.data());
                if (state.drag) |d| {
                    state.drag = null;
                    addPanelFromDrag(dragBox(d.start, d.at));
                } else if (state.moving) |mv| {
                    finishMove(mv.panel);
                } else if (dvui.dragging(me, null) == null) {
                    pick(state.view.toMm(area, me.p));
                }
                state.press_at = null;
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
                dvui.refresh(null, @src(), box.data().id);
            },
            else => {},
        }
    }
}

/// The selected panel, when the pointer went down on it: a drag then moves it.
fn grabbedPanel() ?usize {
    return panelToMove(state.press_at orelse return null);
}

/// The panel a drag from worksheet point `at` would move: the selected
/// panel when `at` is on it; from the worksheet context, the one panel
/// under `at`, if exactly one is (where panels overlap, select one first).
/// The context does not change.
fn panelToMove(at: geom.Point) ?usize {
    switch (state.context) {
        .panel => |pi| return if (contains(state.model.panels.items[pi].box(), at)) pi else null,
        .worksheet => {
            var found: ?usize = null;
            for (state.model.panels.items, 0..) |p, pi| {
                if (!contains(p.box(), at)) continue;
                if (found != null) return null;
                found = pi;
            }
            return found;
        },
        else => return null,
    }
}

fn contains(b: geom.Box, p: geom.Point) bool {
    return p.x >= b.x0 and p.x <= b.x1 and p.y >= b.y0 and p.y <= b.y1;
}

/// Commits a panel drag. A panel that started compliant ends compliant,
/// stopped where it would stop complying; one that was not may end anywhere.
fn finishMove(pi: usize) void {
    const target = panelOrigin(pi);
    state.moving = null;
    const origin = if (state.model.compliant(pi)) state.model.clampCompliant(pi, target) else target;
    state.model.movePanel(pi, origin) catch |err| dvui.log.err("moving a panel: {s}", .{@errorName(err)});
}

/// Makes what is under worksheet point `at` the context: a tile, else a
/// panel, else the worksheet.
fn pick(at: geom.Point) void {
    state.context = .worksheet;
    for (state.model.panels.items, 0..) |panel, pi| {
        const b = panel.box();
        if (at.x >= b.x0 and at.x <= b.x1 and at.y >= b.y0 and at.y <= b.y1) state.context = .{ .panel = pi };
        if (pi >= state.placed.items.len) continue;
        for (state.placed.items[pi].tiles) |t| {
            const body = onSheet(pi, t.body);
            if (at.x >= body.x0 and at.x <= body.x1 and at.y >= body.y0 and at.y <= body.y1) state.context = .{ .tile = t.id };
        }
    }
    revealInTree(state.context);
}

/// Adds the panel drawn out with the add panel tool. A drag under 1 mm on
/// either side is taken as a slip and ignored, leaving the tool ready.
fn addPanelFromDrag(b: geom.Box) void {
    if (b.width() < 1 or b.height() < 1) return;
    var buf: [32]u8 = undefined;
    const name = state.model.nextPanelName(&buf, "Panel");
    const pi = state.model.placePanel(.{
        .name = name,
        .default_name = true,
        .origin = .{ .x = b.x0, .y = b.y0 },
        .w = b.width(),
        .h = b.height(),
    }) catch |err| {
        dvui.log.err("adding a panel: {s}", .{@errorName(err)});
        return;
    };
    // Tools are not modes: a use ends the tool, and the context it was
    // chosen in stays, so the next panel is one press away.
    _ = pi;
    state.tool = .select;
    state.expanded.put(state.gpa, Context.key(.file), true) catch {};
    state.expanded.put(state.gpa, Context.key(.worksheet), true) catch {};
}

const Flags = struct { missing: bool = false, overflow: bool = false };

fn tileFlag(placed: *const layout.place.Placed, id: TileId) Flags {
    var f: Flags = .{};
    for (placed.issues) |i| {
        if (i.tile != id) continue;
        switch (i.kind) {
            .missing_glyph => f.missing = true,
            .label_overflow => f.overflow = true,
            else => {},
        }
    }
    return f;
}

/// The right side: a tool palette for the current context, then its
/// properties.
fn propertiesPane() !void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 320 }, .max_size_content = .width(320), .expand = .vertical, .border = .{ .x = 1 } });
    defer pane.deinit();
    toolPalette();
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .all(8) });
    defer body.deinit();
    try properties();
}

/// Tools for the current context, as icon buttons.
fn toolPalette() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4), .background = true });
    defer bar.deinit();
    var wd: dvui.WidgetData = undefined;
    if (dvui.buttonIcon(@src(), "Zoom to context", dvui.entypo.resize_full_screen, .{}, .{}, .{ .data_out = &wd })) zoomToContext();
    dvui.tooltip(@src(), .{ .active_rect = wd.borderRectScale().r }, "Zoom to fit the {s}", .{lowerKind()}, .{});

    if (state.context == .worksheet) {
        // A mode tool: shown pressed while active; pressing again cancels.
        const on = state.tool == .add_panel;
        var awd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Add panel", dvui.entypo.squared_plus, .{}, .{}, .{
            .data_out = &awd,
            .color_fill = if (on) .{ .color = dvui.themeGet().focus.opacity(0.35) } else null,
        })) {
            state.tool = if (on) .select else .add_panel;
            state.drag = null;
        }
        dvui.tooltip(@src(), .{ .active_rect = awd.borderRectScale().r }, "Add panel: drag out its outline on the sheet", .{}, .{});
    }
}

fn lowerKind() []const u8 {
    return switch (state.context) {
        .file => "file",
        .worksheet => "worksheet",
        .panel => "panel",
        .region => "region",
        .row => "row",
        .tile => "tile",
    };
}

/// Property rows lay out as name and value. `n` numbers rows within a pane
/// so each has its own widget id.
const label_width = 104;

fn heading(comptime fmt: []const u8, args: anytype, n: usize) void {
    dvui.label(@src(), fmt, args, .{ .font = .theme(.heading), .id_extra = n, .padding = .{ .y = 8, .h = 4 } });
}

/// UI style rule: a value the app chose, and the user has not, is italic.
fn styled(font: dvui.Font, default: bool) dvui.Font {
    return if (default) font.withStyle(.italic) else font;
}

fn propText(name: []const u8, comptime fmt: []const u8, args: anytype, n: usize) void {
    propValue(name, false, fmt, args, n);
}

/// A read-only property; `default` marks a value the app chose.
fn propValue(name: []const u8, default: bool, comptime fmt: []const u8, args: anytype, n: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .min_size_content = .{ .w = label_width }, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
    dvui.label(@src(), fmt, args, .{ .expand = .horizontal, .font = styled(.theme(.body), default) });
}

/// The left-hand name of a property row.
fn propName(name: []const u8) void {
    dvui.labelNoFmt(@src(), name, .{}, .{ .min_size_content = .{ .w = label_width }, .gravity_y = 0.5, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
}

/// The worksheet's editable properties: its name (a short description for
/// reference, separate from the file name), and its sheet as a
/// standard paper and orientation or a custom size.
fn worksheetProperties() !void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Name");
        var te = dvui.textEntry(@src(), .{ .text_initial = state.model.sheet.name }, .{ .expand = .horizontal, .font = styled(.theme(.body), state.model.sheet.default_name) });
        const changed = te.text_changed;
        const text = te.textGet();
        te.deinit();
        // A text entry reports a change on its first frame; only a
        // different text is an edit.
        if (changed and !std.mem.eql(u8, text, state.model.sheet.name)) try state.model.nameWorksheet(text);
    }

    const sheet = state.model.sheet;
    const papers = layout.model.papers;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Sheet");
        var names: [papers.len + 1][]const u8 = undefined;
        for (papers, 0..) |p, i| names[i] = p.name;
        names[papers.len] = "Custom";
        var choice: usize = sheet.paper orelse papers.len;
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_size) })) {
            try state.model.setSheet(if (choice < papers.len) .standard(choice, sheet.orientation) else .custom(sheet.w, sheet.h));
            zoomToContext();
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Orientation");
        const names = [_][]const u8{ "Landscape", "Portrait" };
        var choice: usize = @backingInt(sheet.orientation);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_size) })) {
            const o: layout.model.Orientation = @fromBackingInt(@intCast(choice));
            if (o != sheet.orientation) {
                try state.model.setSheet(if (sheet.paper) |p| .standard(p, o) else .custom(sheet.h, sheet.w));
                zoomToContext();
            }
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Units");
        const names = [_][]const u8{ "Millimetres", "Inches" };
        var choice: usize = @backingInt(sheet.units);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_units) })) {
            state.model.setUnits(@fromBackingInt(@intCast(choice)));
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Ruler origin");
        const names = [_][]const u8{ "Bottom left", "Top left", "Bottom right", "Top right" };
        var choice: usize = @backingInt(sheet.ruler_origin);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_ruler_origin) })) {
            state.model.setRulerOrigin(@fromBackingInt(@intCast(choice)));
        }
    }
    if (sheet.paper == null) {
        // A custom sheet takes its size as typed.
        var w = sheet.w;
        var h = sheet.h;
        var changed = false;
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            propName("Width, mm");
            changed = dvui.textEntryNumber(@src(), f64, .{ .value = &w, .min = 1, .max = 10000 }, .{ .expand = .horizontal }).changed or changed;
        }
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            propName("Height, mm");
            changed = dvui.textEntryNumber(@src(), f64, .{ .value = &h, .min = 1, .max = 10000 }, .{ .expand = .horizontal }).changed or changed;
        }
        if (changed) {
            try state.model.setSheet(.custom(w, h));
            zoomToContext();
        }
    } else {
        propValue("Size", sheet.default_size, "{d} × {d} mm", .{ sheet.w, sheet.h }, 50);
    }

    // Margins: ink keep-out bands. Panels may reach into them; their ink
    // may not.
    heading("Margins", .{}, 60);
    var m = sheet.margins;
    var changed = false;
    inline for (.{ .{ "Left, mm", "left" }, .{ "Right, mm", "right" }, .{ "Top, mm", "top" }, .{ "Bottom, mm", "bottom" } }, 0..) |side, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 61 + i });
        defer row.deinit();
        propName(side[0]);
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(m, side[1]), .min = 0, .max = 1000 }, .{
            .expand = .horizontal,
            .font = styled(.theme(.body), sheet.default_margins),
        });
        changed = r.changed or changed;
    }
    if (changed) state.model.setMargins(m) catch {};
    if (state.intrusions.len > 0) {
        propValue("Ink in margins", false, "{d} labels", .{state.intrusions.len}, 70);
    }
    if (state.panel_issues.len > 0) {
        propValue("Out of compliance", false, "{d} panels", .{state.panel_issues.len}, 71);
    }
}

/// A panel's margins: the ink keep-out bands inside its edges.
fn panelMargins(pi: usize) !void {
    const panel = state.model.panels.items[pi];
    heading("Margins", .{}, 10);
    var m = panel.margins;
    var changed = false;
    inline for (.{ .{ "Left, mm", "left" }, .{ "Right, mm", "right" }, .{ "Top, mm", "top" }, .{ "Bottom, mm", "bottom" } }, 0..) |side, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 11 + i });
        defer row.deinit();
        propName(side[0]);
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(m, side[1]), .min = 0, .max = 1000 }, .{
            .expand = .horizontal,
            .font = styled(.theme(.body), panel.default_margins),
            .id_extra = pi,
        });
        changed = r.changed or changed;
    }
    if (changed) state.model.setPanelMargins(pi, m) catch {};
}

/// The font property: a list of installed fonts, with arrows to step
/// through them. All labels share one face for now; per-style fonts come
/// with the style editor.
fn propFont(name: []const u8, n: usize) !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .min_size_content = .{ .w = label_width }, .gravity_y = 0.5, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
    if (state.fonts.len == 0) {
        dvui.labelNoFmt(@src(), "none found (fc-list)", .{}, .{});
        return;
    }
    const lifo = dvui.currentWindow().lifo();
    const names = try lifo.alloc([]const u8, state.fonts.len);
    defer lifo.free(names);
    for (state.fonts, 0..) |f, i| names[i] = f.name;
    if (dvui.dropdown(@src(), names, .{ .choice = &state.font_choice }, .{}, .{ .expand = .horizontal, .max_size_content = .width(120), .font = styled(.theme(.body), !state.font_set) })) state.font_set = true;
    if (dvui.buttonIcon(@src(), "Previous font", dvui.entypo.chevron_left, .{}, .{}, .{})) {
        state.font_choice = (state.font_choice + state.fonts.len - 1) % state.fonts.len;
        state.font_set = true;
    }
    if (dvui.buttonIcon(@src(), "Next font", dvui.entypo.chevron_right, .{}, .{}, .{})) {
        state.font_choice = (state.font_choice + 1) % state.fonts.len;
        state.font_set = true;
    }
}

fn properties() !void {
    heading("{s}", .{state.context.kindName()}, 0);
    switch (state.context) {
        .file => {
            // The file's name is its path, set by saving; it is not a property.
            propValue("Saved", true, "not yet", .{}, 1);
            propText("Engine", "{s}", .{engine.version}, 2);
        },
        .worksheet => {
            try worksheetProperties();
            propText("Panels", "{d}", .{state.model.panels.items.len}, 3);
            propText("Tiles", "{d}", .{state.model.tiles.items.len}, 4);
            try propFont("Legend font", 5);
        },
        .panel => |pi| {
            const panel = state.model.panels.items[pi];
            propValue("Name", panel.default_name, "{s}", .{panel.name}, 1);
            propText("Origin", "({d:.2}, {d:.2}) mm", .{ panel.origin.x, panel.origin.y }, 2);
            propText("Size", "{d:.2} × {d:.2} mm", .{ panel.w, panel.h }, 3);
            propText("Regions", "{d}", .{panel.regions.items.len}, 4);
            try panelMargins(pi);
            if (panelIssue(pi)) |i| {
                if (i.off_sheet > 0) propText("Issue", "{d:.2} mm off the sheet", .{i.off_sheet}, 20);
                if (i.ink_outside > 0) propText("Issue", "ink area {d:.2} mm in margin", .{i.ink_outside}, 21);
            }
            try propFont("Legend font", 5);
        },
        .region => |r| {
            const region = state.model.panels.items[r.panel].regions.items[r.region];
            propText("Name", "{s}", .{region.name}, 1);
            propText("Origin", "({d:.2}, {d:.2}) mm", .{ region.origin.x, region.origin.y }, 2);
            propText("Size", "{d} × {d} u", .{ region.w, region.h }, 3);
            propText("Pitch", "{d} mm", .{region.pitch}, 4);
            propText("Rows", "{d}", .{region.rows.items.len}, 5);
        },
        .row => |r| {
            const region = state.model.panels.items[r.panel].regions.items[r.region];
            const row = region.rows.items[r.row];
            propText("Row", "{d} of {d} in {s}", .{ r.row + 1, region.rows.items.len, region.name }, 1);
            propText("Gap above", "{d} u", .{row.gap}, 2);
            propText("Tiles", "{d}", .{row.places.items.len}, 3);
        },
        .tile => |id| try tileProperties(id),
    }
}

fn tileProperties(id: TileId) !void {
    const t = state.model.tileConst(id);
    propText("Designator", "{s}", .{t.designator}, 1);
    propText("Size", "{d} × {d} u", .{ t.w, t.h }, 2);
    const found = findTile(id);
    if (found) |f| {
        const pt = f.tile;
        propText("Body", "{d:.2} × {d:.2} mm", .{ pt.body.width(), pt.body.height() }, 3);
        propText("Position", "({d:.2}, {d:.2}) mm in panel", .{ pt.body.x0, pt.body.y0 }, 4);
        propText("Row", "{d}", .{pt.row + 1}, 5);
    }

    for (t.slots.items, 0..) |slot, si| {
        const n = 100 + si * 10;
        heading("Slot {s}", .{slot.name}, n);
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n + 1 });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Legend", .{}, .{ .min_size_content = .{ .w = label_width }, .gravity_y = 0.5, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
            var te = dvui.textEntry(@src(), .{ .text_initial = slot.content }, .{
                .expand = .horizontal,
                .id_extra = @backingInt(id) * 16 + si,
            });
            const changed = te.text_changed;
            const text = te.textGet();
            te.deinit();
            if (changed and !std.mem.eql(u8, text, slot.content)) try state.model.setContent(id, slot.name, text);
        }
        propText("Style", "{s}", .{state.model.styles.items[slot.style].name}, n + 2);
        try propFont("Font", n + 3);
        if (found) |f| {
            for (state.placed.items[f.panel].issues, 0..) |i, k| if (i.tile == id and i.slot == si) {
                propText("Issue", "{s}", .{@tagName(i.kind)}, n + 4 + k);
            };
            for (state.intrusions) |i| if (i.tile == id and i.slot == si) {
                propText("Issue", "ink {d:.2} mm into the sheet margin", .{i.amount}, n + 9);
            };
        }
    }
}

fn statusBar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .border = .{ .y = 1 }, .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 } });
    defer bar.deinit();
    var tiles: usize = 0;
    var labels: usize = 0;
    var missing: usize = 0;
    var overflow: usize = 0;
    for (state.placed.items) |*p| {
        tiles += p.tiles.len;
        labels += p.labels.len;
        for (p.issues) |i| switch (i.kind) {
            .missing_glyph => missing += 1,
            .label_overflow, .row_overflow => overflow += 1,
            else => {},
        };
    }
    const font = if (state.fonts.len > 0) state.fonts[state.font_choice].name else "-";
    var pos_buf: [64]u8 = undefined;
    const pos = if (state.mouse) |m_sheet| blk: {
        // Shown as the rulers count: from the ruler origin.
        const m = state.model.sheet.toRuler(m_sheet);
        const u = state.model.sheet.units;
        const k = u.perMm();
        break :blk switch (u) {
            .mm => std.fmt.bufPrint(&pos_buf, "x {d:.2}  y {d:.2} mm · ", .{ m.x * k, m.y * k }),
            .inch => std.fmt.bufPrint(&pos_buf, "x {d:.3}  y {d:.3} in · ", .{ m.x * k, m.y * k }),
        } catch "";
    } else "";
    const tool = switch (state.tool) {
        .select => "",
        .add_panel => "Add panel: drag out its outline · Esc cancels · ",
    };
    dvui.label(@src(), "{s}{s}{s}{s} · {d} panels ({d} out of compliance) · {d} tiles · {d} labels · solved in {d:.1} ms · {d} missing glyphs · {d} overflows · {d} in margins · zoom {d:.2} px/mm", .{
        pos, state.status, tool, font, state.model.panels.items.len, state.panel_issues.len, tiles, labels, state.solve_ms, missing, overflow, state.intrusions.len, state.view.ppm,
    }, .{});
}
