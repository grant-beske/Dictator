#if os(Linux)
import Foundation
import Glibc
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Write end of the self-pipe (see LinuxDaemon.installSignalHandlers). File-scope
// because a C signal handler can't capture Swift context. -1 until installed.
private var gSignalWriteFD: Int32 = -1

// Async-signal-safe signal handler: write the signal number into the pipe and
// return. All real work happens on the main queue in the read source's handler.
private func dictatorSignalHandler(_ signum: Int32) {
  var byte = UInt8(truncatingIfNeeded: signum)
  _ = write(gSignalWriteFD, &byte, 1)
}

// Entry point for the Linux build (called from main.swift). One binary is both
// the daemon and its little CLI client:
//
//   dictator [daemon]   run the background daemon (records, transcribes, pastes)
//   dictator toggle     start/stop recording on the running daemon
//   dictator quit       stop the running daemon
//   dictator status     print whether the daemon is running
//
// `toggle`/`quit` work by signaling the daemon whose PID is in the PID file —
// so you bind a desktop keyboard shortcut to `dictator toggle` and that's your
// global hotkey (see README). No socket server, no privileges.
enum DictatorLinux {
  // Retained for the whole process lifetime so the daemon's weak self-captures
  // (signal sources, async tasks) stay valid while dispatchMain() runs forever.
  private static var daemon: LinuxDaemon?

  static func main() {
    let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "daemon"
    switch cmd {
    case "daemon":
      let d = LinuxDaemon()
      daemon = d
      d.runDaemon()
    case "toggle":
      LinuxDaemon.clientSignal(SIGUSR1, action: "toggle")
    case "quit", "stop":
      LinuxDaemon.clientSignal(SIGTERM, action: "quit")
    case "status":
      LinuxDaemon.clientStatus()
    case "help", "-h", "--help":
      printUsage()
    default:
      FileHandle.standardError.write(Data("Unknown command: \(cmd)\n".utf8))
      printUsage()
      exit(2)
    }
  }

  static func printUsage() {
    let text = """
    Dictator — local push-to-talk dictation (Linux)

    Usage:
      dictator [daemon]   Run the background daemon (default).
      dictator toggle     Start/stop recording (bind this to a keyboard shortcut).
      dictator quit       Stop the running daemon.
      dictator status     Report whether the daemon is running.

    Config: ~/.config/dictator/config.json
    """
    print(text)
  }
}

final class LinuxDaemon {
  private enum State { case idle, recording, transcribing }
  private var state: State = .idle

  private var config = Config.default
  private let recorder = LinuxAudioRecorder()
  private let sounds = LinuxSoundPlayer()
  private let media = LinuxMedia()
  private var server: WhisperServer!
  private var transcriber: Transcriber!
  private var evdev: LinuxEvdevInput?
  private var currentWavURL: URL?
  private var signalReadSource: DispatchSourceRead?
  // Media pause/resume runs here (off the main thread, serialized) so a slow
  // playerctl/D-Bus call can never block the daemon's event loop.
  private let mediaQueue = DispatchQueue(label: "dictator.media")

  // MARK: Daemon lifecycle

  func runDaemon() {
    if let existing = LinuxDaemon.readPid() {
      FileHandle.standardError.write(Data(
        "Dictator is already running (pid \(existing)). Use `dictator toggle`.\n".utf8))
      exit(1)
    }

    config = ConfigStore.load()
    server = WhisperServer(modelPath: config.resolvedModelPath,
                           port: config.serverPort,
                           language: config.language,
                           beamSize: config.beamSize,
                           bestOf: config.bestOf,
                           noTimestamps: config.noTimestamps)
    transcriber = Transcriber(port: config.serverPort, language: config.language,
                              initialPrompt: config.initialPrompt)
    sounds.enabled = config.soundsEnabled
    sounds.ensureDirectory()

    writePidFile()
    installSignalHandlers()
    startInput()

    // Kill any whisper-server left over from a previous daemon that didn't shut
    // down cleanly (e.g. a `kill -9`). Otherwise the orphan keeps holding GPU
    // VRAM and our fresh server hits cudaMalloc OOM and crash-loops.
    killStaleServers()
    server.start()
    prewarmServer()

    logBanner()
    Notify.show("Dictator ready", inputHint)

    // Never returns. Services the main queue: signal sources (toggle/quit) and
    // the DispatchQueue.main hops from the async transcription task.
    dispatchMain()
  }

  private func shutdown() -> Never {
    NSLog("Dictator: shutting down")
    if state == .recording { recorder.stop() }
    evdev?.stop()
    server?.stop()               // terminate whisper-server so it frees GPU VRAM
    LinuxDaemon.removePidFile()
    exit(0)
  }

