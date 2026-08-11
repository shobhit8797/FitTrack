import { randomBytes } from 'node:crypto';
import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { db } from '../lib/admin';
import { TELEGRAM_BOT_USERNAME } from './config';
import { TgUser } from './types';

// Account linking. FitTrack is multi-user and Telegram knows nothing about
// Firebase Auth, so the app mints a short-lived code that the user hands to the
// bot (tapping the t.me deep link sends it automatically as /start <code>).
// Consuming the code binds chat_id → uid; everything the bot does afterwards is
// authorized by that binding.
//
// Collections (server-only — the catch-all deny in firestore.rules blocks
// clients; only the Admin SDK touches these):
//   telegramLinks/{code}    { uid, createdAt, expiresAt, usedAt? }
//   telegramChats/{chatId}  { uid, username, linkedAt }   ← the auth record
// plus a mirror on users/{uid}.telegram so the app can show "Connected".

/**
 * How long a link code stays valid. An hour covers the realistic path: the user
 * generates a code, gets interrupted, and comes back to finish. The code is
 * single-use and 32^6 wide, so the window costs little — a code is only useful
 * to someone who already read it off the user's screen.
 */
const CODE_TTL_MS = 60 * 60 * 1000;

/** No 0/O/1/I — these get read off a screen and retyped. */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 6;

function randomCode(): string {
  let out = '';
  for (const b of randomBytes(CODE_LENGTH)) out += CODE_ALPHABET[b % CODE_ALPHABET.length];
  return out;
}

export interface LinkCode {
  code: string;
  expiresAt: Date;
}

/**
 * Mint a fresh link code for `uid`. Any unused code the user minted earlier is
 * left to expire on its own — harmless, since consuming one requires the code
 * itself and each is single-use.
 */
export async function createLinkCode(uid: string): Promise<LinkCode> {
  const expiresAt = new Date(Date.now() + CODE_TTL_MS);
  // Collisions are vanishingly unlikely (32^6) but a retry costs nothing.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = randomCode();
    try {
      await db.doc(`telegramLinks/${code}`).create({
        uid,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(expiresAt),
      });
      return { code, expiresAt };
    } catch {
      // create() throws if the document already exists — try another code.
    }
  }
  throw new Error('Could not allocate a Telegram link code');
}

export type LinkResult =
  | { ok: true; uid: string }
  | { ok: false; reason: 'unknown' | 'expired' | 'used' };

/**
 * Redeem a code for a chat. Runs in a transaction so the same code can't be
 * consumed twice (e.g. the user forwards the deep link to a second chat).
 */
export async function consumeLinkCode(code: string, chat: TgUser & { chatId: number }): Promise<LinkResult> {
  const normalized = code.trim().toUpperCase();
  if (!/^[A-Z0-9]{4,12}$/.test(normalized)) return { ok: false, reason: 'unknown' };

  const linkRef = db.doc(`telegramLinks/${normalized}`);
  const result = await db.runTransaction<LinkResult>(async (tx) => {
    const snap = await tx.get(linkRef);
    if (!snap.exists) return { ok: false, reason: 'unknown' };
    if (snap.get('usedAt')) return { ok: false, reason: 'used' };
    const expiresAt = snap.get('expiresAt') as Timestamp | undefined;
    if (!expiresAt || expiresAt.toMillis() < Date.now()) return { ok: false, reason: 'expired' };

    const uid = snap.get('uid') as string;
    tx.update(linkRef, { usedAt: FieldValue.serverTimestamp(), chatId: chat.chatId });
    tx.set(db.doc(`telegramChats/${chat.chatId}`), {
      uid,
      username: chat.username ?? null,
      firstName: chat.first_name ?? null,
      linkedAt: FieldValue.serverTimestamp(),
    });
    tx.set(
      db.doc(`users/${uid}`),
      {
        telegram: {
          chatId: chat.chatId,
          username: chat.username ?? null,
          // Stamped in so the app can open the chat later without another call.
          botUsername: TELEGRAM_BOT_USERNAME.value() || null,
          linkedAt: Timestamp.now(),
        },
      },
      { merge: true },
    );
    return { ok: true, uid };
  });
  return result;
}

/** The chat → uid lookup every bot interaction starts with. */
export async function uidForChat(chatId: number): Promise<string | null> {
  const snap = await db.doc(`telegramChats/${chatId}`).get();
  return snap.exists ? ((snap.get('uid') as string) ?? null) : null;
}

/** Sever the binding from either side (bot /unlink, or the app's Disconnect).
 * recursiveDelete, not delete — the chat doc owns a `pending` subcollection of
 * un-reviewed estimates that would otherwise be orphaned. */
export async function unlinkChat(chatId: number): Promise<void> {
  const snap = await db.doc(`telegramChats/${chatId}`).get();
  const uid = snap.exists ? (snap.get('uid') as string | undefined) : undefined;
  await db.recursiveDelete(db.doc(`telegramChats/${chatId}`));
  if (uid) {
    await db.doc(`users/${uid}`).set({ telegram: FieldValue.delete() }, { merge: true });
  }
}

/** Unlink by uid — the path the app's Disconnect button takes. Returns the
 * chat that was unlinked, so the bot can say goodbye. */
export async function unlinkUser(uid: string): Promise<number | null> {
  const snap = await db.doc(`users/${uid}`).get();
  const chatId = snap.get('telegram.chatId') as number | undefined;
  if (chatId != null) await db.recursiveDelete(db.doc(`telegramChats/${chatId}`));
  await db.doc(`users/${uid}`).set({ telegram: FieldValue.delete() }, { merge: true });
  return chatId ?? null;
}
