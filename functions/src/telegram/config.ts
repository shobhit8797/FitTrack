import { defineSecret, defineString } from 'firebase-functions/params';
import { AI_SECRETS } from '../ai/factory';

// Telegram configuration. Like the AI keys, the bot token never leaves the
// backend — the iOS app only ever learns the bot's public @username.

/** From @BotFather. Grants full control of the bot: secret, never a param. */
export const TELEGRAM_BOT_TOKEN = defineSecret('TELEGRAM_BOT_TOKEN');

/**
 * Shared secret echoed by Telegram in the X-Telegram-Bot-Api-Secret-Token
 * header on every webhook delivery. The webhook URL is effectively public, so
 * this header is what proves a request actually came from Telegram.
 */
export const TELEGRAM_WEBHOOK_SECRET = defineSecret('TELEGRAM_WEBHOOK_SECRET');

/** Public bot handle without the @, e.g. "FitTrackCoachBot". Used to build the
 * t.me deep link the app shows when connecting an account. */
export const TELEGRAM_BOT_USERNAME = defineString('TELEGRAM_BOT_USERNAME', { default: '' });

/**
 * Fallback IANA timezone for a user whose profile has none (their "today" and
 * meal-type guess depend on it). Real users get their device timezone stored on
 * the profile when they link, so this only covers the gap.
 */
export const DEFAULT_TIMEZONE = defineString('DEFAULT_TIMEZONE', { default: 'UTC' });

/** Secrets the webhook binds: Telegram's own plus the active AI provider's
 * (photo/text meal estimation runs inline inside the webhook). */
export const TELEGRAM_SECRETS = [TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, ...AI_SECRETS];
