import { setGlobalOptions } from 'firebase-functions/v2';

// FitTrack Cloud Functions entrypoint. All AI keys live in secrets here — the
// app never holds them (spec §13).
setGlobalOptions({ region: 'us-central1', maxInstances: 20 });

// AI food service (spec §10–11) — meal photo / label / text estimation (Gemini).
// Plan generation moved to the Lyzr agents (see users/* below).
export { analyzeMeal, parseLabel, estimateText } from './ai/handlers';

// Users / onboarding / targets (spec §4–5) + on-demand plan generation.
// generateWorkoutPlan / generateDietPlan run the Lyzr agents inline and persist
// the plan (workoutPlans/current, dietPlans/current); the client streams it in.
export {
  completeOnboarding,
  recomputeTargets,
  generateWorkoutPlan,
  generateDietPlan,
} from './users/handlers';

// Food lookup (spec §7.3 / §12)
export { foodBarcode, foodSearch } from './food/handlers';

// Exercise catalog (spec §7.2 / §12)
export { searchExercises, getExercise, createCustomExercise } from './exercises/handlers';

// Account deletion (spec §13: delete account + all data)
export { deleteAccount } from './users/deletion';

// Account data export (spec §13: export account data)
export { exportData } from './users/export';
