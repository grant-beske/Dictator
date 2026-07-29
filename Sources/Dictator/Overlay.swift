import AppKit

// A floating HUD shown at top-center of the active screen: a black bar with
// hexagonal (pointed) ends, a colored state hexagon on the left (red while
// recording, amber while transcribing), and a stationary spectrum-analyzer
// waveform on the right.
//
// CRITICAL: this window must never take keyboard focus, or the synthesized
// Cmd+V would paste into it. We use a .nonactivatingPanel, order it in with
// orderFrontRegardless() (never makeKey), and ignore mouse events.
final class OverlayController {
  enum Mode { case recording, processing }

  private var panel: NSPanel?
  private var waveView: WaveformView?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  private let size = NSSize(width: 300, height: 54)

  // Spaces behavior for the HUD. CRITICAL with MULTIPLE full-screen apps: each
  // full-screen app is its own Space. `.canJoinAllSpaces` + `.fullScreenAuxiliary`
  // lets the panel appear on the *currently active* Space, including over a
  // full-screen app. We intentionally do NOT set `.stationary` here: it's an
  // Exposé behavior that, combined with the above, pins the panel to a single
  // full-screen Space (the one it was first ordered into — e.g. the app you slept
  // on), so it shows there and is occluded everywhere else. We also re-assert this
  // on every show() (see show()) because the active full-screen Space changes
  // between dictations and the association must be refreshed.
  private static let spaceBehavior: NSWindow.CollectionBehavior =
    [.canJoinAllSpaces, .fullScreenAuxiliary]

  init() {
    // The panel is created once and reused for the whole process. Across a
    // sleep/wake or a display reconfiguration (opening the lid, (un)plugging an
    // external monitor, Space/resolution changes) the long-lived status-bar
    // panel's window-server state can go stale and silently stop drawing — the
    // HUD never appears even though recording/sounds work, and only a relaunch
    // fixes it. Guard against that by dropping the panel on those transitions so
    // the next show() rebuilds a fresh one.
    let ws = NSWorkspace.shared.notificationCenter
    observers.append((ws, ws.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.invalidatePanel(reason: "wake")
      }))
    let nc = NotificationCenter.default
    observers.append((nc, nc.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
        self?.invalidatePanel(reason: "screen-change")
      }))
  }

  deinit {
    for (center, token) in observers { center.removeObserver(token) }
  }

  // Build the panel up front so the first dictation doesn't pay the allocation
  // + first CALayer draw cost on its initial show() (the "lag on first
  // appearance" after launch). Safe to call repeatedly; no-ops once built.
  func prepare() {
    makePanelIfNeeded()
  }

  // Drop the current panel so the next show() builds a fresh one. See init() for
  // why: the reused panel can go stale after sleep/wake or a display change.
  private func invalidatePanel(reason: String) {
    guard panel != nil else { return }
    NSLog("Dictator: overlay invalidated (\(reason)) — rebuilding on next show")
    waveView?.stopAnimating()
    panel?.orderOut(nil)
    panel = nil
    waveView = nil
  }

  private func makePanelIfNeeded() {
    guard panel == nil else { return }
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.collectionBehavior = Self.spaceBehavior

    // The view draws the (non-rectangular) hexagon itself; the window is clear,
    // so the drop shadow follows the hexagon's alpha.
    let wave = WaveformView(frame: NSRect(origin: .zero, size: size))
    wave.autoresizingMask = [.width, .height]
    panel.contentView = wave
    self.panel = panel
    self.waveView = wave
  }

  private func reposition() {
    guard let panel = panel else { return }
    let mouse = NSEvent.mouseLocation
    // Fall back all the way to the first available screen: right after wake
    // NSScreen.main can momentarily be nil/stale, and we must NOT leave the
    // panel at an origin computed for the previous display layout (which could
    // be off the now-visible screen).
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
      ?? NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else {
      NSLog("Dictator: overlay reposition found NO screen — HUD may not be visible")
      return
    }
    var x = visible.midX - size.width / 2
    var y = visible.maxY - size.height - 16
    // Clamp fully on-screen in case visibleFrame is unexpectedly small/odd.
    x = min(max(x, visible.minX), visible.maxX - size.width)
    y = min(max(y, visible.minY), visible.maxY - size.height)
    panel.setFrameOrigin(NSPoint(x: x, y: y))
    // Diagnostic: every HUD appearance records where it was placed and on which
    // screen, so a recurrence of the "overlay didn't appear" bug leaves evidence
    // in the log instead of needing a repro. (See CLAUDE.md → Diagnostics.)
    NSLog("Dictator: overlay positioned at (\(Int(x)), \(Int(y))) on visibleFrame \(NSStringFromRect(visible))")
  }

  // MARK: API (main thread)

  func show(mode: Mode) {
    makePanelIfNeeded()
    reposition()
    guard let panel = panel, let wave = waveView else { return }
    wave.mode = (mode == .recording) ? .recording : .processing
    wave.startAnimating()
    // Re-assert Spaces membership every show so the panel lands on whatever Space
    // is active now — including a different full-screen app's Space than last time.
    // (Diagnosed via the post-show `occluded=true` logs while on other full-screen
    // apps; see CLAUDE.md → Diagnostics.)
    panel.collectionBehavior = Self.spaceBehavior
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.invalidateShadow()  // recompute shadow for the hexagon shape
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      panel.animator().alphaValue = 1
    }

    // Anomaly-only health check shortly after show (occlusionState needs a beat
    // to settle after orderFront). In the healthy path the HUD is opaque and on
    // the active Space, so we stay silent. We log ONLY when the window is
    // occluded (sitting on a Space you're not viewing — the multi-full-screen-app
    // bug) or transparent (a dropped alpha fade), so a regression self-reports
    // without per-dictation noise. (See CLAUDE.md → Diagnostics.)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self, let panel = self.panel, panel.isVisible else { return }
      let occluded = !panel.occlusionState.contains(.visible)
      guard occluded || panel.alphaValue < 0.99 else { return }
      let screen = panel.screen.map { NSStringFromRect($0.frame) } ?? "nil"
      NSLog("Dictator: overlay post-show ANOMALY alpha=\(panel.alphaValue) occluded=\(occluded) screen=\(screen)")
    }
  }

  func update(spectrum: [Float]) {
    waveView?.setSpectrum(spectrum)
  }

  func setProcessing() {
    waveView?.mode = .processing
  }

  func hide() {
    guard let panel = panel else { return }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.18
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      panel.orderOut(nil)
      self?.waveView?.stopAnimating()
    })
  }
}

