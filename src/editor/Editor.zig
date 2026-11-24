//! The annotation editor: an xdg_toplevel with a toolbar over a zoomable canvas.
//!
//! Rendering is CPU-side with Cairo into wl_shm buffers sized for the exact fractional
//! scale (wp_fractional_scale_v1 + wp_viewporter). The base image and committed
//! annotations are rendered once into a scene cache for the current view; each frame
//! copies the scene, repaints the toolbar, and draws only the live parts on top (the
//! stroke being drawn, the crop frame, the cursor ring). Damage covers just what changed.
//!
//! The window opens floating in niri: its first commit fixes min = max size (niri
//! floats fixed-size windows), and the limits are lifted once it's mapped.

const Editor = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const xdg = wayland.client.xdg;
const c = @import("c");

const Client = @import("../wl/Client.zig");
const shm = @import("../wl/shm.zig");
const Image = @import("../image/Image.zig");
const codec = @import("../image/codec.zig");
const png = @import("../image/png.zig");
const save_mod = @import("../save.zig");
const Rect = @import("../geom.zig").Rect;
const doc_mod = @import("doc.zig");
const Doc = doc_mod.Doc;
const Obj = doc_mod.Obj;
const Pt = doc_mod.Pt;
const Kind = doc_mod.Kind;
const Color = doc_mod.Color;
const Renderer = @import("render.zig").Renderer;
const toolbar = @import("toolbar.zig");
const Tool = toolbar.Tool;
const Item = toolbar.Item;
const theme = toolbar.theme;
const icons = @import("icons.zig");
const autocopy = @import("autocopy.zig");
const AutoCopy = autocopy.AutoCopy;
const portal = @import("portal.zig");
const OcrJob = @import("ocrjob.zig").OcrJob;
const ocrjob = @import("ocrjob.zig");
const clipboard = @import("../clipboard.zig");
const ocr = @import("../ocr.zig");

pub const Options = struct {
    io: Io,
    /// File that Ctrl+S writes. Null: a new file in `save_dir`.
    path: ?[]const u8 = null,
    /// Absolute directory for new files (and where Save As starts).
    save_dir: ?[]const u8 = null,
    /// strftime(3) template for new file names.
    filename: [:0]const u8 = "Screenshot_%Y-%m-%d_%H-%M-%S",
    /// Format for new files; Save As picks from the chosen name.
    format: codec.Format = .png,
    jpeg_quality: u8 = codec.default_jpeg_quality,
    /// Buffer px per logical px the image was captured at, so 100% maps 1:1.
    image_scale: f64 = 1,
    /// Largest logical window size.
    max_size: [2]f64 = .{ 1600, 1000 },
    /// Re-copy to the clipboard after every edit.
    auto_copy: bool = true,
    /// Ask for a second Esc before discarding unsaved changes.
    confirm_close: bool = true,
    tool: Tool = .pen,
    /// Pango font for the text tool.
    font: [:0]const u8 = "Sans Bold",
    palette: [8]Color = toolbar.default_palette,
    highlighter_color: Color = toolbar.default_palette[2],
    /// Starting size per tool (image px).
    sizes: [@typeInfo(Tool).@"enum".field_names.len]f32 = defaultSizes(),
    /// Tesseract language(s) for Copy text.
    ocr_language: [:0]const u8 = "eng",
    keep_stderr: bool = false,
    /// PICT_TEST_EDITOR: scripted input for automated tests (see `Script`).
    test_script: ?[]const u8 = null,
};

const margin: f64 = 16;
const min_h: f64 = 240;
const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;
const close_confirm_ms = 3000;
const toast_ms = 2200;

const size_steps = [_]f32{ 1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 64, 80, 96, 128 };

fn defaultSizes() [@typeInfo(Tool).@"enum".field_names.len]f32 {
    var s: [@typeInfo(Tool).@"enum".field_names.len]f32 = undefined;
    for (&s, 0..) |*v, i| v.* = defaultSize(@fromBackingInt(@intCast(i)));
    return s;
}

fn defaultSize(t: Tool) f32 {
    return switch (t) {
        .pen, .line, .arrow, .rect, .ellipse => 4,
        .highlighter => 20,
        .eraser => 16,
        .text => 28,
        .blur => 12,
        .pixelate => 14,
        .crop, .picker => 0,
    };
}

fn toolKind(t: Tool) ?Kind {
    return switch (t) {
        .pen => .pen,
        .highlighter => .highlighter,
        .line => .line,
        .arrow => .arrow,
        .rect => .rect,
        .ellipse => .ellipse,
        .text => .text,
        .blur => .blur,
        .pixelate => .pixelate,
        .eraser, .crop, .picker => null,
    };
}

const Handle = enum { nw, n, ne, e, se, s, sw, w, move, new };

const Gesture = union(enum) {
    none,
    stroke: struct { kind: Kind, pts: std.ArrayList(Pt), straight: bool },
    shape: struct { kind: Kind, a: Pt, b: Pt },
    erase: struct { ids: std.ArrayList(u32), last: Pt },
    pan: struct { ptr: [2]f64, pan: [2]f64 },
    crop: struct { handle: Handle, start: Pt, orig: Rect },
    sv,
    hue,
};

const TextEdit = struct {
    buf: std.ArrayList(u8) = .empty,
    at: Pt,
    color: Color,
    size: f32,
    replacing: ?u32 = null,
};

const SceneKey = struct {
    rev: u64,
    k: f64,
    pan: [2]i32,
    w: u32,
    h: u32,
    vr: Rect,
    skip: ?u32,

    fn eql(a: SceneKey, b: SceneKey) bool {
        return a.rev == b.rev and a.k == b.k and a.pan[0] == b.pan[0] and a.pan[1] == b.pan[1] and
            a.w == b.w and a.h == b.h and a.vr.eql(b.vr) and a.skip == b.skip;
    }
};

gpa: Allocator,
client: *Client,
opts: Options,
img: *const Image,
doc: Doc,
rend: Renderer,
path: ?[]u8 = null,

surface: ?*wl.Surface = null,
xdg_surface: ?*xdg.Surface = null,
toplevel: ?*xdg.Toplevel = null,
viewport: ?*wp.Viewport = null,
fractional: ?*wp.FractionalScaleV1 = null,
frame_cb: ?*wl.Callback = null,
configured: bool = false,
relaxed: bool = false,
presented: u32 = 0,
want_w: i32 = 0,
want_h: i32 = 0,
min_w: i32 = 0,
win_w: i32 = 0,
win_h: i32 = 0,
scale: f64 = 1,
buf_w: u32 = 0,
buf_h: u32 = 0,
tb_px: u32 = 0,
bufs: [3]?*shm.Buffer = .{ null, null, null },
last_buf: ?*shm.Buffer = null,

scene: ?*c.cairo_surface_t = null,
scene_key: ?SceneKey = null,
dirty: bool = true,
full_damage: bool = true,
dyn_prev: ?Rect = null,
tb_hash: u64 = 0,
tb: toolbar.Layout = .{},

pointer: ?*wl.Pointer = null,
keyboard: ?*wl.Keyboard = null,
cursor_dev: ?*wp.CursorShapeDeviceV1 = null,
enter_serial: u32 = 0,
cur_shape: ?wp.CursorShapeDeviceV1.Shape = null,
ptr: [2]f64 = .{ -1, -1 },
ptr_in: bool = false,
axis: struct { v: f64 = 0, h: f64 = 0, v120: i32 = 0, h120: i32 = 0, wheel: bool = false } = .{},

xkb_ctx: ?*c.struct_xkb_context = null,
xkb_keymap: ?*c.struct_xkb_keymap = null,
xkb_state: ?*c.struct_xkb_state = null,
repeat_rate: i32 = 25,
repeat_delay: i32 = 600,
repeat_key: ?u32 = null,
repeat_next: i64 = 0,
space_down: bool = false,
test_mods: ?struct { ctrl: bool, shift: bool } = null,

tool: Tool = .pen,
prev_tool: Tool = .pen,
sizes: [@typeInfo(Tool).@"enum".field_names.len]f32 = undefined,
ink: Color = toolbar.default_palette[0],
highlight: Color = toolbar.default_palette[2],
zoom: f64 = 1,
pan: [2]f64 = .{ 0, 0 },
fit: bool = true,
last_vr: ?Rect = null,
hover: ?Item = null,
pressed: ?Item = null,
gesture: Gesture = .none,
text: ?TextEdit = null,
crop_pending: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
popover: bool = false,
hsv: [3]f32 = .{ 0, 1, 1 },
sv_surf: ?*c.cairo_surface_t = null,
sv_key: [2]f64 = .{ -1, -1 },

toast_buf: [160]u8 = undefined,
toast_len: usize = 0,
toast_until: i64 = 0,
close_armed_until: i64 = 0,
quit: bool = false,

ac: AutoCopy,
dialog: ?*portal.SaveDialog = null,
ocr_job: ?*OcrJob = null,
script: ?Script = null,

/// Show the editor for `img` until the window is closed. `img` must outlive the call.
pub fn run(client: *Client, img: *const Image, opts: Options) !void {
    const gpa = client.gpa;
    const compositor = client.compositor orelse return error.NoCompositor;
    const wm_base = client.wm_base orelse return error.NoXdgShell;
    const viewporter = client.viewporter orelse return error.NoViewporter;
    const seat = client.seat orelse return error.NoSeat;

    var ed: Editor = .{
        .gpa = gpa,
        .client = client,
        .opts = opts,
        .img = img,
        .doc = Doc.init(gpa, img.width, img.height),
        .rend = try Renderer.init(gpa, img, opts.font),
        .ac = try AutoCopy.init(opts.auto_copy, 0, opts.keep_stderr),
        .scale = opts.image_scale,
    };
    defer ed.teardown();
    ed.sizes = opts.sizes;
    // Crop and picker have no size; keep them at 0 whatever the caller passed.
    ed.sizes[@backingInt(Tool.crop)] = 0;
    ed.sizes[@backingInt(Tool.picker)] = 0;
    ed.ink = opts.palette[0];
    ed.highlight = opts.highlighter_color;
    ed.tool = if (opts.tool == .crop or opts.tool == .picker) .pen else opts.tool;
    ed.prev_tool = ed.tool;
    if (opts.path) |p| ed.path = try gpa.dupe(u8, p);
    if (opts.test_script) |s| ed.script = Script.init(s);
    ed.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);

    // Window size: the image at 100% plus margins, within the toolbar width and the
    // output.
    const iw = @as(f64, @floatFromInt(img.width)) / opts.image_scale;
    const ih = @as(f64, @floatFromInt(img.height)) / opts.image_scale;
    const minw = toolbar.minWidth();
    ed.min_w = @intFromFloat(@ceil(minw));
    ed.want_w = @intFromFloat(@round(std.math.clamp(iw + 2 * margin, minw, @max(minw, opts.max_size[0]))));
    ed.want_h = @intFromFloat(@round(std.math.clamp(ih + toolbar.height + 2 * margin, min_h, @max(min_h, opts.max_size[1]))));

    const surface = try compositor.createSurface();
    ed.surface = surface;
    ed.viewport = try viewporter.getViewport(surface);
    if (client.fractional_scale) |fs| {
        if (fs.getFractionalScale(surface)) |f| {
            ed.fractional = f;
            f.setListener(*Editor, fractionalListener, &ed);
        } else |_| {}
    }
    const xs = try wm_base.getXdgSurface(surface);
    ed.xdg_surface = xs;
    xs.setListener(*Editor, xdgSurfaceListener, &ed);
    const tl = try xs.getToplevel();
    ed.toplevel = tl;
    tl.setListener(*Editor, toplevelListener, &ed);
    tl.setAppId("pict");
    tl.setTitle("pict");
    // niri opens fixed-size windows floating; the limits are lifted after mapping.
    tl.setMinSize(ed.want_w, ed.want_h);
    tl.setMaxSize(ed.want_w, ed.want_h);
    surface.commit();

    const pointer = try seat.getPointer();
    ed.pointer = pointer;
    pointer.setListener(*Editor, pointerListener, &ed);
    if (client.cursor_shape) |cs| ed.cursor_dev = cs.getPointer(pointer) catch null;
    if (client.seat_caps.keyboard) {
        const kb = try seat.getKeyboard();
        ed.keyboard = kb;
        kb.setListener(*Editor, keyboardListener, &ed);
    }

    try ed.loop();
    ed.ac.flush(ed.doc.rev, FlattenCtx{ .ed = &ed });
}

