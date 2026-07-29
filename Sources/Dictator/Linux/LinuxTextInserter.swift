#if os(Linux)
import Foundation

// Inserts the transcript at the cursor the same way the macOS build does:
//   1. put the text on the clipboard (and LEAVE it there — the re-paste safety
//      net that the macOS TextInserter documents; if paste lands in the wrong
//      place you can just Ctrl+V again), then
//   2. synthesize the paste keystroke.
//
// The tools differ by display server:
//   X11:      xclip/xsel to set the clipboard, xdotool to press Ctrl+V.
//   Wayland:  wl-copy to set the clipboard, wtype (or ydotool) to press Ctrl+V.
//
// If no keystroke-synthesis tool is available (notably GNOME Wayland, which
// doesn't implement the virtual-keyboard protocol wtype uses, unless ydotool +
// uinput are set up), we still succeed at step 1 and report `.clipboardOnly` so
// the caller can tell the user to press Ctrl+V themselves.
enum LinuxTextInserter {
  enum Result { case pasted, clipboardOnly, failed }

  @discardableResult
  static func insert(_ text: String) -> Result {
    let session = SessionType.detect()

    // 1. Clipboard first, always — this is the guaranteed path.
    let copied = setClipboard(text, session: session)

    // 2. Best-effort synthetic paste.
    if synthesizePaste(session: session) {
      return .pasted
    }
    return copied ? .clipboardOnly : .failed
  }

  private static func setClipboard(_ text: String, session: SessionType) -> Bool {
    // Wayland-preferred tools, then X11 tools (which also work under XWayland).
    if session != .x11, let wlcopy = Shell.which("wl-copy") {
      return Shell.run(wlcopy, [], stdin: text) == 0
    }
    if let xclip = Shell.which("xclip") {
      return Shell.run(xclip, ["-selection", "clipboard"], stdin: text) == 0
    }
    if let xsel = Shell.which("xsel") {
      return Shell.run(xsel, ["--clipboard", "--input"], stdin: text) == 0
    }
    // Last resort on Wayland if wl-copy wasn't found above.
    if let wlcopy = Shell.which("wl-copy") {
      return Shell.run(wlcopy, [], stdin: text) == 0
    }
    return false
  }

  private static func synthesizePaste(session: SessionType) -> Bool {
    if session == .x11, let xdotool = Shell.which("xdotool") {
      return Shell.run(xdotool, ["key", "--clearmodifiers", "ctrl+v"]) == 0
    }
    // Wayland (and "unknown", which is usually Wayland on a headless-ish env).
    if session != .x11 {
      if let wtype = Shell.which("wtype") {
        // -M ctrl : hold Ctrl; type v; -m ctrl : release Ctrl.
        return Shell.run(wtype, ["-M", "ctrl", "v", "-m", "ctrl"]) == 0
      }
      if let ydotool = Shell.which("ydotool") {
        // evdev keycodes: LEFTCTRL=29, V=47. press ctrl, press+release v, release ctrl.
        return Shell.run(ydotool, ["key", "29:1", "47:1", "47:0", "29:0"]) == 0
      }
    }
    // Under XWayland an X11 app may still be focused; try xdotool if present.
    if let xdotool = Shell.which("xdotool") {
      return Shell.run(xdotool, ["key", "--clearmodifiers", "ctrl+v"]) == 0
    }
    return false
  }
}
#endif
