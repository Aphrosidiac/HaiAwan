/**
 * First-party connectors. The reference brokers Google Workspace through Composio's hosted OAuth; Awan
 * does it itself: the user grants Google access once (incremental scopes, offline), the server keeps the
 * tokens encrypted at rest, and hosts one MCP server per toolkit at POST /mcp/:toolkit. The agent runtime
 * reaches those with the user's own Awan token (`bearer_token_env_var = "AWAN_AGENT_TOKEN"`), so no new
 * secret ever lands on the Mac.
 */
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { type DB, now, tx } from './db.ts';
import { bearer, sha256, userForToken, type User } from './auth.ts';
import { handleMcpMessage } from './mcp.ts';
import { GOOGLE_MCP_SERVERS } from './google-tools.ts';

export type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

// ───────────────────────────── toolkits ─────────────────────────────

export type GoogleToolkitId = 'gmail' | 'google-calendar' | 'google-drive' | 'google-docs' | 'google-sheets';

const G = 'https://www.googleapis.com/auth/';
export const GOOGLE_TOOLKITS: Record<GoogleToolkitId, { name: string; scopes: string[] }> = {
  gmail: { name: 'Gmail', scopes: [`${G}gmail.modify`] },
  'google-calendar': { name: 'Google Calendar', scopes: [`${G}calendar`] },
  'google-drive': { name: 'Google Drive', scopes: [`${G}drive`] },
  'google-docs': { name: 'Google Docs', scopes: [`${G}documents`] },
  'google-sheets': { name: 'Google Sheets', scopes: [`${G}spreadsheets`] },
};
const IDENTITY_SCOPES = ['openid', 'email'];

const ALIASES: Record<string, GoogleToolkitId> = {
  gmail: 'gmail',
  calendar: 'google-calendar',
  googlecalendar: 'google-calendar',
  'google-calendar': 'google-calendar',
  drive: 'google-drive',
  googledrive: 'google-drive',
  'google-drive': 'google-drive',
  docs: 'google-docs',
  googledocs: 'google-docs',
  'google-docs': 'google-docs',
  sheets: 'google-sheets',
  googlesheets: 'google-sheets',
  'google-sheets': 'google-sheets',
};

/** "gmail,calendar" / ["drive"] → canonical toolkit ids (unknown names dropped, order kept, deduped). */
export function parseToolkits(raw: unknown): GoogleToolkitId[] {
  const parts = (Array.isArray(raw) ? raw : String(raw ?? '').split(',')).map((s) => String(s).trim().toLowerCase());
  const out: GoogleToolkitId[] = [];
  for (const p of parts) {
    const id = ALIASES[p];
    if (id && !out.includes(id)) out.push(id);
  }
  return out;
}

export function toolkitGranted(toolkit: GoogleToolkitId, scopes: string[]): boolean {
  return GOOGLE_TOOLKITS[toolkit].scopes.every((s) => scopes.includes(s));
}

// ───────────────────────────── encryption ─────────────────────────────

/** CONNECTOR_KEY is 32 random bytes, base64 or hex. Returns null when unset; throws when malformed. */
export function parseConnectorKey(raw: string | undefined | null): Buffer | null {
  const s = raw?.trim();
  if (!s) return null;
  const buf = /^[0-9a-f]{64}$/i.test(s) ? Buffer.from(s, 'hex') : Buffer.from(s, 'base64');
  if (buf.length !== 32) throw new Error('CONNECTOR_KEY must be 32 bytes (base64 or 64 hex characters)');
  return buf;
}

/** AES-256-GCM. `aad` binds the ciphertext to its owner, so a row moved to another user fails to open. */
export function sealToken(key: Buffer, plaintext: string, aad: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from(aad));
  const ct = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  return `v1:${iv.toString('base64url')}:${cipher.getAuthTag().toString('base64url')}:${ct.toString('base64url')}`;
}

export function openToken(key: Buffer, sealed: string, aad: string): string {
  const [v, iv, tag, ct] = sealed.split(':');
  if (v !== 'v1' || !iv || !tag || ct === undefined) throw new Error('unrecognised token envelope');
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64url'));
  decipher.setAAD(Buffer.from(aad));
  decipher.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(ct, 'base64url')), decipher.final()]).toString('utf8');
}

// ───────────────────────────── account vault ─────────────────────────────

