import { FieldValue } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';
import { LYZR_SECRETS } from '../ai/lyzr';
import {
  StoredPlanProfile,
  generateAndStoreDietPlan,
  generateAndStoreWorkoutPlan,
} from './plan';
import { computeTargets, Goal, TargetInputs } from './targets';

interface OnboardingProfile {
  displayName: string;
  sex: 'male' | 'female';
  birthDate: string; // ISO; age derived server-side
  heightCm: number;
  weightKg: number;
  activityLevel: TargetInputs['activityLevel'];
  goal: Goal;
  goalFreeText?: string;
  bodyFatPct?: number;
  dietType: string;
  dietaryRestrictions: string[];
  trainingDaysPerWeek: number;
  preferredWeekdays: number[]; // 0=Sun..6=Sat
  experience: string;
  equipment: string[];
  injuriesNotes: string;
  freeFormContext: string;
}

function ageFromBirthDate(iso: string, now: Date): number {
  const b = new Date(iso);
  let age = now.getFullYear() - b.getFullYear();
  const m = now.getMonth() - b.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < b.getDate())) age--;
  return age;
}

/**
 * POST /users/complete-onboarding (spec §4).
 * 1. Store this user's profile.  2. Compute targets deterministically (§5).  3. Return.
 *
 * This does NOT generate any plan. The user lands on the home screen with their
 * targets; they then choose to generate a workout and/or diet plan on demand from
 * Settings (which flips the relevant *PlanStatus to 'generating' and fires the
 * onUserPlanRequested trigger). Onboarding never blocks on an agent call.
 */
export const completeOnboarding = onCall(
  { timeoutSeconds: 30, memory: '256MiB' },
  async (req) => {
    const uid = requireUid(req);
    try {
      const p = req.data?.profile as OnboardingProfile;
      if (!p) throw new Error('profile required');

      const age = ageFromBirthDate(p.birthDate, new Date());
      const targets = computeTargets({
        sex: p.sex,
        age,
        heightCm: p.heightCm,
        weightKg: p.weightKg,
        activityLevel: p.activityLevel,
        goal: p.goal,
        bodyFatPct: p.bodyFatPct,
      });

      // Persist profile + targets immediately, and flag the plan as generating.
      // Writing planStatus='generating' is what fires the async plan trigger.
      await db.doc(`users/${uid}`).set(
        {
          ...p,
          // Persist as a Date so Firestore stores a Timestamp — the iOS client
          // decodes UserProfile.birthDate as a Date, and a raw ISO string would
          // fail that decode (stranding the user on onboarding).
          birthDate: new Date(p.birthDate),
          age,
          calorieTarget: targets.calorieTarget,
          proteinTargetG: targets.proteinTargetG,
          carbTargetG: targets.carbTargetG,
          fatTargetG: targets.fatTargetG,
          bmr: targets.bmr,
          tdee: targets.tdee,
          targetsComputedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
          onboardedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      // No plan generated here — the client routes on targets and the user
      // generates plans on demand from Settings.
      return { targets };
    } catch (err) {
      throw toHttpsError(err);
    }
  },
);

// Plan generation runs inline in these callables. The function marks the status
// 'generating' first (so any other listening device reflects it), runs the matching
// Lyzr agent, then reads the resulting status back. generateAndStore* never throws —
// it records 'failed' + the error on the user doc — so the client always gets a
// definitive status via this return value and/or its profile stream.
//
// timeoutSeconds MUST exceed the Lyzr call's worst case (~181s, see runLyzrAgent),
// or the platform kills the function mid-flight before the catch can write a
// terminal status — leaving the user permanently stranded on 'generating'.
const planCallOpts = { secrets: LYZR_SECRETS, timeoutSeconds: 240, memory: '512MiB' as const };

async function loadPlanProfile(uid: string): Promise<StoredPlanProfile> {
  const snap = await db.doc(`users/${uid}`).get();
  if (!snap.exists || snap.get('calorieTarget') == null) {
    throw new Error('complete onboarding before generating a plan');
  }
  return snap.data() as StoredPlanProfile;
}

/** POST /users/generate-workout-plan — generate or regenerate the workout plan (spec §11.1). */
export const generateWorkoutPlan = onCall(planCallOpts, async (req) => {
  const uid = requireUid(req);
  try {
    const profile = await loadPlanProfile(uid);
    await db.doc(`users/${uid}`).set(
      { workoutPlanStatus: 'generating', workoutPlanError: FieldValue.delete() },
      { merge: true },
    );
    await generateAndStoreWorkoutPlan(uid, profile);
    const status = (await db.doc(`users/${uid}`).get()).get('workoutPlanStatus');
    return { workoutPlanStatus: status ?? 'failed' };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** POST /users/generate-diet-plan — generate or regenerate the diet plan. */
export const generateDietPlan = onCall(planCallOpts, async (req) => {
  const uid = requireUid(req);
  try {
    const profile = await loadPlanProfile(uid);
    await db.doc(`users/${uid}`).set(
      { dietPlanStatus: 'generating', dietPlanError: FieldValue.delete() },
      { merge: true },
    );
    await generateAndStoreDietPlan(uid, profile);
    const status = (await db.doc(`users/${uid}`).get()).get('dietPlanStatus');
    return { dietPlanStatus: status ?? 'failed' };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** POST /users/recompute-targets — re-run §5 after a stat/goal edit. */
export const recomputeTargets = onCall(async (req) => {
  const uid = requireUid(req);
  try {
    const i = req.data?.inputs as TargetInputs;
    if (!i) throw new Error('inputs required');
    const targets = computeTargets(i);
    await db.doc(`users/${uid}`).set(
      {
        calorieTarget: targets.calorieTarget,
        proteinTargetG: targets.proteinTargetG,
        carbTargetG: targets.carbTargetG,
        fatTargetG: targets.fatTargetG,
        bmr: targets.bmr,
        tdee: targets.tdee,
        targetsComputedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return { targets };
  } catch (err) {
    throw toHttpsError(err);
  }
});
