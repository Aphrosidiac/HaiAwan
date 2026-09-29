import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import cors from '@fastify/cors';
import formbody from '@fastify/formbody';
import { type DB, now, tx } from './db.ts';
import {
  bearer,
  createMagicLink,
  isValidHandle,
  issueToken,
  normaliseHandle,
  publicUser,
  redeemMagicLink,
  revokeToken,
  upsertUser,
  userForToken,
  type User,
} from './auth.ts';
import { consume, hasHeadroom, planSnapshot, PLAN_CAPS, PRICES, QuotaExceeded, setPlan, type Plan, type UsageKind } from './plans.ts';
import { complete, completeJson, config as llm, ProviderError, speak, speechModelFor, streamText, transcribe, VOICES, type ChatMessage, type Voice } from './llm.ts';
import * as P from './prompts.ts';
import { parseAssistantTags } from './tags.ts';
import { INTEGRATIONS } from './integrations.ts';
import { validateAwanSpec, validateSuggestion, type AwanSpec, type SuggestionSpec } from './specs.ts';
import { StripeClient, stripeConfigFromEnv, type StripeConfig } from './stripe.ts';
import { cleanupDictation, cleanupMessages, type CleanupInput } from './dictation.ts';
import { liveImageDeps, searchImages, type ImageSearchDeps } from './images.ts';
import { activeSkills, activeSkillsBlock, MAX_ACTIVE_SKILLS, registerSkillRoutes, seedOfficialSkills, visibleSkill, type SkillDraft, type SkillRow } from './skills.ts';
import { dissolveTeamsOf, registerTeamRoutes } from './teams.ts';
import { ConnectorVault, parseConnectorKey, registerConnectorRoutes, type FetchLike, type GoogleOAuthClient } from './connectors.ts';
import { mailerFromEnv, signInEmail, type Mailer } from './mailer.ts';
import { composioFromEnv, registerComposioRoutes } from './composio.ts';

declare module 'fastify' {
  interface FastifyRequest {
    user?: User;
  }
}

export type AppOptions = {
  db: DB;
  devMode?: boolean;
  publicUrl?: string;
  siteUrl?: string;
  /** Override the dictation clean-up model call (tests). */
  dictationModel?: (input: CleanupInput) => Promise<string>;
  /** Override the image search providers and the image check (tests). */
  imageSearch?: ImageSearchDeps;
  /** Override the skill-writing model call behind POST /v1/skills/create (tests). */
  skillWriter?: (brainDump: string) => Promise<SkillDraft>;
  /** Outgoing sign-in email. Omitted → from env (RESEND_API_KEY or SMTP_*); null → none configured. */
  mailer?: Mailer | null;
  /** HTTP for Google OAuth + REST (tests inject a fake). */
  googleFetch?: FetchLike;
  /** Google OAuth client. Omitted → GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET; null → not configured. */
  googleClient?: GoogleOAuthClient | null;
  /** 32-byte key (base64/hex) that encrypts connector tokens. Omitted → CONNECTOR_KEY; null → none. */
  connectorKey?: string | null;
  /** Clock for connector token expiry (tests). */
  clock?: () => number;
  /** MCP tool calls allowed per user per window. */
  mcpRateLimit?: { max: number; windowMs: number };
  /** Composio project key. Omitted → COMPOSIO_API_KEY; null → Composio off (routes answer 501). */
  composioApiKey?: string | null;
  /** HTTP for Composio's REST API and the MCP proxy (tests inject a fake). */
  composioFetch?: FetchLike;
  /** Composio API base (default https://backend.composio.dev/api/v3.1). */
  composioBase?: string;
  /** Stripe keys + HTTP. Omitted fields come from STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET / STRIPE_REFERRAL_COUPON. */
  stripe?: Partial<StripeConfig>;
};

export const REMOTE_CONFIG = {
  links: {
    changelog: '/changelog',
    featureRequest: '/feedback',
    community: 'https://www.instagram.com/ffdev.studio',
    whatsapp: 'https://wa.me/60000000000',
    privacy: '/privacy',
    terms: '/terms',
  },
};

