// Parsing typed sets out of a chat message. Deliberately deterministic — no LLM
// call. Set notation is a tiny formal language that people already write the same
// way in every gym notebook, and an AI round-trip would add seconds of latency
// plus a chance of hallucinated numbers to something a regex reads exactly.
//
// Accepted forms (weight always comes FIRST, the way a logbook reads):
//   squat 80x8, 80x8, 85x6      three sets
//   rdl 70x10 x3                the trailing "x3" repeats the set three times
//   leg press 140kg x 12        "kg" and spaces are optional
//   hanging knee raise bw x12   "bw"/"bodyweight" logs 0 kg
//   bench 90x5 @8.5             "@" records RPE
//
// The one ambiguity is "3x10": this reads it as 3 kg × 10 reps, not 3 sets of 10.
// Bodyweight work should say "bw x10" instead. HELP_TEXT states this.

/** One set as written by the user. */
export interface ParsedSet {
  weightKg: number;
  reps: number;
  rpe?: number;
}

/** One line of the message: the name as typed, plus its sets. */
export interface ParsedExerciseLine {
  rawName: string;
  sets: ParsedSet[];
}

export interface ParseResult {
  exercises: ParsedExerciseLine[];
  /** Lines that held no readable set, echoed back so the user sees what was skipped. */
  unparsed: string[];
}

/**
 * weight [kg] x reps [@ rpe] [x repeatCount]
 * The trailing repeat only matches when an "x" follows immediately, so
 * "80x8, 80x8" stays two sets while "70x10 x3" becomes three.
 */
const SET_RE =
  /(\d+(?:\.\d+)?|bw|bodyweight)\s*(?:kgs?)?\s*[x×*]\s*(\d+)(?:\s*@\s*(\d+(?:\.\d+)?))?(?:\s*[x×*]\s*(\d+)\b)?/gi;

/** Cap a single line so a pasted wall of text cannot balloon a session. */
const MAX_SETS_PER_LINE = 30;

function toWeight(token: string): number {
  const t = token.toLowerCase();
  if (t === 'bw' || t === 'bodyweight') return 0;
  const n = Number(t);
  return Number.isFinite(n) ? n : 0;
}

/** Read every set on one line. Used for a full line and for a guided-flow reply. */
export function parseSets(line: string): ParsedSet[] {
  const sets: ParsedSet[] = [];
  for (const m of line.matchAll(SET_RE)) {
    const weightKg = toWeight(m[1]);
    const reps = Number(m[2]);
    if (!Number.isFinite(reps) || reps <= 0 || reps > 500) continue;
    if (weightKg < 0 || weightKg > 1000) continue;
    const rpeRaw = m[3] != null ? Number(m[3]) : undefined;
    // RPE is a 1–10 scale; anything else is a misread, so drop it rather than
    // storing a nonsense number the app would render.
    const rpe = rpeRaw != null && rpeRaw >= 1 && rpeRaw <= 10 ? rpeRaw : undefined;
    const repeat = m[4] != null ? Math.min(Math.max(Number(m[4]), 1), MAX_SETS_PER_LINE) : 1;
    for (let i = 0; i < repeat && sets.length < MAX_SETS_PER_LINE; i++) {
      sets.push(rpe != null ? { weightKg, reps, rpe } : { weightKg, reps });
    }
  }
  return sets;
}

/** Where the first set starts on a line — everything before it is the name. */
function firstSetIndex(line: string): number {
  SET_RE.lastIndex = 0;
  const m = SET_RE.exec(line);
  SET_RE.lastIndex = 0;
  return m ? m.index : -1;
}

/**
 * Parse a whole message. One exercise per line; a leading "/sets" is stripped.
 * A line with a name but no numbers goes to `unparsed` so the reply can show it
 * — silently dropping a line the user meant to log is the worst outcome here.
 */
export function parseSetMessage(text: string): ParseResult {
  const exercises: ParsedExerciseLine[] = [];
  const unparsed: string[] = [];

  const body = text.replace(/^\s*\/sets(?:@\w+)?\s*/i, '');
  // Semicolons act as line breaks: typing several exercises on one phone line is
  // common, and Telegram makes a newline a two-tap affair.
  const lines = body
    .split(/[\n;]+/)
    .map((l) => l.trim())
    .filter(Boolean);

  for (const line of lines) {
    const idx = firstSetIndex(line);
    if (idx < 0) {
      unparsed.push(line);
      continue;
    }
    const rawName = line
      .slice(0, idx)
      .replace(/[-–—:,]+\s*$/, '')
      .trim();
    const sets = parseSets(line.slice(idx));
    if (!sets.length) {
      unparsed.push(line);
      continue;
    }
    // A line that is only numbers has no name of its own; the caller decides what
    // it belongs to (the guided flow knows; the free-text form cannot).
    exercises.push({ rawName, sets });
  }

  return { exercises, unparsed };
}

