/**
 * Composio broker. The reference hands its long tail of app integrations (Slack, Notion, LinkedIn, HubSpot…)
 * to Composio: Composio runs the OAuth, keeps the grants, and serves one MCP endpoint per user session. Awan
 * does the same when COMPOSIO_API_KEY is set, with two rules of its own:
 *
 *  - The Composio project key never leaves this server. Composio's session MCP endpoint wants that key in
 *    `x-api-key`, so the agent runtime talks to `POST /mcp/composio` here (authenticated with the user's own
 *    Awan token, like the first-party Google servers) and this server forwards to the user's session.
 *  - Composio's user id is our users.id, and every Composio call that touches accounts is filtered by it.
 *
 * REST API v3.1 (https://backend.composio.dev/api/v3.1, header x-api-key):
 *   GET  /toolkits                       catalogue (cached 1 h here)
 *   GET  /auth_configs?toolkit_slug=…    find a Composio-managed auth config; POST /auth_configs creates one
 *   POST /connected_accounts/link        hosted connect page → redirect_url (+ our callback_url)
 *   GET  /connected_accounts?user_ids=…  a user's connections; DELETE /connected_accounts/{id} disconnects
 *   POST /tool_router/session            per-user session → mcp.url
 *   GET  /tools/{slug}                   a tool's input schema (cached 10 min here, like the reference's Worker)
 */
import { randomBytes } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { type DB, now, tx } from './db.ts';
import { sha256, type User } from './auth.ts';
import type { FetchLike } from './connectors.ts';

export const COMPOSIO_API_BASE = 'https://backend.composio.dev/api/v3.1';
export const TOOLKITS_TTL_MS = 60 * 60_000;
export const SCHEMA_TTL_MS = 10 * 60_000;
const LINK_STATE_TTL_MS = 15 * 60_000;
/** The meta tool the agent calls to read exact argument schemas before a write. */
export const SCHEMA_META_TOOL = 'COMPOSIO_GET_TOOL_SCHEMAS';

export class ComposioError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export type ComposioToolkit = {
  slug: string;
  name: string;
  description: string;
  logo: string | null;
  categories: string[];
  toolsCount: number;
  authSchemes: string[];
};

export type ComposioConnection = { id: string; toolkit: string; status: string; disabled: boolean; createdAt: string | null; updatedAt: string | null };

const SLUG = /^[a-z0-9][a-z0-9_-]{0,63}$/;
export const isToolkitSlug = (s: unknown): s is string => typeof s === 'string' && SLUG.test(s);

type Cached<T> = { at: number; value: T };

export class ComposioBroker {
  db: DB;
  apiKey: string;
  fetch: FetchLike;
  base: string;
  clock: () => number;
  private toolkits: Cached<ComposioToolkit[]> | null = null;
  private toolkitsLoading: Promise<ComposioToolkit[]> | null = null;
  private schemas = new Map<string, Cached<unknown>>();
  private metaSchemas = new Map<string, Cached<unknown>>();
  private sessionsCreating = new Map<string, Promise<{ sessionId: string; mcpUrl: string; toolkits: string[] }>>();

  constructor(db: DB, apiKey: string, fetchImpl: FetchLike, opts: { base?: string; clock?: () => number } = {}) {
    this.db = db;
    this.apiKey = apiKey;
    this.fetch = fetchImpl;
    this.base = (opts.base ?? COMPOSIO_API_BASE).replace(/\/$/, '');
    this.clock = opts.clock ?? Date.now;
  }

