const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const Client = @import("wl/Client.zig");
const screencopy = @import("capture/screencopy.zig");
const Image = @import("image/Image.zig");
const png = @import("image/png.zig");
const clipboard = @import("clipboard.zig");
const niri = @import("niri.zig");
const save = @import("save.zig");
const Overlay = @import("overlay/Overlay.zig");
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const compose = @import("compose.zig").compose;
const codec = @import("image/codec.zig");
const Editor = @import("editor/Editor.zig");
const config = @import("config.zig");
const Config = config.Config;
const ocr = @import("ocr.zig");
const notify = @import("notify.zig");
const binds = @import("binds.zig");

pub const version = "1.0.0";

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return 2;
    const argv = if (args.len > 0) args[1..] else args;
    // The forked clipboard owner skips the config.
    const internal = argv.len > 0 and std.mem.eql(u8, argv[0], "__serve-clipboard");
    const cfg: Config = if (internal) .{} else config.load(init.io, arena, init.environ_map).config;
    var diag: cli.Diag = .{};
    const action = cli.parse(argv, baseOptions(cfg), &diag) catch {
        std.debug.print("pict: {s}: {s}\n\n{s}", .{ diag.arg, diag.msg, cli.usage });
        return 2;
    };
    switch (action) {
        .help => {
            writeStdout(init.io, cli.usage) catch {};
            return 0;
        },
        .version => {
            writeStdout(init.io, "pict " ++ version ++ "\n") catch {};
            return 0;
        },
        .print_config => {
            writeStdout(init.io, config.default_text) catch {};
            return 0;
        },
        .print_niri_binds => {
            printNiriBinds(init) catch |err| {
                std.debug.print("pict: {s}\n", .{describe(err)});
                return 2;
            };
            return 0;
        },
        .serve_clipboard => |s| return clipboard.serve(s.data_fd, s.ready_fd, if (s.text) .text else .png),
        .run => |o| return run(init, &cfg, o) catch |err| {
            std.debug.print("pict: {s}\n", .{describe(err)});
            return 2;
        },
    }
}

const Outcome = enum(u8) { captured = 0, cancelled = 1 };

fn baseOptions(cfg: Config) cli.Options {
    return .{
        .mode = cfg.mode,
        .cursor = cfg.cursor,
        .delay_s = cfg.delay,
        .save = cfg.save,
        .copy = cfg.copy,
        .editor = cfg.editor,
        .format = cfg.format,
        .jpeg_quality = cfg.jpeg_quality,
    };
}

