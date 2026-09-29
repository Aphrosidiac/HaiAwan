import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { buildApp } from '../src/app.ts';
import { openDb } from '../src/db.ts';
import { openToken, parseConnectorKey, parseToolkits, sealToken, type FetchLike } from '../src/connectors.ts';
import { buildMime, freeSlots, GOOGLE_MCP_SERVERS, zonedToUtc } from '../src/google-tools.ts';
import { validateArgs } from '../src/mcp.ts';

process.env.LOG = '0';

const KEY = randomBytes(32).toString('base64');
const SCOPE_GMAIL = 'https://www.googleapis.com/auth/gmail.modify';
const SCOPE_CAL = 'https://www.googleapis.com/auth/calendar';

type Call = { method: string; url: URL; headers: Record<string, string>; body: string };

/** A stand-in for accounts.google.com + the Workspace REST APIs. No real network. */
function fakeGoogle(opts: { grantScopes?: string } = {}) {
  const calls: Call[] = [];
  const state = { validAccess: new Set<string>(), issued: 0, refreshes: 0, revoked: [] as string[], drafts: [] as { raw: string; threadId?: string }[] };
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  const fetch: FetchLike = async (input, init = {}) => {
    const url = new URL(String(input));
    const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>).map(([k, v]) => [k.toLowerCase(), v]));
    const body = typeof init.body === 'string' ? init.body : init.body ? Buffer.from(init.body as Uint8Array).toString('utf8') : '';
    const method = init.method ?? 'GET';
    calls.push({ method, url, headers, body });
    if (url.href === 'https://oauth2.googleapis.com/token') {
      const f = new URLSearchParams(body);
      if (f.get('grant_type') === 'authorization_code') {
        if (f.get('code') !== 'good-code') return json(400, { error: 'invalid_grant' });
        const at = `at-${++state.issued}`;
        state.validAccess.add(at);
        return json(200, { access_token: at, refresh_token: 'rt-secret-1', expires_in: 3600, scope: opts.grantScopes ?? `openid email ${SCOPE_GMAIL} ${SCOPE_CAL}` });
      }
      if (f.get('grant_type') === 'refresh_token') {
        if (f.get('refresh_token') !== 'rt-secret-1') return json(400, { error: 'invalid_grant' });
        state.refreshes++;
        const at = `at-${++state.issued}`;
        state.validAccess.add(at);
        return json(200, { access_token: at, expires_in: 3600 });
      }
    }
    if (url.href === 'https://oauth2.googleapis.com/revoke') {
      state.revoked.push(new URLSearchParams(body).get('token') ?? '');
      return new Response('', { status: 200 });
    }
    if (url.href === 'https://openidconnect.googleapis.com/v1/userinfo') return json(200, { email: 'Fakhrul@Example.com' });
    const token = headers.authorization?.replace('Bearer ', '');
    if (!token || !state.validAccess.has(token)) return json(401, { error: { code: 401, message: 'Invalid Credentials' } });
    const p = url.pathname;
    if (p === '/gmail/v1/users/me/messages' && method === 'GET') {
      return json(200, { messages: [{ id: 'm1' }, { id: 'm2' }], resultSizeEstimate: 2 });
    }
    const msg = /^\/gmail\/v1\/users\/me\/messages\/(m\d)$/.exec(p);
    if (msg) {
      const id = msg[1];
      const headersList = [
        { name: 'From', value: 'Ana <ana@example.com>' },
        { name: 'To', value: 'fakhrul@example.com, Bo <bo@example.com>' },
        { name: 'Subject', value: `Invoice ${id}` },
        { name: 'Date', value: 'Mon, 28 Sep 2026 09:00:00 +0800' },
        { name: 'Message-ID', value: `<${id}@mail.example.com>` },
      ];
      if (url.searchParams.get('format') === 'full') {
        return json(200, {
          id,
          threadId: 't1',
          labelIds: ['INBOX'],
          payload: {
            mimeType: 'multipart/mixed',
            headers: headersList,
            parts: [
              { mimeType: 'multipart/alternative', parts: [{ mimeType: 'text/plain', body: { data: Buffer.from('Hi Fakhrul, invoice attached.').toString('base64url') } }, { mimeType: 'text/html', body: { data: Buffer.from('<p>Hi</p>').toString('base64url') } }] },
              { mimeType: 'application/pdf', filename: 'invoice.pdf', body: { attachmentId: 'att-1', size: 1234 } },
            ],
          },
        });
      }
      return json(200, { id, threadId: 't1', labelIds: ['INBOX', 'UNREAD'], snippet: `snippet ${id}`, payload: { headers: headersList } });
    }
    if (p === '/gmail/v1/users/me/drafts' && method === 'POST') {
      const b = JSON.parse(body) as { message: { raw: string; threadId?: string } };
      state.drafts.push(b.message);
      return json(200, { id: `d${state.drafts.length}`, message: { id: 'mx', threadId: b.message.threadId ?? 'tnew' } });
    }
    if (p === '/gmail/v1/users/me/labels') return json(200, { labels: [{ id: 'INBOX', name: 'INBOX', type: 'system' }, { id: 'Label_7', name: 'Receipts', type: 'user' }] });
    if (p === '/gmail/v1/users/me/messages/batchModify') return new Response(null, { status: 204 });
    return json(404, { error: { code: 404, message: `fake google has no ${method} ${p}` } });
  };
  return { fetch, calls, state };
}

