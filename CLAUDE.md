# CLAUDE.md

Guidance for working in this repo. Read this before making changes.

## What this is

Dictator is a native macOS **menu-bar-only** push-to-talk dictation app in Swift.
Hold a hotkey → record mic audio → transcribe locally via a resident
`whisper.cpp` server → paste at the cursor. Built to be lightweight on an 8 GB
M-series MacBook Air (no Electron, no bundled runtime, minimal idle memory).

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

## Critical invariants — do not break these

- **Overlay must never take keyboard focus.** It's a `.nonactivatingPanel`, shown
  with `orderFrontRegardless()` (never `makeKey`), `ignoresMouseEvents = true`.
  If it takes focus, the synthesized ⌘V pastes into the overlay instead of the
  user's app. The HUD is also hidden just before the paste fires.
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