fn run(init: std.process.Init, cfg: *const Config, o: cli.Options) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    if (o.edit_path) |p| return editFile(init, cfg, o, p);

    var t = Timings.init(io, o.timings);
    if (o.delay_s > 0) try io.sleep(.fromSeconds(o.delay_s), .awake);

    const client = try Client.connect(gpa);
    defer client.deinit();
    if (client.outputs.items.len == 0) return error.NoOutputs;
    const ipc = niri.Ipc.fromEnv(io, gpa, init.environ_map);
    t.mark("connect");

    var result: Image = undefined;
    // Buffer px per logical px of the capture, so the editor's 100% is 1:1.
    var image_scale: f64 = 1;
    switch (o.mode) {
        .fullscreen => if (o.all_outputs) {
            const frames = try screencopy.capture(client, client.outputs.items, o.cursor);
            defer screencopy.freeFrames(gpa, frames);
            t.mark("capture");
            const layout = layoutOf(frames);
            const images = try imagesOf(gpa, frames);
            defer gpa.free(images);
            result = try compose(gpa, &layout, images, layout.bounds, null);
            image_scale = layout.scale;
        } else {
            const target = focusedOutput(ipc, client);
            const frames = try screencopy.capture(client, &.{target}, o.cursor);
            defer screencopy.freeFrames(gpa, frames);
            t.mark("capture");
            result = try frames[0].image().crop(gpa, frames[0].image().bounds());
            image_scale = layoutOf(frames).scale;
        },
        .region, .freeform, .window => {
            const frames = try screencopy.capture(client, client.outputs.items, o.cursor);
            defer screencopy.freeFrames(gpa, frames);
            t.mark("capture");

            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            var opts: Overlay.Options = .{
                .mode = switch (o.mode) {
                    .region => .region,
                    .freeform => .freeform,
                    else => .window,
                },
                .adjust = o.adjust,
                .timings = &t,
                .autoselect = testAutoselect(init.environ_map, frames),
            };
            if (o.mode == .window) {
                const nipc = ipc orelse return error.WindowModeNeedsNiri;
                const wins = try nipc.visibleWindows(arena_state.allocator());
                opts.windows = try windowTargets(arena_state.allocator(), wins, frames);
                if (wins.tiled_positions_missing) opts.fallback_window = wins.focused_id;
                t.mark("niri");
            }

            const sel = try Overlay.select(client, frames, opts) orelse return @backingInt(Outcome.cancelled);
            t.mark("select");
            const images = try imagesOf(gpa, frames);
            defer gpa.free(images);
            image_scale = sel.layout.scale;
            result = switch (sel.result) {
                .rect => |r| try compose(gpa, &sel.layout, images, r, null),
                .lasso => |l| blk: {
                    defer gpa.free(l.points);
                    break :blk try compose(gpa, &sel.layout, images, l.bbox, l.points);
                },
                .niri_window => |id| try captureNiriWindow(io, gpa, ipc.?, init.environ_map, id),
            };
        },
    }
    defer result.deinit(gpa);
    const keep_stderr = init.environ_map.get("PICT_DEBUG") != null;

    if (o.ocr) {
        return ocrResult(init, cfg, o, result, image_scale, &t);
    }

    const bytes = try png.encode(gpa, result);
    defer gpa.free(bytes);
    t.mark("encode");

    var saved_path: ?[]u8 = null;
    defer if (saved_path) |sp| gpa.free(sp);
    if (o.save) {
        if (o.output_path) |p| {
            if (std.mem.eql(u8, p, "-")) {
                try Io.File.stdout().writeStreamingAll(io, bytes);
            } else {
                const fmt = codec.Format.fromPath(p) orelse o.format;
                saved_path = try saveEncoded(io, gpa, result, bytes, fmt, o.jpeg_quality, .{ .path = p });
                try printStdout(io, "{s}\n", .{saved_path.?});
            }
        } else {
            const dir = try cfg.saveDir(gpa, init.environ_map.get("HOME"));
            defer gpa.free(dir);
            saved_path = try saveEncoded(io, gpa, result, bytes, o.format, o.jpeg_quality, .{ .new = .{ .dir = dir, .template = cfg.filename } });
            try printStdout(io, "{s}\n", .{saved_path.?});
        }
        t.mark("save");
    }

    if (o.copy) {
        try clipboard.copyPng(bytes, keep_stderr);
        t.mark("clipboard");
    }

    t.report(result.width, result.height, bytes.len, "PNG");

    if (o.editor) {
        try Editor.run(client, &result, editorOptions(init, cfg, o, ipc, client, saved_path, image_scale));
    }
    return @backingInt(Outcome.captured);
}

const SaveWhere = union(enum) { path: []const u8, new: save.Target };

/// Write the capture in `fmt`, reusing the already-encoded PNG when that's the format.
fn saveEncoded(io: Io, gpa: Allocator, img: Image, png_bytes: []const u8, fmt: codec.Format, quality: u8, where: SaveWhere) ![]u8 {
    var other: ?[]u8 = null;
    defer if (other) |b| gpa.free(b);
    const bytes = if (fmt == .png) png_bytes else blk: {
        other = try codec.encode(gpa, img, fmt, quality);
        break :blk other.?;
    };
    return switch (where) {
        .path => |p| save.saveTo(io, gpa, p, bytes),
        .new => |tgt| save.saveNew(io, gpa, tgt, bytes, fmt.ext()),
    };
}