export type ConnectorTokens = { access_token: string; refresh_token?: string };
export type ConnectorAccount = {
  userId: string;
  provider: string;
  scopes: string[];
  email: string | null;
  tokens: ConnectorTokens;
  expiresAt: string | null;
  createdAt: string;
  updatedAt: string;
};
type AccountRow = { user_id: string; provider: string; scopes: string; email: string | null; token_enc: string; expires_at: string | null; created_at: string; updated_at: string };

/** A user-facing problem with the stored grant (not connected, revoked). Shown to the agent verbatim. */
export class ConnectorAuthError extends Error {}

/** A Google API error, compacted to what an agent can act on. */
export class GoogleApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export type GoogleOAuthClient = { clientId: string; clientSecret: string };

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const REVOKE_URL = 'https://oauth2.googleapis.com/revoke';
const USERINFO_URL = 'https://openidconnect.googleapis.com/v1/userinfo';
const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';

export class ConnectorVault {
  private refreshing = new Map<string, Promise<string>>();
  db: DB;
  key: Buffer | null;
  fetch: FetchLike;
  client: GoogleOAuthClient | null;
  clock: () => number;
  constructor(db: DB, key: Buffer | null, fetchImpl: FetchLike, client: GoogleOAuthClient | null, clock: () => number = Date.now) {
    this.db = db;
    this.key = key;
    this.fetch = fetchImpl;
    this.client = client;
    this.clock = clock;
  }

  private aad(userId: string, provider: string) {
    return `awan-connector|${userId}|${provider}`;
  }

  private requireKey(): Buffer {
    if (!this.key) throw new ConnectorAuthError('Connectors are not set up on this Awan server (CONNECTOR_KEY is missing).');
    return this.key;
  }

  get(userId: string, provider: string): ConnectorAccount | null {
    const row = this.db.prepare('SELECT * FROM connector_accounts WHERE user_id = ? AND provider = ?').get(userId, provider) as AccountRow | undefined;
    if (!row) return null;
    let tokens: ConnectorTokens;
    try {
      tokens = JSON.parse(openToken(this.requireKey(), row.token_enc, this.aad(row.user_id, row.provider))) as ConnectorTokens;
    } catch (err) {
      if (err instanceof ConnectorAuthError) throw err;
      throw new ConnectorAuthError('The stored Google access can’t be read on this server. Ask the user to reconnect Google in Awan → Settings → Integrations.');
    }
    return {
      userId: row.user_id,
      provider: row.provider,
      scopes: row.scopes.split(' ').filter(Boolean),
      email: row.email,
      tokens,
      expiresAt: row.expires_at,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  /** Metadata only (never decrypts) — for status listings. */
  summary(userId: string): { provider: string; scopes: string[]; email: string | null; createdAt: string; updatedAt: string }[] {
    const rows = this.db.prepare('SELECT provider, scopes, email, created_at, updated_at FROM connector_accounts WHERE user_id = ? ORDER BY provider').all(userId) as AccountRow[];
    return rows.map((r) => ({ provider: r.provider, scopes: r.scopes.split(' ').filter(Boolean), email: r.email, createdAt: r.created_at, updatedAt: r.updated_at }));
  }

  save(userId: string, provider: string, a: { tokens: ConnectorTokens; scopes: string[]; email: string | null; expiresAt: string | null }) {
    const sealed = sealToken(this.requireKey(), JSON.stringify(a.tokens), this.aad(userId, provider));
    const t = now();
    this.db
      .prepare(
        `INSERT INTO connector_accounts (user_id, provider, scopes, email, token_enc, expires_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (user_id, provider) DO UPDATE SET scopes = excluded.scopes, email = excluded.email,
           token_enc = excluded.token_enc, expires_at = excluded.expires_at, updated_at = excluded.updated_at`,
      )
      .run(userId, provider, [...new Set(a.scopes)].join(' '), a.email, sealed, a.expiresAt, t, t);
  }

  delete(userId: string, provider: string) {
    this.db.prepare('DELETE FROM connector_accounts WHERE user_id = ? AND provider = ?').run(userId, provider);
  }

  /** A live Google access token for the user; refreshes (once, shared by concurrent callers) when near expiry. */
  async googleAccessToken(userId: string, force = false): Promise<string> {
    const acct = this.get(userId, 'google');
    if (!acct) throw new ConnectorAuthError('Google is not connected. Ask the user to connect it in Awan → Settings → Integrations.');
    const fresh = acct.expiresAt ? new Date(acct.expiresAt).getTime() - 60_000 > this.clock() : false;
    if (fresh && !force) return acct.tokens.access_token;
    const pending = this.refreshing.get(userId);
    if (pending) return pending;
    const p = this.refreshGoogle(acct).finally(() => this.refreshing.delete(userId));
    this.refreshing.set(userId, p);
    return p;
  }

  private async refreshGoogle(acct: ConnectorAccount): Promise<string> {
    if (!acct.tokens.refresh_token || !this.client) {
      throw new ConnectorAuthError('Google access expired. Ask the user to reconnect Google in Awan → Settings → Integrations.');
    }
    const res = await this.fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: this.client.clientId,
        client_secret: this.client.clientSecret,
        refresh_token: acct.tokens.refresh_token,
        grant_type: 'refresh_token',
      }).toString(),
    });
    const body = (await res.json().catch(() => ({}))) as { access_token?: string; expires_in?: number; scope?: string; refresh_token?: string; error?: string };
    if (!res.ok || !body.access_token) {
      if (body.error === 'invalid_grant') {
        throw new ConnectorAuthError('Google access was revoked. Ask the user to reconnect Google in Awan → Settings → Integrations.');
      }
      throw new GoogleApiError(res.status || 502, `Google token refresh failed${body.error ? `: ${body.error}` : ''}`);
    }
    this.save(acct.userId, 'google', {
      tokens: { access_token: body.access_token, refresh_token: body.refresh_token ?? acct.tokens.refresh_token },
      scopes: body.scope ? body.scope.split(' ') : acct.scopes,
      email: acct.email,
      expiresAt: new Date(this.clock() + (body.expires_in ?? 3600) * 1000).toISOString(),
    });
    return body.access_token;
  }

  /** Best-effort revoke at Google, then forget the grant. Returns whether Google confirmed the revoke. */
  async disconnect(userId: string, provider: string): Promise<{ revoked: boolean }> {
    let revoked = false;
    if (provider === 'google') {
      let acct: ConnectorAccount | null = null;
      try {
        acct = this.get(userId, provider);
      } catch {
        /* unreadable (key rotated) — still delete */
      }
      const token = acct?.tokens.refresh_token ?? acct?.tokens.access_token;
      if (token) {
        try {
          const r = await this.fetch(REVOKE_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ token }).toString(),
          });
          revoked = r.ok;
        } catch {
          revoked = false;
        }
      }
    }
    this.delete(userId, provider);
    return { revoked };
  }
}

