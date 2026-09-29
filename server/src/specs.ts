/** Validation for model-generated specs. Models are told the schema; this is where we stop trusting them. */

export type RoutineSpec = { everyMinutes: number; title: string };
export type SuggestionSpec = { title: string; description: string; agentPrompt: string; appHint?: string | null; routine?: RoutineSpec | null };
export type AwanSpec = {
  slug: string;
  name: string;
  roleText: string;
  oneLiner: string;
  introMessages: string[];
  suggestedAsks: string[];
  baseHue: number;
  routine?: RoutineSpec | null;
  suggestion?: SuggestionSpec | null;
};

const str = (v: unknown, field: string, max = 4000): string => {
  if (typeof v !== 'string' || !v.trim()) throw new Error(`missing ${field}`);
  return v.trim().slice(0, max);
};

export function slugify(s: string) {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 40) || 'awan'
  );
}

function routine(v: unknown): RoutineSpec | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as { everyMinutes?: unknown; every_minutes?: unknown; title?: unknown };
  const every = Number(o.everyMinutes ?? o.every_minutes);
  if (!Number.isFinite(every) || every < 15) return null;
  return { everyMinutes: Math.round(Math.min(every, 60 * 24 * 31)), title: typeof o.title === 'string' ? o.title.slice(0, 80) : 'Routine' };
}

export function validateSuggestion(v: unknown): SuggestionSpec {
  const o = (v ?? {}) as Record<string, unknown>;
  return {
    title: str(o.title, 'title', 200),
    description: str(o.description, 'description', 1200),
    agentPrompt: str(o.agentPrompt ?? o.agent_prompt, 'agentPrompt', 8000),
    appHint: typeof o.appHint === 'string' ? o.appHint.slice(0, 40) : null,
    routine: routine(o.routine),
  };
}

export function validateAwanSpec(v: unknown): AwanSpec {
  const o = (v ?? {}) as Record<string, unknown>;
  const name = str(o.name, 'name', 40);
  const list = (x: unknown, field: string, n: number) => {
    if (!Array.isArray(x) || x.length === 0) throw new Error(`missing ${field}`);
    return x.map((s) => String(s).trim()).filter(Boolean).slice(0, n);
  };
  const hue = Number(o.baseHue);
  return {
    slug: slugify(typeof o.slug === 'string' && o.slug ? o.slug : name),
    name,
    roleText: str(o.roleText, 'roleText', 40),
    oneLiner: str(o.oneLiner, 'oneLiner', 160),
    introMessages: list(o.introMessages, 'introMessages', 4),
    suggestedAsks: list(o.suggestedAsks, 'suggestedAsks', 3),
    baseHue: Number.isFinite(hue) ? ((hue % 1) + 1) % 1 : Math.random(),
    routine: routine(o.routine),
    suggestion: o.suggestion ? validateSuggestion(o.suggestion) : null,
  };
}
