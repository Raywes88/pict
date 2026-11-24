//! Freeze-frame selector: region, freeform lasso, and window modes.
//!
//! One layer-shell surface per output (overlay layer, all edges, exclusive keyboard).
//! Each shows that output's frozen screencopy buffer untouched, scaled 1:1 with
//! wp_viewporter, so fractional scales never resample. A desynchronized subsurface on
//! top carries the dim, the selection outline and the label. It's redrawn only where
//! the selection changed, and only that damage is sent to the compositor.
//!
//! Selections are kept in canvas pixels (layout.zig) so they can span outputs.

const Overlay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const c = @import("c");

const Client = @import("../wl/Client.zig");
const shm = @import("../wl/shm.zig");
const Frame = @import("../capture/screencopy.zig").Frame;
const geom = @import("../geom.zig");
const Rect = geom.Rect;
const layout_mod = @import("../layout.zig");
const Layout = layout_mod.Layout;
const selection = @import("selection.zig");
const Timings = @import("../main.zig").Timings;

pub const Mode = enum { region, freeform, window };

/// A window that can be hovered in window mode.
pub const WindowTarget = struct {
    id: u64,
    /// Index into `frames` of the output it's on.
    output: usize,
    /// Output-local logical rect: x, y, w, h.
    lrect: [4]f64,
    label: []const u8,
};

/// Test hook (PICT_TEST_AUTOSELECT): drives the overlay without input once every output
/// has presented. Coordinates are physical pixels on `output`.
pub const Auto = struct {
    output: usize,
    /// Region: drag this rect. Freeform: trace the inscribed ellipse. Window: click its
    /// top-left corner.
    rect: Rect,
};

pub const Options = struct {
    mode: Mode = .region,
    /// Region mode: keep the selection editable after release (arrows, Shift+arrows, Enter).
    adjust: bool = false,
    timings: ?*Timings = null,
    /// Window mode: hoverable windows, topmost first.
    windows: []const WindowTarget = &.{},
    /// Window mode: niri window to capture when a click hits no known window (niri 26.04
    /// doesn't report tiled window positions).
    fallback_window: ?u64 = null,
    autoselect: ?Auto = null,
};

pub const Result = union(enum) {
    /// Canvas rect.
    rect: Rect,
    /// Canvas bbox plus polygon points (owned by the caller's allocator).
    lasso: struct { bbox: Rect, points: [][2]f64 },
    /// Ask niri to render this window.
    niri_window: u64,
};

pub const Selected = struct { result: Result, layout: Layout };

const dim_alpha = 0.40;
/// Size label, in logical pixels.
const label_font = 14.0;
const label_pad = 6.0;
const btn_left = 0x110;
const btn_right = 0x111;

gpa: Allocator,
client: *Client,
opts: Options,
outs: []OutSurface,
layout: Layout = .{},

sel: selection.Selection = .{},
lasso: selection.Lasso = .{},
hover: ?usize = null,
outcome: ?Result = null,
state: enum { pending, confirmed, cancelled } = .pending,

mapped_marked: bool = false,
auto_stage: u8 = 0,

pointer: ?*wl.Pointer = null,
keyboard: ?*wl.Keyboard = null,
cursor_dev: ?*wp.CursorShapeDeviceV1 = null,
pointer_out: ?usize = null,
pointer_pos: [2]f64 = .{ 0, 0 },

xkb_ctx: ?*c.struct_xkb_context = null,
xkb_keymap: ?*c.struct_xkb_keymap = null,
xkb_state: ?*c.struct_xkb_state = null,

/// 1×1 cairo context used to measure label text.
measure_surf: ?*c.cairo_surface_t = null,
measure_cr: ?*c.cairo_t = null,