async function setup(o: { googleClient?: null; grantScopes?: string; mcpRateLimit?: { max: number; windowMs: number } } = {}) {
  const db = openDb(':memory:');
  const google = fakeGoogle({ grantScopes: o.grantScopes });
  let nowMs = Date.parse('2026-09-29T08:00:00Z');
  const app = await buildApp({
    db,
    devMode: true,
    publicUrl: 'http://api.test',
    siteUrl: 'http://site.test',
    mailer: null,
    googleFetch: google.fetch,
    googleClient: o.googleClient === null ? null : { clientId: 'cid.apps.googleusercontent.com', clientSecret: 'csecret' },
    connectorKey: KEY,
    clock: () => nowMs,
    mcpRateLimit: o.mcpRateLimit,
  });
  return { db, app, google, advance: (ms: number) => (nowMs += ms) };
}

type App = Awaited<ReturnType<typeof setup>>['app'];

async function signIn(app: App, email: string) {
  const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email } });
  const code = new URL(r.json().devLink).searchParams.get('code')!;
  const v = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
  return decodeURIComponent(/token=([^"&]+)/.exec(v.body)![1]);
}

/** Runs the whole browser leg: app mints a ticket → browser → Google consent → callback. */
async function connectGoogle(app: App, token: string, toolkits = ['gmail', 'calendar']) {
  const start = await app.inject({ method: 'POST', url: '/v1/connectors/google/start', headers: { authorization: `Bearer ${token}` }, payload: { toolkits, redirect: 'awan://connectors' } });
  assert.equal(start.statusCode, 200, start.body);
  const browser = await app.inject({ method: 'GET', url: start.json().url.replace('http://api.test', '') });
  assert.equal(browser.statusCode, 302);
  const consent = new URL(browser.headers.location as string);
  const cb = await app.inject({ method: 'GET', url: `/v1/connectors/google/callback?code=good-code&state=${encodeURIComponent(consent.searchParams.get('state')!)}` });
  return { start, consent, cb };
}

async function rpc(app: App, token: string | null, toolkit: string, body: unknown) {
  return app.inject({
    method: 'POST',
    url: `/mcp/${toolkit}`,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), accept: 'application/json, text/event-stream', 'content-type': 'application/json' },
    payload: JSON.stringify(body),
  });
}

async function callTool(app: App, token: string, toolkit: string, name: string, args: Record<string, unknown>) {
  const r = await rpc(app, token, toolkit, { jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name, arguments: args } });
  assert.equal(r.statusCode, 200, r.body);
  const res = r.json().result as { content: { text: string }[]; isError: boolean };
  let data: any = res.content[0].text;
  try {
    data = JSON.parse(data);
  } catch {
    /* plain text error */
  }
  return { isError: res.isError, data, text: res.content[0].text };
}

// ───────────────────────────── encryption ─────────────────────────────

test('connector tokens: AES-256-GCM round trip; tampering or another owner cannot open them', () => {
  const key = parseConnectorKey(KEY)!;
  assert.equal(key.length, 32);
  assert.equal(parseConnectorKey(randomBytes(32).toString('hex'))!.length, 32, 'hex keys work too');
  assert.equal(parseConnectorKey(''), null);
  assert.throws(() => parseConnectorKey('dG9vc2hvcnQ='), /32 bytes/);
  const sealed = sealToken(key, '{"access_token":"ya29.secret"}', 'awan-connector|u1|google');
  assert.ok(!sealed.includes('ya29'), 'ciphertext does not contain the token');
  assert.notEqual(sealed, sealToken(key, '{"access_token":"ya29.secret"}', 'awan-connector|u1|google'), 'fresh IV each time');
  assert.equal(openToken(key, sealed, 'awan-connector|u1|google'), '{"access_token":"ya29.secret"}');
  assert.throws(() => openToken(key, sealed, 'awan-connector|u2|google'), 'bound to its owner');
  assert.throws(() => openToken(parseConnectorKey(randomBytes(32).toString('base64'))!, sealed, 'awan-connector|u1|google'), 'wrong key');
  const parts = sealed.split(':');
  const flipped = Buffer.from(parts[3], 'base64url');
  flipped[0] ^= 1;
  assert.throws(() => openToken(key, [...parts.slice(0, 3), flipped.toString('base64url')].join(':'), 'awan-connector|u1|google'), 'tamper detected');
});

