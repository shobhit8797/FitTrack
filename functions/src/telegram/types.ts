// The slice of the Telegram Bot API we actually consume. Hand-written rather
// than pulling in a bot framework: we only need webhook parsing + a handful of
// send methods, and Cloud Functions already owns the HTTP lifecycle.

export interface TgUser {
  id: number;
  is_bot: boolean;
  first_name?: string;
  username?: string;
}

export interface TgChat {
  id: number;
  type: 'private' | 'group' | 'supergroup' | 'channel';
}

/** One rendition of a photo. Telegram sends several sizes; we take the largest. */
export interface TgPhotoSize {
  file_id: string;
  file_unique_id: string;
  width: number;
  height: number;
  file_size?: number;
}

export interface TgMessage {
  message_id: number;
  from?: TgUser;
  chat: TgChat;
  date: number; // unix seconds
  text?: string;
  caption?: string;
  photo?: TgPhotoSize[];
}

export interface TgCallbackQuery {
  id: string;
  from: TgUser;
  message?: TgMessage;
  data?: string;
}

export interface TgUpdate {
  update_id: number;
  message?: TgMessage;
  edited_message?: TgMessage;
  callback_query?: TgCallbackQuery;
}

/** A single inline-keyboard button. `callback_data` is capped at 64 bytes by
 * Telegram — keep payloads to short opcodes plus a document id. */
export interface TgInlineButton {
  text: string;
  callback_data?: string;
  url?: string;
}

export type TgInlineKeyboard = TgInlineButton[][];
