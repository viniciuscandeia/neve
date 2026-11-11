// swift-tools-version: 6.0
// AGENT HEADER - Package.swift
// Role: SwiftPM manifest (swift-tools 6.0, macOS 14+, defaultLocalization en). Targets: NeveCore (library: simulation/render-data logic, no windows; resources = Resources/ with
// Localizable.strings pt-BR + en, processed into Neve_NeveCore.bundle), Neve (executable: AppKit/SwiftUI/Metal app shell, depends on NeveCore), NeveCoreTests (Swift Testing, @testable NeveCore).
// Test target uses unsafeFlags -F/-rpath pointing at the CLT Testing.framework (`clt`) because Command Line Tools keep it outside SwiftPM's search path; Xcode needs none of that.
// Run tests only via Tests/run.sh. App bundling/signing is not SwiftPM's job: scripts/make-app.sh. Directory-based targets: adding a source file needs no manifest change.

import PackageDescription

// Command Line Tools ship Testing.framework outside SwiftPM's default search path; Xcode finds it itself.
let clt = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "Neve",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NeveCore", resources: [.process("Resources")]),
        .executableTarget(name: "Neve", dependencies: ["NeveCore"]),
        .testTarget(
            name: "NeveCoreTests", dependencies: ["NeveCore"],
            swiftSettings: [.unsafeFlags(["-F", clt])],
            linkerSettings: [.unsafeFlags(["-F", clt, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", clt, "-Xlinker", "-rpath", "-Xlinker", clt + "/../usr/lib"])]),
    ]
)
