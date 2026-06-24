import { defineSecret, defineString } from 'firebase-functions/params';
import { GeminiProvider } from './gemini';
import { OpenRouterProvider } from './openrouter';
import { LLMProvider } from './types';

// Configurable layer (spec §10). PROVIDER selects the implementation; model
// ids live in config so they change without redeploying the app binary.
// Secrets are injected at runtime — they never appear in client code.
export const PROVIDER = defineString('PROVIDER', { default: 'gemini' });
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

/**
 * Secrets that any AI-calling function binds. Firebase fails a deploy if a bound
 * secret has no value in Secret Manager, so we bind only the active provider's
 * key. Default is Gemini → only GEMINI_API_KEY must be set.
 * To switch to OpenRouter: set PROVIDER=openrouter, create the OPENROUTER_API_KEY
 * secret, and add OPENROUTER_API_KEY back to this array.
 */
export const AI_SECRETS = [GEMINI_API_KEY];
