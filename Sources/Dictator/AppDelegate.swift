import AppKit
import ServiceManagement

// Orchestrates the whole app: status item + menu, permission flow, whisper
// server supervision, and the record → transcribe → insert pipeline.
final class AppDelegate: NSObject, NSApplicationDelegate {

  private enum State { case idle, recording, transcribing }

  private var config = Config.default
  private let recorder = AudioRecorder()
  private let hotkeys = HotkeyManager()
  private let overlay = OverlayController()
  private let sounds = SoundPlayer()
  private let media = MediaController()
  private var server: WhisperServer!
  private var transcriber: Transcriber!

  private var statusItem: NSStatusItem!
  private var state: State = .idle { didSet { updateStatusIcon() } }
  private var currentWavURL: URL?

  // MARK: Launch

  func applicationDidFinishLaunching(_ notification: Notification) {
    config = ConfigStore.load()
    server = WhisperServer(modelPath: config.resolvedModelPath,
                           port: config.serverPort,
                           language: config.language,
                           beamSize: config.beamSize,
                           bestOf: config.bestOf,
                           noTimestamps: config.noTimestamps)
    transcriber = Transcriber(port: config.serverPort, language: config.language)

    setupStatusItem()
    wireHotkeys()

    // Feed the live frequency spectrum to the overlay's waveform while recording.
    recorder.waveformGain = Float(config.waveformGain)
    recorder.onSpectrum = { [weak self] bands in self?.overlay.update(spectrum: bands) }

    // Build the HUD panel now so the first dictation's show() isn't slow. The
    // overlay also rebuilds itself on sleep/wake and display changes — see
    // OverlayController.init.
    overlay.prepare()

    // Set up customizable cue sounds (creates the Sounds folder on first run).
    sounds.enabled = config.soundsEnabled
    sounds.ensureDirectory()

    // Start the warm server immediately; it doesn't need any TCC permission.
    server.start()
    prewarmServer()  // run one throwaway inference so the FIRST dictation is fast

    // Then walk the user through the two permissions we *do* need.
    checkPermissions()
  }

  func applicationWillTerminate(_ notification: Notification) {
    server?.stop()
    hotkeys.stop()
  }

  // MARK: Status item + menu

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    updateStatusIcon()

    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Dictator", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())

    let hint = config.hotkeyMode == "toggle"
      ? "Press your toggle hotkey to start/stop"
      : "Hold \(Self.describe(config.pushToTalkModifiers)) to dictate"
    let hintItem = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
    hintItem.isEnabled = false
    menu.addItem(hintItem)
    menu.addItem(.separator())

