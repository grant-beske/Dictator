import AppKit
import AVFoundation
import ApplicationServices

// Centralizes the two TCC-gated capabilities this app needs:
//  - Accessibility: required for a CGEvent tap (global hotkey) AND for
//    synthesizing the Cmd+V paste keystroke.
//  - Microphone:    required by AVAudioEngine to capture input.
//
// We never fail silently: when a permission is missing we show an alert that
// names the exact System Settings pane and offers to open it.
enum Permissions {

  // MARK: Accessibility

  // AXIsProcessTrusted() is a pure check (no prompt). Passing the
  // kAXTrustedCheckOptionPrompt option makes macOS show its own system prompt
  // and register the app in the Accessibility list, which is what we want on
  // first run so the user can find us in the list.
  static func hasAccessibility(prompt: Bool = false) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  // MARK: Microphone

  static func micAuthorized() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  // Triggers the system mic prompt the first time; later calls just report
  // the stored decision via the completion handler.
  static func requestMic(_ completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default:
      completion(false)
    }
  }

  // MARK: Settings deep-links + alerts

  // These x-apple.systempreferences URLs jump straight to the relevant
  // Privacy & Security pane on modern macOS.
  static func openAccessibilitySettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  static func openMicrophoneSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
  }

  private static func open(_ urlString: String) {
    if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
  }

  // Modal alert that names the pane and opens it on the primary button.
  static func showMissingPermissionAlert(title: String,
                                         message: String,
                                         openSettings: @escaping () -> Void) {
    // Bring the (otherwise dockless) app forward so the alert is visible.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
      openSettings()
    }
  }
}
