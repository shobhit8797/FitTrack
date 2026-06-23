import { CallableRequest, HttpsError } from 'firebase-functions/v2/https';

/**
 * Pull the authenticated uid off a callable request or reject. Every user-facing
 * function enforces auth here — this is the per-user authorization gate (spec §13).
 */
export function requireUid(req: CallableRequest): string {
  const uid = req.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign-in required.');
  }
  return uid;
}

/** Map internal errors to clean, app-facing HttpsErrors. */
export function toHttpsError(err: unknown): HttpsError {
  if (err instanceof HttpsError) return err;
  const message = err instanceof Error ? err.message : String(err);
  // AI parse/availability failures surface as a retryable message (spec §10).
  if (/parse|AI|provider|LLM/i.test(message)) {
    return new HttpsError(
      'unavailable',
      "Couldn't read the AI response — please try again.",
    );
  }
  return new HttpsError('internal', 'Something went wrong. Please try again.');
}