test('toolkit names: short, Composio-style and canonical ids all resolve', () => {
  assert.deepEqual(parseToolkits('gmail,calendar,googledrive,docs,google-sheets,nope,gmail'), ['gmail', 'google-calendar', 'google-drive', 'google-docs', 'google-sheets']);
  assert.deepEqual(parseToolkits(['Sheets']), ['google-sheets']);
});

// ───────────────────────────── OAuth ─────────────────────────────

test('google connect: ticket → consent (offline, incremental) → callback stores encrypted tokens, once', async () => {
  const { app, db } = await setup();
  const token = await signIn(app, 'fakhrul@example.com');
  const { start, consent, cb } = await connectGoogle(app, token);
  assert.match(start.json().url, /^http:\/\/api\.test\/v1\/connectors\/google\/start\?toolkits=gmail%2Cgoogle-calendar&redirect=awan%3A%2F%2Fconnectors&ticket=/);
  assert.equal(consent.origin + consent.pathname, 'https://accounts.google.com/o/oauth2/v2/auth');
  assert.equal(consent.searchParams.get('access_type'), 'offline');
  assert.equal(consent.searchParams.get('include_granted_scopes'), 'true');
  assert.equal(consent.searchParams.get('redirect_uri'), 'http://api.test/v1/connectors/google/callback');
  const scopes = consent.searchParams.get('scope')!.split(' ');
  assert.ok(scopes.includes(SCOPE_GMAIL) && scopes.includes(SCOPE_CAL) && scopes.includes('email'));
  assert.ok(!scopes.some((s) => s.includes('drive')), 'only the scopes for the asked toolkits');

  assert.equal(cb.statusCode, 200);
  assert.match(cb.body, /awan:\/\/connectors\?connected=gmail%2Cgoogle-calendar&amp;email=fakhrul%40example\.com|awan:\/\/connectors\?connected=gmail%2Cgoogle-calendar&email=fakhrul%40example\.com/);
  const row = db.prepare('SELECT * FROM connector_accounts').get() as { token_enc: string; email: string; scopes: string; expires_at: string };
  assert.equal(row.email, 'fakhrul@example.com');
  assert.ok(!row.token_enc.includes('rt-secret-1') && !row.token_enc.includes('at-1'), 'tokens are encrypted at rest');
  assert.ok(row.token_enc.startsWith('v1:'));
  assert.equal(row.expires_at, '2026-09-29T09:00:00.000Z');

  const replay = await app.inject({ method: 'GET', url: `/v1/connectors/google/callback?code=good-code&state=${encodeURIComponent(consent.searchParams.get('state')!)}` });
  assert.equal(replay.statusCode, 400, 'a state is single-use');

  const status = await app.inject({ method: 'GET', url: '/v1/connectors', headers: { authorization: `Bearer ${token}` } });
  const s = status.json();
  assert.equal(s.configured.google, true);
  assert.deepEqual(s.providers[0].toolkits, ['gmail', 'google-calendar']);
  assert.equal(s.toolkits.gmail.connected, true);
  assert.equal(s.toolkits['google-drive'].connected, false);
  assert.ok(!JSON.stringify(s).includes('rt-secret'), 'status never includes tokens');
});

test('google connect: denied consent and unticked scopes come back as errors / missing', async () => {
  const { app } = await setup({ grantScopes: `openid email ${SCOPE_CAL}` });
  const token = await signIn(app, 'a@example.com');
  const start = await app.inject({ method: 'POST', url: '/v1/connectors/google/start', headers: { authorization: `Bearer ${token}` }, payload: { toolkits: 'gmail,calendar' } });
  const state = new URL((await app.inject({ method: 'GET', url: start.json().url.replace('http://api.test', '') })).headers.location as string).searchParams.get('state')!;
  const denied = await app.inject({ method: 'GET', url: `/v1/connectors/google/callback?error=access_denied&state=${encodeURIComponent(state)}` });
  assert.match(denied.body, /awan:\/\/connectors\?error=access_denied/);

  const { cb } = await connectGoogle(app, token, ['gmail', 'calendar']);
  assert.match(cb.body, /connected=google-calendar&(amp;)?missing=gmail/);
});