    menu.addItem(withItem: "Edit Config…", action: #selector(openConfig), target: self)
    menu.addItem(withItem: "Reveal Config in Finder", action: #selector(revealConfig), target: self)
    menu.addItem(withItem: "Open Sounds Folder", action: #selector(openSoundsFolder), target: self)
    menu.addItem(withItem: "Restart Whisper Server", action: #selector(restartServer), target: self)
    menu.addItem(.separator())
    menu.addItem(withItem: "Re-check Permissions…", action: #selector(recheckPermissions), target: self)

    let loginItem = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
    loginItem.target = self
    loginItem.state = launchAtLoginEnabled ? .on : .off
    menu.addItem(loginItem)

    menu.addItem(.separator())
    menu.addItem(withItem: "Quit Dictator", action: #selector(quit), target: self)

    statusItem.menu = menu
  }

  // Render ["rightCommand","rightOption"] as "Right Command + Right Option".
  private static func describe(_ modifiers: [String]) -> String {
    let pretty: [String: String] = [
      "leftcommand": "Left Command", "rightcommand": "Right Command",
      "leftoption": "Left Option", "rightoption": "Right Option",
      "leftcontrol": "Left Control", "rightcontrol": "Right Control",
      "leftshift": "Left Shift", "rightshift": "Right Shift"
    ]
    let names = modifiers.map { pretty[$0.lowercased()] ?? $0 }
    return names.isEmpty ? "your push-to-talk key" : names.joined(separator: " + ")
  }

  private func updateStatusIcon() {
    guard let button = statusItem?.button else { return }
    // SF Symbols communicate state at a glance. Recording is tinted red.
    let (symbol, description, tint): (String, String, NSColor?) = {
      switch state {
      case .idle:          return ("mic", "Dictator (idle)", nil)
      case .recording:     return ("mic.fill", "Dictator (recording)", .systemRed)
      case .transcribing:  return ("waveform", "Dictator (transcribing)", .systemBlue)
      }
    }()
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    image?.isTemplate = (tint == nil)  // template = auto light/dark; tinted = custom color
    button.image = image
    button.contentTintColor = tint
  }

  // MARK: Hotkeys

  private func wireHotkeys() {
    let mode: HotkeyManager.Mode = (config.hotkeyMode == "toggle") ? .toggle : .pushToTalk
    hotkeys.configure(mode: mode,
                      pushToTalkModifiers: config.pushToTalkModifiers,
                      toggleKeyCode: config.toggleKeyCode,
                      toggleModifiers: config.toggleModifiers)
    hotkeys.onStart = { [weak self] in self?.startRecording() }
    hotkeys.onStop = { [weak self] in self?.stopRecordingAndTranscribe() }
    hotkeys.onToggle = { [weak self] in
      guard let self = self else { return }
      if self.state == .recording { self.stopRecordingAndTranscribe() }
      else if self.state == .idle { self.startRecording() }
    }
  }

  // MARK: Permissions

  private func checkPermissions() {
    // Microphone first (it can prompt asynchronously).
    Permissions.requestMic { [weak self] granted in
      guard let self = self else { return }
      if !granted {
        Permissions.showMissingPermissionAlert(
          title: "Microphone Access Needed",
          message: "Dictator records audio to transcribe it. Enable Dictator under "
                 + "Privacy & Security → Microphone, then relaunch.",
          openSettings: Permissions.openMicrophoneSettings)
      }
      self.checkAccessibility()
    }
  }

  private func checkAccessibility() {
    // Try to install the event tap. Success implies Accessibility is granted.
    if hotkeys.start() { return }

    // Not trusted yet: trigger the system prompt (registers us in the list) and
    // explain exactly where to flip the switch.
    _ = Permissions.hasAccessibility(prompt: true)
    Permissions.showMissingPermissionAlert(
      title: "Accessibility Access Needed",
      message: "Dictator needs Accessibility access to detect your global hotkey "
             + "and paste transcribed text. Enable Dictator under Privacy & "
             + "Security → Accessibility, then choose “Re-check Permissions…” "
             + "from the menu (or relaunch).",
      openSettings: Permissions.openAccessibilitySettings)
  }

  // MARK: Recording pipeline

  private func startRecording() {
    guard state == .idle else { return }
    guard Permissions.micAuthorized() else {
      checkPermissions()
      return
    }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dictator-\(UUID().uuidString).wav")
    do {
      try recorder.start(to: url)
      currentWavURL = url
      state = .recording
      // Pause any playing media (YouTube, Spotify, Music…) so we don't dictate
      // over it; resumed in stopRecordingAndTranscribe. Done after start()
      // succeeds so a failed recording never leaves media paused.
      if config.pauseMediaWhileRecording { media.pauseIfPlaying() }
      overlay.show(mode: .recording)  // floating waveform HUD
      sounds.play(.start)             // "recording opened" cue
    } catch {
      NSLog("Dictator: failed to start recording: \(error)")
      overlay.hide()
      state = .idle
    }
  }

  private func stopRecordingAndTranscribe() {
    guard state == .recording else { return }
    recorder.stop()
    // Resume whatever media we paused on record start (no-op if we paused none).
    if config.pauseMediaWhileRecording { media.resumeIfPaused() }
    state = .transcribing
    sounds.play(.stop)       // "recording closed" cue
    overlay.setProcessing()  // swap waveform for the "thinking" animation

    guard let url = currentWavURL else { overlay.hide(); state = .idle; return }
    currentWavURL = nil

    // Transcription is network I/O against the local server: do it off the main
    // thread, then hop back to insert text and reset state.
    Task { [weak self] in
      guard let self = self else { return }
      defer { try? FileManager.default.removeItem(at: url) }  // always clean up temp WAV
      do {
        let text = try await self.transcriber.transcribe(wavURL: url)
        await MainActor.run {
          // Hide the HUD just before pasting so it isn't on screen during ⌘V.
          self.overlay.hide()
          TextInserter.insert(text)
          self.sounds.play(.done)  // "pasted" cue
          self.state = .idle
        }
      } catch {
        NSLog("Dictator: transcription failed: \(error)")
        await MainActor.run {
          self.overlay.hide()
          self.state = .idle
        }
      }
    }
  }

  // MARK: Pre-warm

  // Send one throwaway inference (a fraction of a second of silence) at launch.
  // This pays the model's graph/Metal-pipeline warmup cost up front so the
  // user's FIRST real dictation isn't noticeably slower than the rest. It polls
  // because the freshly-spawned server takes a moment to accept connections.
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
          // The server responded (e.g. empty transcript for silence) — warmed.
          NSLog("Dictator: server prewarmed")
          return
        } catch {
          // Most likely connection-refused while it's still starting; retry.
          try? await Task.sleep(nanoseconds: 500_000_000)
        }
      }
    }
  }

  // Build a tiny 16 kHz / 16-bit / mono silent WAV for warmup.
  private static func makeSilentWav(seconds: Double = 0.25) -> URL? {
    let sampleRate = 16_000
    let numSamples = Int(Double(sampleRate) * seconds)
    let dataSize = numSamples * 2  // 16-bit mono
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataSize)); d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(dataSize))
    d.append(Data(count: dataSize))  // silence (zeros)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-prewarm.wav")
    do { try d.write(to: url); return url } catch { return nil }
  }

  // MARK: Menu actions

  @objc private func openConfig() {
    NSWorkspace.shared.open(ConfigStore.fileURL)
  }

  @objc private func revealConfig() {
    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
  }

  @objc private func openSoundsFolder() {
    sounds.ensureDirectory()
    NSWorkspace.shared.open(SoundPlayer.directory)
  }

  @objc private func restartServer() {
    server.restart()
  }

  @objc private func recheckPermissions() {
    checkPermissions()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  // MARK: Launch at login (SMAppService, macOS 13+)

  private var launchAtLoginEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
    do {
      if launchAtLoginEnabled {
        try SMAppService.mainApp.unregister()
        sender.state = .off
      } else {
        try SMAppService.mainApp.register()
        sender.state = .on
      }
    } catch {
      NSLog("Dictator: launch-at-login toggle failed: \(error)")
    }
  }
}

// Small convenience for building menu items targeting the delegate.
private extension NSMenu {
  func addItem(withItem title: String, action: Selector, target: AnyObject) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = target
    addItem(item)
  }
}
