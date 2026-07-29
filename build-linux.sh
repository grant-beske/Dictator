#!/usr/bin/env bash
# Build Dictator for Linux and install the `dictator` binary.
#
# Unlike the macOS build (build.sh), there's no .app bundle, code signature, or
# TCC permission dance — it's a single binary you run as a background daemon.
#
# Usage:
#   ./build-linux.sh              # build + install to ~/.local/bin/dictator
#   ./build-linux.sh --autostart  # ...and install a login autostart entry
#   ./build-linux.sh --local      # build only, don't install (binary left in .build/)
#
# Prerequisites (see README "Running on Linux"): a Swift toolchain, plus the
# runtime tools (audio recorder, clipboard/paste, notify-send) and a built
# whisper-server + model. This script only compiles and installs Dictator itself.
set -euo pipefail
cd "$(dirname "$0")"

AUTOSTART=0
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --autostart) AUTOSTART=1 ;;
    --local) INSTALL=0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found on PATH. Install the Swift toolchain first" >&2
  echo "       (see README 'Running on Linux' → 'Install the Swift toolchain')." >&2
  exit 1
fi

echo "==> Compiling (release)…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/Dictator"

if [[ "$INSTALL" -eq 0 ]]; then
  echo "==> Built at $BIN_PATH (not installed)."
  echo "Try it: $BIN_PATH daemon"
  exit 0
fi

BINDIR="${PREFIX:-$HOME/.local}/bin"
DEST="$BINDIR/dictator"
mkdir -p "$BINDIR"
# Stop a running daemon so we can overwrite its binary.
"$DEST" quit >/dev/null 2>&1 || true
install -m 0755 "$BIN_PATH" "$DEST"
echo "==> Installed $DEST"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "    NOTE: $BINDIR is not on your PATH. Add to ~/.profile:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac

if [[ "$AUTOSTART" -eq 1 ]]; then
  # A freedesktop autostart entry launches the daemon at graphical login and,
  # crucially, inherits the full session environment (WAYLAND_DISPLAY/DISPLAY,
  # D-Bus, PipeWire) that clipboard, notifications, and audio all need.
  AUTODIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
  mkdir -p "$AUTODIR"
  cat > "$AUTODIR/dictator.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Dictator
Comment=Local push-to-talk dictation daemon
Exec=$DEST daemon
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP
  echo "==> Installed autostart entry $AUTODIR/dictator.desktop"
fi

echo
echo "Next steps:"
echo "  1. Start it now:        dictator daemon &"
echo "  2. Bind a shortcut:     map a key to  dictator toggle  (see README)"
echo "  3. Check it's running:  dictator status"
echo "Done."