  // Kill any whisper-server left over from a previous daemon that didn't exit
  // cleanly (a `kill -9`, a crash). An orphan keeps holding GPU VRAM, which on a
  // small card (e.g. a 4 GB Quadro) makes our fresh server OOM and crash-loop.
  private func killStaleServers() {
    guard let pkill = Shell.which("pkill") else { return }
    if Shell.run(pkill, ["-f", "whisper-server"], timeout: 3.0) == 0 {
      NSLog("Dictator: killed leftover whisper-server(s); waiting for VRAM to free")
      Thread.sleep(forTimeInterval: 0.5)   // let the GPU release the memory
    }
  }

  // MARK: Input wiring

  private func startInput() {
    // evdev push-to-talk is opt-in and best-effort; signal/toggle always works.
    if config.linuxInputMode.lowercased() == "evdev" {
      let ev = LinuxEvdevInput(keyCode: config.linuxPushToTalkKey)
      ev.onStart = { [weak self] in self?.startRecording() }
      ev.onStop  = { [weak self] in self?.stopAndTranscribe() }
      if ev.start() {
        evdev = ev
        NSLog("Dictator: evdev push-to-talk armed on key code \(config.linuxPushToTalkKey)")
      } else {
        NSLog("Dictator: evdev unavailable — using toggle mode "
            + "(bind a shortcut to `dictator toggle`)")
      }
    }
  }

  // MARK: Signals (control channel)

