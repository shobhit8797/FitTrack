// Shared LLM request/response shapes used across both providers.
// The app never sees these — they live entirely behind the Cloud Functions.

export interface ImagePart {
  /** Raw base64 (no data: prefix) */
  base64: string;
  mimeType: string; // e.g. "image/jpeg"
}

export interface LLMRequest {
  /** System instruction; mapped to system_instruction (Gemini) or a system message (OpenRouter). */
  system: string;
  /** The user/content text. */
  user: string;
  /** Optional images for vision tasks (meal photos, labels). */
  images?: ImagePart[];
  /** Force the model to return a single JSON object. */
  jsonObject?: boolean;
  /** Soft cap on output tokens. */
  maxTokens?: number;
  temperature?: number;
  /** Per-request fetch timeout override (ms). Defaults to the transport's 30s.
   * Raise for large generations (e.g. a full 7-day diet plan). */
  timeoutMs?: number;
  /** Per-request retry override. Defaults to the transport's 3. Lower it for
   * long-timeout calls so the worst case stays under the function budget. */
  maxRetries?: number;
}

export interface LLMResponse {
  /** Raw text returned by the model (may contain stray ```json fences). */
  text: string;
  model: string;
  provider: ProviderName;
}

export type ProviderName = 'openrouter' | 'gemini';

export interface LLMProvider {
  readonly name: ProviderName;
  readonly model: string;
  complete(req: LLMRequest): Promise<LLMResponse>;
}

/** Thrown when a provider call fails after retries or returns no content. */
export class LLMError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly retriable = false,
  ) {
    super(message);
    this.name = 'LLMError';
  }
}
