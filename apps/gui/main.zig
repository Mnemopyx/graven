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
    if (dvui.backend.kind == .sdl3) _ = dvui.backend.c.SDL_SetHint(dvui.backend.c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");
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
    panel: usize = 0,
    labels: ?layout.Labels = null,
    placed: ?layout.place.Placed = null,
    placed_rev: u64 = std.math.maxInt(u64),
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
    context: Context = .file,
    /// Tree nodes the user has opened or closed, by context key.
    expanded: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    status: []const u8 = "",
};

/// The current context: a node of the component tree.
const Context = union(enum) {
    file,
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
    state.panel = try samples.pc_keyboard.build(state.gpa, &state.model, .{ .main = main_style, .small = small });
    state.context = .{ .panel = state.panel };
    state.view = .{};
}

fn deinit(_: *dvui.Window) void {
    if (state.placed) |*p| p.deinit();
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
        if (state.placed) |*p| p.deinit();
        state.placed = null;
        if (state.labels) |*l| l.deinit();
        if (state.face) |old| old.deinit();
        state.face = face;
        state.faces = .{face};
        state.labels = .init(state.gpa, &state.faces);
        state.font_loaded = state.font_choice;
        state.placed_rev = std.math.maxInt(u64);
    }
    const labels = if (state.labels) |*l| l else return;
    if (state.model.panels.items.len == 0) {
        if (state.placed) |*p| p.deinit();
        state.placed = null;
        return;
    }
    if (state.placed_rev == state.model.revision and state.placed != null) return;
    const t0: std.Io.Timestamp = .now(dvui.io, .awake);
    const placed = try layout.solve(state.gpa, &state.model, state.panel, labels);
    state.solve_ms = @as(f64, @floatFromInt(t0.untilNow(dvui.io, .awake).toNanoseconds())) / 1e6;
    if (state.placed) |*p| p.deinit();
    state.placed = placed;
    state.placed_rev = state.model.revision;
    state.flat.reset(state.flat.tol);
}