/// `--ocr`: print the text, copy it, and say so in a notification.
fn ocrResult(init: std.process.Init, cfg: *const Config, o: cli.Options, img: Image, image_scale: f64, t: *Timings) !u8 {
    const gpa = init.gpa;
    const text = ocr.recognize(gpa, img, cfg.ocr_language, image_scale) catch |err| {
        if (cfg.ocr_notify) notify.send("pict: text recognition failed", ocr.describe(err));
        std.debug.print("pict: {s}\n", .{ocr.describe(err)});
        return 2;
    };
    defer gpa.free(text);
    t.mark("ocr");
    if (text.len == 0) {
        if (cfg.ocr_notify) notify.send("No text found", "Nothing was copied.");
        std.debug.print("pict: no text found\n", .{});
        t.report(img.width, img.height, 0, "text");
        return @backingInt(Outcome.captured);
    }
    try printStdout(init.io, "{s}\n", .{text});
    if (o.copy) {
        try clipboard.copyText(text, init.environ_map.get("PICT_DEBUG") != null);
        t.mark("clipboard");
        if (cfg.ocr_notify) {
            var buf: [96]u8 = undefined;
            const lines = ocr.lineCount(text);
            const summary = std.fmt.bufPrint(&buf, "Copied {d} line{s} of text", .{ lines, if (lines == 1) "" else "s" }) catch "Copied text";
            notify.send(summary, preview(text));
        }
    }
    t.report(img.width, img.height, text.len, "text");
    return @backingInt(Outcome.captured);
}

/// The first few lines, for a notification body.
fn preview(text: []const u8) []const u8 {
    var end: usize = 0;
    var lines: usize = 0;
    while (end < text.len and lines < 4) : (end += 1) {
        if (text[end] == '\n') lines += 1;
    }
    return text[0..@min(end, 300)];
}

fn editorOptions(init: std.process.Init, cfg: *const Config, o: cli.Options, ipc: ?niri.Ipc, client: *Client, path: ?[]const u8, image_scale: f64) Editor.Options {
    const out = focusedOutput(ipc, client);
    const lw: f64 = @floatFromInt(if (out.logical_w > 0) out.logical_w else 1920);
    const lh: f64 = @floatFromInt(if (out.logical_h > 0) out.logical_h else 1080);
    return .{
        .io = init.io,
        .path = path,
        .save_dir = cfg.saveDir(init.arena.allocator(), init.environ_map.get("HOME")) catch null,
        .filename = cfg.filename,
        .format = o.format,
        .jpeg_quality = o.jpeg_quality,
        .image_scale = image_scale,
        .max_size = .{ lw * 0.9, lh * 0.9 },
        .auto_copy = o.copy and cfg.auto_copy,
        .confirm_close = cfg.confirm_close,
        .tool = cfg.tool,
        .font = cfg.font,
        .palette = cfg.palette,
        .highlighter_color = cfg.highlighter_color,
        .sizes = cfg.sizes,
        .ocr_language = cfg.ocr_language,
        .keep_stderr = init.environ_map.get("PICT_DEBUG") != null,
        .test_script = init.environ_map.get("PICT_TEST_EDITOR"),
    };
}

/// `pict --edit <path>`: open an existing image.
fn editFile(init: std.process.Init, cfg: *const Config, o: cli.Options, path: []const u8) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024)) catch return error.CannotReadImage;
    defer gpa.free(bytes);
    var img = try codec.decode(gpa, bytes);
    defer img.deinit(gpa);

    const client = try Client.connect(gpa);
    defer client.deinit();
    const ipc = niri.Ipc.fromEnv(io, gpa, init.environ_map);
    // A file has no capture scale; assume the focused output's, so 100% is 1:1 there.
    const out = focusedOutput(ipc, client);
    const scale: f64 = if (out.logical_w > 0 and out.mode_w > 0)
        @as(f64, @floatFromInt(@max(out.mode_w, out.mode_h))) / @as(f64, @floatFromInt(@max(out.logical_w, out.logical_h)))
    else
        1;
    try Editor.run(client, &img, editorOptions(init, cfg, o, ipc, client, path, scale));
    return @backingInt(Outcome.captured);
}

/// `pict --print-niri-binds`.
fn printNiriBinds(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const env = init.environ_map;
    const path: ?[]const u8 = if (env.get("NIRI_CONFIG")) |p| p else if (env.get("XDG_CONFIG_HOME")) |x|
        try std.fmt.allocPrint(arena, "{s}/niri/config.kdl", .{x})
    else if (env.get("HOME")) |h|
        try std.fmt.allocPrint(arena, "{s}/.config/niri/config.kdl", .{h})
    else
        null;
    const text: ?[]const u8 = if (path) |p| Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4 << 20)) catch null else null;
    const out = try binds.render(init.gpa, text, if (text != null) path else null, try exeName(init));
    defer init.gpa.free(out);
    try writeStdout(io, out);
}

