# CLAUDE.md

Guidance for working in this repo. Read this before making changes.

## What this is

Dictator is a native macOS **menu-bar-only** push-to-talk dictation app in Swift.
Hold a hotkey → record mic audio → transcribe locally via a resident
`whisper.cpp` server → paste at the cursor. Built to be lightweight on an 8 GB
M-series MacBook Air (no Electron, no bundled runtime, minimal idle memory).

There is also a **Linux** target: a headless daemon (no menu bar / HUD) that runs
the same record→transcribe→insert pipeline, controlled by a desktop shortcut
bound to `dictator toggle`. It shells out to standard desktop tools instead of
linking anything. See "Cross-platform layout" below and the README's "Running on
Linux". **macOS is the primary target — never regress it for the Linux port.**

## Build / run / install

Plain SwiftPM — builds with **Command Line Tools alone** (no full Xcode). Do not
add an `.xcodeproj`.

```sh
./build.sh            # compile, assemble Dictator.app, ad-hoc sign, install to /Applications
./build.sh --run      # ...then launch
./build.sh --local    # assemble into ./build/ only (no install) — use this for quick checks
```

`swift build -c release` works for a pure compile check. The app is **not**
runnable as a bare binary in a useful way — it needs the bundle's Info.plist
(LSUIElement + NSMicrophoneUsageDescription) and code signature.

**Linux:** `./build-linux.sh` (compiles + installs `~/.local/bin/dictator`;
`--autostart` adds a login entry, `--local` builds without installing). There's
no bundle/signing — it's a plain binary run as `dictator daemon`. To verify the
Linux build from a Mac without a Linux box, compile in a container:
`docker run --rm -v "$PWD":/src -w /src swift:6.0 swift build -c release
--scratch-path /tmp/lb` (keep the scratch path off the macOS `.build`). The CLI
and daemon-lifecycle paths (`help`/`status`/`toggle`/`quit`, PID file) run
headless in the container; audio/clipboard/evdev need a real desktop session.

## Architecture (one file per concern, `Sources/Dictator/`)

| File | Role |
| --- | --- |
| `main.swift` | NSApplication bootstrap, `.accessory` activation policy |
| `AppDelegate.swift` | Orchestrator: status item + menu, permission flow, record→transcribe→insert pipeline, server pre-warm |
| `Config.swift` | JSON config at `~/Library/Application Support/Dictator/config.json` |
| `Permissions.swift` | Mic + Accessibility checks, Settings deep-links, alerts |
| `HotkeyManager.swift` | `CGEvent` tap: push-to-talk (modifier chord) + toggle |
| `AudioRecorder.swift` | `AVAudioEngine` → 16 kHz/16-bit/mono WAV; emits FFT spectrum for the UI |
| `SpectrumAnalyzer.swift` | vDSP FFT → normalized frequency bands (auto-gain + loudness gate) |
| `WhisperServer.swift` | Spawn + supervise `whisper-server` child process |
| `Transcriber.swift` | multipart `POST` to `/inference`, parse `{"text":...}` |
| `TextInserter.swift` | Set clipboard → synth ⌘V |
| `Overlay.swift` | Floating HUD panel: hexagon bar + waveform |
| `SoundPlayer.swift` | Hot-swappable start/stop/done cue sounds |
| `MediaController.swift` | Pause/resume now-playing media while dictating (private MediaRemote, loaded via dlsym) |

**Linux files** (`Sources/Dictator/Linux/`, each wrapped in `#if os(Linux)`):

| File | Role |
| --- | --- |
| `LinuxDaemon.swift` | Entry (`DictatorLinux.main`), CLI dispatch, PID-file control channel, `SIGUSR1`=toggle / `SIGTERM`=quit via `DispatchSource`, the record→transcribe→insert pipeline (Linux port of `AppDelegate`), prewarm |
| `LinuxAudioRecorder.swift` | Drives `parecord`/`pw-record`/`ffmpeg`/`arecord` → 16 kHz WAV; SIGINT on stop so the tool finalizes the header |
| `LinuxTextInserter.swift` | Clipboard (`wl-copy`/`xclip`) + synth paste (`wtype`/`ydotool`/`xdotool`); clipboard-only fallback |
| `LinuxEvdevInput.swift` | Optional hold-to-talk: polls `/dev/input/event*` for a key's press/release (needs `input` group) |
| `LinuxSoundPlayer.swift` / `LinuxMedia.swift` | Cue sounds via `paplay`/etc.; media pause via `playerctl` (MPRIS) |
| `LinuxSupport.swift` | `Shell` (which/run/capture/spawn), `SessionType.detect`, `Notify` (notify-send), `LinuxPaths` |

