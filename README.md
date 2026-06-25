# Dictator

A lightweight, **local** push-to-talk dictation tool for macOS. Hold a key,
speak, release — your words are transcribed by a resident `whisper.cpp` server
and pasted at the cursor in whatever app you're using. Menu-bar only, no Dock
icon, no Electron, no bundled runtime. Built for an 8 GB M-series MacBook Air.

- **Capture:** `AVAudioEngine` → 16 kHz / 16-bit / mono WAV (deleted after use).
- **Transcribe:** a warm local `whisper-server` child process (model stays
  loaded — no per-dictation reload), reached over HTTP.
- **Insert:** copies the transcript to the clipboard, then synthesizes ⌘V. The
  transcript stays on the clipboard so you can re-paste if the wrong field was
  focused.

## Prerequisites (assumed already installed)

- `whisper-cpp` via Homebrew (`whisper-server` / `whisper-cli` on `PATH`).
- A model at `~/whisper-models/ggml-large-v3-turbo-q5_0.bin`.
- Apple **Command Line Tools** (`xcode-select --install`) — full Xcode not required.

## Build & install

```sh
./build.sh          # compile, assemble Dictator.app, ad-hoc sign, copy to /Applications
./build.sh --run    # ...and launch it
./build.sh --local  # assemble into ./build/ only (no install)
```

The app is ad-hoc signed with the **stable** bundle id `com.grantbeske.dictator`
so your Microphone/Accessibility grants persist across rebuilds.

## First run — grant the two permissions

Dictator needs two macOS permissions and will show an alert (never failing
silently) if either is missing, with a button that opens the right pane:

1. **Microphone** — System Settings → Privacy & Security → **Microphone** →
   enable **Dictator**. (To capture audio at all.)
2. **Accessibility** — System Settings → Privacy & Security → **Accessibility**
   → enable **Dictator**. (To detect the global hotkey and to paste via ⌘V.)

After enabling Accessibility, pick **Re-check Permissions…** from the menu-bar
icon (or relaunch). The menu-bar icon shows state: `mic` idle, red `mic.fill`
recording, `waveform` transcribing.

While dictating, a small floating HUD appears at the top-center of your active
screen: a black hexagon-ended bar (outlined in the state color) with a state
hexagon on the left (**red** while recording, **amber** while transcribing). On
the right, recording shows a stationary spectrum-analyzer waveform — a **white**
envelope over a red center line — that reacts to your voice. After you release
the keys it switches to an **orange** "processing" sine wave (matching the
hexagon), then fades out as the text is pasted. The HUD never takes focus, so
your cursor stays where it is. If the bars look too small or too maxed-out when
you speak, tune `waveformGain` in the config.

## Using it

- **Push-to-talk (default):** hold **Right Command + Right Option** together,
  speak, release either key. Transcribes and pastes on release. (Requiring two
  right-hand modifiers avoids accidental triggering during normal typing.)
  Optionally add a `start.*` cue sound (see below) for an audible confirmation.
- **Toggle (fallback):** if a held single global key proves unreliable on your
  setup, switch to toggle mode and press **Ctrl+Option+D** to start, again to
  stop. See config below.

## Custom cue sounds

Dictator plays three cues you can fully customize (and hot-swap while it's
running). Drop files into the **Sounds** folder — open it from the menu's
**Open Sounds Folder**, or find it at:

```
~/Library/Application Support/Dictator/Sounds/
```

Name them by event (first matching extension wins —
`wav`, `aiff`, `aif`, `caf`, `mp3`, `m4a`):

| File | Plays when |
| --- | --- |
| `start.*` | you start holding the push-to-talk keys |
| `stop.*`  | you release them (transcription begins) |
| `done.*`  | the transcript has been pasted |

Any missing file is simply silent — the on-screen waveform still signals state.
Changes apply immediately (files are read fresh each play); no rebuild needed.
Toggle all cues with `"soundsEnabled": false` in the config.

**Where to get cool/futuristic sounds:**

