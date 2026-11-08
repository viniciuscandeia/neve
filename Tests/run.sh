#!/bin/sh
# Runs the Swift Testing suite. With Command Line Tools only, `swift test` builds the tests but its
# helper silently runs none of them, so build, then load the bundle into a tiny runner.
#
# Usage: Tests/run.sh [-r] [FILTER]      (FILTER = regex on "Suite/testName", e.g. `Tests/run.sh FlakeMotion`)
#   -r          release-optimised build (-c release -Xswiftc -enable-testing, separate .build/release dir). @testable import works under CLT;
#               measured: full suite runs in ~3 s instead of ~95 s (debug), at the cost of a ~2 min optimised compile
#   FILTER      forwarded to Swift Testing as `--filter FILTER`; any further args are passed through as-is
#               (e.g. `--verbose` prints "passed after N seconds" per test: use it to find the slow ones)
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CFG=debug; EXTRA=
if [ "$1" = "-r" ]; then CFG=release; EXTRA="-Xswiftc -enable-testing"; shift; fi
[ -d "$F/Testing.framework" ] || { echo "run.sh: $F/Testing.framework not found: install/update the Command Line Tools (xcode-select --install)" >&2; exit 2; }
# shellcheck disable=SC2086
swift build --build-tests -c $CFG $EXTRA >&2 || { echo "run.sh: swift build failed (errors above)" >&2; exit 2; }
mkdir -p .build/runner
cat > .build/runner/main.swift <<'EOF'
@_spi(ForToolsIntegrationOnly) import Testing
import Foundation
guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else { print(String(cString: dlerror())); exit(2) }
exit(Int32(await __swiftPMEntryPoint(passing: nil)))
EOF
# Rebuild the runner only when the script/source is newer than the binary.
if [ ! -x .build/runner/run ] || [ Tests/run.sh -nt .build/runner/run ]; then
  swiftc -o .build/runner/run -F $F -framework Testing -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $F/../usr/lib .build/runner/main.swift \
    || { echo "run.sh: compiling the runner failed: the Testing framework or its SPI (__swiftPMEntryPoint) is missing/changed in this toolchain" >&2; exit 2; }
fi
BUNDLE=.build/$CFG/NevePackageTests.xctest/Contents/MacOS/NevePackageTests
[ -e "$BUNDLE" ] || { echo "run.sh: $BUNDLE missing after build" >&2; exit 2; }
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then FILTER=$1; shift; set -- --filter "$FILTER" "$@"; fi
exec .build/runner/run "$BUNDLE" "$@"