fn frame() !dvui.App.Result {
    try update();

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();

    if (menu()) |r| return r;

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

fn menu() ?dvui.App.Result {
    var m = dvui.menu(@src(), .horizontal, .{ .expand = .horizontal, .background = true });
    defer m.deinit();
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        if (state.model.panels.items.len == 0) {
            if (dvui.menuItemLabel(@src(), "Add sample: PC keyboard", .{}, .{ .expand = .horizontal }) != null) {
                loadSample() catch |err| dvui.log.err("loading the sample: {s}", .{@errorName(err)});
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
    if (!treeNode(.file, state.file_name, 0, state.model.panels.items.len > 0, !state.file_name_set)) return;
    for (state.model.panels.items, 0..) |panel, pi| {
        if (!treeNode(.{ .panel = pi }, panel.name, 1, panel.regions.items.len > 0, false)) continue;
        for (panel.regions.items, 0..) |region, ri| {
            if (!treeNode(.{ .region = .{ .panel = pi, .region = ri } }, region.name, 2, region.rows.items.len > 0, false)) continue;
            for (region.rows.items, 0..) |row, rowi| {
                const title = std.fmt.bufPrint(&name_buf, "Row {d}", .{rowi + 1}) catch "Row";
                if (!treeNode(.{ .row = .{ .panel = pi, .region = ri, .row = rowi } }, title, 3, row.places.items.len > 0, false)) continue;
                for (row.places.items) |p| {
                    const t = state.model.tileConst(p.tile);
                    const legend = if (t.slots.items.len > 0) t.slots.items[0].content else "";
                    const text = std.fmt.bufPrint(&name_buf, "{s}  {s}", .{ t.designator, legend }) catch t.designator;
                    _ = treeNode(.{ .tile = p.tile }, text, 4, false, false);
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
        .file, .panel, .region => true,
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
    if (dvui.labelClick(@src(), "{s}", .{text}, .{}, .{
        .expand = .horizontal,
        .background = selected,
        .color_fill = if (selected) .{ .color = dvui.themeGet().focus.opacity(0.25) } else null,
        .font = styled(if (depth == 0) .theme(.heading) else .theme(.body), default),
    })) state.context = ctx;
    return open;
}

/// Opens the tree down to `ctx`, so a context chosen on the canvas shows.
fn revealInTree(ctx: Context) void {
    const placed = if (state.placed) |*p| p else return;
    const id = switch (ctx) {
        .tile => |t| t,
        else => return,
    };
    const pt = placed.findTile(id) orelse return;
    const pi = state.panel;
    for ([_]Context{
        .file,
        .{ .panel = pi },
        .{ .region = .{ .panel = pi, .region = pt.region } },
        .{ .row = .{ .panel = pi, .region = pt.region, .row = pt.row } },
    }) |c| state.expanded.put(state.gpa, c.key(), true) catch {};
}

/// Whether a placed tile belongs to the context, for canvas highlighting.
fn inContext(t: layout.place.PlacedTile) bool {
    return switch (state.context) {
        .tile => |id| t.id == id,
        .row => |r| r.panel == state.panel and t.region == r.region and t.row == r.row,
        .region => |r| r.panel == state.panel and t.region == r.region,
        .file, .panel => false,
    };
}

/// The context's extents in the panel frame, mm.
fn contextExtents(placed: *const layout.place.Placed) geom.Box {
    const panel = state.model.panels.items[state.panel];
    var b: geom.Box = .empty;
    switch (state.context) {
        .file, .panel => return .{ .x0 = 0, .y0 = 0, .x1 = panel.w, .y1 = panel.h },
        else => for (placed.tiles) |t| {
            if (inContext(t)) b = b.join(t.pitch_box);
        },
    }
    return if (b.isEmpty()) placed.bounds else b;
}

/// Centres the context in the canvas and zooms it to fill the canvas.
fn zoomToContext() void {
    const placed = if (state.placed) |*p| p else return;
    state.view.fit = contextExtents(placed);
}

const colors = struct {
    const paper: dvui.Color = .{ .r = 0xfb, .g = 0xfa, .b = 0xf7 };
    const body: dvui.Color = .{ .r = 0xe4, .g = 0xe2, .b = 0xdc };
    const edge: dvui.Color = .{ .r = 0x9a, .g = 0x97, .b = 0x8f };
    const face: dvui.Color = .{ .r = 0xf6, .g = 0xf5, .b = 0xf1 };
    const ink: dvui.Color = .{ .r = 0x1d, .g = 0x1d, .b = 0x1b };
    const missing: dvui.Color = .{ .r = 0xf6, .g = 0xd5, .b = 0xcf };
    const overflow: dvui.Color = .{ .r = 0xc2, .g = 0x41, .b = 0x2d };
};

/// The canvas: the placed panel at true proportions. Wheel zooms about the
/// pointer, dragging pans, a click makes a tile (or the panel) the context,
/// and the context's tiles are outlined.
fn canvas() void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = .{ .color = colors.paper } });
    defer box.deinit();
    const placed = if (state.placed) |*p| p else {
        dvui.labelNoFmt(@src(), "Nothing here yet. File › Add sample: PC keyboard", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.5) },
        });
        return;
    };
    const area = box.data().contentRectScale().r;
    if (area.w <= 0 or area.h <= 0) return;

    // The first frame fits the file's extents.
    if (state.view.ppm == 0 and state.view.fit == null) state.view.fit = contextExtents(placed);
    if (state.view.fit) |b| {
        state.view.cx = (b.x0 + b.x1) / 2;
        state.view.cy = (b.y0 + b.y1) / 2;
        state.view.ppm = 0.92 * @min(area.w / b.width(), area.h / b.height());
    }
    const clip = dvui.clip(area);
    defer dvui.clipSet(clip);

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, box.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
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
            .press => if (me.button.pointer() or me.button == .middle) {
                e.handle(@src(), box.data());
                dvui.captureMouse(box.data(), e.num);
                dvui.dragPreStart(me.button, me.p, .{});
            },
            .motion => if (dvui.captured(box.data().id)) {
                if (dvui.dragging(me, null)) |d| {
                    e.handle(@src(), box.data());
                    state.view.fit = null;
                    state.view.cx -= d.x / state.view.ppm;
                    state.view.cy += d.y / state.view.ppm;
                    dvui.refresh(null, @src(), box.data().id);
                }
            },
            .release => if (dvui.captured(box.data().id)) {
                e.handle(@src(), box.data());
                if (dvui.dragging(me, null) == null) {
                    // A click on a tile makes it the context; elsewhere, the panel.
                    const at = state.view.toMm(area, me.p);
                    state.context = .{ .panel = state.panel };
                    for (placed.tiles) |t| {
                        if (at.x >= t.body.x0 and at.x <= t.body.x1 and at.y >= t.body.y0 and at.y <= t.body.y1) state.context = .{ .tile = t.id };
                    }
                    revealInTree(state.context);
                    dvui.refresh(null, @src(), box.data().id);
                }
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
            },
            else => {},
        }
    }

    const radius: f32 = @floatCast(1.0 * state.view.ppm);
    for (placed.tiles) |t| {
        const flagged = tileFlag(placed, t.id);
        const body = state.view.rect(area, t.body);
        body.fill(.round(radius), .{ .color = .{ .color = colors.body } });
        const in_context = inContext(t);
        body.stroke(.round(radius), .{ .thickness = 1, .color = .{ .color = if (in_context) dvui.themeGet().focus else colors.edge } });
        state.view.rect(area, t.face).fill(.round(radius), .{ .color = .{ .color = if (flagged.missing) colors.missing else colors.face } });
        if (flagged.overflow) state.view.rect(area, t.face).stroke(.round(radius), .{ .thickness = 1.5, .color = .{ .color = colors.overflow } });
        if (in_context) body.stroke(.round(radius), .{ .thickness = if (state.context == .tile) 3 else 2, .color = .{ .color = dvui.themeGet().focus } });
    }

    // Re-flatten when the zoom has moved more than 2x since the last time.
    const tol = 0.2 / state.view.ppm;
    if (state.flat.tol == 0 or tol < state.flat.tol / 2 or tol > state.flat.tol * 2) state.flat.reset(tol);
    const lifo = dvui.currentWindow().lifo();
    for (placed.labels) |l| {
        const contours = state.flat.get(l.render, &state.faces) catch continue;
        const paths = lifo.alloc(dvui.Path, contours.len) catch continue;
        defer lifo.free(paths);
        var made: usize = 0;
        defer for (paths[0..made]) |p| lifo.free(p.points);
        for (contours, paths) |c, *p| {
            const pts = lifo.alloc(dvui.Point.Physical, c.len) catch break;
            for (c, pts) |q, *o| o.* = state.view.toPx(area, .{ .x = q.x + l.origin.x, .y = q.y + l.origin.y });
            p.* = .{ .points = pts };
            made += 1;
        }
        dvui.Path.fill(paths[0..made], .{ .color = .{ .color = colors.ink }, .fade = 1 });
    }
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
}