export async function buildApp(opts: AppOptions): Promise<FastifyInstance> {
  const { db } = opts;
  seedOfficialSkills(db);
  const devMode = opts.devMode ?? process.env.NODE_ENV !== 'production';
  const publicUrl = (opts.publicUrl ?? process.env.PUBLIC_API_URL ?? 'http://127.0.0.1:8787').replace(/\/$/, '');
  const siteUrl = (opts.siteUrl ?? process.env.PUBLIC_SITE_URL ?? 'http://127.0.0.1:5190').replace(/\/$/, '');

  const mailer = opts.mailer !== undefined ? opts.mailer : mailerFromEnv();
  const googleClient =
    opts.googleClient !== undefined
      ? opts.googleClient
      : process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET
        ? { clientId: process.env.GOOGLE_CLIENT_ID, clientSecret: process.env.GOOGLE_CLIENT_SECRET }
        : null;
  const vault = new ConnectorVault(
    db,
    parseConnectorKey(opts.connectorKey !== undefined ? opts.connectorKey : process.env.CONNECTOR_KEY),
    opts.googleFetch ?? ((input, init) => fetch(input, init)),
    googleClient,
    opts.clock,
  );
  const composio = composioFromEnv(
    db,
    opts.composioApiKey !== undefined ? opts.composioApiKey : process.env.COMPOSIO_API_KEY,
    opts.composioFetch ?? ((input, init) => fetch(input, init)),
    { base: opts.composioBase ?? process.env.COMPOSIO_API_BASE, clock: opts.clock },
  );
  const stripe = new StripeClient(stripeConfigFromEnv(opts.stripe));
  const mcpLimiter = new RateLimiter(opts.mcpRateLimit?.max ?? Number(process.env.MCP_CALLS_PER_MINUTE || 120), opts.mcpRateLimit?.windowMs ?? 60_000);
  const magicLimiter = new RateLimiter(Number(process.env.MAGIC_LINKS_PER_EMAIL || 5), 15 * 60_000);
  const magicIpLimiter = new RateLimiter(Number(process.env.MAGIC_LINKS_PER_IP_HOUR || 30), 3600_000);

  const app = Fastify({ logger: process.env.LOG !== '0' ? { level: process.env.LOG_LEVEL || 'info' } : false, bodyLimit: 40 * 1024 * 1024 });
  await app.register(cors, { origin: true });
  await app.register(formbody);
  // Keep the raw JSON body for Stripe signature checks.
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body, done) => {
    (req as FastifyRequest & { rawBody?: string }).rawBody = body as string;
    if (!body) return done(null, {});
    try {
      done(null, JSON.parse(body as string));
    } catch (err) {
      (err as { statusCode?: number }).statusCode = 400;
      done(err as Error, undefined);
    }
  });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof QuotaExceeded) {
      return reply.code(402).send({ error: 'quota_exceeded', kind: err.kind, cap: err.cap, upgrade: true });
    }
    if (err instanceof ProviderError) {
      return reply.code(err.status === 503 ? 503 : 502).send({ error: err.message });
    }
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) app.log.error(err);
    return reply.code(status).send({ error: err.message });
  });

  // Auth guard for everything under /v1 except the explicitly public routes.
  const PUBLIC = new Set(['/v1/config', '/v1/auth/magic', '/v1/billing/webhook', '/v1/integrations', '/v1/voices', '/v1/speech']);
  // Browser legs of the connector OAuth (they check their own one-shot state instead of a bearer).
  const PUBLIC_GET = new Set(['/v1/connectors/google/start', '/v1/connectors/google/callback', '/v1/composio/callback']);
  app.addHook('onRequest', async (req, reply) => {
    const path = req.url.split('?')[0];
    const isPublic = PUBLIC.has(path) || (req.method === 'GET' && PUBLIC_GET.has(path));
    const needsAuth = (path.startsWith('/v1/') && !isPublic) || path.startsWith('/agent/') || path.startsWith('/mcp/');
    if (!needsAuth) return;
    const user = userForToken(db, bearer(req));
    if (!user) {
      if (path.startsWith('/mcp/')) reply.header('WWW-Authenticate', 'Bearer realm="awan"');
      return reply.code(401).send({ error: 'unauthorized' });
    }
    req.user = user;
  });

  const me = (req: FastifyRequest) => req.user as User;

  // ───────────────────────────── public ─────────────────────────────
  app.get('/health', async () => ({
    ok: true,
    provider: llm.apiKey ? (llm.isOpenRouter ? 'openrouter' : 'openai') : 'none',
    stripe: stripe.configured,
    mail: mailer?.name ?? 'none',
    connectors: { google: Boolean(vault.client && vault.key), composio: Boolean(composio) },
  }));

  app.get('/v1/config', async () => ({
    ...REMOTE_CONFIG,
    links: Object.fromEntries(Object.entries(REMOTE_CONFIG.links).map(([k, v]) => [k, v.startsWith('/') ? siteUrl + v : v])),
    prices: PRICES,
    caps: PLAN_CAPS,
    voices: VOICES,
    features: {
      realtime: Boolean(process.env.OPENAI_API_KEY),
      serverSpeech: Boolean(llm.apiKey),
      stripe: stripe.configured,
      emailSignIn: Boolean(mailer) || devMode,
      googleConnectors: Boolean(vault.client && vault.key),
      composio: Boolean(composio),
    },
  }));

  app.get('/v1/voices', async () => ({ voices: VOICES }));
  app.get('/v1/integrations', async () => ({ integrations: INTEGRATIONS }));

  // ───────────────────────────── auth ─────────────────────────────
  app.post('/v1/auth/magic', async (req, reply) => {
    const body = req.body as { email?: string; redirect?: string; referral?: string };
    const email = body.email?.trim().toLowerCase();
    if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply.code(400).send({ error: 'invalid_email' });
    if (!mailer && !devMode) {
      return reply.code(503).send({
        error: 'email_unavailable',
        message: 'Email sign-in isn’t set up on this Awan server yet. Sign in with Google, or ask the server admin to configure RESEND_API_KEY or SMTP.',
      });
    }
    if (!magicLimiter.allow(email) || (!devMode && !magicIpLimiter.allow(req.ip))) {
      return reply.code(429).send({ error: 'too_many_links', message: 'Too many sign-in links. Check your inbox, or wait a few minutes and try again.' });
    }
    const redirect = body.redirect && /^(awan:\/\/|https?:\/\/)/.test(body.redirect) ? body.redirect : 'awan://auth';
    const code = createMagicLink(db, email, redirect, body.referral ?? null);
    const link = `${publicUrl}/auth/verify?code=${code}`;
    if (mailer) {
      try {
        const { id } = await mailer.send({ to: email, ...signInEmail(link) });
        app.log.info({ email, provider: mailer.name, id }, 'magic link emailed');
      } catch (err) {
        app.log.error({ err, email, provider: mailer.name }, 'magic link email failed');
        if (!devMode) return reply.code(502).send({ error: 'email_failed', message: 'We couldn’t send the sign-in email. Try again in a minute.' });
      }
    }
    // The link itself is only ever logged in dev; in production it exists only in the user's inbox.
    if (devMode) app.log.info({ email, link }, 'magic link issued');
    return { sent: true, delivery: mailer?.name ?? 'log', ...(devMode ? { devLink: link } : {}) };
  });

  app.get('/auth/verify', async (req, reply) => {
    const { code } = req.query as { code?: string };
    const redeemed = code ? redeemMagicLink(db, code) : null;
    if (!redeemed) return reply.code(400).type('text/html').send(page('That link has expired', 'Ask Awan for a fresh sign-in link and try again.'));
    const { user } = upsertUser(db, redeemed.email, { referral: redeemed.referral });
    const token = issueToken(db, user.id);
    const target = `${redeemed.redirect}${redeemed.redirect.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}`;
    if (redeemed.redirect.startsWith('awan://')) {
      return reply.type('text/html').send(page('You’re in', 'Awan is opening now. You can close this tab.', target));
    }
    return reply.redirect(target);
  });

  app.get('/auth/google/start', async (req, reply) => {
    const q = req.query as { redirect?: string; ref?: string };
    const clientId = process.env.GOOGLE_CLIENT_ID;
    if (!clientId) return reply.code(501).type('text/html').send(page('Google sign-in isn’t set up', 'Use your email instead — Awan will send you a link.'));
    const state = Buffer.from(JSON.stringify({ r: q.redirect ?? 'awan://auth', ref: q.ref ?? null })).toString('base64url');
    const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    url.search = new URLSearchParams({
      client_id: clientId,
      redirect_uri: `${publicUrl}/auth/google/callback`,
      response_type: 'code',
      scope: 'openid email profile',
      prompt: 'select_account',
      state,
    }).toString();
    return reply.redirect(url.toString());
  });

  app.get('/auth/google/callback', async (req, reply) => {
    const { code, state } = req.query as { code?: string; state?: string };
    if (!code || !state) return reply.code(400).send({ error: 'missing_code' });
    const { r, ref } = JSON.parse(Buffer.from(state, 'base64url').toString()) as { r: string; ref: string | null };
    const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: process.env.GOOGLE_CLIENT_ID!,
        client_secret: process.env.GOOGLE_CLIENT_SECRET!,
        redirect_uri: `${publicUrl}/auth/google/callback`,
        grant_type: 'authorization_code',
      }),
    });
    const tok = (await tokenRes.json()) as { access_token?: string };
    if (!tok.access_token) return reply.code(400).send({ error: 'google_exchange_failed' });
    const info = (await (await fetch('https://openidconnect.googleapis.com/v1/userinfo', { headers: { Authorization: `Bearer ${tok.access_token}` } })).json()) as {
      email?: string;
      email_verified?: boolean;
      name?: string;
      picture?: string;
    };
    if (!info.email || !info.email_verified) return reply.code(400).send({ error: 'google_email_unverified' });
    const { user } = upsertUser(db, info.email.toLowerCase(), { displayName: info.name, avatarUrl: info.picture, referral: ref });
    const token = issueToken(db, user.id);
    const target = `${r}${r.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}`;
    return reply.type('text/html').send(page('You’re in', 'Awan is opening now. You can close this tab.', target));
  });

  app.post('/v1/auth/logout', async (req) => {
    revokeToken(db, bearer(req)!);
    return { ok: true };
  });

  // ───────────────────────────── connectors ─────────────────────────────
  registerConnectorRoutes(app, { db, vault, publicUrl, page, mcpLimiter });
  registerComposioRoutes(app, { db, broker: composio, publicUrl, page, tokenEnvVar: 'AWAN_AGENT_TOKEN' });

  // ───────────────────────────── account ─────────────────────────────
  app.get('/v1/me', async (req) => ({ user: publicUser(me(req)), plan: planSnapshot(db, me(req).id) }));

  app.patch('/v1/me', async (req, reply) => {
    const body = req.body as { displayName?: string; discoveryChannel?: string };
    const u = me(req);
    if (body.displayName !== undefined) {
      const name = body.displayName.trim().slice(0, 60);
      if (!name) return reply.code(400).send({ error: 'invalid_name' });
      db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(name, u.id);
    }
    if (body.discoveryChannel !== undefined) {
      db.prepare('UPDATE users SET discovery_channel = ? WHERE id = ?').run(body.discoveryChannel.slice(0, 40), u.id);
    }
    const fresh = db.prepare('SELECT * FROM users WHERE id = ?').get(u.id) as User;
    return { user: publicUser(fresh) };
  });

  /** Permanently erase the account: tokens, usage, awans, suggestions — the row is anonymised. */
  app.delete('/v1/me', async (req) => {
    const u = me(req);
    // Best-effort: hand the Google grant back before the rows go.
    await vault.disconnect(u.id, 'google').catch(() => undefined);
    await composio?.disconnectAll(u.id).catch(() => undefined);
    tx(db, () => {
      dissolveTeamsOf(db, u.id);
      for (const t of ['api_tokens', 'usage_events', 'awans', 'suggestions', 'profiles', 'subscriptions', 'skill_activations', 'skill_users', 'team_sessions', 'team_dashboard_links', 'connector_accounts', 'connector_oauth_states', 'composio_sessions', 'composio_link_states', 'team_checkouts']) {
        db.prepare(`DELETE FROM ${t} WHERE user_id = ?`).run(u.id);
      }
      db.prepare('DELETE FROM skills WHERE created_by = ?').run(u.id);
      db.prepare("UPDATE users SET email = ?, display_name = 'Deleted user', avatar_url = NULL, deleted_at = ? WHERE id = ?").run(
        `deleted+${u.id}@awan.invalid`,
        now(),
        u.id,
      );
    });
    return { deleted: true };
  });

  // ───────────────────────────── billing ─────────────────────────────
  app.get('/v1/billing/plan', async (req) => planSnapshot(db, me(req).id));

  app.post('/v1/usage/consume', async (req, reply) => {
    const { kind, ref } = req.body as { kind: UsageKind; ref?: string };
    if (!['talk', 'agent_message', 'dictation', 'realtime_minute'].includes(kind)) return reply.code(400).send({ error: 'bad_kind' });
    consume(db, me(req).id, kind, ref);
    return planSnapshot(db, me(req).id);
  });

  app.post('/v1/billing/checkout', async (req, reply) => {
    const { plan, interval } = req.body as { plan: Plan; interval: 'month' | 'year' };
    if (!['pro', 'max'].includes(plan) || !['month', 'year'].includes(interval)) return reply.code(400).send({ error: 'bad_plan' });
    const u = me(req);
    if (stripe.configured) return { url: await stripe.checkout(u, plan, interval, siteUrl) };
    if (!devMode) return reply.code(501).send({ error: 'billing_unavailable' });
    // Dev: a local checkout page that simulates a successful test-mode payment.
    return { url: `${publicUrl}/billing/dev-checkout?plan=${plan}&interval=${interval}&token=${encodeURIComponent(bearer(req)!)}` };
  });

  app.post('/v1/billing/portal', async (req, reply) => {
    if (!stripe.configured) return reply.code(501).send({ error: 'billing_portal_unavailable' });
    return { url: await stripe.portal(db, me(req), siteUrl) };
  });

  app.get('/billing/dev-checkout', async (req, reply) => {
    const q = req.query as { plan: Plan; interval: 'month' | 'year'; token: string };
    const price = PRICES[q.plan as 'pro' | 'max']?.[q.interval];
    if (!devMode || !price) return reply.code(404).send();
    return reply.type('text/html').send(devCheckoutPage(q.plan, q.interval, price, q.token));
  });

  app.post('/billing/dev-checkout', async (req, reply) => {
    if (!devMode) return reply.code(404).send();
    const q = req.body as { plan: Plan; interval: 'month' | 'year'; token: string };
    const u = userForToken(db, q.token);
    if (!u || !['pro', 'max'].includes(q.plan)) return reply.code(400).send({ error: 'bad_request' });
    const periodEnd = new Date(Date.now() + (q.interval === 'year' ? 365 : 30) * 86_400_000);
    setPlan(db, u.id, q.plan, q.interval, { periodEnd: now(periodEnd) });
    recordReferralEarning(db, u.id, `dev_${u.id}_${Date.now()}`, PRICES[q.plan as 'pro' | 'max'][q.interval]);
    return reply.type('text/html').send(page('You’re on ' + (q.plan === 'pro' ? 'Pro' : 'Max'), 'Head back to Awan — your new limits are live.', 'awan://billing/success'));
  });

  app.post('/v1/billing/cancel', async (req) => {
    const u = me(req);
    db.prepare("UPDATE subscriptions SET status = 'canceled', updated_at = ? WHERE user_id = ?").run(now(), u.id);
    return planSnapshot(db, u.id);
  });

  app.post('/v1/billing/webhook', async (req, reply) => {
    if (!stripe.configured) return reply.code(404).send();
    return stripe.webhook(db, req, reply, recordReferralEarning);
  });

  // ───────────────────────────── companion ─────────────────────────────
  /**
   * The voice/text companion turn. Consumes one "talk", streams the reply as SSE:
   *   event: delta   data: {"text": "..."}          (spoken text only, tags stripped)
   *   event: done    data: {"text", "points":[{x,y,label,screen}], "agentTask"}
   */
  app.post('/v1/companion/respond', async (req, reply) => {
    const body = req.body as {
      transcript: string;
      images?: { data: string; label: string; mime?: string }[];
      history?: { user: string; assistant: string }[];
      requestId?: string;
      onboardingDemo?: boolean;
      context?: string;
      /** The document open in the front window (whole-document context), read by the app. */
      document?: { name?: string; text?: string; kind?: string };
      /** Slugs of the skills switched on in the app; when absent the server uses the account's active set. */
      activeSkills?: string[];
    };
    if (!body.transcript?.trim() && !body.onboardingDemo) return reply.code(400).send({ error: 'empty_transcript' });
    const u = me(req);
    if (!body.onboardingDemo) consume(db, u.id, 'talk', body.requestId);

    const messages: ChatMessage[] = [{ role: 'system', content: body.onboardingDemo ? P.ONBOARDING_DEMO_SYSTEM : P.COMPANION_SYSTEM + (body.context ? `\n\ncontext about the user:\n${body.context}` : '') }];
    for (const h of (body.history ?? []).slice(-20)) {
      messages.push({ role: 'user', content: h.user }, { role: 'assistant', content: h.assistant });
    }
    const parts: Exclude<ChatContent, string> = [];
    for (const img of body.images ?? []) {
      parts.push({ type: 'text', text: img.label });
      parts.push({ type: 'image_url', image_url: { url: `data:${img.mime ?? 'image/jpeg'};base64,${img.data}`, detail: 'high' } });
    }
    const doc = documentBlock(body.document);
    if (doc && !body.onboardingDemo) parts.push({ type: 'text', text: doc });
    if (!body.onboardingDemo) {
      const skills = companionSkills(db, u.id, body.activeSkills);
      const block = activeSkillsBlock(skills);
      if (block) parts.push({ type: 'text', text: block });
    }
    parts.push({ type: 'text', text: body.onboardingDemo ? 'say hi and point at something you notice.' : body.transcript });
    messages.push({ role: 'user', content: parts });

    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
    const send = (event: string, data: unknown) => raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    const abort = new AbortController();
    reply.raw.on('close', () => {
      if (!reply.raw.writableFinished) abort.abort();
    });
    let full = '';
    let emitted = 0;
    try {
      const model = doc && !body.onboardingDemo ? llm.models.companion : routeCompanionModel(body.transcript ?? '', (body.images ?? []).length > 0, body.onboardingDemo);
      send('route', { model });
      for await (const d of streamText({ model, messages, signal: abort.signal, maxTokens: 1400 })) {
        full += d;
        // Only emit text that can no longer be part of a trailing [TAG…] block.
        const safe = safePrefix(full);
        if (safe.length > emitted) {
          send('delta', { text: safe.slice(emitted) });
          emitted = safe.length;
        }
      }
      const parsed = parseAssistantTags(full);
      if (parsed.spokenText.length > emitted) send('delta', { text: parsed.spokenText.slice(emitted) });
      send('done', parsed);
    } catch (err) {
      send('error', { error: err instanceof Error ? err.message : String(err) });
    } finally {
      raw.end();
    }
  });

  /** Streams 24 kHz mono PCM16 (`audio/L16`) for the given text and voice. */
  /**
   * Streams 24 kHz mono PCM16 (`audio/L16`) for the given text and voice.
   * Signed out (onboarding voice previews), short lines are allowed at a per-IP rate.
   * Every rendered line is cached on disk, so repeats (previews, stock lines) cost nothing and start instantly.
   */
  app.post('/v1/speech', async (req, reply) => {
    const { text, voice, speed } = req.body as { text: string; voice?: Voice; speed?: number };
    if (!text?.trim()) return reply.code(400).send({ error: 'empty_text' });
    const signedIn = Boolean(userForToken(db, bearer(req)));
    if (!signedIn) {
      if (text.length > 240) return reply.code(401).send({ error: 'unauthorized' });
      if (!previewLimiter.allow(req.ip)) return reply.code(429).send({ error: 'slow_down' });
    }
    const v: Voice = VOICES.includes(voice as Voice) ? (voice as Voice) : 'cedar';
    const sp = Math.round((speed ?? 1) * 100) / 100;
    const clipped = text.slice(0, 4000);
    const cacheFile = speechCache.path(v, sp, clipped);
    reply.hijack();
    reply.raw.writeHead(200, { 'Content-Type': 'audio/L16; rate=24000; channels=1', 'Transfer-Encoding': 'chunked', 'X-Awan-Speech-Cache': cacheFile && existsSync(cacheFile) ? 'hit' : 'miss' });
    if (cacheFile && existsSync(cacheFile)) {
      reply.raw.end(readFileSync(cacheFile));
      return;
    }
    const abort = new AbortController();
    reply.raw.on('close', () => {
      if (!reply.raw.writableFinished) abort.abort();
    });
    const parts: Buffer[] = [];
    let complete = false;
    try {
      for await (const chunk of speak(clipped, v, sp, abort.signal)) {
        parts.push(chunk);
        reply.raw.write(chunk);
      }
      complete = true;
    } catch (err) {
      app.log.warn({ err }, 'speech failed');
    } finally {
      reply.raw.end();
      if (complete && cacheFile && parts.length) speechCache.save(cacheFile, Buffer.concat(parts));
    }
  });

  app.post('/v1/transcribe', async (req, reply) => {
    const body = req.body as { audio: string; format?: 'wav' | 'mp3'; language?: string; dictionary?: string[]; kind?: 'dictation' | 'talk'; requestId?: string };
    if (!body.audio) return reply.code(400).send({ error: 'no_audio' });
    if (body.kind === 'dictation') consume(db, me(req).id, 'dictation', body.requestId);
    const text = await transcribe(Buffer.from(body.audio, 'base64'), body.format ?? 'wav', { language: body.language, dictionary: body.dictionary?.slice(0, 50) });
    return { text };
  });

  /**
   * Dictation clean-up (punctuation, casing, fillers, the user's dictionary). Spends one "dictation"
   * unit keyed on requestId, the same id as a /v1/transcribe call for the same recording, so one
   * dictation is counted once. No em dashes and no invented words are enforced in code; if the model
   * breaks either rule (or is unavailable) a deterministic local tidy is returned instead.
   */
  app.post('/v1/dictation/cleanup', async (req, reply) => {
    const body = req.body as { text?: string; dictionary?: string[]; appName?: string; language?: string; requestId?: string };
    const text = body.text?.trim() ?? '';
    if (!text) return reply.code(400).send({ error: 'empty_text' });
    if (text.length > 20_000) return reply.code(413).send({ error: 'too_long' });
    consume(db, me(req).id, 'dictation', body.requestId);
    const dictionary = Array.isArray(body.dictionary) ? body.dictionary.map(String).filter(Boolean).slice(0, 50) : [];
    const model =
      opts.dictationModel ??
      ((input: CleanupInput) => complete({ model: llm.models.fast, temperature: 0, maxTokens: Math.min(4000, 200 + input.text.length), messages: cleanupMessages(input) }));
    const out = await cleanupDictation({ text, dictionary, appName: body.appName?.slice(0, 80), language: body.language?.slice(0, 20) }, model);
    return { text: out.text, source: out.source, raw: text };
  });

  /**
   * Pictures for an [IMAGES:query] answer card: up to 8 results, each verified to be an image.
   * Doesn't spend a talk (the turn that asked for it already did). Empty list = no card.
   */
  app.get('/v1/images', async (req, reply) => {
    const q = String((req.query as { q?: string }).q ?? '').trim();
    if (!q) return reply.code(400).send({ error: 'empty_query' });
    if (q.length > 200) return reply.code(413).send({ error: 'too_long' });
    const images = await searchImages(q, opts.imageSearch ?? liveImageDeps);
    return { query: q, images };
  });

  /** Realtime voice needs OpenAI's Realtime API directly; without that key the app uses the pipeline. */
  app.post('/v1/realtime/session', async (req, reply) => {
    const key = process.env.OPENAI_API_KEY;
    if (!key) return reply.code(501).send({ error: 'realtime_unavailable', fallback: 'pipeline' });
    consume(db, me(req).id, 'realtime_minute', (req.body as { requestId?: string })?.requestId);
    const { voice, instructions } = req.body as { voice?: Voice; instructions?: string };
    const r = await fetch('https://api.openai.com/v1/realtime/client_secrets', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        session: { type: 'realtime', model: process.env.REALTIME_MODEL || 'gpt-realtime', audio: { output: { voice: voice ?? 'cedar' } }, instructions: instructions ?? P.COMPANION_SYSTEM + P.REALTIME_ADDENDUM },
      }),
    });
    return reply.code(r.status).send(await r.json());
  });

  // ───────────────────────────── onboarding + awans ─────────────────────────────
  app.post('/v1/onboarding/cast', async (req) => {
    const u = me(req);
    const { answers } = req.body as { answers: Record<string, string> };
    const result = await completeJson(
      {
        model: llm.models.companion,
        maxTokens: 4000,
        messages: [
          { role: 'system', content: P.STARTER_CAST_SYSTEM },
          { role: 'user', content: `User's name: ${u.display_name}\nInterview answers:\n${Object.entries(answers ?? {}).map(([q, a]) => `- ${q}: ${a}`).join('\n')}` },
        ],
      },
      (v) => {
        const o = v as { goalSummary?: string; awans?: unknown[] };
        if (!Array.isArray(o.awans) || o.awans.length === 0) throw new Error('no awans');
        return { goalSummary: String(o.goalSummary ?? ''), awans: o.awans.slice(0, 3).map((a) => validateAwanSpec(a)) };
      },
    );
    tx(db, () => {
      db.prepare('INSERT INTO profiles (user_id, answers_json, goal_summary, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET answers_json = excluded.answers_json, goal_summary = excluded.goal_summary, updated_at = excluded.updated_at').run(
        u.id,
        JSON.stringify(answers ?? {}),
        result.goalSummary,
        now(),
      );
      if (answers?.discoveryChannel) db.prepare('UPDATE users SET discovery_channel = ? WHERE id = ?').run(answers.discoveryChannel, u.id);
      for (const a of result.awans) {
        saveAwan(db, u.id, a);
        if (a.suggestion) insertSuggestion(db, u.id, a.slug, a.suggestion, 'onboarding');
      }
    });
    return { goalSummary: result.goalSummary, awans: result.awans, suggestions: listSuggestions(db, u.id) };
  });

  app.post('/v1/awans/interview', async (req) => {
    const u = me(req);
    const { messages } = req.body as { messages: { role: 'awan' | 'user'; text: string }[] };
    const transcript = (messages ?? []).map((m) => `${m.role === 'awan' ? 'Awan' : 'User'}: ${m.text}`).join('\n') || '(nothing yet)';
    const out = await completeJson(
      {
        model: llm.models.companion,
        maxTokens: 1800,
        messages: [
          { role: 'system', content: P.NEW_AWAN_INTERVIEW_SYSTEM },
          { role: 'user', content: `Existing Awans: ${listAwans(db, u.id).map((a) => a.slug).join(', ') || 'none'}\n\n${transcript}` },
        ],
      },
      (v) => {
        const o = v as { done?: boolean; say?: unknown; awan?: unknown };
        const say = Array.isArray(o.say) ? o.say.map(String).filter(Boolean) : [];
        if (o.done) return { done: true as const, say, awan: validateAwanSpec(o.awan) };
        if (!say.length) throw new Error('empty say');
        return { done: false as const, say };
      },
    );
    if (out.done) {
      const slug = uniqueSlug(db, u.id, out.awan.slug);
      out.awan.slug = slug;
      saveAwan(db, u.id, out.awan);
    }
    return out;
  });

  app.get('/v1/awans', async (req) => ({ awans: listAwans(db, me(req).id) }));

  app.put('/v1/awans/:slug', async (req, reply) => {
    const { slug } = req.params as { slug: string };
    const spec = validateAwanSpec({ ...(req.body as object), slug });
    saveAwan(db, me(req).id, spec);
    return reply.send({ awan: spec });
  });

  app.delete('/v1/awans/:slug', async (req) => {
    const { slug } = req.params as { slug: string };
    db.prepare('UPDATE awans SET archived_at = ? WHERE user_id = ? AND slug = ?').run(now(), me(req).id, slug);
    return { archived: true };
  });

  // ───────────────────────────── suggestions ─────────────────────────────
  app.get('/v1/suggestions', async (req) => ({ suggestions: listSuggestions(db, me(req).id), lastCheckedAt: lastSuggestionCheck(db, me(req).id) }));

  app.post('/v1/suggestions/refresh', async (req) => {
    const u = me(req);
    const created = await generateSuggestions(db, u.id, 'manual');
    return { created, suggestions: listSuggestions(db, u.id) };
  });

  app.post('/v1/suggestions/:id/decide', async (req, reply) => {
    const { id } = req.params as { id: string };
    const { decision } = req.body as { decision: 'accepted' | 'declined' };
    if (!['accepted', 'declined'].includes(decision)) return reply.code(400).send({ error: 'bad_decision' });
    // Only a pending suggestion can be decided — the WHERE makes a double-tap a no-op.
    const r = db
      .prepare("UPDATE suggestions SET status = ?, decided_at = ? WHERE id = ? AND user_id = ? AND status = 'pending'")
      .run(decision, now(), Number(id), me(req).id);
    if (r.changes === 0) return reply.code(409).send({ error: 'not_pending' });
    return { suggestion: getSuggestion(db, me(req).id, Number(id)) };
  });

  app.post('/v1/suggestions/:id/adjust', async (req, reply) => {
    const { id } = req.params as { id: string };
    const { change } = req.body as { change: string };
    const s = getSuggestion(db, me(req).id, Number(id));
    if (!s || s.status !== 'pending') return reply.code(404).send({ error: 'not_found' });
    const updated = await completeJson(
      {
        model: llm.models.fast,
        messages: [
          { role: 'system', content: P.ADJUST_SUGGESTION_SYSTEM },
          { role: 'user', content: `Current suggestion:\n${JSON.stringify(s)}\n\nUser's change: ${change}` },
        ],
      },
      validateSuggestion,
    );
    db.prepare('UPDATE suggestions SET title = ?, description = ?, agent_prompt = ?, app_hint = ?, routine_every_minutes = ?, routine_title = ? WHERE id = ? AND user_id = ?').run(
      updated.title,
      updated.description,
      updated.agentPrompt,
      updated.appHint ?? null,
      updated.routine?.everyMinutes ?? null,
      updated.routine?.title ?? null,
      Number(id),
      me(req).id,
    );
    return { suggestion: getSuggestion(db, me(req).id, Number(id)) };
  });

  // ───────────────────────────── agents ─────────────────────────────
  /** The app calls this before every agent turn; it is the only place agent quota is spent. */
  app.post('/v1/agents/turns', async (req, reply) => {
    const { threadId, turnRef } = (req.body ?? {}) as { threadId?: string; turnRef?: string };
    if (!turnRef || typeof turnRef !== 'string') return reply.code(400).send({ error: 'turnRef is required' });
    const { used, cap } = consume(db, me(req).id, 'agent_message', `${threadId || 'thread'}:${turnRef}`);
    return { allowed: true, used, cap };
  });

  app.post('/v1/agents/summary', async (req) => {
    const { prompt, finalText, awanName, files } = req.body as { prompt: string; finalText: string; awanName: string; files?: string[] };
    return completeJson(
      {
        model: llm.models.fast,
        maxTokens: 500,
        messages: [
          { role: 'system', content: P.TURN_SUMMARY_SYSTEM },
          { role: 'user', content: `Agent: ${awanName}\nUser asked: ${prompt}\nFiles: ${(files ?? []).join(', ') || 'none'}\nAgent's final answer:\n${finalText.slice(0, 6000)}` },
        ],
      },
      (v) => {
        const o = v as { summary?: string; spoken?: string; nextSteps?: unknown; title?: string };
        if (!o.summary) throw new Error('no summary');
        return {
          summary: String(o.summary),
          spoken: String(o.spoken ?? o.summary),
          nextSteps: Array.isArray(o.nextSteps) ? o.nextSteps.map(String).slice(0, 3) : [],
          title: String(o.title ?? awanName),
        };
      },
    );
  });

  app.get('/v1/agents/instructions', async () => ({ instructions: P.AGENT_MODEL_INSTRUCTIONS }));

  /**
   * Model proxy for the embedded Codex runtime (`model_provider = "awan"`, wire_api = "responses").
   * Auth is the user's Awan token; the provider key never leaves the server.
   */
  app.all('/agent/openai/v1/*', async (req, reply) => {
    const u = me(req);
    const sub = (req.params as { '*': string })['*'];
    if (sub === 'models') return { object: 'list', data: [{ id: 'awan-agent', object: 'model', owned_by: 'ff-dev-studio' }] };
    if (!hasHeadroom(db, u.id, 'agent_message')) return reply.code(402).send({ error: { message: 'Agent message limit reached. Upgrade Awan to keep going.', type: 'quota_exceeded' } });
    if (!llm.apiKey) return reply.code(503).send({ error: { message: 'No model provider configured on the Awan server.' } });
    const body = { ...(req.body as Record<string, unknown>) };
    body.model = mapAgentModel(String(body.model ?? ''));
    sanitizeResponsesRequest(body);
    const upstream = await fetch(`${llm.baseUrl}/${sub}`, {
      method: req.method,
      headers: {
        Authorization: `Bearer ${llm.apiKey}`,
        'Content-Type': 'application/json',
        Accept: (req.headers.accept as string) || 'text/event-stream',
        ...(llm.isOpenRouter ? { 'HTTP-Referer': siteUrl, 'X-Title': 'Awan by FF Dev Studio' } : {}),
      },
      body: req.method === 'GET' ? undefined : JSON.stringify(body),
    });
    reply.hijack();
    const headers: Record<string, string> = { 'Content-Type': upstream.headers.get('content-type') || 'application/json' };
    if (headers['Content-Type'].includes('event-stream')) headers['Cache-Control'] = 'no-cache';
    reply.raw.writeHead(upstream.status, headers);
    if (upstream.body) {
      for await (const chunk of upstream.body as unknown as AsyncIterable<Uint8Array>) reply.raw.write(chunk);
    }
    reply.raw.end();
  });

  // ───────────────────────────── referrals ─────────────────────────────
  app.get('/v1/referrals', async (req) => {
    const u = me(req);
    const referred = db
      .prepare(
        `SELECT u.id, u.display_name, u.avatar_url, u.created_at, s.plan, s.status,
                (SELECT COALESCE(SUM(amount_cents),0) FROM referral_earnings e WHERE e.referred_id = u.id AND e.referrer_id = ?) AS earned,
                (SELECT COUNT(*) FROM referral_earnings e WHERE e.referred_id = u.id AND e.referrer_id = ?) AS months
         FROM users u LEFT JOIN subscriptions s ON s.user_id = u.id
         WHERE u.referred_by = ? AND u.deleted_at IS NULL ORDER BY u.created_at DESC`,
      )
      .all(u.id, u.id, u.id) as { id: string; display_name: string; avatar_url: string | null; created_at: string; plan: string; status: string; earned: number; months: number }[];
    const total = db.prepare('SELECT COALESCE(SUM(amount_cents),0) AS c FROM referral_earnings WHERE referrer_id = ?').get(u.id) as { c: number };
    const self = db.prepare('SELECT referred_by, created_at FROM users WHERE id = ?').get(u.id) as { referred_by: string | null; created_at: string };
    const inviter = self.referred_by
      ? (db.prepare('SELECT referral_handle, display_name FROM users WHERE id = ?').get(self.referred_by) as { referral_handle: string; display_name: string } | undefined)
      : undefined;
    return {
      invitedBy: inviter ? { handle: inviter.referral_handle, name: inviter.display_name } : null,
      canClaim: !self.referred_by && Date.now() - Date.parse(self.created_at) <= REFERRAL_CLAIM_WINDOW_DAYS * 86_400_000,
      handle: u.referral_handle,
      link: `${siteUrl.replace(/^https?:\/\//, '')}/@${u.referral_handle}`,
      url: `${siteUrl}/@${u.referral_handle}`,
      terms: { share: 0.25, friendDiscount: 0.25, months: 12 },
      totalEarnedCents: total.c,
      referrals: referred.map((r) => ({
        name: r.display_name,
        avatarUrl: r.avatar_url,
        plan: r.plan ?? 'free',
        months: r.months,
        earnedCents: r.earned,
        joinedAt: r.created_at,
      })),
    };
  });

  app.patch('/v1/referrals/handle', async (req, reply) => {
    const h = normaliseHandle((req.body as { handle?: string }).handle ?? '');
    if (!isValidHandle(h)) return reply.code(400).send({ error: 'invalid_handle', rule: '3–24 letters, numbers or underscores' });
    try {
      db.prepare('UPDATE users SET referral_handle = ? WHERE id = ?').run(h, me(req).id);
    } catch {
      return reply.code(409).send({ error: 'handle_taken' });
    }
    return { handle: h };
  });

  /**
   * "Were you invited?" — a friend who signed up without the link claims their referrer afterwards.
   * Accepts a handle, "@handle", or the invite link itself. Only once, only on a young account, never yourself.
   */
  app.post('/v1/referrals/claim', async (req, reply) => {
    const u = me(req);
    const raw = String((req.body as { handle?: unknown })?.handle ?? '').trim();
    const handle = normaliseHandle(referralHandleFrom(raw));
    if (!isValidHandle(handle)) return reply.code(400).send({ error: 'invalid_handle' });
    const fresh = db.prepare('SELECT referred_by, created_at, referral_handle FROM users WHERE id = ?').get(u.id) as
      | { referred_by: string | null; created_at: string; referral_handle: string }
      | undefined;
    if (!fresh) return reply.code(401).send({ error: 'unauthorized' });
    if (fresh.referred_by) return reply.code(409).send({ error: 'already_claimed' });
    if (Date.now() - Date.parse(fresh.created_at) > REFERRAL_CLAIM_WINDOW_DAYS * 86_400_000) {
      return reply.code(409).send({ error: 'account_too_old', days: REFERRAL_CLAIM_WINDOW_DAYS });
    }
    if (handle === fresh.referral_handle) return reply.code(400).send({ error: 'self_referral' });
    const referrer = db.prepare('SELECT id, display_name FROM users WHERE referral_handle = ? AND deleted_at IS NULL').get(handle) as
      | { id: string; display_name: string }
      | undefined;
    if (!referrer) return reply.code(400).send({ error: 'unknown_handle' });
    if (referrer.id === u.id) return reply.code(400).send({ error: 'self_referral' });
    // Conditional update so two racing claims can't both win.
    const r = db.prepare('UPDATE users SET referred_by = ? WHERE id = ? AND referred_by IS NULL').run(referrer.id, u.id);
    if (Number(r.changes) === 0) return reply.code(409).send({ error: 'already_claimed' });
    return { ok: true, referrer: { handle, name: referrer.display_name } };
  });

  app.get('/@:handle', async (req, reply) => {
    const { handle } = req.params as { handle: string };
    const exists = db.prepare('SELECT 1 FROM users WHERE referral_handle = ? AND deleted_at IS NULL').get(normaliseHandle(handle));
    return reply.redirect(`${siteUrl}/${exists ? `?ref=${encodeURIComponent(normaliseHandle(handle))}` : ''}`);
  });

  // ───────────────────────────── skills + teams ─────────────────────────────
  registerSkillRoutes(app, db, { skillWriter: opts.skillWriter });
  registerTeamRoutes(app, db, {
    devMode,
    publicUrl,
    stripe,
    userForId: (id) => (db.prepare('SELECT * FROM users WHERE id = ? AND deleted_at IS NULL').get(id) as User | undefined) ?? null,
  });

  // ───────────────────────────── feedback ─────────────────────────────
  app.post('/v1/feedback', async (req, reply) => {
    const { kind, body, diagnostics } = req.body as { kind: 'bug' | 'feature'; body: string; diagnostics?: unknown };
    if (!['bug', 'feature'].includes(kind) || !body?.trim()) return reply.code(400).send({ error: 'bad_feedback' });
    db.prepare('INSERT INTO feedback (user_id, kind, body, diagnostics, created_at) VALUES (?, ?, ?, ?, ?)').run(
      me(req).id,
      kind,
      body.slice(0, 8000),
      diagnostics ? JSON.stringify(diagnostics).slice(0, 200_000) : null,
      now(),
    );
    return { received: true };
  });

  return app;
}

