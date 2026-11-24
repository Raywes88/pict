# pict

a clone of windows snip tool written (vibe-coded) in zig for my wayland+niri desktop

It's fast and native: raw Wayland, wl_shm and Cairo, with no toolkit and no GPU API. See
[PLAN.md](PLAN.md) for the architecture and roadmap.

**Status:** Phase 1 (region and fullscreen capture, PNG, clipboard).

## Build

Requires Zig 0.17.1 plus `wayland`, `wayland-protocols`, `cairo`, `libpng` and `libxkbcommon`
(all standard on CachyOS/Arch).

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.local   # installs ~/.local/bin/pict
zig build test                                      # unit tests
```

## Use

```sh
pict                       # region: drag on a frozen screen, save + copy
pict --fullscreen          # focused output (asked from niri over $NIRI_SOCKET)
pict --copy-only           # clipboard only, no file
pict --delay 5 --cursor    # wait 5 s, include the pointer
pict -o - | some-tool      # PNG on stdout
```

Files go to `~/Pictures/Screenshots/Screenshot_%Y-%m-%d_%H-%M-%S.png`, and the path is printed
on stdout. Esc or right-click cancels (exit status 1). `--adjust` keeps the selection open after
release: arrows move it, Shift+arrows resize it, Enter confirms.

### niri binds

```kdl
binds {
    Mod+Shift+S { spawn "pict" "--region"; }
    Print       { spawn "pict" "--fullscreen"; }
    Mod+Print   { spawn "pict" "--region" "--copy-only"; }
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

## License

GPL-3.0. See [LICENSE](LICENSE).
