# pict

a clone of windows snip tool written (vibe-coded) in zig for my wayland+niri desktop

It's fast and native: raw Wayland, wl_shm and Cairo, with no toolkit and no GPU API. See
[PLAN.md](PLAN.md) for the architecture and roadmap.

**Status:** 1.0.0. Region, freeform, window and fullscreen capture, monitor-spanning
selections, an annotation editor that opens after each capture, a config file, a niri binds
generator, and copying text out of a snip (OCR). Screen recording is planned in
[RECORDING.md](RECORDING.md).

## Build

Requires Zig 0.17.1 plus `wayland`, `wayland-protocols`, `cairo`, `pango`, `libpng`,
`libjpeg-turbo`, `libwebp`, `libxkbcommon` and `systemd-libs` (sd-bus, for the Save As dialog
and notifications). All are standard on CachyOS/Arch.

OCR is optional: install `tesseract` and `tesseract-data-eng` (or other languages). pict loads
libtesseract only when you copy text, so it builds and runs without it.

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
pict --ocr                 # select an area, copy its text (notification shows what was copied)
pict --format jpg          # save as JPEG (png, jpg or webp; the clipboard always gets PNG)
pict --delay 5 --cursor    # wait 5 s, include the pointer
pict -o - | some-tool      # PNG on stdout
```

Files go to `~/Pictures/Screenshots/Screenshot_%Y-%m-%d_%H-%M-%S.png` by default (see
[Config](#config)), and the path is printed on stdout. Esc or right-click cancels (exit status 1). `--adjust` keeps the selection open after
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
| | | `Ctrl+Shift+C` | Copy text (OCR) |
| `R` / `O` | Rectangle / ellipse (Shift: square, circle) | `Ctrl+S` | Save (overwrites the snip's file) |
| `T` | Text (click a text to edit it; Esc finishes) | `Ctrl+Shift+S` | Save as (desktop file dialog; PNG, JPEG, WebP) |
| `B` / `X` | Blur / pixelate box | `Ctrl+scroll`, `Ctrl+=`/`-` | Zoom |
| `C` | Crop (drag handles; Enter applies, Esc cancels) | `Ctrl+0` / `Ctrl+1` | Fit / 100% |
| `I` | Pick a colour from the image | scroll, middle-drag, `Space`+drag | Pan |

The rainbow swatch opens a colour picker. **Copy text** (the scan-corners button) reads the
text in the edited image, with blur and pixelate applied first, so redacted text isn't copied.
The text replaces the image on the clipboard until your next edit. Esc closes the editor; with unsaved changes it asks
you to close a second time. Annotations stay editable shapes until export, so undo is
unlimited and crop never loses pixels. Blur and pixelate hide content visually; for anything
truly sensitive, pixelate with a large size or cover it with a filled box, because light blur
can sometimes be reversed.

### niri binds

`pict --print-niri-binds` prints a `binds {}` block for every mode. It reads your niri config
and skips key combos that are already taken (falling back to a second choice, or printing the
line commented out with what holds it), and comments out binds that already run pict. Paste
the lines into your `binds {}`, or save the output as `~/.config/niri/pict.kdl` and add
`include "pict.kdl"` to `config.kdl`. The defaults follow Windows where they can:

```kdl
binds {
    Mod+Shift+S hotkey-overlay-title="Snip a region" { spawn "pict"; }
    Alt+Print hotkey-overlay-title="Snip a window" { spawn "pict" "--window"; }
    Shift+Print hotkey-overlay-title="Snip freeform" { spawn "pict" "--freeform"; }
    Ctrl+Print hotkey-overlay-title="Screenshot this monitor" { spawn "pict" "--fullscreen"; }
    Ctrl+Shift+Print hotkey-overlay-title="Screenshot all monitors" { spawn "pict" "--fullscreen" "--all"; }
    Mod+Print hotkey-overlay-title="Snip straight to the clipboard" { spawn "pict" "--copy-only"; }
    Mod+Shift+T hotkey-overlay-title="Copy text from the screen" { spawn "pict" "--ocr"; }
    Mod+Shift+Print hotkey-overlay-title="Snip in 5 seconds" { spawn "pict" "--delay" "5"; }
}
```

## Config

`~/.config/pict/config.toml` (or `$XDG_CONFIG_HOME/pict/config.toml`) sets the defaults;
command-line flags override it. Every key is optional. `pict --print-config` prints the full
documented file with the built-in values, so the easiest start is:

```sh
mkdir -p ~/.config/pict && pict --print-config > ~/.config/pict/config.toml
```

| Table | Keys |
|---|---|
| `[capture]` | `mode` (region, freeform, window, fullscreen), `cursor`, `delay` |
| `[output]` | `dir`, `filename` (strftime template, no extension), `format` (png, jpg, webp), `jpeg_quality`, `save`, `copy` |
| `[editor]` | `open`, `auto_copy`, `confirm_close`, `tool`, `font` (any fontconfig name), `palette` (8 `"#rrggbb"`), `highlighter_color` |
| `[editor.sizes]` | starting size per tool: `pen`, `highlighter`, `eraser`, `line`, `arrow`, `rect`, `ellipse`, `text`, `blur`, `pixelate` |
| `[ocr]` | `language` (e.g. `"eng+deu"`), `notify` |

A mistake in the file is reported on stderr with its line number and skipped; the rest still
applies, so a broken config never stops a capture.

## OCR

`pict --ocr` and the editor's Copy text use Tesseract through its C API. Screen text is small
for Tesseract, so pict upscales captures taken at scale below 1.5 two times and inverts
light-on-dark images first; both fixed misreads in testing. Lines that are only specks of
punctuation (what Tesseract makes of borders and icons) are dropped. A 1111×196 snip takes
about 130 ms. `--ocr` prints the text on stdout, copies it, and shows a desktop notification
(turn that off with `notify = false` under `[ocr]`).

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
