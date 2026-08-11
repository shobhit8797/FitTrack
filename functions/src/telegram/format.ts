import { GroundedFood } from '../food/ifct';
import { esc } from './api';
import { StoredMeal, UserTargets, WorkoutDay, WorkoutPlan } from './store';

// Message rendering. A Telegram chat is a narrow, monospace-less surface, so
// everything here optimizes for one glanceable line per fact plus a bar the user
// can read without doing arithmetic.

/** Unicode progress bar, e.g. ▓▓▓▓▓▓░░░░ for 60%. Clamped so an over-target
 * day fills the bar rather than overflowing the line. */
export function bar(value: number, target: number, width = 10): string {
  if (!target || target <= 0) return '';
  const pct = Math.max(0, Math.min(1, value / target));
  const filled = Math.round(pct * width);
  return '▓'.repeat(filled) + '░'.repeat(width - filled);
}

function pct(value: number, target?: number): string {
  if (!target || target <= 0) return '';
  return ` (${Math.round((value / target) * 100)}%)`;
}

const MEAL_EMOJI: Record<string, string> = {
  breakfast: '🌅',
  lunch: '🍽',
  dinner: '🌙',
  snack: '🍎',
};

/** Compact macro line: "520 kcal · 38P / 44C / 18F". */
function macroLine(m: { calories: number; proteinG: number; carbsG: number; fatG: number }): string {
  return `${Math.round(m.calories)} kcal · ${Math.round(m.proteinG)}P / ${Math.round(m.carbsG)}C / ${Math.round(m.fatG)}F`;
}

/**
 * The review card shown before anything is saved. Always itemized so a wrong
 * portion is obvious at a glance and can be corrected by re-sending — the
 * user's brief asks for the breakdown, not just a total.
 */
export function estimateCard(items: GroundedFood[], heading: string): string {
  const totals = sumItems(items);
  const lines = [`<b>${esc(heading)}</b>`, ''];

  for (const item of items) {
    const g = item.grounded;
    const macros = macroLine(g ?? item);
    const serving = item.servingDescription ? ` — ${esc(item.servingDescription)}` : '';
    lines.push(`• <b>${esc(item.name)}</b>${serving}`);
    lines.push(`  ${macros}`);
    // Say when the numbers come from the food DB rather than the model's guess,
    // and flag a shaky guess so the user knows to check it.
    if (g) {
      lines.push(`  <i>matched ${esc(g.matchedName)} · ~${g.estimatedGrams} g (IFCT)</i>`);
    } else if (item.confidence < 0.5) {
      lines.push('  <i>low confidence — correct me if this is off</i>');
    }
  }

  lines.push('', `<b>Total:</b> ${macroLine(totals)}`);
  return lines.join('\n');
}

export function sumItems(items: GroundedFood[]) {
  return items.reduce(
    (acc, i) => {
      const g = i.grounded;
      return {
        calories: acc.calories + (g?.calories ?? i.calories),
        proteinG: acc.proteinG + (g?.proteinG ?? i.proteinG),
        carbsG: acc.carbsG + (g?.carbsG ?? i.carbsG),
        fatG: acc.fatG + (g?.fatG ?? i.fatG),
        fiberG: acc.fiberG + i.fiberG,
      };
    },
    { calories: 0, proteinG: 0, carbsG: 0, fatG: 0, fiberG: 0 },
  );
}

