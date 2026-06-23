import { db } from '../lib/admin';
import { FoodItem } from '../ai/schemas';

// IFCT grounding (spec §7.3 / §12). Per-100g macros for common Indian dishes
// live in the `ifctFoods` collection (seeded). When the LLM returns a dishKey
// with a confident DB match, we scale the DB composition by the estimated
// portion and surface BOTH numbers so the user can pick.

export interface GroundedFood extends FoodItem {
  /** Grounded (DB-backed) macros, present only when a confident match exists. */
  grounded?: {
    source: 'ifct';
    foodDbId: string;
    matchedName: string;
    estimatedGrams: number;
    calories: number;
    proteinG: number;
    carbsG: number;
    fatG: number;
  };
}

interface IfctDoc {
  name: string;
  dishKey: string;
  per100g: { calories: number; proteinG: number; carbsG: number; fatG: number };
  /** Typical serving in grams (katori/piece) for portion scaling. */
  typicalServingG?: number;
}

/** Look up one dishKey; returns the IFCT doc or null. */
async function findByDishKey(dishKey: string): Promise<(IfctDoc & { id: string }) | null> {
  if (!dishKey) return null;
  const snap = await db
    .collection('ifctFoods')
    .where('dishKey', '==', dishKey)
    .limit(1)
    .get();
  if (snap.empty) return null;
  const doc = snap.docs[0];
  return { id: doc.id, ...(doc.data() as IfctDoc) };
}

/**
 * Estimate the grams a serving represents. We trust the LLM's own calorie
 * estimate to back out a portion size against the DB's per-100g density, which
 * is more robust than parsing free-text serving descriptions.
 */
function estimateGrams(item: FoodItem, doc: IfctDoc): number {
  const per100 = doc.per100g.calories;
  if (per100 > 0 && item.calories > 0) {
    const grams = (item.calories / per100) * 100;
    // Clamp to a sane range so a wild LLM estimate can't produce absurd portions.
    return Math.round(Math.min(Math.max(grams, 20), 1500));
  }
  return doc.typicalServingG ?? 150;
}

export async function groundFoodItems(items: FoodItem[]): Promise<GroundedFood[]> {
  return Promise.all(
    items.map(async (item): Promise<GroundedFood> => {
      const doc = await findByDishKey(item.dishKey);
      if (!doc) return item;
      const grams = estimateGrams(item, doc);
      const scale = grams / 100;
      return {
        ...item,
        grounded: {
          source: 'ifct',
          foodDbId: doc.id,
          matchedName: doc.name,
          estimatedGrams: grams,
          calories: Math.round(doc.per100g.calories * scale),
          proteinG: +(doc.per100g.proteinG * scale).toFixed(1),
          carbsG: +(doc.per100g.carbsG * scale).toFixed(1),
          fatG: +(doc.per100g.fatG * scale).toFixed(1),
        },
      };
    }),
  );
}