fn teardown(ed: *Editor) void {
    ed.cancelGesture();
    if (ed.text) |*t| t.buf.deinit(ed.gpa);
    if (ed.dialog) |d| d.deinit();
    if (ed.ocr_job) |j| j.cancel();
    ed.ac.deinit();
    if (ed.sv_surf) |s| c.cairo_surface_destroy(s);
    if (ed.scene) |s| c.cairo_surface_destroy(s);
    if (ed.frame_cb) |cb| cb.destroy();
    if (ed.cursor_dev) |d| d.destroy();
    if (ed.pointer) |p| p.release();
    if (ed.keyboard) |k| k.release();
    if (ed.fractional) |f| f.destroy();
    if (ed.viewport) |v| v.destroy();
    if (ed.toplevel) |t| t.destroy();
    if (ed.xdg_surface) |x| x.destroy();
    if (ed.surface) |s| s.destroy();
    for (ed.bufs) |b| if (b) |buf| buf.destroy(ed.gpa);
    ed.client.roundtrip() catch {};
    if (ed.xkb_state) |s| c.xkb_state_unref(s);
    if (ed.xkb_keymap) |k| c.xkb_keymap_unref(k);
    if (ed.xkb_ctx) |x| c.xkb_context_unref(x);
    if (ed.path) |p| ed.gpa.free(p);
    ed.rend.deinit();
    ed.doc.deinit();
}

const FlattenCtx = struct {
    ed: *Editor,
    pub fn flatten(f: FlattenCtx) !Image {
        return f.ed.rend.flatten(autocopy.alloc, &f.ed.doc);
    }
};

// ---------------------------------------------------------------------------
// Event loop

fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

fn loop(ed: *Editor) !void {
    const display = ed.client.display;
    const wl_fd = display.getFd();
    var last_rev = ed.doc.rev;
    while (!ed.quit) {
        if (display.dispatchPending() != .SUCCESS) return error.WaylandDispatchFailed;
        const t = now();
        ed.tick(t);
        if (ed.doc.rev != last_rev) {
            last_rev = ed.doc.rev;
            ed.ac.changed(t);
            ed.dirty = true;
        }
        ed.ac.poll(t, ed.doc.rev, ed.gesture != .none or ed.text != null, FlattenCtx{ .ed = ed });
        if (ed.quit) break;
        if (ed.dirty) ed.render();

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.WaylandDispatchFailed;
        }
        _ = display.flush();

        var fds: [4]posix.pollfd = undefined;
        var n: usize = 0;
        fds[n] = .{ .fd = wl_fd, .events = posix.POLL.IN, .revents = 0 };
        n += 1;
        const ac_i = n;
        if (ed.ac.fd()) |f| {
            fds[n] = .{ .fd = f, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        const dlg_i = n;
        if (ed.dialog) |d| {
            fds[n] = .{ .fd = d.fd(), .events = d.events(), .revents = 0 };
            n += 1;
        }
        if (ed.ocr_job) |j| {
            fds[n] = .{ .fd = j.fd(), .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        const timeout = ed.nextTimeout(now());
        _ = posix.poll(fds[0..n], timeout) catch 0;

        if (fds[0].revents & posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) return error.WaylandReadFailed;
        } else {
            display.cancelRead();
        }
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return error.WaylandDisconnected;
        _ = ac_i;
        if (ed.dialog != null and n > dlg_i) ed.dialog.?.process();
    }
}

fn nextTimeout(ed: *Editor, t: i64) i32 {
    var best: i64 = 60_000;
    if (ed.ac.timeout(t)) |d| best = @min(best, d);
    if (ed.ac.fd() != null) best = @min(best, 50);
    if (ed.repeat_key != null) best = @min(best, @max(0, ed.repeat_next - t));
    if (ed.toast_len > 0) best = @min(best, @max(0, ed.toast_until - t));
    if (ed.script) |sc| best = @min(best, @max(1, sc.resume_at - t));
    if (ed.dialog != null) best = @min(best, 250);
    return @intCast(@max(0, best));
}

fn tick(ed: *Editor, t: i64) void {
    if (ed.ocr_job) |j| if (j.take()) |res| {
        ed.ocr_job = null;
        ed.ocrDone(res);
    };
    if (ed.repeat_key) |k| if (t >= ed.repeat_next) {
        ed.repeat_next = t + @divTrunc(1000, @max(1, ed.repeat_rate));
        ed.onKeyEvdev(k);
    };
    if (ed.toast_len > 0 and t >= ed.toast_until) {
        ed.toast_len = 0;
        ed.dirty = true;
    }
    if (ed.dialog) |d| switch (d.state) {
        .waiting => {},
        .chosen => {
            const p = d.path.?;
            d.path = null;
            d.deinit();
            ed.dialog = null;
            ed.saveTo(p) catch |err| ed.toastf("Save failed: {t}", .{err});
            ed.gpa.free(p);
        },
        .cancelled => {
            std.log.debug("save dialog cancelled", .{});
            d.deinit();
            ed.dialog = null;
        },
        .failed => {
            d.deinit();
            ed.dialog = null;
            ed.toastf("The file dialog is unavailable (xdg-desktop-portal)", .{});
        },
    };
    if (ed.script != null and ed.configured and ed.presented > 0 and ed.frame_cb == null and !ed.dirty) ed.stepScript();
}

// ---------------------------------------------------------------------------
// View geometry

fn viewRect(ed: *const Editor) Rect {
    return if (ed.tool == .crop) ed.doc.bounds() else ed.doc.view();
}

/// Buffer px per image px.
fn kScale(ed: *const Editor) f64 {
    return ed.zoom * ed.scale;
}

fn panPx(ed: *const Editor) [2]i32 {
    return .{ @intFromFloat(@round(ed.pan[0] * ed.scale)), @intFromFloat(@round(ed.pan[1] * ed.scale)) };
}

fn canvasSize(ed: *const Editor) [2]f64 {
    return .{ @floatFromInt(ed.win_w), @as(f64, @floatFromInt(ed.win_h)) - toolbar.height };
}

/// Image px → buffer px.
fn toBuf(ed: *const Editor, p: Pt) [2]f64 {
    const vr = ed.viewRect();
    const pp = ed.panPx();
    const k = ed.kScale();
    return .{
        @as(f64, @floatFromInt(pp[0])) + (@as(f64, p[0]) - @as(f64, @floatFromInt(vr.x))) * k,
        @as(f64, @floatFromInt(ed.tb_px)) + @as(f64, @floatFromInt(pp[1])) + (@as(f64, p[1]) - @as(f64, @floatFromInt(vr.y))) * k,
    };
}

/// Logical window px → image px.
fn toImg(ed: *const Editor, l: [2]f64) Pt {
    const vr = ed.viewRect();
    const pp = ed.panPx();
    const k = ed.kScale();
    return .{
        @floatCast((l[0] * ed.scale - @as(f64, @floatFromInt(pp[0]))) / k + @as(f64, @floatFromInt(vr.x))),
        @floatCast((l[1] * ed.scale - @as(f64, @floatFromInt(ed.tb_px)) - @as(f64, @floatFromInt(pp[1]))) / k + @as(f64, @floatFromInt(vr.y))),
    };
}

/// Image px → logical window px.
fn toLogical(ed: *const Editor, p: Pt) [2]f64 {
    const b = ed.toBuf(p);
    return .{ b[0] / ed.scale, b[1] / ed.scale };
}

fn applyView(ed: *const Editor, cr: *c.cairo_t, with_toolbar: bool) void {
    const vr = ed.viewRect();
    const pp = ed.panPx();
    const k = ed.kScale();
    const ty: f64 = if (with_toolbar) @floatFromInt(ed.tb_px) else 0;
    c.cairo_translate(cr, @floatFromInt(pp[0]), ty + @as(f64, @floatFromInt(pp[1])));
    c.cairo_scale(cr, k, k);
    c.cairo_translate(cr, @floatFromInt(-vr.x), @floatFromInt(-vr.y));
}

fn fitZoom(ed: *const Editor) f64 {
    const vr = ed.viewRect();
    const cs = ed.canvasSize();
    const zx = (cs[0] - 2 * margin) / @as(f64, @floatFromInt(@max(1, vr.w)));
    const zy = (cs[1] - 2 * margin) / @as(f64, @floatFromInt(@max(1, vr.h)));
    return @max(0.01, @min(@min(zx, zy), 1 / ed.scale));
}

fn doFit(ed: *Editor) void {
    ed.zoom = ed.fitZoom();
    ed.fit = true;
    ed.clampPan();
}

fn setZoomAt(ed: *Editor, z: f64, anchor: [2]f64) void {
    const minz = @min(ed.fitZoom(), 0.1 / ed.scale) * 0.5;
    const nz = std.math.clamp(z, minz, 32 / ed.scale);
    const ip = ed.toImg(anchor);
    const vr = ed.viewRect();
    ed.zoom = nz;
    ed.fit = false;
    ed.pan = .{
        anchor[0] - (@as(f64, ip[0]) - @as(f64, @floatFromInt(vr.x))) * nz,
        anchor[1] - toolbar.height - (@as(f64, ip[1]) - @as(f64, @floatFromInt(vr.y))) * nz,
    };
    ed.clampPan();
    ed.dirty = true;
}

fn canvasCenter(ed: *const Editor) [2]f64 {
    const cs = ed.canvasSize();
    return .{ cs[0] / 2, toolbar.height + cs[1] / 2 };
}

fn clampPan(ed: *Editor) void {
    const vr = ed.viewRect();
    const cs = ed.canvasSize();
    inline for (0..2) |i| {
        const extent = @as(f64, @floatFromInt(if (i == 0) vr.w else vr.h)) * ed.zoom;
        if (extent + 2 * margin <= cs[i]) {
            ed.pan[i] = (cs[i] - extent) / 2;
        } else {
            ed.pan[i] = std.math.clamp(ed.pan[i], cs[i] - extent - margin, margin);
        }
    }
    ed.dirty = true;
}

/// Keep the picture still when the visible part of the image changes (crop mode,
/// undoing a crop), or refit when fitting.
fn syncView(ed: *Editor) void {
    const vr = ed.viewRect();
    if (ed.last_vr) |old| {
        if (old.eql(vr)) return;
        ed.pan[0] += @as(f64, @floatFromInt(vr.x - old.x)) * ed.zoom;
        ed.pan[1] += @as(f64, @floatFromInt(vr.y - old.y)) * ed.zoom;
    }
    ed.last_vr = vr;
    if (ed.fit) ed.doFit() else ed.clampPan();
}

// ---------------------------------------------------------------------------
// Rendering

fn ensureBuffers(ed: *Editor) void {
    const bw: u32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(ed.win_w)) * ed.scale)));
    const bh: u32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(ed.win_h)) * ed.scale)));
    if (bw == ed.buf_w and bh == ed.buf_h) return;
    for (&ed.bufs) |*b| if (b.*) |buf| {
        buf.destroy(ed.gpa);
        b.* = null;
    };
    ed.last_buf = null;
    ed.buf_w = bw;
    ed.buf_h = bh;
    ed.tb_px = @intFromFloat(@round(toolbar.height * ed.scale));
    ed.full_damage = true;
    ed.scene_key = null;
    ed.viewport.?.setDestination(ed.win_w, ed.win_h);
    // New window size: refit, or keep the image placed sensibly.
    if (ed.last_vr != null) {
        if (ed.fit) ed.doFit() else ed.clampPan();
    }
}