// ───────────────────────────── Google REST client ─────────────────────────────

export type GoogleRequest = {
  method?: string;
  url: string;
  query?: Record<string, string | number | boolean | undefined | null | string[]>;
  json?: unknown;
  body?: BodyInit;
  headers?: Record<string, string>;
  /** Return the response text instead of parsing JSON (exports, media downloads). */
  text?: boolean;
};

export type GoogleApi = (req: GoogleRequest) => Promise<any>;

/** Authenticated Google calls for one user: bearer from the vault, one forced refresh on a 401. */
export function googleApi(vault: ConnectorVault, userId: string): GoogleApi {
  return async (req) => {
    const url = new URL(req.url);
    for (const [k, v] of Object.entries(req.query ?? {})) {
      if (v === undefined || v === null || v === '') continue;
      if (Array.isArray(v)) for (const item of v) url.searchParams.append(k, item);
      else url.searchParams.set(k, String(v));
    }
    const attempt = async (force: boolean) => {
      const token = await vault.googleAccessToken(userId, force);
      const headers: Record<string, string> = { Authorization: `Bearer ${token}`, ...(req.headers ?? {}) };
      let body = req.body;
      if (req.json !== undefined) {
        headers['Content-Type'] = 'application/json';
        body = JSON.stringify(req.json);
      }
      return vault.fetch(url.toString(), { method: req.method ?? 'GET', headers, body });
    };
    let res = await attempt(false);
    if (res.status === 401) res = await attempt(true);
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      let message = text.slice(0, 300);
      try {
        const j = JSON.parse(text) as { error?: { message?: string; status?: string } | string; error_description?: string };
        if (typeof j.error === 'object' && j.error?.message) message = j.error.message;
        else if (typeof j.error === 'string') message = j.error_description ?? j.error;
      } catch {
        /* not JSON */
      }
      if (res.status === 401) throw new ConnectorAuthError('Google rejected the stored access. Ask the user to reconnect Google in Awan → Settings → Integrations.');
      if (res.status === 403 && /insufficient|scope/i.test(message)) {
        throw new ConnectorAuthError(`Google refused: ${message}. Ask the user to reconnect this app in Awan → Settings → Integrations so it can grant the missing permission.`);
      }
      throw new GoogleApiError(res.status, `Google API error ${res.status}: ${message || res.statusText}`);
    }
    if (res.status === 204) return {};
    const text = await res.text();
    if (req.text) return text;
    return text ? JSON.parse(text) : {};
  };
}

