#if os(Linux)
import Foundation
import Glibc

// Records microphone audio to a 16 kHz / 16-bit / mono WAV — exactly what
// whisper.cpp expects — by driving a standard command-line recorder rather than
// linking an audio library. We pick the first backend that's installed:
//
//   parecord  (pulseaudio-utils; works against PipeWire's Pulse shim too)
//   pw-record (pipewire tools)
//   ffmpeg    (Pulse input)
//   arecord   (alsa-utils; raw ALSA fallback)
//
// stop() sends SIGINT so these tools finalize the WAV header (patch the RIFF/data
// sizes) before they exit, escalating to SIGKILL only if one ignores us. It can
// block for up to a couple of seconds, so it MUST be called off the daemon's main
// thread — blocking the main queue freezes the whole event loop.
final class LinuxAudioRecorder {
  private var process: Process?
  private var stderrURL: URL?
  private var stderrHandle: FileHandle?
  private(set) var isRecording = false

  private static func command(for file: String) -> (String, [String])? {
    if let p = Shell.which("parecord") {
      return (p, ["--rate=16000", "--channels=1", "--format=s16le",
                  "--file-format=wav", file])
    }
    if let p = Shell.which("pw-record") {
      return (p, ["--rate=16000", "--channels=1", "--format=s16", file])
    }
    if let p = Shell.which("ffmpeg") {
      return (p, ["-hide_banner", "-loglevel", "error",
                  "-f", "pulse", "-i", "default",
                  "-ar", "16000", "-ac", "1", "-sample_fmt", "s16",
                  "-y", file])
    }
    if let p = Shell.which("arecord") {
      return (p, ["-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "wav", file])
    }
    return nil
  }

  static var backendName: String? {
    ["parecord", "pw-record", "ffmpeg", "arecord"].first { Shell.which($0) != nil }
  }

  @discardableResult
  func start(to url: URL) -> Bool {
    guard !isRecording else { return true }
    guard let (exe, args) = Self.command(for: url.path) else {
      NSLog("Dictator: no audio recorder found — install one of "
          + "pulseaudio-utils, pipewire(-bin), ffmpeg, or alsa-utils")
      return false
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    // Capture stderr to a temp FILE (read back after exit), NOT a live pipe with a
    // readabilityHandler — the latter can deadlock the process wait on Linux.
    let errURL = url.deletingPathExtension().appendingPathExtension("stderr")
    _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let errHandle = try? FileHandle(forWritingTo: errURL)
    p.standardError = errHandle ?? FileHandle.nullDevice
    do {
      try p.run()
    } catch {
      NSLog("Dictator: failed to launch recorder \(exe): \(error)")
      try? errHandle?.close()
      try? FileManager.default.removeItem(at: errURL)
      return false
    }
    process = p
    stderrURL = errURL
    stderrHandle = errHandle
    isRecording = true
    NSLog("Dictator: recorder \((exe as NSString).lastPathComponent) launched (pid \(p.processIdentifier))")
    return true
  }

  // Blocks (up to ~3s) until the recorder flushes + exits. CALL OFF THE MAIN THREAD.
  func stop() {
    guard isRecording, let p = process else { return }
    isRecording = false
    p.interrupt()                                 // SIGINT: recorder finalizes the WAV
    if !waitForExit(p, timeout: 2.0) {
      NSLog("Dictator: recorder ignored SIGINT after 2s — sending SIGKILL")
      kill(p.processIdentifier, SIGKILL)
      _ = waitForExit(p, timeout: 1.0)
    }
    let status = p.isRunning ? "still running" : "\(p.terminationStatus)"
    NSLog("Dictator: recorder exited (status \(status))")

    // Surface anything the recorder printed to stderr (no audio server, bad
    // device, …) — this is where a silent recording failure explains itself.
    try? stderrHandle?.close()
    if let errURL = stderrURL,
       let data = try? Data(contentsOf: errURL),
       let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      NSLog("Dictator: recorder stderr: \(text)")
    }
    if let errURL = stderrURL { try? FileManager.default.removeItem(at: errURL) }
    stderrHandle = nil
    stderrURL = nil
    process = nil
  }

  // Poll for exit instead of Process.waitUntilExit() (which can hang on Linux and
  // would give a stuck recorder no upper time bound).
  private func waitForExit(_ p: Process, timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    return !p.isRunning
  }
}
#endif
