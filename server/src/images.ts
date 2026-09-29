/**
 * Image answers for the companion's [IMAGES:query] tag: up to 8 real pictures, each one checked to be
 * an image before the app is told about it. Candidates come from the model with OpenRouter's web
 * search plugin (it returns URLs it actually found), topped up from Wikimedia Commons (free, keyless)
 * when the model's list comes back thin. Results are cached in memory for a day.
 */
import { complete, config as llm } from './llm.ts';

export type ImageResult = { title: string; imageUrl: string; pageUrl: string | null; thumbnailUrl?: string | null };

export type ImageSearchDeps = {
  /** Candidate images for a query (unvalidated). */
  propose: (query: string) => Promise<ImageResult[]>;
  /** Extra candidates when the first source is thin (optional). */
  fallback?: (query: string) => Promise<ImageResult[]>;
  /** True when the URL answers with an image/* content type. */
  isImage: (url: string) => Promise<boolean>;
};

export const IMAGE_LIMIT = 8;
const CACHE_TTL_MS = 24 * 3600_000;
const cache = new Map<string, { at: number; results: ImageResult[] }>();

export function normaliseQuery(q: string) {
  return q.replace(/\s+/g, ' ').trim().toLowerCase().slice(0, 160);
}

export function clearImageCache() {
  cache.clear();
}

export async function searchImages(query: string, deps: ImageSearchDeps, now = Date.now()): Promise<ImageResult[]> {
  const key = normaliseQuery(query);
  if (!key) return [];
  const hit = cache.get(key);
  if (hit && now - hit.at < CACHE_TTL_MS) return hit.results;

  const seen = new Set<string>();
  const out: ImageResult[] = [];
  const take = async (candidates: ImageResult[]) => {
    const fresh = candidates.filter((c) => {
      if (!isPublicHttpUrl(c.imageUrl) || seen.has(c.imageUrl)) return false;
      seen.add(c.imageUrl);
      return true;
    });
    const checks = await Promise.all(fresh.slice(0, 16).map(async (c) => ((await deps.isImage(c.imageUrl).catch(() => false)) ? c : null)));
    for (const c of checks) if (c && out.length < IMAGE_LIMIT) out.push(tidy(c));
  };
  await take(await deps.propose(query).catch(() => []));
  if (out.length < 3 && deps.fallback) await take(await deps.fallback(query).catch(() => []));

  if (cache.size > 500) cache.delete(cache.keys().next().value!);
  cache.set(key, { at: now, results: out });
  return out;
}

function tidy(c: ImageResult): ImageResult {
  return {
    title: String(c.title ?? '').replace(/\s+/g, ' ').trim().slice(0, 140),
    imageUrl: c.imageUrl,
    pageUrl: c.pageUrl && isPublicHttpUrl(c.pageUrl) ? c.pageUrl : null,
    thumbnailUrl: c.thumbnailUrl && isPublicHttpUrl(c.thumbnailUrl) ? c.thumbnailUrl : null,
  };
}

/** http(s) only, and never a loopback / private / link-local host (the server fetches these). */
export function isPublicHttpUrl(u: unknown): u is string {
  if (typeof u !== 'string' || u.length > 2000) return false;
  let url: URL;
  try {
    url = new URL(u);
  } catch {
    return false;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return false;
  const h = url.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (!h.includes('.') || h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h.endsWith('.localhost')) return false;
  if (/^(127\.|10\.|0\.|169\.254\.|192\.168\.)/.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h)) return false;
  if (h.includes(':')) return false; // IPv6 literals
  return true;
}

// ───────────────────────── live providers ─────────────────────────

const IMAGE_FINDER_SYSTEM = `you find real pictures on the web. search for the query and return JSON only:
{"images":[{"title":"short caption","imageUrl":"direct link to the image file (jpg, png, webp, gif)","pageUrl":"the page the image is on"}]}
up to 8 items. only URLs you actually saw in the search results or on those pages; never guess or build a URL. prefer large, clear photos from reputable pages. if you found none, return {"images":[]}.`;

