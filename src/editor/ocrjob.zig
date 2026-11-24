//! "Copy text" in the editor: OCR on a worker thread so the window stays responsive
//! (Tesseract takes a few hundred ms on a full screen). The editor flattens the image
//! on the main thread (so redactions are applied before recognition), starts the job,
//! polls `fd()`, and collects the text with `take()`.

const std = @import("std");
const c = @import("c");
const Image = @import("../image/Image.zig");
const ocr = @import("../ocr.zig");

pub const alloc = std.heap.c_allocator;

pub const OcrJob = struct {
    thread: std.Thread,
    img: Image,
    language: [:0]const u8,
    scale: f64,
    result: anyerror![]u8 = error.Pending,
    wake_r: c_int,
    wake_w: c_int,

    /// Takes ownership of `img` (allocated with `alloc`).
    pub fn start(img: Image, language: [:0]const u8, scale: f64) !*OcrJob {
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
        const job = try alloc.create(OcrJob);
        errdefer alloc.destroy(job);
        job.* = .{ .thread = undefined, .img = img, .language = language, .scale = scale, .wake_r = fds[0], .wake_w = fds[1] };
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        return job;
    }

    fn work(job: *OcrJob) void {
        job.result = ocr.recognize(alloc, job.img, job.language, job.scale);
        _ = c.write(job.wake_w, "x", 1);
    }

    pub fn fd(job: *const OcrJob) c_int {
        return job.wake_r;
    }

    /// The text (owned by `alloc`) once the worker has finished, else null.
    pub fn take(job: *OcrJob) ?(anyerror![]u8) {
        var b: [8]u8 = undefined;
        if (c.read(job.wake_r, &b, b.len) <= 0) return null;
        job.thread.join();
        const r = job.result;
        job.result = error.Taken;
        job.finish();
        return r;
    }

    /// Wait for the worker and free everything, discarding any result.
    pub fn cancel(job: *OcrJob) void {
        job.thread.join();
        if (job.result) |t| alloc.free(t) else |_| {}
        job.finish();
    }

    fn finish(job: *OcrJob) void {
        job.img.deinit(alloc);
        _ = c.close(job.wake_r);
        _ = c.close(job.wake_w);
        alloc.destroy(job);
    }
};
