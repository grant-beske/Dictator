import AppKit
import CoreGraphics

// Global hotkey handling via a CGEvent tap.
//
// Why a CGEvent tap rather than NSEvent global monitors or Carbon
// RegisterEventHotKey:
//  - NSEvent global monitors are notoriously flaky for modifier-only
//    press/release (especially distinguishing left vs. right Option) and
//    cannot swallow events.
//  - Carbon hotkeys can't observe a *held* modifier key for push-to-talk.
//  - A session-level CGEvent tap sees flagsChanged (modifier transitions) and
//    keyDown reliably, lets us tell Right Option (keycode 61) from Left Option
//    (58), and lets us swallow the toggle chord so it doesn't type a "d".
//
// The tap requires Accessibility permission; tapCreate returns nil without it.
final class HotkeyManager {
  enum Mode { case pushToTalk, toggle }

  // Callbacks fire on the main thread.
  var onStart: () -> Void = {}
  var onStop: () -> Void = {}
  var onToggle: () -> Void = {}

  private var mode: Mode = .pushToTalk
  // Bitmask of device-dependent modifier bits that must ALL be held for
  // push-to-talk (see deviceMask(from:)). 0 means "nothing configured".
  private var pttMask: UInt64 = 0
  private var toggleKeyCode: Int64 = 2
  private var requiredFlags: CGEventFlags = [.maskControl, .maskAlternate]

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  // Tracks whether the push-to-talk key is currently held, so we emit exactly
  // one onStart per press and one onStop per release.
  private var pttActive = false

  func configure(mode: Mode,
                 pushToTalkModifiers: [String],
                 toggleKeyCode: Int,
                 toggleModifiers: [String]) {
    self.mode = mode
    self.pttMask = Self.deviceMask(from: pushToTalkModifiers)
    self.toggleKeyCode = Int64(toggleKeyCode)
    self.requiredFlags = Self.flags(from: toggleModifiers)
  }

  // Device-dependent (left/right-specific) modifier bits, which live in the low
  // bytes of CGEventFlags.rawValue. Unlike .maskCommand/.maskAlternate (which
  // can't tell the two Command/Option keys apart), these distinguish sides — so
  // we can require *Right* Command + *Right* Option and ignore the left ones.
  private static let deviceBits: [String: UInt64] = [
    "leftcontrol":  0x00000001,
    "leftshift":    0x00000002,
    "rightshift":   0x00000004,
    "leftcommand":  0x00000008,
    "rightcommand": 0x00000010,
    "leftoption":   0x00000020,
    "rightoption":  0x00000040,
    "rightcontrol": 0x00002000
  ]

  private static func deviceMask(from names: [String]) -> UInt64 {
    var mask: UInt64 = 0
    for name in names {
      if let bit = deviceBits[name.lowercased()] { mask |= bit }
    }
    return mask
  }

  private static func flags(from names: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for name in names {
      switch name.lowercased() {
      case "command", "cmd": f.insert(.maskCommand)
      case "control", "ctrl": f.insert(.maskControl)
      case "option", "alt": f.insert(.maskAlternate)
      case "shift": f.insert(.maskShift)
      default: break
      }
    }
    return f
  }

  // Returns false if the tap could not be created (i.e. Accessibility not yet
  // granted). The caller should prompt and retry.
  @discardableResult
  func start() -> Bool {
    stop()  // idempotent

    let mask = (1 << CGEventType.keyDown.rawValue)
             | (1 << CGEventType.flagsChanged.rawValue)

    // The C callback can't capture Swift context, so we pass `self` through the
    // userInfo refcon and recover it inside the trampoline below.
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
      let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
      return manager.handle(type: type, event: event)
    }

    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,            // session-wide
      place: .headInsertEventTap,
      options: .defaultTap,               // .defaultTap lets us swallow events
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      return false  // no Accessibility permission
    }

    eventTap = tap
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  func stop() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    runLoopSource = nil
    eventTap = nil
    pttActive = false
  }

  // Core tap callback. Returning the event passes it through; returning nil
  // swallows it (used for the toggle chord only).
  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // The system disables a tap if our callback is too slow or on certain
    // input events; re-enable it so the hotkey keeps working.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }

    switch mode {
    case .pushToTalk:
      // flagsChanged fires on every modifier transition. We check whether ALL
      // required device bits (e.g. Right Command AND Right Option) are held:
      //   - all held & not yet recording  -> start
      //   - recording & any one released  -> stop
      // Using device bits makes "right keys only" reliable and handles a chord
      // of any size with one comparison.
      if type == .flagsChanged && pttMask != 0 {
        let allHeld = (event.flags.rawValue & pttMask) == pttMask
        if allHeld && !pttActive {
          pttActive = true
          DispatchQueue.main.async { self.onStart() }
        } else if !allHeld && pttActive {
          pttActive = false
          DispatchQueue.main.async { self.onStop() }
        }
      }
      // Push-to-talk is intended for modifier keys (we observe flagsChanged).
      // To hold a non-modifier key, use "toggle" mode instead.

    case .toggle:
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      if type == .keyDown && keyCode == toggleKeyCode {
        // Match only the modifiers we require; ignore caps lock / fn noise.
        let mods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if event.flags.intersection(mods) == requiredFlags {
          DispatchQueue.main.async { self.onToggle() }
          return nil  // swallow so the chord doesn't type its base character
        }
      }
    }

    return Unmanaged.passUnretained(event)
  }
}