// ───────────────────────────── helpers ─────────────────────────────

/**
 * Skills for a companion turn: the slugs the app sent (only ones this user can see, at most 3), or the
 * account's active set when the app didn't send any.
 */
export function companionSkills(db: DB, userId: string, requested?: unknown): SkillRow[] {
  if (!Array.isArray(requested)) return activeSkills(db, userId);
  return [...new Set(requested.map(String))]
    .slice(0, MAX_ACTIVE_SKILLS)
    .map((slug) => visibleSkill(db, userId, slug))
    .filter((s): s is SkillRow => Boolean(s));
}

/** Fixed-window per-key limiter for signed-out voice previews. */
export class RateLimiter {
  private hits = new Map<string, { n: number; reset: number }>();
  private max: number;
  private windowMs: number;
  constructor(max: number, windowMs: number) {
    this.max = max;
    this.windowMs = windowMs;
  }
  allow(key: string, now = Date.now()): boolean {
    const h = this.hits.get(key);
    if (!h || h.reset <= now) {
      this.hits.set(key, { n: 1, reset: now + this.windowMs });
      return true;
    }
    if (h.n >= this.max) return false;
    h.n++;
    return true;
  }
}
const previewLimiter = new RateLimiter(Number(process.env.SPEECH_PREVIEW_PER_HOUR || 40), 3600_000);