test('google connect: 501 page without a Google client; the browser start needs a ticket or bearer', async () => {
  const { app } = await setup({ googleClient: null });
  const token = await signIn(app, 'b@example.com');
  const page = await app.inject({ method: 'GET', url: '/v1/connectors/google/start?toolkits=gmail&redirect=awan://connectors' });
  assert.equal(page.statusCode, 501);
  assert.match(page.headers['content-type'] as string, /text\/html/);
  assert.match(page.body, /GOOGLE_CLIENT_ID/);
  const post = await app.inject({ method: 'POST', url: '/v1/connectors/google/start', headers: { authorization: `Bearer ${token}` }, payload: { toolkits: ['gmail'] } });
  assert.equal(post.statusCode, 501);

  const { app: app2 } = await setup();
  assert.equal((await app2.inject({ method: 'GET', url: '/v1/connectors/google/start?toolkits=gmail' })).statusCode, 401);
  assert.equal((await app2.inject({ method: 'GET', url: '/v1/connectors/google/start?ticket=forged' })).statusCode, 400);
  assert.equal((await app2.inject({ method: 'POST', url: '/v1/connectors/google/start', payload: { toolkits: ['gmail'] } })).statusCode, 401, 'minting a ticket needs the Awan token');
});

// ───────────────────────────── MCP ─────────────────────────────

test('mcp: 401 without an Awan token (with a Bearer challenge)', async () => {
  const { app } = await setup();
  const r = await rpc(app, null, 'gmail', { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
  assert.equal(r.statusCode, 401);
  assert.match(r.headers['www-authenticate'] as string, /^Bearer/);
  assert.equal((await rpc(app, 'awn_forged', 'gmail', { jsonrpc: '2.0', id: 1, method: 'tools/list' })).statusCode, 401);
});

test('mcp: initialize → initialized → tools/list → tools/call round trip against mocked Gmail', async () => {
  const { app, google } = await setup();
  const token = await signIn(app, 'fakhrul@example.com');
  await connectGoogle(app, token);

  const init = await rpc(app, token, 'gmail', { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'codex', version: '0' } } });
  assert.equal(init.statusCode, 200);
  assert.equal(init.json().result.protocolVersion, '2025-06-18');
  assert.equal(init.json().result.serverInfo.name, 'awan-gmail');
  assert.ok(init.json().result.capabilities.tools);
  const note = await rpc(app, token, 'gmail', { jsonrpc: '2.0', method: 'notifications/initialized' });
  assert.equal(note.statusCode, 202);
  assert.equal(note.body, '');

  const list = await rpc(app, token, 'gmail', { jsonrpc: '2.0', id: 2, method: 'tools/list' });
  const tools = list.json().result.tools as { name: string; description: string; inputSchema: { type: string } }[];
  assert.deepEqual(tools.map((t) => t.name), ['search_messages', 'get_message', 'list_labels', 'modify_labels', 'create_draft', 'send_draft', 'reply_draft']);
  assert.match(tools.find((t) => t.name === 'send_draft')!.description, /explicitly approved/);
  assert.ok(tools.every((t) => t.inputSchema.type === 'object' && t.description.length > 30));

  const search = await callTool(app, token, 'gmail', 'search_messages', { query: 'is:unread', max_results: 5 });
  assert.equal(search.isError, false);
  assert.equal(search.data.messages.length, 2);
  assert.deepEqual(search.data.messages[0], { id: 'm1', threadId: 't1', from: 'Ana <ana@example.com>', to: 'fakhrul@example.com, Bo <bo@example.com>', subject: 'Invoice m1', date: 'Mon, 28 Sep 2026 09:00:00 +0800', snippet: 'snippet m1', labels: ['INBOX', 'UNREAD'] });
  const listCall = google.calls.find((c) => c.url.pathname === '/gmail/v1/users/me/messages')!;
  assert.equal(listCall.url.searchParams.get('q'), 'is:unread');
  assert.equal(listCall.headers.authorization, 'Bearer at-1');
  assert.ok(google.calls.some((c) => c.url.searchParams.get('fields')?.includes('payload/headers')), 'metadata reads use a field mask');

  const msg = await callTool(app, token, 'gmail', 'get_message', { message_id: 'm1' });
  assert.equal(msg.data.body, 'Hi Fakhrul, invoice attached.');
  assert.deepEqual(msg.data.attachments, [{ filename: 'invoice.pdf', mimeType: 'application/pdf', size: 1234, attachmentId: 'att-1' }]);

  const labels = await callTool(app, token, 'gmail', 'modify_labels', { message_ids: ['m1'], add_labels: ['receipts'], remove_labels: ['INBOX'] });
  assert.deepEqual(labels.data, { modified: 1, added: ['Label_7'], removed: ['INBOX'] });

  const reply = await callTool(app, token, 'gmail', 'reply_draft', { message_id: 'm1', body: 'Thanks Ana!', reply_all: true });
  assert.equal(reply.isError, false, reply.text);
  assert.deepEqual(reply.data.to, ['Ana <ana@example.com>']);
  assert.deepEqual(reply.data.cc, ['Bo <bo@example.com>'], 'reply-all copies others but never the user');
  const raw = Buffer.from(google.state.drafts[0].raw, 'base64url').toString('utf8');
  assert.equal(google.state.drafts[0].threadId, 't1');
  assert.match(raw, /\r\nIn-Reply-To: <m1@mail\.example\.com>\r\n/);
  assert.match(raw, /\r\nSubject: Re: Invoice m1\r\n/);

  const bad = await callTool(app, token, 'gmail', 'create_draft', { subject: 'x', body: 'y' });
  assert.equal(bad.isError, true);
  assert.match(bad.text, /arguments\.to is required/);
  const unknown = await rpc(app, token, 'gmail', { jsonrpc: '2.0', id: 9, method: 'tools/call', params: { name: 'delete_everything', arguments: {} } });
  assert.equal(unknown.json().error.code, -32602);
  const noMethod = await rpc(app, token, 'gmail', { jsonrpc: '2.0', id: 10, method: 'resources/list' });
  assert.equal(noMethod.json().error.code, -32601);
  assert.equal((await rpc(app, token, 'slack', { jsonrpc: '2.0', id: 1, method: 'initialize' })).statusCode, 404);
  assert.equal((await app.inject({ method: 'GET', url: '/mcp/gmail', headers: { authorization: `Bearer ${token}` } })).statusCode, 405);
});

