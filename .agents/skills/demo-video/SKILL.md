---
name: demo-video
description: Record a marketing/social demo video, a 30-second vertical reel, and screenshots of the FitTrack iOS app using seeded demo mode + an automated walkthrough. Use when the user says "make a demo video", "record a demo", "make a reel", "app preview video", "screenshots for the App Store / social", or similar.
---

# Record a FitTrack demo video

Produces a polished screen recording, a captioned 30-second reel, and key
screenshots of the app with fully-populated screens — no real account or backend
needed. Everything runs on the iOS Simulator.

## Commands

Full walkthrough video + screenshots (self-contained, no ffmpeg):
```bash
bash ios/record_demo.sh
```
Captioned 30-second vertical (9:16) reel (needs ffmpeg — `brew install ffmpeg`):
```bash
bash ios/make_reel.sh          # uses the FitTrack-demo-hq.mp4 from record_demo
```

Outputs to `~/Desktop/FitTrack-demo/` (override with `OUT_DIR=...`):
- `FitTrack-demo.mp4` — compact H.264 (~60 MB), ~100 s → the full walkthrough to post
- `FitTrack-demo-hq.mp4` — full-resolution, lossless trim (source for the reel)
- `FitTrack-reel.mp4` — 30 s, 1080×1920, captioned, branded background → **best for Reels/TikTok/Shorts**
- `FitTrack-screens/` — full-res PNG screenshots spanning Today / Workout / Diet / Progress / Log

Simulator defaults to **iPhone 17** (override with `SIM_NAME="iPhone 16"`). On the
lappy Mac the iPhone 17 Pro sim fails to boot — use plain iPhone 17.

The script: regenerates the project → builds the `FitTrackDemo` scheme →
overrides the status bar to a clean 9:41 → screen-records while running the
`DemoWalkthrough` UI test → auto-detects and trims the dead time → exports the
videos and screenshots.

## How it works (what to touch if changing it)

- **Demo mode** is gated on the `FITTRACK_DEMO=1` environment variable, set
  ONLY by the UI test — never in a normal build, and nothing ships. When active,
  `AuthService` presents a signed-in "Alex" and every `Repository` read serves
  seeded data (writes no-op). See:
  - `ios/FitTrack/Services/DemoData.swift` — all seeded content (profile,
    meals, workout plan, 7-day diet plan, ~30 days of weight/calorie history,
    workout sessions). Edit here to change what the video shows. Dates are
    relative to "now" so it always looks current.
  - `ios/FitTrack/Services/AuthService.swift` and `Repository*.swift` — the
    `if Demo.isActive { … }` branches.
- **The walkthrough / pacing**: `ios/FitTrackUITests/DemoWalkthrough.swift`.
  Change the tab order, taps, or `hold(...)` durations to re-pace the tour.
- **Project wiring**: `ios/project.yml` defines the `FitTrackUITests` target and
  the `FitTrackDemo` scheme. Run `xcodegen generate` after editing (the script
  does this). The release `FitTrack` scheme is separate — `sign_and_build.sh` is
  unaffected.
- **Media processing**: `ios/scripts/demo_media.swift` (trim / detect bounds /
  extract frames), driven via the Swift interpreter — no ffmpeg dependency.
- **The reel**: `ios/make_reel.sh` picks 7 segments (by fraction of the source,
  so it's robust to per-run timing drift), composites each onto a branded
  gradient with a caption card, and stitches them to ~30 s. Edit the `SEG`
  array to change captions/segments. Caption cards are rendered by
  `ios/scripts/render_reel_assets.swift` (AppKit — this Homebrew ffmpeg has no
  drawtext). Segment starts use `setpts=PTS-STARTPTS` and the join re-encodes
  (never `-c copy`) — both are required to avoid blank frames at cut points.

## Tips
- Requires `ios/FitTrack/GoogleService-Info.plist` present (Firebase configures
  at launch even in demo mode). It's gitignored — copy between machines.
- To change which screenshots are captured, edit the fraction list in
  `record_demo.sh` (the `awk` step) or call
  `swift ios/scripts/demo_media.swift frames <video> <outdir> <t1,t2,...>`.
- The reel has no audio (add trending music in the IG/TikTok editor). At 30 s it
  fits IG Reels (≤90 s), TikTok, and YouTube Shorts.