/** Rendered speech on disk: data/speech-cache/<sha256(model|voice|speed|text)>.pcm */
const speechCache = {
  dir: process.env.SPEECH_CACHE_DIR || new URL('../data/speech-cache/', import.meta.url).pathname,
  path(voice: string, speed: number, text: string): string | null {
    if (process.env.SPEECH_CACHE === '0') return null;
    const key = createHash('sha256').update(`${speechModelFor(voice)}|${voice}|${speed}|${text}`).digest('hex');
    return join(this.dir, `${key}.pcm`);
  },
  save(file: string, pcm: Buffer) {
    try {
      mkdirSync(this.dir, { recursive: true });
      writeFileSync(file, pcm);
    } catch {
      /* cache is best-effort */
    }
  },
};

export const DOCUMENT_MAX_CHARS = 60_000;

/** `<document name="…">…</document>` for the companion's user turn (the whole file the user has open). */
export function documentBlock(doc?: { name?: string; text?: string; kind?: string }): string | null {
  const text = doc?.text?.trim();
  if (!text) return null;
  const name = (doc?.name ?? 'document').replace(/["<>\n]/g, ' ').slice(0, 200);
  const cut = text.length > DOCUMENT_MAX_CHARS;
  const body = cut ? `${text.slice(0, DOCUMENT_MAX_CHARS)}\n[…truncated, ${text.length - DOCUMENT_MAX_CHARS} more characters not shown]` : text;
  return `the user has this ${doc?.kind ? `${doc.kind} ` : ''}open in the front window; its full text is below. use it when they ask about it.\n<document name="${name}">\n${body}\n</document>`;
}

type ChatContent = ChatMessage['content'];

/** Text that is safe to speak: everything before an unfinished trailing `[` tag. */
export function safePrefix(s: string): string {
  // A [TYPE]…[/TYPE] block is never spoken: drop finished ones, and hold everything from an open one.
  s = s.replace(/\[TYPE(?::[^\]]*)?\][\s\S]*?\[\/TYPE\]/gi, '');
  const open = s.search(/\[TYPE(?::[^\]]*)?\]/i);
  if (open >= 0) s = s.slice(0, open);
  const i = s.lastIndexOf('[');
  const head = i >= 0 && !s.slice(i).includes(']') ? s.slice(0, i).replace(/\s+$/, s.slice(0, i).endsWith(' ') ? ' ' : '') : s;
  return head.replace(/\s*\[(POINT|AGENT|HIGHLIGHT|SHAPE|TARGET|HOVER|IMAGES|TYPE):[^\]]*\]/g, '');
}