/// "pict" when the first "pict" on $PATH is this binary, else this binary's full path.
fn exeName(init: std.process.Init) ![]const u8 {
    const arena = init.arena.allocator();
    const self = std.process.executablePathAlloc(init.io, arena) catch return "pict";
    const path_env = init.environ_map.get("PATH") orelse return self;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const cand = try std.fs.path.join(arena, &.{ dir, "pict" });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = Io.Dir.cwd().realPathFile(init.io, cand, &buf) catch continue;
        return if (std.mem.eql(u8, buf[0..len], self)) "pict" else self;
    }
    return self;
}

fn focusedOutput(ipc: ?niri.Ipc, client: *Client) *Client.Output {
    if (ipc) |nipc| {
        var buf: [128]u8 = undefined;
        if (nipc.focusedOutputName(&buf)) |maybe| {
            if (maybe) |name| if (client.findOutput(name)) |out| return out;
        } else |err| std.log.warn("niri IPC failed ({t}); using the first output", .{err});
    }
    return client.outputs.items[0];
}

/// Canvas layout for frames without an overlay (no exact fractional scale available).
fn layoutOf(frames: []const screencopy.Frame) Layout {
    var geoms: [layout_mod.max_outputs]layout_mod.OutputGeom = undefined;
    const n = @min(frames.len, layout_mod.max_outputs);
    for (frames[0..n], 0..) |f, i| {
        const o = f.output;
        const b = f.buffer.?;
        const lw: f64 = @floatFromInt(if (o.logical_w > 0) o.logical_w else @as(i32, @intCast(b.width)));
        const lh: f64 = @floatFromInt(if (o.logical_h > 0) o.logical_h else @as(i32, @intCast(b.height)));
        geoms[i] = layout_mod.OutputGeom.fromSizes(@floatFromInt(o.logical_x), @floatFromInt(o.logical_y), lw, lh, @intCast(b.width), @intCast(b.height), null);
    }
    return Layout.init(geoms[0..n]);
}

fn imagesOf(gpa: Allocator, frames: []const screencopy.Frame) ![]Image {
    const images = try gpa.alloc(Image, frames.len);
    for (frames, images) |*f, *img| img.* = f.image();
    return images;
}

/// Hoverable windows for the overlay, topmost first: floating (most recently focused
/// first), then tiled (tiles don't overlap).
fn windowTargets(arena: Allocator, wins: niri.Windows, frames: []const screencopy.Frame) ![]Overlay.WindowTarget {
    var list: std.ArrayList(Overlay.WindowTarget) = .empty;
    var order: std.ArrayList(niri.Window) = .empty;
    for (wins.items) |w| if (w.rect != null) try order.append(arena, w);
    std.mem.sort(niri.Window, order.items, {}, struct {
        fn lt(_: void, a: niri.Window, b: niri.Window) bool {
            if (a.is_floating != b.is_floating) return a.is_floating;
            return a.focus_ts > b.focus_ts;
        }
    }.lt);
    for (order.items) |w| {
        const idx = for (frames, 0..) |f, i| {
            if (f.output.name) |n| if (std.mem.eql(u8, n, w.output)) break i;
        } else continue;
        try list.append(arena, .{
            .id = w.id,
            .output = idx,
            .lrect = w.rect.?,
            .label = if (w.app_id.len > 0) w.app_id else w.title,
        });
    }
    return list.items;
}

/// Have niri render window `id` to a temp file, then load it. niri writes the file
/// asynchronously, so poll until it decodes.
fn captureNiriWindow(io: Io, gpa: Allocator, ipc: niri.Ipc, env: *const std.process.Environ.Map, id: u64) !Image {
    const dir = env.get("XDG_RUNTIME_DIR") orelse "/tmp";
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/pict-window-{d}.png", .{ dir, std.c.getpid() });
    Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    try ipc.screenshotWindow(id, path);
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 10) {
        if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024))) |bytes| {
            defer gpa.free(bytes);
            if (png.decode(gpa, bytes)) |img| return img else |_| {}
        } else |_| {}
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.NiriScreenshotTimeout;
}

