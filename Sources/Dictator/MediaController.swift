import Foundation

// Pauses whatever audio/video is currently playing (Music, Spotify, a YouTube
// tab, Podcasts, …) while the user dictates, then resumes it — the same thing
// SuperWhisper does so a hotkey press doesn't talk over your media.
//
// There is no *public* macOS API for "pause the now-playing app", so we use the
// private MediaRemote framework, resolved at runtime via dlsym. If the symbols
// can't be found (a future macOS could remove or lock them down), every method
// becomes a graceful no-op rather than a crash.
//
// All calls are made on the main thread (AppDelegate drives the record pipeline
// there, and the is-playing completion is dispatched back to .main), so the
// little bit of shared state below needs no locking.
final class MediaController {
  // C signatures of the two MediaRemote functions we need.
  private typealias GetIsPlaying =
    @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
  private typealias SendCommand =
    @convention(c) (Int, CFDictionary?) -> Bool

  // MediaRemote command codes.
  private enum Command: Int { case play = 0, pause = 1 }

  private let getIsPlaying: GetIsPlaying?
  private let sendCommand: SendCommand?

  // Did *we* pause media on the last record start? We only resume in that case,
  // so we never start playback the user had paused themselves.
  private var didPause = false
  // The is-playing query is async; track whether it's still in flight and
  // whether a resume arrived before it completed (a very short push-to-talk tap).
  private var queryPending = false
  private var resumeWhenReady = false

  init() {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
      RTLD_LAZY)
    func sym<T>(_ name: String, as type: T.Type) -> T? {
      guard let handle = handle, let ptr = dlsym(handle, name) else { return nil }
      return unsafeBitCast(ptr, to: type)
    }
    getIsPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying",
                       as: GetIsPlaying.self)
    sendCommand = sym("MRMediaRemoteSendCommand", as: SendCommand.self)
  }

  // Pause now-playing media if (and only if) something is actually playing.
  func pauseIfPlaying() {
    guard let getIsPlaying = getIsPlaying, let sendCommand = sendCommand else { return }
    didPause = false
    resumeWhenReady = false
    queryPending = true
    getIsPlaying(.main) { [weak self] isPlaying in
      guard let self = self else { return }
      self.queryPending = false
      if isPlaying {
        _ = sendCommand(Command.pause.rawValue, nil)
        self.didPause = true
        // Honor a resume that arrived while the query was still in flight.
        if self.resumeWhenReady { self.resumeIfPaused() }
      }
    }
  }

  // Resume media only if we were the ones who paused it.
  func resumeIfPaused() {
    // The pause query hasn't returned yet: defer the resume until it does, so a
    // quick tap can't leave media stuck paused.
    if queryPending { resumeWhenReady = true; return }
    guard didPause, let sendCommand = sendCommand else { return }
    didPause = false
    _ = sendCommand(Command.play.rawValue, nil)
  }
}