test('mcp: every toolkit lists exactly the agreed tools with object schemas', async () => {
  const expected: Record<string, string[]> = {
    gmail: ['search_messages', 'get_message', 'list_labels', 'modify_labels', 'create_draft', 'send_draft', 'reply_draft'],
    'google-calendar': ['list_calendars', 'list_events', 'find_free_time', 'create_event', 'update_event', 'delete_event'],
    'google-drive': ['search_files', 'get_file_metadata', 'download_text', 'upload_file', 'share_file', 'move_file'],
    'google-docs': ['create_document', 'get_document_text', 'append_text', 'replace_text'],
    'google-sheets': ['create_spreadsheet', 'get_values', 'append_rows', 'update_values', 'add_sheet'],
  };
  const { app } = await setup();
  const token = await signIn(app, 'c@example.com');
  for (const [toolkit, names] of Object.entries(expected)) {
    assert.deepEqual(GOOGLE_MCP_SERVERS[toolkit].tools.map((t) => t.name), names);
    const r = await rpc(app, token, toolkit, { jsonrpc: '2.0', id: 1, method: 'tools/list' });
    for (const t of r.json().result.tools) {
      assert.equal(t.inputSchema.type, 'object', `${toolkit}.${t.name}`);
      for (const req of t.inputSchema.required ?? []) assert.ok(t.inputSchema.properties[req], `${toolkit}.${t.name} requires a declared property ${req}`);
      for (const [k, v] of Object.entries(t.inputSchema.properties ?? {}) as [string, { description?: string }][]) assert.ok(v.description, `${toolkit}.${t.name}.${k} is described`);
    }
  }
});

