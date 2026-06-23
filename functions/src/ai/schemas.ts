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
export interface PlanDay {
  dayLabel: string;
  order: number;
  exercises: PlanExercise[];
}
export interface WorkoutPlanResult {
  splitName: string;
  summary: string;
  scheduledWeekdays: number[];
  days: PlanDay[];
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
      return {
        dayLabel: str(day.dayLabel, `Day ${di + 1}`),
        order: num(day.order, di),
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
      };
    }),
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
