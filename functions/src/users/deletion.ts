import { getAuth } from 'firebase-admin/auth';
import { onCall } from 'firebase-functions/v2/https';
import { db, storage } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';

/**
 * POST /users/delete-account (spec §13: delete account + all data).
 * Recursively removes the user's Firestore tree, their meal photos, and the
 * Auth record. Irreversible.
 */
export const deleteAccount = onCall({ timeoutSeconds: 300 }, async (req) => {
  const uid = requireUid(req);
  try {
    // Firestore: recursiveDelete handles the user doc + all subcollections.
    await db.recursiveDelete(db.doc(`users/${uid}`));

    // Storage: meal photos under mealPhotos/{uid}/.
    await storage
      .bucket()
      .deleteFiles({ prefix: `mealPhotos/${uid}/` })
      .catch(() => undefined);

    // Auth: remove the identity last so the client is fully signed out.
    await getAuth().deleteUser(uid);

    return { deleted: true };
  } catch (err) {
    throw toHttpsError(err);
  }
});
