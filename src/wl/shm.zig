//! memfd-backed wl_shm buffers.

const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").client.wl;
const c = @import("c");

pub const Buffer = struct {
    wl_buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    stride: u32,
    format: wl.Shm.Format,
    /// True while the compositor holds the buffer (attached and not yet released).
    busy: bool = false,

    pub fn create(gpa: std.mem.Allocator, shm: *wl.Shm, width: u32, height: u32, stride: u32, format: wl.Shm.Format) !*Buffer {
        const size: usize = @as(usize, stride) * height;
        if (size == 0) return error.InvalidBufferSize;

        const fd = try posix.memfd_create("pict-shm", std.os.linux.MFD.CLOEXEC);
        defer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(size)) != 0) return error.FtruncateFailed;

        const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        errdefer posix.munmap(data);

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();
        const wl_buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), format);
        errdefer wl_buffer.destroy();

        const self = try gpa.create(Buffer);
        self.* = .{
            .wl_buffer = wl_buffer,
            .data = data,
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
        };
        wl_buffer.setListener(*Buffer, listener, self);
        return self;
    }

    pub fn destroy(self: *Buffer, gpa: std.mem.Allocator) void {
        self.wl_buffer.destroy();
        posix.munmap(self.data);
        gpa.destroy(self);
    }

    fn listener(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => self.busy = false,
        }
    }
};
