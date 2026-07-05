import { FieldValue } from 'firebase-admin/firestore';
import { logger } from 'firebase-functions/v2';
import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';
import { StoredPlanProfile, buildDietInputs } from '../users/plan';
import { AI_SECRETS, makeProvider } from './factory';
import { parseJson } from './json';
import {
  ChatTurn,
  DIET_COACH_SYSTEM,
  WEEKLY_DIET_SYSTEM,
  coachReplyUser,
  weeklyDietUser,
} from './prompts';
import { validateCoachReply, validateWeeklyDietPlan } from './schemas';

// The "Diet coach" chat: a conversational way to build a 7-day meal plan. Runs on
// the provider abstraction (Gemini/OpenRouter), not the one-shot Lyzr diet agent,
// so we own both the chat behavior and the strict 7-day JSON schema.

/** Coerce untrusted client input into a bounded, well-typed transcript. */
function sanitizeMessages(v: unknown): ChatTurn[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((m): ChatTurn => {
      const o = m && typeof m === 'object' ? (m as Record<string, unknown>) : {};
      const role = o.role === 'assistant' ? 'assistant' : 'user';
      const content = typeof o.content === 'string' ? o.content.slice(0, 4000) : '';
      return { role, content };
    })
    .filter((m) => m.content.trim())
    // Cap history so a runaway client can't blow the context / cost budget.
    .slice(-24);
}

const coachOpts = { secrets: AI_SECRETS, timeoutSeconds: 60, memory: '512MiB' as const };

/**
 * POST /ai/diet-coach-reply — one conversational turn of the diet coach.
 * Stateless: the client relays the full transcript each call. Returns the coach's
 * next message plus whether it now has enough to build the week.
 */
export const dietCoachReply = onCall(coachOpts, async (req) => {
  requireUid(req);
  try {
    const messages = sanitizeMessages(req.data?.messages);
    if (!messages.length) throw new Error('messages required');
    const provider = makeProvider();
    const res = await provider.complete({
      system: DIET_COACH_SYSTEM,
      user: coachReplyUser(messages),
      jsonObject: true,
      temperature: 0.6,
      maxTokens: 500,
    });
    return validateCoachReply(parseJson(res.text));
  } catch (err) {
    throw toHttpsError(err);
  }
});

// A full week is a big generation — give the provider call real headroom but keep
// the worst case (timeout × (1 + retries) + backoff ≈ 182s) under this budget, or
// the platform kills the function before the catch can record 'failed'.
const generateOpts = { secrets: AI_SECRETS, timeoutSeconds: 240, memory: '512MiB' as const };

/**
 * POST /ai/generate-diet-plan-from-chat — turn the planning transcript + the
 * user's stored targets into a strict 7-day plan, persisted to dietPlans/current.
 * Mirrors generateDietPlan's status contract (generating → ready/failed) so the
 * existing Diet-tab stream surfaces it; never throws past the inner catch.
 */
export const generateDietPlanFromChat = onCall(generateOpts, async (req) => {
  const uid = requireUid(req);
  try {
    const messages = sanitizeMessages(req.data?.messages);
    const userRef = db.doc(`users/${uid}`);
    const snap = await userRef.get();
    if (!snap.exists || snap.get('calorieTarget') == null) {
      throw new Error('complete onboarding before generating a plan');
    }
    const profile = snap.data() as StoredPlanProfile;

    await userRef.set(
      { dietPlanStatus: 'generating', dietPlanError: FieldValue.delete() },
      { merge: true },
    );

    try {
      const provider = makeProvider();
      const res = await provider.complete({
        system: WEEKLY_DIET_SYSTEM,
        user: weeklyDietUser(buildDietInputs(profile), messages),
        jsonObject: true,
        temperature: 0.5,
        maxTokens: 12_000,
        timeoutMs: 90_000,
        maxRetries: 1,
      });
      const plan = validateWeeklyDietPlan(parseJson(res.text));

      await userRef.collection('dietPlans').doc('current').set({
        ...plan,
        source: 'chat',
        generatedAt: FieldValue.serverTimestamp(),
      });
      await userRef.set(
        {
          dietPlanStatus: 'ready',
          dietPlanError: FieldValue.delete(),
          dietPlanGeneratedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      logger.info('dietPlan.chat_generated', { uid, days: plan.days.length });
      return { dietPlanStatus: 'ready' };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logger.error('dietPlan.chat_generation_failed', { uid, error: message });
      await userRef.set(
        {
          dietPlanStatus: 'failed',
          dietPlanError: message,
          dietPlanFailedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return { dietPlanStatus: 'failed' };
    }
  } catch (err) {
    throw toHttpsError(err);
  }
});