// Draws the hexagon container, the state hexagon, and the waveform. The
// spectrum is stationary: each band is a fixed slice of the width that rises and
// falls in place (a graphic-EQ / stereo visualizer), not a scrolling history.
final class WaveformView: NSView {
  enum Mode { case recording, processing }
  var mode: Mode = .recording

  private var targetBands: [CGFloat] = []   // latest spectrum from audio
  private var displayBands: [CGFloat] = []  // eased toward target for smooth motion
  private var phase: CGFloat = 0            // processing-wave phase
  private var timer: Timer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }
  required init?(coder: NSCoder) { fatalError("not used") }

  func setSpectrum(_ bands: [Float]) {
    targetBands = bands.map { CGFloat($0) }
    if displayBands.count != targetBands.count {
      displayBands = targetBands
    }
  }

  func startAnimating() {
    guard timer == nil else { return }
    let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func stopAnimating() {
    timer?.invalidate()
    timer = nil
    targetBands = []
    displayBands = []
    phase = 0
  }

  private func tick() {
    if mode == .recording {
      // Ease each band toward its target so bars glide rather than snap.
      if displayBands.count == targetBands.count {
        for i in 0..<displayBands.count {
          displayBands[i] += (targetBands[i] - displayBands[i]) * 0.35
        }
      }
    } else {
      phase += 0.16
    }
    needsDisplay = true
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    // Inset by 2 so the colored border has room inside the window bounds.
    let b = bounds.insetBy(dx: 2, dy: 2)
    let H = b.height
    let tip = H * 0.30                      // shorter pointed ends = sleeker bar
    let stateColor: NSColor = (mode == .recording) ? .systemRed : .systemOrange

    // 1. Black hexagon container with a colored border matching the state.
    let container = Self.hexagon(in: b, tipInset: tip)
    NSColor.black.withAlphaComponent(0.92).setFill()
    container.fill()
    stateColor.setStroke()
    container.lineWidth = 2
    container.lineJoinStyle = .round        // keep the sharp tips from spiking
    container.stroke()

    // 2. State hexagon on the left: a REGULAR (equilateral) FLAT-TOP hexagon
    // whose flat top/bottom edges are flush with the bar (flat-to-flat == H, so
    // R = H/√3). Points face left/right; the right point feeds into the wave.
    let R = H / sqrt(3)
    let hexCX = b.minX + tip + R / 2
    let stateHex = Self.flatTopHexagon(centerX: hexCX, centerY: b.midY, radius: R)
    stateColor.setFill()
    stateHex.fill()

    // 3. Waveform area: starts right at the hexagon's right point (so the
    // center line appears to emerge from it — same color as the hexagon) and
    // runs all the way to the right tip.
    let waveLeft = hexCX + R + 1
    let waveRight = b.maxX - 6
    guard waveRight > waveLeft else { return }
    let pad = H * 0.14
    let waveRect = CGRect(x: waveLeft, y: b.minY + pad,
                          width: waveRight - waveLeft, height: H - 2 * pad)

    switch mode {
    case .recording:
      // Speech waveform: white envelope over a state-colored center line.
      drawSpectrum(in: waveRect, baseColor: stateColor)
    case .processing:
      // The transcribing wave is the SAME color as the hexagon, so we start it
      // inside the hexagon (at its center): the overlap blends orange-on-orange
      // and the wave appears to flow out of the hexagon with no left gap.
      let pRect = CGRect(x: hexCX, y: waveRect.minY,
                         width: waveRight - hexCX, height: waveRect.height)
      drawProcessingWave(in: pRect, color: stateColor)
    }
  }

  // Mirrored filled white envelope (symmetric about the center line) over a
  // state-colored center line.
  private func drawSpectrum(in rect: CGRect, baseColor: NSColor) {
    let midY = rect.midY
    let maxAmp = rect.height / 2
    let count = displayBands.count

    if count >= 2 {
      // Top curve points left→right, then bottom mirror right→left = closed loop.
      var top: [CGPoint] = []
      var bottom: [CGPoint] = []
      for i in 0..<count {
        let fx = count == 1 ? 0.5 : CGFloat(i) / CGFloat(count - 1)
        let x = rect.minX + fx * rect.width
        // Taper the ends so the blob narrows toward the edges (per the sketch).
        let taper = pow(sin(Double.pi * (Double(i) + 0.5) / Double(count)), 0.35)
        let amp = (max(0.05, displayBands[i]) * CGFloat(taper)) * maxAmp
        top.append(CGPoint(x: x, y: midY + amp))
        bottom.append(CGPoint(x: x, y: midY - amp))
      }
      let loop = top + bottom.reversed()
      let path = Self.smoothClosedPath(loop)

      NSColor.white.withAlphaComponent(0.45).setFill()
      path.fill()
      NSColor.white.withAlphaComponent(0.95).setStroke()
      path.lineWidth = 1.5
      path.stroke()
    }

    // State-colored center line, full width.
    let line = NSBezierPath()
    line.move(to: CGPoint(x: rect.minX, y: midY))
    line.line(to: CGPoint(x: rect.maxX, y: midY))
    baseColor.setStroke()
    line.lineWidth = 2
    line.lineCapStyle = .round
    line.stroke()
  }

  // Thin traveling sine wave over a matching baseline, both in the state color
  // (orange). The wave starts inside the hexagon so it flows out seamlessly.
  private func drawProcessingWave(in rect: CGRect, color: NSColor) {
    let midY = rect.midY
    let amp = rect.height * 0.30
    let cycles: CGFloat = 3.4

    color.setStroke()

    // Baseline (the center line / axis).
    let base = NSBezierPath()
    base.move(to: CGPoint(x: rect.minX, y: midY))
    base.line(to: CGPoint(x: rect.maxX, y: midY))
    base.lineWidth = 2
    base.lineCapStyle = .round
    base.stroke()

    let wave = NSBezierPath()
    var x = rect.minX
    while x <= rect.maxX {
      let fx = (x - rect.minX) / rect.width
      let y = midY + sin(fx * cycles * 2 * .pi + phase) * amp
      if x == rect.minX { wave.move(to: CGPoint(x: x, y: y)) }
      else { wave.line(to: CGPoint(x: x, y: y)) }
      x += 2
    }
    wave.lineWidth = 2          // thin — was 4, looked tacky
    wave.lineJoinStyle = .round
    wave.lineCapStyle = .round
    wave.stroke()
  }

  // MARK: Shape helpers

  // Elongated hexagon: flat top/bottom, pointed left/right ends.
  private static func hexagon(in r: CGRect, tipInset tip: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.minX, y: r.midY))
    p.line(to: CGPoint(x: r.minX + tip, y: r.maxY))
    p.line(to: CGPoint(x: r.maxX - tip, y: r.maxY))
    p.line(to: CGPoint(x: r.maxX, y: r.midY))
    p.line(to: CGPoint(x: r.maxX - tip, y: r.minY))
    p.line(to: CGPoint(x: r.minX + tip, y: r.minY))
    p.close()
    return p
  }

  // A regular (equilateral) flat-top hexagon centered at (cx, cy): flat edges on
  // top and bottom, points on the left and right. All six sides equal. With
  // R = H/√3 the flat edges are exactly H apart (flush with the bar).
  private static func flatTopHexagon(centerX cx: CGFloat, centerY cy: CGFloat,
                                     radius R: CGFloat) -> NSBezierPath {
    let dy = R * sqrt(3) / 2   // == H/2 when R = H/√3
    let half = R / 2
    let p = NSBezierPath()
    p.move(to: CGPoint(x: cx + R, y: cy))            // right point
    p.line(to: CGPoint(x: cx + half, y: cy + dy))    // upper right
    p.line(to: CGPoint(x: cx - half, y: cy + dy))    // upper left
    p.line(to: CGPoint(x: cx - R, y: cy))            // left point
    p.line(to: CGPoint(x: cx - half, y: cy - dy))    // lower left
    p.line(to: CGPoint(x: cx + half, y: cy - dy))    // lower right
    p.close()
    return p
  }

  // Catmull-Rom spline through the points, treated as a closed loop, converted
  // to cubic Béziers — gives the smooth organic blob in the sketch.
  private static func smoothClosedPath(_ pts: [CGPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    let n = pts.count
    guard n > 2 else {
      if let first = pts.first {
        path.move(to: first)
        for p in pts.dropFirst() { path.line(to: p) }
        path.close()
      }
      return path
    }
    path.move(to: pts[0])
    for i in 0..<n {
      let p0 = pts[(i - 1 + n) % n]
      let p1 = pts[i]
      let p2 = pts[(i + 1) % n]
      let p3 = pts[(i + 2) % n]
      let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
      let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
      path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
    }
    path.close()
    return path
  }
}
