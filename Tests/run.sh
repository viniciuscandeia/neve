#!/bin/sh
# AGENT HEADER - Tests/run.sh
# Role: THE way to run the Swift Testing suite here. With Command Line Tools only, `swift test` builds the bundle but its helper runs none of the tests, so this script builds
# (`swift build --build-tests`), compiles a tiny runner into $B/runner/run (dlopen's NevePackageTests.xctest and calls __swiftPMEntryPoint, an SPI) and execs it.
# Usage: Tests/run.sh [-r] [--sanitize thread|address] [FILTER] [extra Swift Testing args]. FILTER = regex on "Suite/testName" (e.g. `Tests/run.sh FlakeMotion`);
#   -r = release build with -enable-testing (~3 s run vs ~95 s debug, ~2 min compile; @testable import works); --sanitize builds in .build-thread/.build-address and injects the CLT
#   clang sanitizer runtime via DYLD_INSERT_LIBRARIES (runner not instrumented); --verbose prints per-test timings. Exits 2 when the build/runner/framework is missing.
# After the tests it runs `NEVE_SHADER_CHECK=1 <build>/Neve` (compiles all Metal shaders/pipelines, no UI) and fails on any error.
# Needs /Library/Developer/CommandLineTools/.../Frameworks/Testing.framework (same path as Package.swift's `clt`). Tests that touch the real screen must be idle-gated.
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
$B/runner/run "$BUNDLE" "$@"
# Shader check: the app binary compiles every MSL library/pipeline (NEVE_SHADER_CHECK=1, no UI); a broken shader fails the run.
NEVE_SHADER_CHECK=1 $B/$CFG/Neve || { echo "run.sh: NEVE_SHADER_CHECK failed (Metal shader/pipeline error above)" >&2; exit 1; }