fn freeBuffer(ed: *Editor) ?*shm.Buffer {
    for (ed.bufs) |b| if (b) |buf| if (!buf.busy) return buf;
    for (&ed.bufs) |*b| if (b.* == null) {
        b.* = shm.Buffer.create(ed.gpa, ed.client.shm.?, ed.buf_w, ed.buf_h, ed.buf_w * 4, .xrgb8888) catch return null;
        return b.*;
    };
    return null;
}

fn sceneKey(ed: *const Editor) SceneKey {
    return .{
        .rev = ed.doc.rev,
        .k = ed.kScale(),
        .pan = ed.panPx(),
        .w = ed.buf_w,
        .h = ed.buf_h,
        .vr = ed.viewRect(),
        .skip = if (ed.text) |t| t.replacing else null,
    };
}

fn imageFilter(k: f64) c.cairo_filter_t {
    if (@abs(k - 1) < 1e-6 or k >= 2) return c.CAIRO_FILTER_NEAREST;
    if (k > 1) return c.CAIRO_FILTER_BILINEAR;
    return c.CAIRO_FILTER_GOOD;
}

fn rebuildScene(ed: *Editor) void {
    const key = ed.sceneKey();
    if (ed.scene_key) |k| if (k.eql(key)) return;
    const cw: i32 = @intCast(ed.buf_w);
    const ch: i32 = @intCast(ed.buf_h - @min(ed.buf_h, ed.tb_px));
    if (ed.scene) |s| {
        if (c.cairo_image_surface_get_width(s) != cw or c.cairo_image_surface_get_height(s) != ch) {
            c.cairo_surface_destroy(s);
            ed.scene = null;
        }
    }
    if (ed.scene == null) ed.scene = c.cairo_image_surface_create(c.CAIRO_FORMAT_RGB24, cw, @max(1, ch));
    const cr = c.cairo_create(ed.scene.?) orelse return;
    defer c.cairo_destroy(cr);

    c.cairo_set_source_rgb(cr, theme.canvas[0], theme.canvas[1], theme.canvas[2]);
    c.cairo_paint(cr);

    const vr = ed.viewRect();
    const pp = ed.panPx();
    const k = ed.kScale();
    const ax: f64 = @floatFromInt(pp[0]);
    const ay: f64 = @floatFromInt(pp[1]);
    const aw = @round(@as(f64, @floatFromInt(vr.w)) * k);
    const ah = @round(@as(f64, @floatFromInt(vr.h)) * k);

    // Outline so the image edge reads against the dark canvas.
    c.cairo_rectangle(cr, ax - 1, ay - 1, aw + 2, ah + 2);
    c.cairo_set_source_rgb(cr, 0.21, 0.22, 0.25);
    c.cairo_fill(cr);
    c.cairo_rectangle(cr, ax, ay, aw, ah);
    c.cairo_clip(cr);
    if (!ed.img.is_opaque) checkerboard(cr, ax, ay, aw, ah, 8 * ed.scale);

    c.cairo_save(cr);
    ed.applyView(cr, false);
    ed.rend.drawDoc(cr, &ed.doc, imageFilter(k), key.skip);
    c.cairo_restore(cr);
    c.cairo_surface_flush(ed.scene.?);
    ed.scene_key = key;
    ed.full_damage = true;
}

fn checkerboard(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, cell: f64) void {
    c.cairo_set_source_rgb(cr, 0.32, 0.32, 0.34);
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.42, 0.42, 0.44);
    var j: f64 = 0;
    while (j * cell < h) : (j += 1) {
        var i: f64 = @mod(j, 2);
        while (i * cell < w) : (i += 2) c.cairo_rectangle(cr, x + i * cell, y + j * cell, cell, cell);
    }
    c.cairo_fill(cr);
}

fn render(ed: *Editor) void {
    if (!ed.configured or ed.frame_cb != null) return;
    ed.ensureBuffers();
    ed.syncView();
    ed.tb = toolbar.layout(@floatFromInt(ed.win_w));
    const buf = ed.freeBuffer() orelse return;
    ed.rebuildScene();

    // Canvas: copy the scene.
    const scene = ed.scene.?;
    const sdata = c.cairo_image_surface_get_data(scene);
    const sstride: usize = @intCast(c.cairo_image_surface_get_stride(scene));
    const rows: usize = @intCast(c.cairo_image_surface_get_height(scene));
    const row_bytes: usize = @as(usize, ed.buf_w) * 4;
    const off: usize = @as(usize, ed.tb_px) * buf.stride;
    for (0..@min(rows, ed.buf_h - @min(ed.buf_h, ed.tb_px))) |y| {
        @memcpy(buf.data[off + y * buf.stride ..][0..row_bytes], sdata[y * sstride ..][0..row_bytes]);
    }

    const surf = c.cairo_image_surface_create_for_data(buf.data.ptr, c.CAIRO_FORMAT_RGB24, @intCast(ed.buf_w), @intCast(ed.buf_h), @intCast(buf.stride));
    defer c.cairo_surface_destroy(surf);
    const cr = c.cairo_create(surf) orelse return;
    defer c.cairo_destroy(cr);

    // Toolbar.
    const st = ed.toolbarState();
    c.cairo_save(cr);
    c.cairo_rectangle(cr, 0, 0, @floatFromInt(ed.buf_w), @floatFromInt(ed.tb_px));
    c.cairo_clip(cr);
    c.cairo_set_source_rgb(cr, theme.bar[0], theme.bar[1], theme.bar[2]);
    c.cairo_paint(cr);
    c.cairo_scale(cr, ed.scale, ed.scale);
    toolbar.draw(cr, &ed.tb, st, @floatFromInt(ed.win_w));
    c.cairo_restore(cr);
    const th = st.hash();
    const tb_changed = th != ed.tb_hash;
    ed.tb_hash = th;

    // Live layer.
    var dyn: ?Rect = null;
    ed.drawLive(cr, &dyn);
    c.cairo_surface_flush(surf);

    const surface = ed.surface.?;
    const full: Rect = .{ .x = 0, .y = 0, .w = @intCast(ed.buf_w), .h = @intCast(ed.buf_h) };
    if (ed.full_damage) {
        surface.damageBuffer(0, 0, full.w, full.h);
    } else {
        if (tb_changed) surface.damageBuffer(0, 0, full.w, @intCast(ed.tb_px));
        const d = unionOpt(ed.dyn_prev, dyn);
        if (d) |r| {
            const cl = r.clampTo(full);
            if (!cl.isEmpty()) surface.damageBuffer(cl.x, cl.y, cl.w, cl.h);
        }
    }
    ed.dyn_prev = dyn;
    ed.full_damage = false;

    surface.attach(buf.wl_buffer, 0, 0);
    buf.busy = true;
    ed.last_buf = buf;
    if (surface.frame()) |cb| {
        ed.frame_cb = cb;
        cb.setListener(*Editor, frameListener, ed);
    } else |_| {}
    surface.commit();
    ed.dirty = false;
}

fn unionOpt(a: ?Rect, b: ?Rect) ?Rect {
    if (a == null) return b;
    if (b == null) return a;
    return a.?.bbox(b.?);
}

fn grow(dyn: *?Rect, r: Rect) void {
    dyn.* = unionOpt(dyn.*, r);
}

fn rectF(x: f64, y: f64, w: f64, h: f64, pad: f64) Rect {
    const x0: i32 = @intFromFloat(@floor(@min(x, x + w) - pad));
    const y0: i32 = @intFromFloat(@floor(@min(y, y + h) - pad));
    const x1: i32 = @intFromFloat(@ceil(@max(x, x + w) + pad));
    const y1: i32 = @intFromFloat(@ceil(@max(y, y + h) + pad));
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Image-px box → buffer-px rect.
fn imgBoxToBuf(ed: *const Editor, b: [4]f32, pad: f64) Rect {
    const p0 = ed.toBuf(.{ b[0], b[1] });
    const k = ed.kScale();
    return rectF(p0[0], p0[1], @as(f64, b[2]) * k, @as(f64, b[3]) * k, pad);
}

fn toolbarState(ed: *const Editor) toolbar.State {
    return .{
        .tool = ed.tool,
        .color = ed.curColor(),
        .size = ed.curSize(),
        .can_undo = ed.doc.canUndo(),
        .can_redo = ed.doc.canRedo(),
        .zoom_pct = ed.kScale() * 100,
        .hover = ed.hover,
        .pressed = ed.pressed,
        .popover = ed.popover,
        .palette = ed.opts.palette,
        .busy_ocr = ed.ocr_job != null,
    };
}

fn drawLive(ed: *Editor, cr: *c.cairo_t, dyn: *?Rect) void {
    const canvas_clip: Rect = .{ .x = 0, .y = @intCast(ed.tb_px), .w = @intCast(ed.buf_w), .h = @intCast(ed.buf_h -| ed.tb_px) };
    c.cairo_save(cr);
    c.cairo_rectangle(cr, 0, @floatFromInt(ed.tb_px), @floatFromInt(ed.buf_w), @floatFromInt(ed.buf_h -| ed.tb_px));
    c.cairo_clip(cr);

    // Object being drawn.
    switch (ed.gesture) {
        .stroke => |s| if (s.pts.items.len > 0) {
            const o = Obj{ .kind = s.kind, .color = ed.curColor(), .size = ed.curSize(), .points = s.pts.items };
            ed.drawLiveObj(cr, o, dyn);
        },
        .shape => |s| {
            const pts = [2]Pt{ s.a, s.b };
            const o = Obj{ .kind = s.kind, .color = ed.curColor(), .size = ed.curSize(), .points = @constCast(&pts) };
            ed.drawLiveObj(cr, o, dyn);
            if (s.kind == .blur or s.kind == .pixelate) ed.dashedBox(cr, o.box(), dyn);
        },
        else => {},
    }

    // Text being edited.
    if (ed.text) |t| {
        const pts = [1]Pt{t.at};
        const o = Obj{ .kind = .text, .color = t.color, .size = t.size, .points = @constCast(&pts), .text = t.buf.items };
        ed.drawLiveObj(cr, o, dyn);
        var box = ed.rend.measureText(t.buf.items, t.size, t.at);
        box[0] -= 4;
        box[1] -= 2;
        box[2] += 8;
        box[3] += 4;
        ed.dashedBox(cr, box, dyn);
        const car = ed.rend.caret(t.buf.items, t.size, t.at);
        const p0 = ed.toBuf(.{ car[0], car[1] });
        const h = @as(f64, car[2]) * ed.kScale();
        c.cairo_rectangle(cr, @round(p0[0]), p0[1], @max(1, @round(ed.scale)), h);
        c.cairo_set_source_rgb(cr, t.color.r, t.color.g, t.color.b);
        c.cairo_fill(cr);
    }

    // Crop frame.
    if (ed.tool == .crop) ed.drawCrop(cr, dyn);

    // Eraser target.
    if (ed.tool == .eraser and ed.gesture == .none and ed.pointerOnCanvas()) {
        const p = ed.toImg(ed.ptr);
        if (ed.doc.hitTest(p, ed.curSize() / 2)) |id| {
            const r = ed.imgBoxToBuf(ed.doc.objs.items[id].bounds(), 2);
            c.cairo_rectangle(cr, @as(f64, @floatFromInt(r.x)) + 0.5, @as(f64, @floatFromInt(r.y)) + 0.5, @floatFromInt(r.w - 1), @floatFromInt(r.h - 1));
            const dash = [_]f64{ 4 * ed.scale, 3 * ed.scale };
            c.cairo_set_dash(cr, &dash, 2, 0);
            c.cairo_set_line_width(cr, @max(1, @round(ed.scale)));
            c.cairo_set_source_rgba(cr, 1, 0.3, 0.3, 0.95);
            c.cairo_stroke(cr);
            c.cairo_set_dash(cr, null, 0, 0);
            grow(dyn, r.inflate(2));
        }
    }

    // Brush ring.
    if ((ed.tool == .pen or ed.tool == .highlighter or ed.tool == .eraser) and ed.pointerOnCanvas() and !ed.panning() and !ed.popoverHit(ed.ptr)) {
        const cx = ed.ptr[0] * ed.scale;
        const cy = ed.ptr[1] * ed.scale;
        const r = @max(2.0, @as(f64, ed.curSize()) / 2 * ed.kScale());
        c.cairo_arc(cr, cx, cy, r, 0, 2 * std.math.pi);
        c.cairo_set_line_width(cr, 3 * ed.scale);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0.45);
        c.cairo_stroke_preserve(cr);
        c.cairo_set_line_width(cr, 1.2 * ed.scale);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
        c.cairo_stroke(cr);
        grow(dyn, rectF(cx - r, cy - r, 2 * r, 2 * r, 3 * ed.scale));
    }

    // Colour under the eyedropper.
    if (ed.tool == .picker and ed.pointerOnCanvas()) {
        if (ed.sample(ed.toImg(ed.ptr))) |col| {
            const s = ed.scale;
            const x = ed.ptr[0] * s + 14 * s;
            const y = ed.ptr[1] * s + 14 * s;
            icons.roundRect(cr, x, y, 30 * s, 30 * s, 5 * s);
            c.cairo_set_source_rgb(cr, col.r, col.g, col.b);
            c.cairo_fill_preserve(cr);
            c.cairo_set_line_width(cr, 1.5 * s);
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
            c.cairo_stroke(cr);
            grow(dyn, rectF(x, y, 30 * s, 30 * s, 2 * s));
        }
    }
    c.cairo_restore(cr);
    _ = canvas_clip;

    // Above the canvas: popover, tooltip, toast (logical coordinates).
    c.cairo_save(cr);
    c.cairo_scale(cr, ed.scale, ed.scale);
    if (ed.popover) ed.drawPopover(cr, dyn);
    if (ed.hover) |h| if (ed.gesture == .none and !ed.popover) ed.drawTooltip(cr, h, dyn);
    if (ed.toast_len > 0) ed.drawToast(cr, dyn);
    c.cairo_restore(cr);
}

