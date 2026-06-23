import { LLMError } from './types';

/**
 * fetch with timeout + exponential backoff on 429/5xx (spec §10: retries w/
 * backoff, timeouts, friendly error mapping). Uses the global fetch in Node 20.
 */
export async function fetchWithRetry(
  url: string,
  init: RequestInit,
  opts: { timeoutMs?: number; retries?: number } = {},
): Promise<Response> {
  const timeoutMs = opts.timeoutMs ?? 30_000;
  const retries = opts.retries ?? 3;

  for (let attempt = 0; attempt <= retries; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(url, { ...init, signal: controller.signal });
      clearTimeout(timer);

      if (res.status === 429 || res.status >= 500) {
        if (attempt < retries) {
          await sleep(backoffMs(attempt, res.headers.get('retry-after')));
          continue;
        }
        const body = await safeText(res);
        throw new LLMError(`Provider HTTP ${res.status}: ${body}`, res.status, true);
      }
      return res;
    } catch (err) {
      clearTimeout(timer);
      // AbortError / network blip — retry if attempts remain.
      const isAbort = err instanceof Error && err.name === 'AbortError';
      if (attempt < retries && (isAbort || isNetworkError(err))) {
        await sleep(backoffMs(attempt, null));
        continue;
      }
      if (err instanceof LLMError) throw err;
      throw new LLMError(
        `Provider request failed: ${err instanceof Error ? err.message : String(err)}`,
        undefined,
        true,
      );
    }
  }
  throw new LLMError(`Provider request failed after ${retries} retries`, undefined, true);
}

function backoffMs(attempt: number, retryAfter: string | null): number {
  if (retryAfter) {
    const secs = Number(retryAfter);
    if (Number.isFinite(secs)) return Math.min(secs * 1000, 15_000);
  }
  const base = 500 * Math.pow(2, attempt); // 500, 1000, 2000...
  const jitter = Math.floor(Math.random() * 250);
  return Math.min(base + jitter, 15_000);
}

function isNetworkError(err: unknown): boolean {
  return err instanceof TypeError; // fetch throws TypeError on network failure
}

async function safeText(res: Response): Promise<string> {
  try {
    return (await res.text()).slice(0, 500);
  } catch {
    return '<no body>';
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
