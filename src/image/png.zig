//! PNG encoding through libpng's simplified API (no setjmp/longjmp needed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const Image = @import("Image.zig");

/// Encode to an owned PNG byte slice. Opaque images are written as RGB.
pub fn encode(gpa: Allocator, img: Image) ![]u8 {
    var tmp: ?[]u8 = null;
    defer if (tmp) |t| gpa.free(t);

    var png: c.png_image = std.mem.zeroes(c.png_image);
    png.version = c.PNG_IMAGE_VERSION;
    png.width = img.width;
    png.height = img.height;
    png.flags = c.PNG_IMAGE_FLAG_FAST; // ~40% faster for ~5% bigger files

    var src: []const u8 = undefined;
    var row_stride: i32 = undefined;
    const w: usize = img.width;
    const h: usize = img.height;

    if (img.is_opaque) {
        // Pack BGRX → BGR so the file has no alpha channel.
        png.format = c.PNG_FORMAT_BGR;
        const packed_rows = try gpa.alloc(u8, w * h * 3);
        tmp = packed_rows;
        for (0..h) |y| {
            const in = img.pixels[y * img.stride ..][0 .. w * 4];
            const out = packed_rows[y * w * 3 ..][0 .. w * 3];
            for (0..w) |x| {
                out[x * 3 + 0] = in[x * 4 + 0];
                out[x * 3 + 1] = in[x * 4 + 1];
                out[x * 3 + 2] = in[x * 4 + 2];
            }
        }
        src = packed_rows;
        row_stride = @intCast(w * 3);
    } else {
        // libpng's 8-bit simplified API expects straight (non-premultiplied) alpha.
        png.format = c.PNG_FORMAT_BGRA;
        const straight = try gpa.alloc(u8, w * h * 4);
        tmp = straight;
        for (0..h) |y| {
            const in = img.pixels[y * img.stride ..][0 .. w * 4];
            const out = straight[y * w * 4 ..][0 .. w * 4];
            for (0..w) |x| {
                const a: u32 = in[x * 4 + 3];
                out[x * 4 + 3] = @intCast(a);
                inline for (0..3) |k| {
                    const v: u32 = in[x * 4 + k];
                    out[x * 4 + k] = if (a == 0) 0 else @intCast(@min(255, (v * 255 + a / 2) / a));
                }
            }
        }
        src = straight;
        row_stride = @intCast(w * 4);
    }

    // Generous upper bound: raw size + 2% + slack. Retry once with libpng's figure if short.
    var cap: usize = src.len + src.len / 50 + 64 * 1024;
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const out = try gpa.alloc(u8, cap);
        var len: c.png_alloc_size_t = cap;
        const ok = c.png_image_write_to_memory(&png, out.ptr, &len, 0, src.ptr, row_stride, null);
        if (ok != 0) {
            return gpa.realloc(out, len) catch out[0..len];
        }
        gpa.free(out);
        if (len == cap or len == 0) {
            const msg: [*:0]const u8 = @ptrCast(&png.message);
            std.log.err("libpng: {s}", .{std.mem.span(msg)});
            return error.PngEncodeFailed;
        }
        cap = len; // buffer was too small; libpng reported the size it needs
        c.png_image_free(&png);
        png.@"opaque" = null;
    }
    return error.PngEncodeFailed;
}

/// Decode PNG bytes into a premultiplied ARGB32 image.
pub fn decode(gpa: Allocator, bytes: []const u8) !Image {
    var png: c.png_image = std.mem.zeroes(c.png_image);
    png.version = c.PNG_IMAGE_VERSION;
    if (c.png_image_begin_read_from_memory(&png, bytes.ptr, bytes.len) == 0) return error.PngDecodeFailed;
    defer c.png_image_free(&png);
    png.format = c.PNG_FORMAT_BGRA;

    var img = try Image.alloc(gpa, png.width, png.height);
    errdefer img.deinit(gpa);
    if (c.png_image_finish_read(&png, null, img.pixels.ptr, @intCast(img.stride), null) == 0) return error.PngDecodeFailed;

    // libpng gives straight alpha; cairo and wl_shm want premultiplied.
    var all_opaque = true;
    var i: usize = 0;
    while (i < img.pixels.len) : (i += 4) {
        const a: u32 = img.pixels[i + 3];
        if (a == 255) continue;
        all_opaque = false;
        inline for (0..3) |k| img.pixels[i + k] = @intCast((@as(u32, img.pixels[i + k]) * a + 127) / 255);
    }
    img.is_opaque = all_opaque;
    return img;
}

test "decode round-trips encode" {
    const gpa = std.testing.allocator;
    var img = try Image.alloc(gpa, 5, 3);
    defer img.deinit(gpa);
    for (img.pixels, 0..) |*p, i| p.* = @intCast((i * 37) & 0xff);
    img.forceOpaque();
    const bytes = try encode(gpa, img);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try std.testing.expect(back.is_opaque);
    try std.testing.expectEqualSlices(u8, img.pixels, back.pixels);
}

test "encode produces a PNG signature" {
    const gpa = std.testing.allocator;
    var img = try Image.alloc(gpa, 3, 2);
    defer img.deinit(gpa);
    @memset(img.pixels, 0x80);
    img.forceOpaque();
    const bytes = try encode(gpa, img);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bytes[0..8]);
}