  async call(method: string, path: string, opts: { query?: Record<string, string | number | boolean | undefined>; body?: unknown } = {}): Promise<any> {
    const url = new URL(this.base + path);
    for (const [k, v] of Object.entries(opts.query ?? {})) if (v !== undefined) url.searchParams.set(k, String(v));
    const res = await this.fetch(url, {
      method,
      headers: { 'x-api-key': this.apiKey, Accept: 'application/json', ...(opts.body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
    const text = await res.text();
    let json: any = {};
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { raw: text.slice(0, 200) };
    }
    if (!res.ok) {
      const msg = json?.error?.message ?? json?.message ?? `HTTP ${res.status}`;
      throw new ComposioError(res.status, `Composio: ${String(msg).slice(0, 240)}`);
    }
    return json;
  }

  // ───────────────────────── catalogue ─────────────────────────

  /** Toolkits a user can connect in one click (Composio-managed auth), most used first. Cached for an hour. */
  async listToolkits(): Promise<ComposioToolkit[]> {
    if (this.toolkits && this.clock() - this.toolkits.at < TOOLKITS_TTL_MS) return this.toolkits.value;
    if (this.toolkitsLoading) return this.toolkitsLoading;
    this.toolkitsLoading = (async () => {
      const out: ComposioToolkit[] = [];
      let cursor: string | undefined;
      for (let page = 0; page < 10; page++) {
        const r = await this.call('GET', '/toolkits', { query: { limit: 1000, sort_by: 'usage', managed_by: 'composio', cursor } });
        for (const t of (r.items ?? []) as any[]) {
          const managed = Array.isArray(t.composio_managed_auth_schemes) ? t.composio_managed_auth_schemes : [];
          if (!isToolkitSlug(t.slug) || t.no_auth || !managed.length || t.deprecated?.is_deprecated) continue;
          out.push({
            slug: t.slug,
            name: String(t.name ?? t.slug),
            description: String(t.meta?.description ?? '').trim(),
            logo: typeof t.meta?.logo === 'string' ? t.meta.logo : null,
            categories: (Array.isArray(t.meta?.categories) ? t.meta.categories : []).map((c: any) => String(c?.name ?? c?.id ?? c)).filter(Boolean),
            toolsCount: Number(t.meta?.tools_count ?? 0),
            authSchemes: managed.map(String),
          });
        }
        cursor = r.next_cursor ?? undefined;
        if (!cursor) break;
      }
      this.toolkits = { at: this.clock(), value: out };
      return out;
    })().finally(() => {
      this.toolkitsLoading = null;
    });
    return this.toolkitsLoading;
  }

  // ───────────────────────── auth configs ─────────────────────────

  /** The Composio-managed auth config for a toolkit: ours from the DB, an existing enabled one, or a new one. */
  async authConfigFor(toolkit: string): Promise<string> {
    const row = this.db.prepare('SELECT auth_config_id FROM composio_auth_configs WHERE toolkit = ?').get(toolkit) as { auth_config_id: string } | undefined;
    if (row) return row.auth_config_id;
    const found = await this.call('GET', '/auth_configs', { query: { toolkit_slug: toolkit, is_composio_managed: true, limit: 50 } });
    let id: string | undefined = ((found.items ?? []) as any[]).find(
      (c) => c.is_composio_managed !== false && c.status !== 'DISABLED' && (c.toolkit?.slug ?? toolkit) === toolkit,
    )?.id;
    if (!id) {
      const made = await this.call('POST', '/auth_configs', { body: { toolkit: { slug: toolkit }, auth_config: { type: 'use_composio_managed_auth' } } });
      id = made.auth_config?.id;
    }
    if (!id) throw new ComposioError(502, `Composio: no auth config for ${toolkit}`);
    this.db.prepare('INSERT OR IGNORE INTO composio_auth_configs (toolkit, auth_config_id, created_at) VALUES (?, ?, ?)').run(toolkit, id, now());
    return (this.db.prepare('SELECT auth_config_id FROM composio_auth_configs WHERE toolkit = ?').get(toolkit) as { auth_config_id: string }).auth_config_id;
  }

  // ───────────────────────── connections ─────────────────────────

  /** Starts Composio's hosted connect flow for one toolkit. Returns the page to open and the pending account id. */
  async createLink(userId: string, toolkit: string, callbackUrl: string): Promise<{ redirectUrl: string; connectedAccountId: string | null; expiresAt: string | null }> {
    const authConfigId = await this.authConfigFor(toolkit);
    const r = await this.call('POST', '/connected_accounts/link', { body: { auth_config_id: authConfigId, user_id: userId, callback_url: callbackUrl } });
    if (typeof r.redirect_url !== 'string' || !/^https:\/\//.test(r.redirect_url)) throw new ComposioError(502, 'Composio: no connect page came back');
    return { redirectUrl: r.redirect_url, connectedAccountId: r.connected_account_id ?? null, expiresAt: r.expires_at ?? null };
  }

  /** Every connection this user has (any status). Filtered by user id upstream and again here. */
  async connections(userId: string, toolkit?: string): Promise<ComposioConnection[]> {
    const out: ComposioConnection[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 5; page++) {
      const r = await this.call('GET', '/connected_accounts', { query: { user_ids: userId, toolkit_slugs: toolkit, limit: 200, order_by: 'updated_at', cursor } });
      for (const a of (r.items ?? []) as any[]) {
        if (a.user_id && a.user_id !== userId) continue; // never trust a filter we can't see
        const slug = a.toolkit?.slug;
        if (!isToolkitSlug(slug) || (toolkit && slug !== toolkit)) continue;
        out.push({ id: String(a.id), toolkit: slug, status: String(a.status ?? 'UNKNOWN'), disabled: Boolean(a.is_disabled), createdAt: a.created_at ?? null, updatedAt: a.updated_at ?? null });
      }
      cursor = r.next_cursor ?? undefined;
      if (!cursor) break;
    }
    return out;
  }

  async connectedToolkits(userId: string): Promise<string[]> {
    return [...new Set((await this.connections(userId)).filter(isActive).map((c) => c.toolkit))].sort();
  }

  /** Removes (and revokes upstream) every connection of this user for one toolkit. */
  async disconnect(userId: string, toolkit: string): Promise<number> {
    const mine = await this.connections(userId, toolkit);
    for (const c of mine) await this.call('DELETE', `/connected_accounts/${encodeURIComponent(c.id)}`, { query: { revoke_on_delete: true } });
    this.dropSession(userId);
    return mine.length;
  }

  async disconnectAll(userId: string): Promise<void> {
    for (const c of await this.connections(userId)) await this.call('DELETE', `/connected_accounts/${encodeURIComponent(c.id)}`, { query: { revoke_on_delete: true } });
    this.dropSession(userId);
  }

  // ───────────────────────── sessions ─────────────────────────

  dropSession(userId: string) {
    this.db.prepare('DELETE FROM composio_sessions WHERE user_id = ?').run(userId);
  }

  /**
   * The user's session, scoped to exactly the toolkits they have connected. Connection management is off:
   * agents never start OAuth themselves — connecting happens in Settings → Integrations.
   */
  async session(userId: string, opts: { refresh?: boolean } = {}): Promise<{ sessionId: string; mcpUrl: string; toolkits: string[] }> {
    if (!opts.refresh) {
      const row = this.db.prepare('SELECT session_id, mcp_url, toolkits FROM composio_sessions WHERE user_id = ?').get(userId) as
        | { session_id: string; mcp_url: string; toolkits: string }
        | undefined;
      if (row) return { sessionId: row.session_id, mcpUrl: row.mcp_url, toolkits: row.toolkits ? row.toolkits.split(',') : [] };
    }
    const pending = this.sessionsCreating.get(userId);
    if (pending) return pending;
    const p = (async () => {
      const toolkits = await this.connectedToolkits(userId);
      const authConfigs: Record<string, string> = {};
      for (const t of toolkits) {
        const r = this.db.prepare('SELECT auth_config_id FROM composio_auth_configs WHERE toolkit = ?').get(t) as { auth_config_id: string } | undefined;
        if (r) authConfigs[t] = r.auth_config_id;
      }
      const r = await this.call('POST', '/tool_router/session', {
        body: {
          user_id: userId,
          toolkits: { enable: toolkits },
          ...(Object.keys(authConfigs).length ? { auth_configs: authConfigs } : {}),
          manage_connections: { enable: false },
          // Awans already have a real shell on the Mac; no second sandbox.
          workbench: { enable: false },
        },
      });
      const mcpUrl = r.mcp?.url;
      if (typeof r.session_id !== 'string' || typeof mcpUrl !== 'string' || !/^https:\/\//.test(mcpUrl)) throw new ComposioError(502, 'Composio: the session came back without an MCP URL');
      this.db
        .prepare(
          `INSERT INTO composio_sessions (user_id, session_id, mcp_url, toolkits, created_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET session_id = excluded.session_id, mcp_url = excluded.mcp_url, toolkits = excluded.toolkits, created_at = excluded.created_at`,
        )
        .run(userId, r.session_id, mcpUrl, toolkits.join(','), now());
      return { sessionId: r.session_id as string, mcpUrl: mcpUrl as string, toolkits };
    })().finally(() => this.sessionsCreating.delete(userId));
    this.sessionsCreating.set(userId, p);
    return p;
  }

  // ───────────────────────── tool schemas ─────────────────────────

  /** A tool's exact input schema. Schemas are the same for every user, so one 10-minute cache serves all. */
  async toolSchema(slug: string): Promise<unknown> {
    const hit = this.schemas.get(slug);
    if (hit && this.clock() - hit.at < SCHEMA_TTL_MS) return hit.value;
    const t = await this.call('GET', `/tools/${encodeURIComponent(slug)}`);
    const value = { slug: t.slug ?? slug, name: t.name ?? slug, description: t.description ?? '', toolkit: t.toolkit?.slug ?? null, inputParameters: t.input_parameters ?? {}, outputParameters: t.output_parameters ?? {} };
    this.schemas.set(slug, { at: this.clock(), value });
    return value;
  }

  /** Cache for COMPOSIO_GET_TOOL_SCHEMAS calls made through the MCP proxy (keyed by the exact arguments). */
  metaSchemaHit(key: string): unknown | undefined {
    const hit = this.metaSchemas.get(key);
    return hit && this.clock() - hit.at < SCHEMA_TTL_MS ? hit.value : undefined;
  }
  metaSchemaStore(key: string, result: unknown) {
    this.metaSchemas.set(key, { at: this.clock(), value: result });
    if (this.metaSchemas.size > 500) this.metaSchemas.delete(this.metaSchemas.keys().next().value!);
  }
}

export const isActive = (c: ComposioConnection) => c.status === 'ACTIVE' && !c.disabled;

/** COMPOSIO_API_KEY → a broker, or null (every route then answers 501 composio_not_configured). */
export function composioFromEnv(db: DB, apiKey: string | null | undefined, fetchImpl: FetchLike, opts: { base?: string; clock?: () => number } = {}): ComposioBroker | null {
  const key = apiKey?.trim();
  return key ? new ComposioBroker(db, key, fetchImpl, opts) : null;
}

// ───────────────────────────── routes ─────────────────────────────

export type ComposioRouteContext = {
  db: DB;
  broker: ComposioBroker | null;
  publicUrl: string;
  page: (title: string, body: string, openUrl?: string) => string;
  /** The env var (in the Codex process) that already carries the user's Awan token. */
  tokenEnvVar: string;
};

const NOT_CONFIGURED = { error: 'composio_not_configured', message: 'Composio isn’t set up on this Awan server yet (COMPOSIO_API_KEY is missing).' };

function safeRedirect(raw: unknown): string {
  const s = typeof raw === 'string' ? raw : '';
  return /^(awan:\/\/|https?:\/\/)/.test(s) ? s : 'awan://connectors';
}

function withQuery(target: string, params: Record<string, string>): string {
  return `${target}${target.includes('?') ? '&' : '?'}${new URLSearchParams(params).toString()}`;
}

/** Pulls the JSON-RPC message with `id` out of a Streamable-HTTP reply (plain JSON or an SSE stream). */
export function jsonRpcFromBody(text: string, contentType: string, id: unknown): any | null {
  const pick = (m: any) => (Array.isArray(m) ? m.find((x) => x?.id === id) : m?.id === id ? m : null);
  if (contentType.includes('event-stream')) {
    for (const block of text.split(/\r?\n\r?\n/)) {
      const data = block
        .split(/\r?\n/)
        .filter((l) => l.startsWith('data:'))
        .map((l) => l.slice(5).trimStart())
        .join('\n');
      if (!data) continue;
      try {
        const hit = pick(JSON.parse(data));
        if (hit) return hit;
      } catch {
        /* not JSON: skip */
      }
    }
    return null;
  }
  try {
    return pick(JSON.parse(text));
  } catch {
    return null;
  }
}

export function registerComposioRoutes(app: FastifyInstance, ctx: ComposioRouteContext) {
  const { db, broker, publicUrl, page } = ctx;
  const me = (req: FastifyRequest) => req.user as User;
  const fail = (err: unknown) => {
    const e = err as ComposioError;
    return { code: e instanceof ComposioError ? (e.status === 404 ? 404 : 502) : 500, body: { error: 'composio_error', message: (e as Error).message } };
  };

  app.get('/v1/composio/toolkits', async (_req, reply) => {
    if (!broker) return reply.code(501).send(NOT_CONFIGURED);
    try {
      const toolkits = await broker.listToolkits();
      return { toolkits, total: toolkits.length };
    } catch (err) {
      const f = fail(err);
      return reply.code(f.code).send(f.body);
    }
  });

  /** App entry: `{toolkit}` → Composio's hosted connect page. The browser comes back through /v1/composio/callback. */
  app.post('/v1/composio/connect', async (req, reply) => {
    if (!broker) return reply.code(501).send(NOT_CONFIGURED);
    const body = (req.body ?? {}) as { toolkit?: unknown; redirect?: unknown };
    const toolkit = typeof body.toolkit === 'string' ? body.toolkit.trim().toLowerCase() : '';
    if (!isToolkitSlug(toolkit)) return reply.code(400).send({ error: 'unknown_toolkit' });
    try {
      if (!(await broker.listToolkits()).some((t) => t.slug === toolkit)) return reply.code(400).send({ error: 'unknown_toolkit' });
      const state = randomBytes(24).toString('base64url');
      const at = new Date(broker.clock());
      const expires = new Date(at.getTime() + LINK_STATE_TTL_MS);
      const link = await broker.createLink(me(req).id, toolkit, `${publicUrl}/v1/composio/callback?state=${state}`);
      db.prepare(
        'INSERT INTO composio_link_states (state_hash, user_id, toolkit, connected_account_id, redirect, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      ).run(sha256(state), me(req).id, toolkit, link.connectedAccountId, safeRedirect(body.redirect), now(at), now(expires));
      return { redirectUrl: link.redirectUrl, toolkit, expiresAt: link.expiresAt ?? now(expires) };
    } catch (err) {
      const f = fail(err);
      return reply.code(f.code).send(f.body);
    }
  });

  /** Browser leg: Composio → here → awan://connectors?connected=<toolkit>&source=composio (or ?error=…). */
  app.get('/v1/composio/callback', async (req, reply) => {
    const q = req.query as { state?: string; status?: string; error?: string; connected_account_id?: string };
    if (!broker) return reply.code(501).type('text/html').send(page('Integrations aren’t set up', NOT_CONFIGURED.message));
    const row = q.state
      ? tx(db, () => {
          const r = db.prepare('SELECT * FROM composio_link_states WHERE state_hash = ?').get(sha256(q.state!)) as
            | { user_id: string; toolkit: string; connected_account_id: string | null; redirect: string; expires_at: string; used_at: string | null }
            | undefined;
          if (!r || r.used_at || new Date(r.expires_at).getTime() < broker.clock()) return null;
          db.prepare('UPDATE composio_link_states SET used_at = ? WHERE state_hash = ?').run(now(), sha256(q.state!));
          return r;
        })
      : null;
    if (!row) return reply.code(400).type('text/html').send(page('That link has expired', 'Go back to Awan and press Connect again.'));
    const back = (params: Record<string, string>, title: string, body: string) =>
      reply.type('text/html').send(page(title, body, withQuery(row.redirect, { source: 'composio', ...params })));
    const failed = q.error || (q.status && !['success', 'active', 'ok'].includes(q.status.toLowerCase()));
    if (failed) return back({ error: q.error || q.status || 'failed', toolkit: row.toolkit }, 'Nothing was connected', 'The app didn’t finish connecting. You can try again from Awan.');
    // Trust Composio's own record, not the query string.
    let active = false;
    try {
      active = (await broker.connections(row.user_id, row.toolkit)).some(isActive);
    } catch (err) {
      req.log.warn({ err }, 'composio: connection check failed');
    }
    if (!active) return back({ error: 'not_active', toolkit: row.toolkit }, 'Still connecting', 'Composio hasn’t confirmed the connection yet. Give it a moment, then check Awan → Settings → Integrations.');
    broker.dropSession(row.user_id); // the next session includes the new toolkit
    return back({ connected: row.toolkit }, 'Connected', 'Awan is opening now. Your Awans can use it on their next task.');
  });

  app.get('/v1/composio/connections', async (req, reply) => {
    if (!broker) return reply.code(501).send(NOT_CONFIGURED);
    try {
      const connections = await broker.connections(me(req).id);
      const toolkits: Record<string, { connected: boolean; status: string }> = {};
      for (const c of connections) {
        const prev = toolkits[c.toolkit];
        if (!prev || (!prev.connected && isActive(c))) toolkits[c.toolkit] = { connected: isActive(c), status: c.status };
      }
      return { connections, toolkits };
    } catch (err) {
      const f = fail(err);
      return reply.code(f.code).send(f.body);
    }
  });

  app.post('/v1/composio/disconnect', async (req, reply) => {
    if (!broker) return reply.code(501).send(NOT_CONFIGURED);
    const toolkit = String((req.body as { toolkit?: unknown } | undefined)?.toolkit ?? '').trim().toLowerCase();
    if (!isToolkitSlug(toolkit)) return reply.code(400).send({ error: 'unknown_toolkit' });
    try {
      const removed = await broker.disconnect(me(req).id, toolkit);
      return { disconnected: true, toolkit, removed };
    } catch (err) {
      const f = fail(err);
      return reply.code(f.code).send(f.body);
    }
  });

  /**
   * What the app writes as `[mcp_servers.composio]`: Awan's proxy URL and the env var that already holds the
   * user's Awan token. No Composio secret is ever returned.
   */
  app.post('/v1/composio/session', async (req, reply) => {
    if (!broker) return reply.code(501).send(NOT_CONFIGURED);
    try {
      const s = await broker.session(me(req).id, { refresh: Boolean((req.body as { refresh?: unknown } | undefined)?.refresh) });
      return { mcpUrl: `${publicUrl}/mcp/composio`, bearerTokenEnvVar: ctx.tokenEnvVar, headers: {}, toolkits: s.toolkits, sessionId: s.sessionId };
    } catch (err) {
      const f = fail(err);
      return reply.code(f.code).send(f.body);
    }
  });

  app.get('/v1/composio/tools/:slug/schema', async (req, reply) => {
    if (!broker) return reply.code(501).send(NOT_CONFIGURED);
    const { slug } = req.params as { slug: string };
    if (!/^[A-Z0-9_]{2,120}$/.test(slug)) return reply.code(400).send({ error: 'bad_tool_slug' });
    try {
      return { tool: await broker.toolSchema(slug) };
    } catch (err) {
      const f = fail(err);
      return reply.code(f.code).send(f.body);
    }
  });

  // ───────── MCP proxy: the agent runtime → the user's Composio session ─────────
  const FORWARD = ['content-type', 'accept', 'mcp-session-id', 'mcp-protocol-version', 'last-event-id'];
  app.route({
    method: ['GET', 'POST', 'DELETE'],
    url: '/mcp/composio',
    handler: async (req, reply) => {
      if (!broker) return reply.code(501).send({ jsonrpc: '2.0', id: null, error: { code: -32601, message: NOT_CONFIGURED.message } });
      const user = me(req);
      const raw = req.method === 'POST' ? ((req as FastifyRequest & { rawBody?: string }).rawBody ?? JSON.stringify(req.body ?? {})) : undefined;
      const msg = raw ? (() => { try { return JSON.parse(raw); } catch { return null; } })() : null;
      // COMPOSIO_GET_TOOL_SCHEMAS: served from a 10-minute cache when the same schemas were asked for recently.
      const schemaCall = msg && !Array.isArray(msg) && msg.method === 'tools/call' && msg.params?.name === SCHEMA_META_TOOL;
      const schemaKey = schemaCall ? JSON.stringify(msg.params?.arguments ?? {}) : '';
      if (schemaCall) {
        const hit = broker.metaSchemaHit(schemaKey);
        if (hit !== undefined) return reply.code(200).type('application/json').send({ jsonrpc: '2.0', id: msg.id, result: hit });
      }
      const headers: Record<string, string> = { 'x-api-key': broker.apiKey };
      for (const h of FORWARD) {
        const v = req.headers[h];
        if (typeof v === 'string') headers[h] = v;
      }
      if (req.method === 'POST') {
        headers['content-type'] ??= 'application/json';
        headers.accept ??= 'application/json, text/event-stream';
      }
      let upstream: Response | null = null;
      for (let attempt = 0; attempt < 2; attempt++) {
        let session;
        try {
          session = await broker.session(user.id, { refresh: attempt > 0 });
        } catch (err) {
          return reply.code(502).send({ jsonrpc: '2.0', id: msg?.id ?? null, error: { code: -32603, message: (err as Error).message } });
        }
        upstream = await broker.fetch(session.mcpUrl, { method: req.method, headers, body: raw });
        // A session Composio no longer knows: make a fresh one once (only before an MCP session id exists).
        if ((upstream.status === 404 || upstream.status === 410) && !headers['mcp-session-id'] && attempt === 0) continue;
        break;
      }
      const ct = upstream!.headers.get('content-type') ?? 'application/json';
      if (schemaCall) {
        const text = await upstream!.text();
        const rpc = jsonRpcFromBody(text, ct, msg.id);
        if (upstream!.ok && rpc?.result && !rpc.result.isError) broker.metaSchemaStore(schemaKey, rpc.result);
        const sid = upstream!.headers.get('mcp-session-id');
        if (sid) reply.header('mcp-session-id', sid);
        return reply.code(upstream!.status).type(ct).send(text);
      }
      reply.hijack();
      const out: Record<string, string> = { 'Content-Type': ct };
      const sid = upstream!.headers.get('mcp-session-id');
      if (sid) out['Mcp-Session-Id'] = sid;
      if (ct.includes('event-stream')) out['Cache-Control'] = 'no-cache';
      reply.raw.writeHead(upstream!.status, out);
      if (upstream!.body) for await (const chunk of upstream!.body as unknown as AsyncIterable<Uint8Array>) reply.raw.write(chunk);
      reply.raw.end();
    },
  });
}
