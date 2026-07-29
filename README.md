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

> **On Linux?** The same record → transcribe → insert pipeline runs as a small
> headless daemon (no menu bar, no HUD). Jump to [**Running on Linux**](#running-on-linux)
> for a complete from-scratch setup. The macOS sections below don't apply there.

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

## Running on Linux

The Linux build is one self-contained Swift binary, `dictator`, that runs as a
background **daemon**. It has no menu bar or floating HUD — feedback comes from
desktop notifications, and your "global hotkey" is a normal desktop keyboard
shortcut bound to `dictator toggle`. Everything OS-specific (audio, clipboard,
paste, media pause, notifications) is done by shelling out to standard desktop
tools, so there are no libraries to link and nothing that trips
unverified-application policies — you compile it yourself from source.

Tested building against the Swift 6.0 Linux toolchain; Swift 5.9+ should work.
The steps below assume a Debian/Ubuntu-based distro (e.g. gLinux) with `apt`.

### 1. Install the Swift toolchain

The easiest home-directory install (no root) is via **swiftly**:

```sh
curl -fsSL https://swiftlang.github.io/swiftly/swiftly-install.sh | bash
# open a new shell so `swiftly`/`swift` are on PATH, then:
swiftly install latest
swift --version        # expect 5.9 or newer
```

(Alternatively grab a toolchain tarball from <https://swift.org/download/> and
put its `usr/bin` on your `PATH`.)

### 2. Install the runtime tools

First check which display server you're on — it decides the clipboard/paste tools:

```sh
echo "$XDG_SESSION_TYPE"     # "wayland" or "x11"
```

Install the tools for your session (skip any you already have):

```sh
# Always: an audio recorder + notifications + media-pause.
# (PipeWire's pw-record is usually already present on modern GNOME.)
sudo apt install pipewire-bin pulseaudio-utils libnotify-bin playerctl

# Wayland — clipboard + synthetic paste:
sudo apt install wl-clipboard wtype

# X11 — clipboard + synthetic paste:
sudo apt install xclip xdotool
```

Dictator auto-detects the session and picks the right tools at runtime; if you're
unsure, installing both sets is harmless. See [the paste caveat](#gnome-wayland-paste-caveat)
if you're on GNOME Wayland.

### 3. Build whisper.cpp (with CUDA) and download the model

You have an NVIDIA GPU, so build the server with CUDA for near-instant
transcription. You need the CUDA toolkit (`nvcc --version` to check; install with
`sudo apt install nvidia-cuda-toolkit` if missing) plus `build-essential cmake git`.

```sh
git clone https://github.com/ggml-org/whisper.cpp ~/whisper.cpp
cd ~/whisper.cpp

# Build everything (including whisper-server) with the CUDA backend.
cmake -B build -DGGML_CUDA=1
cmake --build build -j --config Release
# -> server binary at ~/whisper.cpp/build/bin/whisper-server  (Dictator finds this)

# Download the same model the macOS build uses, into ~/whisper-models/.
bash ./models/download-ggml-model.sh large-v3-turbo-q5_0
mkdir -p ~/whisper-models
cp models/ggml-large-v3-turbo-q5_0.bin ~/whisper-models/
```

Dictator starts and supervises this server for you (auto-restart on crash,
pre-warmed at launch) — you don't run it yourself. For a **CPU-only** machine,
just omit `-DGGML_CUDA=1`; `large-v3-turbo` is designed to be fast and stays
usable on a many-core CPU (a few seconds per dictation).

### 4. Build & install Dictator

```sh
git clone <this-repo> ~/Dictator && cd ~/Dictator
./build-linux.sh                 # installs ~/.local/bin/dictator
# ./build-linux.sh --autostart   # ...and start it automatically at login
# ./build-linux.sh --local       # build only, don't install
```

Make sure `~/.local/bin` is on your `PATH` (the script warns if not).

### 5. Start it and bind your hotkey

```sh
dictator daemon &      # starts the daemon (and the whisper-server) in the background
dictator status        # -> "Dictator daemon is running (pid …)"
```

Now bind a key to the toggle. On **GNOME**: *Settings → Keyboard → View and
Customize Shortcuts → Custom Shortcuts → +*, then:

- **Name:** `Dictator`
- **Command:** `/home/YOUR_USERNAME/.local/bin/dictator toggle`  ← use the absolute path
- **Shortcut:** pick a key, e.g. `Super+D`

Press it once to start recording (you'll get a "🎙 Recording…" notification),
press again to stop → transcribe → paste. On **KDE** use *System Settings →
Shortcuts → Custom Shortcuts*; on other desktops, any "run this command on this
key" facility works.

**Launch at login:** run `./build-linux.sh --autostart` (installs a freedesktop
autostart entry that inherits your full graphical-session environment — the most
reliable option, since clipboard/notifications/audio all need session env vars).

### 6. Linux configuration

Config lives at `~/.config/dictator/config.json` (created on first run). The
cross-platform keys (`modelPath`, `language`, `serverPort`, `beamSize`, `bestOf`,
`noTimestamps`, `soundsEnabled`, `pauseMediaWhileRecording`) work as on macOS.
The macOS-only keys (`hotkeyMode`, `pushToTalkModifiers`, `toggle*`,
`waveformGain`) are ignored. Two keys are Linux-specific:

```json
{
  "linuxInputMode": "socket",
  "linuxPushToTalkKey": 97
}
```

- **`linuxInputMode`** — `"socket"` (default) uses the toggle-via-shortcut flow
  above (no special permissions, works on X11 and Wayland). `"evdev"` enables
  true hold-to-talk (see below).
- **`linuxPushToTalkKey`** — the evdev key code for the hold key in `evdev` mode.

Cue sounds work too: drop `start.wav` / `stop.wav` / `done.wav` (or `.ogg`) into
`~/.config/dictator/sounds/`.

### Optional: true push-to-talk (hold-to-talk) via evdev

Toggle mode is press-to-start/press-to-stop. To get the macOS **hold** feel —
record only while a key is held — Dictator can read key press/release straight
from the kernel (`/dev/input/event*`), which works under both X11 and Wayland.
This needs read access to input devices:

```sh
sudo usermod -aG input "$USER"     # then log out and back in
```

Then set `"linuxInputMode": "evdev"` and pick your hold key with
`"linuxPushToTalkKey"` (default `97` = Right Ctrl; other common codes: `100` =
Right Alt, `125` = Super). Find a key's code with `sudo evtest` or `wev`. If input
access isn't available, the daemon logs a warning and automatically falls back to
toggle mode, so nothing breaks.

### GNOME Wayland paste caveat

On **GNOME Wayland specifically**, synthetic keystrokes via `wtype` usually don't
work (GNOME doesn't implement the virtual-keyboard protocol). Dictator still puts
the transcript on your clipboard and notifies you to press **Ctrl+V** — the same
"it's always on the clipboard" safety net the macOS build relies on. To get fully
automatic paste on GNOME Wayland, either set up **ydotool** (needs a `ydotoold`
daemon with `/dev/uinput` access) or use an **X11** session, where `xdotool`
pastes automatically.

### Linux troubleshooting

Run the daemon in the foreground to watch its log (Dictator logs via `NSLog`,
which goes to stderr on Linux):

```sh
dictator quit          # stop any background instance
dictator daemon        # run in this terminal; Ctrl+C to stop
```

- **`session=… recorder=NONE`** in the log → no recorder installed; see step 2.
- **Text lands on the clipboard but doesn't paste** → the GNOME Wayland caveat
  above; press Ctrl+V, or switch to X11 / set up ydotool.
- **No notifications** → install `libnotify-bin`, and start the daemon from within
  your graphical session (a terminal in your desktop, or the `--autostart` entry)
  so it inherits the session's D-Bus address.
- **"Transcription failed"** → the whisper-server isn't answering. Confirm
  `~/whisper.cpp/build/bin/whisper-server` exists and the model is at the path in
  your config; the daemon's log shows the server's own output.

### Uninstall (Linux)

```sh
dictator quit
rm ~/.local/bin/dictator
rm -rf ~/.config/dictator
rm -f ~/.config/autostart/dictator.desktop
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

**Linux equivalents.** `Config`, `Transcriber`, and `WhisperServer` are shared;
the Apple-framework files are excluded from the Linux build in `Package.swift`
and replaced by `Sources/Dictator/Linux/*` (each `#if os(Linux)`-guarded):

| Concern | macOS | Linux |
| --- | --- | --- |
| Process model | menu-bar app (`NSStatusItem`) | headless daemon + `dictator toggle` CLI |
| Global hotkey | session `CGEvent` tap | desktop shortcut → `SIGUSR1` (toggle), or evdev `/dev/input` (hold-to-talk) |
| Audio | `AVAudioEngine` + `AVAudioConverter` | `parecord`/`pw-record`/`ffmpeg`/`arecord` → WAV |
| Insert text | clipboard + synth ⌘V (`CGEvent`) | `wl-copy`+`wtype` / `xclip`+`xdotool` (clipboard is the fallback) |
| Media pause | private MediaRemote (dlsym) | `playerctl` (MPRIS) |
| Feedback | floating HUD + status icon | `notify-send` desktop notifications |
| Whisper backend | Metal (`GGML_METAL_PATH_RESOURCES`) | CUDA/CPU (chosen at whisper.cpp build time) |
| Launch at login | `SMAppService` | freedesktop autostart entry |
