import { FieldValue } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { db } from '../lib/admin';
import { fetchWithRetry } from '../ai/http';
import { requireUid, toHttpsError } from '../lib/callable';

// ---- Open Food Facts barcode proxy + cache (spec §7.3 / §12) ----
interface CachedProduct {
  barcode: string;
  productName: string | null;
  brand: string | null;
  servingSize: string | null;
  perServing: {
    calories: number | null;
    proteinG: number | null;
    carbsG: number | null;
    fatG: number | null;
    fiberG: number | null;
  };
  per100g: {
    calories: number | null;
    proteinG: number | null;
    carbsG: number | null;
    fatG: number | null;
    fiberG: number | null;
  };
  source: 'openfoodfacts';
}

function n(v: unknown): number | null {
  const x = typeof v === 'string' ? Number(v) : v;
  return typeof x === 'number' && Number.isFinite(x) ? x : null;
}

/** GET /food/barcode/{code} → cached OFF product. */
export const foodBarcode = onCall(async (req) => {
  requireUid(req);
  try {
    const code = String(req.data?.barcode ?? '').replace(/\D/g, '');
    if (!code) throw new Error('barcode required');

    const cacheRef = db.doc(`foodsCache/${code}`);
    const cached = await cacheRef.get();
    if (cached.exists) return { product: cached.data() };

    const res = await fetchWithRetry(
      `https://world.openfoodfacts.org/api/v2/product/${code}.json?fields=product_name,brands,serving_size,nutriments`,
      { headers: { 'User-Agent': 'FitTrack/0.1 (contact@fittrack.app)' } },
      { retries: 2, timeoutMs: 12_000 },
    );
    const json = (await res.json()) as { status?: number; product?: Record<string, any> };
    if (json.status !== 1 || !json.product) {
      return { product: null, notFound: true };
    }
    const p = json.product;
    const nutr = p.nutriments ?? {};
    const product: CachedProduct = {
      barcode: code,
      productName: p.product_name ?? null,
      brand: p.brands ?? null,
      servingSize: p.serving_size ?? null,
      perServing: {
        calories: n(nutr['energy-kcal_serving']),
        proteinG: n(nutr['proteins_serving']),
        carbsG: n(nutr['carbohydrates_serving']),
        fatG: n(nutr['fat_serving']),
        fiberG: n(nutr['fiber_serving']),
      },
      per100g: {
        calories: n(nutr['energy-kcal_100g']),
        proteinG: n(nutr['proteins_100g']),
        carbsG: n(nutr['carbohydrates_100g']),
        fatG: n(nutr['fat_100g']),
        fiberG: n(nutr['fiber_100g']),
      },
      source: 'openfoodfacts',
    };
    await cacheRef.set({ ...product, cachedAt: FieldValue.serverTimestamp() });
    return { product };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** GET /food/search?q= → IFCT DB + cached OFF products (spec §7.3). */
export const foodSearch = onCall(async (req) => {
  requireUid(req);
  try {
    const q = String(req.data?.q ?? '').trim().toLowerCase();
    if (q.length < 2) return { results: [] };
    const token = q.split(/\s+/)[0];

    const ifctSnap = await db
      .collection('ifctFoods')
      .where('searchTokens', 'array-contains', token)
      .limit(20)
      .get();

    const results = ifctSnap.docs.map((d) => {
      const data = d.data();
      return {
        id: d.id,
        name: data.name,
        source: 'ifct' as const,
        per100g: data.per100g,
        typicalServingG: data.typicalServingG ?? null,
      };
    });
    return { results };
  } catch (err) {
    throw toHttpsError(err);
  }
});