- [Pixabay Sound Effects](https://pixabay.com/sound-effects/search/ui/) — free, no
  attribution; search "sci-fi UI", "interface", "blip".
- [Mixkit](https://mixkit.co/free-sound-effects/sci-fi/) — free sci-fi / UI packs.
- [freesound.org](https://freesound.org) — huge library (check each clip's CC license).
- [Zapsplat](https://www.zapsplat.com) — large "user interface" + sci-fi categories
  (free with account/attribution).
- Apple's own system sounds in `/System/Library/Sounds/` (e.g. `Tink.aiff`,
  `Pop.aiff`, `Morse.aiff`) make decent placeholders — copy and rename them.

Tip: keep them short (under ~400 ms) and pick a lower-pitched `start` and a
higher, brighter `done` so the open/close/complete arc is audible without looking.

## Configuration

Config lives at `~/Library/Application Support/Dictator/config.json` (created
with defaults on first launch). Edit it via the menu's **Edit Config…**, then
**Quit** and relaunch.

```json
{
  "modelPath": "~/whisper-models/ggml-large-v3-turbo-q5_0.bin",
  "hotkeyMode": "pushToTalk",
  "pushToTalkModifiers": ["rightCommand", "rightOption"],
  "toggleKeyCode": 2,
  "toggleModifiers": ["control", "option"],
  "serverPort": 8080,
  "language": "en",
  "soundsEnabled": true,
  "waveformGain": 1.4,
  "beamSize": 3,
  "bestOf": 5,
  "noTimestamps": true
}
```

- **Decoding speed:** `beamSize`/`bestOf` default to `3`/`5` (beam search, a
  balance of speed and accuracy). Lower them toward `1`/`1` for greedy decoding
  (fastest) if you want more speed on clean audio. `noTimestamps: true` is
  slightly faster and avoids whisper's per-segment newlines.

- **Tune the waveform:** raise `waveformGain` (e.g. `2.0`) if the bars barely
  move when you speak; lower it if they're always pinned to full height.

- **Change the model:** point `modelPath` at another `ggml-*.bin`.
- **Change the language:** set `language` (e.g. `"es"`, or `"auto"` to detect).
- **Switch to toggle mode:** set `"hotkeyMode": "toggle"`.
- **Change the push-to-talk chord:** set `pushToTalkModifiers` to the *modifier*
  keys you must hold together. Side-specific names: `leftCommand`,
  `rightCommand`, `leftOption`, `rightOption`, `leftControl`, `rightControl`,
  `leftShift`, `rightShift`. One entry = a single modifier (e.g.
  `["rightOption"]`); multiple = all held at once. (Push-to-talk observes
  modifier keys; to hold a non-modifier key, use toggle mode instead.)
- **Change the toggle chord:** set `toggleKeyCode` (e.g. D `2`) and
  `toggleModifiers` (any of `command`, `control`, `option`, `shift`).
- **Change the port:** set `serverPort` if `8080` is taken.

## Launch at login

Use the menu-bar item **Launch at Login** (toggles via `SMAppService`). It
applies to the copy in `/Applications`.

## Uninstall

```sh
# 1. Quit it
pkill -x Dictator

# 2. Remove the app and its config
rm -rf /Applications/Dictator.app
rm -rf ~/"Library/Application Support/Dictator"

# 3. Disable launch-at-login if you enabled it (the menu toggle does this too)
#    Removing the app is sufficient; the login entry becomes inert.

# 4. Revoke the TCC grants if you want a clean slate:
#    System Settings → Privacy & Security → Microphone / Accessibility → remove Dictator.
```

## How it works (internals)

| Concern | Approach |
| --- | --- |
| Menu-bar only | `LSUIElement=true` + `NSApp.setActivationPolicy(.accessory)`; `NSStatusItem` |
| Global hotkey | Session `CGEvent` tap on `flagsChanged` (push-to-talk) / `keyDown` (toggle); matches a chord of side-specific modifiers via device-dependent flag bits (so "right keys only" is reliable); re-enables itself if the system disables the tap |
| Audio | `AVAudioEngine` input tap → `AVAudioConverter` → 16 kHz/16-bit/mono WAV |
| Warm model | `whisper-server` child process kept resident & supervised (auto-restart on crash) with `GGML_METAL_PATH_RESOURCES` set so Metal engages; pre-warmed at launch with one silent inference so the first dictation is fast |
| Transcribe | multipart `POST` to `http://127.0.0.1:<port>/inference` |
| Insert text | set transcript on clipboard → synth ⌘V via `CGEvent` (transcript left on clipboard for re-paste) |

If the resident server ever proves troublesome you can fall back to invoking
`whisper-cli` per dictation; the multipart client in `Transcriber.swift` is the
only piece that would change.
