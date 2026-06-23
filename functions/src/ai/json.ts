import { LLMError } from './types';

/**
 * Strip stray ```json fences and parse into T (spec §10). On failure throws an
 * LLMError that callers map to the app-facing "couldn't read the AI response".
 */
export function parseJson<T>(raw: string): T {
  const cleaned = stripFences(raw).trim();
  try {
    return JSON.parse(cleaned) as T;
  } catch {
    // Last resort: grab the first balanced {...} or [...] block.
    const salvaged = salvageJson(cleaned);
    if (salvaged) {
      try {
        return JSON.parse(salvaged) as T;
      } catch {
        /* fall through */
      }
    }
    throw new LLMError('Could not parse AI JSON response', undefined, false);
  }
}

function stripFences(s: string): string {
  return s
    .replace(/^\s*```(?:json)?\s*/i, '')
    .replace(/\s*```\s*$/i, '')
    .trim();
}

function salvageJson(s: string): string | null {
  const firstObj = s.indexOf('{');
  const firstArr = s.indexOf('[');
  const start =
    firstObj === -1 ? firstArr : firstArr === -1 ? firstObj : Math.min(firstObj, firstArr);
  if (start === -1) return null;
  const open = s[start];
  const close = open === '{' ? '}' : ']';
  let depth = 0;
  for (let i = start; i < s.length; i++) {
    if (s[i] === open) depth++;
    else if (s[i] === close) {
      depth--;
      if (depth === 0) return s.slice(start, i + 1);
    }
  }
  return null;
}