test('mcp: a toolkit that was not granted explains how to connect it', async () => {
  const { app } = await setup();
  const token = await signIn(app, 'd@example.com');
  const none = await callTool(app, token, 'gmail', 'list_labels', {});
  assert.equal(none.isError, true);
  assert.match(none.text, /Gmail isn't connected.*Settings → Integrations/);
  await connectGoogle(app, token, ['gmail', 'calendar']);
  const drive = await callTool(app, token, 'google-drive', 'search_files', { query: 'budget' });
  assert.equal(drive.isError, true);
  assert.match(drive.text, /Google Drive isn't connected/);
});

test('mcp: expired access token is refreshed before the call; a 401 forces one refresh', async () => {
  const { app, google, advance, db } = await setup();
  const token = await signIn(app, 'e@example.com');
  await connectGoogle(app, token);
  await callTool(app, token, 'gmail', 'list_labels', {});
  assert.equal(google.state.refreshes, 0, 'fresh token used as is');

  advance(3600_000); // past expiry
  const r = await callTool(app, token, 'gmail', 'list_labels', {});
  assert.equal(r.isError, false, r.text);
  assert.equal(google.state.refreshes, 1);
  const refresh = google.calls.find((c) => new URLSearchParams(c.body).get('grant_type') === 'refresh_token')!;
  assert.equal(new URLSearchParams(refresh.body).get('refresh_token'), 'rt-secret-1');
  assert.equal(google.calls.at(-1)!.headers.authorization, 'Bearer at-2');
  assert.equal((db.prepare('SELECT expires_at FROM connector_accounts').get() as { expires_at: string }).expires_at, '2026-09-29T10:00:00.000Z');

  google.state.validAccess.delete('at-2'); // Google revokes the access token early
  const again = await callTool(app, token, 'gmail', 'list_labels', {});
  assert.equal(again.isError, false, again.text);
  assert.equal(google.state.refreshes, 2);

  // Concurrent calls on an expired token share one refresh.
  advance(3600_000);
  await Promise.all([callTool(app, token, 'gmail', 'list_labels', {}), callTool(app, token, 'gmail', 'list_labels', {}), callTool(app, token, 'gmail', 'list_labels', {})]);
  assert.equal(google.state.refreshes, 3);
});

test('mcp: users are isolated — nobody reaches or decrypts another user’s Google grant', async () => {
  const { app, db } = await setup();
  const alice = await signIn(app, 'alice@example.com');
  const bob = await signIn(app, 'bob@example.com');
  await connectGoogle(app, alice);
  const asBob = await callTool(app, bob, 'gmail', 'search_messages', { query: '' });
  assert.equal(asBob.isError, true);
  assert.match(asBob.text, /isn't connected/);
  const bobStatus = (await app.inject({ method: 'GET', url: '/v1/connectors', headers: { authorization: `Bearer ${bob}` } })).json();
  assert.deepEqual(bobStatus.providers, []);
  // Even a row copied into Bob's name does not open: the ciphertext is bound to Alice.
  const bobId = (db.prepare('SELECT id FROM users WHERE email = ?').get('bob@example.com') as { id: string }).id;
  db.prepare("INSERT INTO connector_accounts (user_id, provider, scopes, email, token_enc, expires_at, created_at, updated_at) SELECT ?, provider, scopes, email, token_enc, expires_at, created_at, updated_at FROM connector_accounts WHERE provider = 'google'").run(bobId);
  const stolen = await rpc(app, bob, 'gmail', { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'list_labels', arguments: {} } });
  assert.equal(stolen.json().result.isError, true);
  assert.ok(!stolen.body.includes('Receipts'), 'no Gmail data leaks through a copied row');
});

test('mcp: tool calls are rate-limited per user', async () => {
  const { app } = await setup({ mcpRateLimit: { max: 2, windowMs: 60_000 } });
  const token = await signIn(app, 'f@example.com');
  await connectGoogle(app, token);
  assert.equal((await callTool(app, token, 'gmail', 'list_labels', {})).isError, false);
  assert.equal((await callTool(app, token, 'gmail', 'list_labels', {})).isError, false);
  const third = await callTool(app, token, 'gmail', 'list_labels', {});
  assert.equal(third.isError, true);
  assert.match(third.text, /Too many Google calls/);
  const other = await signIn(app, 'g@example.com');
  await connectGoogle(app, other);
  assert.equal((await callTool(app, other, 'gmail', 'list_labels', {})).isError, false, 'the limit is per user');
});

test('disconnect revokes at Google and forgets the grant', async () => {
  const { app, google, db } = await setup();
  const token = await signIn(app, 'h@example.com');
  await connectGoogle(app, token);
  const r = await app.inject({ method: 'POST', url: '/v1/connectors/google/disconnect', headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().revoked, true);
  assert.deepEqual(google.state.revoked, ['rt-secret-1']);
  assert.equal((db.prepare('SELECT COUNT(*) AS n FROM connector_accounts').get() as { n: number }).n, 0);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/connectors/slack/disconnect', headers: { authorization: `Bearer ${token}` } })).statusCode, 404);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/connectors/google/disconnect' })).statusCode, 401);
});

// ───────────────────────────── helpers ─────────────────────────────

test('MIME: headers cannot be injected; non-ASCII subjects are encoded; HTML gets a text part', () => {
  const raw = buildMime({ from: 'me@example.com', to: ['a@example.com\r\nBcc: evil@example.com'], subject: 'Hari Raya 🎉\r\nX-Evil: 1', text: 'Selamat!', html: '<p>Selamat!</p>' });
  assert.ok(!/\r\nBcc: evil/.test(raw), 'no smuggled Bcc header');
  assert.ok(!/\r\nX-Evil/.test(raw));
  assert.match(raw, /Subject: =\?UTF-8\?B\?/);
  assert.match(raw, /multipart\/alternative/);
  assert.match(raw, /text\/plain/);
});

