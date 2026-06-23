import { fetchWithRetry } from './http';
import { LLMError, LLMProvider, LLMRequest, LLMResponse } from './types';

const ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';

type ContentPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string } };

/** OpenAI-compatible provider (spec §10). */
export class OpenRouterProvider implements LLMProvider {
  readonly name = 'openrouter' as const;

  constructor(
    readonly model: string,
    private readonly apiKey: string,
    private readonly referer = 'https://fittrack.app',
    private readonly title = 'FitTrack',
  ) {}

  async complete(req: LLMRequest): Promise<LLMResponse> {
    const userContent: ContentPart[] = [{ type: 'text', text: req.user }];
    for (const img of req.images ?? []) {
      userContent.push({
        type: 'image_url',
        image_url: { url: `data:${img.mimeType};base64,${img.base64}` },
      });
    }

    const body: Record<string, unknown> = {
      model: this.model,
      messages: [
        { role: 'system', content: req.system },
        { role: 'user', content: userContent },
      ],
      temperature: req.temperature ?? 0.4,
      max_tokens: req.maxTokens ?? 2048,
    };
    if (req.jsonObject) body.response_format = { type: 'json_object' };

    const res = await fetchWithRetry(ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': this.referer,
        'X-Title': this.title,
      },
      body: JSON.stringify(body),
    });

    const json = (await res.json()) as {
      choices?: { message?: { content?: string } }[];
      error?: { message?: string };
    };
    if (json.error) throw new LLMError(`OpenRouter error: ${json.error.message}`, res.status);

    const text = json.choices?.[0]?.message?.content;
    if (!text) throw new LLMError('OpenRouter returned no content', res.status);

    return { text, model: this.model, provider: this.name };
  }
}