// ───────────────────────────── OAuth routes ─────────────────────────────

export type ConnectorContext = {
  db: DB;
  vault: ConnectorVault;
  publicUrl: string;
  page: (title: string, body: string, openUrl?: string) => string;
  /** Per-user limiter for MCP tool calls. */
  mcpLimiter: { allow(key: string): boolean };
};

const STATE_TTL_MS = 10 * 60_000;

function safeRedirect(raw: unknown): string {
  const s = typeof raw === 'string' ? raw : '';
  return /^(awan:\/\/|https?:\/\/)/.test(s) ? s : 'awan://connectors';
}

function withQuery(target: string, params: Record<string, string>): string {
  const qs = new URLSearchParams(params).toString();
  return `${target}${target.includes('?') ? '&' : '?'}${qs}`;
}

function googleConfigProblem(vault: ConnectorVault): string | null {
  if (!vault.client) return 'Google isn’t set up on this Awan server yet (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET are missing).';
  if (!vault.key) return 'Connectors aren’t set up on this Awan server yet (CONNECTOR_KEY is missing).';
  return null;
}

function mintState(db: DB, userId: string, toolkits: GoogleToolkitId[], redirect: string): string {
  const state = randomBytes(24).toString('base64url');
  const t = new Date();
  db.prepare(
    'INSERT INTO connector_oauth_states (state_hash, user_id, provider, toolkits, redirect, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
  ).run(sha256(state), userId, 'google', toolkits.join(','), redirect, now(t), now(new Date(t.getTime() + STATE_TTL_MS)));
  return state;
}

function peekState(db: DB, state: string) {
  const row = db.prepare('SELECT * FROM connector_oauth_states WHERE state_hash = ?').get(sha256(state)) as
    | { user_id: string; provider: string; toolkits: string; redirect: string; expires_at: string; used_at: string | null }
    | undefined;
  if (!row || row.used_at || new Date(row.expires_at) < new Date()) return null;
  return row;
}

/** Single-use: only the first callback for a state gets its row. */
function redeemState(db: DB, state: string) {
  return tx(db, () => {
    const row = peekState(db, state);
    if (!row) return null;
    db.prepare('UPDATE connector_oauth_states SET used_at = ? WHERE state_hash = ? AND used_at IS NULL').run(now(), sha256(state));
    return row;
  });
}

export function googleConsentUrl(client: GoogleOAuthClient, publicUrl: string, toolkits: GoogleToolkitId[], state: string, loginHint?: string | null): string {
  const scopes = [...IDENTITY_SCOPES, ...toolkits.flatMap((t) => GOOGLE_TOOLKITS[t].scopes)];
  const url = new URL(AUTH_URL);
  url.search = new URLSearchParams({
    client_id: client.clientId,
    redirect_uri: `${publicUrl}/v1/connectors/google/callback`,
    response_type: 'code',
    scope: [...new Set(scopes)].join(' '),
    access_type: 'offline',
    include_granted_scopes: 'true',
    // consent → Google always returns a refresh token, even for an account granted before.
    prompt: 'consent',
    state,
    ...(loginHint ? { login_hint: loginHint } : {}),
  }).toString();
  return url.toString();
}

/** Status shape shared by GET /v1/connectors and the callback. */
export function connectorStatus(vault: ConnectorVault, userId: string) {
  const providers = vault.summary(userId).map((p) => ({
    provider: p.provider,
    email: p.email,
    scopes: p.scopes,
    toolkits: p.provider === 'google' ? (Object.keys(GOOGLE_TOOLKITS) as GoogleToolkitId[]).filter((t) => toolkitGranted(t, p.scopes)) : [],
    connectedAt: p.createdAt,
    updatedAt: p.updatedAt,
  }));
  const google = providers.find((p) => p.provider === 'google');
  const toolkits = Object.fromEntries(
    (Object.keys(GOOGLE_TOOLKITS) as GoogleToolkitId[]).map((t) => [t, { connected: Boolean(google?.toolkits.includes(t)), email: google?.email ?? null }]),
  );
  return { configured: { google: googleConfigProblem(vault) === null }, providers, toolkits };
}

