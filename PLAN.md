# pict — plan

A fast, native Wayland clone of the Windows Snipping Tool, written in Zig, for niri on CachyOS.
Feature parity minus the bloat: no cloud, no telemetry, no accounts, no AI.

Binary: `pict`. Config: `~/.config/pict/config.toml` (Phase 4).

## Target environment (verified on kotov, 2026-11-24)

- Zig **0.17.1**. `@cImport` is gone, so C headers go through `b.addTranslateC`. `main` takes
  `std.process.Init`, and I/O goes through `std.Io`.
- niri **26.04**, 2× 2560×1440 at scale 1.0, RTX 2080 on the proprietary driver.
- Globals niri 26.04 advertises that pict uses: `zwlr_screencopy_manager_v1` v3,
  `zwlr_layer_shell_v1` v5, `ext_data_control_manager_v1` v1, `zwlr_data_control_manager_v1` v2,
  `wp_fractional_scale_manager_v1`, `wp_viewporter`, `wp_cursor_shape_manager_v1` v2,
  `zxdg_output_manager_v1` v3, `xdg_wm_base` v7.
- **Not advertised by 26.04:** `ext_image_copy_capture_manager_v1` (on niri master after 26.04,
  output sources only, no toplevel source) and `wp_single_pixel_buffer_manager_v1`.
- **niri IPC gap:** on 26.04, `layout.tile_pos_in_workspace_view` is `null` for tiled windows. Only
  floating windows get a position. niri master fills it for visible tiled tiles.

## Stack

- **zig-wayland v0.7.0** (Zig 0.17) generates the protocol bindings at build time and links
  libwayland-client. The wlr XMLs are vendored in `protocol/` because Arch doesn't package them.
- **wl_shm and Cairo, no GPU API.** Pixels have to be in CPU memory anyway (PNG, clipboard, OCR),
  shm screencopy is the reliable path on NVIDIA, and there's no EGL driver load on every launch.
  Heavy compositing goes to niri: the frozen frame is uploaded once, and the dim and selection
  border are subsurfaces made of a 1×1 shm buffer stretched by `wp_viewporter`.
- **Codecs:** libpng (fast compression level), TurboJPEG, libwebp.
- **Input:** xkbcommon for the keyboard and `wp_cursor_shape` for cursors.
- **Clipboard:** after encoding, pict forks a detached child that owns the selection through
  `ext_data_control_v1` (falling back to `zwlr_data_control_v1`, then `wl-copy`). The child exits
  on `cancelled`, so there's no daemon.
- **Fractional scaling:** each output's frozen frame is native pixels with viewporter destination
  set to the logical size, so pixels map 1:1 at any scale. Selection edges snap to physical
  pixels. The editor uses `wp_fractional_scale_v1`, a logical × scale buffer and a viewporter.

## Layout

```
build.zig / build.zig.zon     scanner, translate-c module, exe, tests
protocol/                     vendored wlr XMLs
src/main.zig                  entry, mode dispatch, sinks, --timings
src/cli.zig                   flags → Options
src/c.h                       translate-c: cairo, png, xkbcommon, libc (+ jpeg, webp later)
src/geom.zig                  Rect math
src/wl/Client.zig, shm.zig    registry, outputs (wl_output + xdg_output), seat; memfd buffers
src/capture/screencopy.zig    parallel per-output capture (image_copy.zig in Phase 2)
src/image/                    Image (ARGB32), png.zig (+ jpeg, webp)
src/overlay/                  Overlay.zig (layer surfaces, render, input), selection.zig (pure)
src/clipboard.zig             re-exec'd data-control owner, wl-copy fallback
src/niri.zig                  $NIRI_SOCKET JSON IPC
src/save.zig                  default dir, strftime template, collision-safe names
src/editor/                   Phase 3: Editor, doc, render, effects, toolbar, icons, autocopy, portal
src/image/codec.zig           JPEG and WebP, format sniffing
```

Data flow: `capture` returns `[]Frame`, `overlay` returns a `Selection` in physical px,
`Image.crop` produces the result, and the result goes to the sinks. OCR is a new sink. Recording is
a capture session that yields N frames.

## Phases

### Phase 1 — CLI, capture, freeze-frame region, PNG and clipboard

1. Scaffold: build files, bindings pinned to the versions niri advertises, translate-c, tests.
2. Wayland core: version-negotiated globals, outputs (name, logical rect, scale, transform), seat
   with xkb, cursor shape.
3. Capture: screencopy every output in parallel, handle `y_invert`, `--cursor`/`--no-cursor`,
   normalize the pixel format.
4. Sinks: PNG to `~/Pictures/Screenshots/Screenshot_%Y-%m-%d_%H-%M-%S.png` (or `-o PATH`), print
   the path, forked clipboard owner, `--copy-only`. **Milestone:** `--fullscreen` (focused output
   via niri IPC) works end-to-end.
5. Overlay: layer surface per output (overlay layer, all anchors, exclusive keyboard). Frozen
   frame, dimming outside the selection, crosshair, W×H label. Mouse release confirms, Esc
   cancels, arrows nudge, Shift+arrows resize. A selection stays on the output it started on.
6. `--timings`, unit tests, and a manual matrix: 1.5 scale via `niri msg output DP-3 scale 1.5`,
   pixel comparison against `grim -g`, paste after the process exits.

Done when `Mod+Shift+S { spawn "pict" "--region"; }` works.

**Status (2026-11-24):** steps 1–5 are built.
- Verified on kotov (ReleaseFast): `--fullscreen` capture of a 2560×1440 output takes 13 ms
  and the PNG encode about 100 ms. The overlay is visible about 50 ms after launch.
