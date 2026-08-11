import { logger } from 'firebase-functions/v2';
import { estimateMealFromPhoto, estimateMealFromText } from '../ai/foodEstimate';
import { GroundedFood } from '../food/ifct';
import {
  answerCallbackQuery,
  editMessageReplyMarkup,
  editMessageText,
  esc,
  fetchPhotoAsImagePart,
  sendChatAction,
  sendMessage,
} from './api';
import { HELP_TEXT, estimateCard, sumItems, todayCard, workoutCard } from './format';
import { consumeLinkCode, uidForChat, unlinkChat } from './linking';
import {
  MealType,
  addMeals,
  addSession,
  addWeight,
  dayId,
  deleteMeal,
  fetchMeals,
  fetchTargets,
  fetchWorkoutPlan,
  latestWeight,
  planDayFor,
  savePending,
  sessionLoggedOn,
  suggestedMealType,
  takePending,
  timeZoneFor,
} from './store';
import { TgCallbackQuery, TgInlineKeyboard, TgMessage, TgUpdate } from './types';

// The bot's dispatcher: one Telegram update in, zero or more messages out.
// Deliberately synchronous — Cloud Run gives no guarantees about work that
// continues after the HTTP response, so we finish the AI call and the Firestore
// write before returning 200. The webhook dedupes on update_id, so a Telegram
// retry after its own timeout can never double-log.

/** Callback opcodes. Kept to one character: callback_data is capped at 64 bytes
 * and the Firestore auto-id already eats 20 of them. */
const CB = {
  save: 's', // s:<pendingId>:<mealTypeInitial>
  pick: 'm', // m:<pendingId>          → swap in the meal-type picker
  discard: 'x', // x:<pendingId>
  workoutDone: 'w', // w
} as const;

const MEAL_TYPES: Record<string, MealType> = {
  b: 'breakfast',
  l: 'lunch',
  d: 'dinner',
  s: 'snack',
};
const MEAL_INITIALS: Record<MealType, string> = {
  breakfast: 'b',
  lunch: 'l',
  dinner: 'd',
  snack: 's',
};

export async function handleUpdate(update: TgUpdate): Promise<void> {
  if (update.callback_query) return handleCallback(update.callback_query);
  const msg = update.message ?? update.edited_message;
  if (msg) return handleMessage(msg);
}

// ---- Messages ------------------------------------------------------------

async function handleMessage(msg: TgMessage): Promise<void> {
  const chatId = msg.chat.id;
  // Group chats would mean several people writing into one person's log.
  if (msg.chat.type !== 'private') return;

  const text = (msg.text ?? '').trim();

  // /start and /link are the only things an unlinked chat may do.
  if (text.startsWith('/start') || text.startsWith('/link')) {
    return handleLink(msg, text);
  }

  const uid = await uidForChat(chatId);
  if (!uid) {
    await sendMessage(
      chatId,
      [
        "👋 I don't know whose log this is yet.",
        '',
        'Open <b>FitTrack → Settings → Telegram</b>, tap <b>Connect</b>, and either follow the link it shows you or send me the 6-character code here.',
      ].join('\n'),
    );
    return;
  }

  if (text.startsWith('/')) return handleCommand(uid, msg, text);
  if (msg.photo?.length) return handlePhoto(uid, msg);
  if (text) return handleFreeText(uid, msg, text);

  await sendMessage(chatId, "I can read text and photos of food. Try /help to see what I understand.");
}

async function handleLink(msg: TgMessage, text: string): Promise<void> {
  const chatId = msg.chat.id;
  // Tapping the t.me deep link sends "/start <code>"; typing it sends "/link <code>".
  const code = text.split(/\s+/)[1];
  const existing = await uidForChat(chatId);

  if (!code) {
    if (existing) {
      await sendMessage(chatId, `✅ This chat is already connected to your FitTrack account.\n\n${HELP_TEXT}`);
    } else {
      await sendMessage(
        chatId,
        [
          '👋 <b>Welcome to FitTrack.</b>',
          '',
          'To connect this chat to your account, open <b>FitTrack → Settings → Telegram</b> and tap <b>Connect</b>. Then send me the 6-character code, like:',
          '<code>/link A7K2QP</code>',
        ].join('\n'),
      );
    }
    return;
  }

  const result = await consumeLinkCode(code, {
    id: msg.from?.id ?? chatId,
    is_bot: false,
    chatId,
    username: msg.from?.username,
    first_name: msg.from?.first_name,
  });

  if (!result.ok) {
    const reason = {
      unknown: "That code doesn't look right.",
      expired: 'That code has expired — codes last an hour.',
      used: 'That code has already been used.',
    }[result.reason];
    await sendMessage(chatId, `⚠️ ${reason} Generate a fresh one in <b>FitTrack → Settings → Telegram</b>.`);
    return;
  }

  const targets = await fetchTargets(result.uid);
  const hello = targets.displayName ? `You're all set, ${esc(targets.displayName)}.` : "You're all set.";
  await sendMessage(chatId, `✅ <b>${hello}</b>\n\n${HELP_TEXT}`);
}

