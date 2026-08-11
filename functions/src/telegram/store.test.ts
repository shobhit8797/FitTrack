import assert from 'node:assert';
import { test } from 'node:test';
import { WorkoutPlan, dayId, planDayFor, suggestedMealType, weekdayIn } from './store';

// The bot has no device to read a timezone from, so every "today" it computes
// runs through these helpers. A wrong day bucket puts a meal on the wrong date,
// which is invisible in the chat and only shows up later in the app.

const IST = 'Asia/Kolkata'; // UTC+5:30 — a half-hour offset, so it catches
                            // naive UTC math that a whole-hour zone would hide.

test('dayId buckets by local calendar day, not UTC', () => {
  // 2026-08-09 19:00 UTC is already 2026-08-10 00:30 in India.
  const t = new Date('2026-08-09T19:00:00Z');
  assert.strictEqual(dayId(t, 'UTC'), '2026-08-09');
  assert.strictEqual(dayId(t, IST), '2026-08-10');
});

test('dayId keeps the same day when the offset does not cross midnight', () => {
  const t = new Date('2026-08-09T06:00:00Z');
  assert.strictEqual(dayId(t, IST), '2026-08-09');
});

test('weekdayIn returns 0=Sun..6=Sat in the local zone', () => {
  // 2026-08-09 is a Sunday.
  assert.strictEqual(weekdayIn(new Date('2026-08-09T06:00:00Z'), IST), 0);
  // 19:00 UTC is Monday in India.
  assert.strictEqual(weekdayIn(new Date('2026-08-09T19:00:00Z'), IST), 1);
});

test('suggestedMealType follows local hour, matching the iOS buckets', () => {
  const at = (utc: string) => suggestedMealType(new Date(utc), IST);
  assert.strictEqual(at('2026-08-09T03:00:00Z'), 'breakfast'); // 08:30 IST
  assert.strictEqual(at('2026-08-09T08:00:00Z'), 'lunch'); //     13:30 IST
  assert.strictEqual(at('2026-08-09T14:00:00Z'), 'dinner'); //    19:30 IST
  assert.strictEqual(at('2026-08-09T20:00:00Z'), 'snack'); //     01:30 IST
});

const plan: WorkoutPlan = {
  splitName: 'Push / Pull / Legs',
  summary: '',
  scheduledWeekdays: [1, 3, 5], // Mon, Wed, Fri
  days: [
    { dayLabel: 'Push', order: 0, exercises: [] },
    { dayLabel: 'Pull', order: 1, exercises: [] },
    { dayLabel: 'Legs', order: 2, exercises: [] },
  ],
};

test('planDayFor maps a scheduled weekday to its position in the split', () => {
  // 2026-08-10 is a Monday — the first scheduled day.
  assert.strictEqual(planDayFor(plan, new Date('2026-08-10T06:00:00Z'), IST)?.dayLabel, 'Push');
  assert.strictEqual(planDayFor(plan, new Date('2026-08-12T06:00:00Z'), IST)?.dayLabel, 'Pull');
  assert.strictEqual(planDayFor(plan, new Date('2026-08-14T06:00:00Z'), IST)?.dayLabel, 'Legs');
});

test('planDayFor returns null on a rest day', () => {
  // Sunday is not in scheduledWeekdays.
  assert.strictEqual(planDayFor(plan, new Date('2026-08-09T06:00:00Z'), IST), null);
});

test('planDayFor wraps when there are more training days than plan days', () => {
  const twoDay: WorkoutPlan = { ...plan, days: plan.days.slice(0, 2) };
  // Third scheduled weekday (Fri) wraps back to the first plan day.
  assert.strictEqual(planDayFor(twoDay, new Date('2026-08-14T06:00:00Z'), IST)?.dayLabel, 'Push');
});
