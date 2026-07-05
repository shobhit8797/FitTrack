#!/usr/bin/env bash
#
# make_reel.sh — cut a polished 30-second vertical (9:16) reel from the demo
# recording, with animated captions on a branded background. Requires ffmpeg
# (`brew install ffmpeg`) and a source video from record_demo.sh.
#
# Usage:  bash ios/make_reel.sh [path/to/FitTrack-demo-hq.mp4]
# Env:    OUT_DIR (default ~/Desktop/FitTrack-demo)
#
set -euo pipefail
cd "$(dirname "$0")"                                   # -> ios/

OUT_DIR="${OUT_DIR:-$HOME/Desktop/FitTrack-demo}"
SRC="${1:-$OUT_DIR/FitTrack-demo-hq.mp4}"
[ -f "$SRC" ] || { echo "❌ source not found: $SRC (run: bash ios/record_demo.sh)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "❌ ffmpeg not installed (brew install ffmpeg)"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$OUT_DIR/FitTrack-reel.mp4"
log() { printf '\033[1;36m▶︎ %s\033[0m\n' "$*"; }

# Segments: FRACTION DUR "CAPTION". FRACTION is the start as a proportion of the
# source duration (robust to per-run timing drift — mirrors the screenshot step).
# Durations total ≈ 30s.
SEG=(
  "0.010 4.2  Your whole day,\nat a glance"
  "0.085 4.2  Log meals\nin seconds"
  "0.225 4.6  AI-built\nworkout plans"
  "0.500 4.2  7-day meal plans,\nauto-built"
  "0.635 4.6  Track every trend"
  "0.795 4.2  Watch your\nstrength climb"
  "0.900 4.0  Your AI\nfitness coach"
)
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$SRC")

# Render background + caption cards.
CAPS=(); for s in "${SEG[@]}"; do CAPS+=("$(echo "$s" | awk '{$1=$2=""; sub(/^  */,""); print}')"); done
log "Rendering ${#CAPS[@]} caption cards…"
swift scripts/render_reel_assets.swift "$WORK" "${CAPS[@]}" >/dev/null

# Build each segment: phone screen scaled onto the gradient bg + caption overlay.
log "Composing segments…"
i=0
: > "$WORK/list.txt"
for s in "${SEG[@]}"; do
  i=$((i+1))
  FRAC=$(echo "$s" | awk '{print $1}')
  DUR=$(echo "$s"  | awk '{print $2}')
  # Resolve fraction → absolute start, clamped so START+DUR stays in the source.
  START=$(awk -v f="$FRAC" -v d="$SRC_DUR" -v du="$DUR" 'BEGIN{s=f*d; if(s+du>d-0.15)s=d-du-0.15; if(s<0)s=0; printf "%.2f", s}')
  CAP=$(printf '%02d' "$i")
  ffmpeg -y -v error \
    -ss "$START" -t "$DUR" -i "$SRC" \
    -loop 1 -t "$DUR" -i "$WORK/bg.png" \
    -loop 1 -t "$DUR" -i "$WORK/cap_$CAP.png" \
    -filter_complex "[0:v]setpts=PTS-STARTPTS,fps=30,scale=-2:1320,setsar=1[ph];[1:v][ph]overlay=(W-w)/2:360[b];[b][2:v]overlay=0:0:shortest=1,format=yuv420p[v]" \
    -map "[v]" -r 30 -c:v libx264 -profile:v high -preset medium -crf 20 \
    -video_track_timescale 30000 "$WORK/seg_$CAP.mp4"
  echo "file 'seg_$CAP.mp4'" >> "$WORK/list.txt"
done

# Concatenate (re-encode, not -c copy: copying independently-keyframed segments
# corrupts the frames right after each boundary), then fade + faststart.
log "Stitching + finishing…"
ffmpeg -y -v error -f concat -safe 0 -i "$WORK/list.txt" \
  -c:v libx264 -profile:v high -crf 20 -pix_fmt yuv420p "$WORK/joined.mp4"
TOTAL=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$WORK/joined.mp4")
OUTPOINT=$(awk -v d="$TOTAL" 'BEGIN{printf "%.2f", d-0.5}')
mkdir -p "$OUT_DIR"
ffmpeg -y -v error -i "$WORK/joined.mp4" \
  -vf "fade=t=in:st=0:d=0.4,fade=t=out:st=$OUTPOINT:d=0.5" \
  -c:v libx264 -profile:v high -crf 20 -pix_fmt yuv420p -movflags +faststart "$OUT"

printf '\n\033[1;32m✅ Reel:\033[0m %s  (%.0fs, 1080x1920)\n' "$OUT" "$TOTAL"
