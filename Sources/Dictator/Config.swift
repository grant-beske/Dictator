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

  // Pause currently-playing media (Music, Spotify, a YouTube tab, …) while
  // dictating, then resume it afterwards — like SuperWhisper.
  var pauseMediaWhileRecording: Bool

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

  // Linux only (ignored on macOS). How the daemon starts/stops recording:
  //  - "socket": toggle mode — bind a desktop keyboard shortcut to
  //    `dictator toggle`, which signals the running daemon. No special
  //    permissions; works on both X11 and Wayland. This is the default.
  //  - "evdev": true push-to-talk — read key press/release from /dev/input
  //    directly (below the display server). Needs your user in the `input`
  //    group. Uses `linuxPushToTalkKey` as the hold key.
  var linuxInputMode: String
  // Linux evdev push-to-talk key code (EV_KEY code). 97 == KEY_RIGHTCTRL.
  // Common alternatives: 100 (KEY_RIGHTALT), 125 (KEY_LEFTMETA / Super).
  var linuxPushToTalkKey: Int

  static let `default` = Config(
    modelPath: "~/whisper-models/ggml-large-v3-turbo-q5_0.bin",
    hotkeyMode: "pushToTalk",
    pushToTalkModifiers: ["rightCommand", "rightOption"],  // hold both to dictate
    toggleKeyCode: 2,               // D
    toggleModifiers: ["control", "option"],
    serverPort: 8080,
    language: "en",
    soundsEnabled: true,
    pauseMediaWhileRecording: true,
    waveformGain: 1.4,
    beamSize: 3,
    bestOf: 5,
    noTimestamps: true,
    linuxInputMode: "socket",
    linuxPushToTalkKey: 97          // KEY_RIGHTCTRL
  )

  // Model path with a leading ~ expanded to the home directory.
  var resolvedModelPath: String {
    #if os(macOS)
    return (modelPath as NSString).expandingTildeInPath
    #else
    // NSString.expandingTildeInPath is unreliable on Linux Foundation; expand
    // a leading ~ ourselves against the current user's home directory.
    guard modelPath == "~" || modelPath.hasPrefix("~/") else { return modelPath }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + modelPath.dropFirst()
    #endif
  }

  // Memberwise init (no longer free once we add a custom decoder below).
  init(modelPath: String, hotkeyMode: String, pushToTalkModifiers: [String],
       toggleKeyCode: Int, toggleModifiers: [String], serverPort: Int,
       language: String, soundsEnabled: Bool, pauseMediaWhileRecording: Bool,
       waveformGain: Double, beamSize: Int, bestOf: Int, noTimestamps: Bool,
       linuxInputMode: String, linuxPushToTalkKey: Int) {
    self.modelPath = modelPath
    self.hotkeyMode = hotkeyMode
    self.pushToTalkModifiers = pushToTalkModifiers
    self.toggleKeyCode = toggleKeyCode
    self.toggleModifiers = toggleModifiers
    self.serverPort = serverPort
    self.language = language
    self.soundsEnabled = soundsEnabled
    self.pauseMediaWhileRecording = pauseMediaWhileRecording
    self.waveformGain = waveformGain
    self.beamSize = beamSize
    self.bestOf = bestOf
    self.noTimestamps = noTimestamps
    self.linuxInputMode = linuxInputMode
    self.linuxPushToTalkKey = linuxPushToTalkKey
  }

  // Tolerant decoding: any key missing from an older config.json falls back to
  // its default rather than failing the whole decode (which would reset every
  // setting). This is what lets us add new options without disrupting users.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Config.default
    func g<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      (try? c.decode(T.self, forKey: key)) ?? fallback
    }
    modelPath = g(.modelPath, d.modelPath)
    hotkeyMode = g(.hotkeyMode, d.hotkeyMode)
    pushToTalkModifiers = g(.pushToTalkModifiers, d.pushToTalkModifiers)
    toggleKeyCode = g(.toggleKeyCode, d.toggleKeyCode)
    toggleModifiers = g(.toggleModifiers, d.toggleModifiers)
    serverPort = g(.serverPort, d.serverPort)
    language = g(.language, d.language)
    soundsEnabled = g(.soundsEnabled, d.soundsEnabled)
    pauseMediaWhileRecording = g(.pauseMediaWhileRecording, d.pauseMediaWhileRecording)
    waveformGain = g(.waveformGain, d.waveformGain)
    beamSize = g(.beamSize, d.beamSize)
    bestOf = g(.bestOf, d.bestOf)
    noTimestamps = g(.noTimestamps, d.noTimestamps)
    linuxInputMode = g(.linuxInputMode, d.linuxInputMode)
    linuxPushToTalkKey = g(.linuxPushToTalkKey, d.linuxPushToTalkKey)
  }
}

enum ConfigStore {
  // macOS: ~/Library/Application Support/Dictator
  // Linux: $XDG_CONFIG_HOME/dictator (default ~/.config/dictator)
  static var directory: URL {
    #if os(Linux)
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    return base.appendingPathComponent("dictator", isDirectory: true)
    #else
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
    return base.appendingPathComponent("Dictator", isDirectory: true)
    #endif
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
