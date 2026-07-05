---
name: ship-it
description: Release FitTrack — deploy backend if changed, build + upload the iOS app (incl. the home-screen widgets) to TestFlight, and confirm processing. Use when the user says "ship it", "release", "publish to TestFlight", or "upload a new build".
---

# Ship a FitTrack release

Ships the **whole app**: the iOS app target *and* the embedded `FitTrackWidgets`
extension, backend included. Work through these steps in order; report progress
between steps.

## 1. Preflight (fast, fail early)
- `git -C /Users/lappy/code/FitTrack status --porcelain` — note uncommitted changes (informational; don't block).
- Verify credentials exist: `~/.appstoreconnect/private_keys/AuthKey_GQ653NHYST.p8`, `security find-identity -v -p codesigning | grep "Apple Distribution.*7MFYAGK3VV"`, and `ios/FitTrack/GoogleService-Info.plist`. If any is missing, stop and tell the user (see CLAUDE.md "One-time machine setup").
- **Provisioning profiles** — release builds sign *manually* and need two installed profiles: **"FitTrack App Store"** (`com.shobhit.fittrack`) and **"FitTrack Widgets App Store"** (`com.shobhit.fittrack.Widgets`). Check they exist:
  ```bash
  for p in ~/Library/MobileDevice/"Provisioning Profiles"/*.mobileprovision; do
    security cms -D -i "$p" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null
  done | grep -c "FitTrack .*App Store"
  ```
  If this prints fewer than 2, regenerate them: `python3 ios/create_profiles.py` (creates + installs both from the App Store Connect API). This is normal on a fresh machine or after a cert/profile expiry.

## 2. Backend (only if changed)
- If `git diff HEAD --stat -- functions firebase.json` shows changes **or** the user said the backend changed: run `cd functions && npm run deploy` (requires `functions/.env` and a logged-in Firebase CLI). If `firebase: command not found`, use `npx firebase-tools deploy --only functions` instead. On env/login errors, stop and surface the fix from CLAUDE.md.
- Otherwise skip and say so.

## 3. iOS build + upload
- Run `cd ios && bash sign_and_build.sh` as a background task (takes 10–20 min). The script auto-bumps the build number, runs xcodegen, archives both targets, signs manually with the profiles above, exports, and uploads.
- **Note:** `sign_and_build.sh` exits 0 even when the *export/upload* fails — do NOT trust the exit code. Confirm the log tail actually ends with `Upload succeeded` / `EXPORT SUCCEEDED`. dSYM warnings for Firebase frameworks (grpc, absl, FirebaseFirestoreInternal, etc.) are harmless — ignore them.
- If it fails, read `ios/build/build.log` and match the error:
  - `No profiles for 'com.shobhit.fittrack.Widgets'` / `doesn't support the group.com.shobhit.fittrack App Group` / empty `application-groups` in a profile → the widget App ID is missing the App Group assignment in the portal (capability enabled ≠ group assigned). The user must open the `com.shobhit.fittrack.Widgets` App ID at developer.apple.com → App Groups → **Configure** → tick `group.com.shobhit.fittrack` → Save. Then rerun `python3 ios/create_profiles.py` and rebuild. (App Group assignment is portal-only — no API.)
  - `Authentication failed: bearer token expired` during `GatherProvisioningInputs` → stale/auto-signing path; ensure the two manual profiles are installed (step 1) and rebuild.
  - `UISupportedInterfaceOrientations ... need to include all ... orientations` → an iPhone-only portrait app must set `UIRequiresFullScreen: true` in `project.yml` (already set; only relevant if it was removed).

## 4. Confirm processing
- Run `bash ios/check_status.sh`. The new build shows `PROCESSING` then `VALID` (usually within ~15 min). Poll a couple of times if needed; don't spin forever — if still `PROCESSING` after two checks, report that it's uploaded and processing.

## 5. Report
Tell the user: the new build number, its processing state, and the next manual step — distribute at appstoreconnect.apple.com → **Log Fitness** → TestFlight (internal group = instant; external group/public link = Beta App Review on first build of a version).