test('free time: busy blocks merged, slots inside working hours in the user’s time zone, weekends skipped', () => {
  const tz = 'Asia/Kuala_Lumpur'; // UTC+8
  assert.equal(new Date(zonedToUtc(2026, 10, 1, 9, 0, tz)).toISOString(), '2026-10-01T01:00:00.000Z');
  const busy = [
    { start: Date.parse('2026-10-01T02:00:00Z'), end: Date.parse('2026-10-01T03:00:00Z') }, // 10–11 local
    { start: Date.parse('2026-10-01T02:30:00Z'), end: Date.parse('2026-10-01T04:00:00Z') }, // overlaps → 10–12
  ];
  const slots = freeSlots(busy, Date.parse('2026-10-01T00:00:00Z'), Date.parse('2026-10-05T00:00:00Z'), 30 * 60_000, { tz, workStart: '09:00', workEnd: '18:00' });
  const iso = slots.map((s) => [new Date(s.start).toISOString(), new Date(s.end).toISOString()]);
  assert.deepEqual(iso[0], ['2026-10-01T01:00:00.000Z', '2026-10-01T02:00:00.000Z']); // 9–10
  assert.deepEqual(iso[1], ['2026-10-01T04:00:00.000Z', '2026-10-01T10:00:00.000Z']); // 12–18
  assert.deepEqual(iso[2], ['2026-10-02T01:00:00.000Z', '2026-10-02T10:00:00.000Z']); // Fri
  assert.equal(iso.length, 3, 'Sat 3 Oct and Sun 4 Oct are skipped');
  const tight = freeSlots(busy, Date.parse('2026-10-01T01:00:00Z'), Date.parse('2026-10-01T02:10:00Z'), 90 * 60_000);
  assert.deepEqual(tight, [], 'gaps shorter than the duration are dropped');
});

test('argument validation: required, types, enums, unknown keys', () => {
  const schema = GOOGLE_MCP_SERVERS['google-calendar'].tools.find((t) => t.name === 'create_event')!.inputSchema;
  assert.equal(validateArgs(schema, { summary: 'x', start: 'a', end: 'b' }), null);
  assert.match(validateArgs(schema, { summary: 'x', start: 'a' })!, /end is required/);
  assert.match(validateArgs(schema, { summary: 'x', start: 'a', end: 'b', send_updates: 'everyone' })!, /one of: none, all, externalOnly/);
  assert.match(validateArgs(schema, { summary: 'x', start: 'a', end: 'b', colour: 'red' })!, /not a known argument/);
  assert.match(validateArgs(schema, { summary: 3, start: 'a', end: 'b' })!, /summary must be a string/);
});

