import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';
import { TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_USERNAME } from './config';
import { sendMessage } from './api';
import { createLinkCode, unlinkUser } from './linking';

// The app-facing half of the Telegram integration: mint a link code, and break
// the link again. The bot token stays server-side — the app only ever learns the
// bot's public @username so it can build the t.me deep link.

/**
 * POST /telegram/create-link-code — start connecting this account to Telegram.
 *
 * Also stores the caller's IANA timezone on the profile. The bot has no device
 * to read a timezone from, and every "today" it computes (day buckets, the
 * meal-type guess, which workout is scheduled) depends on it.
 */
export const createTelegramLinkCode = onCall(
  { timeoutSeconds: 30, memory: '256MiB' },
  async (req) => {
    const uid = requireUid(req);
    try {
      const timeZone = req.data?.timeZone as string | undefined;
      if (timeZone && /^[A-Za-z_+\-/0-9]{3,64}$/.test(timeZone)) {
        await db.doc(`users/${uid}`).set({ timeZone }, { merge: true });
      }

      const { code, expiresAt } = await createLinkCode(uid);
      const botUsername = TELEGRAM_BOT_USERNAME.value();
      return {
        code,
        // No fractional seconds: the iOS client decodes with the .iso8601
        // strategy, which rejects them.
        expiresAt: expiresAt.toISOString().replace(/\.\d{3}Z$/, 'Z'),
        botUsername,
        // Tapping this opens the chat and sends "/start <code>" automatically —
        // the user never has to retype anything.
        deepLink: botUsername ? `https://t.me/${botUsername}?start=${code}` : null,
      };
    } catch (err) {
      throw toHttpsError(err);
    }
  },
);

/** POST /telegram/unlink — disconnect from the app side. */
export const unlinkTelegram = onCall(
  { secrets: [TELEGRAM_BOT_TOKEN], timeoutSeconds: 30, memory: '256MiB' },
  async (req) => {
    const uid = requireUid(req);
    try {
      const chatId = await unlinkUser(uid);
      // Courtesy note so the chat doesn't just go silent. Best-effort: the
      // unlink itself has already happened and must not fail on a send error.
      if (chatId != null) {
        try {
          await sendMessage(
            chatId,
            '🔌 This chat was disconnected from the FitTrack app. Reconnect any time from <b>Settings → Telegram</b>.',
          );
        } catch {
          /* ignore */
        }
      }
      return { unlinked: chatId != null };
    } catch (err) {
      throw toHttpsError(err);
    }
  },
);