/// PICT_TEST_AUTOSELECT="OUTPUT:x,y,w,h" (physical px on that output) drives the overlay
/// without input, for automated smoke tests.
fn testAutoselect(env: *const std.process.Environ.Map, frames: []const screencopy.Frame) ?Overlay.Auto {
    const spec = env.get("PICT_TEST_AUTOSELECT") orelse return null;
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    const name = spec[0..colon];
    var it = std.mem.splitScalar(u8, spec[colon + 1 ..], ',');
    var v: [4]i32 = undefined;
    for (&v) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    for (frames, 0..) |f, i| {
        if (f.output.name) |n| if (std.mem.eql(u8, n, name)) {
            return .{ .output = i, .rect = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] } };
        };
    }
    return null;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NoWaylandDisplay => "cannot connect to a Wayland display (is WAYLAND_DISPLAY set?)",
        error.NoScreencopy => "compositor offers no capture protocol (need zwlr_screencopy_manager_v1)",
        error.NoLayerShell => "compositor offers no zwlr_layer_shell_v1; the overlay needs it",
        error.NoSeat => "no input seat; the overlay needs a pointer",
        error.CaptureFailed => "screen capture failed",
        error.UnsupportedFormat => "compositor offered an unsupported pixel format",
        error.NoOutputs => "no outputs found",
        error.NoHome => "HOME is not set",
        error.WindowModeNeedsNiri => "--window needs niri ($NIRI_SOCKET is not set)",
        error.NiriScreenshotTimeout => "niri did not produce the window screenshot in time",
        error.CannotReadImage => "cannot read the image file",
        error.UnknownImageFormat => "not a PNG, JPEG or WebP image",
        error.NoXdgShell => "compositor offers no xdg_wm_base; the editor needs it",
        error.WlCopyFailed => "clipboard: no data-control protocol and wl-copy failed",
        error.TemplateTooLong => "the [output] filename template expands to more than 255 bytes",
        else => @errorName(err),
    };
}

fn writeStdout(io: Io, s: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, s);
}

fn printStdout(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

pub const Timings = struct {
    io: Io,
    enabled: bool,
    start: Io.Timestamp,
    last: Io.Timestamp,
    marks: [12]Mark = undefined,
    n: usize = 0,

    const Mark = struct { name: []const u8, ns: i96 };

    pub fn init(io: Io, enabled: bool) Timings {
        const now = Io.Timestamp.now(io, .awake);
        return .{ .io = io, .enabled = enabled, .start = now, .last = now };
    }

    pub fn mark(t: *Timings, name: []const u8) void {
        if (!t.enabled or t.n == t.marks.len) return;
        const now = Io.Timestamp.now(t.io, .awake);
        t.marks[t.n] = .{ .name = name, .ns = t.last.durationTo(now).toNanoseconds() };
        t.n += 1;
        t.last = now;
    }

    fn report(t: *Timings, w: u32, h: u32, out_len: usize, what: []const u8) void {
        if (!t.enabled) return;
        std.debug.print("pict timings ({d}x{d}, {d} KiB {s}):\n", .{ w, h, out_len / 1024, what });
        for (t.marks[0..t.n]) |m| std.debug.print("  {s:<10} {d:>8.2} ms\n", .{ m.name, ms(m.ns) });
        std.debug.print("  {s:<10} {d:>8.2} ms\n", .{ "total", ms(t.start.durationTo(t.last).toNanoseconds()) });
    }

    fn ms(ns: i96) f64 {
        return @as(f64, @floatFromInt(ns)) / 1e6;
    }
};

test {
    _ = @import("geom.zig");
    _ = cli;
    _ = Image;
    _ = png;
    _ = save;
    _ = @import("overlay/selection.zig");
    _ = layout_mod;
    _ = @import("compose.zig");
    _ = @import("editor/doc.zig");
    _ = @import("editor/effects.zig");
    _ = @import("image/codec.zig");
    _ = @import("editor/render.zig");
    _ = @import("editor/icons.zig");
    _ = @import("editor/toolbar.zig");
    _ = @import("editor/portal.zig");
    _ = @import("editor/autocopy.zig");
    _ = @import("config.zig");
    _ = @import("ocr.zig");
    _ = @import("notify.zig");
    _ = @import("binds.zig");
}
