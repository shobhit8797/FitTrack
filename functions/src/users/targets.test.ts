import assert from 'node:assert';
import { test } from 'node:test';
import { bmr, computeTargets, TargetInputs } from './targets';

const base: TargetInputs = {
  sex: 'male',
  age: 30,
  heightCm: 178,
  weightKg: 80,
  activityLevel: 'moderate',
  goal: 'recomp',
};

test('Mifflin-St Jeor BMR (male)', () => {
  // 10*80 + 6.25*178 - 5*30 + 5 = 800 + 1112.5 - 150 + 5 = 1767.5
  assert.strictEqual(Math.round(bmr(base)), 1768);
});

test('Mifflin-St Jeor BMR (female)', () => {
  const f = bmr({ ...base, sex: 'female' });
  // ...same minus (5+161) = -166 from male
  assert.strictEqual(Math.round(f), 1768 - 166);
});

test('recomp applies a deficit below TDEE', () => {
  const t = computeTargets(base);
  assert.ok(t.calorieTarget < t.tdee, 'recomp should be below maintenance');
  assert.ok(t.calorieTarget > 0);
});

test('macros sum back to roughly the calorie target', () => {
  const t = computeTargets(base);
  const kcal = t.proteinTargetG * 4 + t.carbTargetG * 4 + t.fatTargetG * 9;
  assert.ok(Math.abs(kcal - t.calorieTarget) <= 5, `macros ${kcal} vs ${t.calorieTarget}`);
});

test('muscle gain uses a surplus and higher protein', () => {
  const recomp = computeTargets(base);
  const gain = computeTargets({ ...base, goal: 'muscleGain' });
  assert.ok(gain.calorieTarget > gain.tdee);
  assert.ok(gain.proteinTargetG >= recomp.proteinTargetG);
});

test('calorie floor respected for aggressive cases', () => {
  const t = computeTargets({ ...base, weightKg: 45, goal: 'fatLoss', activityLevel: 'sedentary' });
  assert.ok(t.calorieTarget >= 1500);
});

test('body-fat lowers protein toward lean mass', () => {
  const withBf = computeTargets({ ...base, bodyFatPct: 25 });
  const without = computeTargets(base);
  assert.ok(withBf.proteinTargetG < without.proteinTargetG);
});
