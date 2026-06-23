import { FieldValue } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';
import { AI_SECRETS, makeProvider } from '../ai/factory';
import { parseJson } from '../ai/json';
import { PLAN_SYSTEM, planUser } from '../ai/prompts';
import { validatePlan } from '../ai/schemas';
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
 * 1. Store this user's profile.  2. Compute targets deterministically (§5).
 * 3. Generate a workout plan via the AI service (§11.1).  4. Persist both.
 * No app-wide defaults — everything is derived from this user's inputs.
 */
export const completeOnboarding = onCall(
  { secrets: AI_SECRETS, timeoutSeconds: 120, memory: '512MiB' },
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

      const userRef = db.doc(`users/${uid}`);

      // Generate plan (AI). Falls through to profile+targets save even if AI fails,
      // so onboarding never hard-blocks on connectivity (spec §9 degradation).
      let plan = null;
      let planError: string | null = null;
      try {
        const provider = makeProvider();
        const weekdayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
        const res = await provider.complete({
          system: PLAN_SYSTEM,
          user: planUser({
            sex: p.sex,
            age,
            heightCm: p.heightCm,
            weightKg: p.weightKg,
            goal: p.goalFreeText ? `${p.goal} (${p.goalFreeText})` : p.goal,
            trainingDaysPerWeek: p.trainingDaysPerWeek,
            preferredWeekdays: p.preferredWeekdays.map((d) => weekdayNames[d]).join(','),
            experience: p.experience,
            equipment: p.equipment.join(','),
            dietType: p.dietType,
            restrictions: p.dietaryRestrictions.join(','),
            injuriesNotes: p.injuriesNotes,
            freeFormContext: p.freeFormContext,
          }),
          jsonObject: true,
          temperature: 0.5,
          maxTokens: 3000,
        });
        plan = validatePlan(parseJson(res.text));
      } catch (e) {
        planError = e instanceof Error ? e.message : String(e);
      }

      // Atomic-ish write: profile + targets together, then plan in its subcollection.
      await userRef.set(
        {
          ...p,
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

      if (plan) {
        await userRef.collection('workoutPlans').doc('current').set({
          ...plan,
          generatedAt: FieldValue.serverTimestamp(),
        });
      }

      return { targets, plan, planError };
    } catch (err) {
      throw toHttpsError(err);
    }
  },
);

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