  // We deliberately do NOT use DispatchSource.makeSignalSource here. On Linux,
  // that combined with signal(sig, SIG_IGN) is unreliable — an ignored signal
  // can be discarded by the kernel before the source ever observes it, so the
  // daemon would never react to `dictator toggle` (the exact bug this fixes).
  //
  // Instead we use the classic "self-pipe" trick: a plain C signal handler (the
  // top-level dictatorSignalHandler) writes the signal number into a pipe, and a
  // DispatchSource READ source — which is rock-solid on Linux — drains it on the
  // main queue and does the real work. write()/read() on a pipe are the only
  // async-signal-safe primitives involved.
  private func installSignalHandlers() {
    var fds = [Int32](repeating: 0, count: 2)
    guard pipe(&fds) == 0 else {
      NSLog("Dictator: FATAL could not create signal pipe (errno \(errno))")
      return
    }
    let readFD = fds[0]
    gSignalWriteFD = fds[1]
    // Non-blocking read end so draining never stalls the main queue.
    _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL, 0) | O_NONBLOCK)

    // Install real handlers (NOT SIG_IGN) that just poke the pipe.
    signal(SIGUSR1, dictatorSignalHandler)
    signal(SIGTERM, dictatorSignalHandler)
    signal(SIGINT, dictatorSignalHandler)

    let src = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .main)
    src.setEventHandler { [weak self] in
      guard let self = self else { return }
      var buf = [UInt8](repeating: 0, count: 64)
      let n = read(readFD, &buf, buf.count)
      guard n > 0 else { return }
      for i in 0..<n {
        if Int32(buf[i]) == SIGUSR1 {
          self.toggle()
        } else {
          self.shutdown()   // SIGTERM / SIGINT
        }
      }
    }
    src.resume()
    signalReadSource = src
    NSLog("Dictator: control channel ready (SIGUSR1=toggle, SIGTERM/SIGINT=quit)")
  }

  private func toggle() {
    NSLog("Dictator: toggle received (state=\(state))")
    switch state {
    case .idle:         startRecording()
    case .recording:    stopAndTranscribe()
    case .transcribing: break   // busy; ignore
    }
  }

  // MARK: Recording pipeline (mirrors AppDelegate on macOS)

  private func startRecording() {
    guard state == .idle else {
      NSLog("Dictator: startRecording ignored (state=\(state))")
      return
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dictator-\(UUID().uuidString).wav")
    NSLog("Dictator: starting recording via \(LinuxAudioRecorder.backendName ?? "NONE")")
    guard recorder.start(to: url) else {
      NSLog("Dictator: ERROR could not start the audio recorder")
      Notify.show("Dictator", "No microphone recorder available (see logs)")
      return
    }
    currentWavURL = url
    state = .recording
    // Pause media off the main thread (playerctl/D-Bus can be slow) and only
    // after recording actually started, so a failed start never leaves it paused.
    if config.pauseMediaWhileRecording {
      mediaQueue.async { [weak self] in self?.media.pauseIfPlaying() }
    }
    sounds.play(.start)
    Notify.show("🎙 Recording…")
    NSLog("Dictator: recording — toggle again to stop")
  }

  private func stopAndTranscribe() {
    guard state == .recording else { return }
    // Flip state on the main thread FIRST so the event loop stays responsive and
    // further toggles/evdev events are treated as "busy". The blocking recorder
    // stop AND the network transcription then happen entirely off the main queue
    // — doing recorder.stop() on main was what froze the daemon after one toggle.
    state = .transcribing
    sounds.play(.stop)
    Notify.show("⏳ Transcribing…")

    guard let url = currentWavURL else { state = .idle; return }
    currentWavURL = nil
    if config.pauseMediaWhileRecording {
      mediaQueue.async { [weak self] in self?.media.resumeIfPaused() }
    }

    Task { [weak self] in
      guard let self = self else { return }
      defer { try? FileManager.default.removeItem(at: url) }   // always clean up temp WAV
      // recorder.stop() blocks ~0.4s (kills the recorder + builds the WAV).
      self.recorder.stop()
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
      let size = (attrs?[.size] as? Int) ?? 0
      // A 44-byte file is a header with no audio (hold too short to capture any) —
      // don't POST it (whisper-server would 400) and tell the user why.
      guard size > 44 else {
        NSLog("Dictator: no audio captured (\(size) bytes) — hold the key a moment longer")
        Notify.show("Dictator", "No audio captured — hold the key a moment longer")
        DispatchQueue.main.async { self.state = .idle }
        return
      }
      NSLog("Dictator: transcribing \(url.lastPathComponent) (\(size) bytes)")
      do {
        let text = try await self.transcriber.transcribe(wavURL: url)
        // Insert (clipboard + best-effort paste) HERE, off the main thread. The
        // clipboard owner keeps running to serve the selection, so waiting for it
        // on the main queue is exactly what froze the daemon after a transcription.
        let result = LinuxTextInserter.insert(text)
        DispatchQueue.main.async {
          self.sounds.play(.done)
          switch result {
          case .pasted:        break   // insert() already logged the tool used
          case .clipboardOnly: Notify.show("📋 Copied to clipboard", "Press Ctrl+V to paste")
          case .failed:        Notify.show("Dictator", "Could not access the clipboard")
          }
          self.state = .idle
        }
      } catch {
        NSLog("Dictator: transcription failed: \(error)")
        DispatchQueue.main.async {
          Notify.show("Dictator", "Transcription failed (is whisper-server running?)")
          self.state = .idle
        }
      }
    }
  }

  // MARK: Pre-warm (one throwaway inference so the FIRST dictation isn't slow)

  private func prewarmServer() {
    guard let wav = Self.makeSilentWav() else { return }
    let transcriber = self.transcriber!
    Task.detached {
      defer { try? FileManager.default.removeItem(at: wav) }
      for _ in 0..<40 {
        do {
          _ = try await transcriber.transcribe(wavURL: wav)
          NSLog("Dictator: server prewarmed")
          return
        } catch is Transcriber.TranscribeError {
          NSLog("Dictator: server prewarmed")   // responded (empty for silence) = warm
          return
        } catch {
          try? await Task.sleep(nanoseconds: 500_000_000)   // still starting; retry
        }
      }
    }
  }

  // Build a tiny 16 kHz / 16-bit / mono silent WAV for warmup.
  private static func makeSilentWav(seconds: Double = 0.25) -> URL? {
    let sampleRate = 16_000
    let numSamples = Int(Double(sampleRate) * seconds)
    let dataSize = numSamples * 2
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(Data("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(Data("WAVE".utf8))
    d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(Data("data".utf8)); u32(UInt32(dataSize))
    d.append(Data(count: dataSize))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-prewarm.wav")
    do { try d.write(to: url); return url } catch { return nil }
  }

  // MARK: Startup logging

  private var inputHint: String {
    if evdev != nil {
      return "Hold key code \(config.linuxPushToTalkKey) to dictate."
    }
    return "Bind a keyboard shortcut to `dictator toggle` to dictate."
  }

  private func logBanner() {
    NSLog("Dictator: daemon started (pid \(getpid()))")
    NSLog("Dictator: session=\(SessionType.detect().rawValue) "
        + "recorder=\(LinuxAudioRecorder.backendName ?? "NONE") "
        + "input=\(evdev != nil ? "evdev" : "toggle")")
    if LinuxAudioRecorder.backendName == nil {
      NSLog("Dictator: WARNING no audio recorder installed — dictation will fail")
    }
  }

  // MARK: PID file + client commands

  private func writePidFile() {
    let pid = "\(getpid())\n"
    try? pid.write(toFile: LinuxPaths.pidFile, atomically: true, encoding: .utf8)
  }

  static func removePidFile() {
    try? FileManager.default.removeItem(atPath: LinuxPaths.pidFile)
  }

  // Returns the daemon's PID if the PID file names a live process, else nil
  // (cleaning up a stale file left by a crash).
  static func readPid() -> pid_t? {
    guard let text = try? String(contentsOfFile: LinuxPaths.pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    if kill(pid, 0) == 0 { return pid }        // process exists
    try? FileManager.default.removeItem(atPath: LinuxPaths.pidFile)   // stale
    return nil
  }

  static func clientSignal(_ sig: Int32, action: String) {
    guard let pid = readPid() else {
      FileHandle.standardError.write(Data(
        "Dictator daemon isn't running. Start it with `dictator daemon`.\n".utf8))
      exit(1)
    }
    if kill(pid, sig) != 0 {
      FileHandle.standardError.write(Data("Failed to \(action) daemon (pid \(pid)).\n".utf8))
      exit(1)
    }
  }

  static func clientStatus() {
    if let pid = readPid() {
      print("Dictator daemon is running (pid \(pid)).")
    } else {
      print("Dictator daemon is not running.")
      exit(1)
    }
  }
}
#endif