fn drawLiveObj(ed: *Editor, cr: *c.cairo_t, o: Obj, dyn: *?Rect) void {
    c.cairo_save(cr);
    ed.applyView(cr, true);
    ed.rend.drawObj(cr, o, null, imageFilter(ed.kScale()));
    c.cairo_restore(cr);
    const b = if (o.kind == .text) ed.rend.measureText(o.text, o.size, o.points[0]) else o.bounds();
    grow(dyn, ed.imgBoxToBuf(b, 4));
}

fn dashedBox(ed: *Editor, cr: *c.cairo_t, box: [4]f32, dyn: *?Rect) void {
    const r = ed.imgBoxToBuf(box, 0);
    const x: f64 = @as(f64, @floatFromInt(r.x)) + 0.5;
    const y: f64 = @as(f64, @floatFromInt(r.y)) + 0.5;
    c.cairo_rectangle(cr, x, y, @floatFromInt(@max(1, r.w - 1)), @floatFromInt(@max(1, r.h - 1)));
    c.cairo_set_line_width(cr, @max(1, @round(ed.scale)));
    const dash = [_]f64{ 5 * ed.scale, 4 * ed.scale };
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.6);
    c.cairo_stroke_preserve(cr);
    c.cairo_set_dash(cr, &dash, 2, 0);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
    c.cairo_stroke(cr);
    c.cairo_set_dash(cr, null, 0, 0);
    grow(dyn, r.inflate(2));
}

fn drawCrop(ed: *Editor, cr: *c.cairo_t, dyn: *?Rect) void {
    const cp = ed.crop_pending;
    const box = [4]f32{ @floatFromInt(cp.x), @floatFromInt(cp.y), @floatFromInt(cp.w), @floatFromInt(cp.h) };
    const r = ed.imgBoxToBuf(box, 0);
    const vr = ed.viewRect();
    const all = ed.imgBoxToBuf(.{ @floatFromInt(vr.x), @floatFromInt(vr.y), @floatFromInt(vr.w), @floatFromInt(vr.h) }, 0);
    // Dim the image outside the crop.
    c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_EVEN_ODD);
    rectPath(cr, all);
    rectPath(cr, r);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.55);
    c.cairo_fill(cr);
    c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_WINDING);
    // Frame, thirds and handles.
    const lw = @max(1, @round(ed.scale));
    c.cairo_set_line_width(cr, lw);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
    c.cairo_rectangle(cr, @as(f64, @floatFromInt(r.x)) + lw / 2, @as(f64, @floatFromInt(r.y)) + lw / 2, @as(f64, @floatFromInt(r.w)) - lw, @as(f64, @floatFromInt(r.h)) - lw);
    c.cairo_stroke(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.25);
    for (1..3) |i| {
        const f: f64 = @floatFromInt(i);
        const x = @round(@as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) * f / 3) + 0.5;
        const y = @round(@as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) * f / 3) + 0.5;
        c.cairo_move_to(cr, x, @floatFromInt(r.y));
        c.cairo_line_to(cr, x, @floatFromInt(r.y2()));
        c.cairo_move_to(cr, @floatFromInt(r.x), y);
        c.cairo_line_to(cr, @floatFromInt(r.x2()), y);
    }
    c.cairo_stroke(cr);
    const hs = 8 * ed.scale;
    for (handlePoints(r)) |hp| {
        c.cairo_rectangle(cr, hp[0] - hs / 2, hp[1] - hs / 2, hs, hs);
    }
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.5);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    // Size label under the frame.
    var buf: [48]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d} \u{00d7} {d}", .{ cp.w, cp.h }) catch "";
    c.cairo_save(cr);
    c.cairo_scale(cr, ed.scale, ed.scale);
    const lx = @as(f64, @floatFromInt(r.x)) / ed.scale;
    var ly = @as(f64, @floatFromInt(r.y2())) / ed.scale + 8;
    if (ly + 26 > @as(f64, @floatFromInt(ed.win_h))) ly = @as(f64, @floatFromInt(r.y)) / ed.scale + 8;
    pill(cr, txt, lx, ly, 12);
    c.cairo_restore(cr);
    grow(dyn, all.inflate(2));
    grow(dyn, rectF(lx * ed.scale, ly * ed.scale, 160 * ed.scale, 28 * ed.scale, 2));
}

fn handlePoints(r: Rect) [8][2]f64 {
    const x0: f64 = @floatFromInt(r.x);
    const y0: f64 = @floatFromInt(r.y);
    const x1: f64 = @floatFromInt(r.x2());
    const y1: f64 = @floatFromInt(r.y2());
    const mx = (x0 + x1) / 2;
    const my = (y0 + y1) / 2;
    return .{ .{ x0, y0 }, .{ mx, y0 }, .{ x1, y0 }, .{ x1, my }, .{ x1, y1 }, .{ mx, y1 }, .{ x0, y1 }, .{ x0, my } };
}

fn rectPath(cr: *c.cairo_t, r: Rect) void {
    c.cairo_rectangle(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
}

/// Dark rounded label at (x, y), logical px. Returns its size.
fn pill(cr: *c.cairo_t, text: []const u8, x: f64, y: f64, size: f64) void {
    const m = toolbar.measure(cr, text, size);
    const pad = 7.0;
    icons.roundRect(cr, x, y, m[0] + 2 * pad, m[1] + pad, 5);
    c.cairo_set_source_rgba(cr, 0.05, 0.055, 0.065, 0.92);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, theme.fg[0], theme.fg[1], theme.fg[2]);
    toolbar.label(cr, text, x + pad, y, m[0], m[1] + pad, size, false);
}

fn drawTooltip(ed: *Editor, cr: *c.cairo_t, item: Item, dyn: *?Rect) void {
    const slot = ed.tb.find(item) orelse return;
    var buf: [64]u8 = undefined;
    const text = toolbar.tooltip(item, &buf);
    const m = toolbar.measure(cr, text, 12);
    const w = m[0] + 14;
    const x = std.math.clamp(slot.x, 4, @max(4, @as(f64, @floatFromInt(ed.win_w)) - w - 4));
    const y = toolbar.height + 4;
    pill(cr, text, x, y, 12);
    grow(dyn, rectF(x * ed.scale, y * ed.scale, w * ed.scale, (m[1] + 7) * ed.scale, 2));
}

fn drawToast(ed: *Editor, cr: *c.cairo_t, dyn: *?Rect) void {
    const text = ed.toast_buf[0..ed.toast_len];
    const m = toolbar.measure(cr, text, 13);
    const w = m[0] + 14;
    const h = m[1] + 7;
    const x = (@as(f64, @floatFromInt(ed.win_w)) - w) / 2;
    const y = @as(f64, @floatFromInt(ed.win_h)) - h - 18;
    pill(cr, text, x, y, 13);
    grow(dyn, rectF(x * ed.scale, y * ed.scale, w * ed.scale, h * ed.scale, 2));
}

// Custom colour popover: saturation/value square and a hue bar (logical px).
const pop_w: f64 = 198;
const pop_h: f64 = 172;
const sv_size: f64 = 150;

fn popoverOrigin(ed: *const Editor) [2]f64 {
    const slot = ed.tb.find(.custom) orelse return .{ 8, toolbar.height + 4 };
    const x = std.math.clamp(slot.x + slot.w / 2 - pop_w / 2, 4, @max(4, @as(f64, @floatFromInt(ed.win_w)) - pop_w - 4));
    return .{ x, toolbar.height + 4 };
}

fn popoverHit(ed: *const Editor, l: [2]f64) bool {
    if (!ed.popover) return false;
    const o = ed.popoverOrigin();
    return l[0] >= o[0] and l[0] < o[0] + pop_w and l[1] >= o[1] and l[1] < o[1] + pop_h;
}

