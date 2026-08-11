import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { GroundedFood } from '../food/ifct';
import { db } from '../lib/admin';
import { DEFAULT_TIMEZONE } from './config';

// Firestore access for the bot. Every write here must produce exactly the
// document shape ios/FitTrack/Models/Domain.swift decodes — a meal logged from
// Telegram is indistinguishable from one logged in the app, and the app's
// Firestore listeners pick it up live. Mirrors Repository.swift deliberately:
// same paths, same field names, same rollup recomputation.

// ---- Day bucketing -------------------------------------------------------
// The app buckets meals by *device-local* calendar day (Repository.dayId uses
// the current TimeZone). The server has no device, so we key off the timezone
// captured on the profile when the user linked Telegram.

/** IANA timezone for a user, falling back to the configured default. */
export async function timeZoneFor(uid: string): Promise<string> {
  const snap = await db.doc(`users/${uid}`).get();
  const tz = snap.get('timeZone') as string | undefined;
  return tz || DEFAULT_TIMEZONE.value() || 'UTC';
}

/** "yyyy-MM-dd" in `tz` — the dayLogs document id (en-CA formats ISO-style). */
export function dayId(date: Date, tz: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);
}

/** Local hour-of-day in `tz`, used for the meal-type guess. */
function hourIn(date: Date, tz: string): number {
  return Number(
    new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', hour12: false }).format(date),
  );
}

/** Local weekday in `tz`, 0=Sun..6=Sat — matches UserProfile.preferredWeekdays. */
export function weekdayIn(date: Date, tz: string): number {
  const short = new Intl.DateTimeFormat('en-US', { timeZone: tz, weekday: 'short' }).format(date);
  return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(short);
}

export type MealType = 'breakfast' | 'lunch' | 'dinner' | 'snack';

/** Same buckets as MealType.suggestedForNow in the iOS app. */
export function suggestedMealType(date: Date, tz: string): MealType {
  const h = hourIn(date, tz);
  if (h >= 4 && h < 11) return 'breakfast';
  if (h >= 11 && h < 16) return 'lunch';
  if (h >= 16 && h < 22) return 'dinner';
  return 'snack';
}

// ---- Profile / targets ---------------------------------------------------

export interface UserTargets {
  displayName?: string;
  calorieTarget?: number;
  proteinTargetG?: number;
  carbTargetG?: number;
  fatTargetG?: number;
}

export async function fetchTargets(uid: string): Promise<UserTargets> {
  const snap = await db.doc(`users/${uid}`).get();
  if (!snap.exists) return {};
  const d = snap.data() ?? {};
  return {
    displayName: d.displayName,
    calorieTarget: d.calorieTarget,
    proteinTargetG: d.proteinTargetG,
    carbTargetG: d.carbTargetG,
    fatTargetG: d.fatTargetG,
  };
}

// ---- Meals ---------------------------------------------------------------

export interface StoredMeal {
  id: string;
  mealType: MealType;
  loggedAt: Date;
  name: string;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  fiberG: number;
  servingDescription?: string;
  entryMethod: string;
  confidence?: number;
}

function mealsRef(uid: string, day: string) {
  return db.collection(`users/${uid}/dayLogs/${day}/meals`);
}

/**
 * Round the way the app does before persisting: calories are an Int on the
 * client, macros are Doubles but a gram is already finer than the estimate's
 * real precision.
 */
function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

/**
 * Write one meal per estimated food item (the app does the same — the review
 * sheet saves each row separately), then recompute the day rollup.
 * `at` is the logging instant; the day bucket is derived from it in `tz`.
 */
