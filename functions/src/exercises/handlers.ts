import { FieldValue } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { requireUid, toHttpsError } from '../lib/callable';

// Exercise catalog (spec §7.2 / §12): shared read-only catalog + private custom
// exercises. Catalog is seeded by Cloud Functions; clients search it and may
// create their own customs.

/** GET /exercises?search= — search the shared catalog + this user's customs. */
export const searchExercises = onCall(async (req) => {
  const uid = requireUid(req);
  try {
    const q = String(req.data?.search ?? '').trim().toLowerCase();
    const limit = Math.min(Number(req.data?.limit ?? 25), 50);

    let catalogQ = db.collection('exercises').orderBy('name').limit(limit);
    if (q.length >= 2) {
      const token = q.split(/\s+/)[0];
      catalogQ = db
        .collection('exercises')
        .where('searchTokens', 'array-contains', token)
        .limit(limit);
    }
    const [catalog, customs] = await Promise.all([
      catalogQ.get(),
      db.collection(`users/${uid}/customExercises`).limit(limit).get(),
    ]);

    const map = (d: FirebaseFirestore.QueryDocumentSnapshot, isCustom: boolean) => ({
      id: d.id,
      isCustom,
      ...d.data(),
    });
    const customResults = customs.docs
      .map((d) => map(d, true))
      .filter((e: any) => !q || String(e.name).toLowerCase().includes(q));

    return { results: [...customResults, ...catalog.docs.map((d) => map(d, false))] };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** GET /exercises/{id} — full detail incl. videoUrl + form cues. */
export const getExercise = onCall(async (req) => {
  const uid = requireUid(req);
  try {
    const id = String(req.data?.id ?? '');
    if (!id) throw new Error('id required');
    const catalog = await db.doc(`exercises/${id}`).get();
    if (catalog.exists) return { exercise: { id, isCustom: false, ...catalog.data() } };
    const custom = await db.doc(`users/${uid}/customExercises/${id}`).get();
    if (custom.exists) return { exercise: { id, isCustom: true, ...custom.data() } };
    return { exercise: null };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** POST /exercises/custom — create a private custom exercise. */
export const createCustomExercise = onCall(async (req) => {
  const uid = requireUid(req);
  try {
    const e = req.data?.exercise as {
      name: string;
      primaryMuscle?: string;
      equipment?: string;
      instructions?: string;
      formCues?: string[];
      videoUrl?: string;
    };
    if (!e?.name?.trim()) throw new Error('name required');
    const ref = db.collection(`users/${uid}/customExercises`).doc();
    const tokens = e.name.toLowerCase().split(/\s+/);
    await ref.set({
      name: e.name.trim(),
      primaryMuscle: e.primaryMuscle ?? '',
      equipment: e.equipment ?? '',
      instructions: e.instructions ?? '',
      formCues: e.formCues ?? [],
      videoUrl: e.videoUrl ?? null,
      difficulty: 'custom',
      isCustom: true,
      ownerUserId: uid,
      searchTokens: tokens,
      createdAt: FieldValue.serverTimestamp(),
    });
    return { id: ref.id };
  } catch (err) {
    throw toHttpsError(err);
  }
});