/**
 * The reference routes every question: quick ones to a fast model, deep or screen-heavy ones to a frontier
 * model. Ours: explicit depth words, long questions and "on my screen" questions go deep; the rest go fast.
 */
export function routeCompanionModel(transcript: string, hasImages: boolean, onboardingDemo = false): string {
  if (onboardingDemo) return llm.models.fast;
  const t = transcript.toLowerCase();
  const deep = /\b(explain|why|how (do|does|can|would)|walk me|step by step|teach|compare|debug|fix|analy[sz]e|review|in detail|go deeper|elaborate|write|draft|plan)\b/.test(t);
  const screen = hasImages && /\b(this|here|screen|see|looking at|where('| i)s|click|button|menu|find)\b/.test(t);
  if (deep || screen || t.length > 140) return llm.models.companion;
  return llm.models.fast;
}

function mapAgentModel(requested: string) {
  if (!requested || requested === 'awan-agent' || requested.startsWith('awan')) return llm.models.agent;
  if (llm.isOpenRouter && !requested.includes('/')) return `openai/${requested}`;
  return requested;
}

/** Drop request fields some OpenAI-compatible providers reject. */
function sanitizeResponsesRequest(body: Record<string, unknown>) {
  if (!llm.isOpenRouter) return;
  delete body.prompt_cache_key;
  delete body.client_metadata;
  if (Array.isArray(body.include)) body.include = (body.include as string[]).filter((x) => x === 'reasoning.encrypted_content');
}

function saveAwan(db: DB, userId: string, a: AwanSpec) {
  db.prepare(
    `INSERT INTO awans (user_id, slug, name, role_text, one_liner, spec_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id, slug) DO UPDATE SET name = excluded.name, role_text = excluded.role_text, one_liner = excluded.one_liner, spec_json = excluded.spec_json, archived_at = NULL`,
  ).run(userId, a.slug, a.name, a.roleText, a.oneLiner, JSON.stringify(a), now());
}

function listAwans(db: DB, userId: string): AwanSpec[] {
  return (db.prepare('SELECT spec_json FROM awans WHERE user_id = ? AND archived_at IS NULL ORDER BY created_at').all(userId) as { spec_json: string }[]).map(
    (r) => JSON.parse(r.spec_json),
  );
}

function uniqueSlug(db: DB, userId: string, slug: string) {
  let s = slug;
  for (let i = 2; db.prepare('SELECT 1 FROM awans WHERE user_id = ? AND slug = ? AND archived_at IS NULL').get(userId, s); i++) s = `${slug}-${i}`;
  return s;
}

function insertSuggestion(db: DB, userId: string, slug: string, s: SuggestionSpec, reason: 'onboarding' | 'morning' | 'manual') {
  db.prepare(
    `INSERT INTO suggestions (user_id, awan_slug, title, description, agent_prompt, app_hint, routine_every_minutes, routine_title, check_reason, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(userId, slug, s.title, s.description, s.agentPrompt, s.appHint ?? null, s.routine?.everyMinutes ?? null, s.routine?.title ?? null, reason, now());
}

type SuggestionRow = {
  id: number;
  awan_slug: string;
  title: string;
  description: string;
  agent_prompt: string;
  app_hint: string | null;
  routine_every_minutes: number | null;
  routine_title: string | null;
  check_reason: string;
  status: string;
  created_at: string;
};

function shapeSuggestion(r: SuggestionRow) {
  return {
    id: r.id,
    awanSlug: r.awan_slug,
    title: r.title,
    description: r.description,
    agentPrompt: r.agent_prompt,
    appHint: r.app_hint,
    routine: r.routine_every_minutes ? { everyMinutes: r.routine_every_minutes, title: r.routine_title } : null,
    checkReason: r.check_reason,
    status: r.status,
    createdAt: r.created_at,
  };
}

function listSuggestions(db: DB, userId: string) {
  return (db.prepare("SELECT * FROM suggestions WHERE user_id = ? AND status = 'pending' ORDER BY id").all(userId) as SuggestionRow[]).map(shapeSuggestion);
}

function getSuggestion(db: DB, userId: string, id: number) {
  const r = db.prepare('SELECT * FROM suggestions WHERE id = ? AND user_id = ?').get(id, userId) as SuggestionRow | undefined;
  return r ? shapeSuggestion(r) : null;
}

function lastSuggestionCheck(db: DB, userId: string): string | null {
  const r = db.prepare('SELECT MAX(created_at) AS t FROM suggestions WHERE user_id = ?').get(userId) as { t: string | null };
  return r.t;
}

/** Generates up to three fresh suggestions for the user's Awans. Exported for the morning job. */
export async function generateSuggestions(db: DB, userId: string, reason: 'morning' | 'manual'): Promise<number> {
  const awans = listAwans(db, userId);
  if (!awans.length) return 0;
  const profile = db.prepare('SELECT goal_summary FROM profiles WHERE user_id = ?').get(userId) as { goal_summary: string | null } | undefined;
  const past = (db.prepare('SELECT title FROM suggestions WHERE user_id = ? ORDER BY id DESC LIMIT 30').all(userId) as { title: string }[]).map((r) => r.title);
  const out = await completeJson(
    {
      model: llm.models.fast,
      maxTokens: 2500,
      messages: [
        { role: 'system', content: P.SUGGESTIONS_SYSTEM },
        {
          role: 'user',
          content: `User goal: ${profile?.goal_summary ?? 'unknown'}\nToday: ${new Date().toDateString()}\nAwans:\n${awans.map((a) => `- ${a.slug}: ${a.name} (${a.roleText}) — ${a.oneLiner}`).join('\n')}\nAlready suggested (don't repeat):\n${past.map((t) => `- ${t}`).join('\n') || 'none'}`,
        },
      ],
    },
    (v) => {
      const o = v as { suggestions?: unknown[] };
      if (!Array.isArray(o.suggestions)) throw new Error('no suggestions');
      return o.suggestions.slice(0, 3).map((s) => ({ slug: String((s as { awanSlug?: string }).awanSlug), spec: validateSuggestion(s) }));
    },
  );
  const slugs = new Set(awans.map((a) => a.slug));
  let n = 0;
  tx(db, () => {
    db.prepare("UPDATE suggestions SET status = 'expired' WHERE user_id = ? AND status = 'pending' AND check_reason != 'onboarding'").run(userId);
    for (const s of out) {
      if (!slugs.has(s.slug)) continue;
      insertSuggestion(db, userId, s.slug, s.spec, reason);
      n++;
    }
  });
  return n;
}

