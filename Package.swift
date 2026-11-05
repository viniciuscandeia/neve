// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools ship Testing.framework outside SwiftPM's default search path; Xcode finds it itself.
let clt = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "Neve",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NeveCore"),
        .executableTarget(name: "Neve", dependencies: ["NeveCore"]),
        .testTarget(
            name: "NeveCoreTests", dependencies: ["NeveCore"],
            swiftSettings: [.unsafeFlags(["-F", clt])],
            linkerSettings: [.unsafeFlags(["-F", clt, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", clt, "-Xlinker", "-rpath", "-Xlinker", clt + "/../usr/lib"])]),
    ]
)
