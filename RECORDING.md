# Screen recording: plan (Phase 5)

**Status:** proposal, not started. Written 2026-11-24, right after 1.0.0. Facts marked
*verified* were checked on kotov and xarl that day; everything else is a design choice or an
open question, and is labelled as one.

Recording was the stretch goal in the original brief ("local screen recording, MP4/WebM/GIF").
This document is the spec to build it from. It deliberately reuses what 1.0 already has:
the overlay's region selection, `wl/Client.zig`, the screencopy code, the clipboard owner,
notifications, the config file and the niri binds generator.

---

## 1. What "parity" means here

The Windows Snipping Tool records like this: Win+Shift+R, drag a region, press Start, a 3-2-1
countdown, then a dashed border around the region and a small toolbar (timer, pause, stop,
mic and system-audio toggles) placed outside it. Stopping opens a preview, and the result is an
MP4.

**pict recording v1 goals:**

- Region (single monitor) and full-monitor recording.
- MP4 (H.264) by default, with GIF and WebM as exports of the same recording.
- Optional system audio and microphone.
- Start, pause/resume and stop from keybinds, plus an on-screen pill outside the region.
- The same bind toggles: press it to start, press it again to stop.
- Hardware encoding where the machine has it, software fallback otherwise.
- Crash-safe: killing pict mid-recording still leaves a playable file.
- After stop: save to `~/Videos/Screencasts/`, notify, and put the file on the clipboard.