/// Run the selector over `frames` (one per output). Returns null if cancelled.
pub fn select(client: *Client, frames: []Frame, opts: Options) !?Selected {
    const gpa = client.gpa;
    const compositor = client.compositor orelse return error.NoCompositor;
    const layer_shell = client.layer_shell orelse return error.NoLayerShell;
    const viewporter = client.viewporter orelse return error.NoViewporter;
    const subcompositor = client.subcompositor orelse return error.NoSubcompositor;
    const seat = client.seat orelse return error.NoSeat;
    if (!client.seat_caps.pointer) return error.NoSeat;
    if (frames.len > layout_mod.max_outputs) return error.TooManyOutputs;

    var ov: Overlay = .{ .gpa = gpa, .client = client, .opts = opts, .outs = &.{} };
    defer ov.teardown();

    ov.measure_surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
    ov.measure_cr = c.cairo_create(ov.measure_surf);
    ov.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);

    ov.outs = try gpa.alloc(OutSurface, frames.len);
    for (ov.outs) |*os| os.* = .{}; // so teardown is safe on partial init
    for (frames, ov.outs, 0..) |*f, *os, i| {
        try os.init(&ov, i, f, compositor, subcompositor, layer_shell, viewporter);
    }
    ov.relayout();

    const pointer = try seat.getPointer();
    ov.pointer = pointer;
    pointer.setListener(*Overlay, pointerListener, &ov);
    if (client.cursor_shape) |cs| ov.cursor_dev = cs.getPointer(pointer) catch null;
    if (client.seat_caps.keyboard) {
        const kb = try seat.getKeyboard();
        ov.keyboard = kb;
        kb.setListener(*Overlay, keyboardListener, &ov);
    }

    while (ov.state == .pending) {
        try client.dispatch();
        while (ov.state == .pending) {
            for (ov.outs) |*os| if (os.dirty) os.render();
            const a = opts.autoselect orelse break;
            if (!ov.stepAutoselect(a)) break; // must wait for a frame callback
        }
    }

    if (ov.state == .cancelled) return null;
    const result = ov.outcome orelse return null;
    ov.outcome = null; // ownership of lasso points moves to the caller
    return .{ .result = result, .layout = ov.layout };
}

fn teardown(ov: *Overlay) void {
    if (ov.outcome) |o| switch (o) {
        .lasso => |l| ov.gpa.free(l.points),
        else => {},
    };
    ov.lasso.deinit(ov.gpa);
    if (ov.cursor_dev) |d| d.destroy();
    if (ov.pointer) |p| p.release();
    if (ov.keyboard) |k| k.release();
    for (ov.outs) |*os| os.deinit(ov.gpa);
    if (ov.outs.len > 0) ov.gpa.free(ov.outs);
    // Make sure the compositor has unmapped us before the caller encodes and saves.
    ov.client.roundtrip() catch {};
    if (ov.xkb_state) |s| c.xkb_state_unref(s);
    if (ov.xkb_keymap) |k| c.xkb_keymap_unref(k);
    if (ov.xkb_ctx) |x| c.xkb_context_unref(x);
    if (ov.measure_cr) |cr| c.cairo_destroy(cr);
    if (ov.measure_surf) |s| c.cairo_surface_destroy(s);
}

fn relayout(ov: *Overlay) void {
    var geoms: [layout_mod.max_outputs]layout_mod.OutputGeom = undefined;
    for (ov.outs, 0..) |*os, i| {
        const o = os.output;
        const lw: i32 = if (o.logical_w > 0) o.logical_w else @intCast(os.logical_w);
        const lh: i32 = if (o.logical_h > 0) o.logical_h else @intCast(os.logical_h);
        geoms[i] = layout_mod.OutputGeom.fromSizes(
            @floatFromInt(o.logical_x),
            @floatFromInt(o.logical_y),
            @floatFromInt(if (lw > 0) lw else @as(i32, @intCast(os.pw))),
            @floatFromInt(if (lh > 0) lh else @as(i32, @intCast(os.ph))),
            @intCast(os.pw),
            @intCast(os.ph),
            os.exact_scale,
        );
    }
    ov.layout = Layout.init(geoms[0..ov.outs.len]);
    ov.markAllDirty();
}

fn markAllDirty(ov: *Overlay) void {
    for (ov.outs) |*os| os.dirty = true;
}

fn pointerCanvas(ov: *Overlay) ?[2]f64 {
    const i = ov.pointer_out orelse return null;
    return ov.layout.toCanvas(i, ov.pointer_pos[0], ov.pointer_pos[1]);
}

fn roundPt(p: [2]f64) [2]i32 {
    return .{ @intFromFloat(@round(p[0])), @intFromFloat(@round(p[1])) };
}

fn windowRect(ov: *const Overlay, w: WindowTarget) Rect {
    return ov.layout.logicalRectToCanvas(w.output, w.lrect[0], w.lrect[1], w.lrect[2], w.lrect[3]);
}

/// Topmost known window under canvas point p (window mode).
fn windowAt(ov: *const Overlay, p: [2]i32) ?usize {
    for (ov.opts.windows, 0..) |w, i| {
        const r = ov.windowRect(w).clampTo(ov.layout.rects[w.output]);
        if (p[0] >= r.x and p[0] < r.x2() and p[1] >= r.y and p[1] < r.y2()) return i;
    }
    return null;
}

fn updateHover(ov: *Overlay) void {
    const p = ov.pointerCanvas() orelse return;
    const h = ov.windowAt(roundPt(p));
    if (h != ov.hover) {
        ov.hover = h;
        ov.markAllDirty();
    }
    // The fallback hint follows the cursor.
    if (h == null and ov.opts.fallback_window != null) ov.markAllDirty();
}

