//! Writing results to disk: directory, filename template, collisions.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");

/// Where and how captures are named; built from [output] in the config.
pub const Target = struct {
    /// Absolute directory (created if missing).
    dir: []const u8,
    /// strftime(3) template for the file name, without the extension.
    template: [:0]const u8 = "Screenshot_%Y-%m-%d_%H-%M-%S",
};

/// Save `bytes` as a new timestamped file in `t.dir`, never overwriting.
/// Returns the absolute path (owned by `gpa`).
pub fn saveNew(io: Io, gpa: Allocator, t: Target, bytes: []const u8, ext: []const u8) ![]u8 {
    try Io.Dir.cwd().createDirPath(io, t.dir);

    var stamp_buf: [256]u8 = undefined;
    const stamp = try fileStem(&stamp_buf, t.template);

    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const name = if (n == 0)
            try std.fmt.allocPrint(gpa, "{s}.{s}", .{ stamp, ext })
        else
            try std.fmt.allocPrint(gpa, "{s}-{d}.{s}", .{ stamp, n, ext });
        defer gpa.free(name);
        const full = try std.fs.path.join(gpa, &.{ t.dir, name });
        errdefer gpa.free(full);

        const file = Io.Dir.cwd().createFile(io, full, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(full);
                continue;
            },
            else => return err,
        };
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        return full;
    }
    return error.TooManyCollisions;
}

/// Save to an explicit path (overwrites). Returns the path as given (owned by `gpa`).
pub fn saveTo(io: Io, gpa: Allocator, path: []const u8, bytes: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    return gpa.dupe(u8, path);
}

/// The template expanded with the local time, with '/' replaced so a template can't
/// escape the directory. Falls back to "Screenshot" if it expands to nothing.
pub fn fileStem(buf: []u8, template: [:0]const u8) ![]const u8 {
    const s = formatNow(buf, template) catch |err| switch (err) {
        error.TemplateTooLong => if (template.len == 0) "" else return err,
        else => return err,
    };
    const out = buf[0..s.len];
    for (out) |*ch| if (ch.* == '/') {
        ch.* = '_';
    };
    if (std.mem.trim(u8, out, " .").len == 0) return "Screenshot";
    return out;
}

/// Expand a strftime template with the local time.
pub fn formatNow(buf: []u8, template: [:0]const u8) ![]const u8 {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&now, &tm) == null) return error.LocalTimeFailed;
    const n = c.strftime(buf.ptr, buf.len, template.ptr, &tm);
    if (n == 0) return error.TemplateTooLong;
    return buf[0..n];
}

test "formatNow expands a template" {
    var buf: [64]u8 = undefined;
    const s = try formatNow(&buf, "Screenshot_%Y");
    try std.testing.expect(std.mem.startsWith(u8, s, "Screenshot_2"));
    try std.testing.expectEqual(@as(usize, "Screenshot_".len + 4), s.len);
}

test "fileStem keeps names inside the directory" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a_b", try fileStem(&buf, "a/b"));
    try std.testing.expectEqualStrings("Screenshot", try fileStem(&buf, ""));
    try std.testing.expectEqualStrings("Screenshot", try fileStem(&buf, ".."));
}
