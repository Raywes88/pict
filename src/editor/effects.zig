//! Redaction effects on premultiplied ARGB32 images: box blur and pixelate.
//!
//! Both read the source image only and return a new image the size of the (clamped)
//! rect, which the renderer caches per annotation and paints at the object's place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("../image/Image.zig");
const Rect = @import("../geom.zig").Rect;

const V = @Vector(4, u32);

fn load(px: []const u8, i: usize) V {
    return .{ px[i], px[i + 1], px[i + 2], px[i + 3] };
}

fn store(px: []u8, i: usize, v: V) void {
    inline for (0..4) |k| px[i + k] = @intCast(v[k]);
}

/// Approximate Gaussian blur of `rect` with the given radius (three box passes per
/// axis). Only pixels inside the rect are used, edge-clamped, so the box blurs evenly
/// instead of fading toward whatever surrounds it.
pub fn blur(gpa: Allocator, src: Image, rect: Rect, radius: u32) !Image {
    const r = rect.clampTo(src.bounds());
    if (r.isEmpty()) return error.EmptySelection;
    const work = r;

    var a = try src.crop(gpa, work);
    defer a.deinit(gpa);
    var b = try Image.alloc(gpa, a.width, a.height);
    defer b.deinit(gpa);

    const rr: usize = @max(1, radius);
    for (0..3) |_| {
        boxH(a, b, rr);
        boxV(b, a, rr);
    }

    var out = try a.crop(gpa, .{ .x = r.x - work.x, .y = r.y - work.y, .w = r.w, .h = r.h });
    out.is_opaque = src.is_opaque;
    return out;
}

/// One horizontal box pass from `s` into `d` (same size), clamping at the edges.
fn boxH(s: Image, d: Image, r: usize) void {
    const w: usize = s.width;
    const win: u32 = @intCast(2 * r + 1);
    const half: V = @splat(win / 2);
    const winv: V = @splat(win);
    for (0..s.height) |y| {
        const in = s.pixels[y * s.stride ..];
        const out = d.pixels[y * d.stride ..];
        var sum: V = @splat(0);
        // Window centred on x = 0: indices -r..r, clamped.
        var k: isize = -@as(isize, @intCast(r));
        while (k <= @as(isize, @intCast(r))) : (k += 1) sum += load(in, clampIdx(k, w) * 4);
        for (0..w) |x| {
            store(out, x * 4, (sum + half) / winv);
            const add_i = clampIdx(@as(isize, @intCast(x + r + 1)), w);
            const sub_i = clampIdx(@as(isize, @intCast(x)) - @as(isize, @intCast(r)), w);
            sum += load(in, add_i * 4);
            sum -= load(in, sub_i * 4);
        }
    }
}

fn boxV(s: Image, d: Image, r: usize) void {
    const h: usize = s.height;
    const win: u32 = @intCast(2 * r + 1);
    const half: V = @splat(win / 2);
    const winv: V = @splat(win);
    for (0..s.width) |x| {
        var sum: V = @splat(0);
        var k: isize = -@as(isize, @intCast(r));
        while (k <= @as(isize, @intCast(r))) : (k += 1) sum += load(s.pixels, clampIdx(k, h) * s.stride + x * 4);
        for (0..h) |y| {
            store(d.pixels, y * d.stride + x * 4, (sum + half) / winv);
            const add_i = clampIdx(@as(isize, @intCast(y + r + 1)), h);
            const sub_i = clampIdx(@as(isize, @intCast(y)) - @as(isize, @intCast(r)), h);
            sum += load(s.pixels, add_i * s.stride + x * 4);
            sum -= load(s.pixels, sub_i * s.stride + x * 4);
        }
    }
}

fn clampIdx(i: isize, n: usize) usize {
    if (i < 0) return 0;
    const u: usize = @intCast(i);
    return @min(u, n - 1);
}

/// Replace `rect` with flat blocks of `block` px (grid aligned to the rect's corner),
/// each the average of the pixels it covers.
pub fn pixelate(gpa: Allocator, src: Image, rect: Rect, block: u32) !Image {
    const r = rect.clampTo(src.bounds());
    if (r.isEmpty()) return error.EmptySelection;
    var out = try src.crop(gpa, r);
    errdefer out.deinit(gpa);
    const bs: usize = @max(2, block);
    const w: usize = out.width;
    const h: usize = out.height;

    var by: usize = 0;
    while (by < h) : (by += bs) {
        const bh = @min(bs, h - by);
        var bx: usize = 0;
        while (bx < w) : (bx += bs) {
            const bw = @min(bs, w - bx);
            var sum: V = @splat(0);
            for (by..by + bh) |y| {
                for (bx..bx + bw) |x| sum += load(out.pixels, y * out.stride + x * 4);
            }
            const n: u32 = @intCast(bw * bh);
            const avg = (sum + @as(V, @splat(n / 2))) / @as(V, @splat(n));
            for (by..by + bh) |y| {
                for (bx..bx + bw) |x| store(out.pixels, y * out.stride + x * 4, avg);
            }
        }
    }
    return out;
}

// ---- tests ----

const testing = std.testing;

fn checker(gpa: Allocator, w: u32, h: u32) !Image {
    var img = try Image.alloc(gpa, w, h);
    for (0..h) |y| for (0..w) |x| {
        const v: u8 = if ((x + y) % 2 == 0) 255 else 0;
        @memset(img.pixels[y * img.stride + x * 4 ..][0..3], v);
        img.pixels[y * img.stride + x * 4 + 3] = 255;
    };
    img.is_opaque = true;
    return img;
}

test "blur flattens a checkerboard toward grey and keeps alpha" {
    const gpa = testing.allocator;
    var img = try checker(gpa, 32, 32);
    defer img.deinit(gpa);
    var b = try blur(gpa, img, .{ .x = 8, .y = 8, .w = 16, .h = 16 }, 3);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(u32, 16), b.width);
    for (0..16) |y| for (0..16) |x| {
        const p = b.pixels[y * b.stride + x * 4 ..][0..4];
        try testing.expect(p[0] > 100 and p[0] < 155);
        try testing.expectEqual(@as(u8, 255), p[3]);
    };
}

test "pixelate averages each block" {
    const gpa = testing.allocator;
    var img = try checker(gpa, 8, 8);
    defer img.deinit(gpa);
    var p = try pixelate(gpa, img, .{ .x = 0, .y = 0, .w = 8, .h = 8 }, 4);
    defer p.deinit(gpa);
    // Every 4×4 block of a checkerboard averages to mid grey.
    try testing.expectEqual(@as(u8, 128), p.pixels[0]);
    try testing.expectEqual(p.pixels[0], p.pixels[3 * p.stride + 3 * 4]);
}

test "effects clamp the rect to the image" {
    const gpa = testing.allocator;
    var img = try checker(gpa, 10, 10);
    defer img.deinit(gpa);
    var p = try pixelate(gpa, img, .{ .x = 6, .y = -4, .w = 10, .h = 8 }, 3);
    defer p.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), p.width);
    try testing.expectEqual(@as(u32, 4), p.height);
}
