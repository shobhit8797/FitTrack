import { onCall } from 'firebase-functions/v2/https';
import { requireUid, toHttpsError } from '../lib/callable';
import { groundFoodItems } from '../food/ifct';
import { AI_SECRETS, makeProvider } from './factory';
import { parseJson } from './json';
import {
  LABEL_SYSTEM,
  MEAL_PHOTO_SYSTEM,
  PLAN_SYSTEM,
  PlanPromptInputs,
  TEXT_ESTIMATE_SYSTEM,
  planUser,
} from './prompts';
import {
  validateFoodAnalysis,
  validateLabel,
  validatePlan,
} from './schemas';
import { ImagePart } from './types';

const callOpts = { secrets: AI_SECRETS, timeoutSeconds: 120, memory: '512MiB' as const };

/** POST /ai/generate-plan — workout plan generation (spec §11.1). */
export const generatePlan = onCall(callOpts, async (req) => {
  requireUid(req);
  try {
    const inputs = req.data?.inputs as PlanPromptInputs;
    if (!inputs) throw new Error('inputs required');
    const provider = makeProvider();
    const res = await provider.complete({
      system: PLAN_SYSTEM,
      user: planUser(inputs),
      jsonObject: true,
      temperature: 0.5,
      maxTokens: 3000,
    });
    return { plan: validatePlan(parseJson(res.text)), model: res.model };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** POST /ai/analyze-meal — photo analysis + IFCT grounding (spec §11.2 / §7.3). */
export const analyzeMeal = onCall(callOpts, async (req) => {
  requireUid(req);
  try {
    const image = req.data?.image as ImagePart | undefined;
    if (!image?.base64) throw new Error('image required');
    const provider = makeProvider();
    const res = await provider.complete({
      system: MEAL_PHOTO_SYSTEM,
      user: 'Analyze the food in this photo.',
      images: [image],
      jsonObject: true,
      temperature: 0.3,
    });
    const analysis = validateFoodAnalysis(parseJson(res.text));
    // Cross-reference each dishKey against the IFCT DB; attach grounded macros.
    const grounded = await groundFoodItems(analysis.items);
    return { items: grounded, model: res.model };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** POST /ai/parse-label — nutrition-label parsing (spec §11.3). */
export const parseLabel = onCall(callOpts, async (req) => {
  requireUid(req);
  try {
    const ocrText = (req.data?.ocrText as string) ?? '';
    const image = req.data?.image as ImagePart | undefined;
    const provider = makeProvider();
    const res = await provider.complete({
      system: LABEL_SYSTEM,
      user: ocrText
        ? `OCR text from label:\n${ocrText}`
        : 'Read the nutrition label in this image.',
      images: image?.base64 ? [image] : undefined,
      jsonObject: true,
      temperature: 0.1,
    });
    return { label: validateLabel(parseJson(res.text)), model: res.model };
  } catch (err) {
    throw toHttpsError(err);
  }
});

/** POST /ai/estimate-text — free-text meal estimate + grounding (spec §11.4). */
export const estimateText = onCall(callOpts, async (req) => {
  requireUid(req);
  try {
    const description = (req.data?.description as string) ?? '';
    if (!description.trim()) throw new Error('description required');
    const provider = makeProvider();
    const res = await provider.complete({
      system: TEXT_ESTIMATE_SYSTEM,
      user: `Meal description: ${description}`,
      jsonObject: true,
      temperature: 0.3,
    });
    const analysis = validateFoodAnalysis(parseJson(res.text));
    const grounded = await groundFoodItems(analysis.items);
    return { items: grounded, model: res.model };
  } catch (err) {
    throw toHttpsError(err);
  }
});
