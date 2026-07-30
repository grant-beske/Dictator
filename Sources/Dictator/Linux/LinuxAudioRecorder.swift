#if os(Linux)
import Foundation

// Records microphone audio to a 16 kHz / 16-bit / mono WAV — exactly what
// whisper.cpp expects — by driving a standard command-line recorder rather than
// linking an audio library. We pick the first backend that's installed:
//
//   parecord  (pulseaudio-utils; works against PipeWire's Pulse shim too)
//   pw-record (pipewire tools)
//   ffmpeg    (Pulse input)
//   arecord   (alsa-utils; raw ALSA fallback)
//
// Stopping sends SIGINT (Process.interrupt), which lets these tools finalize the
// WAV header (patch the RIFF/data sizes) before they exit, so the file whisper
// reads back is valid.
final class LinuxAudioRecorder {
  private var process: Process?
  private var errFileHandle: FileHandle?
  private(set) var isRecording = false

  // Returns (executable, args) for the first available backend, or nil if none.
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

  // Human-readable name of the backend that would be used (for the startup log).
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
    // Surface the recorder's own errors (no audio server, bad device, …) to our
    // log instead of swallowing them — this is where "recording did nothing"
    // usually explains itself.
    let errPipe = Pipe()
    p.standardError = errPipe
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { NSLog("Dictator: recorder(\((exe as NSString).lastPathComponent)): \(trimmed)") }
    }
    do {
      try p.run()
    } catch {
      NSLog("Dictator: failed to launch recorder \(exe): \(error)")
      return false
    }
    process = p
    errFileHandle = errPipe.fileHandleForReading
    isRecording = true
    NSLog("Dictator: recorder \((exe as NSString).lastPathComponent) launched (pid \(p.processIdentifier))")
    return true
  }

  func stop() {
    guard isRecording, let p = process else { return }
    p.interrupt()          // SIGINT: recorder finalizes the WAV header, then exits
    p.waitUntilExit()
    errFileHandle?.readabilityHandler = nil
    errFileHandle = nil
    NSLog("Dictator: recorder exited (status \(p.terminationStatus))")
    process = nil
    isRecording = false
  }
}
#endif
