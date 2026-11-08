#!/bin/bash
# Usage: scripts/release.sh VERSION -> dist/Neve-VERSION.zip (universal, ad-hoc signed).
# Builds into dist/Neve.app so the locally signed build/Neve.app you run (and its Accessibility grant) is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: release.sh VERSION}
# A dev bundle (NEVE_DEV) would be built into build/, leaving a stale dist/Neve.app to be signed and zipped.
unset NEVE_DEV NEVE_INSTANCE NEVE_SCENE
export NEVE_VERSION=$V NEVE_SIGN=- NEVE_UNIVERSAL=1 NEVE_APP_DIR=dist
mkdir -p dist
rm -rf dist/Neve.app
scripts/make-app.sh
# Validate the fresh artifact before signing / zipping.
APP=dist/Neve.app; PL=$APP/Contents/Info.plist
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PL"; }
fail() { echo "release.sh: $*" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/Neve" ] || fail "missing executable $APP/Contents/MacOS/Neve"
[ "$(pb CFBundleIdentifier)" = io.github.viniciuscandeia.neve ] || fail "unexpected bundle id $(pb CFBundleIdentifier)"
[ "$(pb CFBundleShortVersionString)" = "$V" ] || fail "CFBundleShortVersionString is $(pb CFBundleShortVersionString), expected $V"
[ "$(pb CFBundleVersion)" = "$V" ] || fail "CFBundleVersion is $(pb CFBundleVersion), expected $V"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Neve")
case " $ARCHS " in *" arm64 "*) ;; *) fail "no arm64 slice ($ARCHS)";; esac
case " $ARCHS " in *" x86_64 "*) ;; *) fail "no x86_64 slice ($ARCHS)";; esac
codesign --force --deep -s - dist/Neve.app
rm -f "dist/Neve-$V.zip"
ditto -c -k --keepParent dist/Neve.app "dist/Neve-$V.zip"
lipo -archs dist/Neve.app/Contents/MacOS/Neve
shasum -a 256 "dist/Neve-$V.zip"
