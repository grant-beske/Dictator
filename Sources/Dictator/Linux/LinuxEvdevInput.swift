#if os(Linux)
import Foundation
import Glibc

// OPTIONAL true push-to-talk (hold-to-talk) by reading key press/release events
// straight from the kernel's evdev interface (/dev/input/event*). This works
// regardless of X11 vs Wayland because it reads *below* the display server —
// which is exactly why Wayland can't offer a userspace global-hotkey API.
//
// The catch: reading /dev/input requires membership in the `input` group (a
// one-time `sudo usermod -aG input $USER` + re-login). When that access isn't
// available, the daemon falls back to signal/toggle mode automatically. Enable
// this with "linuxInputMode": "evdev" in config.json; pick the hold key with
// "linuxPushToTalkKey" (an EV_KEY code, e.g. 97 = Right Ctrl).
//
// We open every readable event device (a keyboard's key events could come from
// any of them) non-blocking and poll() them from a background thread, emitting
// onStart on key-down and onStop on key-up for the configured code.
final class LinuxEvdevInput {
  var onStart: () -> Void = {}
  var onStop: () -> Void = {}

  private let keyCode: UInt16
  private var fds: [Int32] = []
  private var thread: Thread?
  private var running = false

  // struct input_event on 64-bit Linux: struct timeval time (16 bytes),
  // __u16 type, __u16 code, __s32 value. => 24 bytes; fields at offsets 16/18/20.
  private static let eventSize = MemoryLayout<timeval>.size + 8

  init(keyCode: Int) { self.keyCode = UInt16(truncatingIfNeeded: keyCode) }

  @discardableResult
  func start() -> Bool {
    let dir = "/dev/input"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
      return false
    }
    for name in entries where name.hasPrefix("event") {
      let fd = open("\(dir)/\(name)", O_RDONLY | O_NONBLOCK)
      if fd >= 0 { fds.append(fd) }
    }
    guard !fds.isEmpty else {
      NSLog("Dictator: evdev found no readable /dev/input/event* devices "
          + "(add your user to the 'input' group, then log out and back in)")
      return false
    }
    running = true
    let t = Thread { [weak self] in self?.loop() }
    t.stackSize = 1 << 20
    thread = t
    t.start()
    return true
  }

  func stop() {
    running = false
    for fd in fds { close(fd) }
    fds = []
  }

  private func loop() {
    let size = Self.eventSize
    var buf = [UInt8](repeating: 0, count: size)
    var held = false

    while running {
      var pfds = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
      // Short timeout so we notice `running` flipping to false on stop().
      let ready = poll(&pfds, nfds_t(pfds.count), 300)
      if ready <= 0 { continue }

      for pfd in pfds where (pfd.revents & Int16(POLLIN)) != 0 {
        // Drain every queued event on this fd (non-blocking: read returns -1 /
        // EAGAIN when empty, giving n < size, which breaks the inner loop).
        while true {
          let n = read(pfd.fd, &buf, size)
          if n < size { break }
          let type  = UInt16(buf[16]) | (UInt16(buf[17]) << 8)
          let code  = UInt16(buf[18]) | (UInt16(buf[19]) << 8)
          let value = Int32(buf[20]) | (Int32(buf[21]) << 8)
                    | (Int32(buf[22]) << 16) | (Int32(buf[23]) << 24)
          guard type == 1, code == keyCode else { continue }   // EV_KEY only
          if value == 1 && !held {          // key down (value 2 == autorepeat)
            held = true
            DispatchQueue.main.async { self.onStart() }
          } else if value == 0 && held {    // key up
            held = false
            DispatchQueue.main.async { self.onStop() }
          }
        }
      }
    }
  }
}
#endif
