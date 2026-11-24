//! A pixel buffer in native-endian ARGB32 (premultiplied), the format shared by
//! wl_shm ARGB8888/XRGB8888 and cairo's CAIRO_FORMAT_ARGB32. In memory on
//! little-endian that is B, G, R, A per pixel.

const Image = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("../geom.zig").Rect;

width: u32,
height: u32,
/// Bytes per row.
stride: u32,
pixels: []u8,
/// False for views onto memory owned elsewhere (e.g. a screencopy shm buffer).
owned: bool,
/// True when every alpha byte is 0xFF (screen captures). Lets encoders drop alpha.
is_opaque: bool,

pub fn view(pixels: []u8, width: u32, height: u32, stride: u32, is_opaque: bool) Image {
    return .{ .width = width, .height = height, .stride = stride, .pixels = pixels, .owned = false, .is_opaque = is_opaque };
}

pub fn alloc(gpa: Allocator, width: u32, height: u32) !Image {
    const stride = width * 4;
    const pixels = try gpa.alloc(u8, @as(usize, stride) * height);
    return .{ .width = width, .height = height, .stride = stride, .pixels = pixels, .owned = true, .is_opaque = false };
}

pub fn deinit(self: *Image, gpa: Allocator) void {
    if (self.owned) gpa.free(self.pixels);
    self.* = undefined;
}

pub fn bounds(self: Image) Rect {
    return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
}

/// Copy `rect` (clamped to the image) into a new owned image.
pub fn crop(self: Image, gpa: Allocator, rect: Rect) !Image {
    const r = rect.clampTo(self.bounds());
    if (r.isEmpty()) return error.EmptySelection;
    var out = try alloc(gpa, @intCast(r.w), @intCast(r.h));
    out.is_opaque = self.is_opaque;
    const row_bytes: usize = @as(usize, @intCast(r.w)) * 4;
    var y: usize = 0;
    while (y < out.height) : (y += 1) {
        const src_off = (@as(usize, @intCast(r.y)) + y) * self.stride + @as(usize, @intCast(r.x)) * 4;
        @memcpy(out.pixels[y * out.stride ..][0..row_bytes], self.pixels[src_off..][0..row_bytes]);
    }
    return out;
}

/// Flip rows in place (screencopy `y_invert`).
pub fn flipVertical(self: Image) void {
    var top: usize = 0;
    var bottom: usize = self.height -| 1;
    const row_bytes: usize = @as(usize, self.width) * 4;
    while (top < bottom) : ({
        top += 1;
        bottom -= 1;
    }) {
        const a = self.pixels[top * self.stride ..][0..row_bytes];
        const b = self.pixels[bottom * self.stride ..][0..row_bytes];
        for (a, b) |*x, *y| std.mem.swap(u8, x, y);
    }
}

/// Force every alpha byte to 0xFF (XRGB sources leave it undefined).
pub fn forceOpaque(self: *Image) void {
    var y: usize = 0;
    while (y < self.height) : (y += 1) {
        const row = self.pixels[y * self.stride ..][0 .. @as(usize, self.width) * 4];
        var i: usize = 3;
        while (i < row.len) : (i += 4) row[i] = 0xFF;
    }
    self.is_opaque = true;
}

test "crop copies the right pixels" {
    const gpa = std.testing.allocator;
    var img = try alloc(gpa, 4, 3);
    defer img.deinit(gpa);
    for (img.pixels, 0..) |*p, i| p.* = @intCast(i / 4); // pixel index in every byte
    var c = try img.crop(gpa, .{ .x = 1, .y = 1, .w = 2, .h = 2 });
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), c.width);
    try std.testing.expectEqual(@as(u8, 5), c.pixels[0]); // (1,1) = index 5
    try std.testing.expectEqual(@as(u8, 10), c.pixels[c.stride + 4]); // (2,2) = index 10
}

test "flipVertical swaps rows" {
    const gpa = std.testing.allocator;
    var img = try alloc(gpa, 1, 3);
    defer img.deinit(gpa);
    @memcpy(img.pixels, &[_]u8{ 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 });
    img.flipVertical();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1 }, img.pixels);
}
