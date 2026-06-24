import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';

/**
 * exportData (spec §13: export account data). Gathers the signed-in user's full
 * Firestore tree into a single JSON-serializable object and returns it. Firestore
 * Timestamps serialize fine through the callable transport, so we hand back the
 * raw doc data. No pagination for v1 — but we only read this user's own subtrees,
 * never an unbounded collection group.
 */

/** Read every doc in a subcollection under users/{uid} as id + data. */
async function readSubcollection(
  uid: string,
  name: string,
): Promise<Array<Record<string, unknown>>> {
  const snap = await db.collection(`users/${uid}/${name}`).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

export const exportData = onCall({ timeoutSeconds: 120 }, async (req) => {
  const uid = requireUid(req);
  try {
    const profileSnap = await db.doc(`users/${uid}`).get();

    const [weightEntries, workoutSessions, workoutPlans, customExercises] =
      await Promise.all([
        readSubcollection(uid, 'weightEntries'),
        readSubcollection(uid, 'workoutSessions'),
        readSubcollection(uid, 'workoutPlans'),
        readSubcollection(uid, 'customExercises'),
      ]);

    // dayLogs nest a meals subcollection per day — fetch each day's meals too.
    const dayLogsSnap = await db.collection(`users/${uid}/dayLogs`).get();
    const dayLogs = await Promise.all(
      dayLogsSnap.docs.map(async (d) => {
        const mealsSnap = await db
          .collection(`users/${uid}/dayLogs/${d.id}/meals`)
          .get();
        return {
          id: d.id,
          ...d.data(),
          meals: mealsSnap.docs.map((m) => ({ id: m.id, ...m.data() })),
        };
      }),
    );

    return {
      exportedAt: new Date().toISOString(),
      data: {
        profile: profileSnap.exists ? { id: profileSnap.id, ...profileSnap.data() } : null,
        weightEntries,
        dayLogs,
        workoutSessions,
        workoutPlans,
        customExercises,
      },
    };
  } catch (err) {
    throw toHttpsError(err);
  }
});