const Shape = union(enum) { none, rect: Rect, lasso: Rect };

fn shape(ov: *const Overlay) Shape {
    switch (ov.opts.mode) {
        .region => if (ov.sel.rect()) |r| return .{ .rect = r },
        .freeform => if (ov.lasso.bbox()) |b| return .{ .lasso = b },
        .window => if (ov.hover) |i| {
            const w = ov.opts.windows[i];
            return .{ .rect = ov.windowRect(w).clampTo(ov.layout.rects[w.output]) };
        },
    }
    return .none;
}

fn labelText(ov: *const Overlay, buf: []u8) ?[:0]const u8 {
    const times = "\u{00d7}";
    switch (ov.shape()) {
        .rect, .lasso => |r| {
            if (ov.opts.mode == .window) {
                const name = ov.opts.windows[ov.hover.?].label;
                const short = name[0..@min(name.len, 40)];
                return std.fmt.bufPrintSentinel(buf, "{s}   {d} " ++ times ++ " {d}", .{ short, r.w, r.h }, 0) catch null;
            }
            return std.fmt.bufPrintSentinel(buf, "{d} " ++ times ++ " {d}", .{ r.w, r.h }, 0) catch null;
        },
        .none => {
            if (ov.opts.mode == .window and ov.opts.fallback_window != null)
                return std.fmt.bufPrintSentinel(buf, "click: focused window", .{}, 0) catch null;
            return null;
        },
    }
}

/// Output that shows the label for canvas rect r: the one under its bottom-left corner,
/// else its top-left, else the pointer's.
fn labelOutput(ov: *const Overlay, r: Rect) ?usize {
    return ov.layout.outputAt(r.x, r.y2() - 1) orelse ov.layout.outputAt(r.x, r.y) orelse ov.pointer_out;
}

fn finish(ov: *Overlay, result: Result) void {
    ov.outcome = result;
    ov.state = .confirmed;
}

fn confirmRegion(ov: *Overlay) void {
    if (ov.sel.rect()) |r| ov.finish(.{ .rect = r });
}

fn confirmLasso(ov: *Overlay) void {
    const b = ov.lasso.bbox() orelse {
        ov.lasso.clear();
        ov.markAllDirty();
        return;
    };
    const pts = ov.gpa.dupe([2]f64, ov.lasso.points.items) catch {
        ov.state = .cancelled;
        return;
    };
    ov.finish(.{ .lasso = .{ .bbox = b, .points = pts } });
}

fn clickWindow(ov: *Overlay) void {
    if (ov.hover) |i| {
        const w = ov.opts.windows[i];
        ov.finish(.{ .rect = ov.windowRect(w).clampTo(ov.layout.rects[w.output]) });
    } else if (ov.opts.fallback_window) |id| {
        ov.finish(.{ .niri_window = id });
    }
}

/// Advance the test hook one stage. Returns false while it must wait for the compositor.
fn stepAutoselect(ov: *Overlay, a: Auto) bool {
    for (ov.outs) |*os| if (os.presented == 0) return false;
    const os = &ov.outs[a.output];
    if (os.frame_cb != null or os.dirty) return false; // wait until the last change was presented

    const o: [2]f64 = .{ @floatFromInt(ov.layout.rects[a.output].x), @floatFromInt(ov.layout.rects[a.output].y) };
    const k = ov.layout.ratio(a.output);
    const toC = struct {
        fn f(origin: [2]f64, kk: f64, x: f64, y: f64) [2]f64 {
            return .{ origin[0] + x / kk, origin[1] + y / kk };
        }
    }.f;
    const r = a.rect;
    const x0: f64 = @floatFromInt(r.x);
    const y0: f64 = @floatFromInt(r.y);
    const w: f64 = @floatFromInt(r.w);
    const h: f64 = @floatFromInt(r.h);

    switch (ov.opts.mode) {
        .region => switch (ov.auto_stage) {
            0 => {
                ov.sel.begin(ov.layout.bounds, roundPt(toC(o, k, x0, y0)));
                ov.sel.update(roundPt(toC(o, k, x0 + w / 2, y0 + h / 2)));
            },
            1 => ov.sel.update(roundPt(toC(o, k, x0 + w, y0 + h))),
            else => {
                ov.sel.dragging = false;
                ov.confirmRegion();
                return true;
            },
        },
        .freeform => {
            const steps = 64;
            const ellipse = struct {
                fn pt(i: usize, ox: f64, oy: f64, ww: f64, hh: f64) [2]f64 {
                    const t = @as(f64, @floatFromInt(i)) / steps * 2 * std.math.pi;
                    return .{ ox + ww / 2 + @cos(t) * ww / 2, oy + hh / 2 + @sin(t) * hh / 2 };
                }
            }.pt;
            switch (ov.auto_stage) {
                0 => {
                    const p0 = ellipse(0, x0, y0, w, h);
                    ov.lasso.begin(ov.gpa, ov.layout.bounds, toC(o, k, p0[0], p0[1])) catch return false;
                    for (1..steps / 2) |i| {
                        const p = ellipse(i, x0, y0, w, h);
                        _ = ov.lasso.add(ov.gpa, toC(o, k, p[0], p[1])) catch return false;
                    }
                },
                1 => for (steps / 2..steps) |i| {
                    const p = ellipse(i, x0, y0, w, h);
                    _ = ov.lasso.add(ov.gpa, toC(o, k, p[0], p[1])) catch return false;
                },
                else => {
                    ov.lasso.dragging = false;
                    ov.confirmLasso();
                    return true;
                },
            }
        },
        .window => switch (ov.auto_stage) {
            0 => {
                ov.pointer_out = a.output;
                const s = ov.layout.geoms[a.output].scale;
                ov.pointer_pos = .{ (x0 + 0.5) / s, (y0 + 0.5) / s };
                ov.updateHover();
            },
            else => {
                ov.clickWindow();
                if (ov.state == .pending) ov.state = .cancelled; // nothing to click: don't hang
                return true;
            },
        },
    }
    ov.auto_stage += 1;
    ov.markAllDirty();
    return true;
}

