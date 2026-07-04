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

export interface FoodItem {
  name: string;
  dishKey: string;
  servingDescription: string;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
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

export function validateDietPlan(v: unknown): DietPlanResult {
  if (!isObj(v) || !Array.isArray(v.meals)) {
    throw new LLMError('AI diet plan missing meals', undefined, false);
  }
  const meals: DietMeal[] = v.meals.map((m, mi) => {
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
  // Prefer the agent's stated totals; fall back to summing the items so the UI
  // always has a sane daily figure even if the agent omits the rollup.
  const sum = (pick: (i: DietFoodItem) => number) =>
    meals.reduce((acc, m) => acc + m.items.reduce((a, it) => a + pick(it), 0), 0);
  return {
    planName: str(v.planName, 'Your Meal Plan'),
    summary: str(v.summary),
    dailyCalories: Math.round(num(v.dailyCalories, sum((i) => i.calories))),
    proteinG: Math.round(num(v.proteinG, sum((i) => i.proteinG))),
    carbsG: Math.round(num(v.carbsG, sum((i) => i.carbsG))),
    fatG: Math.round(num(v.fatG, sum((i) => i.fatG))),
    meals,
    hydrationNote: str(v.hydrationNote),
    groceryList: Array.isArray(v.groceryList)
      ? v.groceryList.filter((s): s is string => typeof s === 'string')
      : [],
    notes: str(v.notes),
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
    return { calories: n('calories'), proteinG: n('proteinG'), carbsG: n('carbsG'), fatG: n('fatG') };
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
