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
//
// Every branch logs which tool it used (or couldn't find), because "nothing was
// pasted" on Linux is almost always a missing/blocked clipboard tool.
enum LinuxTextInserter {
  enum Result { case pasted, clipboardOnly, failed }

  @discardableResult
  static func insert(_ text: String) -> Result {
    let session = SessionType.detect()
    NSLog("Dictator: insert \(text.count) chars (session=\(session.rawValue))")

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
    var order: [(String, [String])] = []
    if session != .x11 { order.append(("wl-copy", [])) }
    order.append(("xclip", ["-selection", "clipboard"]))
    order.append(("xsel", ["--clipboard", "--input"]))
    if session == .x11 { order.append(("wl-copy", [])) }   // XWayland edge case

    for (tool, args) in order {
      guard let path = Shell.which(tool) else { continue }
      let rc = Shell.run(path, args, stdin: text)
      if rc == 0 {
        NSLog("Dictator: clipboard set via \(tool)")
        return true
      }
      NSLog("Dictator: \(tool) failed (exit \(rc))")
    }
    NSLog("Dictator: NO clipboard tool found — install wl-clipboard (Wayland) or xclip (X11)")
    return false
  }

  private static func synthesizePaste(session: SessionType) -> Bool {
    if session == .x11, let xdotool = Shell.which("xdotool") {
      if Shell.run(xdotool, ["key", "--clearmodifiers", "ctrl+v"]) == 0 {
        NSLog("Dictator: pasted via xdotool"); return true
      }
    }
    if session != .x11 {
      if let wtype = Shell.which("wtype") {
        // -M ctrl : hold Ctrl; type v; -m ctrl : release Ctrl.
        if Shell.run(wtype, ["-M", "ctrl", "v", "-m", "ctrl"]) == 0 {
          NSLog("Dictator: pasted via wtype"); return true
        }
      }
      if let ydotool = Shell.which("ydotool") {
        // evdev keycodes: LEFTCTRL=29, V=47. press ctrl, press+release v, release ctrl.
        if Shell.run(ydotool, ["key", "29:1", "47:1", "47:0", "29:0"]) == 0 {
          NSLog("Dictator: pasted via ydotool"); return true
        }
      }
    }
    // Under XWayland an X11 app may still be focused; try xdotool if present.
    if session != .x11, let xdotool = Shell.which("xdotool") {
      if Shell.run(xdotool, ["key", "--clearmodifiers", "ctrl+v"]) == 0 {
        NSLog("Dictator: pasted via xdotool (XWayland)"); return true
      }
    }
    NSLog("Dictator: no synthetic-paste tool (on GNOME Wayland this is expected — press Ctrl+V)")
    return false
  }
}
#endif
