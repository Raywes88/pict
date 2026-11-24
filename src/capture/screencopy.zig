//! Output capture via zwlr_screencopy_manager_v1 (niri 26.04's capture protocol).
//! Every output is requested at once, then events are dispatched until all finish,
//! so a multi-monitor freeze costs one frame, not one per monitor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Client = @import("../wl/Client.zig");
const shm = @import("../wl/shm.zig");
const Image = @import("../image/Image.zig");

pub const Frame = struct {
    output: *Client.Output,
    /// Pixels (normalized to ARGB8888/XRGB8888, upright). Also attachable as a wl_buffer.
    buffer: ?*shm.Buffer = null,

    client: *Client,
    proxy: ?*zwlr.ScreencopyFrameV1 = null,
    offered: ?Offer = null,
    y_invert: bool = false,
    state: enum { pending, ready, failed } = .pending,

    const Offer = struct { format: wl.Shm.Format, width: u32, height: u32, stride: u32 };

    pub fn image(f: *const Frame) Image {
        const b = f.buffer.?;
        return Image.view(b.data, b.width, b.height, b.stride, true);
    }

    pub fn deinit(f: *Frame, gpa: Allocator) void {
        if (f.proxy) |p| p.destroy();
        if (f.buffer) |b| b.destroy(gpa);
        f.* = undefined;
    }
};

pub const Error = error{ NoScreencopy, NoShm, CaptureFailed, UnsupportedFormat } || Allocator.Error;

/// Capture `outputs` in parallel. The returned slice owns its frames.
pub fn capture(client: *Client, outputs: []const *Client.Output, cursor: bool) Error![]Frame {
    const gpa = client.gpa;
    const mgr = client.screencopy orelse return error.NoScreencopy;
    if (client.shm == null) return error.NoShm;

    const frames = try gpa.alloc(Frame, outputs.len);
    errdefer gpa.free(frames);
    for (frames, outputs) |*f, o| f.* = .{ .output = o, .client = client };
    errdefer for (frames) |*f| f.deinit(gpa);

    for (frames) |*f| {
        const p = mgr.captureOutput(@intFromBool(cursor), f.output.wl_output) catch return error.OutOfMemory;
        f.proxy = p;
        p.setListener(*Frame, frameListener, f);
    }

    while (true) {
        var pending = false;
        for (frames) |f| {
            if (f.state == .failed) return error.CaptureFailed;
            if (f.state == .pending) pending = true;
        }
        if (!pending) break;
        client.dispatch() catch return error.CaptureFailed;
    }

    for (frames) |*f| {
        f.proxy.?.destroy();
        f.proxy = null;
        try normalize(f, gpa);
    }
    return frames;
}

pub fn freeFrames(gpa: Allocator, frames: []Frame) void {
    for (frames) |*f| f.deinit(gpa);
    gpa.free(frames);
}

fn supported(fmt: wl.Shm.Format) bool {
    return switch (fmt) {
        .xrgb8888, .argb8888, .xbgr8888, .abgr8888 => true,
        else => false,
    };
}

fn startCopy(f: *Frame) void {
    const offer = f.offered orelse {
        f.state = .failed;
        return;
    };
    const b = shm.Buffer.create(f.client.gpa, f.client.shm.?, offer.width, offer.height, offer.stride, offer.format) catch {
        f.state = .failed;
        return;
    };
    f.buffer = b;
    f.proxy.?.copy(b.wl_buffer);
}

fn frameListener(proxy: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, f: *Frame) void {
    switch (event) {
        .buffer => |b| {
            // Prefer XRGB/ARGB (no conversion) if several shm formats are offered.
            const better = if (f.offered) |cur| (b.format == .xrgb8888 or b.format == .argb8888) and
                !(cur.format == .xrgb8888 or cur.format == .argb8888) else true;
            if (supported(b.format) and better) {
                f.offered = .{ .format = b.format, .width = b.width, .height = b.height, .stride = b.stride };
            }
            // v1/v2 have no buffer_done: copy as soon as the shm buffer is described.
            if (proxy.getVersion() < 3) startCopy(f);
        },
        .linux_dmabuf, .damage => {},
        .buffer_done => startCopy(f),
        .flags => |fl| f.y_invert = fl.flags.y_invert,
        .ready => f.state = .ready,
        .failed => f.state = .failed,
    }
}

/// Make the frame upright XRGB/ARGB with opaque alpha.
fn normalize(f: *Frame, gpa: Allocator) Error!void {
    const b = f.buffer.?;
    switch (b.format) {
        .xrgb8888, .argb8888 => {},
        .xbgr8888, .abgr8888 => {
            // Swap R and B in place, then relabel by re-creating the wl_buffer as XRGB.
            const conv = shm.Buffer.create(gpa, f.client.shm.?, b.width, b.height, b.stride, .xrgb8888) catch return error.OutOfMemory;
            var i: usize = 0;
            while (i + 3 < b.data.len) : (i += 4) {
                conv.data[i + 0] = b.data[i + 2];
                conv.data[i + 1] = b.data[i + 1];
                conv.data[i + 2] = b.data[i + 0];
                conv.data[i + 3] = 0xFF;
            }
            b.destroy(gpa);
            f.buffer = conv;
        },
        else => return error.UnsupportedFormat,
    }
    var img = f.image();
    if (f.y_invert) img.flipVertical();
    img.forceOpaque();
}
