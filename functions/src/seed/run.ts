import { FieldValue } from 'firebase-admin/firestore';
import { db } from '../lib/admin';
import { EXERCISES } from './exercises.data';
import { IFCT_FOODS } from './ifct.data';

// Seed the shared catalog + IFCT food DB. Idempotent: doc ids are slugs, so
// re-running upserts. Run against the emulator or with admin creds:
//   npm run seed
function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
}
function tokens(s: string): string[] {
  return Array.from(new Set(s.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 2)));
}

async function seedExercises(): Promise<number> {
  let batch = db.batch();
  let n = 0;
  for (const e of EXERCISES) {
    const ref = db.doc(`exercises/${slug(e.name)}`);
    batch.set(ref, {
      ...e,
      isCustom: false,
      searchTokens: tokens(`${e.name} ${e.primaryMuscle} ${e.equipment}`),
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (++n % 400 === 0) {
      await batch.commit();
      batch = db.batch();
    }
  }
  await batch.commit();
  return EXERCISES.length;
}

async function seedFoods(): Promise<number> {
  let batch = db.batch();
  let n = 0;
  for (const f of IFCT_FOODS) {
    const ref = db.doc(`ifctFoods/${slug(f.dishKey)}`);
    batch.set(ref, {
      ...f,
      searchTokens: tokens(`${f.name} ${f.dishKey}`),
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (++n % 400 === 0) {
      await batch.commit();
      batch = db.batch();
    }
  }
  await batch.commit();
  return IFCT_FOODS.length;
}

async function main(): Promise<void> {
  const [ex, food] = await Promise.all([seedExercises(), seedFoods()]);
  // eslint-disable-next-line no-console
  console.log(`Seeded ${ex} exercises and ${food} IFCT foods.`);
}

main().then(
  () => process.exit(0),
  (err) => {
    // eslint-disable-next-line no-console
    console.error(err);
    process.exit(1);
  },
);
