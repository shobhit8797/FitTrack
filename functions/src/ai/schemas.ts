import { LLMError } from './types';

// Parsed shapes for each AI task + minimal runtime validation. We don't pull in
// a schema lib; these guards keep the dependency surface small and the failure
// mode explicit (LLMError → app shows "couldn't read the AI response").

export interface PlanExercise {
  name: string;
  sets: number;
  repRange: string;
  notes: string;
  order: number;
}
/** A warm-up movement or cool-down stretch: name + prescription ("2 min",
 * "10 reps/side", "30 s hold") + optional cue. */
export interface MobilityItem {
  name: string;
  prescription: string;
  notes: string;
}
export interface PlanDay {
  dayLabel: string;
  order: number;
  warmup: MobilityItem[];
  exercises: PlanExercise[];
  cooldown: MobilityItem[];
}
export interface WorkoutPlanResult {
  splitName: string;
  summary: string;
  scheduledWeekdays: number[];
  days: PlanDay[];
}

export interface DietFoodItem {
  name: string;
  servingDescription: string;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
}
export interface DietMeal {
  mealLabel: string;
  order: number;
  items: DietFoodItem[];
}
export interface DietPlanResult {
  planName: string;
  summary: string;
  dailyCalories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  meals: DietMeal[];
  hydrationNote: string;
  groceryList: string[];
  notes: string;
}

/** One day of a 7-day plan: its meals plus that day's macro totals + a tip. */
export interface DietDayResult {
  day: string;
  order: number;
  meals: DietMeal[];
  dailyCalories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  note: string;
}
/** A 7-day plan. Extends the single-day shape (top-level fields act as a hero +
 * legacy fallback) with a per-day breakdown the client renders via a day picker. */
export interface WeeklyDietPlanResult extends DietPlanResult {
  days: DietDayResult[];
}

/** The diet-coach's conversational turn. */
export interface CoachReply {
  reply: string;
  readyToGenerate: boolean;
}

export interface FoodItem {
  name: string;
  dishKey: string;
  servingDescription: string;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  fiberG: number;
  confidence: number;
}
export interface FoodAnalysisResult {
  items: FoodItem[];
}

export interface MacroSet {
  calories: number | null;
  proteinG: number | null;
  carbsG: number | null;
  fatG: number | null;
  fiberG: number | null;
}
export interface LabelResult {
  productName: string | null;
  brand: string | null;
  servingSize: string | null;
  perServing: MacroSet;
  per100g: MacroSet;
  confidence: number;
}

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null;
}
function num(v: unknown, fallback = 0): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
}
function str(v: unknown, fallback = ''): string {
  return typeof v === 'string' ? v : fallback;
}

export function validatePlan(v: unknown): WorkoutPlanResult {
  if (!isObj(v) || !Array.isArray(v.days)) {
    throw new LLMError('AI plan missing days', undefined, false);
  }
  return {
    splitName: str(v.splitName, 'Custom Split'),
    summary: str(v.summary),
    scheduledWeekdays: Array.isArray(v.scheduledWeekdays)
      ? v.scheduledWeekdays.filter((n): n is number => typeof n === 'number')
      : [],
    days: v.days.map((d, di) => {
      const day = isObj(d) ? d : {};
      const ex = Array.isArray(day.exercises) ? day.exercises : [];
      const mobility = (list: unknown): MobilityItem[] =>
        (Array.isArray(list) ? list : []).map((m) => {
          const x = isObj(m) ? m : {};
          return {
            name: str(x.name, 'Movement'),
            prescription: str(x.prescription),
            notes: str(x.notes),
          };
        });
      return {
        dayLabel: str(day.dayLabel, `Day ${di + 1}`),
        order: num(day.order, di),
        warmup: mobility(day.warmup),
        exercises: ex.map((e, ei) => {
          const x = isObj(e) ? e : {};
          return {
            name: str(x.name, 'Exercise'),
            sets: num(x.sets, 3),
            repRange: str(x.repRange, '8-12'),
            notes: str(x.notes),
            order: num(x.order, ei),
          };
        }),
        cooldown: mobility(day.cooldown),
      };
    }),
  };
}

/** Validate a list of meals (shared by the single-day and 7-day plan shapes). */
function validateMeals(v: unknown): DietMeal[] {
  return (Array.isArray(v) ? v : []).map((m, mi) => {
    const meal = isObj(m) ? m : {};
    const items = Array.isArray(meal.items) ? meal.items : [];
    return {
      mealLabel: str(meal.mealLabel, `Meal ${mi + 1}`),
      order: num(meal.order, mi),
      items: items.map((it) => {
        const x = isObj(it) ? it : {};
        return {
          name: str(x.name, 'Food'),
          servingDescription: str(x.servingDescription),
          calories: Math.round(num(x.calories)),
          proteinG: num(x.proteinG),
          carbsG: num(x.carbsG),
          fatG: num(x.fatG),
        };
      }),
    };
  });
}

/** Sum a macro across a day's meals — used to backfill missing rollups. */
function sumMeals(meals: DietMeal[], pick: (i: DietFoodItem) => number): number {
  return meals.reduce((acc, m) => acc + m.items.reduce((a, it) => a + pick(it), 0), 0);
}