/** Referral share: 25% of each paid invoice for the referred user's first 12 months. */
export function recordReferralEarning(db: DB, referredUserId: string, invoiceRef: string, paidCents: number) {
  const u = db.prepare('SELECT referred_by, created_at FROM users WHERE id = ?').get(referredUserId) as { referred_by: string | null; created_at: string } | undefined;
  if (!u?.referred_by) return;
  const months = (db.prepare('SELECT COUNT(*) AS n FROM referral_earnings WHERE referred_id = ?').get(referredUserId) as { n: number }).n;
  if (months >= 12) return;
  db.prepare('INSERT OR IGNORE INTO referral_earnings (referrer_id, referred_id, invoice_ref, amount_cents, created_at) VALUES (?, ?, ?, ?, ?)').run(
    u.referred_by,
    referredUserId,
    invoiceRef,
    Math.floor(paidCents * 0.25),
    now(),
  );
}

export const REFERRAL_CLAIM_WINDOW_DAYS = 30;

/** "@sam", "sam", "awan.ffdev.studio/@sam" or "https://…/?ref=sam" → "sam" (not yet normalised). */
export function referralHandleFrom(raw: string): string {
  const s = raw.trim();
  const ref = /[?&]ref=([^&#\s]+)/i.exec(s);
  if (ref) return decodeURIComponent(ref[1]);
  const at = /@([A-Za-z0-9_]+)\/?\s*$/.exec(s);
  if (at) return at[1];
  return s.replace(/^@/, '');
}

function esc(s: string) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
}

/** Minimal branded page used by auth/billing hand-offs. */
function page(title: string, body: string, openUrl?: string) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)} · Awan</title>
<style>:root{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0B0B0A;color:#F3EFE4;font:16px/1.5 "Instrument Sans",-apple-system,system-ui,sans-serif}
main{max-width:420px;padding:32px;text-align:center}h1{font-weight:600;font-size:28px;margin:18px 0 8px}p{color:#8B8981;margin:0 0 24px}
a.btn{display:inline-block;background:#D9FF43;color:#0B0B0A;text-decoration:none;font-weight:600;padding:12px 22px;border-radius:999px}
.mark{font-weight:700;letter-spacing:-.02em;color:#8B8981}</style></head>
<body><main><div class="mark">//FF · Awan</div><h1>${esc(title)}</h1><p>${esc(body)}</p>${openUrl ? `<a class="btn" href="${esc(openUrl)}">Open Awan</a><script>setTimeout(()=>{location.href=${JSON.stringify(openUrl)}},300)</script>` : ''}</main></body></html>`;
}

function devCheckoutPage(plan: string, interval: string, cents: number, token: string) {
  const name = plan === 'pro' ? 'Awan Pro' : 'Awan Max';
  return `<!doctype html><html><head><meta charset="utf-8"><title>Checkout · ${name}</title>
<style>:root{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0B0B0A;color:#F3EFE4;font:16px/1.5 -apple-system,system-ui,sans-serif}
form{background:#242421;border-radius:20px;padding:32px;width:360px}h1{margin:0 0 4px;font-size:22px}.p{font-size:40px;font-weight:700;margin:16px 0}.m{color:#8B8981;font-size:13px}
button{width:100%;margin-top:20px;background:#D9FF43;color:#0B0B0A;border:0;border-radius:999px;padding:14px;font-weight:700;font-size:15px;cursor:pointer}</style></head>
<body><form method="post" action="/billing/dev-checkout"><div class="m">Test mode — no card is charged</div><h1>${name}</h1>
<div class="p">$${(cents / 100).toFixed(0)}<span class="m"> / ${interval === 'year' ? 'year' : 'month'}</span></div>
<input type="hidden" name="plan" value="${esc(plan)}"><input type="hidden" name="interval" value="${esc(interval)}"><input type="hidden" name="token" value="${esc(token)}">
<button type="submit">Subscribe (test)</button></form></body></html>`;
}
