// swift-tools-version:5.9
import PackageDescription

// Cross-platform SwiftPM executable.
//
// macOS build: uses the AppKit / AVFoundation / CoreGraphics files as-is and
// auto-links the system frameworks. Builds with the Command Line Tools alone
// (no full Xcode required); do not add an .xcodeproj.
//
// Linux build: the Apple-framework files below can't compile, so they're
// excluded from the target when `swift build` runs on Linux. The Linux
// implementation lives in Sources/Dictator/Linux/ (each file `#if os(Linux)`-
// guarded) and shells out to standard desktop tools instead of linking any C
// libraries — see README "Running on Linux". `#if os(Linux)` here is evaluated
// on the machine doing the build, which for a native Linux build is Linux.
#if os(Linux)
let excludedSources = [
  "AppDelegate.swift",
  "AudioRecorder.swift",
  "HotkeyManager.swift",
  "MediaController.swift",
  "Overlay.swift",
  "Permissions.swift",
  "SoundPlayer.swift",
  "SpectrumAnalyzer.swift",
  "TextInserter.swift",
]
#else
let excludedSources: [String] = []
#endif

let package = Package(
  name: "Dictator",
  platforms: [
    .macOS(.v13)  // SMAppService (launch at login) needs macOS 13+; ignored on Linux
  ],
  targets: [
    .executableTarget(
      name: "Dictator",
      path: "Sources/Dictator",
      exclude: excludedSources
    )
  ]
)
