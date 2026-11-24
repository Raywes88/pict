//! Freeze-frame region selector.
//!
//! One layer-shell surface per output (overlay layer, all edges, exclusive keyboard).
//! Each shows that output's frozen screencopy buffer untouched, scaled 1:1 with
//! wp_viewporter, so fractional scales never resample. A desynchronized subsurface on
//! top carries the dim, the selection border and the size label. It's redrawn only
//! where the selection changed, and only that damage is sent to the compositor.

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
const selection = @import("selection.zig");
const Timings = @import("../main.zig").Timings;

pub const Options = struct {
    /// Keep the selection editable after release (arrows, Shift+arrows, Enter).
    adjust: bool = false,
    timings: ?*Timings = null,
    /// Test hook (PICT_TEST_AUTOSELECT): once every output has presented, drag to `rect`
    /// on `frame` in two steps, then confirm. Exercises the real render/damage path.
    autoselect: ?Result = null,
};

pub const Result = struct { frame: usize, rect: Rect };

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
sel: selection.Selection = .{},
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
pub fn select(client: *Client, frames: []Frame, opts: Options) !?Result {
    const gpa = client.gpa;
    const compositor = client.compositor orelse return error.NoCompositor;
    const layer_shell = client.layer_shell orelse return error.NoLayerShell;
    const viewporter = client.viewporter orelse return error.NoViewporter;
    const subcompositor = client.subcompositor orelse return error.NoSubcompositor;
    const seat = client.seat orelse return error.NoSeat;
    if (!client.seat_caps.pointer) return error.NoSeat;

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
        if (opts.autoselect) |a| ov.stepAutoselect(a);
        for (ov.outs) |*os| if (os.dirty) os.render();
    }

    if (ov.state == .cancelled) return null;
    const r = ov.sel.rect() orelse return null;
    return .{ .frame = ov.sel.frame.?, .rect = r };
}

fn teardown(ov: *Overlay) void {
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

fn stepAutoselect(ov: *Overlay, a: Result) void {
    for (ov.outs) |*os| if (os.presented == 0) return;
    const os = &ov.outs[a.frame];
    if (os.frame_cb != null or os.dirty) return; // wait until the last change was presented
    const r = a.rect;
    switch (ov.auto_stage) {
        0 => {
            ov.sel.begin(a.frame, os.bounds(), .{ r.x, r.y });
            ov.sel.update(.{ r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2) });
        },
        1 => ov.sel.update(.{ r.x2(), r.y2() }),
        else => {
            ov.sel.dragging = false;
            ov.confirm();
            return;
        },
    }
    ov.auto_stage += 1;
    ov.markAllDirty();
}

fn markAllDirty(ov: *Overlay) void {
    for (ov.outs) |*os| os.dirty = true;
}

fn geomOf(ov: *Overlay, idx: usize) selection.OutputGeom {
    const os = &ov.outs[idx];
    const o = os.output;
    const lw: f64 = @floatFromInt(if (o.logical_w > 0) o.logical_w else @as(i32, @intCast(os.logical_w)));
    const lh: f64 = @floatFromInt(if (o.logical_h > 0) o.logical_h else @as(i32, @intCast(os.logical_h)));
    return .{
        .lx = @floatFromInt(o.logical_x),
        .ly = @floatFromInt(o.logical_y),
        .lw = if (lw > 0) lw else @floatFromInt(os.pw),
        .lh = if (lh > 0) lh else @floatFromInt(os.ph),
        .pw = @intCast(os.pw),
        .ph = @intCast(os.ph),
    };
}

/// Pointer position mapped onto output `to`'s frame.
fn pointerOn(ov: *Overlay, to: usize) ?[2]i32 {
    const from = ov.pointer_out orelse return null;
    return selection.toPhysical(ov.geomOf(from), ov.geomOf(to), ov.pointer_pos[0], ov.pointer_pos[1]);
}

