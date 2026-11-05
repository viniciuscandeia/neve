#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Neve.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Neve" "$APP/Contents/MacOS/Neve"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>io.github.viniciuscandeia.neve</string>
	<key>CFBundleName</key><string>Neve</string>
	<key>CFBundleExecutable</key><string>Neve</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Stable identity keeps privacy permissions across rebuilds (create it with scripts/make-cert.sh).
SIGN="-"
if security find-identity -p codesigning | grep -q "Neve Local Signing"; then
  SIGN="Neve Local Signing"
else
  echo "WARNING: 'Neve Local Signing' identity not found; signing ad-hoc. Privacy permissions (Accessibility) will be lost on every rebuild. Run scripts/make-cert.sh first." >&2
fi
codesign --force --sign "$SIGN" --identifier io.github.viniciuscandeia.neve "$APP"
echo "Built $APP"
