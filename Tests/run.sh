#!/bin/sh
# Runs the Swift Testing suite. With Command Line Tools only, `swift test` builds the tests but its
# helper silently runs none of them, so build, then load the bundle into a tiny runner.
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift build --build-tests >/dev/null
mkdir -p .build/runner
cat > .build/runner/main.swift <<'EOF'
@_spi(ForToolsIntegrationOnly) import Testing
import Foundation
guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else { print(String(cString: dlerror())); exit(2) }
exit(Int32(await __swiftPMEntryPoint(passing: nil)))
EOF
swiftc -o .build/runner/run -F $F -framework Testing -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $F/../usr/lib .build/runner/main.swift 2>/dev/null
exec .build/runner/run .build/debug/NevePackageTests.xctest/Contents/MacOS/NevePackageTests
