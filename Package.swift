// swift-tools-version:5.9
import PackageDescription

// Plain SwiftPM executable. Builds with the Command Line Tools alone
// (no full Xcode required). System frameworks like AppKit / AVFoundation /
// ApplicationServices auto-link on macOS when imported.
let package = Package(
  name: "Dictator",
  platforms: [
    .macOS(.v13)  // SMAppService (launch at login) needs macOS 13+
  ],
  targets: [
    .executableTarget(
      name: "Dictator",
      path: "Sources/Dictator"
    )
  ]
)
