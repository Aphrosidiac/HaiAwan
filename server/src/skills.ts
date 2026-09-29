import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { type DB, now, tx } from './db.ts';
import { CATEGORIES, OFFICIAL_SKILLS, type Category } from './skills-seed.ts';
import { completeJson, config as llm } from './llm.ts';
import { teamOf } from './teams.ts';
import type { User } from './auth.ts';

/** The reference keeps three skill slots; the fourth activation must swap one out. */
export const MAX_ACTIVE_SKILLS = 3;
/** Total size of the `<active_skills>` block added to a companion turn. */
export const ACTIVE_SKILLS_MAX_CHARS = 6000;
export const SKILL_CONTENT_MAX = 60_000;
/** Skill creations per user per rolling day (each one is a frontier-model call). */
export const SKILL_CREATIONS_PER_DAY = 10;

export type SkillRow = {
  slug: string;
  title: string;
  one_liner: string;
  whats_inside: string;
  content: string;
  category: Category;
  symbol: string;
  color: string;
  author_name: string;
  is_official: number;
  origin: 'library' | 'created' | 'imported';
  created_by: string | null;
  team_id: string | null;
  published: number;
  users_count: number;
  created_at: string;
  updated_at: string;
  active_users_count?: number;
};

export type SkillDraft = { title: string; oneLiner: string; whatsInside: string[]; category: Category; content: string; symbol?: string };

export class SlotsFull extends Error {
  active: string[];
  constructor(active: string[]) {
    super('slots_full');
    this.active = active;
  }
}

const httpError = (status: number, message: string) => Object.assign(new Error(message), { statusCode: status });

// ───────────────────────────── seed ─────────────────────────────

/** Upserts FF's official skills (content changes ship with the server; usage counts are kept). */
export function seedOfficialSkills(db: DB) {
  const at = now();
  const up = db.prepare(
    `INSERT INTO skills (slug, title, one_liner, whats_inside, content, category, symbol, color, author_name, is_official, origin, published, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'FF Dev Studio', 1, 'library', 1, ?, ?)
     ON CONFLICT(slug) DO UPDATE SET title = excluded.title, one_liner = excluded.one_liner, whats_inside = excluded.whats_inside,
       content = excluded.content, category = excluded.category, symbol = excluded.symbol, color = excluded.color, updated_at = excluded.updated_at
     WHERE skills.is_official = 1`,
  );
  tx(db, () => {
    for (const s of OFFICIAL_SKILLS) {
      const cat = CATEGORIES[s.category];
      up.run(s.slug, s.title, s.oneLiner, JSON.stringify(s.whatsInside), s.content, s.category, s.symbol ?? cat.symbol, cat.color, at, at);
    }
  });
}

// ───────────────────────────── queries ─────────────────────────────

const VISIBLE = `(s.is_official = 1 OR s.published = 1 OR s.created_by = ? OR (s.team_id IS NOT NULL AND s.team_id = ?))`;
const ACTIVE_COUNT = `(SELECT COUNT(*) FROM skill_activations a WHERE a.slug = s.slug) AS active_users_count`;

export function visibleSkill(db: DB, userId: string, slug: string): SkillRow | undefined {
  const team = teamOf(db, userId)?.id ?? null;
  return db.prepare(`SELECT s.*, ${ACTIVE_COUNT} FROM skills s WHERE s.slug = ? AND ${VISIBLE}`).get(slug, userId, team) as SkillRow | undefined;
}

export function activeSlugs(db: DB, userId: string): string[] {
  return (db.prepare('SELECT slug FROM skill_activations WHERE user_id = ? ORDER BY activated_at, rowid').all(userId) as { slug: string }[]).map((r) => r.slug);
}

/** The user's active skills that they can still see (a skill unshared from their team drops out). */
export function activeSkills(db: DB, userId: string): SkillRow[] {
  return activeSlugs(db, userId)
    .map((slug) => visibleSkill(db, userId, slug))
    .filter((s): s is SkillRow => Boolean(s));
}