async function handleCommand(uid: string, msg: TgMessage, text: string): Promise<void> {
  const chatId = msg.chat.id;
  // "/today@FitTrackBot" — Telegram appends the handle in some clients.
  const [rawCmd, ...rest] = text.split(/\s+/);
  const cmd = rawCmd.split('@')[0].toLowerCase();
  const args = rest.join(' ').trim();

  switch (cmd) {
    case '/help':
      return void (await sendMessage(chatId, HELP_TEXT));
    case '/today':
      return sendToday(uid, chatId);
    case '/workout':
      return sendWorkout(uid, chatId);
    case '/weight':
      return logWeight(uid, chatId, args);
    case '/undo':
      return undoLast(uid, chatId);
    case '/unlink':
      await unlinkChat(chatId);
      return void (await sendMessage(
        chatId,
        '🔌 Disconnected. Your logged data is untouched — reconnect any time from Settings.',
      ));
    case '/log':
      // "/log 2 eggs" is the explicit form of just typing the food.
      if (!args) {
        return void (await sendMessage(chatId, 'Tell me what to log, e.g. <code>/log 2 eggs and toast</code>'));
      }
      return estimateAndConfirm(uid, chatId, args);
    default:
      return void (await sendMessage(chatId, "I don't know that command. /help shows what I can do."));
  }
}

/**
 * Free text is a meal unless it's obviously a weigh-in ("72.4 kg", "72.4kg").
 * The weight shorthand is worth special-casing: it's the one thing people type
 * daily that would otherwise be sent to the LLM as food.
 */
async function handleFreeText(uid: string, msg: TgMessage, text: string): Promise<void> {
  const weight = text.match(/^(\d{2,3}(?:[.,]\d{1,2})?)\s*(?:kg|kgs)$/i);
  if (weight) return logWeight(uid, msg.chat.id, weight[1]);
  return estimateAndConfirm(uid, msg.chat.id, text);
}

async function handlePhoto(uid: string, msg: TgMessage): Promise<void> {
  const chatId = msg.chat.id;
  // Telegram sends the same photo in several resolutions, ascending.
  const largest = msg.photo![msg.photo!.length - 1];
  await sendChatAction(chatId, 'typing');
  try {
    const image = await fetchPhotoAsImagePart(largest.file_id);
    const items = await estimateMealFromPhoto(image, msg.caption);
    if (!items.length) {
      await sendMessage(
        chatId,
        "I couldn't make out any food in that photo. Try a closer shot, or just tell me what it is.",
        { replyTo: msg.message_id },
      );
      return;
    }
    await presentEstimate(uid, chatId, items, {
      entryMethod: 'photo',
      description: msg.caption ?? 'photo',
      heading: 'From your photo',
      replyTo: msg.message_id,
    });
  } catch (err) {
    logger.error('telegram photo estimate failed', err);
    await sendMessage(chatId, "⚠️ I couldn't read that photo just now. Try again in a moment?");
  }
}

async function estimateAndConfirm(uid: string, chatId: number, description: string): Promise<void> {
  await sendChatAction(chatId, 'typing');
  try {
    const items = await estimateMealFromText(description);
    if (!items.length) {
      await sendMessage(chatId, "I couldn't turn that into food items. Try naming the foods and rough amounts.");
      return;
    }
    await presentEstimate(uid, chatId, items, {
      entryMethod: 'llm',
      description,
      heading: 'Here’s my estimate',
    });
  } catch (err) {
    logger.error('telegram text estimate failed', err);
    await sendMessage(chatId, "⚠️ The estimate didn't come back. Try again in a moment?");
  }
}

