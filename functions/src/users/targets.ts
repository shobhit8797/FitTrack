// Deterministic nutrition targets (spec §5). Computed server-side from the
// user's own inputs — never the LLM, never hardcoded defaults. Pure function so
// it is unit-testable and reproducible.

export type Sex = 'male' | 'female';
export type ActivityLevel =
  | 'sedentary'
  | 'light'
  | 'moderate'
  | 'active'
  | 'veryActive';
export type Goal = 'fatLoss' | 'recomp' | 'muscleGain' | 'maintain';

export interface TargetInputs {
  sex: Sex;
  age: number;
  heightCm: number;
  weightKg: number;
  activityLevel: ActivityLevel;
  goal: Goal;
  /** Optional body-fat % (0–100) to refine protein toward lean mass. */
  bodyFatPct?: number;
}

export interface Targets {
  bmr: number;
  tdee: number;
  calorieTarget: number;
  proteinTargetG: number;
  carbTargetG: number;
  fatTargetG: number;
}

const ACTIVITY_MULTIPLIER: Record<ActivityLevel, number> = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725,
  veryActive: 1.9,
};

/** Mifflin-St Jeor BMR. */
export function bmr(i: TargetInputs): number {
  const base = 10 * i.weightKg + 6.25 * i.heightCm - 5 * i.age;
  return i.sex === 'male' ? base + 5 : base - 161;
}

export function computeTargets(i: TargetInputs): Targets {
  const b = bmr(i);
  const tdee = b * ACTIVITY_MULTIPLIER[i.activityLevel];

  // Calories by goal (spec §5.3), with a sane floor.
  let calories: number;
  switch (i.goal) {
    case 'fatLoss':
    case 'recomp':
      calories = tdee * 0.82; // ~18% deficit
      break;
    case 'muscleGain':
      calories = tdee * 1.1;
      break;
    case 'maintain':
    default:
      calories = tdee;
  }
  const floor = i.sex === 'male' ? 1500 : 1200;
  calories = Math.max(calories, floor);

  // Protein 1.6–2.0 g/kg, refined to lean mass if body-fat known (spec §5.4).
  const leanKg =
    i.bodyFatPct != null && i.bodyFatPct > 0 && i.bodyFatPct < 60
      ? i.weightKg * (1 - i.bodyFatPct / 100)
      : null;
  const proteinPerKg = i.goal === 'muscleGain' || i.goal === 'recomp' ? 2.0 : 1.8;
  const proteinG = Math.round((leanKg ?? i.weightKg) * proteinPerKg);

  const fatG = Math.round(i.weightKg * 0.8); // ~0.8 g/kg
  const proteinKcal = proteinG * 4;
  const fatKcal = fatG * 9;
  const carbG = Math.max(0, Math.round((calories - proteinKcal - fatKcal) / 4));

  return {
    bmr: Math.round(b),
    tdee: Math.round(tdee),
    calorieTarget: Math.round(calories),
    proteinTargetG: proteinG,
    carbTargetG: carbG,
    fatTargetG: fatG,
  };
}