export function shapeSkill(row: SkillRow, viewer: { userId: string; active: Set<string> }, withContent = false) {
  let inside: string[] = [];
  try {
    inside = JSON.parse(row.whats_inside);
  } catch {}
  return {
    slug: row.slug,
    title: row.title,
    oneLiner: row.one_liner,
    whatsInside: inside,
    category: row.category,
    categoryName: CATEGORIES[row.category]?.name ?? row.category,
    symbol: row.symbol,
    color: row.color,
    author: row.author_name,
    isOfficial: row.is_official === 1,
    isMine: row.created_by === viewer.userId,
    teamShared: row.team_id !== null,
    published: row.published === 1 || row.is_official === 1,
    origin: row.origin,
    usersCount: row.users_count,
    activeUsersCount: row.active_users_count ?? 0,
    active: viewer.active.has(row.slug),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(withContent ? { content: row.content } : {}),
  };
}

// ───────────────────────────── activation ─────────────────────────────

function recordAdopter(db: DB, userId: string, slug: string) {
  const r = db.prepare('INSERT OR IGNORE INTO skill_users (user_id, slug, first_at) VALUES (?, ?, ?)').run(userId, slug, now());
  if (Number(r.changes) > 0) db.prepare('UPDATE skills SET users_count = users_count + 1 WHERE slug = ?').run(slug);
}

/**
 * Switch a skill on. The count-then-insert runs inside BEGIN IMMEDIATE, so racing requests can never
 * leave more than three active. `replace` swaps an active skill out in the same transaction.
 */
export function activateSkill(db: DB, userId: string, slug: string, replace?: string | null): string[] {
  return tx(db, () => {
    if (!visibleSkill(db, userId, slug)) throw httpError(404, 'skill_not_found');
    const active = activeSlugs(db, userId);
    if (active.includes(slug)) return active;
    if (replace) {
      if (!active.includes(replace)) throw httpError(400, 'replace_not_active');
      db.prepare('DELETE FROM skill_activations WHERE user_id = ? AND slug = ?').run(userId, replace);
    } else if (active.length >= MAX_ACTIVE_SKILLS) {
      throw new SlotsFull(active);
    }
    db.prepare('INSERT INTO skill_activations (user_id, slug, activated_at) VALUES (?, ?, ?)').run(userId, slug, now());
    recordAdopter(db, userId, slug);
    return activeSlugs(db, userId);
  });
}

export function deactivateSkill(db: DB, userId: string, slug: string): string[] {
  db.prepare('DELETE FROM skill_activations WHERE user_id = ? AND slug = ?').run(userId, slug);
  return activeSlugs(db, userId);
}

/** Replace the whole active set (onboarding picks, the reference's `activations/sync`). */
export function syncActivations(db: DB, userId: string, slugs: string[]): string[] {
  const wanted = [...new Set(slugs.map(String))];
  if (wanted.length > MAX_ACTIVE_SKILLS) throw httpError(400, 'too_many_skills');
  return tx(db, () => {
    for (const s of wanted) if (!visibleSkill(db, userId, s)) throw httpError(404, `skill_not_found:${s}`);
    const before = activeSlugs(db, userId);
    for (const s of before) if (!wanted.includes(s)) db.prepare('DELETE FROM skill_activations WHERE user_id = ? AND slug = ?').run(userId, s);
    for (const s of wanted) {
      if (before.includes(s)) continue;
      db.prepare('INSERT INTO skill_activations (user_id, slug, activated_at) VALUES (?, ?, ?)').run(userId, s, now());
      recordAdopter(db, userId, s);
    }
    return activeSlugs(db, userId);
  });
}

// ───────────────────────────── prompt block ─────────────────────────────

/**
 * The `<active_skills>` block added to the companion's user turn. The whole block stays within
 * ACTIVE_SKILLS_MAX_CHARS: each skill gets an even share and long bodies are cut with an ellipsis.
 */
