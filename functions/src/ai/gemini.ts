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
    const res = await fetchWithRetry(url, {
      method: 'POST',
      headers: {
        'x-goog-api-key': this.apiKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });

    const json = (await res.json()) as {
      candidates?: { content?: { parts?: { text?: string }[] } }[];
      error?: { message?: string };
    };
    if (json.error) throw new LLMError(`Gemini error: ${json.error.message}`, res.status);

    const text = json.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('');
    if (!text) throw new LLMError('Gemini returned no content', res.status);

    return { text, model: this.model, provider: this.name };
  }
}
