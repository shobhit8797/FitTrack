import { onCall } from 'firebase-functions/v2/https';
import { requireUid, toHttpsError } from '../lib/callable';
import { groundFoodItems } from '../food/ifct';
import { AI_SECRETS, makeProvider } from './factory';
import { estimateMealFromPhoto, estimateMealFromText } from './foodEstimate';
import { parseJson } from './json';
import {
  ChatTurn,
  LABEL_SYSTEM,
  MEAL_CHAT_SYSTEM,
  mealChatUser,
} from './prompts';
import { validateLabel, validateMealChat } from './schemas';
import { ImagePart } from './types';

const callOpts = { secrets: AI_SECRETS, timeoutSeconds: 120, memory: '512MiB' as const };

/** POST /ai/analyze-meal — photo analysis + IFCT grounding (spec §11.2 / §7.3). */
export const analyzeMeal = onCall(callOpts, async (req) => {
  requireUid(req);
  try {
    const image = req.data?.image as ImagePart | undefined;
    if (!image?.base64) throw new Error('image required');
    // Estimation + IFCT grounding live in ai/foodEstimate so the Telegram bot
    // produces identical items from the same photo.
    const items = await estimateMealFromPhoto(image);
    return { items };
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

// ---- Multimodal meal-logging chat ----
// Stateless like the diet coach: the client relays the full transcript + every
// attached image each turn. Bound both so an untrusted client can't blow the
// cost/context budget.
const MAX_CHAT_IMAGES = 6;

function sanitizeChat(v: unknown): ChatTurn[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((m): ChatTurn => {
      const o = m && typeof m === 'object' ? (m as Record<string, unknown>) : {};
      const role = o.role === 'assistant' ? 'assistant' : 'user';
      const content = typeof o.content === 'string' ? o.content.slice(0, 4000) : '';
      return { role, content };
    })
    .filter((m) => m.content.trim())
    .slice(-24);
}

function sanitizeImages(v: unknown): ImagePart[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((i): ImagePart | null => {
      const o = i && typeof i === 'object' ? (i as Record<string, unknown>) : {};
      const base64 = typeof o.base64 === 'string' ? o.base64 : '';
      const mimeType = typeof o.mimeType === 'string' ? o.mimeType : 'image/jpeg';
      return base64 ? { base64, mimeType } : null;
    })
    .filter((i): i is ImagePart => i !== null)
    // Keep the most recent images if the client somehow sends more than the cap.
    .slice(-MAX_CHAT_IMAGES);
}

/**
 * POST /ai/meal-chat — one turn of the multimodal meal-logging chat. Combines the
 * transcript, any scanned-product context, and all attached photos, then either
 * asks a clarifying question or returns grounded food items ready to review.
 */
export const mealChat = onCall(callOpts, async (req) => {
  requireUid(req);
  try {
    const messages = sanitizeChat(req.data?.messages);
    const images = sanitizeImages(req.data?.images);
    if (!messages.length && !images.length) throw new Error('messages or images required');
    const provider = makeProvider();
    const res = await provider.complete({
      system: MEAL_CHAT_SYSTEM,
      user: mealChatUser(messages, images.length),
      images: images.length ? images : undefined,
      jsonObject: true,
      temperature: 0.3,
    });
    const result = validateMealChat(parseJson(res.text));
    // Only ground once the model has committed to items (a question turn has none).
    const items = result.items.length ? await groundFoodItems(result.items) : [];
    return { reply: result.reply, needsFollowUp: result.needsFollowUp, items, model: res.model };
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
    const items = await estimateMealFromText(description);
    return { items };
  } catch (err) {
    throw toHttpsError(err);
  }
});