## Critical invariants — do not break these

- **Overlay must never take keyboard focus.** It's a `.nonactivatingPanel`, shown
  with `orderFrontRegardless()` (never `makeKey`), `ignoresMouseEvents = true`.
  If it takes focus, the synthesized ⌘V pastes into the overlay instead of the
  user's app. The HUD is also hidden just before the paste fires.
- **Overlay Spaces behavior is `[.canJoinAllSpaces, .fullScreenAuxiliary]`, re-asserted
  on every `show()`.** With MULTIPLE full-screen apps (each its own Space), the HUD
  must appear on whichever Space is active *now*. Do NOT add `.stationary` (an Exposé
  behavior): combined with the above it pins the panel to a single full-screen Space
  (the one it was first ordered into) so it shows there and is `occluded` everywhere
  else — the exact "HUD only on the app I slept on" bug. `OverlayController.spaceBehavior`
  is the single source of truth; `show()` re-applies it because the active full-screen
  Space changes between dictations.
- **`GGML_METAL_PATH_RESOURCES`** must be set (to `brew --prefix whisper-cpp` +
  `/share/whisper-cpp`) in the server's environment or Metal won't engage and
  transcription is slow. Set in `WhisperServer.start()`.
- **Stable bundle id** `com.grantbeske.dictator`, pinned via `codesign
  --identifier` in `build.sh`. Changing it makes macOS forget the TCC
  (Microphone/Accessibility) grants — users would have to re-approve.
- **Audio format is exactly 16 kHz / 16-bit / mono PCM WAV** — what whisper.cpp
  expects. `AudioRecorder` converts the hardware float input via `AVAudioConverter`.
- **CGEvent tap requires Accessibility.** `HotkeyManager.start()` returns `false`
  if not granted; the app then prompts. The same permission is needed to post ⌘V.
- **Transcript is intentionally left on the clipboard** after pasting (no restore
  of the previous clipboard) — the user wants a re-paste safety net for
  mis-focused dictations. Don't "fix" this back to save/restore.
- **The overlay panel is rebuilt on sleep/wake and display changes.** The single
  long-lived `NSPanel` can go stale across a sleep/wake or display
  reconfiguration and silently stop drawing (HUD never appears, but recording +
  sounds still work). `OverlayController` observes `NSWorkspace.didWakeNotification`
  and `NSApplication.didChangeScreenParametersNotification` and drops the panel so
  the next `show()` rebuilds a fresh one. Don't remove these observers or make the
  panel a one-time singleton.
- **`MediaController` uses the private MediaRemote framework, resolved at runtime
  via `dlsym`** (there is no public "pause now-playing" API). Every method must
  stay a graceful no-op when the symbols can't be loaded — don't link the
  framework directly or force-unwrap the function pointers, or a future macOS
  that removes/locks the symbols would crash the app instead of just disabling
  the feature. It pauses only when media is *actually* playing and resumes only
  what it paused (never starts playback the user paused themselves). Gated on the
  `pauseMediaWhileRecording` config flag.
- **`Config` decodes tolerantly (custom `init(from:)` with per-key fallback to
  `Config.default`).** A missing key falls back to its default instead of failing
  the whole decode — which would silently reset every user setting. When you add
  a new config field, add it to the memberwise init, `Config.default`, AND the
  `init(from:)` decoder. Don't revert to synthesized `Codable`.

## Cross-platform layout (do not break the macOS build)

