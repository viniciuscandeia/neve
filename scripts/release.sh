#!/bin/bash
# Usage: scripts/release.sh VERSION -> dist/Neve-VERSION.zip (universal, ad-hoc signed).
# Builds into dist/Neve.app so the locally signed build/Neve.app you run (and its Accessibility grant) is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: release.sh VERSION}
export NEVE_VERSION=$V NEVE_SIGN=- NEVE_UNIVERSAL=1 NEVE_APP_DIR=dist
mkdir -p dist
scripts/make-app.sh
codesign --force --deep -s - dist/Neve.app
rm -f "dist/Neve-$V.zip"
ditto -c -k --keepParent dist/Neve.app "dist/Neve-$V.zip"
lipo -archs dist/Neve.app/Contents/MacOS/Neve
shasum -a 256 "dist/Neve-$V.zip"
