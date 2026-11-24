//! Writing results to disk: default directory, filename template, collisions.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");

pub const default_subdir = "Pictures/Screenshots";
/// strftime(3) template. Configurable in Phase 4.
pub const default_template = "Screenshot_%Y-%m-%d_%H-%M-%S";

/// Save `bytes` under ~/Pictures/Screenshots with a timestamped name, never overwriting.
/// Returns the absolute path (owned by `gpa`).
pub fn saveDefault(io: Io, gpa: Allocator, home: []const u8, bytes: []const u8, ext: []const u8) ![]u8 {
    const dir_path = try std.fs.path.join(gpa, &.{ home, default_subdir });
    defer gpa.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);

    var stamp_buf: [128]u8 = undefined;
    const stamp = try formatNow(&stamp_buf, default_template);

    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const name = if (n == 0)
            try std.fmt.allocPrint(gpa, "{s}.{s}", .{ stamp, ext })
        else
            try std.fmt.allocPrint(gpa, "{s}-{d}.{s}", .{ stamp, n, ext });
        defer gpa.free(name);
        const full = try std.fs.path.join(gpa, &.{ dir_path, name });
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