/** The /today card: progress against targets, then the itemized log. */
export function todayCard(
  meals: StoredMeal[],
  targets: UserTargets,
  opts: { tz: string; label: string },
): string {
  const total = meals.reduce(
    (a, m) => ({
      calories: a.calories + m.calories,
      proteinG: a.proteinG + m.proteinG,
      carbsG: a.carbsG + m.carbsG,
      fatG: a.fatG + m.fatG,
      fiberG: a.fiberG + m.fiberG,
    }),
    { calories: 0, proteinG: 0, carbsG: 0, fatG: 0, fiberG: 0 },
  );

  const lines = [`<b>${esc(opts.label)}</b>`, ''];

  const kcalTarget = targets.calorieTarget;
  if (kcalTarget) {
    const left = kcalTarget - total.calories;
    lines.push(
      `🔥 <b>${Math.round(total.calories)}</b> / ${kcalTarget} kcal${pct(total.calories, kcalTarget)}`,
    );
    lines.push(`${bar(total.calories, kcalTarget)}  ${left >= 0 ? `${left} left` : `${-left} over`}`);
  } else {
    lines.push(`🔥 <b>${Math.round(total.calories)}</b> kcal`);
  }

  const proteinTarget = targets.proteinTargetG;
  if (proteinTarget) {
    const left = proteinTarget - total.proteinG;
    lines.push(
      `🥩 <b>${Math.round(total.proteinG)}</b> / ${proteinTarget} g protein${pct(total.proteinG, proteinTarget)}`,
    );
    lines.push(
      `${bar(total.proteinG, proteinTarget)}  ${left > 0 ? `${Math.round(left)} g to go` : 'target hit ✅'}`,
    );
  } else {
    lines.push(`🥩 <b>${Math.round(total.proteinG)}</b> g protein`);
  }

  lines.push(
    `🍞 ${Math.round(total.carbsG)} g carbs · 🥑 ${Math.round(total.fatG)} g fat · 🌾 ${Math.round(total.fiberG)} g fiber`,
  );

  if (!meals.length) {
    lines.push('', '<i>Nothing logged yet. Send me what you ate, or a photo of it.</i>');
    return lines.join('\n');
  }

  lines.push('', '<b>Logged</b>');
  for (const m of meals) {
    const time = new Intl.DateTimeFormat('en-GB', {
      timeZone: opts.tz,
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    }).format(m.loggedAt);
    lines.push(
      `${MEAL_EMOJI[m.mealType] ?? '•'} <code>${time}</code> ${esc(m.name)} — ${Math.round(m.calories)} kcal, ${Math.round(m.proteinG)}P`,
    );
  }
  return lines.join('\n');
}

/** The /workout card: today's session from the current plan. */
export function workoutCard(
  plan: WorkoutPlan,
  day: WorkoutDay,
  opts: { alreadyLogged: boolean },
): string {
  const lines = [
    `<b>🏋️ ${esc(day.dayLabel)}</b>`,
    `<i>${esc(plan.splitName)}</i>`,
    '',
  ];

  if (day.warmup?.length) {
    lines.push('<b>Warm-up</b>');
    for (const w of day.warmup) lines.push(`• ${esc(w.name)} — ${esc(w.prescription)}`);
    lines.push('');
  }

  lines.push('<b>Main work</b>');
  for (const e of [...(day.exercises ?? [])].sort((a, b) => a.order - b.order)) {
    lines.push(`• <b>${esc(e.name)}</b> — ${e.sets} × ${esc(e.repRange)}`);
    if (e.notes) lines.push(`  <i>${esc(e.notes)}</i>`);
  }

  if (day.cooldown?.length) {
    lines.push('', '<b>Cool-down</b>');
    for (const c of day.cooldown) lines.push(`• ${esc(c.name)} — ${esc(c.prescription)}`);
  }

  if (opts.alreadyLogged) lines.push('', '✅ <i>Already logged today — nice.</i>');
  return lines.join('\n');
}

export const HELP_TEXT = [
  '<b>FitTrack bot</b> — log without opening the app.',
  '',
  '<b>Food</b>',
  'Just tell me what you ate:',
  '<code>150g chicken thigh + 100g rice + salad</code>',
  'Or send a <b>photo</b> of your plate (add a caption like "half of this" to help with portions).',
  'I estimate the macros and show the breakdown — nothing saves until you tap <b>Save</b>.',
  '',
  '<b>Commands</b>',
  '/today — calories &amp; protein vs. your targets, plus everything logged',
  '/workout — today&#39;s session from your plan, with a Done button',
  '/weight 72.5 — log a morning weigh-in',
  '/undo — remove the last thing you logged today',
  '/help — this message',
  '/unlink — disconnect this chat from your account',
  '',
  '<i>Everything you log here appears in the FitTrack app straight away.</i>',
].join('\n');
