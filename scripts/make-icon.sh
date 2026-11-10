#!/bin/bash
# Regenerates Resources/Neve.icns (committed, so builds don't need this): draws a 1024 PNG, scales it with sips, packs it with iconutil.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); SET=$T/Neve.iconset; mkdir -p "$SET" Resources
swift scripts/make-icon.swift "$T/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/Neve.icns
rm -rf "$T"
echo "Wrote Resources/Neve.icns"
