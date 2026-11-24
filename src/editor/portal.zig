//! "Save as" through xdg-desktop-portal's FileChooser (the desktop's own file dialog),
//! over sd-bus. The call returns at once; the answer arrives later as a Response
//! signal, so the editor polls `fd()` alongside Wayland until `state` leaves `.waiting`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const Format = @import("../image/codec.zig").Format;

pub const SaveDialog = struct {
    gpa: Allocator,
    bus: *c.sd_bus,
    slot: ?*c.sd_bus_slot = null,
    state: enum { waiting, chosen, cancelled, failed } = .waiting,
    /// Chosen path (owned), with an extension that matches the chosen filter.
    path: ?[]u8 = null,
    filter: Format = .png,

    const filters = [_]struct { name: [:0]const u8, fmt: Format, globs: []const [:0]const u8 }{
        .{ .name = "PNG image", .fmt = .png, .globs = &.{"*.png"} },
        .{ .name = "JPEG image", .fmt = .jpeg, .globs = &.{ "*.jpg", "*.jpeg" } },
        .{ .name = "WebP image", .fmt = .webp, .globs = &.{"*.webp"} },
    };

    /// Ask the portal for a save location. `name` is the suggested file name and
    /// `folder` the starting directory.
    pub fn start(gpa: Allocator, name: []const u8, folder: []const u8, initial: Format) !*SaveDialog {
        var bus: ?*c.sd_bus = null;
        if (c.sd_bus_open_user(&bus) < 0) return error.NoSessionBus;
        errdefer _ = c.sd_bus_flush_close_unref(bus);

        const d = try gpa.create(SaveDialog);
        errdefer gpa.destroy(d);
        d.* = .{ .gpa = gpa, .bus = bus.?, .filter = initial };

        // Subscribe to the Response before calling, on the path the portal will use.
        var unique: [*c]const u8 = null;
        if (c.sd_bus_get_unique_name(d.bus, &unique) < 0) return error.NoUniqueName;
        var sender_buf: [128]u8 = undefined;
        const sender = std.mem.span(unique);
        var sn: usize = 0;
        for (sender[1..]) |ch| {
            if (sn == sender_buf.len) return error.NameTooLong;
            sender_buf[sn] = if (ch == '.') '_' else ch;
            sn += 1;
        }
        var token_buf: [48]u8 = undefined;
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const token = try std.fmt.bufPrintSentinel(&token_buf, "pict_{d}_{d}", .{ std.c.getpid(), @as(u32, @truncate(@as(u64, @bitCast(@as(i64, ts.tv_nsec))))) }, 0);
        var path_buf: [256]u8 = undefined;
        const req_path = try std.fmt.bufPrintSentinel(&path_buf, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender_buf[0..sn], token }, 0);
        if (c.sd_bus_match_signal(d.bus, &d.slot, "org.freedesktop.portal.Desktop", req_path.ptr, "org.freedesktop.portal.Request", "Response", onResponse, d) < 0)
            return error.MatchFailed;
        errdefer _ = c.sd_bus_slot_unref(d.slot);

        var m: ?*c.sd_bus_message = null;
        if (c.sd_bus_message_new_method_call(d.bus, &m, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.FileChooser", "SaveFile") < 0)
            return error.CallFailed;
        defer _ = c.sd_bus_message_unref(m);

        const name_z = try gpa.dupeSentinel(u8, name, 0);
        defer gpa.free(name_z);
        try check(c.sd_bus_message_append_basic(m, 's', "")); // parent window
        try check(c.sd_bus_message_append_basic(m, 's', "Save screenshot"));
        try check(c.sd_bus_message_open_container(m, 'a', "{sv}"));
        try dictString(m, "handle_token", token);
        try dictString(m, "current_name", name_z);
        // current_folder is a NUL-terminated byte array.
        try check(c.sd_bus_message_open_container(m, 'e', "sv"));
        try check(c.sd_bus_message_append_basic(m, 's', "current_folder"));
        try check(c.sd_bus_message_open_container(m, 'v', "ay"));
        const folder_z = try gpa.dupeSentinel(u8, folder, 0);
        defer gpa.free(folder_z);
        try check(c.sd_bus_message_append_array(m, 'y', folder_z.ptr, folder_z.len + 1));
        try check(c.sd_bus_message_close_container(m));
        try check(c.sd_bus_message_close_container(m));
        // filters: a(sa(us))
        try check(c.sd_bus_message_open_container(m, 'e', "sv"));
        try check(c.sd_bus_message_append_basic(m, 's', "filters"));
        try check(c.sd_bus_message_open_container(m, 'v', "a(sa(us))"));
        try check(c.sd_bus_message_open_container(m, 'a', "(sa(us))"));
        for (filters) |f| try appendFilter(m, f.name, f.globs);
        try check(c.sd_bus_message_close_container(m));
        try check(c.sd_bus_message_close_container(m));
        try check(c.sd_bus_message_close_container(m));
        // current_filter: (sa(us))
        try check(c.sd_bus_message_open_container(m, 'e', "sv"));
        try check(c.sd_bus_message_append_basic(m, 's', "current_filter"));
        try check(c.sd_bus_message_open_container(m, 'v', "(sa(us))"));
        for (filters) |f| if (f.fmt == initial) try appendFilter(m, f.name, f.globs);
        try check(c.sd_bus_message_close_container(m));
        try check(c.sd_bus_message_close_container(m));
        try check(c.sd_bus_message_close_container(m)); // a{sv}

        var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        var reply: ?*c.sd_bus_message = null;
        if (c.sd_bus_call(d.bus, m, 10 * std.time.us_per_s, &err, &reply) < 0) {
            if (err.message != null) std.log.err("portal: {s}", .{std.mem.span(err.message)});
            return error.PortalUnavailable;
        }
        defer _ = c.sd_bus_message_unref(reply);
        return d;
    }

    pub fn deinit(d: *SaveDialog) void {
        if (d.path) |p| d.gpa.free(p);
        _ = c.sd_bus_slot_unref(d.slot);
        _ = c.sd_bus_flush_close_unref(d.bus);
        d.gpa.destroy(d);
    }

    pub fn fd(d: *const SaveDialog) c_int {
        return c.sd_bus_get_fd(d.bus);
    }

    pub fn events(d: *const SaveDialog) i16 {
        const e = c.sd_bus_get_events(d.bus);
        return if (e > 0) @intCast(e) else std.posix.POLL.IN;
    }

    /// Handle whatever arrived on the bus.
    pub fn process(d: *SaveDialog) void {
        while (d.state == .waiting) {
            const r = c.sd_bus_process(d.bus, null);
            if (r < 0) {
                d.state = .failed;
                return;
            }
            if (r == 0) return;
        }
    }

    fn onResponse(m: ?*c.sd_bus_message, userdata: ?*anyopaque, _: [*c]c.sd_bus_error) callconv(.c) c_int {
        const d: *SaveDialog = @ptrCast(@alignCast(userdata.?));
        d.parseResponse(m.?) catch {
            if (d.state == .waiting) d.state = .failed;
        };
        return 0;
    }

    fn parseResponse(d: *SaveDialog, m: *c.sd_bus_message) !void {
        var response: u32 = 2;
        try check(c.sd_bus_message_read_basic(m, 'u', &response));
        if (response != 0) {
            d.state = .cancelled;
            return;
        }
        var uri: ?[]const u8 = null;
        var filter_name: ?[]const u8 = null;
        try check(c.sd_bus_message_enter_container(m, 'a', "{sv}"));
        while (try checkN(c.sd_bus_message_enter_container(m, 'e', "sv")) > 0) {
            var key: [*c]const u8 = null;
            try check(c.sd_bus_message_read_basic(m, 's', @ptrCast(&key)));
            const k = std.mem.span(key);
            if (std.mem.eql(u8, k, "uris")) {
                try check(c.sd_bus_message_enter_container(m, 'v', "as"));
                try check(c.sd_bus_message_enter_container(m, 'a', "s"));
                var s: [*c]const u8 = null;
                if (try checkN(c.sd_bus_message_read_basic(m, 's', @ptrCast(&s))) > 0) uri = std.mem.span(s);
                try check(c.sd_bus_message_exit_container(m));
                try check(c.sd_bus_message_exit_container(m));
            } else if (std.mem.eql(u8, k, "current_filter")) {
                try check(c.sd_bus_message_enter_container(m, 'v', "(sa(us))"));
                try check(c.sd_bus_message_enter_container(m, 'r', "sa(us)"));
                var s: [*c]const u8 = null;
                try check(c.sd_bus_message_read_basic(m, 's', @ptrCast(&s)));
                filter_name = std.mem.span(s);
                try check(c.sd_bus_message_skip(m, "a(us)"));
                try check(c.sd_bus_message_exit_container(m));
                try check(c.sd_bus_message_exit_container(m));
            } else {
                try check(c.sd_bus_message_skip(m, "v"));
            }
            try check(c.sd_bus_message_exit_container(m));
        }
        try check(c.sd_bus_message_exit_container(m));

        if (filter_name) |fname| for (filters) |f| {
            if (std.mem.eql(u8, f.name, fname)) d.filter = f.fmt;
        };
        const u = uri orelse return error.NoUri;
        const path = try fileUriToPath(d.gpa, u);
        errdefer d.gpa.free(path);
        if (Format.fromPath(path) == null) {
            const with_ext = try std.fmt.allocPrint(d.gpa, "{s}.{s}", .{ path, d.filter.ext() });
            d.gpa.free(path);
            d.path = with_ext;
        } else {
            d.path = path;
            d.filter = Format.fromPath(path).?;
        }
        d.state = .chosen;
    }
};

fn check(r: c_int) !void {
    if (r < 0) return error.DbusError;
}

fn checkN(r: c_int) !c_int {
    if (r < 0) return error.DbusError;
    return r;
}

fn dictString(m: ?*c.sd_bus_message, key: [:0]const u8, value: [:0]const u8) !void {
    try check(c.sd_bus_message_open_container(m, 'e', "sv"));
    try check(c.sd_bus_message_append_basic(m, 's', key.ptr));
    try check(c.sd_bus_message_open_container(m, 'v', "s"));
    try check(c.sd_bus_message_append_basic(m, 's', value.ptr));
    try check(c.sd_bus_message_close_container(m));
    try check(c.sd_bus_message_close_container(m));
}

fn appendFilter(m: ?*c.sd_bus_message, name: [:0]const u8, globs: []const [:0]const u8) !void {
    try check(c.sd_bus_message_open_container(m, 'r', "sa(us)"));
    try check(c.sd_bus_message_append_basic(m, 's', name.ptr));
    try check(c.sd_bus_message_open_container(m, 'a', "(us)"));
    for (globs) |g| {
        try check(c.sd_bus_message_open_container(m, 'r', "us"));
        const zero: u32 = 0;
        try check(c.sd_bus_message_append_basic(m, 'u', &zero));
        try check(c.sd_bus_message_append_basic(m, 's', g.ptr));
        try check(c.sd_bus_message_close_container(m));
    }
    try check(c.sd_bus_message_close_container(m));
    try check(c.sd_bus_message_close_container(m));
}

/// "file:///a%20b/c.png" → "/a b/c.png" (owned).
pub fn fileUriToPath(gpa: Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.NotAFileUri;
    const rest = uri[prefix.len..];
    var out = try gpa.alloc(u8, rest.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                out[n] = rest[i];
                n += 1;
                continue;
            };
            out[n] = v;
            n += 1;
            i += 2;
        } else {
            out[n] = rest[i];
            n += 1;
        }
    }
    return gpa.realloc(out, n) catch out[0..n];
}

test "file URI to path" {
    const gpa = std.testing.allocator;
    const p = try fileUriToPath(gpa, "file:///home/w/My%20Shots/a%2Bb.png");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/home/w/My Shots/a+b.png", p);
}
