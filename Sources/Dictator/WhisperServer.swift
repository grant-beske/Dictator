import Foundation

// Spawns and supervises a local whisper-server child process, keeping the model
// resident (warm) so there's no per-dictation reload.
//
// Key detail: whisper.cpp's Metal backend needs GGML_METAL_PATH_RESOURCES set
// to "<brew --prefix whisper-cpp>/share/whisper-cpp" or it won't find its Metal
// resources and falls back to slow CPU decoding.
final class WhisperServer {
  private let modelPath: String
  private let port: Int
  private let language: String
  private let beamSize: Int
  private let bestOf: Int
  private let noTimestamps: Bool

  private var process: Process?
  private var stopping = false       // distinguishes intentional stop from a crash
  private var restartCount = 0

  init(modelPath: String, port: Int, language: String,
       beamSize: Int, bestOf: Int, noTimestamps: Bool) {
    self.modelPath = modelPath
    self.port = port
    self.language = language
    self.beamSize = beamSize
    self.bestOf = bestOf
    self.noTimestamps = noTimestamps
  }

  // MARK: Locating the Homebrew binary + resources

  // Find whisper-server: prefer Apple-Silicon Homebrew, then Intel, then PATH.
  private static func serverExecutable() -> String? {
    let candidates = ["/opt/homebrew/bin/whisper-server",
                      "/usr/local/bin/whisper-server"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
    return runCapturing("/usr/bin/which", ["whisper-server"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty
  }

  // `brew --prefix whisper-cpp` + "/share/whisper-cpp"
  private static func metalResourcesPath() -> String? {
    let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let brew = brew,
          let prefix = runCapturing(brew, ["--prefix", "whisper-cpp"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else { return nil }
    return prefix + "/share/whisper-cpp"
  }

  private static func runCapturing(_ launchPath: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
      try p.run()
      p.waitUntilExit()
    } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  // MARK: Lifecycle

  func start() {
    guard process == nil else { return }
    guard FileManager.default.fileExists(atPath: modelPath) else {
      NSLog("Dictator: model not found at \(modelPath)")
      return
    }
    guard let exe = Self.serverExecutable() else {
      NSLog("Dictator: whisper-server not found on PATH or Homebrew dirs")
      return
    }

    stopping = false
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    var args = [
      "--model", modelPath,
      "--host", "127.0.0.1",
      "--port", String(port),
      "--language", language,
      "--inference-path", "/inference",
      // Decoding speed knobs (see Config). bs/bo of 1 == greedy = fastest.
      "-bs", String(beamSize),
      "-bo", String(bestOf)
    ]
    if noTimestamps { args.append("-nt") }
    p.arguments = args

    // Inherit the environment and inject the Metal resources path so GPU
    // acceleration actually engages.
    var env = ProcessInfo.processInfo.environment
    if let resources = Self.metalResourcesPath() {
      env["GGML_METAL_PATH_RESOURCES"] = resources
      NSLog("Dictator: GGML_METAL_PATH_RESOURCES=\(resources)")
    } else {
      NSLog("Dictator: could not resolve whisper-cpp resources path; Metal may be slow")
    }
    p.environment = env

    // Drain stderr/stdout to the unified log so problems are diagnosable.
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = outPipe
    outPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
      NSLog("whisper-server: \(line.trimmingCharacters(in: .newlines))")
    }

    // Supervision: if the server dies unexpectedly, restart it (with a small
    // backoff and a sanity cap so a persistently-broken config doesn't spin).
    p.terminationHandler = { [weak self] proc in
      guard let self = self else { return }
      outPipe.fileHandleForReading.readabilityHandler = nil
      self.process = nil
      if self.stopping { return }
      NSLog("Dictator: whisper-server exited (status \(proc.terminationStatus)); restarting")
      self.restartCount += 1
      if self.restartCount <= 5 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          self?.start()
        }
      } else {
        NSLog("Dictator: whisper-server restarted too many times; giving up")
      }
    }

    do {
      try p.run()
      process = p
      NSLog("Dictator: whisper-server started on 127.0.0.1:\(port)")
    } catch {
      NSLog("Dictator: failed to launch whisper-server: \(error)")
    }
  }

  func stop() {
    stopping = true
    process?.terminate()
    process = nil
  }

  func restart() {
    stop()
    restartCount = 0
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.start()
    }
  }

  var isRunning: Bool { process?.isRunning ?? false }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