// ---- Matching a typed name to the plan ----------------------------------
// Linking a logged set to the planned exercise is what makes progression
// tracking work: "squat", "back squat" and "Barbell Back Squat" must all land on
// the same exercise, or every session looks like a brand-new movement.

/** Gym shorthand that no amount of string similarity would resolve. */
const ALIASES: Record<string, string> = {
  rdl: 'romanian deadlift',
  sldl: 'stiff leg deadlift',
  dl: 'deadlift',
  ohp: 'overhead press',
  bp: 'bench press',
  bb: 'barbell',
  db: 'dumbbell',
  lat: 'lat pulldown',
  pulldown: 'lat pulldown',
  pullup: 'pull up',
  pullups: 'pull up',
  chinup: 'chin up',
  chinups: 'chin up',
  hkr: 'hanging knee raise',
  calves: 'calf raise',
  legcurl: 'leg curl',
  legext: 'leg extension',
};

function normalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function words(s: string): string[] {
  return normalize(s).split(' ').filter(Boolean);
}

/** Expand shorthand tokens before matching. */
function expand(raw: string): string {
  return words(raw)
    .map((w) => ALIASES[w] ?? w)
    .join(' ');
}

export interface PlanExerciseRef {
  name: string;
  exerciseId?: string;
}

/**
 * Score how well a typed name matches a plan exercise. Higher wins; 0 means no
 * match. The ordering encodes intent: an exact name beats "every word I typed
 * appears in the plan name" (squat → Barbell Back Squat), which beats a partial
 * word-prefix match (calf → Standing Calf Raise).
 */
function score(typed: string, candidate: string): number {
  const t = words(expand(typed));
  const c = words(candidate);
  if (!t.length || !c.length) return 0;

  const tJoined = t.join(' ');
  const cJoined = c.join(' ');
  if (tJoined === cJoined) return 100;

  const allTypedInCandidate = t.every((w) => c.includes(w));
  if (allTypedInCandidate) return 80 + t.length;

  const allCandidateInTyped = c.every((w) => t.includes(w));
  if (allCandidateInTyped) return 70 + c.length;

  if (cJoined.includes(tJoined) || tJoined.includes(cJoined)) return 60;

  // Every typed word at least prefixes some candidate word ("quad" → "quads").
  const everyTypedPrefixes = t.every((w) => c.some((cw) => cw.startsWith(w) || w.startsWith(cw)));
  if (everyTypedPrefixes) return 40 + t.length;

  return 0;
}

/**
 * Resolve a typed name against the day's planned exercises. Falls back to the
 * user's own words (title-cased) when nothing matches — logging an off-plan
 * accessory lift must never fail, it just does not get an exerciseId.
 */
export function resolveExercise(
  rawName: string,
  planExercises: PlanExerciseRef[],
): { name: string; exerciseId?: string; matched: boolean } {
  let best: { ref: PlanExerciseRef; score: number } | null = null;
  for (const ref of planExercises) {
    const s = score(rawName, ref.name);
    if (s > 0 && (!best || s > best.score)) best = { ref, score: s };
  }
  if (best) {
    return {
      name: best.ref.name,
      ...(best.ref.exerciseId ? { exerciseId: best.ref.exerciseId } : {}),
      matched: true,
    };
  }
  return { name: titleCase(rawName), matched: false };
}

function titleCase(s: string): string {
  const cleaned = s.trim();
  if (!cleaned) return 'Exercise';
  return cleaned
    .split(/\s+/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

/** Total load moved, the one number that summarizes a session at a glance. */
export function volumeKg(sets: ParsedSet[]): number {
  return Math.round(sets.reduce((a, s) => a + s.weightKg * s.reps, 0));
}

/**
 * The session's best set: heaviest, and among equal weights the one with most
 * reps. This is what gets compared week to week.
 */
export function topSet(sets: ParsedSet[]): ParsedSet | null {
  return sets.reduce<ParsedSet | null>((best, s) => {
    if (!best) return s;
    if (s.weightKg > best.weightKg) return s;
    if (s.weightKg === best.weightKg && s.reps > best.reps) return s;
    return best;
  }, null);
}