fn drawPopover(ed: *Editor, cr: *c.cairo_t, dyn: *?Rect) void {
    const o = ed.popoverOrigin();
    icons.roundRect(cr, o[0], o[1], pop_w, pop_h, 8);
    c.cairo_set_source_rgba(cr, 0.09, 0.094, 0.11, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_line_width(cr, 1);
    c.cairo_set_source_rgb(cr, theme.sep[0], theme.sep[1], theme.sep[2]);
    c.cairo_stroke(cr);

    const sx = o[0] + 11;
    const sy = o[1] + 11;
    // SV square, rendered per hue at the buffer scale.
    if (ed.sv_key[0] != ed.hsv[0] or ed.sv_key[1] != ed.scale) {
        if (ed.sv_surf) |s| c.cairo_surface_destroy(s);
        const n: usize = @intFromFloat(@round(sv_size * ed.scale));
        const s = c.cairo_image_surface_create(c.CAIRO_FORMAT_RGB24, @intCast(n), @intCast(n));
        const data = c.cairo_image_surface_get_data(s);
        const stride: usize = @intCast(c.cairo_image_surface_get_stride(s));
        for (0..n) |y| for (0..n) |x| {
            const sat: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(n - 1));
            const val: f32 = 1 - @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(n - 1));
            const rgb = icons.hsv(ed.hsv[0], sat, val);
            const p = data[y * stride + x * 4 ..][0..4];
            p.* = .{ @intFromFloat(rgb[2] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[0] * 255), 255 };
        };
        c.cairo_surface_mark_dirty(s);
        ed.sv_surf = s;
        ed.sv_key = .{ ed.hsv[0], ed.scale };
    }
    c.cairo_save(cr);
    c.cairo_translate(cr, sx, sy);
    c.cairo_scale(cr, 1 / ed.scale, 1 / ed.scale);
    c.cairo_set_source_surface(cr, ed.sv_surf.?, 0, 0);
    c.cairo_paint(cr);
    c.cairo_restore(cr);
    const mx = sx + @as(f64, ed.hsv[1]) * sv_size;
    const my = sy + (1 - @as(f64, ed.hsv[2])) * sv_size;
    c.cairo_arc(cr, mx, my, 5, 0, 2 * std.math.pi);
    c.cairo_set_line_width(cr, 2);
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_stroke_preserve(cr);
    c.cairo_set_line_width(cr, 1);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.6);
    c.cairo_stroke(cr);

    // Hue bar.
    const hx = sx + sv_size + 10;
    const hw = 16.0;
    const grad = c.cairo_pattern_create_linear(0, sy, 0, sy + sv_size);
    defer c.cairo_pattern_destroy(grad);
    for (0..7) |i| {
        const f: f32 = @as(f32, @floatFromInt(i)) / 6;
        const rgb = icons.hsv(f, 1, 1);
        c.cairo_pattern_add_color_stop_rgb(grad, f, rgb[0], rgb[1], rgb[2]);
    }
    icons.roundRect(cr, hx, sy, hw, sv_size, 3);
    c.cairo_set_source(cr, grad);
    c.cairo_fill(cr);
    const hy = sy + @as(f64, ed.hsv[0]) * sv_size;
    icons.roundRect(cr, hx - 2, hy - 3, hw + 4, 6, 2);
    c.cairo_set_line_width(cr, 2);
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_stroke(cr);
    grow(dyn, rectF(o[0] * ed.scale, o[1] * ed.scale, pop_w * ed.scale, pop_h * ed.scale, 2));
}

fn popoverPick(ed: *Editor, l: [2]f64, which: enum { sv, hue }) void {
    const o = ed.popoverOrigin();
    const sx = o[0] + 11;
    const sy = o[1] + 11;
    switch (which) {
        .sv => {
            ed.hsv[1] = @floatCast(std.math.clamp((l[0] - sx) / sv_size, 0, 1));
            ed.hsv[2] = @floatCast(std.math.clamp(1 - (l[1] - sy) / sv_size, 0, 1));
        },
        .hue => ed.hsv[0] = @floatCast(std.math.clamp((l[1] - sy) / sv_size, 0, 0.999)),
    }
    const rgb = icons.hsv(ed.hsv[0], ed.hsv[1], ed.hsv[2]);
    ed.setColor(.{ .r = rgb[0], .g = rgb[1], .b = rgb[2] }, false);
}

fn popoverZone(ed: *const Editor, l: [2]f64) ?enum { sv, hue } {
    const o = ed.popoverOrigin();
    const sx = o[0] + 11;
    const sy = o[1] + 11;
    if (l[1] < sy - 4 or l[1] > sy + sv_size + 4) return null;
    if (l[0] >= sx - 4 and l[0] <= sx + sv_size + 4) return .sv;
    const hx = sx + sv_size + 10;
    if (l[0] >= hx - 4 and l[0] <= hx + 20) return .hue;
    return null;
}

// ---------------------------------------------------------------------------
// Tool state

fn curColor(ed: *const Editor) Color {
    if (ed.text) |t| return t.color;
    return if (ed.tool == .highlighter) ed.highlight else ed.ink;
}

fn curSize(ed: *const Editor) f32 {
    if (ed.text) |t| return t.size;
    return ed.sizes[@backingInt(ed.tool)];
}

/// Apply a colour to the current tool (and the text being edited). `from_palette`
/// also syncs the popover's HSV.
fn setColor(ed: *Editor, col: Color, from_palette: bool) void {
    if (ed.text) |*t| t.color = col;
    const target = if (ed.tool == .picker) ed.prev_tool else ed.tool;
    if (target == .highlighter) ed.highlight = col else ed.ink = col;
    if (from_palette) ed.hsv = icons.toHsv(col.r, col.g, col.b);
    ed.dirty = true;
}

fn stepSize(ed: *Editor, dir: i32) void {
    if (ed.tool == .crop or ed.tool == .picker) return;
    const cur = ed.curSize();
    var next = cur;
    if (dir > 0) {
        for (size_steps) |s| if (s > cur + 0.01) {
            next = s;
            break;
        };
    } else {
        var i = size_steps.len;
        while (i > 0) {
            i -= 1;
            if (size_steps[i] < cur - 0.01) {
                next = size_steps[i];
                break;
            }
        }
    }
    if (ed.text) |*t| t.size = next;
    ed.sizes[@backingInt(ed.tool)] = next;
    ed.dirty = true;
}

fn setTool(ed: *Editor, t: Tool) void {
    if (t == ed.tool) return;
    ed.cancelGesture();
    ed.commitText();
    if (ed.tool == .crop) ed.applyCrop();
    if (t == .crop or t == .picker) ed.prev_tool = if (ed.tool == .crop or ed.tool == .picker) ed.prev_tool else ed.tool;
    if (t == .crop) ed.crop_pending = ed.doc.view();
    ed.tool = t;
    ed.popover = false;
    ed.updateCursor();
    ed.dirty = true;
    ed.full_damage = true;
}

fn applyCrop(ed: *Editor) void {
    ed.doc.setCrop(ed.crop_pending) catch {};
}

fn cancelCrop(ed: *Editor) void {
    ed.cancelGesture();
    ed.tool = ed.prev_tool;
    ed.dirty = true;
    ed.updateCursor();
}

fn cancelGesture(ed: *Editor) void {
    switch (ed.gesture) {
        .stroke => |*s| s.pts.deinit(ed.gpa),
        .erase => |*e| {
            // Undo the live hiding.
            for (e.ids.items) |id| ed.doc.objs.items[id].visible = true;
            if (e.ids.items.len > 0) ed.doc.rev += 1;
            e.ids.deinit(ed.gpa);
        },
        else => {},
    }
    ed.gesture = .none;
    ed.dirty = true;
}

fn commitText(ed: *Editor) void {
    var t = ed.text orelse return;
    ed.text = null;
    defer t.buf.deinit(ed.gpa);
    ed.dirty = true;
    // Trailing newlines add nothing visible.
    var len = t.buf.items.len;
    while (len > 0 and (t.buf.items[len - 1] == '\n' or t.buf.items[len - 1] == ' ')) len -= 1;
    if (len == 0) {
        if (t.replacing) |old| {
            const ids = ed.gpa.dupe(u32, &.{old}) catch return;
            ed.doc.commitErase(ids) catch {};
        }
        return;
    }
    const text = ed.gpa.dupe(u8, t.buf.items[0..len]) catch return;
    const pts = ed.gpa.dupe(Pt, &.{t.at}) catch {
        ed.gpa.free(text);
        return;
    };
    var o: Obj = .{ .kind = .text, .color = t.color, .size = t.size, .points = pts, .text = text };
    o.text_box = ed.rend.measureText(text, t.size, t.at);
    if (t.replacing) |old| {
        _ = ed.doc.replace(old, o) catch {};
    } else {
        _ = ed.doc.add(o) catch {};
    }
}

fn sample(ed: *const Editor, p: Pt) ?Color {
    const x: i32 = @intFromFloat(@floor(p[0]));
    const y: i32 = @intFromFloat(@floor(p[1]));
    if (x < 0 or y < 0 or x >= ed.img.width or y >= ed.img.height) return null;
    const px = ed.img.pixels[@as(usize, @intCast(y)) * ed.img.stride + @as(usize, @intCast(x)) * 4 ..][0..4];
    const a: f32 = @as(f32, @floatFromInt(px[3])) / 255;
    if (a == 0) return null;
    return .{
        .r = @as(f32, @floatFromInt(px[2])) / 255 / a,
        .g = @as(f32, @floatFromInt(px[1])) / 255 / a,
        .b = @as(f32, @floatFromInt(px[0])) / 255 / a,
    };
}

fn toastf(ed: *Editor, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&ed.toast_buf, fmt, args) catch ed.toast_buf[0..];
    ed.toast_len = s.len;
    ed.toast_until = now() + toast_ms;
    ed.dirty = true;
}

// ---------------------------------------------------------------------------
// Commands

fn undo(ed: *Editor) void {
    ed.cancelGesture();
    ed.commitText();
    if (ed.tool == .crop) ed.cancelCrop();
    _ = ed.doc.undo();
    ed.dirty = true;
}

fn redo(ed: *Editor) void {
    ed.cancelGesture();
    ed.commitText();
    if (ed.tool == .crop) ed.cancelCrop();
    _ = ed.doc.redo();
    ed.dirty = true;
}

fn finishPending(ed: *Editor) void {
    ed.cancelGesture();
    ed.commitText();
    if (ed.tool == .crop) {
        ed.applyCrop();
        ed.tool = ed.prev_tool;
    }
}

fn copy(ed: *Editor) void {
    ed.finishPending();
    ed.ac.copyNow(ed.doc.rev, FlattenCtx{ .ed = ed }) catch |err| {
        ed.toastf("Copy failed: {t}", .{err});
        return;
    };
    ed.toastf("Copied to clipboard", .{});
}

/// Ctrl+Shift+C: recognise the text in the edited image and copy it.
fn copyText(ed: *Editor) void {
    ed.finishPending();
    if (ed.ocr_job != null) return;
    const img = ed.rend.flatten(ocrjob.alloc, &ed.doc) catch |err| {
        ed.toastf("Copy text failed: {t}", .{err});
        return;
    };
    ed.ocr_job = OcrJob.start(img, ed.opts.ocr_language, ed.scale) catch |err| {
        var m = img;
        m.deinit(ocrjob.alloc);
        ed.toastf("Copy text failed: {t}", .{err});
        return;
    };
    ed.toastf("Reading text\u{2026}", .{});
    ed.toast_until = std.math.maxInt(i64);
}

fn ocrDone(ed: *Editor, res: anyerror![]u8) void {
    const text = res catch |err| {
        ed.toastf("{s}", .{ocr.describe(err)});
        return;
    };
    defer ocrjob.alloc.free(text);
    if (text.len == 0) {
        ed.toastf("No text found", .{});
        return;
    }
    // Stop a pending image copy from replacing the text; the next edit re-copies.
    ed.ac.yieldTo(ed.doc.rev);
    clipboard.copyText(text, ed.opts.keep_stderr) catch |err| {
        ed.toastf("Copy text failed: {t}", .{err});
        return;
    };
    const lines = ocr.lineCount(text);
    ed.toastf("Copied {d} line{s} of text", .{ lines, if (lines == 1) "" else "s" });
}

