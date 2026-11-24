# pict

a clone of windows snip tool written (vibe-coded) in zig for my wayland+niri desktop

It's fast and native: raw Wayland, wl_shm and Cairo, with no toolkit and no GPU API. See
[PLAN.md](PLAN.md) for the architecture and roadmap.

**Status:** Phase 3. Region, freeform and window capture, monitor-spanning selections, and an
annotation editor that opens after each capture. Config file and OCR are Phase 4.

## Build

Requires Zig 0.17.1 plus `wayland`, `wayland-protocols`, `cairo`, `pango`, `libpng`,
`libjpeg-turbo`, `libwebp`, `libxkbcommon` and `systemd-libs` (sd-bus, for the Save As dialog).
All are standard on CachyOS/Arch.

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.local   # installs ~/.local/bin/pict
zig build test                                      # unit tests
```

## Use

```sh
pict                       # region: drag on a frozen screen, save + copy, open the editor
pict --no-edit             # same, without the editor
pict --edit shot.png       # open an existing PNG, JPEG or WebP in the editor
pict --freeform            # lasso; outside the shape is transparent
pict --window              # hover a window, click to capture it
pict --fullscreen          # focused output (asked from niri over $NIRI_SOCKET)
pict --fullscreen --all    # every output in one image
pict --copy-only           # clipboard only: no file, no editor
pict --delay 5 --cursor    # wait 5 s, include the pointer
pict -o - | some-tool      # PNG on stdout
```

Files go to `~/Pictures/Screenshots/Screenshot_%Y-%m-%d_%H-%M-%S.png`, and the path is printed
on stdout. Esc or right-click cancels (exit status 1). `--adjust` keeps the selection open after
release: arrows move it, Shift+arrows resize it, Enter confirms. Selections can span monitors,
including ones at different scales (the result uses the highest scale).

**Window mode on niri 26.04:** niri only reports positions for floating windows. Those
hover-snap. Anywhere else, clicking captures the focused window through niri's own window
screenshot. niri puts that image on the clipboard too, even with `--no-copy`. Newer niri
reports tiled window positions as well, and pict uses them automatically.

### The editor

After a capture, the snip is saved and copied first, then the editor opens as a floating window.
Every change is re-copied to the clipboard about a quarter of a second after it settles, like the
Windows Snipping Tool, so you can annotate and paste without pressing anything. (If you run a
clipboard history such as cliphist, each re-copy is a new entry.)

| Key | Tool | Key | Action |
|---|---|---|---|
| `P` | Pen (Shift: straight) | `1`–`8` | Palette colour |
| `H` | Highlighter (multiplies, so text stays readable) | `[` `]` | Thinner / thicker |
| `E` | Eraser (removes whole marks) | `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / redo |
| `L` / `A` | Line / arrow (Shift: 45°) | `Ctrl+C` | Copy now |
| `R` / `O` | Rectangle / ellipse (Shift: square, circle) | `Ctrl+S` | Save (overwrites the snip's file) |
| `T` | Text (click a text to edit it; Esc finishes) | `Ctrl+Shift+S` | Save as (desktop file dialog; PNG, JPEG, WebP) |
| `B` / `X` | Blur / pixelate box | `Ctrl+scroll`, `Ctrl+=`/`-` | Zoom |
| `C` | Crop (drag handles; Enter applies, Esc cancels) | `Ctrl+0` / `Ctrl+1` | Fit / 100% |
| `I` | Pick a colour from the image | scroll, middle-drag, `Space`+drag | Pan |

The rainbow swatch opens a colour picker. Esc closes the editor; with unsaved changes it asks
you to close a second time. Annotations stay editable shapes until export, so undo is
unlimited and crop never loses pixels. Blur and pixelate hide content visually; for anything
truly sensitive, pixelate with a large size or cover it with a filled box, because light blur
can sometimes be reversed.

### niri binds

```kdl
binds {
    Mod+Shift+S { spawn "pict" "--region"; }
    Print       { spawn "pict" "--fullscreen"; }
    Mod+Print   { spawn "pict" "--region" "--copy-only"; }
    Mod+Shift+W { spawn "pict" "--window"; }
    Mod+Shift+F { spawn "pict" "--freeform"; }
}
```

## How the clipboard survives exit

Wayland clipboard contents are served by their owner, so pict forks a small background copy of
itself (`pict __serve-clipboard`). It owns the selection through `ext-data-control-v1` (or
`wlr-data-control`) and exits as soon as another app takes the clipboard. Without either
protocol it falls back to `wl-copy`. Set `PICT_DEBUG=1` to keep that process's stderr.

## Testing hooks

`--timings` prints per-stage latency.

`PICT_TEST_AUTOSELECT="DP-3:200,200,800,500"` (physical pixels on that output) drives the
overlay without input. It maps the overlay, drags in two steps and confirms. Use it for smoke
tests, then compare with `grim -g`.

`PICT_TEST_EDITOR="tool rect; drag 20 20 200 120; key ctrl+z; dump /tmp/ui.png; save /tmp/out.png; quit"`
scripts the editor one frame at a time (image-pixel coordinates). The full command list is at
the bottom of `src/editor/Editor.zig`. `dump` writes the window as rendered, for checking the UI.

## License

GPL-3.0. See [LICENSE](LICENSE).
