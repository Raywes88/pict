//! Keeps the clipboard in step with the editor, like the Windows Snipping Tool: after
//! each change settles (a short debounce), the edited image is flattened on the main
//! thread, PNG-encoded on a worker thread, and handed to a fresh clipboard owner
//! (clipboard.zig). The previous owner sees `cancelled` and exits.

const std = @import("std");
const posix = std.posix;
const c = @import("c");
const Image = @import("../image/Image.zig");
const png = @import("../image/png.zig");
const clipboard = @import("../clipboard.zig");

/// The worker allocates with libc malloc so it never shares an allocator with the UI.
pub const alloc = std.heap.c_allocator;
const debounce_ms = 250;

pub const AutoCopy = struct {
    enabled: bool,
    keep_stderr: bool,
    /// Document revision now on the clipboard.
    copied_rev: u64,
    deadline: ?i64 = null,
    thread: ?std.Thread = null,
    job: Job = undefined,
    wake_r: c_int,
    wake_w: c_int,

    const Job = struct { img: Image, rev: u64, bytes: ?[]u8 = null, wake: c_int };

    pub fn init(enabled: bool, copied_rev: u64, keep_stderr: bool) !AutoCopy {
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
        return .{ .enabled = enabled, .keep_stderr = keep_stderr, .copied_rev = copied_rev, .wake_r = fds[0], .wake_w = fds[1] };
    }

    pub fn deinit(ac: *AutoCopy) void {
        if (ac.thread) |t| {
            t.join();
            if (ac.job.bytes) |b| alloc.free(b);
        }
        _ = c.close(ac.wake_r);
        _ = c.close(ac.wake_w);
    }

    /// Note a document change at time `now` (monotonic ms).
    pub fn changed(ac: *AutoCopy, now: i64) void {
        if (ac.enabled) ac.deadline = now + debounce_ms;
    }

    /// Milliseconds until the next deadline, if one is set.
    pub fn timeout(ac: *const AutoCopy, now: i64) ?i64 {
        const d = ac.deadline orelse return null;
        return @max(0, d - now);
    }

    /// Fd to poll while a worker runs.
    pub fn fd(ac: *const AutoCopy) ?c_int {
        return if (ac.thread != null) ac.wake_r else null;
    }

    /// Drive the state machine. `busy` defers the copy while a gesture is in progress.
    /// `ctx.flatten()` returns the image to copy, allocated with `alloc`.
    pub fn poll(ac: *AutoCopy, now: i64, rev: u64, busy: bool, ctx: anytype) void {
        if (ac.thread != null) {
            var b: [8]u8 = undefined;
            if (c.read(ac.wake_r, &b, b.len) <= 0) return; // still encoding
            ac.finish();
            if (rev != ac.copied_rev and ac.deadline == null) ac.changed(now);
        }
        const d = ac.deadline orelse return;
        if (now < d or busy) return;
        ac.deadline = null;
        if (rev == ac.copied_rev) return;
        const img = ctx.flatten() catch |err| {
            std.log.warn("auto-copy: flatten failed ({t})", .{err});
            return;
        };
        ac.job = .{ .img = img, .rev = rev, .wake = ac.wake_w };
        ac.thread = std.Thread.spawn(.{}, work, .{&ac.job}) catch {
            // No thread: encode inline.
            work(&ac.job);
            ac.finishInline();
            return;
        };
    }

    /// Copy `rev` now, synchronously (Ctrl+C, and at exit for anything still pending).
    pub fn copyNow(ac: *AutoCopy, rev: u64, ctx: anytype) !void {
        if (ac.thread) |t| {
            t.join();
            ac.thread = null;
            if (ac.job.bytes) |b| alloc.free(b);
            ac.job.bytes = null;
        }
        ac.deadline = null;
        var img = try ctx.flatten();
        defer img.deinit(alloc);
        const bytes = try png.encode(alloc, img);
        defer alloc.free(bytes);
        try clipboard.copyPng(bytes, ac.keep_stderr);
        ac.copied_rev = rev;
    }

    /// At exit: make sure the clipboard holds the final edit.
    pub fn flush(ac: *AutoCopy, rev: u64, ctx: anytype) void {
        if (!ac.enabled) return;
        if (ac.thread) |t| {
            t.join();
            ac.thread = null;
            var b: [8]u8 = undefined;
            _ = c.read(ac.wake_r, &b, b.len);
            ac.deliver();
        }
        if (rev == ac.copied_rev) return;
        ac.copyNow(rev, ctx) catch |err| std.log.warn("clipboard: {t}", .{err});
    }

    fn finish(ac: *AutoCopy) void {
        ac.thread.?.join();
        ac.thread = null;
        ac.deliver();
    }

    fn finishInline(ac: *AutoCopy) void {
        var b: [8]u8 = undefined;
        _ = c.read(ac.wake_r, &b, b.len);
        ac.deliver();
    }

    fn deliver(ac: *AutoCopy) void {
        const bytes = ac.job.bytes orelse return;
        defer alloc.free(bytes);
        ac.job.bytes = null;
        clipboard.copyPng(bytes, ac.keep_stderr) catch |err| {
            std.log.warn("clipboard: {t}", .{err});
            return;
        };
        ac.copied_rev = ac.job.rev;
    }

    fn work(job: *Job) void {
        job.bytes = png.encode(alloc, job.img) catch null;
        job.img.deinit(alloc);
        _ = c.write(job.wake, "x", 1);
    }
};
