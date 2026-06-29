import { FieldValue } from 'firebase-admin/firestore';
import { logger } from 'firebase-functions/v2';
import { db } from '../lib/admin';
import { parseJson } from '../ai/json';
import {
  DietPromptInputs,
  PlanPromptInputs,
  dietMessage,
  workoutMessage,
} from '../ai/prompts';
import { LYZR_DIET_AGENT_ID, LYZR_WORKOUT_AGENT_ID, runLyzrAgent } from '../ai/lyzr';
import { validateDietPlan, validatePlan } from '../ai/schemas';

const WEEKDAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** Plan-status values written to users/{uid} (mirrored by the iOS client). */
export type PlanStatus = 'generating' | 'ready' | 'failed';

/** The persisted profile fields the plan prompts need (a superset of onboarding). */
export interface StoredPlanProfile {
  sex: string;
  age: number;
  heightCm: number;
  weightKg: number;
  goal: string;
  goalFreeText?: string;
  activityLevel: string;
  trainingDaysPerWeek: number;
  preferredWeekdays: number[];
  experience: string;
  equipment: string[];
  dietType: string;
  dietaryRestrictions: string[];
  injuriesNotes: string;
  freeFormContext: string;
  // Deterministic targets (spec §5) — fed to the diet agent so it builds the day
  // to our numbers rather than inventing its own.
  calorieTarget: number;
  proteinTargetG: number;
  carbTargetG: number;
  fatTargetG: number;
}

/** Map a stored profile into the typed workout-prompt inputs. */
export function buildPlanInputs(p: StoredPlanProfile): PlanPromptInputs {
  return {
    sex: p.sex,
    age: p.age,
    heightCm: p.heightCm,
    weightKg: p.weightKg,
    goal: p.goalFreeText ? `${p.goal} (${p.goalFreeText})` : p.goal,
    trainingDaysPerWeek: p.trainingDaysPerWeek,
    preferredWeekdays: (p.preferredWeekdays ?? []).map((d) => WEEKDAY_NAMES[d]).join(','),
    experience: p.experience,
    equipment: (p.equipment ?? []).join(','),
    dietType: p.dietType,
    restrictions: (p.dietaryRestrictions ?? []).join(','),
    injuriesNotes: p.injuriesNotes,
    freeFormContext: p.freeFormContext,
  };
}

/** Map a stored profile into the typed diet-prompt inputs. */
export function buildDietInputs(p: StoredPlanProfile): DietPromptInputs {
  return {
    sex: p.sex,
    age: p.age,
    heightCm: p.heightCm,
    weightKg: p.weightKg,
    goal: p.goalFreeText ? `${p.goal} (${p.goalFreeText})` : p.goal,
    activityLevel: p.activityLevel,
    dietType: p.dietType,
    restrictions: (p.dietaryRestrictions ?? []).join(','),
    freeFormContext: p.freeFormContext,
    calorieTarget: p.calorieTarget,
    proteinTargetG: p.proteinTargetG,
    carbTargetG: p.carbTargetG,
    fatTargetG: p.fatTargetG,
  };
}

/**
 * Generate a workout plan via the Lyzr Fitness Architect agent and persist it,
 * fully async and decoupled from the request (spec §11.1). On success: write the
 * plan to workoutPlans/current and set workoutPlanStatus=ready. On failure: log
 * the error and set workoutPlanStatus=failed + workoutPlanError — never throw past
 * here, so a dead agent can never strand the user.
 */
export async function generateAndStoreWorkoutPlan(
  uid: string,
  profile: StoredPlanProfile,
): Promise<void> {
  const userRef = db.doc(`users/${uid}`);
  try {
    const raw = await runLyzrAgent(
      LYZR_WORKOUT_AGENT_ID.value(),
      uid,
      workoutMessage(buildPlanInputs(profile)),
    );
    const plan = validatePlan(parseJson(raw));

    await userRef.collection('workoutPlans').doc('current').set({
      ...plan,
      source: 'lyzr',
      generatedAt: FieldValue.serverTimestamp(),
    });
    await userRef.set(
      {
        workoutPlanStatus: 'ready' as PlanStatus,
        workoutPlanError: FieldValue.delete(),
        workoutPlanGeneratedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    logger.info('workoutPlan.generated', { uid, days: plan.days.length });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error('workoutPlan.generation_failed', { uid, error: message });
    await userRef.set(
      {
        workoutPlanStatus: 'failed' as PlanStatus,
        workoutPlanError: message,
        workoutPlanFailedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }
}

/**
 * Generate a diet plan via the Lyzr Nutrition Architect agent and persist it.
 * Same async + safety contract as the workout generator above, writing to
 * dietPlans/current and dietPlanStatus.
 */
export async function generateAndStoreDietPlan(
  uid: string,
  profile: StoredPlanProfile,
): Promise<void> {
  const userRef = db.doc(`users/${uid}`);
  try {
    const raw = await runLyzrAgent(
      LYZR_DIET_AGENT_ID.value(),
      uid,
      dietMessage(buildDietInputs(profile)),
    );
    const plan = validateDietPlan(parseJson(raw));

    await userRef.collection('dietPlans').doc('current').set({
      ...plan,
      source: 'lyzr',
      generatedAt: FieldValue.serverTimestamp(),
    });
    await userRef.set(
      {
        dietPlanStatus: 'ready' as PlanStatus,
        dietPlanError: FieldValue.delete(),
        dietPlanGeneratedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    logger.info('dietPlan.generated', { uid, meals: plan.meals.length });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error('dietPlan.generation_failed', { uid, error: message });
    await userRef.set(
      {
        dietPlanStatus: 'failed' as PlanStatus,
        dietPlanError: message,
        dietPlanFailedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }
}
