#if os(Linux)
import Foundation

// Pauses whatever media is playing (browser video, Spotify, mpv, …) while the
// user dictates, then resumes it — the Linux counterpart to the macOS
// MediaController. It uses `playerctl`, which speaks MPRIS over D-Bus (the
// standard "now playing" bus most Linux players expose).
//
// Like the macOS version, it only pauses when something is actually playing and
// only resumes what *it* paused, so it never starts playback the user paused
// themselves. Every method is a graceful no-op when playerctl isn't installed.
final class LinuxMedia {
  private let playerctl: String?
  private var didPause = false

  init() { playerctl = Shell.which("playerctl") }

  func pauseIfPlaying() {
    guard let pc = playerctl else { return }
    didPause = false
    // `playerctl status` prints "Playing" / "Paused" / "Stopped" (or errors with
    // "No players found", which capture() turns into an empty string).
    if Shell.capture(pc, ["status"]) == "Playing" {
      _ = Shell.run(pc, ["pause"])
      didPause = true
    }
  }

  func resumeIfPaused() {
    guard didPause, let pc = playerctl else { return }
    didPause = false
    _ = Shell.run(pc, ["play"])
  }
}
#endif