export async function addMeals(
  uid: string,
  items: GroundedFood[],
  opts: { at: Date; tz: string; mealType: MealType; entryMethod: string },
): Promise<StoredMeal[]> {
  const day = dayId(opts.at, opts.tz);
  const batch = db.batch();
  const saved: StoredMeal[] = [];

  for (const item of items) {
    // Prefer the IFCT-grounded macros when the dish matched the food DB —
    // same preference order the app's review sheet defaults to.
    const g = item.grounded;
    const ref = mealsRef(uid, day).doc();
    const meal: StoredMeal = {
      id: ref.id,
      mealType: opts.mealType,
      loggedAt: opts.at,
      name: item.name,
      calories: Math.round(g?.calories ?? item.calories),
      proteinG: round1(g?.proteinG ?? item.proteinG),
      carbsG: round1(g?.carbsG ?? item.carbsG),
      fatG: round1(g?.fatG ?? item.fatG),
      fiberG: round1(item.fiberG),
      servingDescription: item.servingDescription || undefined,
      entryMethod: opts.entryMethod,
      confidence: item.confidence,
    };
    // Build the payload key by key rather than spreading `meal`: the Firestore
    // instance does not set ignoreUndefinedProperties, so an absent
    // servingDescription would throw instead of being omitted.
    batch.set(ref, {
      id: meal.id,
      mealType: meal.mealType,
      loggedAt: Timestamp.fromDate(opts.at),
      name: meal.name,
      calories: meal.calories,
      proteinG: meal.proteinG,
      carbsG: meal.carbsG,
      fatG: meal.fatG,
      fiberG: meal.fiberG,
      entryMethod: meal.entryMethod,
      confidence: meal.confidence ?? null,
      ...(meal.servingDescription ? { servingDescription: meal.servingDescription } : {}),
      ...(g ? { foodDbId: g.foodDbId } : {}),
      source: 'telegram', // provenance, ignored by the app's decoder
    });
    saved.push(meal);
  }

  await batch.commit();
  await recomputeDayRollup(uid, day, opts.at);
  return saved;
}

/** Delete a meal and refresh the day's totals. */
export async function deleteMeal(uid: string, day: string, mealId: string, at: Date): Promise<void> {
  await mealsRef(uid, day).doc(mealId).delete();
  await recomputeDayRollup(uid, day, at);
}

export async function fetchMeals(uid: string, day: string): Promise<StoredMeal[]> {
  const snap = await mealsRef(uid, day).orderBy('loggedAt').get();
  return snap.docs.map((d) => {
    const m = d.data();
    return {
      id: d.id,
      mealType: (m.mealType ?? 'snack') as MealType,
      loggedAt: (m.loggedAt as Timestamp)?.toDate() ?? new Date(),
      name: m.name ?? 'Food',
      calories: m.calories ?? 0,
      proteinG: m.proteinG ?? 0,
      carbsG: m.carbsG ?? 0,
      fatG: m.fatG ?? 0,
      fiberG: m.fiberG ?? 0,
      servingDescription: m.servingDescription,
      entryMethod: m.entryMethod ?? 'manual',
      confidence: m.confidence,
    };
  });
}

/**
 * Recompute the day rollup from its meals — never trust a stored total
 * (spec §9). Identical to Repository.recomputeDayRollup so both writers
 * converge on the same numbers.
 */