/** Park the estimate and show it with Save / Change meal / Discard. */
async function presentEstimate(
  uid: string,
  chatId: number,
  items: GroundedFood[],
  opts: { entryMethod: string; description: string; heading: string; replyTo?: number },
): Promise<void> {
  const tz = await timeZoneFor(uid);
  const at = new Date();
  const mealType = suggestedMealType(at, tz);
  const pendingId = await savePending(chatId, {
    items,
    entryMethod: opts.entryMethod,
    at,
    description: opts.description,
  });

  const keyboard: TgInlineKeyboard = [
    [
      { text: `✅ Save as ${mealType}`, callback_data: `${CB.save}:${pendingId}:${MEAL_INITIALS[mealType]}` },
    ],
    [
      { text: '🍽 Change meal', callback_data: `${CB.pick}:${pendingId}` },
      { text: '🗑 Discard', callback_data: `${CB.discard}:${pendingId}` },
    ],
  ];
  await sendMessage(chatId, estimateCard(items, opts.heading), {
    keyboard,
    replyTo: opts.replyTo,
  });
}

// ---- Commands ------------------------------------------------------------

async function sendToday(uid: string, chatId: number): Promise<void> {
  const tz = await timeZoneFor(uid);
  const now = new Date();
  const [meals, targets] = await Promise.all([
    fetchMeals(uid, dayId(now, tz)),
    fetchTargets(uid),
  ]);
  const label = new Intl.DateTimeFormat('en-GB', {
    timeZone: tz,
    weekday: 'long',
    day: 'numeric',
    month: 'long',
  }).format(now);
  await sendMessage(chatId, todayCard(meals, targets, { tz, label: `Today · ${label}` }));
}

async function sendWorkout(uid: string, chatId: number): Promise<void> {
  const tz = await timeZoneFor(uid);
  const now = new Date();
  const plan = await fetchWorkoutPlan(uid);

  if (!plan) {
    await sendMessage(
      chatId,
      "You don't have a workout plan yet. Generate one in <b>FitTrack → Settings → Plans</b> and I'll show it here.",
    );
    return;
  }

  const day = planDayFor(plan, now, tz);
  if (!day) {
    await sendMessage(
      chatId,
      `😌 <b>Rest day</b>\n<i>${esc(plan.splitName)}</i>\n\nNothing scheduled today. Eat well — /today shows where you are.`,
    );
    return;
  }

  const alreadyLogged = await sessionLoggedOn(uid, now, tz);
  const keyboard: TgInlineKeyboard = alreadyLogged
    ? []
    : [[{ text: '✅ Mark done', callback_data: CB.workoutDone }]];
  await sendMessage(chatId, workoutCard(plan, day, { alreadyLogged }), {
    keyboard: keyboard.length ? keyboard : undefined,
  });
}

async function logWeight(uid: string, chatId: number, arg: string): Promise<void> {
  const value = Number(arg.replace(',', '.').replace(/kgs?$/i, '').trim());
  if (!Number.isFinite(value) || value < 20 || value > 400) {
    await sendMessage(chatId, 'Send a weight in kg, e.g. <code>/weight 72.5</code>');
    return;
  }
  const previous = await latestWeight(uid);
  const at = new Date();
  await addWeight(uid, value, at);

  let line = `⚖️ Logged <b>${value} kg</b>.`;
  if (previous) {
    const delta = value - previous.weightKg;
    const tz = await timeZoneFor(uid);
    const since = new Intl.DateTimeFormat('en-GB', { timeZone: tz, day: 'numeric', month: 'short' }).format(
      previous.date,
    );
    const sign = delta > 0 ? '+' : '';
    line += ` ${sign}${delta.toFixed(1)} kg since ${since}.`;
  }
  await sendMessage(chatId, line);
}

async function undoLast(uid: string, chatId: number): Promise<void> {
  const tz = await timeZoneFor(uid);
  const now = new Date();
  const day = dayId(now, tz);
  const meals = await fetchMeals(uid, day);
  const last = meals[meals.length - 1];
  if (!last) {
    await sendMessage(chatId, "Nothing logged today to undo.");
    return;
  }
  await deleteMeal(uid, day, last.id, now);
  await sendMessage(
    chatId,
    `🗑 Removed <b>${esc(last.name)}</b> (${Math.round(last.calories)} kcal). /today for the new total.`,
  );
}

// ---- Callback buttons ----------------------------------------------------

