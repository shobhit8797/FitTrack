import { fetchWithRetry } from '../ai/http';
import { ImagePart } from '../ai/types';
import { TELEGRAM_BOT_TOKEN } from './config';
import { TgInlineKeyboard } from './types';

// Thin Telegram Bot API client. Every call goes through fetchWithRetry so a 429
// or a 5xx from Telegram backs off instead of dropping the user's message.

const API_BASE = 'https://api.telegram.org';

function token(): string {
  const t = TELEGRAM_BOT_TOKEN.value();
  if (!t) throw new Error('TELEGRAM_BOT_TOKEN is not configured');
  return t;
}

async function call<T>(method: string, body: unknown): Promise<T> {
  const res = await fetchWithRetry(
    `${API_BASE}/bot${token()}/${method}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    },
    { timeoutMs: 20_000, retries: 2 },
  );
  const json = (await res.json()) as { ok: boolean; result: T; description?: string };
  if (!json.ok) throw new Error(`Telegram ${method} failed: ${json.description ?? 'unknown error'}`);
  return json.result;
}

/**
 * Escape text for parse_mode: HTML. We use HTML rather than MarkdownV2 because
 * food names are full of characters MarkdownV2 requires escaping (-, ., (, +),
 * and a single missed one makes Telegram reject the whole message.
 */
export function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Telegram rejects messages over 4096 characters. */
const MAX_MESSAGE = 4096;

export async function sendMessage(
  chatId: number,
  text: string,
  opts: { keyboard?: TgInlineKeyboard; replyTo?: number } = {},
): Promise<number> {
  const msg = await call<{ message_id: number }>('sendMessage', {
    chat_id: chatId,
    text: text.slice(0, MAX_MESSAGE),
    parse_mode: 'HTML',
    // Link previews on a food name are noise in a logging chat.
    link_preview_options: { is_disabled: true },
    reply_to_message_id: opts.replyTo,
    reply_markup: opts.keyboard ? { inline_keyboard: opts.keyboard } : undefined,
  });
  return msg.message_id;
}

/** Rewrite a message in place — used to collapse a confirmation prompt's
 * buttons into a final "saved" / "discarded" line. */
export async function editMessageText(
  chatId: number,
  messageId: number,
  text: string,
  keyboard?: TgInlineKeyboard,
): Promise<void> {
  await call('editMessageText', {
    chat_id: chatId,
    message_id: messageId,
    text: text.slice(0, MAX_MESSAGE),
    parse_mode: 'HTML',
    link_preview_options: { is_disabled: true },
    reply_markup: keyboard ? { inline_keyboard: keyboard } : undefined,
  });
}

/**
 * Swap a message's buttons without touching its text. Used for the meal-type
 * picker: editMessageText would require re-sending the card, and Telegram only
 * hands back the *plain* rendering of what we sent, so the formatting would be
 * lost in the round-trip.
 */
export async function editMessageReplyMarkup(
  chatId: number,
  messageId: number,
  keyboard: TgInlineKeyboard,
): Promise<void> {
  await call('editMessageReplyMarkup', {
    chat_id: chatId,
    message_id: messageId,
    reply_markup: { inline_keyboard: keyboard },
  });
}

/** Show "typing…" while an AI estimate runs (they take a few seconds). */
export async function sendChatAction(chatId: number, action = 'typing'): Promise<void> {
  await call('sendChatAction', { chat_id: chatId, action });
}

/** Dismiss the button spinner. Telegram shows a spinner on the tapped inline
 * button until this is answered, so it must be called on every callback. */
export async function answerCallbackQuery(id: string, text?: string): Promise<void> {
  await call('answerCallbackQuery', { callback_query_id: id, text });
}

/**
 * Download a photo the user sent and return it as the base64 ImagePart the LLM
 * providers expect. Two hops: getFile resolves a file_id to a path, then the
 * file endpoint serves the bytes.
 */
export async function fetchPhotoAsImagePart(fileId: string): Promise<ImagePart> {
  const file = await call<{ file_path?: string }>('getFile', { file_id: fileId });
  if (!file.file_path) throw new Error('Telegram returned no file path for the photo');
  const res = await fetchWithRetry(
    `${API_BASE}/file/bot${token()}/${file.file_path}`,
    { method: 'GET' },
    { timeoutMs: 30_000, retries: 2 },
  );
  const buf = Buffer.from(await res.arrayBuffer());
  const mimeType = file.file_path.endsWith('.png') ? 'image/png' : 'image/jpeg';
  return { base64: buf.toString('base64'), mimeType };
}

/** Register the command list shown in Telegram's "/" menu. Called by
 * scripts/setup-telegram.mjs, not at runtime. */
export async function setMyCommands(
  commands: Array<{ command: string; description: string }>,
): Promise<void> {
  await call('setMyCommands', { commands });
}
