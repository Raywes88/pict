const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Wayland protocol bindings (generated at build time) ----
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml"); // required by cursor-shape
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-data-control-unstable-v1.xml"));

    // Max versions pict implements. Bound at min(this, what the compositor advertises).
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zxdg_output_manager_v1", 3);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.generate("zwlr_data_control_manager_v1", 2);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    // ---- C libraries (Zig 0.17 has no @cImport) ----
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_libs = [_][]const u8{ "cairo", "libpng", "xkbcommon" };
    for (c_libs) |lib| translate_c.linkSystemLibrary(lib, .{});
    const c_mod = translate_c.createModule();

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "c", .module = c_mod },
        },
    });
    root_mod.linkSystemLibrary("wayland-client", .{});
    for (c_libs) |lib| root_mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "pict", .root_module = root_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run pict").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