fn confirm(ov: *Overlay) void {
    if (ov.sel.rect() != null) ov.state = .confirmed;
}

// ---------------------------------------------------------------------------
// Per-output surfaces

const Drawn = struct {
    sel: ?Rect = null,
    label: ?Rect = null,

    fn eql(a: Drawn, b: Drawn) bool {
        return optEql(a.sel, b.sel) and optEql(a.label, b.label);
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
        if (os.logical_w == 0) return 1;
        return @as(f64, @floatFromInt(os.pw)) / @as(f64, @floatFromInt(os.logical_w));
    }

    fn borderWidth(os: *const OutSurface) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(os.pxScale()))));
    }

    /// What this output should show right now.
    fn wanted(os: *OutSurface) Drawn {
        const ov = os.ov;
        if (ov.sel.frame != os.idx) return .{};
        const r = ov.sel.rect() orelse return .{};
        return .{ .sel = r, .label = os.labelRect(r) };
    }

    fn labelText(buf: []u8, r: Rect) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{d} \u{00d7} {d}", .{ r.w, r.h }, 0) catch "";
    }

    fn fontSize(os: *const OutSurface) f64 {
        return label_font * os.pxScale();
    }

    fn labelRect(os: *OutSurface, r: Rect) Rect {
        const cr = os.ov.measure_cr.?;
        var tbuf: [48]u8 = undefined;
        const text = labelText(&tbuf, r);
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

        var y = r.y2() + bw + gap;
        if (y + h > b.h) y = r.y - bw - gap - h; // no room below: go above
        if (y < 0) y = r.y + gap; // no room above either: inside
        const x = std.math.clamp(r.x, 0, @max(0, b.w - w));
        return .{ .x = x, .y = y, .w = w, .h = h };
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
        if (prev.sel != null or b.sel != null) {
            if (prev.sel == null or b.sel == null) {
                out[n] = (prev.sel orelse b.sel.?).inflate(bw).clampTo(full);
                n += 1;
            } else {
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

        for (region) |r| c.cairo_rectangle(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
        c.cairo_clip(cr);

        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0, 0, 0, dim_alpha);
        c.cairo_paint(cr);

        if (want.sel) |s| {
            // Clear the hole so the frozen frame shows through untouched.
            rect(cr, s);
            c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
            c.cairo_fill(cr);
            // Border sits outside the selection, never over selected pixels.
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_EVEN_ODD);
            rect(cr, s.inflate(os.borderWidth()));
            rect(cr, s);
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
            c.cairo_fill(cr);
            c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_WINDING);
        }

        if (want.label) |l| {
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            roundedRect(cr, l, 4.0 * os.pxScale());
            c.cairo_set_source_rgba(cr, 0.08, 0.08, 0.10, 0.85);
            c.cairo_fill(cr);

            var tbuf: [48]u8 = undefined;
            const text = labelText(&tbuf, want.sel.?);
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
            os.dirty = true;
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
            } else if (b.button == btn_left and pressed) {
                const idx = ov.pointer_out orelse return;
                const p = ov.pointerOn(idx) orelse return;
                ov.sel.begin(idx, ov.outs[idx].bounds(), p);
                ov.markAllDirty();
            } else if (b.button == btn_left and !pressed and ov.sel.dragging) {
                ov.sel.dragging = false;
                if (ov.sel.rect() == null) {
                    ov.sel.clear(); // a click without a drag selects nothing
                    ov.markAllDirty();
                } else if (!ov.opts.adjust) {
                    ov.confirm();
                }
            }
        },
        else => {},
    }
}

fn onPointerMoved(ov: *Overlay) void {
    if (!ov.sel.dragging) return;
    const idx = ov.sel.frame orelse return;
    const p = ov.pointerOn(idx) orelse return;
    ov.sel.update(p);
    ov.outs[idx].dirty = true;
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
        .enter => ov.confirm(),
        .left, .right, .up, .down => {
            if (ov.sel.dragging) return;
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
