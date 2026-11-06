#!/bin/bash
# Usage: scripts/release.sh VERSION -> dist/Neve-VERSION.zip (universal, ad-hoc signed)
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: release.sh VERSION}
export NEVE_VERSION=$V NEVE_SIGN=- NEVE_UNIVERSAL=1
scripts/make-app.sh
codesign --force --deep -s - build/Neve.app
mkdir -p dist; rm -f "dist/Neve-$V.zip"
ditto -c -k --keepParent build/Neve.app "dist/Neve-$V.zip"
lipo -archs build/Neve.app/Contents/MacOS/Neve
shasum -a 256 "dist/Neve-$V.zip"
