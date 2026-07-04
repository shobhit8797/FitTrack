---
name: ship-it
description: Release FitTrack — deploy backend if changed, build + upload the iOS app to TestFlight, and confirm processing. Use when the user says "ship it", "release", "publish to TestFlight", or "upload a new build".
---

# Ship a FitTrack release

Run the full release pipeline. Work through these steps in order; report progress between steps.

## 1. Preflight (fast, fail early)
- `git -C /Users/lappy/FitTrack status --porcelain` — note uncommitted changes (informational; don't block).
- Verify credentials exist: `~/.appstoreconnect/private_keys/AuthKey_GQ653NHYST.p8`, `security find-identity -v -p codesigning | grep "Apple Distribution.*7MFYAGK3VV"`, and `ios/FitTrack/GoogleService-Info.plist`. If any is missing, stop and tell the user (see CLAUDE.md "One-time machine setup").

## 2. Backend (only if changed)
- If `git diff HEAD --stat -- functions firebase.json` shows changes **or** the user said the backend changed: run `cd functions && npm run deploy` (requires `functions/.env` and a logged-in Firebase CLI). On env/login errors, stop and surface the fix from CLAUDE.md.
- Otherwise skip and say so.

## 3. iOS build + upload
- Run `cd ios && bash sign_and_build.sh` as a background task (takes 10–20 min). The script auto-bumps the build number, runs xcodegen, archives, signs, and uploads.
- When it finishes, confirm the log ends with `Upload succeeded` / `EXPORT SUCCEEDED`. dSYM warnings for Firebase frameworks (grpc, absl, etc.) are harmless — ignore them.
- If the archive fails on signing, remind the user to approve the keychain dialog on screen.

## 4. Confirm processing
- Run `bash ios/check_status.sh`. The new build shows `PROCESSING` then `VALID` (usually within ~15 min). Poll a couple of times if needed; don't spin forever — if still `PROCESSING` after two checks, report that it's uploaded and processing.

## 5. Report
Tell the user: the new build number, its processing state, and the next manual step — distribute at appstoreconnect.apple.com → **Log Fitness** → TestFlight (internal group = instant; external group/public link = Beta App Review on first build of a version).
