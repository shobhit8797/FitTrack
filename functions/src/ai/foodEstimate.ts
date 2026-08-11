import { GroundedFood, groundFoodItems } from '../food/ifct';
import { makeProvider } from './factory';
import { parseJson } from './json';
import { MEAL_PHOTO_SYSTEM, TEXT_ESTIMATE_SYSTEM } from './prompts';
import { validateFoodAnalysis } from './schemas';
import { ImagePart } from './types';

// The meal-estimation core, extracted from the callable handlers so it has two
// callers: the iOS app (via onCall in ai/handlers.ts) and the Telegram bot
// (telegram/router.ts). Both must produce identical items — a meal logged from
// Telegram is the same document the app would have written.

/** Estimate + ground a meal described in free text ("150g chicken thigh + rice"). */
export async function estimateMealFromText(description: string): Promise<GroundedFood[]> {
  const provider = makeProvider();
  const res = await provider.complete({
    system: TEXT_ESTIMATE_SYSTEM,
    user: `Meal description: ${description}`,
    jsonObject: true,
    temperature: 0.3,
  });
  const analysis = validateFoodAnalysis(parseJson(res.text));
  return groundFoodItems(analysis.items);
}

/**
 * Estimate + ground a meal from a photo. `caption` carries any text the user
 * sent alongside the image ("about 200g", "half of this") — it materially
 * improves portion estimates, which are the weakest part of vision estimates.
 */
export async function estimateMealFromPhoto(
  image: ImagePart,
  caption?: string,
): Promise<GroundedFood[]> {
  const provider = makeProvider();
  const res = await provider.complete({
    system: MEAL_PHOTO_SYSTEM,
    user: caption?.trim()
      ? `Analyze the food in this photo. The user adds: "${caption.trim()}" — use it to pin down portions.`
      : 'Analyze the food in this photo.',
    images: [image],
    jsonObject: true,
    temperature: 0.3,
  });
  const analysis = validateFoodAnalysis(parseJson(res.text));
  return groundFoodItems(analysis.items);
}
