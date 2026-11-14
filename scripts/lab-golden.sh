#!/bin/sh
# AGENT HEADER - scripts/lab-golden.sh
# Role: conscious regeneration of the Neve Lab golden PNGs (Tests/LabGolden/<GPU>-macos<N>/). Usage: scripts/lab-golden.sh --update [scene]   (no scene = all). Runs only the LabGolden test in update mode (NEVE_GOLDEN_UPDATE),
# prints NEW / UPDATED / UNCHANGED per image; review with `git diff --stat Tests/LabGolden` and by LOOKING at the changed PNGs before committing. Plain verification is just Tests/run.sh LabGolden.
set -e
cd "$(dirname "$0")/.."
[ "$1" = "--update" ] || { echo "usage: scripts/lab-golden.sh --update [scene]" >&2; exit 2; }
NEVE_GOLDEN_UPDATE=${2:-1} Tests/run.sh LabGolden 2>&1 | grep -E "LAB-GOLDEN|error|failed|Issue" || true
