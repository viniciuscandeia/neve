#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Dev bundle: NEVE_DEV=<name> (or --dev <name>) -> build/Neve-<name>.app, own bundle id, executable Neve-dev-<name>.
[ "${1:-}" = "--dev" ] && NEVE_DEV=$2
swift build -c release
BID=io.github.viniciuscandeia.neve; APP=build/Neve.app; EXE=Neve; EXTRA=""
if [ -n "${NEVE_DEV:-}" ]; then
  BID=$BID.dev; APP="build/Neve-$NEVE_DEV.app"; EXE="Neve-dev-$NEVE_DEV"
  EXTRA="<key>NeveInstance</key><string>$NEVE_DEV</string>"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Neve" "$APP/Contents/MacOS/$EXE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$BID</string>
	<key>CFBundleName</key><string>Neve</string>
	<key>CFBundleExecutable</key><string>$EXE</string>
	$EXTRA
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAudioCaptureUsageDescription</key><string>A Neve usa o áudio que está tocando no Mac só para fazer a neve dançar no ritmo da música. Nada é gravado ou enviado.</string>
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
codesign --force --sign "$SIGN" --identifier "$BID" "$APP"
echo "Built $APP"