// ---------------------------------------------------------------------------
// Per-output surfaces

const Kind = enum { none, rect, lasso };

const Drawn = struct {
    kind: Kind = .none,
    /// Selection rect (or lasso bbox) in this output's physical px; may extend past it.
    sel: ?Rect = null,
    /// Lasso point count (points are only ever appended).
    n: usize = 0,
    label: ?Rect = null,
    text_hash: u64 = 0,

    fn eql(a: Drawn, b: Drawn) bool {
        return a.kind == b.kind and optEql(a.sel, b.sel) and a.n == b.n and optEql(a.label, b.label) and a.text_hash == b.text_hash;
    }
    fn optEql(a: ?Rect, b: ?Rect) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.eql(b.?);
    }
};

const UiBuf = struct {
    buf: ?*shm.Buffer = null,
    drawn: ?Drawn = null,
};

const OutSurface = struct {
    ov: *Overlay = undefined,
    idx: usize = 0,
    output: *Client.Output = undefined,
    frame: *Frame = undefined,

    surface: ?*wl.Surface = null,
    layer: ?*zwlr.LayerSurfaceV1 = null,
    viewport: ?*wp.Viewport = null,
    fractional: ?*wp.FractionalScaleV1 = null,
    ui_surface: ?*wl.Surface = null,
    ui_sub: ?*wl.Subsurface = null,
    ui_viewport: ?*wp.Viewport = null,
    bufs: [2]UiBuf = .{ .{}, .{} },
    frame_cb: ?*wl.Callback = null,
    /// Frame callbacks received (frames the compositor has shown).
    presented: u32 = 0,

    configured: bool = false,
    dirty: bool = false,
    committed: ?Drawn = null,
    logical_w: u32 = 0,
    logical_h: u32 = 0,
    /// Exact scale from wp_fractional_scale_v1, if the compositor sent one.
    exact_scale: ?f64 = null,
    /// Frame (physical) size.
    pw: u32 = 0,
    ph: u32 = 0,

    fn init(
        os: *OutSurface,
        ov: *Overlay,
        idx: usize,
        frame: *Frame,
        compositor: *wl.Compositor,
        subcompositor: *wl.Subcompositor,
        layer_shell: *zwlr.LayerShellV1,
        viewporter: *wp.Viewporter,
    ) !void {
        const fb = frame.buffer.?;
        os.* = .{ .ov = ov, .idx = idx, .output = frame.output, .frame = frame, .pw = fb.width, .ph = fb.height };

        const surface = try compositor.createSurface();
        os.surface = surface;
        os.viewport = try viewporter.getViewport(surface);
        if (ov.client.fractional_scale) |fs| {
            if (fs.getFractionalScale(surface)) |f| {
                os.fractional = f;
                f.setListener(*OutSurface, fractionalListener, os);
            } else |_| {}
        }

        const ui = try compositor.createSurface();
        os.ui_surface = ui;
        const sub = try subcompositor.getSubsurface(ui, surface);
        os.ui_sub = sub;
        sub.setPosition(0, 0);
        sub.setDesync();
        os.ui_viewport = try viewporter.getViewport(ui);
        // Input goes to the base surface; the UI layer is click-through.
        const empty = try compositor.createRegion();
        ui.setInputRegion(empty);
        empty.destroy();

        const layer = try layer_shell.getLayerSurface(surface, frame.output.wl_output, .overlay, "pict");
        os.layer = layer;
        layer.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        layer.setExclusiveZone(-1);
        layer.setKeyboardInteractivity(.exclusive);
        layer.setListener(*OutSurface, layerListener, os);
        surface.commit();
    }

    fn deinit(os: *OutSurface, gpa: Allocator) void {
        if (os.frame_cb) |cb| cb.destroy();
        if (os.fractional) |f| f.destroy();
        if (os.ui_viewport) |v| v.destroy();
        if (os.ui_sub) |s| s.destroy();
        if (os.ui_surface) |s| s.destroy();
        if (os.viewport) |v| v.destroy();
        if (os.layer) |l| l.destroy();
        if (os.surface) |s| s.destroy();
        for (&os.bufs) |*b| if (b.buf) |buf| buf.destroy(gpa);
        os.* = .{};
    }

    fn bounds(os: *const OutSurface) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(os.pw), .h = @intCast(os.ph) };
    }

    fn pxScale(os: *const OutSurface) f64 {
        if (os.exact_scale) |s| return s;
        if (os.logical_w == 0) return 1;
        return @as(f64, @floatFromInt(os.pw)) / @as(f64, @floatFromInt(os.logical_w));
    }

    fn borderWidth(os: *const OutSurface) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(os.pxScale()))));
    }

    fn fontSize(os: *const OutSurface) f64 {
        return label_font * os.pxScale();
    }

    /// What this output should show right now.
    fn wanted(os: *OutSurface) Drawn {
        const ov = os.ov;
        var tbuf: [96]u8 = undefined;
        const text = ov.labelText(&tbuf);
        const th: u64 = if (text) |t| std.hash.Wyhash.hash(0, t) else 0;

        switch (ov.shape()) {
            .none => {
                // Window-mode hint follows the cursor on the pointer's output.
                if (text != null and ov.pointer_out == os.idx) {
                    const p = ov.layout.toLocal(os.idx, (ov.pointerCanvas() orelse return .{})[0], ov.pointerCanvas().?[1]);
                    const off = 18.0 * os.pxScale();
                    const anchor = Rect{ .x = @intFromFloat(p[0] + off), .y = @intFromFloat(p[1] + off), .w = 0, .h = 0 };
                    return .{ .label = os.labelRect(anchor, text.?, false), .text_hash = th };
                }
                return .{};
            },
            .rect, .lasso => |r| {
                const kind: Kind = if (ov.shape() == .rect) .rect else .lasso;
                const local = ov.layout.rectToLocal(os.idx, r);
                const bw = os.borderWidth();
                const visible = !local.inflate(bw + 1).intersect(os.bounds()).isEmpty();
                var d: Drawn = .{ .kind = if (visible) kind else .none, .sel = if (visible) local else null };
                if (kind == .lasso and visible) d.n = ov.lasso.points.items.len;
                if (text != null and ov.labelOutput(r) == os.idx) {
                    d.label = os.labelRect(local, text.?, true);
                    d.text_hash = th;
                }
                return d;
            },
        }
    }

    /// Label box for `text`: below `r` (or above / inside when there's no room), clamped
    /// to this output. With below = false, `r` is just an anchor point.
    fn labelRect(os: *OutSurface, r: Rect, text: [:0]const u8, below: bool) Rect {
        const cr = os.ov.measure_cr.?;
        setFont(cr, os.fontSize());
        var ext: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, text.ptr, &ext);
        const s = os.pxScale();
        const pad = label_pad * s;
        const w: i32 = @intFromFloat(@ceil(ext.x_advance + 2 * pad));
        const h: i32 = @intFromFloat(@ceil(os.fontSize() * 1.25 + pad));
        const gap: i32 = @intFromFloat(@round(6.0 * s));
        const bw = os.borderWidth();
        const b = os.bounds();

        var y = if (below) r.y2() + bw + gap else r.y;
        if (y + h > b.h) y = if (below) r.y - bw - gap - h else b.h - h; // no room below: go above
        if (y < 0) y = if (below) @max(0, r.y) + gap else 0; // no room above either: inside
        const x = std.math.clamp(r.x, 0, @max(0, b.w - w));
        return .{ .x = x, .y = std.math.clamp(y, 0, @max(0, b.h - h)), .w = w, .h = h };
    }

    /// Rects that differ between two drawn states (clamped to the frame).
    fn changed(os: *const OutSurface, a: ?Drawn, b: Drawn, out: *[8]Rect) []Rect {
        const full = os.bounds();
        const prev = a orelse {
            out[0] = full;
            return out[0..1];
        };
        if (prev.eql(b)) return out[0..0];

        var n: usize = 0;
        const bw = os.borderWidth();
        const lasso = prev.kind == .lasso or b.kind == .lasso;
        const grow = if (lasso) bw + 2 else bw;
        if (prev.sel != null or b.sel != null) {
            if (prev.sel == null or b.sel == null) {
                out[n] = (prev.sel orelse b.sel.?).inflate(grow).clampTo(full);
                n += 1;
            } else if (lasso or prev.kind != b.kind) {
                out[n] = prev.sel.?.inflate(grow).bbox(b.sel.?.inflate(grow)).clampTo(full);
                n += 1;
            } else {
                // Rect → rect: pixels inside both holes are unchanged.
                const outer = prev.sel.?.inflate(bw).bbox(b.sel.?.inflate(bw)).clampTo(full);
                var parts: [4]Rect = undefined;
                for (geom.subtract(outer, prev.sel.?.intersect(b.sel.?), &parts)) |p| {
                    out[n] = p;
                    n += 1;
                }
            }
        }
        if (prev.label) |l| {
            out[n] = l.clampTo(full);
            n += 1;
        }
        if (b.label) |l| {
            out[n] = l.clampTo(full);
            n += 1;
        }
        return out[0..n];
    }

    fn freeBuffer(os: *OutSurface) ?*UiBuf {
        for (&os.bufs) |*b| {
            if (b.buf) |buf| {
                if (!buf.busy) return b;
            }
        }
        // Allocate lazily: idle outputs only ever need one buffer.
        for (&os.bufs) |*b| {
            if (b.buf == null) {
                b.buf = shm.Buffer.create(os.ov.gpa, os.ov.client.shm.?, os.pw, os.ph, os.pw * 4, .argb8888) catch return null;
                return b;
            }
        }
        return null;
    }

    fn render(os: *OutSurface) void {
        if (!os.configured or os.frame_cb != null) return; // wait for configure / frame callback
        const want = os.wanted();
        if (os.committed) |cur| if (cur.eql(want)) {
            os.dirty = false;
            return;
        };
        const ub = os.freeBuffer() orelse return; // both busy; retry after the next event
        const buf = ub.buf.?;

        var paint_rects: [8]Rect = undefined;
        os.paint(buf, os.changed(ub.drawn, want, &paint_rects), want);
        ub.drawn = want;

        const ui = os.ui_surface.?;
        var dmg: [8]Rect = undefined;
        for (os.changed(os.committed, want, &dmg)) |r| ui.damageBuffer(r.x, r.y, r.w, r.h);
        ui.attach(buf.wl_buffer, 0, 0);
        buf.busy = true;
        if (ui.frame()) |cb| {
            os.frame_cb = cb;
            cb.setListener(*OutSurface, frameListener, os);
        } else |_| {}
        ui.commit();
        os.committed = want;
        os.dirty = false;
    }

    fn paint(os: *OutSurface, buf: *shm.Buffer, region: []const Rect, want: Drawn) void {
        if (region.len == 0) return;
        const surf = c.cairo_image_surface_create_for_data(buf.data.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(buf.width), @intCast(buf.height), @intCast(buf.stride));
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf) orelse return;
        defer c.cairo_destroy(cr);

        for (region) |r| rect(cr, r);
        c.cairo_clip(cr);

        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0, 0, 0, dim_alpha);
        c.cairo_paint(cr);

        const bw = os.borderWidth();
        switch (want.kind) {
            .none => {},
            .rect => {
                const s = want.sel.?;
                // Clear the hole so the frozen frame shows through untouched.
                rect(cr, s);
                c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
                c.cairo_fill(cr);
                // Border sits outside the selection, never over selected pixels.
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
                c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_EVEN_ODD);
                rect(cr, s.inflate(bw));
                rect(cr, s);
                c.cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
                c.cairo_fill(cr);
                c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_WINDING);
            },
            .lasso => {
                const pts = os.ov.lasso.points.items[0..@min(want.n, os.ov.lasso.points.items.len)];
                for (pts, 0..) |p, i| {
                    const q = os.ov.layout.toLocal(os.idx, p[0], p[1]);
                    if (i == 0) c.cairo_move_to(cr, q[0], q[1]) else c.cairo_line_to(cr, q[0], q[1]);
                }
                c.cairo_close_path(cr);
                c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
                c.cairo_fill_preserve(cr);
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
                c.cairo_set_line_width(cr, @floatFromInt(bw));
                c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
                c.cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
                c.cairo_stroke(cr);
            },
        }

        if (want.label) |l| {
            var tbuf: [96]u8 = undefined;
            const text = os.ov.labelText(&tbuf) orelse return;
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            roundedRect(cr, l, 4.0 * os.pxScale());
            c.cairo_set_source_rgba(cr, 0.08, 0.08, 0.10, 0.85);
            c.cairo_fill(cr);

            setFont(cr, os.fontSize());
            var fe: c.cairo_font_extents_t = undefined;
            c.cairo_font_extents(cr, &fe);
            const pad = label_pad * os.pxScale();
            const lh: f64 = @floatFromInt(l.h);
            const baseline = @as(f64, @floatFromInt(l.y)) + (lh + fe.ascent - fe.descent) / 2.0;
            c.cairo_move_to(cr, @as(f64, @floatFromInt(l.x)) + pad, @round(baseline));
            c.cairo_set_source_rgba(cr, 1, 1, 1, 1);
            c.cairo_show_text(cr, text.ptr);
        }
        c.cairo_surface_flush(surf);
    }

    fn onConfigure(os: *OutSurface, w: u32, h: u32) void {
        os.logical_w = if (w > 0) w else @intCast(@max(1, os.output.logical_w));
        os.logical_h = if (h > 0) h else @intCast(@max(1, os.output.logical_h));
        const lw: i32 = @intCast(os.logical_w);
        const lh: i32 = @intCast(os.logical_h);

        os.viewport.?.setDestination(lw, lh);
        os.ui_viewport.?.setDestination(lw, lh);
        if (!os.configured) {
            const surface = os.surface.?;
            surface.attach(os.frame.buffer.?.wl_buffer, 0, 0);
            surface.damageBuffer(0, 0, @intCast(os.pw), @intCast(os.ph));
            const opaque_region = os.ov.client.compositor.?.createRegion() catch null;
            if (opaque_region) |r| {
                r.add(0, 0, lw, lh);
                surface.setOpaqueRegion(r);
                r.destroy();
            }
            os.configured = true;
            os.ov.relayout();
            os.render(); // first UI commit, before the parent maps
        }
        os.surface.?.commit();
    }
};

