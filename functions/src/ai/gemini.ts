import { fetchWithRetry } from './http';
import { LLMError, LLMProvider, LLMRequest, LLMResponse } from './types';

/** Direct Google Gemini provider (spec §10). */
export class GeminiProvider implements LLMProvider {
  readonly name = 'gemini' as const;

  constructor(
    readonly model: string,
    private readonly apiKey: string,
  ) {}

  async complete(req: LLMRequest): Promise<LLMResponse> {
    const parts: Record<string, unknown>[] = [{ text: req.user }];
    for (const img of req.images ?? []) {
      parts.push({ inline_data: { mime_type: img.mimeType, data: img.base64 } });
    }

    const generationConfig: Record<string, unknown> = {
      temperature: req.temperature ?? 0.4,
      maxOutputTokens: req.maxTokens ?? 2048,
    };
    if (req.jsonObject) generationConfig.responseMimeType = 'application/json';

    const body = {
      system_instruction: { parts: [{ text: req.system }] },
      contents: [{ role: 'user', parts }],
      generationConfig,
    };

    const url = `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent`;
    const res = await fetchWithRetry(
      url,
      {
        method: 'POST',
        headers: {
          'x-goog-api-key': this.apiKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      },
      { timeoutMs: req.timeoutMs, retries: req.maxRetries },
    );

    const json = (await res.json()) as {
      candidates?: {
        content?: { parts?: { text?: string }[] };
        finishReason?: string;
      }[];
      promptFeedback?: { blockReason?: string };
      error?: { message?: string };
    };
    if (json.error) throw new LLMError(`Gemini error: ${json.error.message}`, res.status);

    // A blocked prompt returns no candidates — surface why so it's debuggable.
    if (json.promptFeedback?.blockReason) {
      throw new LLMError(
        `Gemini blocked the prompt (${json.promptFeedback.blockReason})`,
        res.status,
      );
    }

    const candidate = json.candidates?.[0];
    const text = candidate?.content?.parts?.map((p) => p.text ?? '').join('');
    if (!text) {
      throw new LLMError(
        `Gemini returned no content (finishReason=${candidate?.finishReason ?? 'none'})`,
        res.status,
      );
    }
    // MAX_TOKENS means the JSON is truncated and will fail to parse — fail loud
    // with an actionable message instead of a cryptic JSON error downstream.
    if (candidate?.finishReason === 'MAX_TOKENS') {
      throw new LLMError(
        'Gemini response truncated (MAX_TOKENS) — raise maxTokens for this task.',
        res.status,
      );
    }

    return { text, model: this.model, provider: this.name };
  }
}