export function activeSkillsBlock(skills: { title: string; slug: string; content: string }[], max = ACTIVE_SKILLS_MAX_CHARS): string | null {
  const list = skills.slice(0, MAX_ACTIVE_SKILLS);
  if (!list.length) return null;
  const head =
    '<active_skills>\nThe user switched these skills on. When a request fits one, follow it (including its "How to help" moves: point, type, or hand work to an Awan). When it does not fit, let it fade into the background.\n';
  const tail = '</active_skills>';
  const wrap = (s: { title: string; slug: string }, body: string) => `<skill name="${s.title.replace(/"/g, "'")}" slug="${s.slug}">\n${body}\n</skill>\n`;
  const overhead = list.reduce((n, s) => n + wrap(s, '').length, head.length + tail.length);
  const share = Math.max(0, Math.floor((max - overhead) / list.length));
  const body = list
    .map((s) => {
      const text = s.content.trim();
      return wrap(s, text.length > share ? text.slice(0, Math.max(0, share - 1)).trimEnd() + '…' : text);
    })
    .join('');
  return (head + body + tail).slice(0, max);
}

// ───────────────────────────── authoring ─────────────────────────────

export const SKILL_WRITER_SYSTEM = `You write skills for Awan, a Mac companion that sees the user's screen, talks, points at things on screen, types into the focused field, and hands bigger jobs to background agents called Awans.

A skill is a short playbook that shapes how Awan helps with one kind of task. From the user's brain dump, write ONE skill.

Return JSON only:
{
  "title": "2 to 3 word name, Title Case, no emoji",
  "oneLiner": "one sentence under 110 characters saying what it does for the user",
  "whatsInside": ["4 to 6 bullets, each under 45 characters"],
  "category": "one of: writing, research, design, dev, marketing, productivity, learning, fun",
  "content": "the SKILL.md body in markdown"
}

The content must:
- open with one or two sentences in the second person saying who Awan should be ("You are…"),
- have a "## When to apply" section (when to use it, and one line on when not to),
- have one or two sections of concrete rules or method (short bullets, real numbers where useful),
- end with a "## How to help" section: answer briefly out loud, point at the relevant thing on screen, type rewrites into the focused field, and hand long or multi-step work to an Awan with a named deliverable.
- stay under 2,500 characters. No front matter. Never invent facts about the user.`;

export function validateSkillDraft(v: unknown): SkillDraft {
  const o = (v ?? {}) as Record<string, unknown>;
  const title = String(o.title ?? '').trim().slice(0, 40);
  const oneLiner = String(o.oneLiner ?? o.one_liner ?? '').trim().slice(0, 160);
  const content = String(o.content ?? '').trim().slice(0, SKILL_CONTENT_MAX);
  const category = String(o.category ?? '').trim().toLowerCase() as Category;
  const whatsInside = (Array.isArray(o.whatsInside) ? o.whatsInside : Array.isArray(o.whats_inside) ? o.whats_inside : [])
    .map((x) => String(x).trim())
    .filter(Boolean)
    .slice(0, 7);
  if (!title) throw new Error('skill needs a title');
  if (!oneLiner) throw new Error('skill needs a one-liner');
  if (content.length < 40) throw new Error('skill content too short');
  return { title, oneLiner, whatsInside, category: category in CATEGORIES ? category : 'productivity', content };
}