fn rect(cr: *c.cairo_t, r: Rect) void {
    c.cairo_rectangle(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
}

fn roundedRect(cr: *c.cairo_t, r: Rect, radius: f64) void {
    const x: f64 = @floatFromInt(r.x);
    const y: f64 = @floatFromInt(r.y);
    const w: f64 = @floatFromInt(r.w);
    const h: f64 = @floatFromInt(r.h);
    const rad = @min(radius, @min(w, h) / 2.0);
    const pi = std.math.pi;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - rad, y + rad, rad, -pi / 2.0, 0);
    c.cairo_arc(cr, x + w - rad, y + h - rad, rad, 0, pi / 2.0);
    c.cairo_arc(cr, x + rad, y + h - rad, rad, pi / 2.0, pi);
    c.cairo_arc(cr, x + rad, y + rad, rad, pi, 3.0 * pi / 2.0);
    c.cairo_close_path(cr);
}

fn setFont(cr: *c.cairo_t, size: f64) void {
    c.cairo_select_font_face(cr, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, size);
}

// ---------------------------------------------------------------------------
// Listeners

fn layerListener(layer: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, os: *OutSurface) void {
    switch (event) {
        .configure => |cfg| {
            layer.ackConfigure(cfg.serial);
            os.onConfigure(cfg.width, cfg.height);
        },
        .closed => os.ov.state = .cancelled,
    }
}

