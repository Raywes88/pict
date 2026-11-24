//! Desktop notifications over D-Bus (org.freedesktop.Notifications), via sd-bus, which
//! the editor already links for the file dialog. Best effort: failures are ignored.

const std = @import("std");
const c = @import("c");

pub fn send(summary: []const u8, body: []const u8) void {
    var bus: ?*c.sd_bus = null;
    if (c.sd_bus_open_user(&bus) < 0) return;
    defer _ = c.sd_bus_flush_close_unref(bus);

    var sbuf: [256]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    const s = zstr(&sbuf, summary);
    const b = zstr(&bbuf, body);

    var m: ?*c.sd_bus_message = null;
    if (c.sd_bus_message_new_method_call(bus, &m, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify") < 0) return;
    defer _ = c.sd_bus_message_unref(m);
    const replaces: u32 = 0;
    const timeout: i32 = 4000;
    if (c.sd_bus_message_append_basic(m, 's', "pict") < 0) return;
    if (c.sd_bus_message_append_basic(m, 'u', &replaces) < 0) return;
    if (c.sd_bus_message_append_basic(m, 's', "edit-paste") < 0) return;
    if (c.sd_bus_message_append_basic(m, 's', s.ptr) < 0) return;
    if (c.sd_bus_message_append_basic(m, 's', b.ptr) < 0) return;
    if (c.sd_bus_message_open_container(m, 'a', "s") < 0) return;
    if (c.sd_bus_message_close_container(m) < 0) return;
    if (c.sd_bus_message_open_container(m, 'a', "{sv}") < 0) return;
    if (c.sd_bus_message_close_container(m) < 0) return;
    if (c.sd_bus_message_append_basic(m, 'i', &timeout) < 0) return;

    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    if (c.sd_bus_call(bus, m, 2 * std.time.us_per_s, &err, &reply) >= 0) _ = c.sd_bus_message_unref(reply);
}

/// Copy into `buf` with a NUL, truncating at a UTF-8 boundary.
fn zstr(buf: []u8, s: []const u8) [:0]const u8 {
    var n = @min(s.len, buf.len - 1);
    while (n > 0 and n < s.len and (s[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

test "zstr truncates on a UTF-8 boundary" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("ab", zstr(&buf, "ab\u{00e9}z"));
}
