import { setGlobalOptions } from 'firebase-functions/v2';

// FitTrack Cloud Functions entrypoint. All AI keys live in secrets here — the
// app never holds them (spec §13).
setGlobalOptions({ region: 'us-central1', maxInstances: 20 });

// AI food service (spec §10–11) — meal photo / label / text estimation (Gemini).
// Plan generation moved to the Lyzr agents (see users/* below).
export { analyzeMeal, parseLabel, estimateText, mealChat } from './ai/handlers';

// Diet coach chat + 7-day plan generation (Gemini/OpenRouter). A conversational
// surface where the user describes what they want, then generates a weekly plan
// into dietPlans/current (streamed into the Diet tab like any other plan).
export { dietCoachReply, generateDietPlanFromChat } from './ai/dietCoach';

// Users / onboarding / targets (spec §4–5) + on-demand plan generation.
// generateWorkoutPlan / generateDietPlan run the Lyzr agents inline and persist
// the plan (workoutPlans/current, dietPlans/current); the client streams it in.
export {
  completeOnboarding,
  updateProfile,
  recomputeTargets,
  generateWorkoutPlan,
  generateDietPlan,
} from './users/handlers';

// Food lookup (spec §7.3 / §12)
export { foodBarcode, foodSearch } from './food/handlers';

// Exercise catalog (spec §7.2 / §12)
export { searchExercises, getExercise, createCustomExercise } from './exercises/handlers';

// Telegram bot — a second front-end onto the same Firestore data. The webhook
// is the bot's only public surface; the two callables are the app's side of
// account linking (see functions/src/telegram/README-ish comments).
export { telegramWebhook } from './telegram/webhook';
export { createTelegramLinkCode, unlinkTelegram } from './telegram/handlers';

// Account deletion (spec §13: delete account + all data)
export { deleteAccount } from './users/deletion';

// Account data export (spec §13: export account data)
export { exportData } from './users/export';
