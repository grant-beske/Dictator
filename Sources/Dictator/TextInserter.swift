import AppKit
import CoreGraphics

// Inserts text at the current cursor in whatever app has focus by:
//   1. placing the transcript on the pasteboard,
//   2. synthesizing Cmd+V.
//
// The transcript is intentionally LEFT on the clipboard afterwards: if the wrong
// field was focused (or nothing was), you can just paste it again manually. This
// trades away preserving your previous clipboard for that safety net.
//
// Pasting is far more reliable than synthesizing each character (which breaks on
// non-ASCII, dead keys, and input-method state) and is faster for long text.
enum TextInserter {

  static func insert(_ text: String) {
    let pasteboard = NSPasteboard.general

    // 1. Put the transcript on the pasteboard (and leave it there).
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    // 2. Synthesize Cmd+V. virtualKey 9 == "V". We use a private event source
    // and post to the HID tap so the keystroke reaches the focused app exactly
    // like a real one. (Requires Accessibility permission.)
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 9
    if let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
       let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
      down.flags = .maskCommand
      up.flags = .maskCommand
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
  }
}
