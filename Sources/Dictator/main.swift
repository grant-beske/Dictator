#if os(macOS)
import AppKit

// Menu-bar-only bootstrap. We rely on LSUIElement=true in Info.plist to hide
// the Dock icon, and additionally set the activation policy to .accessory so
// the same behavior holds even when the binary is run directly (e.g. from a
// terminal during development, before the .app bundle exists).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

#elseif os(Linux)

// Headless daemon bootstrap. There is no menu bar / tray on Linux (see
// Sources/Dictator/Linux/); the process runs in the background, is toggled by a
// desktop keyboard shortcut bound to `dictator toggle`, and gives feedback via
// desktop notifications. Sub-commands (toggle/quit/status) are dispatched inside
// DictatorLinux.main by inspecting CommandLine.arguments.
DictatorLinux.main()

#endif
