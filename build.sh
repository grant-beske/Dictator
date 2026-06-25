#!/bin/bash
# Build Dictator, assemble a proper .app bundle, ad-hoc code-sign it with a
# STABLE bundle identifier (so macOS privacy/TCC grants survive rebuilds), and
# install it to /Applications.
#
# Usage:
#   ./build.sh            # build + assemble + sign + install to /Applications
#   ./build.sh --run      # ...then relaunch the installed app
#   ./build.sh --local    # assemble into ./build/ only (no /Applications copy)
#
# Requires only the Command Line Tools (swift + codesign); full Xcode not needed.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dictator"
# STABLE identifier: TCC keys grants on this + the signing identifier, so keep
# it constant across rebuilds or you'll have to re-grant permissions each time.
BUNDLE_ID="com.grantbeske.dictator"
VERSION="1.0"
BUILD_NUMBER="1"

RUN_AFTER=0
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --run) RUN_AFTER=1 ;;
    --local) INSTALL=0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Compiling (release)…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

STAGE="build/$APP_NAME.app"
echo "==> Assembling $STAGE …"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
mkdir -p "$STAGE/Contents/Resources"
cp "$BIN_PATH" "$STAGE/Contents/MacOS/$APP_NAME"

# Info.plist: LSUIElement hides the Dock icon (menu-bar only); the mic usage
# string is mandatory or macOS kills the app the instant it touches the mic.
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Dictator records your speech so it can be transcribed locally and inserted at your cursor.</string>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing with stable identifier ($BUNDLE_ID)…"
# --sign - is ad-hoc. --identifier pins the signing id to our stable bundle id
# (don't let codesign derive a volatile one from the path). No hardened runtime,
# so the mic works via the usage string without extra entitlements.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$STAGE"
codesign --verify --verbose "$STAGE" || true

if [[ "$INSTALL" -eq 1 ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST …"
  # Quit any running instance so we can overwrite it.
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$STAGE" "$DEST"
  echo "==> Installed."
  FINAL="$DEST"
else
  echo "==> Local build at $STAGE (not installed)."
  FINAL="$STAGE"
fi

if [[ "$RUN_AFTER" -eq 1 ]]; then
  echo "==> Launching…"
  open "$FINAL"
fi

echo "Done."
