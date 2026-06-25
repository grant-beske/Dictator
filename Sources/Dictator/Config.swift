import Foundation

// User-editable configuration, persisted as JSON at:
//   ~/Library/Application Support/Dictator/config.json
// On first launch the file is created with the defaults below.
struct Config: Codable {
  // Absolute or ~-relative path to the ggml model file.
  var modelPath: String

  // "pushToTalk" (hold one or more modifiers) or "toggle" (press a chord to
  // start/stop).
  var hotkeyMode: String

  // Modifier keys that must ALL be held for push-to-talk. These are
  // side-specific so we can require the right-hand keys and ignore the left.
  // Valid names: leftCommand, rightCommand, leftOption, rightOption,
  // leftControl, rightControl, leftShift, rightShift.
  var pushToTalkModifiers: [String]

  // Toggle chord: a key plus modifiers. 2 == "D".
  var toggleKeyCode: Int
  // Modifier names that must be held for the toggle: any of
  // "command", "control", "option", "shift".
  var toggleModifiers: [String]

  // Local whisper-server port.
  var serverPort: Int

  // Spoken language code, e.g. "en". Use "auto" to auto-detect.
  var language: String

  // Play start/stop/done cue sounds (from the Sounds folder).
  var soundsEnabled: Bool

  // Visual gain for the recording waveform. Raise it if the bars look too
  // small when you speak; lower it if they're always maxed out.
  var waveformGain: Double

  // Decoding speed/accuracy knobs passed to whisper-server. Lower values are
  // faster; 1/1 is greedy decoding (fastest), good for clean dictation audio.
  var beamSize: Int
  var bestOf: Int
  // Skip generating timestamp tokens: a bit faster, and avoids the per-segment
  // newlines whisper otherwise inserts.
  var noTimestamps: Bool

  static let `default` = Config(
    modelPath: "~/whisper-models/ggml-large-v3-turbo-q5_0.bin",
    hotkeyMode: "pushToTalk",
    pushToTalkModifiers: ["rightCommand", "rightOption"],  // hold both to dictate
    toggleKeyCode: 2,               // D
    toggleModifiers: ["control", "option"],
    serverPort: 8080,
    language: "en",
    soundsEnabled: true,
    waveformGain: 1.4,
    beamSize: 3,
    bestOf: 5,
    noTimestamps: true
  )

  // Model path with a leading ~ expanded to the home directory.
  var resolvedModelPath: String {
    (modelPath as NSString).expandingTildeInPath
  }
}

enum ConfigStore {
  // ~/Library/Application Support/Dictator
  static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
    return base.appendingPathComponent("Dictator", isDirectory: true)
  }

  static var fileURL: URL {
    directory.appendingPathComponent("config.json")
  }

  // Load config, creating the file with defaults if it does not yet exist.
  // Any decode error falls back to defaults rather than crashing.
  static func load() -> Config {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

    guard let data = try? Data(contentsOf: fileURL) else {
      let cfg = Config.default
      save(cfg)
      return cfg
    }
    do {
      return try JSONDecoder().decode(Config.self, from: data)
    } catch {
      NSLog("Dictator: config decode failed (\(error)); using defaults")
      return Config.default
    }
  }

  static func save(_ config: Config) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config) {
      try? data.write(to: fileURL)
    }
  }
}
