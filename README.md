# FitTrack

A native iPhone fitness + nutrition tracker (Swift/SwiftUI) on a Firebase backend.
Built to the FitTrack v2 build spec, mapped onto Firebase (see table below).

## Repository layout

```
fittrack/
├── firebase.json, .firebaserc        # Firebase project config
├── firestore.rules                   # per-user data isolation (spec §13)
├── storage.rules                     # meal-photo access control
├── firestore.indexes.json
├── functions/                        # backend — Cloud Functions (TypeScript)
│   └── src/
│       ├── ai/        # OpenRouter/Gemini provider abstraction + /ai callables
│       ├── users/     # targets math (deterministic) + onboarding + deletion
│       ├── food/      # Open Food Facts proxy + IFCT grounding/search
│       ├── exercises/ # catalog search + custom exercises
│       ├── lib/       # admin init, auth guards
│       └── seed/      # exercise + IFCT seed data and runner
└── ios/FitTrack/                     # iOS app (SwiftUI, MVVM + services)
    ├── App/           # entry, root routing, TabView
    ├── Models/        # Codable domain models (mirror Firestore docs)
    ├── Services/      # Auth, Repository (Firestore), Functions, HealthKit
    ├── DesignSystem/  # theme, calorie ring, macro bars, components
    └── Features/      # Onboarding, Dashboard, Logging, Workout, Progress, Settings
```

## How the v2 spec maps onto Firebase

| Spec (Postgres-based) | This implementation |
|---|---|
| Custom JWT auth (Apple/Google/email) | **Firebase Auth** — same three providers, built-in account linking |
| Postgres + per-endpoint authz | **Firestore** + **Security Rules** scoping every doc to `request.auth.uid` |
| Custom REST + delta sync (§9) | **Firestore offline persistence** (native cache + sync) |
| AI proxy backend, keys in env (§10) | **Cloud Functions** (callable); keys in **Functions secrets** |
| Meal-photo object storage | **Firebase Storage** + rules |
| Targets math server-side (§5) | Cloud Function, deterministic, unit-tested |

The deterministic targets math, the OpenRouter⇄Gemini swap (config only), the
hybrid food accuracy (LLM + Open Food Facts + IFCT), per-user data, and
"no app-wide default targets" requirements are all preserved.

## Backend — run & deploy

```bash
cd functions
npm install
npm run build          # tsc
npm test               # targets math unit tests (node --test)
npm run serve          # local emulators (functions, firestore, auth, storage)
npm run seed           # seed exercise catalog + IFCT foods (against emulator/prod)
npm run deploy         # firebase deploy --only functions
```

### Configure the AI provider (spec §10 — the only place keys live)

```bash
# Choose provider + models (no app redeploy needed to change models)
firebase functions:config  # legacy; this project uses params/secrets:
#   PROVIDER = openrouter | gemini
#   MODEL_OPENROUTER = google/gemini-3.5-flash
#   MODEL_GEMINI = gemini-3.5-flash
firebase functions:secrets:set OPENROUTER_API_KEY
firebase functions:secrets:set GEMINI_API_KEY
```

Set `PROVIDER`/`MODEL_*` as environment params in `functions/.env` (gitignored)
or via the Firebase console. **Verify the current model id** against each
provider's models page at deploy time.

## iOS — Xcode setup

The Swift sources are complete, but a `.xcodeproj` and the Firebase SDK must be
added in Xcode (SourceKit "No such module 'Firebase…'" errors disappear once
the packages resolve):

1. **Create the project**: Xcode → New → App → "FitTrack", iOS 17+, SwiftUI.
   Add the existing `ios/FitTrack/` source folders to the target.
2. **Add Firebase via SPM**: `https://github.com/firebase/firebase-ios-sdk`
   — products: `FirebaseAuth`, `FirebaseFirestore`, `FirebaseFunctions`,
   `FirebaseStorage`, `FirebaseCore`.
3. **Add Google Sign-In via SPM**: `https://github.com/google/GoogleSignIn-iOS`
   and implement `GoogleSignInHelper.signIn()` in `SignInView.swift`.
4. **Drop in `GoogleService-Info.plist`** from the Firebase console (gitignored).
5. **Capabilities**: Sign in with Apple; HealthKit; Background Modes (if using
   HealthKit observer queries).
6. **Info.plist**: merge the usage strings from `Resources/Info.plist` and set
   the reversed Google client ID URL scheme.

## Status

- ✅ Backend: config, security rules, full AI service (both providers), targets
  math (tested), onboarding/deletion, food + exercise functions, seed data.
- ✅ iOS: models, services (Auth/Repository/Functions/HealthKit), design system,
  sign-in, onboarding, Today dashboard, text/weight logging, workout plan +
  session logging, progress (weight chart), settings.
- 🔜 Next: camera/VisionKit photo + barcode + label OCR capture flows; remaining
  progress charts (calories/macros/adherence heatmap); data export; push of last
  session's weights for progressive overload; broader exercise/IFCT datasets.

*Not medical advice.*
