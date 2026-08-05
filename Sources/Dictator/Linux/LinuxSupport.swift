#if os(Linux)
import Foundation
import Glibc

// Small helpers shared by the Linux implementation. The Linux port deliberately
// links no C libraries: every OS interaction is done by shelling out to a
// standard desktop tool (parecord, wl-copy, xdotool, playerctl, notify-send, …),
// which keeps the binary trivial to build from source and dependency-free.

enum Shell {
  // Resolve an executable name to an absolute path by searching PATH. An
  // absolute path is returned only if it's actually executable.
  static func which(_ name: String) -> String? {
    if name.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for dir in path.split(separator: ":") where !dir.isEmpty {
      let full = "\(dir)/\(name)"
      if FileManager.default.isExecutableFile(atPath: full) { return full }
    }
    return nil
  }

  // First of `names` that exists on PATH (returns the bare name), or nil.
  static func firstAvailable(_ names: [String]) -> String? {
    names.first { which($0) != nil }
  }

  // Retains detached processes (and their stdin pipes) so they aren't torn down
  // before the child consumes stdin. Pruned on each runDetached call.
  private static var detached: [Process] = []
  private static let detachedLock = NSLock()

  // Run a command to completion, but NEVER block indefinitely: if it outlives
  // `timeout` it's SIGKILLed and we return -2. (A hung external tool must not be
  // able to wedge a caller — this is what froze the daemon before.) If `stdin` is
  // given it's written to the child's standard input, then closed. Returns the
  // exit status, -1 on spawn error, or -2 on timeout.
  @discardableResult
  static func run(_ exe: String, _ args: [String], stdin: String? = nil,
                  timeout: Double = 8.0) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    // Keep child chatter out of our own stdout/stderr.
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let inPipe: Pipe?
    if stdin != nil {
      let pipe = Pipe()
      p.standardInput = pipe
      inPipe = pipe
    } else {
      inPipe = nil
    }
    do { try p.run() } catch {
      NSLog("Dictator: failed to run \(exe): \(error)")
      return -1
    }
    if let inPipe = inPipe, let data = stdin?.data(using: .utf8) {
      inPipe.fileHandleForWriting.write(data)
      inPipe.fileHandleForWriting.closeFile()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if p.isRunning {
      NSLog("Dictator: \((exe as NSString).lastPathComponent) exceeded \(timeout)s — killing")
      kill(p.processIdentifier, SIGKILL)
      return -2
    }
    return p.terminationStatus
  }

  // Launch a tool, feed it stdin, and DON'T wait — for clipboard owners (wl-copy,
  // xclip, xsel) that must KEEP RUNNING to serve the selection, so waiting for
  // them to "finish" would block forever. Returns true if it launched.
  @discardableResult
  static func runDetached(_ exe: String, _ args: [String], stdin: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let inPipe = Pipe()
    p.standardInput = inPipe
    do { try p.run() } catch {
      NSLog("Dictator: failed to run \(exe): \(error)")
      return false
    }
    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
    inPipe.fileHandleForWriting.closeFile()
    detachedLock.lock()
    detached.removeAll { !$0.isRunning }   // reap finished selection owners
    detached.append(p)
    detachedLock.unlock()
    return true
  }

  // Run a command and capture its trimmed stdout (empty string on failure).
  static func capture(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  // Launch a command without waiting (fire-and-forget). Returns the Process so
  // the caller can stop it later; nil on spawn failure.
  @discardableResult
  static func spawn(_ exe: String, _ args: [String]) -> Process? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); return p } catch {
      NSLog("Dictator: failed to spawn \(exe): \(error)")
      return nil
    }
  }
}

// The active display server. Governs how we set the clipboard and synthesize the
// paste keystroke (the two mechanisms that differ most between X11 and Wayland).
enum SessionType: String {
  case wayland, x11, unknown

  static func detect() -> SessionType {
    let env = ProcessInfo.processInfo.environment
    switch env["XDG_SESSION_TYPE"]?.lowercased() {
    case "wayland": return .wayland
    case "x11":     return .x11
    default:        break
    }
    if env["WAYLAND_DISPLAY"] != nil { return .wayland }
    if env["DISPLAY"] != nil { return .x11 }
    return .unknown
  }
}

// Desktop notifications via notify-send (best-effort; silent if not installed).
enum Notify {
  private static let tool = Shell.which("notify-send")

  static func show(_ title: String, _ body: String = "") {
    guard let tool = tool else { return }
    // Fire-and-forget: a slow notification daemon must never delay the pipeline.
    Shell.spawn(tool, ["-a", "Dictator", "-t", "2500", title, body])
  }
}

// Runtime paths for the control channel (PID file used to signal the daemon).
enum LinuxPaths {
  static var runtimeDir: String {
    let env = ProcessInfo.processInfo.environment
    if let dir = env["XDG_RUNTIME_DIR"], !dir.isEmpty { return dir }
    return "/tmp"
  }

  static var pidFile: String { "\(runtimeDir)/dictator.pid" }
}
#endif