**Not in v1:** window recording (niri 26.04 can't hand it over; see §9), regions spanning
monitors, a preview/trim window, webcam overlay, editing.

---

## 2. Environment (verified 2026-11-24)

| | kotov | xarl |
|---|---|---|
| GPU | RTX 2080 (Turing), NVIDIA 620.73 | Intel UHD 620 (Whiskey Lake), `intel-media-driver` (iHD) |
| Outputs | 2× 2560×1440 @ 1.0 | eDP-1 1920×1080 @ 1.0 |
| ffmpeg | n9.1 | n9.1 |
| H.264 encoders in ffmpeg | `h264_nvenc`, `h264_vaapi`, `libx264` | `h264_vaapi`, `libx264` (`h264_nvenc` is compiled in but there's no NVIDIA GPU) |
| Other encoders | `hevc_nvenc`, `libvpx-vp9`, `libsvtav1`, `gif` | `hevc_vaapi`, `libvpx-vp9`, `libsvtav1`, `gif` |
| Audio | PipeWire 1.6.11 with pipewire-pulse | same stack |
| Portal | `xdg-desktop-portal-gnome` 51 | same |
| niri | 26.04: `zwlr_screencopy_manager_v1` v3, **no** `ext_image_copy_capture` | same |

- `av1_nvenc` is listed by kotov's ffmpeg, but Turing has no AV1 encoder, so AV1 there is
  `libsvtav1` on the CPU.
- 1.0's one-shot capture took about 12 ms for one 2560×1440 output on kotov and 17 ms for
  1920×1080 on xarl. That time **includes waiting for the next compositor frame**, so it is not
  the per-frame copy cost of a streaming loop. That cost is unmeasured; see §7.
- `Super+Shift+R` (Windows' record key) is taken on both machines by niri's
  `switch-preset-window-height`. `Super+Alt+R` is free on both, matching how OCR landed on
  `Super+Alt+T`.

---

## 3. Key decisions (recommended)

### 3.1 Capture: a wlr-screencopy streaming loop into shm buffers

Each frame calls `capture_output_region(overlay_cursor, output, x, y, w, h)` followed by
`copy_with_damage` into one of a small ring of `wl_shm` buffers.

- **Region capture happens in the compositor.** Only the selected rectangle is copied, so a
  small region costs proportionally less, which matters for NVIDIA readback.
- **`copy_with_damage` waits for something to change.** An idle screen produces no copies, and
  the encoder repeats the last frame instead (§3.3).
- **It's the path 1.0 already proved,** including the pixel formats, the y-invert flag, rotated
  outputs and NVIDIA.

Alternatives considered:

- **xdg-desktop-portal ScreenCast plus PipeWire.** niri supports it through the GNOME portal,
  and it gives dmabuf zero-copy and window casting. The catch is that the portal shows a
  chooser dialog on every recording unless a restore token is kept, and it adds libpipewire.
  Revisit it for window recording (§9).
- **dmabuf screencopy buffers.** These avoid the CPU copy, but feeding them to NVENC needs CUDA
  or EGL interop. That's a performance upgrade to make later if the spike in §7 shows shm can't
  keep up.
- **`ext-image-copy-capture`.** Not offered by niri 26.04. Put it behind the same `Stream`
  interface once niri ships it.

### 3.2 Encoding: spawn `ffmpeg` and send raw frames over a pipe

pict writes BGRA frames to ffmpeg's stdin (`-f rawvideo -pix_fmt bgra -s WxH -r FPS -i -`),
and ffmpeg handles encoding, audio capture, mixing and muxing.

- **Everything comes for free:** hardware encoders (`h264_nvenc` takes `bgra` and converts on
  the GPU; VA-API uses `format=nv12,hwupload`), PulseAudio/PipeWire audio input, the GIF
  palette filters and every container.
- **No libav ABI pinning,** and libav stays out of the snip path. Snips keep their sub-100 ms
  startup.
- **Cost:** one extra copy through a pipe. That's 2560×1440×4×30 = 442 MB/s for a full kotov
  monitor at 30 fps, and 249 MB/s for xarl at 1080p30. Pipes move several GB/s, but measure it
  (§7).
- **Fallback:** an in-process libav backend, `dlopen`ed on first use the way libtesseract is,
  behind the same `Encoder` interface. Only build it if the spike shows the pipe is the
  bottleneck.

**Encoder auto-selection, in order:**

1. `h264_nvenc`, if `/dev/nvidia0` exists.
2. `h264_vaapi`, if `/dev/dri/renderD128` is an Intel or AMD device.
3. `libx264 -preset veryfast`.

pict probes the choice once with a short trial encode and caches the result in
`$XDG_CACHE_HOME/pict/encoder`, then retries the next option if ffmpeg exits during start-up.
The `[record] encoder` key overrides it.

### 3.3 Timing: constant frame rate, paced by pict

A ticker thread runs at the target fps (default 30). On each tick it sends the newest complete
frame, which is a repeat if nothing was damaged.

- **Why not variable frame rate:** a rawvideo pipe carries no timestamps, and constant frame
  rate keeps audio sync simple.
- **If the encoder pipe falls behind,** drop frames rather than queue them, and count the
  drops. Show the count in `--timings` and in the stop notification if it's above 1%.

### 3.4 Crash safety: record to MKV, remux to MP4 on stop

ffmpeg writes `~/.cache/pict/rec-<pid>.mkv`, which is still playable after a kill. On stop pict
runs `ffmpeg -i rec.mkv -c copy -movflags +faststart out.mp4`, which takes well under a second
for a minute of video, and deletes the temp file.

- **On start,** a leftover `rec-*.mkv` whose pid is dead gets recovered: remuxed into the
  Screencasts directory and announced in a notification.
- **Why not fragmented MP4:** some players and upload sites handle fMP4 badly. A remux is cheap
  and gives a normal file.

### 3.5 Control: one bind toggles, and a socket finds the running recorder

- **`pict --record` while a recording is running** connects to
  `$XDG_RUNTIME_DIR/pict/record.sock`, sends `stop` and exits 0. That makes one key both start
  and stop recording.
- **Other commands:** `pict --record-stop` and `--record-pause` (toggles), and
  `--record-status` (prints JSON, so a waybar module is possible).
- **Signals:** SIGINT and SIGTERM stop cleanly. A stale socket, where `connect` gets
  `ECONNREFUSED`, is unlinked and replaced.

### 3.6 Selection and indicator

- **The selection overlay is live, not frozen.** Unlike snips, the region is picked over the
  live screen: a translucent layer-shell overlay with the same dim, handles and size label,
  and no capture beforehand. `overlay/selection.zig` is reused unchanged; only the background
  differs.
- **In v1 the selection is clamped to the monitor it starts on.**
- **Countdown, 3 s by default** (`[record] countdown`). It's drawn in the middle of the region,
  then the overlay is unmapped. Capture starts only after a frame callback confirms the
  compositor has presented without it.
- **Border:** a 2 px red dashed border is drawn *just outside* the region on its own overlay
  surface with an empty input region (clicks pass through). Because capture is limited to the
  region (§3.1), the border is never in the video.
- **Pill:** a small surface showing a red dot, the elapsed time, pause and stop. It sits
  outside the region, below it if there's room, then above, then to the side.
- **Full-monitor recordings have no "outside",** so the pill and border are hidden. The bind,
  `--record-stop` and a "Recording, press Super+Alt+R to stop" notification cover it.
- **Open question:** a niri `layer-rule { match namespace="^pict-rec"; block-out-from
  "screen-capture"; }` should hide the pill even inside a full-monitor recording. Check
  whether niri applies `block-out-from` to wlr-screencopy clients before relying on it. If it
  does, `--print-niri-binds` can print the rule too.

### 3.7 Audio

`[record] audio = "none" | "system" | "mic" | "both"`, default `"none"`. A flag overrides it:
`--audio system,mic`.

- **System audio:** `-f pulse -i @DEFAULT_MONITOR@`.
- **Microphone:** `-f pulse -i @DEFAULT_SOURCE@`.
- **Both:** mixed with `amix=inputs=2:duration=first`, encoded as AAC 160k for MP4 or Opus for
  WebM.
- **Pause** stops sending video frames and mutes the audio by switching the `amix` weights
  through ffmpeg's stdin command interface, or simply stops and appends segments (concat on
  stop). Pick whichever the spike shows is reliable. The segment approach is simpler and
  always correct.
- **Sync risk:** audio starts when ffmpeg opens the device, while video starts at pict's first
  tick. pict starts ffmpeg, waits for its first `out_time` progress line, and only then starts
  the ticker. Measure the residual offset with the beep-and-flash test (§8).

### 3.8 Output

- **Default path:** `~/Videos/Screencasts/Recording_%Y-%m-%d_%H-%M-%S.mp4`, reusing
  `save.Target` and collision handling.
- **On stop:**
  - Show a notification with the duration, size and path, plus an "Open" action that runs
    `xdg-open` if the notification server supports actions.
  - Copy to the clipboard as `text/uri-list` (`file:///…`). Also offer
    `x-special/gnome-copied-files`, which is what file managers use and what Discord and
    browsers accept for a pasted file. Test which targets Discord, Firefox and Nautilus actually
    take (§8).
- **GIF export (`--format gif`):** a second ffmpeg pass on stop, `fps=15,scale='min(960,iw)':-1`
  then `palettegen=stats_mode=diff` and `paletteuse=dither=bayer:bayer_scale=4`. Warn in the
  notification when it's over 20 MB, and keep the MKV until the GIF is written.
- **WebM export:** VP9 (`libvpx-vp9 -deadline realtime -cpu-used 8`) or AV1 (`libsvtav1`), run as
  a second pass like GIF. Live WebM encoding is not worth it on xarl's CPU.

---

## 4. CLI and config

```
pict --record                 # region (live overlay) → countdown → record; again to stop
pict --record --fullscreen    # the focused monitor
pict --record --audio both    # system + mic
pict --record --fps 60 --format gif
pict --record-stop | --record-pause | --record-status
```

`--record` combines with the existing mode flags. `--window` and `--freeform` are rejected in
v1 with a pointer to this file. `--delay` works and runs before the selection.

```toml
[record]
dir = "~/Videos/Screencasts"
filename = "Recording_%Y-%m-%d_%H-%M-%S"
format = "mp4"          # mp4, webm, gif
fps = 30                # 1-60
encoder = "auto"        # auto, nvenc, vaapi, x264
quality = 23            # CRF / CQ / QP, depending on encoder
audio = "none"          # none, system, mic, both
countdown = 3           # seconds, 0 to skip
cursor = true           # recordings usually want the pointer, unlike snips
show_border = true
```

The `config.zig` parser needs no changes. Add the table to `Config`, `apply()` and
`default_text`; the round-trip test covers the new keys automatically.

**Binds:** add an entry to `binds.zig` with title "Record the screen", args `--record`, and
combos `Mod+Shift+R` then `Mod+Alt+R`. On both of Wes's machines that resolves to
`Mod+Alt+R`.

---

## 5. Architecture

```
src/record/
  Recorder.zig     state machine: select → countdown → recording ⇄ paused → stopping → done;
                   owns the control socket, the ticker, and cleanup
  stream.zig       screencopy streaming: buffer ring, capture_output_region, copy_with_damage,
                   transform/y-invert handling (shares format code with capture/screencopy.zig)
  ffmpeg.zig       Encoder: builds the ffmpeg argv (encoder, audio, filters), spawns with
                   pipes, parses -progress output, remux/export passes
  indicator.zig    border + pill layer surfaces (Cairo, same toolkit-free drawing as overlay)
  control.zig      Unix-socket protocol (stop, pause, status) and the client side of
                   --record-stop/--record-pause/--record-status
src/overlay/Overlay.zig   + a `live` mode: no frozen frame, translucent dim, same selection
src/clipboard.zig         + Kind.uri_list (text/uri-list + x-special/gnome-copied-files)
src/config.zig            + [record]
src/cli.zig               + --record, --record-stop/-pause/-status, --fps, --audio
src/binds.zig             + "Record the screen"
```

**Threads:**

1. **Main thread:** the Wayland event loop for screencopy events, the indicator, frame
   callbacks and the control socket.
2. **Ticker:** every 1/fps seconds it takes the newest completed buffer.
3. **Writer:** `write()`s the frame to ffmpeg's stdin. It blocks there, never on the Wayland
   loop.

The buffer ring has 4 entries, each marked free, capturing, ready or writing, so a slow writer
never stalls capture. If no buffer is free when a capture should start, that frame is dropped
and counted.

The pixels for a region recording go straight from the screencopy buffer to the pipe. There's
no `Image` copy and no compose, which is why v1 keeps regions to one monitor. Spanning monitors
needs a compose per frame (§9).

---

## 6. Phases

**5.0: Spike (measure before building).** A throwaway `pict --record-bench` that streams
screencopy for 10 s and writes frames to `ffmpeg -f null` with each encoder. Record:

- achieved fps and drops for a full monitor and for an 800×600 region, at 30 and 60 fps
- the CPU use of pict and of ffmpeg
- whether `copy_with_damage` blocks on an idle screen

Run it on kotov (NVENC) and xarl (VA-API).

- **Go:** full-monitor 30 fps with under 1% drops on both. Then the shm plus pipe design
  stands.
- **No-go:** move to dmabuf buffers or in-process libav for that machine.

**5a: MVP.**
- Live region overlay, countdown, region and fullscreen.
- MP4 H.264 with auto encoder, no audio.
- The toggle bind and control socket, border and pill.
- MKV-then-remux, recovering orphaned recordings.
- Notification and uri-list clipboard, `[record]` config, the binds entry, and `--timings`
  stats.

**5b: Audio and pause.** System, mic and both; pause/resume by segments; the A/V sync test.

**5c: Exports.** GIF (two-pass palette) and WebM (VP9/AV1), plus size warnings.

**5d: Later, each optional.**
- Window recording.
- Regions spanning monitors.
- dmabuf zero-copy.
- A preview/trim window (decode via ffmpeg into the editor's Cairo canvas, plus audio
  playback; this is substantial).
- `ext-image-copy-capture` when niri ships it.

---

## 7. Performance budget

| Stage | Target (1440p30 on kotov, 1080p30 on xarl) |
|---|---|
| Bind to live overlay visible | < 60 ms (snips manage about 50 ms with a capture first) |
| Screencopy per frame | ≤ 1/3 of the frame interval (≤ 11 ms at 30 fps) |
| Pipe write per frame | ≤ 5 ms |
| Frame drops | < 1% over 60 s |
| CPU, pict | < 15% of one core |
| Stop to file saved and notified | < 1 s per minute of recording (the remux) |
| Memory | flat over a 10-minute recording (fixed buffer ring) |

---

## 8. Testing

Test hooks follow 1.0's `PICT_TEST_*` pattern:

- **`PICT_TEST_RECORD="seconds=3"`** auto-stops. Combined with `PICT_TEST_AUTOSELECT`, this
  gives a fully scripted recording.
- **ffprobe checks:** duration within 1 frame, resolution equal to the selected physical rect,
  the expected codec, and fps.
- **Frame accuracy:** record a window running `ffplay -f lavfi testsrc2=rate=30` (it has a
  frame counter). The decoded counter must increase by exactly 1 per frame. Repeats are
  allowed only when ffplay itself stalls.
- **A/V sync:** a window flashes white while `pw-play` beeps at the same instant. Measure the
  offset between the flash frame and the audio onset; it must be under 1 frame (33 ms).
- **Crash safety:** `kill -9` mid-recording, then run `pict --record` again. The orphan must be
  recovered as a playable MP4.
- **Toggle:** a second `pict --record` stops the first. A stale socket after a crash is cleaned
  up.
- **Rotated and fractional outputs:** as in Phase 2, rotate DP-3 or set scale 1.5 briefly and
  compare the first frame against `grim -g`.
- **Clipboard:** paste the result into Discord, Firefox (file input) and Nautilus, and record
  which targets each one takes.

---

## 9. Risks and open questions

- **`capture_output_region` coordinate space.** The wlr protocol describes the region in
  output logical coordinates. At fractional scales the returned buffer can be a pixel larger
  than expected, so crop to the exact physical rect pict computed (the overlay's math already
  does this for snips).
- **Rotated outputs.** Screencopy returns untransformed frames (found in Phase 2). For a
  rotated monitor, either map the region into buffer space and add an ffmpeg `transpose`, or
  rotate in the writer. Prefer the ffmpeg filter.
- **NVIDIA shm readback at 60 fps** may not keep up for a full 1440p monitor. The spike decides
  whether 60 fps is supported only for regions.
- **`block-out-from` for screencopy** is unverified (§3.6).
- **Window recording on niri 26.04** is only possible through the portal plus PipeWire (niri
  supports window casts there). It needs libpipewire, a chooser dialog, and a different frame
  source behind `stream.zig`'s interface. Alternatively, wait for niri to add a toplevel
  source to `ext-image-copy-capture`.
- **Pause via segments** creates a concat step on stop. Check that keyframes at segment
  boundaries don't make seeking stutter (`-force_key_frames` on resume).
- **Clipboard file paste:** apps disagree about targets. If none of `text/uri-list` or
  `x-special/gnome-copied-files` work in Discord, fall back to copying the path as text.

---

## 10. Decisions for Wes before 5a

1. **Encoding through the `ffmpeg` CLI** (§3.2), with ffmpeg as a runtime dependency for
   recording only. The alternative is in-process libav.
2. **Default audio:** `none` (recommended) or `system`.
3. **Record bind:** `Super+Alt+R` on both machines, since `Super+Shift+R` is niri's
   window-height preset.
4. **Save location:** `~/Videos/Screencasts/`.
5. **Preview window after stop:** skip it in v1 (recommended; notification plus clipboard
   only), or include it.