fn saveCurrent(ed: *Editor) void {
    ed.finishPending();
    if (ed.path) |p| {
        const dup = ed.gpa.dupe(u8, p) catch return;
        defer ed.gpa.free(dup);
        ed.saveTo(dup) catch |err| ed.toastf("Save failed: {t}", .{err});
        return;
    }
    const dir = ed.opts.save_dir orelse {
        ed.toastf("Save failed: no save directory (is HOME set?)", .{});
        return;
    };
    var img = ed.rend.flatten(ed.gpa, &ed.doc) catch return;
    defer img.deinit(ed.gpa);
    const bytes = codec.encode(ed.gpa, img, ed.opts.format, ed.opts.jpeg_quality) catch return;
    defer ed.gpa.free(bytes);
    const path = save_mod.saveNew(ed.opts.io, ed.gpa, .{ .dir = dir, .template = ed.opts.filename }, bytes, ed.opts.format.ext()) catch |err| {
        ed.toastf("Save failed: {t}", .{err});
        return;
    };
    ed.path = path;
    ed.doc.saved_rev = ed.doc.rev;
    ed.toastf("Saved {s}", .{std.fs.path.basename(path)});
}

fn saveTo(ed: *Editor, path: []const u8) !void {
    const fmt = codec.Format.fromPath(path) orelse ed.opts.format;
    var img = try ed.rend.flatten(ed.gpa, &ed.doc);
    defer img.deinit(ed.gpa);
    const bytes = try codec.encode(ed.gpa, img, fmt, ed.opts.jpeg_quality);
    defer ed.gpa.free(bytes);
    const written = try save_mod.saveTo(ed.opts.io, ed.gpa, path, bytes);
    if (ed.path) |old| ed.gpa.free(old);
    ed.path = written;
    ed.doc.saved_rev = ed.doc.rev;
    ed.toastf("Saved {s}", .{std.fs.path.basename(path)});
}

fn saveAs(ed: *Editor) void {
    ed.finishPending();
    if (ed.dialog != null) return;
    var name_buf: [160]u8 = undefined;
    var folder_buf: [512]u8 = undefined;
    var name: []const u8 = undefined;
    var folder: []const u8 = undefined;
    var fmt: codec.Format = ed.opts.format;
    if (ed.path) |p| {
        name = std.fs.path.basename(p);
        folder = std.fs.path.dirname(p) orelse "/";
        fmt = codec.Format.fromPath(p) orelse ed.opts.format;
    } else {
        var stamp: [256]u8 = undefined;
        const s = save_mod.fileStem(&stamp, ed.opts.filename) catch "Screenshot";
        name = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ s, fmt.ext() }) catch "Screenshot.png";
        folder = std.fmt.bufPrint(&folder_buf, "{s}", .{ed.opts.save_dir orelse "/"}) catch "/";
    }
    ed.dialog = portal.SaveDialog.start(ed.gpa, name, folder, fmt) catch |err| blk: {
        ed.toastf("The file dialog is unavailable ({t})", .{err});
        break :blk null;
    };
}

fn requestClose(ed: *Editor) void {
    const t = now();
    if (ed.opts.confirm_close and ed.doc.dirty() and t > ed.close_armed_until) {
        ed.close_armed_until = t + close_confirm_ms;
        ed.toastf("Unsaved changes. Close again to discard, Ctrl+S to save", .{});
        return;
    }
    ed.finishPending();
    ed.quit = true;
}

fn activate(ed: *Editor, item: Item) void {
    switch (item) {
        .tool => |t| ed.setTool(t),
        .swatch => |i| ed.setColor(ed.opts.palette[i], true),
        .custom => {
            ed.popover = !ed.popover;
            if (ed.popover) {
                const col = ed.curColor();
                ed.hsv = icons.toHsv(col.r, col.g, col.b);
            }
        },
        .size_down => ed.stepSize(-1),
        .size_up => ed.stepSize(1),
        .size_value => {},
        .undo => ed.undo(),
        .redo => ed.redo(),
        .zoom => if (ed.fit and @abs(ed.zoom - 1 / ed.scale) > 1e-6) {
            ed.setZoomAt(1 / ed.scale, ed.canvasCenter());
        } else ed.doFit(),
        .copy => ed.copy(),
        .ocr => ed.copyText(),
        .save => ed.saveCurrent(),
        .save_as => ed.saveAs(),
    }
    ed.dirty = true;
}

// ---------------------------------------------------------------------------
// Pointer

fn pointerOnCanvas(ed: *const Editor) bool {
    return ed.ptr_in and ed.ptr[1] >= toolbar.height;
}

fn panning(ed: *const Editor) bool {
    return ed.gesture == .pan or ed.space_down;
}

fn cropHandleAt(ed: *const Editor, l: [2]f64) Handle {
    const box = [4]f32{ @floatFromInt(ed.crop_pending.x), @floatFromInt(ed.crop_pending.y), @floatFromInt(ed.crop_pending.w), @floatFromInt(ed.crop_pending.h) };
    const r = ed.imgBoxToBuf(box, 0);
    const b = [2]f64{ l[0] * ed.scale, l[1] * ed.scale };
    const tol = 9 * ed.scale;
    const hs = handlePoints(r);
    const order = [_]Handle{ .nw, .n, .ne, .e, .se, .s, .sw, .w };
    for (hs, order) |hp, h| {
        if (@abs(b[0] - hp[0]) <= tol and @abs(b[1] - hp[1]) <= tol) return h;
    }
    const x0: f64 = @floatFromInt(r.x);
    const y0: f64 = @floatFromInt(r.y);
    const x1: f64 = @floatFromInt(r.x2());
    const y1: f64 = @floatFromInt(r.y2());
    const in_y = b[1] > y0 and b[1] < y1;
    const in_x = b[0] > x0 and b[0] < x1;
    if (in_y and @abs(b[0] - x0) <= tol) return .w;
    if (in_y and @abs(b[0] - x1) <= tol) return .e;
    if (in_x and @abs(b[1] - y0) <= tol) return .n;
    if (in_x and @abs(b[1] - y1) <= tol) return .s;
    if (in_x and in_y) return .move;
    return .new;
}

fn wantedShape(ed: *const Editor) wp.CursorShapeDeviceV1.Shape {
    if (!ed.pointerOnCanvas() or ed.popoverHit(ed.ptr)) return .default;
    if (ed.gesture == .pan) return .grabbing;
    if (ed.space_down) return .grab;
    switch (ed.tool) {
        .text => return .text,
        .crop => {
            const h = switch (ed.gesture) {
                .crop => |g| g.handle,
                else => ed.cropHandleAt(ed.ptr),
            };
            return switch (h) {
                .nw, .se => .nwse_resize,
                .ne, .sw => .nesw_resize,
                .n, .s => .ns_resize,
                .e, .w => .ew_resize,
                .move => .move,
                .new => .crosshair,
            };
        },
        else => return .crosshair,
    }
}

fn updateCursor(ed: *Editor) void {
    const d = ed.cursor_dev orelse return;
    if (!ed.ptr_in) return;
    const s = ed.wantedShape();
    if (ed.cur_shape) |cur| if (cur == s) return;
    d.setShape(ed.enter_serial, s);
    ed.cur_shape = s;
}

fn onMotion(ed: *Editor, l: [2]f64) void {
    ed.ptr = l;
    ed.ptr_in = true;
    const p = ed.toImg(l);
    switch (ed.gesture) {
        .none => {},
        .stroke => |*s| {
            if (s.straight) {
                const a = s.pts.items[0];
                const b = doc_mod.snap45(a, p);
                if (s.pts.items.len == 1) s.pts.append(ed.gpa, b) catch {} else s.pts.items[1] = b;
            } else {
                const last = s.pts.items[s.pts.items.len - 1];
                // Skip sub-pixel jitter (measured on screen, so zooming in keeps detail).
                if (doc_mod.dist(last, p) * @as(f32, @floatCast(ed.zoom)) >= 1.0) s.pts.append(ed.gpa, p) catch {};
            }
        },
        .shape => |*s| s.b = ed.constrain(s.kind, s.a, p),
        .erase => |*e| {
            ed.eraseAlong(e.last, p, &e.ids);
            e.last = p;
        },
        .pan => |g| {
            ed.pan = .{ g.pan[0] + l[0] - g.ptr[0], g.pan[1] + l[1] - g.ptr[1] };
            ed.fit = false;
            ed.clampPan();
        },
        .crop => |g| ed.dragCrop(g.handle, g.start, g.orig, p),
        .sv => ed.popoverPick(l, .sv),
        .hue => ed.popoverPick(l, .hue),
    }
    const h = if (l[1] < toolbar.height) ed.tb.hit(l[0], l[1]) else null;
    if (!optItemEql(h, ed.hover)) ed.hover = h;
    ed.updateCursor();
    ed.dirty = true;
}

fn optItemEql(a: ?Item, b: ?Item) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

fn constrain(ed: *const Editor, kind: Kind, a: Pt, b: Pt) Pt {
    if (!ed.shiftHeld()) return b;
    return switch (kind) {
        .line, .arrow => doc_mod.snap45(a, b),
        .rect, .ellipse, .blur, .pixelate => doc_mod.squareFrom(a, b),
        else => b,
    };
}

fn eraseAlong(ed: *Editor, a: Pt, b: Pt, ids: *std.ArrayList(u32)) void {
    const r = ed.curSize() / 2;
    const d = doc_mod.dist(a, b);
    const steps: usize = @intFromFloat(@ceil(d / @max(1, r / 2)));
    for (0..steps + 1) |i| {
        const t: f32 = if (steps == 0) 0 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const p: Pt = .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
        while (ed.doc.hitTest(p, r)) |id| {
            ed.doc.hide(id);
            ids.append(ed.gpa, id) catch return;
        }
    }
}

fn dragCrop(ed: *Editor, h: Handle, start: Pt, orig: Rect, p: Pt) void {
    const dx: i32 = @intFromFloat(@round(p[0] - start[0]));
    const dy: i32 = @intFromFloat(@round(p[1] - start[1]));
    var x0 = orig.x;
    var y0 = orig.y;
    var x1 = orig.x2();
    var y1 = orig.y2();
    switch (h) {
        .move => {
            const b = ed.doc.bounds();
            const mx = std.math.clamp(dx, -orig.x, b.w - orig.x2());
            const my = std.math.clamp(dy, -orig.y, b.h - orig.y2());
            ed.crop_pending = .{ .x = orig.x + mx, .y = orig.y + my, .w = orig.w, .h = orig.h };
            ed.dirty = true;
            return;
        },
        .new => {
            const sx: i32 = @intFromFloat(@round(start[0]));
            const sy: i32 = @intFromFloat(@round(start[1]));
            const ex: i32 = @intFromFloat(@round(p[0]));
            const ey: i32 = @intFromFloat(@round(p[1]));
            x0 = sx;
            y0 = sy;
            x1 = ex;
            y1 = ey;
        },
        .nw => {
            x0 += dx;
            y0 += dy;
        },
        .n => y0 += dy,
        .ne => {
            x1 += dx;
            y0 += dy;
        },
        .e => x1 += dx,
        .se => {
            x1 += dx;
            y1 += dy;
        },
        .s => y1 += dy,
        .sw => {
            x0 += dx;
            y1 += dy;
        },
        .w => x0 += dx,
    }
    var r = Rect.fromCorners(x0, y0, x1, y1).clampTo(ed.doc.bounds());
    if (r.w < 1) r.w = 1;
    if (r.h < 1) r.h = 1;
    ed.crop_pending = r;
    ed.dirty = true;
}