- **The 9 Apple-framework files stay byte-identical and are excluded from Linux
  builds via `Package.swift`** (a host-conditional `#if os(Linux)` exclude list:
  AppDelegate, AudioRecorder, HotkeyManager, MediaController, Overlay,
  Permissions, SoundPlayer, SpectrumAnalyzer, TextInserter). This guarantees the
  macOS build is untouched by Linux work. If you add a macOS-only file, add it to
  that exclude list too.
- **Linux files are additionally `#if os(Linux)`-guarded**, so they compile to
  nothing on macOS and need no macOS-side exclude.
- **`main.swift` branches on `#if os(macOS)` / `#elseif os(Linux)`** — the only
  file compiled on both. macOS runs the `NSApplication` bootstrap; Linux calls
  `DictatorLinux.main()`.
- **Three files are genuinely shared with small internal guards:** `Config`
  (Linux config dir `~/.config/dictator`, manual `~` expansion), `Transcriber`
  (`import FoundationNetworking` on Linux), `WhisperServer` (Linux binary paths;
  the Metal env var + `metalResourcesPath` are `#if os(macOS)`-only). Keep changes
  to these behind guards so both targets keep building.
- **Config's two Linux-only fields** (`linuxInputMode`, `linuxPushToTalkKey`) were
  added following the tolerant-decode rule below (memberwise init + `default` +
  `init(from:)`). They're harmless on macOS.
- **The Linux daemon has no GUI to test in CI**, but the control plane
  (help/status/toggle/quit, PID file, config creation, SIGTERM shutdown) runs
  headless — smoke-test it in the `swift:6.0` container after Linux changes.
- **Linux signal handling uses the self-pipe trick, NOT `DispatchSource`
  signal sources.** `DispatchSource.makeSignalSource` + `signal(sig, SIG_IGN)`
  works on macOS (kqueue) but is unreliable on Linux libdispatch — an ignored
  signal can be discarded before the source observes it, so `dictator toggle`
  (which `kill`s the daemon with SIGUSR1) did nothing. A plain C handler
  (`dictatorSignalHandler`) writes the signum to a pipe; a `DispatchSource` READ
  source drains it on `.main` and dispatches toggle/quit. Don't switch it back to
  a signal source. `SIGUSR1`=toggle, `SIGTERM`/`SIGINT`=quit.
- **Never block the Linux daemon's main queue — this has bitten us repeatedly.**
  `dispatchMain()` services the main queue (signal read source + evdev's
  `DispatchQueue.main.async` hops); block it and the WHOLE daemon freezes — no
  toggles, no keys, and `dictator quit` stops working (SIGTERM routes through the
  self-pipe → main). So EVERYTHING that shells out or waits runs off the main
  thread: `stopAndTranscribe` does the recorder stop, the network transcription,
  AND the clipboard/paste insert inside a `Task` (flipping `state` to
  `.transcribing` on main first so re-entry is refused); media pause/resume runs
  on `mediaQueue`; `Notify.show` is fire-and-forget (`Shell.spawn`). The main
  thread only does quick state flips and hands work off. Belt-and-suspenders:
  `Shell.run` has an 8s timeout+SIGKILL so no external tool can hang a caller
  forever, and clipboard owners (wl-copy/xclip/xsel) go through
  `Shell.runDetached` (they stay alive to serve the selection, so you must NOT
  wait on them — waiting was the freeze after a successful transcription).
- **On startup the daemon `pkill`s stale `whisper-server`s** (`killStaleServers`)
  so an orphan from a previous `kill -9` doesn't keep holding GPU VRAM and OOM the
  fresh server on a small card. `shutdown()` calls `server.stop()` to free VRAM.
- **Short holds need `--latency-msec=30` on parecord**, or it buffers and a <~2s
  recording is lost entirely when killed (0-byte capture → whisper 400). The Task
  also skips WAVs ≤44 bytes (header only) rather than POSTing an empty file.
- **Capture child stderr via a temp FILE, not a live `Pipe` + `readabilityHandler`**
  — the latter can deadlock the process wait on Linux Foundation. The recorder
  writes stderr to a `.stderr` sidecar file read back after exit.
