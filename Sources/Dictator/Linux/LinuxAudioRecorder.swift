#if os(Linux)
import Foundation
import Glibc

// Records microphone audio for whisper.cpp by driving a standard command-line
// recorder — but as HEADERLESS raw PCM (S16LE, 16 kHz, mono). We write the WAV
// header ourselves in stop(), so the resulting file is ALWAYS valid no matter how
// the recorder process ended.
//
// Why not let the recorder write the WAV directly? Because a WAV's RIFF/data size
// fields are only patched in when the tool exits cleanly, and parecord did NOT
// exit on our stop signal in time — it got SIGKILLed, leaving an unfinalized
// header that whisper-server rejects with HTTP 400. Recording raw + adding our own
// header removes that whole failure mode (SIGKILL becomes harmless: the PCM the
// kernel already flushed to the file is all we need).
//
// Backends, first installed wins:
//   parecord  (pulseaudio-utils; works against PipeWire's Pulse shim too)
//   pw-record (pipewire tools)
//   ffmpeg    (Pulse input)
//   arecord   (alsa-utils)
//
// stop() can block ~1s waiting for the recorder to flush + exit, so it MUST be
// called off the daemon's main thread.
final class LinuxAudioRecorder {
  private var process: Process?
  private var rawURL: URL?
  private var wavURL: URL?
  private var stderrURL: URL?
  private var stderrHandle: FileHandle?
  private(set) var isRecording = false

  private static let sampleRate: UInt32 = 16_000

  // (executable, args) writing raw S16LE 16 kHz mono PCM to `raw`.
  private static func command(for raw: String) -> (String, [String])? {
    if let p = Shell.which("parecord") {
      // --latency-msec=30 forces parecord to flush to the file every ~30 ms.
      // Without it, parecord buffers a large chunk and a short (<~2 s) hold is
      // lost entirely when the process is killed — you'd get a 0-byte capture.
      return (p, ["--raw", "--latency-msec=30", "--rate=16000", "--channels=1",
                  "--format=s16le", raw])
    }
    if let p = Shell.which("pw-record") {
      return (p, ["--raw", "--rate=16000", "--channels=1", "--format=s16", raw])
    }
    if let p = Shell.which("ffmpeg") {
      return (p, ["-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", "default",
                  "-ar", "16000", "-ac", "1", "-f", "s16le", "-y", raw])
    }
    if let p = Shell.which("arecord") {
      return (p, ["-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", raw])
    }
    return nil
  }

  static var backendName: String? {
    ["parecord", "pw-record", "ffmpeg", "arecord"].first { Shell.which($0) != nil }
  }

  @discardableResult
  func start(to url: URL) -> Bool {
    guard !isRecording else { return true }
    let raw = url.deletingPathExtension().appendingPathExtension("raw")
    guard let (exe, args) = Self.command(for: raw.path) else {
      NSLog("Dictator: no audio recorder found — install one of "
          + "pulseaudio-utils, pipewire(-bin), ffmpeg, or alsa-utils")
      return false
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    // Capture stderr to a temp FILE (read after exit), NOT a live pipe with a
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
    rawURL = raw
    wavURL = url
    stderrURL = errURL
    stderrHandle = errHandle
    isRecording = true
    NSLog("Dictator: recorder \((exe as NSString).lastPathComponent) launched (pid \(p.processIdentifier))")
    return true
  }

  // Stop the recorder and write a valid WAV at the URL passed to start().
  // CALL OFF THE MAIN THREAD (blocks up to ~1.5s).
  func stop() {
    guard isRecording, let p = process else { return }
    isRecording = false
    // SIGTERM first (clean), then SIGKILL quickly. With --latency-msec the PCM is
    // already flushed to the file continuously, so a hard kill costs only ~30 ms
    // of audio — no need to wait long for a recorder that's slow to exit (parecord
    // via the PipeWire-Pulse shim often is).
    kill(p.processIdentifier, SIGTERM)
    if !waitForExit(p, timeout: 0.4) {
      kill(p.processIdentifier, SIGKILL)
      _ = waitForExit(p, timeout: 0.4)
    }
    let status = p.isRunning ? "still running" : "\(p.terminationStatus)"

    try? stderrHandle?.close()
    logStderr()
    let pcmBytes = wrapRawAsWav()   // <- WAV validity no longer depends on the exit
    NSLog("Dictator: recorder stopped (exit \(status)); captured \(pcmBytes) PCM bytes")

    process = nil; rawURL = nil; wavURL = nil; stderrURL = nil; stderrHandle = nil
  }

  // Read the raw PCM and write `wavURL` = 44-byte WAV header + PCM. Returns the
  // number of PCM bytes (0 if nothing was captured).
  private func wrapRawAsWav() -> Int {
    guard let rawURL = rawURL, let wavURL = wavURL else { return 0 }
    defer { try? FileManager.default.removeItem(at: rawURL) }
    guard let pcm = try? Data(contentsOf: rawURL) else { return 0 }

    let dataSize = UInt32(truncatingIfNeeded: pcm.count)
    let sr = Self.sampleRate
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(Data("RIFF".utf8)); u32(36 &+ dataSize); d.append(Data("WAVE".utf8))
    d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)          // PCM, mono
    u32(sr); u32(sr &* 2); u16(2); u16(16)                        // byterate, block align, bits
    d.append(Data("data".utf8)); u32(dataSize)
    d.append(pcm)
    try? d.write(to: wavURL)
    return pcm.count
  }

  private func logStderr() {
    guard let errURL = stderrURL else { return }
    defer { try? FileManager.default.removeItem(at: errURL) }
    if let data = try? Data(contentsOf: errURL),
       let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      NSLog("Dictator: recorder stderr: \(text)")
    }
  }

  // Poll for exit instead of Process.waitUntilExit() (which can hang on Linux).
  private func waitForExit(_ p: Process, timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    return !p.isRunning
  }
}
#endif