fn lowerKind() []const u8 {
    return switch (state.context) {
        .file => "file",
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
            propValue("Name", !state.file_name_set, "{s}", .{state.file_name}, 1);
            propText("Panels", "{d}", .{state.model.panels.items.len}, 2);
            propText("Tiles", "{d}", .{state.model.tiles.items.len}, 3);
            try propFont("Legend font", 4);
        },
        .panel => |pi| {
            const panel = state.model.panels.items[pi];
            propText("Name", "{s}", .{panel.name}, 1);
            propText("Size", "{d:.2} × {d:.2} mm", .{ panel.w, panel.h }, 2);
            propText("Regions", "{d}", .{panel.regions.items.len}, 3);
            try propFont("Legend font", 4);
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
    if (state.placed) |*p| if (p.findTile(id)) |pt| {
        propText("Body", "{d:.2} × {d:.2} mm", .{ pt.body.width(), pt.body.height() }, 3);
        propText("Position", "({d:.2}, {d:.2}) mm", .{ pt.body.x0, pt.body.y0 }, 4);
        propText("Row", "{d}", .{pt.row + 1}, 5);
    };

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
            if (changed) try state.model.setContent(id, slot.name, text);
        }
        propText("Style", "{s}", .{state.model.styles.items[slot.style].name}, n + 2);
        try propFont("Font", n + 3);
        if (state.placed) |*p| {
            for (p.issues, 0..) |i, k| if (i.tile == id and i.slot == si) {
                propText("Issue", "{s}", .{@tagName(i.kind)}, n + 4 + k);
            };
        }
    }
}

fn statusBar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .border = .{ .y = 1 }, .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 } });
    defer bar.deinit();
    const p = if (state.placed) |*p| p else {
        dvui.labelNoFmt(@src(), "No panels", .{}, .{});
        return;
    };
    var missing: usize = 0;
    var overflow: usize = 0;
    for (p.issues) |i| switch (i.kind) {
        .missing_glyph => missing += 1,
        .label_overflow, .row_overflow => overflow += 1,
        else => {},
    };
    const font = if (state.fonts.len > 0) state.fonts[state.font_choice].name else "-";
    dvui.label(@src(), "{s} · {d} tiles · {d} labels · solved in {d:.1} ms · {d} missing glyphs · {d} overflows · zoom {d:.2} px/mm", .{
        font, p.tiles.len, p.labels.len, state.solve_ms, missing, overflow, state.view.ppm,
    }, .{});
}