fn fractionalListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, os: *OutSurface) void {
    switch (event) {
        .preferred_scale => |p| {
            os.exact_scale = @as(f64, @floatFromInt(p.scale)) / 120.0;
            os.ov.relayout();
        },
    }
}

fn frameListener(cb: *wl.Callback, event: wl.Callback.Event, os: *OutSurface) void {
    switch (event) {
        .done => {
            cb.destroy();
            os.frame_cb = null;
            os.presented += 1;
            const ov = os.ov;
            if (!ov.mapped_marked) {
                ov.mapped_marked = true;
                if (ov.opts.timings) |t| t.mark("overlay");
            }
        },
    }
}

fn outIndex(ov: *Overlay, surface: ?*wl.Surface) ?usize {
    const s = surface orelse return null;
    for (ov.outs, 0..) |*os, i| if (os.surface == s) return i;
    return null;
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ov: *Overlay) void {
    switch (event) {
        .enter => |e| {
            ov.pointer_out = outIndex(ov, e.surface);
            ov.pointer_pos = .{ e.surface_x.toDouble(), e.surface_y.toDouble() };
            if (ov.cursor_dev) |d| d.setShape(e.serial, .crosshair);
            ov.onPointerMoved();
        },
        .leave => {},
        .motion => |m| {
            ov.pointer_pos = .{ m.surface_x.toDouble(), m.surface_y.toDouble() };
            ov.onPointerMoved();
        },
        .button => |b| {
            const pressed = b.state == .pressed;
            if (b.button == btn_right and pressed) {
                ov.state = .cancelled;
            } else if (b.button == btn_left) {
                if (pressed) ov.onPress() else ov.onRelease();
            }
        },
        else => {},
    }
}