fn onPress(ed: *Editor, button: u32) void {
    const l = ed.ptr;
    if (button == btn_middle or (button == btn_left and ed.space_down and l[1] >= toolbar.height)) {
        ed.cancelGesture();
        ed.gesture = .{ .pan = .{ .ptr = l, .pan = ed.pan } };
        ed.updateCursor();
        return;
    }
    if (button == btn_right) {
        // Right-click abandons the mark in progress.
        if (ed.gesture != .none) ed.cancelGesture();
        return;
    }
    if (button != btn_left) return;

    if (ed.popover) {
        if (ed.popoverHit(l)) {
            if (ed.popoverZone(l)) |z| {
                ed.gesture = if (z == .sv) .sv else .hue;
                ed.popoverPick(l, if (z == .sv) .sv else .hue);
            }
            return;
        }
        const on_custom = if (ed.tb.hit(l[0], l[1])) |it| it == .custom else false;
        if (!on_custom) {
            ed.popover = false;
            ed.dirty = true;
            if (l[1] >= toolbar.height) return; // a click outside just closes it
        }
    }

    if (l[1] < toolbar.height) {
        if (ed.tb.hit(l[0], l[1])) |it| {
            ed.pressed = it;
            ed.activate(it);
        }
        return;
    }

    const p = ed.toImg(l);
    switch (ed.tool) {
        .pen, .highlighter => {
            ed.commitText();
            var pts: std.ArrayList(Pt) = .empty;
            pts.append(ed.gpa, p) catch return;
            ed.gesture = .{ .stroke = .{ .kind = toolKind(ed.tool).?, .pts = pts, .straight = ed.shiftHeld() } };
        },
        .line, .arrow, .rect, .ellipse, .blur, .pixelate => {
            ed.gesture = .{ .shape = .{ .kind = toolKind(ed.tool).?, .a = p, .b = p } };
        },
        .eraser => {
            var ids: std.ArrayList(u32) = .empty;
            ed.eraseAlong(p, p, &ids);
            ed.gesture = .{ .erase = .{ .ids = ids, .last = p } };
        },
        .text => ed.textClick(p),
        .crop => {
            const h = ed.cropHandleAt(l);
            ed.gesture = .{ .crop = .{ .handle = h, .start = p, .orig = ed.crop_pending } };
        },
        .picker => {
            if (ed.sample(p)) |col| ed.setColor(col, true);
            ed.tool = ed.prev_tool;
            ed.updateCursor();
        },
    }
    ed.dirty = true;
}

fn textClick(ed: *Editor, p: Pt) void {
    if (ed.text) |t| {
        const box = ed.rend.measureText(t.buf.items, t.size, t.at);
        const inside = p[0] >= box[0] - 6 and p[0] <= box[0] + box[2] + 6 and p[1] >= box[1] - 4 and p[1] <= box[1] + box[3] + 4;
        if (!inside) ed.commitText();
        return;
    }
    // Click on an existing text object: edit it.
    var i = ed.doc.objs.items.len;
    while (i > 0) {
        i -= 1;
        const o = ed.doc.objs.items[i];
        if (!o.visible or o.kind != .text) continue;
        if (o.distance(p) <= 2) {
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(ed.gpa, o.text) catch return;
            ed.text = .{ .buf = buf, .at = o.points[0], .color = o.color, .size = o.size, .replacing = @intCast(i) };
            return;
        }
    }
    const size = ed.sizes[@backingInt(Tool.text)];
    ed.text = .{ .at = .{ p[0], p[1] - size * 0.6 }, .color = ed.ink, .size = size };
}

fn onRelease(ed: *Editor, button: u32) void {
    if (button == btn_left) ed.pressed = null;
    switch (ed.gesture) {
        .none => {},
        .pan => if (button == btn_middle or button == btn_left) {
            ed.gesture = .none;
        },
        .stroke => |*s| if (button == btn_left) {
            const pts = s.pts.toOwnedSlice(ed.gpa) catch {
                ed.cancelGesture();
                return;
            };
            const kind = s.kind;
            ed.gesture = .none;
            _ = ed.doc.add(.{ .kind = kind, .color = ed.curColor(), .size = ed.curSize(), .points = pts }) catch {};
        },
        .shape => |s| if (button == btn_left) {
            ed.gesture = .none;
            // Ignore clicks that never became a shape (measured on screen).
            if (doc_mod.dist(s.a, s.b) * @as(f32, @floatCast(ed.zoom)) < 3) return;
            const pts = ed.gpa.dupe(Pt, &.{ s.a, s.b }) catch return;
            var o: Obj = .{ .kind = s.kind, .color = ed.curColor(), .size = ed.curSize(), .points = pts };
            if (s.kind == .blur or s.kind == .pixelate) {
                const pb = o.pixelBox().clampTo(ed.doc.bounds());
                if (pb.w < 2 or pb.h < 2) {
                    ed.gpa.free(pts);
                    return;
                }
                o.color = .{ .r = 0, .g = 0, .b = 0 };
            }
            _ = ed.doc.add(o) catch {};
        },
        .erase => |*e| if (button == btn_left) {
            const ids = e.ids.toOwnedSlice(ed.gpa) catch {
                ed.cancelGesture();
                return;
            };
            ed.gesture = .none;
            ed.doc.commitErase(ids) catch {};
        },
        .crop => if (button == btn_left) {
            ed.gesture = .none;
        },
        .sv, .hue => if (button == btn_left) {
            ed.gesture = .none;
        },
    }
    ed.updateCursor();
    ed.dirty = true;
}

