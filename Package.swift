// swift-tools-version: 6.0
// AGENT HEADER - Package.swift
// Role: SwiftPM manifest (swift-tools 6.0, macOS 14+, defaultLocalization en). Targets: NeveCore (library: simulation/render-data logic, no windows; resources = Resources/ with
// Localizable.strings pt-BR + en, processed into Neve_NeveCore.bundle), NeveRender (library: Metal shaders, pipelines, frame data preparation + encoding shared by the app and the lab; Metal + NeveCore, no AppKit), Neve (executable: AppKit/SwiftUI app shell, depends on NeveCore + NeveRender), NeveCoreTests (Swift Testing, @testable NeveCore), NeveRenderTests (offscreen render tests; equivalence with the legacy bridge).
// Test targets use unsafeFlags -F/-rpath pointing at the CLT Testing.framework (`clt`) only when it exists (`hasCLT`): Command Line Tools keep it outside SwiftPM's search path; Xcode needs none of that (Xcode-only machine: unverified).
// Run tests only via Tests/run.sh. App bundling/signing is not SwiftPM's job: scripts/make-app.sh. Directory-based targets: adding a source file needs no manifest change.

import Foundation
import PackageDescription

// Command Line Tools ship Testing.framework outside SwiftPM's default search path; Xcode finds it itself.
// The flags apply only when the CLT copy exists, so a machine with only Xcode builds the tests without them (unverified there).
let clt = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let hasCLT = FileManager.default.fileExists(atPath: clt + "/Testing.framework")

let package = Package(
    name: "Neve",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NeveCore", resources: [.process("Resources")]),
        .target(name: "NeveRender", dependencies: ["NeveCore"]),
        .executableTarget(name: "Neve", dependencies: ["NeveCore", "NeveRender"]),
        .testTarget(
            name: "NeveCoreTests", dependencies: ["NeveCore"],
            swiftSettings: hasCLT ? [.unsafeFlags(["-F", clt])] : [],
            linkerSettings: hasCLT ? [.unsafeFlags(["-F", clt, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", clt, "-Xlinker", "-rpath", "-Xlinker", clt + "/../usr/lib"])] : []),
        .testTarget(
            name: "NeveRenderTests", dependencies: ["NeveCore", "NeveRender"],
            swiftSettings: hasCLT ? [.unsafeFlags(["-F", clt])] : [],
            linkerSettings: hasCLT ? [.unsafeFlags(["-F", clt, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", clt, "-Xlinker", "-rpath", "-Xlinker", clt + "/../usr/lib"])] : []),
    ]
)