/** Parses an imported SKILL.md: front matter with `name` and `description` is required. */
export function parseSkillMarkdown(md: string): { name: string; description: string; category?: string; body: string } {
  const text = md.replace(/^﻿/, '').replace(/\r\n/g, '\n');
  if (!text.startsWith('---\n')) throw httpError(400, 'missing_front_matter');
  const end = text.indexOf('\n---', 4);
  if (end < 0) throw httpError(400, 'missing_front_matter');
  const fm: Record<string, string> = {};
  for (const line of text.slice(4, end).split('\n')) {
    const i = line.indexOf(':');
    if (i < 0) continue;
    let value = line.slice(i + 1).trim();
    if (value.length >= 2 && /^["'].*["']$/.test(value)) value = value.slice(1, -1);
    fm[line.slice(0, i).trim().toLowerCase()] = value;
  }
  const body = text.slice(end + 4).replace(/^-*\n/, '').trim();
  if (!fm.name) throw httpError(400, 'front_matter_needs_name');
  if (!fm.description) throw httpError(400, 'front_matter_needs_description');
  if (!body) throw httpError(400, 'empty_skill');
  return { name: fm.name, description: fm.description, category: fm.category, body };
}

export function slugify(s: string): string {
  return (
    s
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[^\p{L}\p{N}]+/gu, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 40) || 'skill'
  );
}

function uniqueSkillSlug(db: DB, base: string): string {
  let slug = slugify(base);
  for (let i = 2; db.prepare('SELECT 1 FROM skills WHERE slug = ?').get(slug); i++) slug = `${slugify(base).slice(0, 36)}-${i}`;
  return slug;
}

export function insertUserSkill(db: DB, user: User, d: SkillDraft, origin: 'created' | 'imported'): SkillRow {
  const cat = CATEGORIES[d.category] ?? CATEGORIES.productivity;
  const slug = uniqueSkillSlug(db, d.title);
  const at = now();
  db.prepare(
    `INSERT INTO skills (slug, title, one_liner, whats_inside, content, category, symbol, color, author_name, is_official, origin, created_by, published, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 0, ?, ?)`,
  ).run(slug, d.title, d.oneLiner, JSON.stringify(d.whatsInside), d.content, d.category, d.symbol ?? cat.symbol, cat.color, user.display_name || 'You', origin, user.id, at, at);
  return visibleSkill(db, user.id, slug)!;
}

// ───────────────────────────── routes ─────────────────────────────

export type SkillRouteOptions = {
  /** Override the skill-writing model call (tests). */
  skillWriter?: (brainDump: string) => Promise<SkillDraft>;
};

export function registerSkillRoutes(app: FastifyInstance, db: DB, opts: SkillRouteOptions = {}) {
  const me = (req: FastifyRequest) => req.user as User;
  const viewer = (userId: string) => ({ userId, active: new Set(activeSlugs(db, userId)) });

  /** Loads a skill the caller owns: 404 when they can't see it, 403 when it isn't theirs. */
  const owned = (req: FastifyRequest, reply: FastifyReply): SkillRow | null => {
    const { slug } = req.params as { slug: string };
    const row = visibleSkill(db, me(req).id, slug);
    if (!row) {
      reply.code(404).send({ error: 'skill_not_found' });
      return null;
    }
    if (row.created_by !== me(req).id) {
      reply.code(403).send({ error: 'not_your_skill' });
      return null;
    }
    return row;
  };

  app.get('/v1/skills/library', async (req) => {
    const u = me(req);
    const q = req.query as { filter?: string; q?: string; category?: string };
    const team = teamOf(db, u.id);
    const where: string[] = [];
    const args: (string | null)[] = [];
    switch (q.filter) {
      case 'team':
        where.push('s.team_id IS NOT NULL AND s.team_id = ?');
        args.push(team?.id ?? '__none__');
        break;
      case 'mine':
        where.push('s.created_by = ?');
        args.push(u.id);
        break;
      default:
        where.push(VISIBLE);
        args.push(u.id, team?.id ?? null);
    }
    if (q.category && q.category in CATEGORIES) {
      where.push('s.category = ?');
      args.push(q.category);
    }
    const term = (q.q ?? '').trim().toLowerCase();
    if (term) {
      where.push("(lower(s.title) LIKE ? ESCAPE '\\' OR lower(s.one_liner) LIKE ? ESCAPE '\\' OR s.category LIKE ? ESCAPE '\\' OR lower(s.author_name) LIKE ? ESCAPE '\\')");
      const like = `%${term.replace(/[\\%_]/g, (c) => '\\' + c)}%`;
      args.push(like, like, like, like);
    }
    const rows = db
      .prepare(`SELECT s.*, ${ACTIVE_COUNT} FROM skills s WHERE ${where.join(' AND ')} ORDER BY s.is_official DESC, s.users_count DESC, s.title COLLATE NOCASE`)
      .all(...args) as SkillRow[];
    const v = viewer(u.id);
    return {
      skills: rows.map((r) => shapeSkill(r, v)),
      activeSlugs: [...v.active],
      maxActive: MAX_ACTIVE_SKILLS,
      categories: Object.entries(CATEGORIES).map(([id, c]) => ({ id, ...c })),
      team: team ? { id: team.id, name: team.name } : null,
    };
  });

  app.get('/v1/skills/active', async (req) => {
    const u = me(req);
    const v = viewer(u.id);
    return { skills: activeSkills(db, u.id).map((r) => shapeSkill(r, v, true)), maxActive: MAX_ACTIVE_SKILLS };
  });

  const activation = (slugs: string[]) => ({ activeSlugs: slugs, maxActive: MAX_ACTIVE_SKILLS });

  app.post('/v1/skills/activate', async (req, reply) => {
    const { slug, replace } = (req.body ?? {}) as { slug?: string; replace?: string };
    if (!slug) return reply.code(400).send({ error: 'slug_required' });
    try {
      return activation(activateSkill(db, me(req).id, slug, replace));
    } catch (err) {
      if (err instanceof SlotsFull) return reply.code(409).send({ error: 'slots_full', activeSlugs: err.active, maxActive: MAX_ACTIVE_SKILLS });
      throw err;
    }
  });

  app.post('/v1/skills/deactivate', async (req, reply) => {
    const { slug } = (req.body ?? {}) as { slug?: string };
    if (!slug) return reply.code(400).send({ error: 'slug_required' });
    return activation(deactivateSkill(db, me(req).id, slug));
  });

  app.post('/v1/skills/activations/sync', async (req, reply) => {
    const { activeSlugs: slugs } = (req.body ?? {}) as { activeSlugs?: unknown };
    if (!Array.isArray(slugs)) return reply.code(400).send({ error: 'active_slugs_required' });
    return activation(syncActivations(db, me(req).id, slugs.map(String)));
  });

  /** Brain dump → a finished skill (one frontier-model call). The result is private until published. */
  app.post('/v1/skills/create', async (req, reply) => {
    const u = me(req);
    const brainDump = String((req.body as { brainDump?: unknown })?.brainDump ?? '').trim();
    if (brainDump.length < 12) return reply.code(400).send({ error: 'brain_dump_too_short' });
    if (brainDump.length > 20_000) return reply.code(400).send({ error: 'brain_dump_too_long' });
    const recent = db
      .prepare("SELECT COUNT(*) AS n FROM skills WHERE created_by = ? AND origin = 'created' AND created_at > ?")
      .get(u.id, now(new Date(Date.now() - 86_400_000))) as { n: number };
    if (recent.n >= SKILL_CREATIONS_PER_DAY) return reply.code(429).send({ error: 'too_many_creations', perDay: SKILL_CREATIONS_PER_DAY });
    const draft = opts.skillWriter
      ? validateSkillDraft(await opts.skillWriter(brainDump))
      : await completeJson(
          {
            model: llm.models.companion,
            maxTokens: 3000,
            temperature: 0.6,
            messages: [
              { role: 'system', content: SKILL_WRITER_SYSTEM },
              { role: 'user', content: `Brain dump from ${u.display_name || 'the user'}:\n\n${brainDump}` },
            ],
          },
          validateSkillDraft,
        );
    const row = insertUserSkill(db, u, draft, 'created');
    return { skill: shapeSkill(row, viewer(u.id), true) };
  });

  /** Import a SKILL.md (front matter with name + description). */
  app.post('/v1/skills/import', async (req, reply) => {
    const u = me(req);
    const markdown = String((req.body as { markdown?: unknown })?.markdown ?? '');
    if (!markdown.trim()) return reply.code(400).send({ error: 'empty_skill' });
    if (markdown.length > SKILL_CONTENT_MAX) return reply.code(413).send({ error: 'skill_too_large', max: SKILL_CONTENT_MAX });
    const parsed = parseSkillMarkdown(markdown);
    const headings = [...parsed.body.matchAll(/^##\s+(.+)$/gm)].map((m) => m[1].trim()).slice(0, 6);
    const category = (parsed.category?.toLowerCase() ?? '') as Category;
    const row = insertUserSkill(
      db,
      u,
      {
        title: parsed.name.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()).slice(0, 40),
        oneLiner: parsed.description.slice(0, 160),
        whatsInside: headings,
        category: category in CATEGORIES ? category : 'productivity',
        content: parsed.body,
      },
      'imported',
    );
    return { skill: shapeSkill(row, viewer(u.id), true) };
  });

  app.get('/v1/skills/:slug', async (req, reply) => {
    const u = me(req);
    const row = visibleSkill(db, u.id, (req.params as { slug: string }).slug);
    if (!row) return reply.code(404).send({ error: 'skill_not_found' });
    return { skill: shapeSkill(row, viewer(u.id), true) };
  });

  app.patch('/v1/skills/:slug', async (req, reply) => {
    const row = owned(req, reply);
    if (!row) return;
    const b = (req.body ?? {}) as Partial<{ title: string; oneLiner: string; whatsInside: string[]; content: string; category: string; symbol: string; color: string }>;
    const next = {
      title: b.title !== undefined ? String(b.title).trim().slice(0, 40) : row.title,
      one_liner: b.oneLiner !== undefined ? String(b.oneLiner).trim().slice(0, 160) : row.one_liner,
      whats_inside: b.whatsInside !== undefined ? JSON.stringify((Array.isArray(b.whatsInside) ? b.whatsInside : []).map(String).slice(0, 7)) : row.whats_inside,
      content: b.content !== undefined ? String(b.content).trim() : row.content,
      category: b.category !== undefined ? String(b.category) : row.category,
      symbol: b.symbol !== undefined ? String(b.symbol).slice(0, 60) : row.symbol,
      color: b.color !== undefined ? String(b.color) : row.color,
    };
    if (!next.title || !next.one_liner) return reply.code(400).send({ error: 'title_and_one_liner_required' });
    if (!next.content || next.content.length > SKILL_CONTENT_MAX) return reply.code(400).send({ error: 'bad_content' });
    if (!(next.category in CATEGORIES)) return reply.code(400).send({ error: 'bad_category' });
    if (!/^#[0-9a-fA-F]{6}$/.test(next.color)) return reply.code(400).send({ error: 'bad_color' });
    db.prepare(
      'UPDATE skills SET title = ?, one_liner = ?, whats_inside = ?, content = ?, category = ?, symbol = ?, color = ?, updated_at = ? WHERE slug = ? AND created_by = ?',
    ).run(next.title, next.one_liner, next.whats_inside, next.content, next.category, next.symbol, next.color, now(), row.slug, me(req).id);
    return { skill: shapeSkill(visibleSkill(db, me(req).id, row.slug)!, viewer(me(req).id), true) };
  });

  app.delete('/v1/skills/:slug', async (req, reply) => {
    const row = owned(req, reply);
    if (!row) return;
    db.prepare('DELETE FROM skills WHERE slug = ? AND created_by = ?').run(row.slug, me(req).id);
    return { deleted: true };
  });

  const lifecycle = (path: string, set: (row: SkillRow, u: User, reply: FastifyReply) => [string, unknown] | null) =>
    app.post(`/v1/skills/:slug/${path}`, async (req, reply) => {
      const row = owned(req, reply);
      if (!row) return;
      const change = set(row, me(req), reply);
      if (!change) return;
      db.prepare(`UPDATE skills SET ${change[0]} = ?, updated_at = ? WHERE slug = ?`).run(change[1] as string | number | null, now(), row.slug);
      return { skill: shapeSkill(visibleSkill(db, me(req).id, row.slug)!, viewer(me(req).id), true) };
    });

  lifecycle('publish', () => ['published', 1]);
  lifecycle('unpublish', () => ['published', 0]);
  lifecycle('share-to-team', (_row, u, reply) => {
    const team = teamOf(db, u.id);
    if (!team) {
      reply.code(409).send({ error: 'not_in_a_team' });
      return null;
    }
    return ['team_id', team.id];
  });
  lifecycle('unshare-from-team', () => ['team_id', null]);
}
