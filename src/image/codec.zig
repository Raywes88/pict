//! Image formats: PNG (png.zig), JPEG (TurboJPEG) and WebP (libwebp).
//! `encode` picks the format; `decode` sniffs it from the magic bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const Image = @import("Image.zig");
const png = @import("png.zig");

pub const Format = enum {
    png,
    jpeg,
    webp,

    pub fn ext(f: Format) []const u8 {
        return switch (f) {
            .png => "png",
            .jpeg => "jpg",
            .webp => "webp",
        };
    }

    /// Format for a file name's extension (case-insensitive), or null if unknown.
    pub fn fromPath(path: []const u8) ?Format {
        const e = std.fs.path.extension(path);
        if (e.len < 2) return null;
        var buf: [8]u8 = undefined;
        if (e.len - 1 > buf.len) return null;
        const low = std.ascii.lowerString(&buf, e[1..]);
        if (std.mem.eql(u8, low, "png")) return .png;
        if (std.mem.eql(u8, low, "jpg") or std.mem.eql(u8, low, "jpeg")) return .jpeg;
        if (std.mem.eql(u8, low, "webp")) return .webp;
        return null;
    }

    /// "png", "jpg"/"jpeg" or "webp" (case-insensitive).
    pub fn fromName(name: []const u8) ?Format {
        if (name.len == 0 or name.len > 6) return null;
        var buf: [8]u8 = undefined;
        buf[0] = 'x';
        buf[1] = '.';
        @memcpy(buf[2..][0..name.len], name);
        return fromPath(buf[0 .. name.len + 2]);
    }
};

pub const default_jpeg_quality = 92;

/// `jpeg_quality` (1-100) applies to JPEG only; WebP is lossless.
pub fn encode(gpa: Allocator, img: Image, format: Format, jpeg_quality: u8) ![]u8 {
    return switch (format) {
        .png => png.encode(gpa, img),
        .jpeg => encodeJpeg(gpa, img, std.math.clamp(jpeg_quality, 1, 100)),
        .webp => encodeWebp(gpa, img),
    };
}

pub fn decode(gpa: Allocator, bytes: []const u8) !Image {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return png.decode(gpa, bytes);
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff")) return decodeJpeg(gpa, bytes);
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return decodeWebp(gpa, bytes);
    return error.UnknownImageFormat;
}

/// JPEG has no alpha: transparent pixels are composited over white. 4:4:4 keeps text
/// edges clean.
fn encodeJpeg(gpa: Allocator, img: Image, quality: c_int) ![]u8 {
    const h = c.tj3Init(c.TJINIT_COMPRESS) orelse return error.JpegInitFailed;
    defer c.tj3Destroy(h);
    _ = c.tj3Set(h, c.TJPARAM_QUALITY, quality);
    _ = c.tj3Set(h, c.TJPARAM_SUBSAMP, c.TJSAMP_444);

    var src = img.pixels;
    var flat: ?[]u8 = null;
    defer if (flat) |f| gpa.free(f);
    if (!img.is_opaque) {
        const f = try gpa.dupe(u8, img.pixels);
        flat = f;
        overWhite(f);
        src = f;
    }

    var out: [*c]u8 = null;
    var len: usize = 0;
    if (c.tj3Compress8(h, src.ptr, @intCast(img.width), @intCast(img.stride), @intCast(img.height), c.TJPF_BGRX, &out, &len) != 0) {
        std.log.err("jpeg: {s}", .{std.mem.span(c.tj3GetErrorStr(h))});
        if (out != null) c.tj3Free(out);
        return error.JpegEncodeFailed;
    }
    defer c.tj3Free(out);
    return gpa.dupe(u8, out[0..len]);
}

/// Premultiplied pixels over white: v + 255 − a.
fn overWhite(px: []u8) void {
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const a = px[i + 3];
        inline for (0..3) |k| px[i + k] = px[i + k] +| (255 - a);
        px[i + 3] = 255;
    }
}

