//! Text recognition with Tesseract.
//!
//! libtesseract is loaded with dlopen the first time OCR runs, so ordinary snips don't
//! pay for loading it and pict still works without tesseract installed (OCR then says
//! what's missing). Screen text is small for Tesseract, so captures at scale < 1.5 are
//! upscaled 2× first, and light-on-dark images are inverted; both fixed misreads in
//! testing ("Wi-Fi", "$") for about 10 ms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const Image = @import("image/Image.zig");

const Handle = opaque {};

const Api = struct {
    create: *const fn () callconv(.c) ?*Handle,
    delete: *const fn (?*Handle) callconv(.c) void,
    init3: *const fn (?*Handle, ?[*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    set_variable: *const fn (?*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    set_image: *const fn (?*Handle, [*]const u8, c_int, c_int, c_int, c_int) callconv(.c) void,
    set_resolution: *const fn (?*Handle, c_int) callconv(.c) void,
    get_text: *const fn (?*Handle) callconv(.c) ?[*:0]u8,
    delete_text: *const fn (?[*:0]const u8) callconv(.c) void,
    end: *const fn (?*Handle) callconv(.c) void,
};

/// Loaded once. Not locked: pict runs at most one recognition at a time (the CLI on
/// the main thread, the editor on one worker).
var api_cache: ?Api = null;

fn loadApi() !Api {
    if (api_cache) |a| return a;
    const lib = c.dlopen("libtesseract.so.5", c.RTLD_NOW | c.RTLD_LOCAL) orelse
        c.dlopen("libtesseract.so", c.RTLD_NOW | c.RTLD_LOCAL) orelse return error.TesseractMissing;
    // Never dlclosed: tesseract keeps global state and thread pools alive.
    const a: Api = .{
        .create = try sym(lib, "TessBaseAPICreate", @FieldType(Api, "create")),
        .delete = try sym(lib, "TessBaseAPIDelete", @FieldType(Api, "delete")),
        .init3 = try sym(lib, "TessBaseAPIInit3", @FieldType(Api, "init3")),
        .set_variable = try sym(lib, "TessBaseAPISetVariable", @FieldType(Api, "set_variable")),
        .set_image = try sym(lib, "TessBaseAPISetImage", @FieldType(Api, "set_image")),
        .set_resolution = try sym(lib, "TessBaseAPISetSourceResolution", @FieldType(Api, "set_resolution")),
        .get_text = try sym(lib, "TessBaseAPIGetUTF8Text", @FieldType(Api, "get_text")),
        .delete_text = try sym(lib, "TessDeleteText", @FieldType(Api, "delete_text")),
        .end = try sym(lib, "TessBaseAPIEnd", @FieldType(Api, "end")),
    };
    api_cache = a;
    return a;
}

fn sym(lib: *anyopaque, name: [*:0]const u8, comptime T: type) !T {
    const p = c.dlsym(lib, name) orelse return error.TesseractMissing;
    return @ptrCast(p);
}

/// Recognise the text in `img`. `image_scale` is the capture's buffer px per logical px.
/// Returns UTF-8 text owned by `gpa`, trimmed; empty when nothing was found.
pub fn recognize(gpa: Allocator, img: Image, language: [:0]const u8, image_scale: f64) ![]u8 {
    const api = try loadApi();

    const k: u32 = if (image_scale < 1.5 and @as(u64, img.width) * img.height <= 8_000_000) 2 else 1;
    const gray = try grayscale(gpa, img, k);
    defer gpa.free(gray.px);

    const h = api.create() orelse return error.TesseractFailed;
    defer api.delete(h);
    _ = api.set_variable(h, "debug_file", "/dev/null");
    if (api.init3(h, null, language.ptr) != 0) return error.TesseractLanguageMissing;
    defer api.end(h);
    api.set_image(h, gray.px.ptr, @intCast(gray.w), @intCast(gray.h), 1, @intCast(gray.w));
    api.set_resolution(h, 300);
    const raw = api.get_text(h) orelse return error.TesseractFailed;
    defer api.delete_text(raw);
    return tidy(gpa, std.mem.span(raw));
}

const Gray = struct { px: []u8, w: u32, h: u32 };

/// Scale by k (Cairo's good filter), composite over white, convert to 8-bit luma, and
/// invert when the image is mostly dark so text ends up dark on light.
fn grayscale(gpa: Allocator, img: Image, k: u32) !Gray {
    const w = img.width * k;
    const h = img.height * k;
    var scaled: Image = img;
    var owned: ?Image = null;
    defer if (owned) |*o| o.deinit(gpa);
    if (k != 1) {
        var out = try Image.alloc(gpa, w, h);
        errdefer out.deinit(gpa);
        @memset(out.pixels, 0);
        const dst = c.cairo_image_surface_create_for_data(out.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(w), @intCast(h), @intCast(out.stride));
        defer c.cairo_surface_destroy(dst);
        const src = c.cairo_image_surface_create_for_data(img.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(img.width), @intCast(img.height), @intCast(img.stride));
        defer c.cairo_surface_destroy(src);
        const cr = c.cairo_create(dst) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        const kf: f64 = @floatFromInt(k);
        c.cairo_scale(cr, kf, kf);
        c.cairo_set_source_surface(cr, src, 0, 0);
        c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_GOOD);
        // Pad, so the edges don't fade to transparent (which would read as white).
        c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
        c.cairo_paint(cr);
        c.cairo_surface_flush(dst);
        owned = out;
        scaled = out;
    }

    const px = try gpa.alloc(u8, @as(usize, w) * h);
    errdefer gpa.free(px);
    var sum: u64 = 0;
    for (0..h) |y| {
        const row = scaled.pixels[y * scaled.stride ..];
        for (0..w) |x| {
            const p = row[x * 4 ..][0..4];
            const white: u32 = 255 - @as(u32, p[3]); // premultiplied: v + (255 − a) is "over white"
            const b: u32 = @min(255, @as(u32, p[0]) + white);
            const g: u32 = @min(255, @as(u32, p[1]) + white);
            const r: u32 = @min(255, @as(u32, p[2]) + white);
            const l: u8 = @intCast((r * 54 + g * 183 + b * 19) >> 8);
            px[y * w + x] = l;
            sum += l;
        }
    }
    if (px.len > 0 and sum / px.len < 128) {
        for (px) |*v| v.* = 255 - v.*;
    }
    return .{ .px = px, .w = w, .h = h };
}

/// Trim trailing spaces on each line, drop specks (see `isSpeck`), collapse runs of
/// blank lines to one, and trim the ends.
fn tidy(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var blank_run: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r\x0c");
        if (isSpeck(line)) continue;
        if (line.len == 0) {
            blank_run += 1;
            continue;
        }
        if (out.items.len > 0) {
            try out.append(gpa, '\n');
            if (blank_run > 0) try out.append(gpa, '\n');
        }
        blank_run = 0;
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// A short line of punctuation with at most one letter or digit, like ". s": what
/// Tesseract makes of borders, icons and rounded corners. A lone "5" or "A" stays.
fn isSpeck(line: []const u8) bool {
    var visible: usize = 0;
    var alnum: usize = 0;
    var other: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == ' ' or ch == '\t') continue;
        visible += 1;
        if (std.ascii.isAlphanumeric(ch)) {
            alnum += 1;
        } else if (ch >= 0x80) {
            // A multi-byte character: count it as a letter.
            alnum += 1;
            while (i + 1 < line.len and (line[i + 1] & 0xc0) == 0x80) i += 1;
        } else other += 1;
    }
    return visible <= 3 and alnum <= 1 and other >= 1;
}

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |ch| {
        if (ch == '\n') n += 1;
    }
    return n - std.mem.count(u8, text, "\n\n");
}

pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.TesseractMissing => "OCR needs tesseract: pacman -S tesseract tesseract-data-eng",
        error.TesseractLanguageMissing => "OCR language data missing (install tesseract-data-<lang>)",
        else => @errorName(err),
    };
}

test "tidy trims and collapses blank lines" {
    const gpa = std.testing.allocator;
    const t = try tidy(gpa, "  a  \n\n\n\nb \n. s\n5\n\u{00e9}\n\x0c\n");
    defer gpa.free(t);
    try std.testing.expectEqualStrings("  a\n\nb\n5\n\u{00e9}", t);
    try std.testing.expectEqual(@as(usize, 4), lineCount(t));
}

test "grayscale inverts dark images and upscales" {
    const gpa = std.testing.allocator;
    var img = try Image.alloc(gpa, 4, 4);
    defer img.deinit(gpa);
    for (0..16) |i| @memcpy(img.pixels[i * 4 ..][0..4], &[_]u8{ 20, 20, 20, 255 });
    const g = try grayscale(gpa, img, 2);
    defer gpa.free(g.px);
    try std.testing.expectEqual(@as(u32, 8), g.w);
    for (g.px) |v| try std.testing.expect(v > 220); // dark became light, edges included
}
