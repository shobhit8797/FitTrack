import { Timestamp } from 'firebase-admin/firestore';
import { logger } from 'firebase-functions/v2';
import { onRequest } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { TELEGRAM_SECRETS, TELEGRAM_WEBHOOK_SECRET } from './config';
import { handleUpdate } from './router';
import { TgUpdate } from './types';

/**
 * POST /telegramWebhook — the bot's only public surface.
 *
 * Registered with Telegram's setWebhook (see functions/scripts/setup-telegram.mjs),
 * which then POSTs every update here. Two rules govern this handler:
 *
 * 1. Authenticate. The URL is guessable, so we require the secret token Telegram
 *    echoes in X-Telegram-Bot-Api-Secret-Token. Anything else gets a flat 401.
 * 2. Always answer 200 once we've accepted an update. A non-2xx makes Telegram
 *    redeliver on a backoff, and a message that failed to parse will fail again —
 *    a permanent error would loop forever. Failures are logged, not retried.
 *
 * Meal estimation runs inline (a few seconds), so the timeout is generous.
 * Telegram gives up waiting after ~60s and redelivers; the update_id dedupe
 * below makes that redelivery a no-op instead of a double-log.
 */
export const telegramWebhook = onRequest(
  { secrets: TELEGRAM_SECRETS, timeoutSeconds: 120, memory: '512MiB', maxInstances: 10 },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).send('Method Not Allowed');
      return;
    }
    const expected = TELEGRAM_WEBHOOK_SECRET.value();
    if (!expected || req.get('X-Telegram-Bot-Api-Secret-Token') !== expected) {
      logger.warn('telegram webhook: bad or missing secret token');
      res.status(401).send('Unauthorized');
      return;
    }

    const update = req.body as TgUpdate | undefined;
    if (!update || typeof update.update_id !== 'number') {
      res.status(200).send('ignored');
      return;
    }

    if (!(await claimUpdate(update.update_id))) {
      logger.info(`telegram webhook: duplicate update ${update.update_id}, skipping`);
      res.status(200).send('duplicate');
      return;
    }

    try {
      await handleUpdate(update);
    } catch (err) {
      // Swallow: see rule 2 above. The user already got an error reply from the
      // router for anything it could anticipate.
      logger.error('telegram webhook: unhandled failure', err);
    }
    res.status(200).send('ok');
  },
);

/** Dedupe window for redelivered updates. Comfortably longer than Telegram's
 * retry schedule; a TTL policy on `expiresAt` sweeps the collection. */
const DEDUPE_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Claim an update_id exactly once. create() fails if the document exists, which
 * is the whole mechanism — the winner processes, the loser returns immediately.
 */
async function claimUpdate(updateId: number): Promise<boolean> {
  try {
    await db.doc(`telegramUpdates/${updateId}`).create({
      receivedAt: Timestamp.now(),
      expiresAt: Timestamp.fromDate(new Date(Date.now() + DEDUPE_TTL_MS)),
    });
    return true;
  } catch {
    return false;
  }
}
