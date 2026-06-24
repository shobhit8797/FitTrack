import { defineSecret, defineString } from 'firebase-functions/params';
import { GeminiProvider } from './gemini';
import { OpenRouterProvider } from './openrouter';
import { LLMProvider } from './types';

// Configurable layer (spec §10). PROVIDER selects the implementation; model
// ids live in config so they change without redeploying the app binary.
// Secrets are injected at runtime — they never appear in client code.
// Resolved at module load from .env (Firebase loads .env before analyzing the
// codebase). We use it to decide which secret to *declare* — Firebase requires
// every declared secret to have a value at deploy time, so a Gemini-only setup
// must not declare the OpenRouter secret at all.
const PROVIDER_NAME = process.env.PROVIDER ?? 'gemini';

export const PROVIDER = defineString('PROVIDER', { default: 'gemini' });
export const MODEL_OPENROUTER = defineString('MODEL_OPENROUTER', {
  default: 'google/gemini-3.5-flash',
});
export const MODEL_GEMINI = defineString('MODEL_GEMINI', { default: 'gemini-3.5-flash' });

export const GEMINI_API_KEY = defineSecret('GEMINI_API_KEY');
// Declared only when actually using OpenRouter, otherwise a Gemini-only deploy
// would fail because Secret Manager has no OPENROUTER_API_KEY version.
export const OPENROUTER_API_KEY =
  PROVIDER_NAME === 'openrouter' ? defineSecret('OPENROUTER_API_KEY') : undefined;

/**
 * Build the active provider from config/secrets. Call this inside the function
 * handler (after secrets are bound), not at module load.
 */
export function makeProvider(): LLMProvider {
  if (PROVIDER.value() === 'gemini') {
    return new GeminiProvider(MODEL_GEMINI.value(), GEMINI_API_KEY.value());
  }
  if (!OPENROUTER_API_KEY) {
    throw new Error(
      'OpenRouter selected but not configured. Set PROVIDER=openrouter in .env and create the OPENROUTER_API_KEY secret.',
    );
  }
  return new OpenRouterProvider(MODEL_OPENROUTER.value(), OPENROUTER_API_KEY.value());
}

/**
 * Secrets each AI-calling function binds. Only the active provider's key is
 * bound, so the deploy never requires a secret you haven't set.
 * Switch to OpenRouter: set PROVIDER=openrouter in .env + create OPENROUTER_API_KEY.
 */
export const AI_SECRETS =
  PROVIDER_NAME === 'openrouter' ? [OPENROUTER_API_KEY!, GEMINI_API_KEY] : [GEMINI_API_KEY];