async function handleCallback(cb: TgCallbackQuery): Promise<void> {
  const chatId = cb.message?.chat.id;
  const messageId = cb.message?.message_id;
  if (!chatId || !messageId) return void (await answerCallbackQuery(cb.id));

  const uid = await uidForChat(chatId);
  if (!uid) return void (await answerCallbackQuery(cb.id, 'This chat is no longer connected.'));

  const [op, id, extra] = (cb.data ?? '').split(':');

  try {
    switch (op) {
      case CB.save:
        return await commitPending(uid, cb, chatId, messageId, id, MEAL_TYPES[extra] ?? 'snack');
      case CB.pick:
        await answerCallbackQuery(cb.id);
        // Swap the keyboard for the four meal types; the card text stays put.
        return await showMealPicker(chatId, messageId, id);
      case CB.discard: {
        await takePending(chatId, id);
        await answerCallbackQuery(cb.id, 'Discarded');
        return await editMessageText(chatId, messageId, '🗑 <i>Discarded — nothing was saved.</i>');
      }
      case CB.workoutDone:
        return await markWorkoutDone(uid, cb, chatId, messageId);
      default:
        return void (await answerCallbackQuery(cb.id));
    }
  } catch (err) {
    logger.error('telegram callback failed', err);
    await answerCallbackQuery(cb.id, "That didn't go through — try again.");
  }
}

/** Turn a reviewed estimate into real meal documents, then report the day's
 * new position against the user's targets. */
async function commitPending(
  uid: string,
  cb: TgCallbackQuery,
  chatId: number,
  messageId: number,
  pendingId: string,
  mealType: MealType,
): Promise<void> {
  const pending = await takePending(chatId, pendingId);
  if (!pending) {
    await answerCallbackQuery(cb.id, 'That estimate has already been handled.');
    return;
  }
  const tz = await timeZoneFor(uid);
  await addMeals(uid, pending.items, {
    at: pending.at,
    tz,
    mealType,
    entryMethod: pending.entryMethod,
  });

  const totals = sumItems(pending.items);
  const targets = await fetchTargets(uid);
  const meals = await fetchMeals(uid, dayId(pending.at, tz));
  const dayKcal = meals.reduce((a, m) => a + m.calories, 0);
  const dayProtein = meals.reduce((a, m) => a + m.proteinG, 0);

  const lines = [
    `✅ <b>Saved as ${mealType}</b> — ${Math.round(totals.calories)} kcal, ${Math.round(totals.proteinG)} g protein.`,
  ];
  if (targets.calorieTarget) {
    const left = targets.calorieTarget - dayKcal;
    lines.push(
      left >= 0
        ? `Today: ${Math.round(dayKcal)} / ${targets.calorieTarget} kcal — ${Math.round(left)} left.`
        : `Today: ${Math.round(dayKcal)} / ${targets.calorieTarget} kcal — ${Math.round(-left)} over.`,
    );
  }
  if (targets.proteinTargetG) {
    const left = targets.proteinTargetG - dayProtein;
    lines.push(
      left > 0
        ? `Protein: ${Math.round(dayProtein)} / ${targets.proteinTargetG} g — ${Math.round(left)} g to go.`
        : `Protein: ${Math.round(dayProtein)} / ${targets.proteinTargetG} g — hit ✅`,
    );
  }

  await answerCallbackQuery(cb.id, 'Saved');
  // Replace the card (buttons and all) so a stale prompt can't be tapped again.
  await editMessageText(chatId, messageId, lines.join('\n'));
}

async function showMealPicker(
  chatId: number,
  messageId: number,
  pendingId: string,
): Promise<void> {
  const keyboard: TgInlineKeyboard = [
    [
      { text: '🌅 Breakfast', callback_data: `${CB.save}:${pendingId}:b` },
      { text: '🍽 Lunch', callback_data: `${CB.save}:${pendingId}:l` },
    ],
    [
      { text: '🌙 Dinner', callback_data: `${CB.save}:${pendingId}:d` },
      { text: '🍎 Snack', callback_data: `${CB.save}:${pendingId}:s` },
    ],
    [{ text: '🗑 Discard', callback_data: `${CB.discard}:${pendingId}` }],
  ];
  await editMessageReplyMarkup(chatId, messageId, keyboard);
}

async function markWorkoutDone(
  uid: string,
  cb: TgCallbackQuery,
  chatId: number,
  messageId: number,
): Promise<void> {
  const tz = await timeZoneFor(uid);
  const now = new Date();
  if (await sessionLoggedOn(uid, now, tz)) {
    await answerCallbackQuery(cb.id, 'Already logged today.');
    return;
  }
  const plan = await fetchWorkoutPlan(uid);
  const day = plan ? planDayFor(plan, now, tz) : null;
  await addSession(uid, { at: now, dayLabel: day?.dayLabel });
  await answerCallbackQuery(cb.id, 'Logged');
  await editMessageText(
    chatId,
    messageId,
    `✅ <b>${esc(day?.dayLabel ?? 'Workout')} logged.</b>\n<i>Add your sets in the app whenever you like.</i>`,
  );
}