export function registerConnectorRoutes(app: FastifyInstance, ctx: ConnectorContext) {
  const { db, vault, publicUrl, page, mcpLimiter } = ctx;
  const me = (req: FastifyRequest) => req.user as User;

  /** App entry point: mint a one-shot state for the signed-in user and hand back the browser URL. */
  app.post('/v1/connectors/google/start', async (req, reply) => {
    const problem = googleConfigProblem(vault);
    if (problem) return reply.code(501).send({ error: 'connectors_unavailable', message: problem });
    const body = (req.body ?? {}) as { toolkits?: unknown; redirect?: string };
    const toolkits = parseToolkits(body.toolkits);
    if (!toolkits.length) return reply.code(400).send({ error: 'unknown_toolkits' });
    const redirect = safeRedirect(body.redirect);
    const ticket = mintState(db, me(req).id, toolkits, redirect);
    const url = `${publicUrl}/v1/connectors/google/start?${new URLSearchParams({ toolkits: toolkits.join(','), redirect, ticket })}`;
    return { url, toolkits, expiresInSeconds: STATE_TTL_MS / 1000 };
  });

  /**
   * Browser entry point → Google consent. Needs either `ticket` (from the POST above; the browser has no
   * Awan token) or an Authorization header (API clients). Scopes come from the ticket, not the query.
   */
  app.get('/v1/connectors/google/start', async (req, reply) => {
    const problem = googleConfigProblem(vault);
    if (problem) return reply.code(501).type('text/html').send(page('Google connectors aren’t set up', problem));
    const q = req.query as { toolkits?: string; redirect?: string; ticket?: string };
    let state: string;
    let toolkits: GoogleToolkitId[];
    let userId: string;
    if (q.ticket) {
      const row = peekState(db, q.ticket);
      if (!row) return reply.code(400).type('text/html').send(page('That link has expired', 'Go back to Awan and press Connect again.'));
      state = q.ticket;
      toolkits = parseToolkits(row.toolkits);
      userId = row.user_id;
    } else {
      const user = userForToken(db, bearer(req));
      if (!user) return reply.code(401).type('text/html').send(page('Start from Awan', 'Open Awan → Settings → Integrations and press Connect.'));
      toolkits = parseToolkits(q.toolkits);
      if (!toolkits.length) return reply.code(400).type('text/html').send(page('Nothing to connect', 'Pick an app to connect in Awan → Settings → Integrations.'));
      state = mintState(db, user.id, toolkits, safeRedirect(q.redirect));
      userId = user.id;
    }
    const hint = (db.prepare('SELECT email FROM connector_accounts WHERE user_id = ? AND provider = ?').get(userId, 'google') as { email: string } | undefined)?.email;
    return reply.redirect(googleConsentUrl(vault.client!, publicUrl, toolkits, state, hint));
  });

  app.get('/v1/connectors/google/callback', async (req, reply) => {
    const q = req.query as { code?: string; state?: string; error?: string };
    const row = q.state ? redeemState(db, q.state) : null;
    if (!row) return reply.code(400).type('text/html').send(page('That link has expired', 'Go back to Awan and press Connect again.'));
    const back = (params: Record<string, string>, title: string, body: string) =>
      reply.type('text/html').send(page(title, body, withQuery(row.redirect, params)));
    if (q.error || !q.code) return back({ error: q.error || 'missing_code' }, 'Google wasn’t connected', 'Nothing changed. You can try again from Awan.');
    const client = vault.client!;
    const tokenRes = await vault.fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code: q.code,
        client_id: client.clientId,
        client_secret: client.clientSecret,
        redirect_uri: `${publicUrl}/v1/connectors/google/callback`,
        grant_type: 'authorization_code',
      }).toString(),
    });
    const tok = (await tokenRes.json().catch(() => ({}))) as { access_token?: string; refresh_token?: string; expires_in?: number; scope?: string };
    if (!tokenRes.ok || !tok.access_token) return back({ error: 'exchange_failed' }, 'Google wasn’t connected', 'Google didn’t hand back access. Try again from Awan.');
    const info = (await (await vault.fetch(USERINFO_URL, { headers: { Authorization: `Bearer ${tok.access_token}` } })).json().catch(() => ({}))) as { email?: string };
    const previous = (() => {
      try {
        return vault.get(row.user_id, 'google');
      } catch {
        return null;
      }
    })();
    // A different Google account replaces the old grant entirely; the same one merges scopes.
    const sameAccount = previous && (!info.email || !previous.email || previous.email.toLowerCase() === info.email.toLowerCase());
    const granted = (tok.scope ?? '').split(' ').filter(Boolean);
    const scopes = sameAccount ? [...new Set([...previous!.scopes, ...granted])] : granted;
    vault.save(row.user_id, 'google', {
      tokens: { access_token: tok.access_token, refresh_token: tok.refresh_token ?? (sameAccount ? previous!.tokens.refresh_token : undefined) },
      scopes,
      email: info.email?.toLowerCase() ?? previous?.email ?? null,
      expiresAt: new Date(vault.clock() + (tok.expires_in ?? 3600) * 1000).toISOString(),
    });
    const asked = parseToolkits(row.toolkits);
    const connected = asked.filter((t) => toolkitGranted(t, scopes));
    const missing = asked.filter((t) => !connected.includes(t));
    const params: Record<string, string> = { connected: connected.join(',') };
    if (missing.length) params.missing = missing.join(',');
    if (info.email) params.email = info.email.toLowerCase();
    if (!connected.length) return back(params, 'Nothing was connected', 'Google didn’t grant the permissions Awan asked for. Try again and leave the boxes ticked.');
    const names = connected.map((t) => GOOGLE_TOOLKITS[t].name).join(', ');
    return back(params, `${names} connected`, 'Awan is opening now. Your Awans can use it on their next task.');
  });

  app.get('/v1/connectors', async (req) => connectorStatus(vault, me(req).id));

  app.post('/v1/connectors/:provider/disconnect', async (req, reply) => {
    const { provider } = req.params as { provider: string };
    if (provider !== 'google') return reply.code(404).send({ error: 'unknown_provider' });
    const { revoked } = await vault.disconnect(me(req).id, provider);
    return { disconnected: true, revoked, ...connectorStatus(vault, me(req).id) };
  });

  // ───────────────────────── Awan-hosted MCP servers ─────────────────────────
  /**
   * Streamable HTTP MCP endpoint, one per toolkit (gmail, google-calendar, google-drive, google-docs,
   * google-sheets). Auth is the user's Awan bearer (the onRequest hook guards /mcp/*). initialize and
   * tools/list always work so the runtime can start; tools/call explains when the toolkit isn't connected.
   */
  app.post('/mcp/:toolkit', async (req, reply) => {
    const { toolkit } = req.params as { toolkit: string };
    const spec = GOOGLE_MCP_SERVERS[toolkit];
    if (!spec) return reply.code(404).send({ jsonrpc: '2.0', id: null, error: { code: -32601, message: `No Awan MCP server called ${toolkit}` } });
    const user = me(req);
    const body = req.body as unknown;
    if (!body || typeof body !== 'object' || (Array.isArray(body) && !body.length)) {
      return reply.code(400).send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error: expected a JSON-RPC message' } });
    }
    const account = () => vault.summary(user.id).find((p) => p.provider === 'google');
    const name = GOOGLE_TOOLKITS[toolkit as GoogleToolkitId].name;
    const hooks = {
      beforeCall: () => {
        const acct = account();
        if (!acct) return `${name} isn't connected. Ask the user to connect ${name} in Awan → Settings → Integrations, then try again.`;
        if (!toolkitGranted(toolkit as GoogleToolkitId, acct.scopes)) return `${name} isn't connected for ${acct.email ?? 'this Google account'}. Ask the user to press Connect next to ${name} in Awan → Settings → Integrations.`;
        if (!mcpLimiter.allow(user.id)) return 'Too many Google calls in the last minute. Wait a minute, then continue with fewer, larger calls.';
        return null;
      },
      describeError: (err: unknown) => {
        if (err instanceof ConnectorAuthError || err instanceof GoogleApiError) return err.message;
        req.log.warn({ err, toolkit }, 'mcp tool failed');
        return err instanceof Error ? err.message : 'Unexpected error';
      },
    };
    const toolCtx = { g: googleApi(vault, user.id), get accountEmail() { return account()?.email ?? null; } };
    const messages = Array.isArray(body) ? body : [body];
    const out = [];
    for (const m of messages) {
      const r = await handleMcpMessage(spec, m, toolCtx, hooks);
      if (r) out.push(r);
    }
    if (!out.length) return reply.code(202).send();
    return reply.code(200).type('application/json').send(Array.isArray(body) ? out : out[0]);
  });

  // No server-initiated stream and no sessions: GET/DELETE are not offered (spec-compliant 405).
  for (const method of ['GET', 'DELETE'] as const) {
    app.route({ method, url: '/mcp/:toolkit', handler: async (_req, reply) => reply.code(405).header('Allow', 'POST').send({ error: 'method_not_allowed' }) });
  }
}

