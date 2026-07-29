#if os(Linux)
import Foundation

// Plays the three optional cue sounds by shelling out to whatever audio player
// is installed. Files live in a user-writable folder so they can be swapped
// without rebuilding:
//
//   ~/.config/dictator/sounds/
//     start.<ext>   played when recording opens
//     stop.<ext>    played when recording closes
//     done.<ext>    played when the transcript has been inserted
//
// If a file is missing that event is simply silent (notifications still give
// feedback). Supported extensions depend on the player; wav/ogg work everywhere.
final class LinuxSoundPlayer {
  enum Event: String { case start, stop, done }

  var enabled = true
  private let player: String?

  init() {
    // paplay/pw-play accept ogg+wav; aplay is WAV-only; ffplay is the catch-all.
    player = Shell.firstAvailable(["paplay", "pw-play", "aplay", "ffplay"])
  }

  static var directory: URL {
    ConfigStore.directory.appendingPathComponent("sounds", isDirectory: true)
  }

  func ensureDirectory() {
    let dir = Self.directory
    let fm = FileManager.default
    guard !fm.fileExists(atPath: dir.path) else { return }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let readme = """
    Drop sound files here to customize Dictator's cues. Name them by event:

      start.wav   — when recording opens
      stop.wav    — when recording closes
      done.wav    — when the transcript has been inserted

    wav and ogg work with any player. Changes take effect immediately.
    """
    try? readme.write(to: dir.appendingPathComponent("README.txt"),
                      atomically: true, encoding: .utf8)
  }

  func play(_ event: Event) {
    guard enabled, let player = player, let url = fileURL(for: event) else { return }
    let args: [String]
    if player.hasSuffix("ffplay") {
      args = ["-nodisp", "-autoexit", "-loglevel", "quiet", url.path]
    } else {
      args = [url.path]
    }
    Shell.spawn(player, args)   // fire-and-forget; cues shouldn't block the pipeline
  }

  private func fileURL(for event: Event) -> URL? {
    let dir = Self.directory
    for ext in ["wav", "ogg", "oga", "flac", "mp3"] {
      let url = dir.appendingPathComponent("\(event.rawValue).\(ext)")
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }
}
#endif