- The overlay was driven by `PICT_TEST_AUTOSELECT` (no protocol errors). Its crop matches
  `grim -g` pixel-for-pixel apart from live content.
- The clipboard persists after exit, and its owner exits on `cancelled`.
- `--delay` is built early.
- Interactive test by Wes: the overlay appears instantly with no niri animation or shadow, the
  crosshair shows, and pasting works. The label was enlarged from 12 to 14 px.
- Still open: fractional scale (1.5) on a real output.

### Phase 2

- niri IPC client.
- Window mode: hover-snap uses `tile_pos_in_workspace_view` when niri provides it. Floating
  windows work on 26.04. Tiled windows fall back to the focused window via
  `screenshot-window --id` until niri's next release, then work with no code change.
- Freeform lasso with alpha outside, `--delay`.
- Cross-output selections with mixed scales; output transforms.
- `ext-image-copy-capture` backend, auto-selected when advertised.

**Status (2026-11-24):**
- **Canvas (`layout.zig`):** one pixel grid across every output, at the highest output scale.
  Each output's origin is rounded to a whole pixel, so outputs at the canvas scale stay exact
  and lower-scale outputs are upscaled.
- **Exact scales:** the overlay uses `wp_fractional_scale_v1`'s exact scale instead of pw/lw,
  because niri rounds 2560/1.5 up to 1707.
- **Done and verified with the test hook:**
  - A region spanning DP-2 and DP-3 matches `grim -g` exactly.
  - A mixed-scale run (DP-3 at 1.5) gives a 600×450 result. The 1.5 part is exact, and the
    1.0 part is upscaled with a mean error of 0.01% against grim.
  - The lasso produces an RGBA PNG that is transparent outside the shape.
  - `--fullscreen --all` gives one 5120×1440 image.
  - Window mode works through IPC. On 26.04 it falls back to niri's `ScreenshotWindow`
    writing to `$XDG_RUNTIME_DIR`, and pict then loads that file.
- **Not yet tested by hand:**
  - Hover-snap on a floating window (none were open).
  - Drawing a lasso by hand.
- **Deferred:**
  - `ext-image-copy-capture`: niri 26.04 doesn't offer it, so there is nothing here to test
    against.
- **Output transforms (rotated monitors):** done. niri's screencopy returns frames in hardware
  orientation, so pict makes them upright at capture time. 90, 270 and flipped-90 on DP-3
  match `grim` exactly. The other flipped variants use the same formulas but weren't tested.

### Phase 3

Editor: xdg_toplevel with a Cairo canvas.

- Annotations stay vector until export. Undo/redo only flips visibility or swaps a crop rect,
  so there are no pixel snapshots.
- Tools: pen, highlighter, eraser (removes whole objects), line, arrow, rectangle, ellipse, text,
  blur and pixelate.
- Non-destructive crop, color picker, zoom and pan (only the visible region is rendered).
- `--edit`. Save As via the xdg-desktop-portal FileChooser.

**Decisions (Wes, 2026-11-24):** open floating with the fixed-size trick (no niri rule), Pango
for text, re-copy to the clipboard after every edit (like Windows), Save As through the desktop's
standard dialog.

**Status (2026-11-24):** built and verified with `PICT_TEST_EDITOR` scripts on kotov.
- **Modules:** `editor/doc.zig` (objects, crop, undo; pure, tested), `effects.zig` (box blur,
  pixelate), `render.zig` (Cairo + Pango, shared by the view and export), `toolbar.zig` +
  `icons.zig`, `autocopy.zig`, `portal.zig` (sd-bus FileChooser), `Editor.zig` (window, loop,
  input). `image/codec.zig` adds JPEG (TurboJPEG, 4:4:4) and lossless WebP, encode and decode.
- **Rendering:** the base image and committed annotations go into a scene cache keyed on
  (doc revision, zoom, pan, size, crop mode). Each frame copies the scene, repaints the toolbar,
  and draws the live layer (stroke in progress, crop frame, brush ring, tooltip, toast). Damage
  covers the toolbar only when it changed plus the live layer's old and new bounds.
- **Floating:** niri floats windows whose min and max height match on the first commit. pict
  sets both to its preferred size, then clears them after the first frame. Verified: niri
  reports `is_floating: true` and the window resizes freely afterwards.
- **Auto-copy:** a change schedules a copy 250 ms later (deferred while a stroke or text box is
  open). The image is flattened on the main thread and PNG-encoded on a worker thread, then
  handed to a new `__serve-clipboard` process; the old one exits on `cancelled`. Pending changes
  are flushed at exit. Verified: the clipboard held the mid-edit state during the session and
  matched the final saved file exactly after closing. Each copy is a new cliphist entry.
- **Blur:** edge-clamped inside the box (sampling outside made the box fade at its edges).
  Blur and pixelate read the base image, not annotations under them.
- **Verified:** shapes, smoothed pen, multiply highlighter, text add and re-edit, eraser hover
  and erase, undo/redo, crop handles, 200% zoom with nearest-neighbour pixels, the colour
  popover, tooltips, the unsaved-changes close confirmation, and the portal dialog (Nautilus
  opens floating; closing it returns `cancelled`). At scale 1.5 a 1300×600 window renders a
  1950×900 buffer and 100% is exact. Launch to first frame to exit takes under 100 ms
  (ReleaseFast).
- **Not yet tested by hand:** real mouse drawing feel, key repeat, choosing a file in the Save
  As dialog, and pasting an edited snip into another app.

### Phase 4

TOML config (the subset pict uses), `--print-niri-binds`, JPG/WebP defaults, filename templates,
OCR via the tesseract C API.
