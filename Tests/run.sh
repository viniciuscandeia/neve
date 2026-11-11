#!/bin/sh
# Runs the Swift Testing suite. With Command Line Tools only, `swift test` builds the tests but its
# helper silently runs none of them, so build, then load the bundle into a tiny runner.
#
# Usage: Tests/run.sh [-r] [--sanitize thread|address] [FILTER]      (FILTER = regex on "Suite/testName", e.g. `Tests/run.sh FlakeMotion`)
#   -r          release-optimised build (-c release -Xswiftc -enable-testing, separate .build/release dir). @testable import works under CLT;
#               measured: full suite runs in ~3 s instead of ~95 s (debug), at the cost of a ~2 min optimised compile
#   --sanitize  TSan / ASan build in a separate scratch dir (.build-thread / .build-address); the runner is not instrumented, so the CLT clang
#               sanitizer runtime is injected with DYLD_INSERT_LIBRARIES. Debug unless -r is also given.
#   FILTER      forwarded to Swift Testing as `--filter FILTER`; any further args are passed through as-is
#               (e.g. `--verbose` prints "passed after N seconds" per test: use it to find the slow ones)
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CFG=debug; EXTRA=
B=.build; SAN=
while [ $# -gt 0 ]; do
  case $1 in
    -r) CFG=release; EXTRA="-Xswiftc -enable-testing"; shift ;;
    --sanitize) case ${2:-} in thread|address) SAN=$2 ;; *) echo "run.sh: --sanitize takes thread or address" >&2; exit 2 ;; esac; shift 2 ;;
    *) break ;;
  esac
done
[ -d "$F/Testing.framework" ] || { echo "run.sh: $F/Testing.framework not found: install/update the Command Line Tools (xcode-select --install)" >&2; exit 2; }
# shellcheck disable=SC2086
swift build --build-tests -c $CFG $EXTRA ${SAN:+--sanitize=$SAN --scratch-path .build-$SAN} >&2 || { echo "run.sh: swift build failed (errors above)" >&2; exit 2; }
[ -n "$SAN" ] && B=.build-$SAN
mkdir -p $B/runner
cat > $B/runner/main.swift <<'EOF'
@_spi(ForToolsIntegrationOnly) import Testing
import Foundation
guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else { print(String(cString: dlerror())); exit(2) }
exit(Int32(await __swiftPMEntryPoint(passing: nil)))
EOF
# Rebuild the runner only when the script/source is newer than the binary.
if [ ! -x $B/runner/run ] || [ Tests/run.sh -nt $B/runner/run ]; then
  swiftc -o $B/runner/run -F $F -framework Testing -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $F/../usr/lib $B/runner/main.swift \
    || { echo "run.sh: compiling the runner failed: the Testing framework or its SPI (__swiftPMEntryPoint) is missing/changed in this toolchain" >&2; exit 2; }
fi
BUNDLE=$B/$CFG/NevePackageTests.xctest/Contents/MacOS/NevePackageTests
[ -e "$BUNDLE" ] || { echo "run.sh: $BUNDLE missing after build" >&2; exit 2; }
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then FILTER=$1; shift; set -- --filter "$FILTER" "$@"; fi
if [ -n "$SAN" ]; then
  case $SAN in thread) RT=tsan ;; address) RT=asan ;; esac
  CLANG=$(xcrun --find clang); LIB=$(ls "$(dirname "$CLANG")"/../lib/clang/*/lib/darwin/libclang_rt.${RT}_osx_dynamic.dylib 2>/dev/null | tail -1)
  [ -n "$LIB" ] || { echo "run.sh: libclang_rt.${RT}_osx_dynamic.dylib not found next to $CLANG" >&2; exit 2; }
  export DYLD_INSERT_LIBRARIES=$LIB
fi
exec $B/runner/run "$BUNDLE" "$@"
