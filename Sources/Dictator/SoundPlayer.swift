import AppKit

// Plays short UI sounds for the three dictation events. Files live in a
// user-writable folder so they can be hot-swapped without re-signing or
// rebuilding the app:
//
//   ~/Library/Application Support/Dictator/Sounds/
//     start.<ext>   played when push-to-talk opens
//     stop.<ext>    played when push-to-talk is released
//     done.<ext>    played when the transcript has been pasted
//
// Any of these extensions work: wav, aiff, aif, caf, mp3, m4a. If a file is
// missing, that event is simply silent (the overlay still gives visual cues).
final class SoundPlayer: NSObject, NSSoundDelegate {
  enum Event: String { case start, stop, done }

  var enabled = true

  private static let extensions = ["wav", "aiff", "aif", "caf", "mp3", "m4a"]
  // NSSound stops if it's deallocated mid-playback, so keep a strong reference
  // to each sound until it finishes (removed in soundDidFinishPlaying).
  private var active: [NSSound] = []

  static var directory: URL {
    ConfigStore.directory.appendingPathComponent("Sounds", isDirectory: true)
  }

  // Create the folder on first launch and drop a note explaining the naming.
  func ensureDirectory() {
    let dir = Self.directory
    let fm = FileManager.default
    guard !fm.fileExists(atPath: dir.path) else { return }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let readme = """
    Drop sound files here to customize Dictator's cues. Name them by event:

      start.wav   — when you start holding the push-to-talk keys
      stop.wav    — when you release them
      done.wav    — when the transcript has been pasted

    Supported extensions: wav, aiff, aif, caf, mp3, m4a.
    Changes take effect immediately — no rebuild needed.
    """
    try? readme.write(to: dir.appendingPathComponent("README.txt"),
                      atomically: true, encoding: .utf8)
  }

  func play(_ event: Event) {
    guard enabled, let url = fileURL(for: event) else { return }
    // byReference re-reads the file each time, so swapped-in sounds take effect
    // without relaunching.
    guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
    sound.delegate = self
    active.append(sound)
    sound.play()
  }

  private func fileURL(for event: Event) -> URL? {
    let dir = Self.directory
    for ext in Self.extensions {
      let url = dir.appendingPathComponent("\(event.rawValue).\(ext)")
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  func sound(_ sound: NSSound, didFinishPlaying _: Bool) {
    active.removeAll { $0 === sound }
  }
}