- **`LinuxAudioRecorder` records HEADERLESS raw PCM (`--raw`, s16le/16k/mono) and
  writes the WAV header itself in `stop()`.** Do NOT go back to letting the
  recorder write the WAV: a WAV's RIFF/data sizes are only patched in on a clean
  exit, and parecord did NOT exit on our stop signal in time — it got SIGKILLed,
  leaving an unfinalized header that whisper-server rejects with HTTP 400.
  Recording raw + wrapping it ourselves makes the WAV valid regardless of how the
  recorder died (SIGKILL just loses the last unflushed buffer). Stop uses a direct
  `kill(pid, SIGTERM)` (not `Process.interrupt()`) + bounded poll + SIGKILL
  fallback. The header bytes match `makeSilentWav` (proven accepted by the real
  server via prewarm).
- **The Linux daemon logs each pipeline step via `NSLog`** (toggle received,
  recorder launched/exited with its stderr, transcribing N bytes, inserted/
  clipboard, shutdown) — the daemon is headless with no HUD, so this log (seen by
  running `dictator daemon` in the foreground) is the only way to see what it's
  doing. Keep the steps loud.

## Diagnostics / logging

The overlay emits `NSLog` lines (visible via `log stream --predicate 'process ==
"Dictator"'` or Console.app) to make the intermittent "HUD didn't appear" bug
self-evidencing if it recurs:

- `overlay positioned at (x, y) on visibleFrame …` — logged on **every** HUD
  appearance (`OverlayController.reposition`). If the bug recurs, check whether
  this line is missing (show path never reached) or shows an off-screen origin.
- `overlay reposition found NO screen …` — no usable `NSScreen` at show time.
- `overlay invalidated (wake|screen-change) …` — the panel was dropped and will
  be rebuilt on next show.
- `overlay post-show ANOMALY alpha=… occluded=… screen=…` — **anomaly-only**, logged
  ~0.25s after a show *only* when the HUD ended up wrong: `occluded=true` means the
  panel is alive but on a Space you're not viewing (the multi-full-screen-app bug);
  `alpha<1` means the fade got dropped (transparent window). Silence here = healthy.

If you change the overlay show/position path, keep these logs (or update this
section to match).

## Conventions

- **2-space indentation.**
- Comment the tricky parts (hotkey registration, CGEvent insertion, permission
  checks, whisper-server supervision) — the existing files set the bar.
- Match the surrounding style; keep one concern per file.

## whisper-server notes

- Binary: `/opt/homebrew/bin/whisper-server` (Apple Silicon Homebrew).
- Flags used: `--model --host --port --language --inference-path /inference
  -bs <beamSize> -bo <bestOf> [-nt]`. Greedy = `-bs 1 -bo 1`; default config is
  `3`/`5`.
- The model file is at `~/whisper-models/ggml-large-v3-turbo-q5_0.bin` and is
  **not** in the repo. Don't download models.
- The endpoint returns `{"text": "..."}`; whisper inserts per-segment newlines,
  which `Transcriber` collapses to single spaces (`-nt` also reduces this).
- whisper sometimes hallucinates a leading dash/bullet (`- `, a subtitle/dialogue
  marker). `Transcriber` strips a leading run of `- – — • *` + whitespace from the
  start only, so mid-sentence dashes (`twenty-one`, `well — maybe`) survive.
- Server is pre-warmed at launch with one silent inference (`AppDelegate
  .prewarmServer`) so the first real dictation isn't slow.

## Testing

- **Server/HTTP path is testable headless:** spawn `whisper-server` with the env
  var and `POST` a WAV (e.g. the bundled `share/whisper-cpp/jfk.wav`) — no GUI or
  permissions needed.
- **Hotkey, mic capture, paste, and the overlay require a real GUI session and
  the two TCC permissions** — can't be validated from a sandbox; ask the user to
  run `./build.sh --run` and observe.

## Possible future improvements (discussed, not done)

Streaming/chunked transcription (start decoding while speaking), VAD trimming,
or switching the engine to **WhisperKit** (CoreML on the Neural Engine, in-process,
streaming) which would also delete the server-supervision layer.