fn onPress(ov: *Overlay) void {
    const p = ov.pointerCanvas() orelse return;
    switch (ov.opts.mode) {
        .region => ov.sel.begin(ov.layout.bounds, roundPt(p)),
        .freeform => ov.lasso.begin(ov.gpa, ov.layout.bounds, p) catch return,
        .window => return ov.clickWindow(),
    }
    ov.markAllDirty();
}

fn onRelease(ov: *Overlay) void {
    switch (ov.opts.mode) {
        .region => {
            if (!ov.sel.dragging) return;
            ov.sel.dragging = false;
            if (ov.sel.rect() == null) {
                ov.sel.clear(); // a click without a drag selects nothing
                ov.markAllDirty();
            } else if (!ov.opts.adjust) {
                ov.confirmRegion();
            }
        },
        .freeform => {
            if (!ov.lasso.dragging) return;
            ov.lasso.dragging = false;
            ov.confirmLasso();
        },
        .window => {},
    }
}

fn onPointerMoved(ov: *Overlay) void {
    switch (ov.opts.mode) {
        .region => if (ov.sel.dragging) {
            const p = ov.pointerCanvas() orelse return;
            ov.sel.update(roundPt(p));
            ov.markAllDirty();
        },
        .freeform => if (ov.lasso.dragging) {
            const p = ov.pointerCanvas() orelse return;
            if (ov.lasso.add(ov.gpa, p) catch false) ov.markAllDirty();
        },
        .window => ov.updateHover(),
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, ov: *Overlay) void {
    switch (event) {
        .keymap => |km| {
            defer _ = c.close(km.fd);
            if (km.format != .xkb_v1 or ov.xkb_ctx == null) return;
            const map = std.posix.mmap(null, km.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, km.fd, 0) catch return;
            defer std.posix.munmap(map);
            const len = std.mem.indexOfScalar(u8, map, 0) orelse map.len; // usually NUL-terminated
            const keymap = c.xkb_keymap_new_from_buffer(ov.xkb_ctx, map.ptr, len, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
            const state = c.xkb_state_new(keymap) orelse {
                c.xkb_keymap_unref(keymap);
                return;
            };
            if (ov.xkb_state) |s| c.xkb_state_unref(s);
            if (ov.xkb_keymap) |k| c.xkb_keymap_unref(k);
            ov.xkb_keymap = keymap;
            ov.xkb_state = state;
        },
        .modifiers => |m| if (ov.xkb_state) |s| {
            _ = c.xkb_state_update_mask(s, m.mods_depressed, m.mods_latched, m.mods_locked, 0, 0, m.group);
        },
        .key => |k| if (k.state == .pressed) ov.onKey(k.key),
        .enter, .leave, .repeat_info => {},
    }
}

const Key = enum { escape, enter, left, right, up, down, other };

fn classify(ov: *Overlay, evdev: u32) Key {
    if (ov.xkb_state) |s| {
        return switch (c.xkb_state_key_get_one_sym(s, evdev + 8)) {
            c.XKB_KEY_Escape => .escape,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .enter,
            c.XKB_KEY_Left => .left,
            c.XKB_KEY_Right => .right,
            c.XKB_KEY_Up => .up,
            c.XKB_KEY_Down => .down,
            else => .other,
        };
    }
    // No keymap: raw evdev codes.
    return switch (evdev) {
        1 => .escape,
        28, 96 => .enter,
        105 => .left,
        106 => .right,
        103 => .up,
        108 => .down,
        else => .other,
    };
}

fn shiftHeld(ov: *Overlay) bool {
    const s = ov.xkb_state orelse return false;
    return c.xkb_state_mod_name_is_active(s, "Shift", c.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn onKey(ov: *Overlay, evdev: u32) void {
    const key = ov.classify(evdev);
    switch (key) {
        .escape => ov.state = .cancelled,
        .enter => switch (ov.opts.mode) {
            .region => ov.confirmRegion(),
            .window => ov.clickWindow(),
            .freeform => {},
        },
        .left, .right, .up, .down => {
            if (ov.opts.mode != .region or ov.sel.dragging) return;
            const d: [2]i32 = switch (key) {
                .left => .{ -1, 0 },
                .right => .{ 1, 0 },
                .up => .{ 0, -1 },
                .down => .{ 0, 1 },
                else => unreachable,
            };
            ov.sel.nudge(d[0], d[1], ov.shiftHeld());
            ov.markAllDirty();
        },
        .other => {},
    }
}