/** The model with OpenRouter's web plugin, asked for image URLs it found. */
export async function proposeWithWebSearch(query: string): Promise<ImageResult[]> {
  if (!llm.apiKey || !llm.isOpenRouter) return [];
  const text = await complete({
    model: process.env.IMAGE_SEARCH_MODEL || llm.models.fast,
    temperature: 0,
    maxTokens: 1200,
    json: true,
    plugins: [{ id: 'web', max_results: 5 }],
    messages: [
      { role: 'system', content: IMAGE_FINDER_SYSTEM },
      { role: 'user', content: `query: ${query}` },
    ],
  });
  return parseImageJson(text);
}

export function parseImageJson(text: string): ImageResult[] {
  const cleaned = text.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '');
  const start = cleaned.search(/[[{]/);
  if (start < 0) return [];
  let v: unknown;
  try {
    v = JSON.parse(cleaned.slice(start, Math.max(cleaned.lastIndexOf('}'), cleaned.lastIndexOf(']')) + 1));
  } catch {
    return [];
  }
  const list = Array.isArray(v) ? v : Array.isArray((v as { images?: unknown[] })?.images) ? (v as { images: unknown[] }).images : [];
  return list
    .map((x) => x as Record<string, unknown>)
    .filter((x) => typeof x?.imageUrl === 'string')
    .map((x) => ({ title: String(x.title ?? ''), imageUrl: String(x.imageUrl), pageUrl: typeof x.pageUrl === 'string' ? x.pageUrl : null }));
}

const UA = 'AwanImageSearch/0.1 (https://awan.ffdev.studio; FF Dev Studio)';

/** Wikimedia Commons file search: real, freely licensed images with a thumbnail and a file page. */
export async function proposeFromCommons(query: string): Promise<ImageResult[]> {
  const u = new URL('https://commons.wikimedia.org/w/api.php');
  u.search = new URLSearchParams({
    action: 'query',
    format: 'json',
    generator: 'search',
    gsrsearch: `${query} filetype:bitmap`,
    gsrnamespace: '6',
    gsrlimit: '10',
    prop: 'imageinfo',
    iiprop: 'url|mime',
    iiurlwidth: '480',
  }).toString();
  const r = await fetch(u, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(6000) });
  if (!r.ok) return [];
  const j = (await r.json()) as { query?: { pages?: Record<string, { title?: string; index?: number; imageinfo?: { url?: string; thumburl?: string; descriptionurl?: string; mime?: string }[] }> } };
  return Object.values(j.query?.pages ?? {})
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .map((p) => ({ p, info: p.imageinfo?.[0] }))
    .filter(({ info }) => info?.mime?.startsWith('image/') && (info.thumburl || info.url))
    .map(({ p, info }) => ({
      title: (p.title ?? '').replace(/^File:/, '').replace(/\.[a-z0-9]+$/i, '').replace(/[_-]+/g, ' '),
      imageUrl: info!.thumburl || info!.url!,
      pageUrl: info!.descriptionurl ?? null,
    }));
}

/** HEAD first; some hosts refuse HEAD, so fall back to a one-byte ranged GET. */
export async function headIsImage(url: string): Promise<boolean> {
  const look = (r: Response) => r.ok && (r.headers.get('content-type') ?? '').toLowerCase().startsWith('image/');
  try {
    const r = await fetch(url, { method: 'HEAD', redirect: 'follow', headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(4000) });
    if (look(r)) return true;
    if (r.status !== 405 && r.status !== 403 && r.status !== 501) return false;
  } catch {
    /* fall through */
  }
  try {
    const r = await fetch(url, { method: 'GET', redirect: 'follow', headers: { 'User-Agent': UA, Range: 'bytes=0-0' }, signal: AbortSignal.timeout(4000) });
    const ok = (r.ok || r.status === 206) && (r.headers.get('content-type') ?? '').toLowerCase().startsWith('image/');
    await r.body?.cancel().catch(() => {});
    return ok;
  } catch {
    return false;
  }
}

export const liveImageDeps: ImageSearchDeps = { propose: proposeWithWebSearch, fallback: proposeFromCommons, isImage: headIsImage };
