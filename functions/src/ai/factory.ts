import { defineSecret, defineString } from 'firebase-functions/params';
import { GeminiProvider } from './gemini';
import { OpenRouterProvider } from './openrouter';
import { LLMProvider } from './types';

// Configurable layer (spec §10). PROVIDER selects the implementation; model
// ids live in config so they change without redeploying the app binary.
// Secrets are injected at runtime — they never appear in client code.
export const PROVIDER = defineString('PROVIDER', { default: 'openrouter' });
export const MODEL_OPENROUTER = defineString('MODEL_OPENROUTER', {
  default: 'google/gemini-3.5-flash',
});
export const MODEL_GEMINI = defineString('MODEL_GEMINI', { default: 'gemini-3.5-flash' });

export const OPENROUTER_API_KEY = defineSecret('OPENROUTER_API_KEY');
export const GEMINI_API_KEY = defineSecret('GEMINI_API_KEY');

/**
 * Build the active provider from config/secrets. Call this inside the function
 * handler (after secrets are bound), not at module load.
 */
export function makeProvider(): LLMProvider {
  if (PROVIDER.value() === 'gemini') {
    return new GeminiProvider(MODEL_GEMINI.value(), GEMINI_API_KEY.value());
  }
  return new OpenRouterProvider(MODEL_OPENROUTER.value(), OPENROUTER_API_KEY.value());
}

/** Secrets that any AI-calling function must declare in its `runWith`. */
export const AI_SECRETS = [OPENROUTER_API_KEY, GEMINI_API_KEY];