fn decodeJpeg(gpa: Allocator, bytes: []const u8) !Image {
    const h = c.tj3Init(c.TJINIT_DECOMPRESS) orelse return error.JpegInitFailed;
    defer c.tj3Destroy(h);
    if (c.tj3DecompressHeader(h, bytes.ptr, bytes.len) != 0) return error.JpegDecodeFailed;
    const w = c.tj3Get(h, c.TJPARAM_JPEGWIDTH);
    const ht = c.tj3Get(h, c.TJPARAM_JPEGHEIGHT);
    if (w <= 0 or ht <= 0) return error.JpegDecodeFailed;
    var img = try Image.alloc(gpa, @intCast(w), @intCast(ht));
    errdefer img.deinit(gpa);
    if (c.tj3Decompress8(h, bytes.ptr, bytes.len, img.pixels.ptr, @intCast(img.stride), c.TJPF_BGRA) != 0) return error.JpegDecodeFailed;
    img.forceOpaque();
    return img;
}

/// Lossless: screenshots are mostly flat colour and text, where lossless WebP is
/// smaller than PNG and exact.
fn encodeWebp(gpa: Allocator, img: Image) ![]u8 {
    const straight = try gpa.dupe(u8, img.pixels);
    defer gpa.free(straight);
    if (!img.is_opaque) unpremultiply(straight);
    var out: [*c]u8 = null;
    const len = c.WebPEncodeLosslessBGRA(straight.ptr, @intCast(img.width), @intCast(img.height), @intCast(img.stride), &out);
    if (len == 0 or out == null) return error.WebpEncodeFailed;
    defer c.WebPFree(out);
    return gpa.dupe(u8, out[0..len]);
}

fn decodeWebp(gpa: Allocator, bytes: []const u8) !Image {
    var w: c_int = 0;
    var h: c_int = 0;
    const px = c.WebPDecodeBGRA(bytes.ptr, bytes.len, &w, &h) orelse return error.WebpDecodeFailed;
    defer c.WebPFree(px);
    var img = try Image.alloc(gpa, @intCast(w), @intCast(h));
    errdefer img.deinit(gpa);
    @memcpy(img.pixels, px[0..img.pixels.len]);
    img.is_opaque = premultiply(img.pixels);
    return img;
}

fn unpremultiply(px: []u8) void {
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        if (a == 255) continue;
        inline for (0..3) |k| px[i + k] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, px[i + k]) * 255 + a / 2) / a));
    }
}

/// Returns true when every pixel is opaque.
fn premultiply(px: []u8) bool {
    var all = true;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        if (a == 255) continue;
        all = false;
        inline for (0..3) |k| px[i + k] = @intCast((@as(u32, px[i + k]) * a + 127) / 255);
    }
    return all;
}

// ---- tests ----

const testing = std.testing;

fn gradient(gpa: Allocator) !Image {
    var img = try Image.alloc(gpa, 16, 8);
    for (0..8) |y| for (0..16) |x| {
        const p = img.pixels[y * img.stride + x * 4 ..][0..4];
        p.* = .{ @intCast(x * 16), @intCast(y * 32), 128, 255 };
    };
    img.is_opaque = true;
    return img;
}

test "format from path" {
    try testing.expectEqual(Format.jpeg, Format.fromPath("/a/b.JPEG").?);
    try testing.expectEqual(Format.webp, Format.fromPath("x.webp").?);
    try testing.expect(Format.fromPath("noext") == null);
}

test "webp round-trips losslessly" {
    const gpa = testing.allocator;
    var img = try gradient(gpa);
    defer img.deinit(gpa);
    const bytes = try encode(gpa, img, .webp, 92);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expect(back.is_opaque);
    try testing.expectEqualSlices(u8, img.pixels, back.pixels);
}

test "jpeg round-trips approximately" {
    const gpa = testing.allocator;
    var img = try gradient(gpa);
    defer img.deinit(gpa);
    const bytes = try encode(gpa, img, .jpeg, 92);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expectEqual(img.width, back.width);
    for (img.pixels, back.pixels) |a, b| try testing.expect(@abs(@as(i32, a) - @as(i32, b)) <= 12);
}