export function validateDietPlan(v: unknown): DietPlanResult {
  if (!isObj(v) || !Array.isArray(v.meals)) {
    throw new LLMError('AI diet plan missing meals', undefined, false);
  }
  const meals = validateMeals(v.meals);
  // Prefer the agent's stated totals; fall back to summing the items so the UI
  // always has a sane daily figure even if the agent omits the rollup.
  return {
    planName: str(v.planName, 'Your Meal Plan'),
    summary: str(v.summary),
    dailyCalories: Math.round(num(v.dailyCalories, sumMeals(meals, (i) => i.calories))),
    proteinG: Math.round(num(v.proteinG, sumMeals(meals, (i) => i.proteinG))),
    carbsG: Math.round(num(v.carbsG, sumMeals(meals, (i) => i.carbsG))),
    fatG: Math.round(num(v.fatG, sumMeals(meals, (i) => i.fatG))),
    meals,
    hydrationNote: str(v.hydrationNote),
    groceryList: Array.isArray(v.groceryList)
      ? v.groceryList.filter((s): s is string => typeof s === 'string')
      : [],
    notes: str(v.notes),
  };
}

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

export function validateWeeklyDietPlan(v: unknown): WeeklyDietPlanResult {
  if (!isObj(v) || !Array.isArray(v.days) || v.days.length === 0) {
    throw new LLMError('AI diet plan missing days', undefined, false);
  }
  const days: DietDayResult[] = v.days.map((d, di) => {
    const day = isObj(d) ? d : {};
    const meals = validateMeals(day.meals);
    return {
      day: str(day.day, WEEKDAYS[di] ?? `Day ${di + 1}`),
      order: num(day.order, di),
      meals,
      dailyCalories: Math.round(num(day.dailyCalories, sumMeals(meals, (i) => i.calories))),
      proteinG: Math.round(num(day.proteinG, sumMeals(meals, (i) => i.proteinG))),
      carbsG: Math.round(num(day.carbsG, sumMeals(meals, (i) => i.carbsG))),
      fatG: Math.round(num(day.fatG, sumMeals(meals, (i) => i.fatG))),
      note: str(day.note),
    };
  });
  days.sort((a, b) => a.order - b.order);
  // Top-level fields double as the hero + a fallback for any single-day renderer:
  // macros are the weekly average; meals default to the first day.
  const avg = (pick: (d: DietDayResult) => number) =>
    Math.round(days.reduce((acc, d) => acc + pick(d), 0) / days.length);
  return {
    planName: str(v.planName, 'Your 7-Day Plan'),
    summary: str(v.summary),
    dailyCalories: avg((d) => d.dailyCalories),
    proteinG: avg((d) => d.proteinG),
    carbsG: avg((d) => d.carbsG),
    fatG: avg((d) => d.fatG),
    meals: days[0]?.meals ?? [],
    hydrationNote: str(v.hydrationNote),
    groceryList: Array.isArray(v.groceryList)
      ? v.groceryList.filter((s): s is string => typeof s === 'string')
      : [],
    notes: str(v.notes),
    days,
  };
}

export function validateCoachReply(v: unknown): CoachReply {
  const o = isObj(v) ? v : {};
  return {
    reply: str(o.reply, "Tell me a bit about what you'd like to eat this week."),
    readyToGenerate: o.readyToGenerate === true,
  };
}

export function validateFoodAnalysis(v: unknown): FoodAnalysisResult {
  const items = isObj(v) && Array.isArray(v.items) ? v.items : [];
  return {
    items: items.map((it) => {
      const x = isObj(it) ? it : {};
      return {
        name: str(x.name, 'Food'),
        dishKey: str(x.dishKey).toLowerCase(),
        servingDescription: str(x.servingDescription),
        calories: Math.round(num(x.calories)),
        proteinG: num(x.proteinG),
        carbsG: num(x.carbsG),
        fatG: num(x.fatG),
        fiberG: num(x.fiberG),
        confidence: Math.max(0, Math.min(1, num(x.confidence, 0.5))),
      };
    }),
  };
}

export function validateLabel(v: unknown): LabelResult {
  const o = isObj(v) ? v : {};
  const macros = (m: unknown): MacroSet => {
    const x = isObj(m) ? m : {};
    const n = (k: string): number | null =>
      typeof x[k] === 'number' && Number.isFinite(x[k] as number) ? (x[k] as number) : null;
    return {
      calories: n('calories'),
      proteinG: n('proteinG'),
      carbsG: n('carbsG'),
      fatG: n('fatG'),
      fiberG: n('fiberG'),
    };
  };
  return {
    productName: typeof o.productName === 'string' ? o.productName : null,
    brand: typeof o.brand === 'string' ? o.brand : null,
    servingSize: typeof o.servingSize === 'string' ? o.servingSize : null,
    perServing: macros(o.perServing),
    per100g: macros(o.per100g),
    confidence: Math.max(0, Math.min(1, num(o.confidence, 0.5))),
  };
}
