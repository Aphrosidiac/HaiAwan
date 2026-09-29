import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp } from '../src/app.ts';
import { openDb } from '../src/db.ts';
import type { FetchLike } from '../src/connectors.ts';
import { jsonRpcFromBody } from '../src/composio.ts';

process.env.LOG = '0';

const KEY = 'ak_test_project_key';
const BASE = 'https://composio.test/api/v3.1';

type Account = { id: string; user_id: string; toolkit: string; status: string; auth_config_id: string };

/** A stand-in for Composio's v3.1 REST API and its session MCP endpoint. No real network. */
function fakeComposio() {
  const state = {
    accounts: [] as Account[],
    authConfigs: [] as { id: string; toolkit: string }[],
    sessions: new Map<string, { user_id: string; body: any }>(),
    calls: [] as { method: string; path: string; query: URLSearchParams; body: any; headers: Record<string, string> }[],
    links: [] as { callback_url: string; user_id: string }[],
    n: 0,
  };
  const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
  const toolkit = (slug: string, name: string, extra: Record<string, unknown> = {}) => ({
    slug,
    name,
    type: 'native',
    auth_schemes: ['OAUTH2'],
    composio_managed_auth_schemes: ['OAUTH2'],
    no_auth: false,
    deprecated: { toolkitId: slug },
    meta: { description: `${name} for agents`, logo: `https://logos.composio.dev/api/${slug}`, categories: [{ id: 'productivity', name: 'Productivity' }], tools_count: 42, triggers_count: 3, version: '20260901_00' },
    ...extra,
  });
  const pages = [
    [toolkit('gmail', 'Gmail'), toolkit('slack', 'Slack'), toolkit('composio_search', 'Search', { no_auth: true, composio_managed_auth_schemes: [] })],
    [toolkit('notion', 'Notion'), toolkit('byo_only', 'Bring Your Own', { composio_managed_auth_schemes: [] }), toolkit('googlecalendar', 'Google Calendar')],
  ];
  const fetch: FetchLike = async (input, init = {}) => {
    const url = new URL(String(input));
    const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>).map(([k, v]) => [k.toLowerCase(), v]));
    const method = init.method ?? 'GET';
    const body = typeof init.body === 'string' && init.body ? JSON.parse(init.body) : undefined;
    const path = url.pathname.replace('/api/v3.1', '');
    state.calls.push({ method, path, query: url.searchParams, body, headers });
    if (headers['x-api-key'] !== KEY) return json(401, { error: { message: 'Invalid API key', code: 401, slug: 'unauthorized', status: 401 } });

    // ── session MCP endpoint ──
    const mcp = /^\/tool_router\/(trs_\d+)\/mcp$/.exec(url.pathname);
    if (mcp) {
      const s = state.sessions.get(mcp[1]);
      if (!s) return json(404, { error: { message: 'session not found' } });
      if (method !== 'POST') return new Response(null, { status: 405 });
      if (body.method === 'initialize') return json(200, { jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-06-18', serverInfo: { name: 'composio' }, capabilities: { tools: {} } } }, { 'mcp-session-id': `mcp-${mcp[1]}` });
      if (body.method === 'tools/list') {
        const tools = [{ name: 'COMPOSIO_SEARCH_TOOLS' }, { name: 'COMPOSIO_GET_TOOL_SCHEMAS' }, ...s.body.toolkits.enable.map((t: string) => ({ name: `${t.toUpperCase()}_LIST` }))];
        return json(200, { jsonrpc: '2.0', id: body.id, result: { tools, forUser: s.user_id } });
      }
      if (body.method === 'tools/call' && body.params.name === 'COMPOSIO_GET_TOOL_SCHEMAS') {
        const payload = { jsonrpc: '2.0', id: body.id, result: { content: [{ type: 'text', text: JSON.stringify({ SLACK_SEND_MESSAGE: { channel: 'string', markdown_text: 'string' } }) }] } };
        return new Response(`event: message\ndata: ${JSON.stringify(payload)}\n\n`, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
      }
      return json(200, { jsonrpc: '2.0', id: body.id, error: { code: -32601, message: 'nope' } });
    }

    if (path === '/toolkits' && method === 'GET') {
      const i = url.searchParams.get('cursor') ? 1 : 0;
      return json(200, { items: pages[i], next_cursor: i === 0 ? 'cGFnZT0y' : null, total_pages: 2, current_page: i + 1, total_items: 6 });
    }
    if (path === '/auth_configs' && method === 'GET') {
      return json(200, { items: state.authConfigs.filter((c) => c.toolkit === url.searchParams.get('toolkit_slug')).map((c) => ({ id: c.id, toolkit: { slug: c.toolkit }, is_composio_managed: true, status: 'ENABLED' })), next_cursor: null });
    }
    if (path === '/auth_configs' && method === 'POST') {
      const id = `ac_${body.toolkit.slug}_${++state.n}`;
      state.authConfigs.push({ id, toolkit: body.toolkit.slug });
      return json(201, { toolkit: { slug: body.toolkit.slug }, auth_config: { id, auth_scheme: 'OAUTH2', is_composio_managed: body.auth_config.type === 'use_composio_managed_auth' } });
    }
    if (path === '/connected_accounts/link' && method === 'POST') {
      const cfg = state.authConfigs.find((c) => c.id === body.auth_config_id);
      if (!cfg) return json(404, { error: { message: 'auth config not found' } });
      const id = `ca_${++state.n}`;
      state.accounts.push({ id, user_id: body.user_id, toolkit: cfg.toolkit, status: 'INITIATED', auth_config_id: cfg.id });
      state.links.push({ callback_url: body.callback_url, user_id: body.user_id });
      return json(201, { link_token: `lk_${id}`, redirect_url: `https://connect.composio.test/link/lk_${id}`, expires_at: '2026-09-29T12:00:00Z', connected_account_id: id });
    }
    if (path === '/connected_accounts' && method === 'GET') {
      const users = url.searchParams.getAll('user_ids');
      const kits = url.searchParams.getAll('toolkit_slugs');
      const items = state.accounts
        .filter((a) => (!users.length || users.includes(a.user_id)) && (!kits.length || kits.includes(a.toolkit)))
        .map((a) => ({ id: a.id, toolkit: { slug: a.toolkit }, auth_config: { id: a.auth_config_id, is_composio_managed: true }, status: a.status, is_disabled: false, created_at: '2026-09-29T00:00:00Z', updated_at: '2026-09-29T00:00:00Z' }));
      return json(200, { items, next_cursor: null });
    }
    const del = /^\/connected_accounts\/(ca_\d+)$/.exec(path);
    if (del && method === 'DELETE') {
      const before = state.accounts.length;
      state.accounts = state.accounts.filter((a) => a.id !== del[1]);
      return json(before === state.accounts.length ? 404 : 200, { success: true });
    }
    if (path === '/tool_router/session' && method === 'POST') {
      const id = `trs_${++state.n}`;
      state.sessions.set(id, { user_id: body.user_id, body });
      return json(201, { session_id: id, mcp: { type: 'http', url: `https://composio.test/tool_router/${id}/mcp` }, tool_router_tools: ['COMPOSIO_SEARCH_TOOLS'], config: { user_id: body.user_id }, config_version: 1 });
    }
    const tool = /^\/tools\/([A-Z_]+)$/.exec(path);
    if (tool) return json(200, { slug: tool[1], name: 'Send message', description: 'Posts a message', toolkit: { slug: 'slack', name: 'Slack', logo: '' }, input_parameters: { type: 'object', properties: { channel: { type: 'string' } }, required: ['channel'] }, output_parameters: {} });
    return json(404, { error: { message: `no fake for ${method} ${path}` } });
  };
  const activate = (userId: string, toolkit: string) => state.accounts.filter((a) => a.user_id === userId && a.toolkit === toolkit).forEach((a) => (a.status = 'ACTIVE'));
  return { fetch, state, activate };
}

async function setup(opts: { configured?: boolean } = {}) {
  const db = openDb(':memory:');
  const fake = fakeComposio();
  let t = Date.parse('2026-09-29T08:00:00Z');
  const clock = { now: () => t, advance: (ms: number) => (t += ms) };
  const app = await buildApp({
    db,
    devMode: true,
    publicUrl: 'http://api.test',
    siteUrl: 'http://site.test',
    mailer: null,
    googleClient: null,
    connectorKey: null,
    composioApiKey: opts.configured === false ? null : KEY,
    composioFetch: fake.fetch,
    composioBase: BASE,
    clock: clock.now,
  });
  return { db, app, fake, clock };
}

async function signIn(app: Awaited<ReturnType<typeof setup>>['app'], email: string) {
  const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email } });
  const code = new URL(r.json().devLink).searchParams.get('code')!;
  const v = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
  const token = decodeURIComponent(/token=([^"&]+)/.exec(v.body)![1]);
  const headers = { authorization: `Bearer ${token}` };
  const id = (await app.inject({ method: 'GET', url: '/v1/me', headers })).json().user.id as string;
  return { headers, id };
}

/** Runs the whole connect round trip for one user and toolkit (the user finishing OAuth is `activate`). */
async function connect(ctx: Awaited<ReturnType<typeof setup>>, user: { headers: Record<string, string>; id: string }, toolkit: string) {
  const r = await ctx.app.inject({ method: 'POST', url: '/v1/composio/connect', headers: user.headers, payload: { toolkit } });
  assert.equal(r.statusCode, 200, r.body);
  ctx.fake.activate(user.id, toolkit);
  const cb = new URL(ctx.fake.state.links.at(-1)!.callback_url);
  return ctx.app.inject({ method: 'GET', url: `${cb.pathname}${cb.search}&status=success&connected_account_id=x` });
}

const openUrl = (html: string) => JSON.parse(/location\.href=("[^"]+")/.exec(html)![1]) as string;

test('composio: without COMPOSIO_API_KEY every route is a clear 501 and the feature flag is off', async () => {
  const { app, fake } = await setup({ configured: false });
  const u = await signIn(app, 'off@b.co');
  const cfg = (await app.inject({ method: 'GET', url: '/v1/config' })).json();
  assert.equal(cfg.features.composio, false);
  for (const [method, url] of [
    ['GET', '/v1/composio/toolkits'],
    ['POST', '/v1/composio/connect'],
    ['GET', '/v1/composio/connections'],
    ['POST', '/v1/composio/disconnect'],
    ['POST', '/v1/composio/session'],
  ] as const) {
    const r = await app.inject({ method, url, headers: u.headers, payload: method === 'POST' ? { toolkit: 'slack' } : undefined });
    assert.equal(r.statusCode, 501, url);
    assert.equal(r.json().error, 'composio_not_configured', url);
  }
  const mcp = await app.inject({ method: 'POST', url: '/mcp/composio', headers: u.headers, payload: { jsonrpc: '2.0', id: 1, method: 'tools/list' } });
  assert.equal(mcp.statusCode, 501);
  assert.equal(fake.state.calls.length, 0, 'nothing reaches Composio');
  const on = await setup();
  assert.equal((await on.app.inject({ method: 'GET', url: '/v1/config' })).json().features.composio, true);
});

test('composio: catalogue is the connectable toolkits across pages, shaped for the app, cached for an hour', async () => {
  const { app, fake, clock } = await setup();
  const u = await signIn(app, 'cat@b.co');
  assert.equal((await app.inject({ method: 'GET', url: '/v1/composio/toolkits' })).statusCode, 401, 'signed-in only');
  const r = await app.inject({ method: 'GET', url: '/v1/composio/toolkits', headers: u.headers });
  assert.equal(r.statusCode, 200);
  const { toolkits } = r.json();
  assert.deepEqual(toolkits.map((t: { slug: string }) => t.slug), ['gmail', 'slack', 'notion', 'googlecalendar'], 'no-auth and bring-your-own-only toolkits are left out');
  assert.deepEqual(toolkits[1], {
    slug: 'slack',
    name: 'Slack',
    description: 'Slack for agents',
    logo: 'https://logos.composio.dev/api/slack',
    categories: ['Productivity'],
    toolsCount: 42,
    authSchemes: ['OAUTH2'],
  });
  const listCalls = () => fake.state.calls.filter((c) => c.path === '/toolkits').length;
  assert.equal(listCalls(), 2, 'two pages');
  assert.equal(fake.state.calls[0].query.get('managed_by'), 'composio');
  await app.inject({ method: 'GET', url: '/v1/composio/toolkits', headers: u.headers });
  assert.equal(listCalls(), 2, 'second read is cached');
  clock.advance(61 * 60_000);
  await app.inject({ method: 'GET', url: '/v1/composio/toolkits', headers: u.headers });
  assert.equal(listCalls(), 4, 'refetched after an hour');
});

test('composio: connect returns the hosted page, reuses one managed auth config, and bounces back to awan://', async () => {
  const ctx = await setup();
  const { app, fake } = ctx;
  const u = await signIn(app, 'conn@b.co');
  assert.equal((await app.inject({ method: 'POST', url: '/v1/composio/connect', headers: u.headers, payload: { toolkit: 'not-a-kit' } })).statusCode, 400);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/composio/connect', headers: u.headers, payload: { toolkit: '../etc' } })).statusCode, 400);
  const r = await app.inject({ method: 'POST', url: '/v1/composio/connect', headers: u.headers, payload: { toolkit: 'Slack' } });
  assert.equal(r.statusCode, 200);
  assert.match(r.json().redirectUrl, /^https:\/\/connect\.composio\.test\/link\//);
  assert.equal(r.json().toolkit, 'slack');
  const created = fake.state.calls.filter((c) => c.path === '/auth_configs' && c.method === 'POST');
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].body, { toolkit: { slug: 'slack' }, auth_config: { type: 'use_composio_managed_auth' } });
  const link = fake.state.calls.find((c) => c.path === '/connected_accounts/link')!;
  assert.equal(link.body.user_id, u.id, 'Composio user id = our user id');
  assert.match(link.body.callback_url, /^http:\/\/api\.test\/v1\/composio\/callback\?state=/);

  // The user closes the tab before finishing: Composio has no ACTIVE account, so nothing is claimed.
  const cb = new URL(fake.state.links[0].callback_url);
  const early = await app.inject({ method: 'GET', url: `${cb.pathname}${cb.search}&status=success` });
  assert.equal(new URL(openUrl(early.body)).searchParams.get('error'), 'not_active');
  assert.equal((await app.inject({ method: 'GET', url: `${cb.pathname}${cb.search}` })).statusCode, 400, 'state is single use');

  // Second attempt, finished: the same auth config is reused, the page opens awan://connectors?connected=slack.
  const done = await connect(ctx, u, 'slack');
  assert.equal(done.statusCode, 200);
  const back = new URL(openUrl(done.body));
  assert.equal(back.protocol, 'awan:');
  assert.equal(back.host, 'connectors');
  assert.equal(back.searchParams.get('connected'), 'slack');
  assert.equal(back.searchParams.get('source'), 'composio');
  assert.equal(fake.state.calls.filter((c) => c.path === '/auth_configs' && c.method === 'POST').length, 1, 'auth config created once');
  // A failed OAuth comes back as an error the app can explain.
  await app.inject({ method: 'POST', url: '/v1/composio/connect', headers: u.headers, payload: { toolkit: 'notion' } });
  const nb = new URL(fake.state.links.at(-1)!.callback_url);
  const failed = await app.inject({ method: 'GET', url: `${nb.pathname}${nb.search}&status=failed` });
  assert.equal(new URL(openUrl(failed.body)).searchParams.get('error'), 'failed');
});

test('composio: connections and disconnect are per user', async () => {
  const ctx = await setup();
  const { app, fake } = ctx;
  const a = await signIn(app, 'a@b.co');
  const b = await signIn(app, 'b@b.co');
  await connect(ctx, a, 'slack');
  await connect(ctx, a, 'notion');
  await app.inject({ method: 'POST', url: '/v1/composio/connect', headers: b.headers, payload: { toolkit: 'slack' } }); // b never finishes

  const la = (await app.inject({ method: 'GET', url: '/v1/composio/connections', headers: a.headers })).json();
  assert.deepEqual(Object.keys(la.toolkits).sort(), ['notion', 'slack']);
  assert.equal(la.toolkits.slack.connected, true);
  const lb = (await app.inject({ method: 'GET', url: '/v1/composio/connections', headers: b.headers })).json();
  assert.deepEqual(lb.toolkits, { slack: { connected: false, status: 'INITIATED' } }, 'b only sees b’s pending account');
  assert.ok(fake.state.calls.filter((c) => c.path === '/connected_accounts' && c.method === 'GET').every((c) => c.query.get('user_ids')), 'every listing is filtered by user');

  const bd = (await app.inject({ method: 'POST', url: '/v1/composio/disconnect', headers: b.headers, payload: { toolkit: 'slack' } })).json();
  assert.equal(bd.removed, 1, 'b removes only b’s own account');
  assert.equal(fake.state.accounts.filter((x) => x.user_id === a.id).length, 2, 'a keeps both');
  const del = fake.state.calls.find((c) => c.method === 'DELETE')!;
  assert.equal(del.query.get('revoke_on_delete'), 'true', 'the grant is revoked upstream too');
  await app.inject({ method: 'POST', url: '/v1/composio/disconnect', headers: a.headers, payload: { toolkit: 'slack' } });
  const after = (await app.inject({ method: 'GET', url: '/v1/composio/connections', headers: a.headers })).json();
  assert.deepEqual(Object.keys(after.toolkits), ['notion']);
});

test('composio: session hands out Awan’s proxy URL (no Composio secret) and the proxy reaches only the caller’s session', async () => {
  const ctx = await setup();
  const { app, fake } = ctx;
  const a = await signIn(app, 'sa@b.co');
  const b = await signIn(app, 'sb@b.co');
  await connect(ctx, a, 'slack');
  await connect(ctx, b, 'notion');

  const s = await app.inject({ method: 'POST', url: '/v1/composio/session', headers: a.headers, payload: {} });
  assert.equal(s.statusCode, 200);
  assert.deepEqual({ ...s.json(), sessionId: undefined }, { mcpUrl: 'http://api.test/mcp/composio', bearerTokenEnvVar: 'AWAN_AGENT_TOKEN', headers: {}, toolkits: ['slack'], sessionId: undefined });
  assert.doesNotMatch(s.body, new RegExp(KEY), 'the project key never leaves the server');
  assert.doesNotMatch(s.body, /composio\.test/, 'nor the upstream MCP URL');
  const made = fake.state.calls.find((c) => c.path === '/tool_router/session')!;
  assert.equal(made.body.user_id, a.id);
  assert.deepEqual(made.body.toolkits, { enable: ['slack'] });
  assert.deepEqual(made.body.manage_connections, { enable: false }, 'agents never start OAuth');
  const again = (await app.inject({ method: 'POST', url: '/v1/composio/session', headers: a.headers, payload: {} })).json();
  assert.equal(again.sessionId, s.json().sessionId, 'reused until the connected set changes');

  assert.equal((await app.inject({ method: 'POST', url: '/mcp/composio', payload: { jsonrpc: '2.0', id: 1, method: 'tools/list' } })).statusCode, 401);
  const init = await app.inject({ method: 'POST', url: '/mcp/composio', headers: a.headers, payload: { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} } });
  assert.equal(init.statusCode, 200);
  assert.equal(init.headers['mcp-session-id'], `mcp-${s.json().sessionId}`, 'the MCP session header is passed through');
  const la = await app.inject({ method: 'POST', url: '/mcp/composio', headers: a.headers, payload: { jsonrpc: '2.0', id: 2, method: 'tools/list' } });
  assert.equal(la.json().result.forUser, a.id);
  assert.ok(la.json().result.tools.some((t: { name: string }) => t.name === 'SLACK_LIST'));
  const lb = await app.inject({ method: 'POST', url: '/mcp/composio', headers: b.headers, payload: { jsonrpc: '2.0', id: 2, method: 'tools/list' } });
  assert.equal(lb.json().result.forUser, b.id);
  assert.ok(!lb.json().result.tools.some((t: { name: string }) => t.name === 'SLACK_LIST'), 'b can’t reach a’s Slack');
  const upstream = fake.state.calls.filter((c) => c.path.includes('/mcp'));
  assert.ok(upstream.every((c) => c.headers['x-api-key'] === KEY), 'the proxy adds the key upstream');
  assert.ok(upstream.every((c) => !c.headers.authorization), 'the user’s Awan token is not forwarded to Composio');

  // Connecting another toolkit makes the next session include it.
  await connect(ctx, a, 'notion');
  const s2 = (await app.inject({ method: 'POST', url: '/v1/composio/session', headers: a.headers, payload: {} })).json();
  assert.deepEqual(s2.toolkits, ['notion', 'slack']);
  assert.notEqual(s2.sessionId, s.json().sessionId);
});

test('composio: tool schemas are cached for ten minutes (REST and COMPOSIO_GET_TOOL_SCHEMAS through the proxy)', async () => {
  const ctx = await setup();
  const { app, fake, clock } = ctx;
  const a = await signIn(app, 'schema@b.co');
  await connect(ctx, a, 'slack');
  const one = await app.inject({ method: 'GET', url: '/v1/composio/tools/SLACK_SEND_MESSAGE/schema', headers: a.headers });
  assert.equal(one.statusCode, 200);
  assert.deepEqual(one.json().tool.inputParameters.required, ['channel']);
  await app.inject({ method: 'GET', url: '/v1/composio/tools/SLACK_SEND_MESSAGE/schema', headers: a.headers });
  const restCalls = () => fake.state.calls.filter((c) => c.path === '/tools/SLACK_SEND_MESSAGE').length;
  assert.equal(restCalls(), 1);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/composio/tools/..%2Fx/schema', headers: a.headers })).statusCode, 400);

  const call = (id: number) =>
    app.inject({ method: 'POST', url: '/mcp/composio', headers: a.headers, payload: { jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'COMPOSIO_GET_TOOL_SCHEMAS', arguments: { tool_slugs: ['SLACK_SEND_MESSAGE'] } } } });
  const first = await call(7);
  assert.equal(first.statusCode, 200);
  assert.match(first.body, /markdown_text/);
  const second = await call(8);
  assert.equal(second.json().id, 8, 'a cached answer carries the new request id');
  assert.match(JSON.stringify(second.json().result), /markdown_text/);
  const metaCalls = () => fake.state.calls.filter((c) => c.path.includes('/mcp') && c.body?.params?.name === 'COMPOSIO_GET_TOOL_SCHEMAS').length;
  assert.equal(metaCalls(), 1, 'the second schema read never left the server');
  clock.advance(11 * 60_000);
  await call(9);
  assert.equal(metaCalls(), 2, 'expired after ten minutes');
  assert.deepEqual(jsonRpcFromBody('event: message\ndata: {"jsonrpc":"2.0","id":3,"result":{"ok":1}}\n\n', 'text/event-stream', 3).result, { ok: 1 });
});

test('agent instructions: composio route first, exact schema keys, read-back, never OAuth from the agent', async () => {
  const { app } = await setup();
  const u = await signIn(app, 'instr@b.co');
  const text = (await app.inject({ method: 'GET', url: '/v1/agents/instructions', headers: u.headers })).json().instructions as string;
  assert.match(text, /`composio`/);
  assert.match(text, /COMPOSIO_GET_TOOL_SCHEMAS once/);
  assert.match(text, /read the result back/);
  assert.match(text, /no OAuth[\s\S]*Settings → Integrations/);
});