test('tool requests: calendar, drive, docs and sheets build the right Google calls', async () => {
  const seen: { method: string; url: string; query?: Record<string, unknown>; json?: any; headers?: Record<string, string>; body?: unknown; text?: boolean }[] = [];
  const canned: [RegExp, unknown][] = [
    [/calendar\/v3\/users\/me\/settings\/timezone$/, { value: 'Asia/Kuala_Lumpur' }],
    [/calendar\/v3\/freeBusy$/, { calendars: { primary: { busy: [{ start: '2026-10-01T02:00:00Z', end: '2026-10-01T03:00:00Z' }] } } }],
    [/calendar\/v3\/calendars\/primary\/events$/, { id: 'ev1', summary: 'Sync', start: { dateTime: '2026-10-02T15:00:00+08:00' }, end: { dateTime: '2026-10-02T15:30:00+08:00' }, hangoutLink: 'https://meet.google.com/x' }],
    [/drive\/v3\/files\/f1$/, { id: 'f1', name: 'Plan', mimeType: 'application/vnd.google-apps.spreadsheet', webViewLink: 'https://docs.google.com/x', parents: ['old'] }],
    [/drive\/v3\/files\/f1\/export$/, 'a,b\n1,2\n'],
    [/upload\/drive\/v3\/files$/, { id: 'up1', name: 'notes.csv' }],
    [/docs\.googleapis\.com\/v1\/documents$/, { documentId: 'doc1', title: 'Brief' }],
    [/documents\/doc1:batchUpdate$/, { replies: [{ replaceAllText: { occurrencesChanged: 3 } }] }],
    [/documents\/doc1$/, { documentId: 'doc1', title: 'Brief', body: { content: [{ paragraph: { elements: [{ textRun: { content: 'Hello\n' } }] } }, { table: { tableRows: [{ tableCells: [{ content: [{ paragraph: { elements: [{ textRun: { content: 'a\n' } }] } }] }, { content: [{ paragraph: { elements: [{ textRun: { content: 'b\n' } }] } }] }] }] } }] } }],
    [/spreadsheets\/s1\/values\/.*:append$/, { updates: { updatedRange: "'Leads'!A5:B5", updatedRows: 1, updatedCells: 2 } }],
    [/spreadsheets\/s1$/, { sheets: [{ properties: { sheetId: 0, title: 'Q3 Sales', gridProperties: { rowCount: 10, columnCount: 3 } } }] }],
    [/spreadsheets\/s1\/values\//, { range: "'Q3 Sales'!A1:C3", values: [['x'], ['y'], ['z']] }],
  ];
  const g = async (req: any) => {
    seen.push({ method: 'GET', ...req });
    const hit = canned.find(([re]) => re.test(req.url));
    return hit ? hit[1] : {};
  };
  const ctx = { g, accountEmail: 'me@example.com' };
  const tool = (kit: string, name: string) => GOOGLE_MCP_SERVERS[kit].tools.find((t) => t.name === name)!;

  const free = (await tool('google-calendar', 'find_free_time').run(
    { time_min: '2026-10-01T00:00:00Z', time_max: '2026-10-01T12:00:00Z', duration_minutes: 30, working_hours: { start: '09:00', end: '12:00' }, max_slots: 10 },
    ctx,
  )) as any;
  assert.equal(free.timeZone, 'Asia/Kuala_Lumpur');
  assert.deepEqual(free.slots.map((s: any) => s.local), ['Thu 1 Oct, 09:00 – Thu 1 Oct, 10:00', 'Thu 1 Oct, 11:00 – Thu 1 Oct, 12:00']);

  const ev = (await tool('google-calendar', 'create_event').run({ calendar_id: 'primary', summary: 'Sync', start: '2026-10-02T15:00:00+08:00', end: '2026-10-02T15:30:00+08:00', attendees: ['ana@example.com'], add_meet: true, send_updates: 'none' }, ctx)) as any;
  const create = seen.find((r) => r.method === 'POST' && /events$/.test(r.url))!;
  assert.equal(create.query!.conferenceDataVersion, 1);
  assert.deepEqual(create.json.attendees, [{ email: 'ana@example.com' }]);
  assert.equal(create.json.conferenceData.createRequest.conferenceSolutionKey.type, 'hangoutsMeet');
  assert.equal(ev.event.meetLink, 'https://meet.google.com/x');

  const csv = (await tool('google-drive', 'download_text').run({ file_id: 'f1', max_chars: 50_000 }, ctx)) as any;
  assert.equal(csv.text, 'a,b\n1,2\n');
  assert.equal(seen.find((r) => /export$/.test(r.url))!.query!.mimeType, 'text/csv');

  await tool('google-drive', 'search_files').run({ query: "Q3 'final'", max_results: 20 }, ctx);
  assert.match(String(seen.at(-1)!.query!.q), /name contains 'Q3 \\'final\\''/, 'quotes are escaped in Drive queries');

  await tool('google-drive', 'upload_file').run({ name: 'notes.csv', content_base64: Buffer.from('a,b\n').toString('base64'), mime_type: 'text/csv', convert_to_google: true }, ctx);
  const up = seen.find((r) => /upload\/drive/.test(r.url))!;
  assert.match(up.headers!['Content-Type'], /^multipart\/related; boundary=/);
  assert.match(Buffer.from(up.body as Buffer).toString(), /"mimeType":"application\/vnd.google-apps.spreadsheet"[\s\S]*a,b/);

  await tool('google-drive', 'move_file').run({ file_id: 'f1', folder_id: 'new' }, ctx);
  const move = seen.find((r) => r.method === 'PATCH')!;
  assert.equal(move.query!.addParents, 'new');
  assert.equal(move.query!.removeParents, 'old');

  const doc = (await tool('google-docs', 'create_document').run({ title: 'Brief', text: 'Hello' }, ctx)) as any;
  assert.equal(doc.url, 'https://docs.google.com/document/d/doc1/edit');
  assert.deepEqual(seen.at(-1)!.json.requests[0].insertText, { location: { index: 1 }, text: 'Hello' });
  await tool('google-docs', 'append_text').run({ document_id: 'doc1', text: '\nMore' }, ctx);
  assert.deepEqual(seen.at(-1)!.json.requests[0].insertText, { endOfSegmentLocation: {}, text: '\nMore' });
  const replaced = (await tool('google-docs', 'replace_text').run({ document_id: 'doc1', find: 'a', replace: 'b', match_case: true }, ctx)) as any;
  assert.equal(replaced.occurrencesChanged, 3);
  const text = (await tool('google-docs', 'get_document_text').run({ document_id: 'doc1', max_chars: 50_000 }, ctx)) as any;
  assert.equal(text.text, 'Hello\na\tb\n');

  const appended = (await tool('google-sheets', 'append_rows').run({ spreadsheet_id: 's1', range: 'Leads', rows: [['Ana', 'ana@example.com']], value_input: 'USER_ENTERED' }, ctx)) as any;
  assert.equal(appended.updatedRows, 1);
  assert.equal(seen.at(-1)!.query!.insertDataOption, 'INSERT_ROWS');
  const vals = (await tool('google-sheets', 'get_values').run({ spreadsheet_id: 's1', value_render: 'FORMATTED_VALUE', max_rows: 2 }, ctx)) as any;
  assert.ok(seen.at(-1)!.url.endsWith(`/values/${encodeURIComponent("'Q3 Sales'")}`), 'tab names with spaces are quoted');
  assert.deepEqual(vals.values, [['x'], ['y']]);
  assert.equal(vals.truncated, true);
});