export async function recomputeDayRollup(uid: string, day: string, date: Date): Promise<void> {
  const meals = await fetchMeals(uid, day);
  await db.doc(`users/${uid}/dayLogs/${day}`).set(
    {
      date: Timestamp.fromDate(date),
      totalCalories: meals.reduce((a, m) => a + m.calories, 0),
      totalProteinG: round1(meals.reduce((a, m) => a + m.proteinG, 0)),
      totalCarbsG: round1(meals.reduce((a, m) => a + m.carbsG, 0)),
      totalFatG: round1(meals.reduce((a, m) => a + m.fatG, 0)),
      totalFiberG: round1(meals.reduce((a, m) => a + m.fiberG, 0)),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

// ---- Weight --------------------------------------------------------------

export async function addWeight(uid: string, weightKg: number, at: Date, note?: string): Promise<void> {
  const ref = db.collection(`users/${uid}/weightEntries`).doc();
  await ref.set({
    id: ref.id,
    date: Timestamp.fromDate(at),
    weightKg,
    source: 'telegram',
    ...(note ? { note } : {}),
  });
}

export async function latestWeight(uid: string): Promise<{ weightKg: number; date: Date } | null> {
  const snap = await db
    .collection(`users/${uid}/weightEntries`)
    .orderBy('date', 'desc')
    .limit(1)
    .get();
  if (snap.empty) return null;
  const d = snap.docs[0].data();
  return { weightKg: d.weightKg, date: (d.date as Timestamp).toDate() };
}

// ---- Workout plan + sessions --------------------------------------------

export interface PlannedExercise {
  name: string;
  sets: number;
  repRange: string;
  notes: string;
  order: number;
}
export interface MobilityItem {
  name: string;
  prescription: string;
  notes: string;
}
export interface WorkoutDay {
  dayLabel: string;
  order: number;
  exercises: PlannedExercise[];
  warmup?: MobilityItem[];
  cooldown?: MobilityItem[];
}
export interface WorkoutPlan {
  splitName: string;
  summary: string;
  scheduledWeekdays: number[];
  days: WorkoutDay[];
}

export async function fetchWorkoutPlan(uid: string): Promise<WorkoutPlan | null> {
  const snap = await db.doc(`users/${uid}/workoutPlans/current`).get();
  return snap.exists ? (snap.data() as WorkoutPlan) : null;
}

/**
 * The day of the plan that falls on `date`. Mirrors WorkoutPlan.dayLabel(for:)
 * in the app: plans don't pin days to weekdays, so we take the plan day at the
 * same position as `date`'s weekday within the sorted schedule. Returns null on
 * a rest day so both surfaces agree on what "today" is.
 */
export function planDayFor(plan: WorkoutPlan, date: Date, tz: string): WorkoutDay | null {
  const weekday = weekdayIn(date, tz);
  const scheduled = [...(plan.scheduledWeekdays ?? [])].sort((a, b) => a - b);
  if (!scheduled.includes(weekday) || !plan.days?.length) return null;
  const position = scheduled.indexOf(weekday);
  const days = [...plan.days].sort((a, b) => a.order - b.order);
  return days[position % days.length];
}

/** Whether a session is already recorded for the given local day. */
export async function sessionLoggedOn(uid: string, date: Date, tz: string): Promise<boolean> {
  const day = dayId(date, tz);
  const snap = await db
    .collection(`users/${uid}/workoutSessions`)
    .orderBy('date', 'desc')
    .limit(20)
    .get();
  return snap.docs.some((d) => {
    const ts = d.get('date') as Timestamp | undefined;
    return ts ? dayId(ts.toDate(), tz) === day : false;
  });
}

/**
 * Record a completed session. Logged from Telegram there are no per-set numbers,
 * so loggedSets is empty and the detail lives in `note` — WorkoutSession decodes
 * fine either way, and the user can fill in sets in the app.
 */
export async function addSession(
  uid: string,
  opts: { at: Date; dayLabel?: string; note?: string },
): Promise<void> {
  const ref = db.collection(`users/${uid}/workoutSessions`).doc();
  await ref.set({
    id: ref.id,
    date: Timestamp.fromDate(opts.at),
    dayLabel: opts.dayLabel ?? null,
    loggedSets: [],
    note: opts.note ?? 'Logged from Telegram',
    source: 'telegram',
  });
}

// ---- Pending confirmations ----------------------------------------------
// An AI estimate is shown for review before it's saved, so the items have to
// survive the round-trip to the user's tap. They're parked under the chat doc
// (never under users/, which the app streams) and read back by callback id.

export interface PendingEstimate {
  items: GroundedFood[];
  entryMethod: string;
  at: Date;
  description: string;
}

export async function savePending(
  chatId: number,
  pending: PendingEstimate,
): Promise<string> {
  const ref = db.collection(`telegramChats/${chatId}/pending`).doc();
  await ref.set({
    items: pending.items,
    entryMethod: pending.entryMethod,
    at: Timestamp.fromDate(pending.at),
    description: pending.description,
    createdAt: FieldValue.serverTimestamp(),
  });
  return ref.id;
}

export async function takePending(chatId: number, id: string): Promise<PendingEstimate | null> {
  const ref = db.doc(`telegramChats/${chatId}/pending/${id}`);
  const snap = await ref.get();
  if (!snap.exists) return null;
  await ref.delete(); // single-use: a double-tap must not double-log
  const d = snap.data()!;
  return {
    items: (d.items ?? []) as GroundedFood[],
    entryMethod: d.entryMethod ?? 'llm',
    at: (d.at as Timestamp)?.toDate() ?? new Date(),
    description: d.description ?? '',
  };
}
