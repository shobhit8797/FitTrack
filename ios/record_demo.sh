#!/usr/bin/env bash
#
# record_demo.sh — one command to produce a marketing demo video of FitTrack.
#
# Boots the seeded DEMO MODE (no Firebase, no account) and drives a scripted
# XCUITest walkthrough (Today → Workout → Diet → Progress → Log) on the
# simulator while screen-recording, then auto-trims the dead time and exports:
#   • FitTrack-demo.mp4      compact H.264 (~50 MB) — post this
#   • FitTrack-demo-hq.mp4   full-resolution, lossless trim
#   • FitTrack-screens/      key full-res screenshots
#
# Everything is self-contained (AVFoundation via ios/scripts/demo_media.swift) —
# no ffmpeg required. Demo mode is gated on the FITTRACK_DEMO env var, which is
# ONLY set here for the test run; it never affects a normal build.
#
# Usage:   bash ios/record_demo.sh
# Env:     SIM_NAME (default "iPhone 17")   OUT_DIR (default ~/Desktop)
#
set -euo pipefail

cd "$(dirname "$0")"                          # -> ios/
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SIM_NAME="${SIM_NAME:-iPhone 17}"
SCHEME="FitTrackDemo"
PROJECT="FitTrack.xcodeproj"
OUT_DIR="${OUT_DIR:-$HOME/Desktop}"
HELPER="scripts/demo_media.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;36m▶︎ %s\033[0m\n' "$*"; }

log "Generating Xcode project (xcodegen)…"
xcodegen generate >/dev/null

log "Resolving simulator '$SIM_NAME'…"
UDID="$(xcrun simctl list devices available | awk -v n="$SIM_NAME (" 'index($0,n){ if (match($0,/[0-9A-Fa-f-]{36}/)) { print substr($0,RSTART,RLENGTH); exit } }')"
[ -n "$UDID" ] || { echo "❌ No available simulator named '$SIM_NAME'. Try: SIM_NAME='iPhone 16' bash ios/record_demo.sh"; exit 1; }
echo "   $SIM_NAME → $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
open -a Simulator >/dev/null 2>&1 || true

log "Building for testing (scheme $SCHEME)…"
xcodebuild build-for-testing -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$UDID" -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet

log "Overriding status bar (clean 9:41)…"
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged \
  --batteryLevel 100 --cellularBars 4 --cellularMode active --wifiBars 3 --dataNetwork wifi >/dev/null 2>&1 || true

RAW="$WORK/raw.mp4"
log "Recording + running walkthrough…"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$RAW" >/dev/null 2>&1 &
REC_PID=$!

# The test spin-up gives the recorder ample time to start; the lead-in dead time
# is stripped by `detect` afterwards.
xcodebuild test-without-building -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$UDID" -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet || true

kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true

log "Detecting app content bounds…"
read -r START END < <(swift "$HELPER" detect "$RAW" 2>/dev/null)
echo "   content ${START}s → ${END}s"

mkdir -p "$OUT_DIR"
log "Exporting full-res (lossless) video…"
swift "$HELPER" trim "$RAW" "$OUT_DIR/FitTrack-demo-hq.mp4" "$START" "$END" >/dev/null 2>&1

log "Exporting compact (postable) video…"
swift "$HELPER" trim "$RAW" "$OUT_DIR/FitTrack-demo.mp4" "$START" "$END" AVAssetExportPreset1280x720 >/dev/null 2>&1

log "Grabbing key screenshots…"
# Deterministic stills at fractions of the app content — spans
# Today / Workout / Diet / Progress / Log regardless of exact timing.
TIMES="$(awk -v s="$START" -v e="$END" 'BEGIN{
  n=split("0.05 0.20 0.34 0.48 0.62 0.78 0.94",f," ");
  for(i=1;i<=n;i++){ printf "%s%.2f",(i>1?",":""), s+(e-s)*f[i] }
}')"
swift "$HELPER" frames "$OUT_DIR/FitTrack-demo-hq.mp4" "$OUT_DIR/FitTrack-screens" "$TIMES" >/dev/null 2>&1

printf '\n\033[1;32m✅ Done\033[0m\n'
echo "   • $OUT_DIR/FitTrack-demo.mp4      (compact — post this)"
echo "   • $OUT_DIR/FitTrack-demo-hq.mp4   (full resolution)"
echo "   • $OUT_DIR/FitTrack-screens/      (screenshots)"