fn onScroll(ed: *Editor) void {
    const a = ed.axis;
    ed.axis = .{};
    var dv: f64 = a.v;
    var dh: f64 = a.h;
    if (ed.ctrlHeld()) {
        const steps: f64 = if (a.v120 != 0) @as(f64, @floatFromInt(a.v120)) / 120 else dv / 10;
        if (steps != 0) ed.setZoomAt(ed.zoom * std.math.pow(f64, 1.15, -steps), ed.ptr);
        return;
    }
    if (ed.shiftHeld()) {
        std.mem.swap(f64, &dv, &dh);
    }
    const mult: f64 = if (a.wheel) 3 else 1;
    ed.pan[0] -= dh * mult;
    ed.pan[1] -= dv * mult;
    ed.fit = false;
    ed.clampPan();
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ed: *Editor) void {
    switch (event) {
        .enter => |e| {
            if (e.surface != ed.surface) return;
            ed.enter_serial = e.serial;
            ed.cur_shape = null;
            ed.ptr_in = true;
            ed.onMotion(.{ e.surface_x.toDouble(), e.surface_y.toDouble() });
        },
        .leave => {
            ed.ptr_in = false;
            ed.hover = null;
            ed.dirty = true;
        },
        .motion => |m| ed.onMotion(.{ m.surface_x.toDouble(), m.surface_y.toDouble() }),
        .button => |b| if (b.state == .pressed) ed.onPress(b.button) else ed.onRelease(b.button),
        .axis => |ax| switch (ax.axis) {
            .vertical_scroll => ed.axis.v += ax.value.toDouble(),
            .horizontal_scroll => ed.axis.h += ax.value.toDouble(),
            else => {},
        },
        .axis_value120 => |ax| switch (ax.axis) {
            .vertical_scroll => ed.axis.v120 += ax.value120,
            .horizontal_scroll => ed.axis.h120 += ax.value120,
            else => {},
        },
        .axis_source => |s| ed.axis.wheel = s.axis_source == .wheel,
        .frame => if (ed.axis.v != 0 or ed.axis.h != 0 or ed.axis.v120 != 0 or ed.axis.h120 != 0) ed.onScroll(),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Keyboard

fn ctrlHeld(ed: *const Editor) bool {
    if (ed.test_mods) |m| return m.ctrl;
    const s = ed.xkb_state orelse return false;
    return c.xkb_state_mod_name_is_active(s, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn shiftHeld(ed: *const Editor) bool {
    if (ed.test_mods) |m| return m.shift;
    const s = ed.xkb_state orelse return false;
    return c.xkb_state_mod_name_is_active(s, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn onKeyEvdev(ed: *Editor, evdev: u32) void {
    const state = ed.xkb_state orelse return;
    const kc = evdev + 8;
    const sym = c.xkb_state_key_get_one_sym(state, kc);
    var base = sym;
    if (ed.xkb_keymap) |km| {
        var syms: [*c]const c.xkb_keysym_t = null;
        const layout = c.xkb_state_key_get_layout(state, kc);
        if (c.xkb_keymap_key_get_syms_by_level(km, kc, layout, 0, &syms) > 0) base = syms[0];
    }
    var utf8: [16]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(state, kc, &utf8, utf8.len);
    const len: usize = if (n > 0) @min(@as(usize, @intCast(n)), utf8.len - 1) else 0;
    ed.onKey(sym, c.xkb_keysym_to_lower(base), utf8[0..len]);
}

fn onKey(ed: *Editor, sym: u32, base: u32, utf8: []const u8) void {
    const ctrl = ed.ctrlHeld();
    const shift = ed.shiftHeld();
    ed.dirty = true;

    if (ctrl) {
        switch (base) {
            c.XKB_KEY_z => if (shift) ed.redo() else ed.undo(),
            c.XKB_KEY_y => ed.redo(),
            c.XKB_KEY_c => if (shift) ed.copyText() else ed.copy(),
            c.XKB_KEY_s => if (shift) ed.saveAs() else ed.saveCurrent(),
            c.XKB_KEY_0 => ed.doFit(),
            c.XKB_KEY_1 => ed.setZoomAt(1 / ed.scale, ed.canvasCenter()),
            c.XKB_KEY_equal, c.XKB_KEY_plus, c.XKB_KEY_KP_Add => ed.setZoomAt(ed.zoom * 1.25, ed.canvasCenter()),
            c.XKB_KEY_minus, c.XKB_KEY_KP_Subtract => ed.setZoomAt(ed.zoom / 1.25, ed.canvasCenter()),
            c.XKB_KEY_w, c.XKB_KEY_q => ed.requestClose(),
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => ed.commitText(),
            else => {},
        }
        return;
    }

    // Typing into a text box.
    if (ed.text) |*t| {
        switch (sym) {
            c.XKB_KEY_Escape => ed.commitText(),
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => t.buf.append(ed.gpa, '\n') catch {},
            c.XKB_KEY_BackSpace => {
                var n = t.buf.items.len;
                while (n > 0) {
                    n -= 1;
                    if (t.buf.items[n] & 0xC0 != 0x80) break;
                }
                t.buf.shrinkRetainingCapacity(n);
            },
            else => if (utf8.len > 0 and utf8[0] >= 0x20 and utf8[0] != 0x7f) {
                t.buf.appendSlice(ed.gpa, utf8) catch {};
            },
        }
        return;
    }

    switch (sym) {
        c.XKB_KEY_Escape => {
            if (ed.gesture != .none) return ed.cancelGesture();
            if (ed.popover) {
                ed.popover = false;
                return;
            }
            if (ed.tool == .crop) return ed.cancelCrop();
            if (ed.tool == .picker) {
                ed.tool = ed.prev_tool;
                ed.updateCursor();
                return;
            }
            ed.requestClose();
            return;
        },
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => if (ed.tool == .crop) {
            ed.applyCrop();
            ed.tool = ed.prev_tool;
            ed.updateCursor();
            return;
        },
        c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => if (ed.tool == .crop) {
            ed.crop_pending = ed.doc.bounds();
            return;
        },
        c.XKB_KEY_space => {
            ed.space_down = true;
            ed.updateCursor();
            return;
        },
        else => {},
    }

    const t: ?Tool = switch (base) {
        c.XKB_KEY_p => .pen,
        c.XKB_KEY_h => .highlighter,
        c.XKB_KEY_e => .eraser,
        c.XKB_KEY_l => .line,
        c.XKB_KEY_a => .arrow,
        c.XKB_KEY_r => .rect,
        c.XKB_KEY_o => .ellipse,
        c.XKB_KEY_t => .text,
        c.XKB_KEY_b => .blur,
        c.XKB_KEY_x => .pixelate,
        c.XKB_KEY_c => .crop,
        c.XKB_KEY_i => .picker,
        else => null,
    };
    if (t) |tool| return ed.setTool(tool);
    if (base >= c.XKB_KEY_1 and base <= c.XKB_KEY_8) return ed.setColor(ed.opts.palette[base - c.XKB_KEY_1], true);
    switch (base) {
        c.XKB_KEY_bracketleft => ed.stepSize(-1),
        c.XKB_KEY_bracketright => ed.stepSize(1),
        else => {},
    }
}

fn onKeyRelease(ed: *Editor, evdev: u32) void {
    const state = ed.xkb_state orelse return;
    if (c.xkb_state_key_get_one_sym(state, evdev + 8) == c.XKB_KEY_space) {
        ed.space_down = false;
        ed.updateCursor();
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, ed: *Editor) void {
    switch (event) {
        .keymap => |km| {
            defer _ = c.close(km.fd);
            if (km.format != .xkb_v1 or ed.xkb_ctx == null) return;
            const map = posix.mmap(null, km.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, km.fd, 0) catch return;
            defer posix.munmap(map);
            const len = std.mem.indexOfScalar(u8, map, 0) orelse map.len;
            const keymap = c.xkb_keymap_new_from_buffer(ed.xkb_ctx, map.ptr, len, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
            const state = c.xkb_state_new(keymap) orelse {
                c.xkb_keymap_unref(keymap);
                return;
            };
            if (ed.xkb_state) |s| c.xkb_state_unref(s);
            if (ed.xkb_keymap) |k| c.xkb_keymap_unref(k);
            ed.xkb_keymap = keymap;
            ed.xkb_state = state;
        },
        .modifiers => |m| if (ed.xkb_state) |s| {
            _ = c.xkb_state_update_mask(s, m.mods_depressed, m.mods_latched, m.mods_locked, 0, 0, m.group);
            ed.dirty = true;
        },
        .key => |k| {
            if (k.state == .pressed) {
                ed.onKeyEvdev(k.key);
                if (ed.xkb_keymap) |km| if (c.xkb_keymap_key_repeats(km, k.key + 8) != 0 and ed.repeat_rate > 0) {
                    ed.repeat_key = k.key;
                    ed.repeat_next = now() + ed.repeat_delay;
                };
            } else {
                if (ed.repeat_key == k.key) ed.repeat_key = null;
                ed.onKeyRelease(k.key);
            }
        },
        .repeat_info => |r| {
            ed.repeat_rate = r.rate;
            ed.repeat_delay = r.delay;
        },
        .leave => {
            ed.repeat_key = null;
            ed.space_down = false;
        },
        .enter => {},
    }
}

// ---------------------------------------------------------------------------
// Window listeners

fn xdgSurfaceListener(xs: *xdg.Surface, event: xdg.Surface.Event, ed: *Editor) void {
    switch (event) {
        .configure => |cfg| {
            xs.ackConfigure(cfg.serial);
            if (ed.win_w == 0) {
                ed.win_w = ed.want_w;
                ed.win_h = ed.want_h;
            }
            ed.configured = true;
            ed.dirty = true;
            ed.full_damage = true;
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, ed: *Editor) void {
    switch (event) {
        .configure => |cfg| {
            if (cfg.width > 0 and cfg.height > 0) {
                ed.win_w = @max(cfg.width, 1);
                ed.win_h = @max(cfg.height, 1);
            }
        },
        .close => ed.requestClose(),
        .configure_bounds, .wm_capabilities => {},
    }
}

fn fractionalListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, ed: *Editor) void {
    switch (event) {
        .preferred_scale => |p| {
            const s = @as(f64, @floatFromInt(p.scale)) / 120.0;
            if (s == ed.scale) return;
            const was_100 = @abs(ed.zoom * ed.scale - 1) < 1e-6;
            ed.scale = s;
            if (ed.fit) ed.doFit() else if (was_100) ed.zoom = 1 / s;
            ed.dirty = true;
            ed.full_damage = true;
        },
    }
}

fn frameListener(cb: *wl.Callback, event: wl.Callback.Event, ed: *Editor) void {
    switch (event) {
        .done => {
            cb.destroy();
            ed.frame_cb = null;
            ed.presented += 1;
            if (!ed.relaxed) {
                // Mapped and floating: let the user resize from here on.
                ed.relaxed = true;
                const tl = ed.toplevel.?;
                tl.setMinSize(ed.min_w, @intFromFloat(min_h));
                tl.setMaxSize(0, 0);
                ed.surface.?.commit();
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Test script (PICT_TEST_EDITOR)
//
// Commands separated by ';'. Coordinates are image pixels.
//   tool NAME | color N | size N | fit | zoom PCT
//   drag X0 Y0 X1 Y1 [shift] | path X0 Y0 X1 Y1 ... | click X Y
//   type TEXT (\n = newline) | key [ctrl+][shift+]KEYSYM
//   move LX LY | lclick LX LY (logical window px) | sleep MS | saveas | close
//   save PATH | dump PATH (window buffer as PNG) | quit

const Script = struct {
    rest: []const u8,
    /// Remaining points of a drag in progress, consumed one per frame.
    pending: [64]Pt = undefined,
    np: usize = 0,
    ip: usize = 0,
    shift: bool = false,
    resume_at: i64 = 0,

    fn init(s: []const u8) Script {
        return .{ .rest = s };
    }

    fn next(s: *Script) ?[]const u8 {
        while (s.rest.len > 0) {
            const i = std.mem.indexOfScalar(u8, s.rest, ';') orelse s.rest.len;
            const cmd = std.mem.trim(u8, s.rest[0..i], " \t\n");
            s.rest = if (i < s.rest.len) s.rest[i + 1 ..] else "";
            if (cmd.len > 0) return cmd;
        }
        return null;
    }
};

fn stepScript(ed: *Editor) void {
    const s = &(ed.script.?);
    if (now() < s.resume_at) return;
    // Continue a drag: one motion per frame, then release.
    if (s.np > 0) {
        if (s.ip < s.np) {
            ed.onMotion(ed.toLogical(s.pending[s.ip]));
            s.ip += 1;
        } else {
            ed.onRelease(btn_left);
            s.np = 0;
            ed.test_mods = null;
        }
        ed.dirty = true;
        return;
    }
    const cmd = s.next() orelse {
        ed.script = null;
        return;
    };
    ed.runCommand(cmd) catch |err| std.log.err("test script: '{s}': {t}", .{ cmd, err });
    ed.dirty = true;
}

fn runCommand(ed: *Editor, cmd: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const op = it.next() orelse return;
    const s = &(ed.script.?);
    if (eq(op, "tool")) {
        const name = it.next() orelse return error.MissingArg;
        ed.setTool(std.meta.stringToEnum(Tool, name) orelse return error.BadTool);
    } else if (eq(op, "color")) {
        const n = try std.fmt.parseInt(u8, it.next() orelse return error.MissingArg, 10);
        ed.setColor(ed.opts.palette[n - 1], true);
    } else if (eq(op, "size")) {
        const v = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
        if (ed.text) |*t| t.size = v;
        ed.sizes[@backingInt(ed.tool)] = v;
    } else if (eq(op, "fit")) {
        ed.doFit();
    } else if (eq(op, "zoom")) {
        const pct = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
        ed.setZoomAt(pct / 100 / ed.scale, ed.canvasCenter());
    } else if (eq(op, "drag") or eq(op, "path")) {
        var pts: [64]Pt = undefined;
        var n: usize = 0;
        var shift = false;
        while (it.next()) |tok| {
            if (eq(tok, "shift")) {
                shift = true;
                continue;
            }
            const x = try std.fmt.parseFloat(f32, tok);
            const y = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
            if (n == pts.len) return error.TooManyPoints;
            pts[n] = .{ x, y };
            n += 1;
        }
        if (n < 2) return error.MissingArg;
        if (shift) ed.test_mods = .{ .ctrl = false, .shift = true };
        ed.onMotion(ed.toLogical(pts[0]));
        ed.onPress(btn_left);
        // Interpolate drags so the live frames show progress.
        var m: usize = 0;
        if (eq(op, "drag")) {
            for (1..5) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / 4;
                s.pending[m] = .{ pts[0][0] + (pts[1][0] - pts[0][0]) * t, pts[0][1] + (pts[1][1] - pts[0][1]) * t };
                m += 1;
            }
        } else {
            for (pts[1..n]) |p| {
                s.pending[m] = p;
                m += 1;
            }
        }
        s.np = m;
        s.ip = 0;
    } else if (eq(op, "sleep")) {
        s.resume_at = now() + try std.fmt.parseInt(i64, it.next() orelse return error.MissingArg, 10);
    } else if (eq(op, "move") or eq(op, "lclick")) {
        // Logical window coordinates (toolbar, popover).
        const x = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
        const y = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
        ed.onMotion(.{ x, y });
        if (eq(op, "lclick")) {
            ed.onPress(btn_left);
            ed.onRelease(btn_left);
        }
    } else if (eq(op, "click")) {
        const x = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
        const y = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
        ed.onMotion(ed.toLogical(.{ x, y }));
        ed.onPress(btn_left);
        ed.onRelease(btn_left);
    } else if (eq(op, "type")) {
        const text = std.mem.trimStart(u8, cmd[op.len..], " ");
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == 'n') {
                ed.onKey(c.XKB_KEY_Return, c.XKB_KEY_Return, "");
                i += 1;
            } else {
                ed.onKey(text[i], text[i], text[i .. i + 1]);
            }
        }
    } else if (eq(op, "key")) {
        var combo = it.next() orelse return error.MissingArg;
        var ctrl = false;
        var shift = false;
        while (true) {
            if (std.mem.startsWith(u8, combo, "ctrl+")) {
                ctrl = true;
                combo = combo[5..];
            } else if (std.mem.startsWith(u8, combo, "shift+")) {
                shift = true;
                combo = combo[6..];
            } else break;
        }
        var zbuf: [64]u8 = undefined;
        const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{combo}, 0);
        const sym = c.xkb_keysym_from_name(z.ptr, c.XKB_KEYSYM_NO_FLAGS);
        if (sym == 0) return error.UnknownKey;
        ed.test_mods = .{ .ctrl = ctrl, .shift = shift };
        defer ed.test_mods = null;
        var u: [8]u8 = undefined;
        const n = c.xkb_keysym_to_utf8(sym, &u, u.len);
        ed.onKey(sym, c.xkb_keysym_to_lower(sym), if (n > 1 and !ctrl) u[0..@intCast(n - 1)] else "");
    } else if (eq(op, "saveas")) {
        ed.saveAs();
    } else if (eq(op, "close")) {
        ed.requestClose();
    } else if (eq(op, "save")) {
        ed.finishPending();
        try ed.saveTo(it.next() orelse return error.MissingArg);
    } else if (eq(op, "dump")) {
        const buf = ed.last_buf orelse return error.NothingRendered;
        const view = Image.view(buf.data[0 .. @as(usize, buf.stride) * buf.height], buf.width, buf.height, buf.stride, true);
        const bytes = try png.encode(ed.gpa, view);
        defer ed.gpa.free(bytes);
        const p = try save_mod.saveTo(ed.opts.io, ed.gpa, it.next() orelse return error.MissingArg, bytes);
        ed.gpa.free(p);
    } else if (eq(op, "quit")) {
        ed.finishPending();
        ed.quit = true;
    } else return error.UnknownCommand;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
