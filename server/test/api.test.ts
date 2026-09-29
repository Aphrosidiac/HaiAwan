import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp, documentBlock, DOCUMENT_MAX_CHARS, RateLimiter, recordReferralEarning, referralHandleFrom, routeCompanionModel, safePrefix } from '../src/app.ts';
import { clearImageCache, isPublicHttpUrl, parseImageJson, searchImages, type ImageResult } from '../src/images.ts';
import { COMPANION_SYSTEM, REALTIME_ADDENDUM } from '../src/prompts.ts';
import { openDb } from '../src/db.ts';
import { consume, currentWindow, planSnapshot, QuotaExceeded, setPlan } from '../src/plans.ts';
import { parseAssistantTags } from '../src/tags.ts';
import { verifyStripeSignature } from '../src/stripe.ts';
import { SpeechEndpoint } from '../src/llm.ts';
import { localTidy, onlySpokenWords, stripDashes } from '../src/dictation.ts';
import { createHmac } from 'node:crypto';

process.env.LOG = '0';

async function setup() {
  const db = openDb(':memory:');
  const app = await buildApp({ db, devMode: true, publicUrl: 'http://api.test', siteUrl: 'http://site.test' });
  return { db, app };
}

async function signIn(app: Awaited<ReturnType<typeof setup>>['app'], email: string, referral?: string) {
  const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email, referral } });
  assert.equal(r.statusCode, 200);
  const code = new URL(r.json().devLink).searchParams.get('code')!;
  const v = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
  assert.equal(v.statusCode, 200);
  const token = /token=([^"&]+)/.exec(v.body)![1];
  return decodeURIComponent(token);
}

test('magic link signs in once, and only once', async () => {
  const { app } = await setup();
  const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'Fakhrul@Example.com' } });
  const code = new URL(r.json().devLink).searchParams.get('code')!;
  const first = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
  assert.equal(first.statusCode, 200);
  assert.match(first.body, /awan:\/\/auth\?token=/);
  const second = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
  assert.equal(second.statusCode, 400, 'a used link must not mint a second session');
});

test('bad email is refused; protected routes need a token', async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email: 'nope' } })).statusCode, 400);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/me' })).statusCode, 401);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: 'Bearer awn_fake' } })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/agent/openai/v1/responses', payload: {} })).statusCode, 401);
});

test('me returns the free plan snapshot in the reference shape', async () => {
  const { app } = await setup();
  const token = await signIn(app, 'a@b.co');
  const r = await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${token}` } });
  const body = r.json();
  assert.equal(body.user.email, 'a@b.co');
  assert.equal(body.plan.tier, 'free');
  assert.deepEqual(body.plan.usage.messages, { cap: 25, used: 0 });
  assert.deepEqual(body.plan.usage.agents, { cap: 25, used: 0 });
  assert.equal(body.plan.pro_agents_cap, 150);
  assert.equal(body.plan.max_agents_cap, 1000);
});

test('quota: the 26th talk on free is refused with 402, and a retried ref is not double-counted', async () => {
  const { app } = await setup();
  const token = await signIn(app, 'q@b.co');
  const h = { authorization: `Bearer ${token}` };
  for (let i = 0; i < 25; i++) {
    const r = await app.inject({ method: 'POST', url: '/v1/usage/consume', headers: h, payload: { kind: 'talk', ref: `r${i}` } });
    assert.equal(r.statusCode, 200);
  }
  const retry = await app.inject({ method: 'POST', url: '/v1/usage/consume', headers: h, payload: { kind: 'talk', ref: 'r3' } });
  assert.equal(retry.statusCode, 200, 'an idempotent retry of an already-counted ref succeeds');
  assert.equal(retry.json().usage.messages.used, 25);
  const over = await app.inject({ method: 'POST', url: '/v1/usage/consume', headers: h, payload: { kind: 'talk', ref: 'r26' } });
  assert.equal(over.statusCode, 402);
  assert.equal(over.json().kind, 'talk');
});

test('quota: racing consumers can never take more than the cap', async () => {
  const { db, app } = await setup();
  const token = await signIn(app, 'race@b.co');
  const userId = (db.prepare('SELECT id FROM users WHERE email = ?').get('race@b.co') as { id: string }).id;
  const results = await Promise.allSettled(Array.from({ length: 60 }, (_, i) => Promise.resolve().then(() => consume(db, userId, 'agent_message', `t${i}`))));
  const ok = results.filter((r) => r.status === 'fulfilled').length;
  const refused = results.filter((r) => r.status === 'rejected' && (r.reason as Error) instanceof QuotaExceeded).length;
  assert.equal(ok, 25);
  assert.equal(refused, 35);
  assert.equal(planSnapshot(db, userId).usage.agents.used, 25);
  void token;
});

test('plans: pro lifts talk to unlimited and agents to 150; a lapsed plan falls back to free caps', async () => {
  const { db, app } = await setup();
  await signIn(app, 'p@b.co');
  const userId = (db.prepare('SELECT id FROM users WHERE email = ?').get('p@b.co') as { id: string }).id;
  setPlan(db, userId, 'pro', 'month', { periodEnd: new Date(Date.now() + 86400_000).toISOString() });
  let snap = planSnapshot(db, userId);
  assert.equal(snap.usage.messages.cap, null);
  assert.equal(snap.usage.agents.cap, 150);
  setPlan(db, userId, 'pro', 'month', { periodEnd: new Date(Date.now() - 1000).toISOString() });
  snap = planSnapshot(db, userId);
  assert.equal(snap.tier, 'free');
  assert.equal(snap.usage.agents.cap, 25);
});

test('usage window is a rolling 30 days anchored on sign-up', () => {
  const created = '2026-09-28T18:10:47.199Z';
  const w = currentWindow(created, new Date('2026-09-29T00:00:00Z'));
  assert.equal(w.end.toISOString(), '2026-10-28T18:10:47.199Z');
  const w2 = currentWindow(created, new Date('2026-11-01T00:00:00Z'));
  assert.equal(w2.start.toISOString(), '2026-10-28T18:10:47.199Z');
});

test('dev checkout upgrades the plan and pays the referrer 25%', async () => {
  const { db, app } = await setup();
  const refToken = await signIn(app, 'referrer@b.co');
  const handle = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${refToken}` } })).json().handle;
  const token = await signIn(app, 'friend@b.co', handle);
  const co = await app.inject({ method: 'POST', url: '/v1/billing/checkout', headers: { authorization: `Bearer ${token}` }, payload: { plan: 'pro', interval: 'month' } });
  assert.equal(co.statusCode, 200);
  const done = await app.inject({ method: 'POST', url: '/billing/dev-checkout', payload: { plan: 'pro', interval: 'month', token } });
  assert.equal(done.statusCode, 200);
  const me = (await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${token}` } })).json();
  assert.equal(me.plan.tier, 'pro');
  const refs = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${refToken}` } })).json();
  assert.equal(refs.referrals.length, 1);
  assert.equal(refs.referrals[0].plan, 'pro');
  assert.equal(refs.totalEarnedCents, 500, '25% of $20');
  // earnings stop after 12 paid months
  const friendId = (db.prepare('SELECT id FROM users WHERE email = ?').get('friend@b.co') as { id: string }).id;
  for (let i = 0; i < 15; i++) recordReferralEarning(db, friendId, `inv_${i}`, 2000);
  const after = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${refToken}` } })).json();
  assert.equal(after.totalEarnedCents, 500 * 12);
});

test('referral handle: validated, unique', async () => {
  const { app } = await setup();
  const a = await signIn(app, 'one@b.co');
  const b = await signIn(app, 'two@b.co');
  const bad = await app.inject({ method: 'PATCH', url: '/v1/referrals/handle', headers: { authorization: `Bearer ${a}` }, payload: { handle: 'x' } });
  assert.equal(bad.statusCode, 400);
  const ok = await app.inject({ method: 'PATCH', url: '/v1/referrals/handle', headers: { authorization: `Bearer ${a}` }, payload: { handle: 'Aphro' } });
  assert.equal(ok.json().handle, 'aphro');
  const taken = await app.inject({ method: 'PATCH', url: '/v1/referrals/handle', headers: { authorization: `Bearer ${b}` }, payload: { handle: 'aphro' } });
  assert.equal(taken.statusCode, 409);
  const redirect = await app.inject({ method: 'GET', url: '/@aphro' });
  assert.equal(redirect.headers.location, 'http://site.test/?ref=aphro');
});

test('suggestion decisions: only pending can be decided; double-tap is a 409', async () => {
  const { db, app } = await setup();
  const token = await signIn(app, 's@b.co');
  const userId = (db.prepare('SELECT id FROM users WHERE email = ?').get('s@b.co') as { id: string }).id;
  db.prepare("INSERT INTO suggestions (user_id, awan_slug, title, description, agent_prompt, check_reason, created_at) VALUES (?, 'x', 't', 'd', 'p', 'manual', ?)").run(userId, new Date().toISOString());
  const h = { authorization: `Bearer ${token}` };
  const list = (await app.inject({ method: 'GET', url: '/v1/suggestions', headers: h })).json();
  const id = list.suggestions[0].id;
  assert.equal((await app.inject({ method: 'POST', url: `/v1/suggestions/${id}/decide`, headers: h, payload: { decision: 'accepted' } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'POST', url: `/v1/suggestions/${id}/decide`, headers: h, payload: { decision: 'declined' } })).statusCode, 409);
  // another user cannot touch it
  const other = await signIn(app, 'other@b.co');
  assert.equal((await app.inject({ method: 'POST', url: `/v1/suggestions/${id}/decide`, headers: { authorization: `Bearer ${other}` }, payload: { decision: 'declined' } })).statusCode, 409);
});

test('delete account erases usage and revokes tokens', async () => {
  const { app } = await setup();
  const token = await signIn(app, 'gone@b.co');
  const h = { authorization: `Bearer ${token}` };
  await app.inject({ method: 'POST', url: '/v1/usage/consume', headers: h, payload: { kind: 'talk' } });
  assert.equal((await app.inject({ method: 'DELETE', url: '/v1/me', headers: h })).statusCode, 200);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/me', headers: h })).statusCode, 401);
  // the email can sign up fresh
  const again = await signIn(app, 'gone@b.co');
  const me = (await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${again}` } })).json();
  assert.equal(me.plan.usage.messages.used, 0);
});

test('tag parser: point, multi-point, screen, none, agent', () => {
  assert.deepEqual(parseAssistantTags('open the inspector. [POINT:1100,42:color inspector]').points, [{ x: 1100, y: 42, label: 'color inspector', screen: null }]);
  const two = parseAssistantTags('click file. [POINT:10,20:file] then export. [POINT:30,40:export:screen2]');
  assert.equal(two.points.length, 2);
  assert.equal(two.points[1].screen, 2);
  assert.equal(two.spokenText, 'click file. then export.');
  const none = parseAssistantTags('html is the skeleton. [POINT:none]');
  assert.equal(none.points.length, 0);
  assert.equal(none.spokenText, 'html is the skeleton.');
  const agent = parseAssistantTags("on it. [AGENT:Research competitors and save a PDF.] [POINT:none]");
  assert.equal(agent.agentTask, 'Research competitors and save a PDF.');
  assert.equal(agent.spokenText, 'on it.');
});

test('drawing and guided tags are stripped from speech (the app parses them from text)', () => {
  const r = parseAssistantTags('[TARGET:120,210,40:add modifier] click add modifier. [HIGHLIGHT:1,2,3,4:panel] this panel. [SHAPE:circle:5,6;7,8:tool] that tool.');
  assert.equal(r.spokenText, 'click add modifier. this panel. that tool.');
  assert.ok(r.text.includes('[TARGET:120,210,40:add modifier]'));
  assert.equal(safePrefix('[TARGET:1,2,3:x] click it. [HIGHLIGHT:1,2'), ' click it. ');
});

test('safePrefix never leaks a half-written tag', () => {
  assert.equal(safePrefix('see that button [POI'), 'see that button ');
  assert.equal(safePrefix('see that button [POINT:1,2:x] and'), 'see that button and');
  assert.equal(safePrefix('plain text'), 'plain text');
});

test('stripe signature check', () => {
  const secret = 'whsec_test';
  const raw = '{"a":1}';
  const t = Math.floor(Date.now() / 1000);
  const sig = createHmac('sha256', secret).update(`${t}.${raw}`).digest('hex');
  assert.ok(verifyStripeSignature(raw, `t=${t},v1=${sig}`, secret));
  assert.ok(!verifyStripeSignature(raw + ' ', `t=${t},v1=${sig}`, secret));
  assert.ok(!verifyStripeSignature(raw, `t=${t - 10_000},v1=${sig}`, secret));
});

test('companion router: quick → fast model, deep or on-screen → frontier model', () => {
  process.env.FAST_MODEL = 'fast';
  process.env.COMPANION_MODEL = 'deep';
  assert.equal(routeCompanionModel('what is html', false), 'fast');
  assert.equal(routeCompanionModel('explain how closures work', false), 'deep');
  assert.equal(routeCompanionModel("where's the export button", true), 'deep');
  assert.equal(routeCompanionModel('what time is it in tokyo', true), 'fast');
});

test('agent turns: each turn spends one agent message, retries are free, the 26th is a 402', async () => {
  const { app } = await setup();
  const token = await signIn(app, 'agent@b.co');
  const h = { authorization: `Bearer ${token}` };
  assert.equal((await app.inject({ method: 'POST', url: '/v1/agents/turns', headers: h, payload: { threadId: 't' } })).statusCode, 400);
  for (let i = 0; i < 25; i++) {
    const r = await app.inject({ method: 'POST', url: '/v1/agents/turns', headers: h, payload: { threadId: 'research-scout', turnRef: `turn-${i}` } });
    assert.equal(r.statusCode, 200);
    assert.equal(r.json().used, i + 1);
    assert.equal(r.json().cap, 25);
  }
  const retry = await app.inject({ method: 'POST', url: '/v1/agents/turns', headers: h, payload: { threadId: 'research-scout', turnRef: 'turn-7' } });
  assert.equal(retry.statusCode, 200, 'a retried turn ref is not double-counted');
  assert.equal(retry.json().used, 25);
  const over = await app.inject({ method: 'POST', url: '/v1/agents/turns', headers: h, payload: { threadId: 'research-scout', turnRef: 'turn-26' } });
  assert.equal(over.statusCode, 402);
  assert.equal(over.json().kind, 'agent_message');
  const plan = await app.inject({ method: 'GET', url: '/v1/billing/plan', headers: h });
  assert.deepEqual(plan.json().usage.agents, { cap: 25, used: 25 });
  const proxy = await app.inject({ method: 'POST', url: '/agent/openai/v1/responses', headers: h, payload: { model: 'awan-agent', input: 'hi' } });
  // The 25th turn was counted up front; its model calls must still go through (no provider key in tests → 503, not 402).
  assert.notEqual(proxy.statusCode, 402, 'the in-flight last turn is not cut off by the proxy');
});

test('agent instructions carry the whole output protocol', async () => {
  const { app } = await setup();
  const token = await signIn(app, 'instr@b.co');
  const r = await app.inject({ method: 'GET', url: '/v1/agents/instructions', headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.statusCode, 200);
  const text: string = r.json().instructions;
  for (const tag of ['<SUMMARY>', '<NEXT_ACTIONS>', '<DONE_TITLE>', '<ARTIFACTS>', '<ROUTINE>', '<COMPUTER_USE_REQUEST>', 'AGENTS.md', 'output/']) {
    assert.ok(text.includes(tag), `instructions mention ${tag}`);
  }
  assert.ok(!/clicky/i.test(text), 'no reference product name');
});

test('dictation cleanup: tidies, strips em dashes, spends one dictation per requestId, 402 at the free cap', async () => {
  const db = openDb(':memory:');
  let reply = '';
  const app = await buildApp({ db, devMode: true, publicUrl: 'http://api.test', siteUrl: 'http://site.test', dictationModel: async () => reply });
  const token = await signIn(app, 'dict@b.co');
  const h = { authorization: `Bearer ${token}` };
  const post = (payload: object) => app.inject({ method: 'POST', url: '/v1/dictation/cleanup', headers: h, payload });

  assert.equal((await post({ text: '   ' })).statusCode, 400);

  // a well-behaved model reply is kept, minus its em dashes
  reply = 'Hello, this is a test of Awan dictation — it works.';
  let r = await post({ text: 'um hello this is a test of awan dictation it works', dictionary: ['Awan'], requestId: 'd1' });
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().source, 'model');
  assert.equal(r.json().text, 'Hello, this is a test of Awan dictation, it works.');
  assert.ok(!/[—–]/.test(r.json().text));

  // a model that invents words is overruled by the local tidy
  reply = 'Hello, this is a wonderful test of Awan dictation.';
  r = await post({ text: 'um hello this is a test of awan dictation', dictionary: ['Awan'], requestId: 'd2' });
  assert.equal(r.json().source, 'local');
  assert.equal(r.json().text, 'Hello this is a test of Awan dictation.');

  // an empty model reply falls back too
  reply = '';
  r = await post({ text: 'so uh i think the the meeting is at 3', requestId: 'd3' });
  assert.equal(r.json().text, 'So I think the meeting is at 3.');

  // retrying the same requestId is free
  await post({ text: 'hello', requestId: 'd3' });
  let me = (await app.inject({ method: 'GET', url: '/v1/me', headers: h })).json();
  assert.equal(me.plan.usage.dictation.used, 3);

  // the free cap is 50
  reply = 'Hi.';
  for (let i = 4; i <= 50; i++) assert.equal((await post({ text: 'hi', requestId: `d${i}` })).statusCode, 200);
  const over = await post({ text: 'hi', requestId: 'd51' });
  assert.equal(over.statusCode, 402);
  assert.equal(over.json().kind, 'dictation');
  me = (await app.inject({ method: 'GET', url: '/v1/me', headers: h })).json();
  assert.equal(me.plan.usage.dictation.used, 50);
});

test('dictation helpers: dashes, invented-word guard, local tidy', () => {
  assert.equal(stripDashes('wait — no – yes'), 'wait, no, yes');
  assert.equal(stripDashes('a well-known fact'), 'a well-known fact');
  assert.ok(onlySpokenWords('meet at three no four pm', 'Meet at 4 PM.'));
  assert.ok(onlySpokenWords('i do not know', "I don't know."));
  assert.ok(!onlySpokenWords('send the report', 'Please send the quarterly report.'));
  assert.ok(onlySpokenWords('ask ff dev studio', 'Ask FF Dev Studio.', ['FF Dev Studio']));
  assert.equal(localTidy('Um, what do you think awan', ['Awan']), 'What do you think Awan.');
  assert.equal(localTidy('i think uh we should ship it. yes'), 'I think we should ship it. Yes.');
});

test('speech: signed-out previews are short-only; the limiter caps a window', async () => {
  const { app } = await setup();
  const long = await app.inject({ method: 'POST', url: '/v1/speech', payload: { text: 'x'.repeat(300), voice: 'cedar' } });
  assert.equal(long.statusCode, 401, 'long text needs an account');
  const empty = await app.inject({ method: 'POST', url: '/v1/speech', payload: { text: '  ' } });
  assert.equal(empty.statusCode, 400);
  const lim = new RateLimiter(2, 1000);
  assert.ok(lim.allow('ip', 0) && lim.allow('ip', 1));
  assert.ok(!lim.allow('ip', 2), 'third call in the window is refused');
  assert.ok(lim.allow('ip', 1001), 'window resets');
  assert.ok(lim.allow('other', 2), 'keys are independent');
});

test('speech endpointing: stops after trailing silence and caps runaway streams', () => {
  const tone = (secs: number, amp: number) => {
    const b = Buffer.alloc(Math.round(secs * 24000) * 2);
    for (let i = 0; i < b.length / 2; i++) b.writeInt16LE(Math.round(amp * Math.sin(i / 5)), i * 2);
    return b;
  };
  const e = new SpeechEndpoint('hi there. how are you');
  assert.equal(e.feed(tone(1, 8000)).length, 48000);
  e.heardText('Hi there.');
  e.feed(tone(1.2, 0));
  assert.ok(!e.done, 'a pause between sentences is not the end while words remain');
  e.feed(tone(1, 8000));
  e.heardText(' How are you?');
  assert.ok(e.scriptFinished);
  const tail = e.feed(tone(3, 0));
  assert.ok(e.done, '2 s of silence after the last word ends the clip');
  assert.ok(tail.length <= 2.05 * 24000 * 2);
  const hum = new SpeechEndpoint('one two');
  for (let i = 0; i < 20 && !hum.done; i++) hum.feed(tone(1, 1500));
  assert.ok(hum.done, 'a stream that never goes quiet is capped by script length');
});

test('referral handle parsing accepts a handle, @handle or the invite link', () => {
  assert.equal(referralHandleFrom('@sam'), 'sam');
  assert.equal(referralHandleFrom('sam'), 'sam');
  assert.equal(referralHandleFrom('awan.ffdev.studio/@sam_k'), 'sam_k');
  assert.equal(referralHandleFrom('https://awan.ffdev.studio/?ref=sam'), 'sam');
});

test('referral claim: once, young accounts only, never yourself, handle must exist', async () => {
  const { db, app } = await setup();
  const sam = await signIn(app, 'sam@b.co');
  const friend = await signIn(app, 'late-friend@b.co');
  const other = await signIn(app, 'other@b.co');
  const samHandle = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${sam}` } })).json().handle;
  const otherHandle = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${other}` } })).json().handle;
  const claim = (token: string, handle: unknown) =>
    app.inject({ method: 'POST', url: '/v1/referrals/claim', headers: { authorization: `Bearer ${token}` }, payload: { handle } });

  assert.equal((await claim(friend, '')).statusCode, 400, 'empty handle');
  const unknown = await claim(friend, 'nobody_here');
  assert.equal(unknown.statusCode, 400, 'unknown handle');
  assert.equal(unknown.json().error, 'unknown_handle');
  const self = await claim(sam, `@${samHandle}`);
  assert.equal(self.statusCode, 400);
  assert.equal(self.json().error, 'self_referral');

  const before = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${friend}` } })).json();
  assert.equal(before.canClaim, true);
  assert.equal(before.invitedBy, null);
  const ok = await claim(friend, `http://site.test/@${samHandle}`);
  const after = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${friend}` } })).json();
  assert.equal(after.canClaim, false);
  assert.equal(after.invitedBy.handle, samHandle);
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.json().referrer.handle, samHandle);
  const samId = (db.prepare('SELECT id FROM users WHERE email = ?').get('sam@b.co') as { id: string }).id;
  const row = () => (db.prepare('SELECT referred_by FROM users WHERE email = ?').get('late-friend@b.co') as { referred_by: string }).referred_by;
  assert.equal(row(), samId);

  const again = await claim(friend, otherHandle);
  assert.equal(again.statusCode, 409, 'a referrer is never replaced');
  assert.equal(again.json().error, 'already_claimed');
  assert.equal(row(), samId);

  // An account older than 30 days can no longer claim.
  db.prepare('UPDATE users SET created_at = ? WHERE email = ?').run(new Date(Date.now() - 31 * 86_400_000).toISOString(), 'other@b.co');
  const old = await claim(other, `https://site.test/?ref=${samHandle}`);
  assert.equal(old.statusCode, 409);
  assert.equal(old.json().error, 'account_too_old');

  const refs = (await app.inject({ method: 'GET', url: '/v1/referrals', headers: { authorization: `Bearer ${sam}` } })).json();
  assert.equal(refs.referrals.length, 1);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/referrals/claim', payload: { handle: samHandle } })).statusCode, 401);
});
test('TYPE blocks: parsed, never spoken, never streamed', () => {
  const r = parseAssistantTags("here you go, typing it in. [TYPE:640,812:reply box]sounds good: see you at 8 [ok]![/TYPE] [POINT:none]");
  assert.equal(r.typeText, 'sounds good: see you at 8 [ok]!');
  assert.equal(r.spokenText, 'here you go, typing it in.');
  const plain = parseAssistantTags('typing it. [TYPE]\nline one\nline two\n[/TYPE]');
  assert.equal(plain.typeText, 'line one\nline two');
  assert.equal(plain.spokenText, 'typing it.');
  const open = parseAssistantTags('typing it. [TYPE]half a mess');
  assert.equal(open.typeText, 'half a mess');
  assert.equal(open.spokenText, 'typing it.');
  assert.equal(parseAssistantTags('no typing here.').typeText, null);
  // streaming: the text inside the block is held back while open and dropped once closed
  assert.equal(safePrefix('typing it. [TYPE]dear sam, thanks for'), 'typing it. ');
  assert.equal(safePrefix('typing it. [TYPE:1,2:box]dear sam[/TYPE] done'), 'typing it.  done');
  assert.equal(safePrefix('typing it. [TY'), 'typing it. ');
});

test('IMAGES tag: query parsed and stripped from speech', () => {
  const r = parseAssistantTags('a small wallaby with a big grin. [IMAGES:quokka on rottnest island] [POINT:none]');
  assert.equal(r.imagesQuery, 'quokka on rottnest island');
  assert.equal(r.spokenText, 'a small wallaby with a big grin.');
  assert.equal(safePrefix('a wallaby. [IMAGES:quok'), 'a wallaby. ');
});

test('prompts teach TYPE, IMAGES and documents; realtime routes tags through a tool', () => {
  assert.ok(COMPANION_SYSTEM.includes('[TYPE]') && COMPANION_SYSTEM.includes('[/TYPE]'));
  assert.ok(COMPANION_SYSTEM.includes('[IMAGES:'));
  assert.ok(COMPANION_SYSTEM.includes('<document>'));
  assert.ok(REALTIME_ADDENDUM.includes('show_on_screen'));
});

test('document block: named, wrapped, truncated at 60k', () => {
  assert.equal(documentBlock(undefined), null);
  assert.equal(documentBlock({ name: 'x', text: '   ' }), null);
  const b = documentBlock({ name: 'Q3 "plan".pdf', text: 'hello world', kind: 'PDF' })!;
  assert.ok(b.includes('<document name="Q3  plan .pdf">\nhello world\n</document>'), b);
  const big = documentBlock({ name: 'big.txt', text: 'a'.repeat(DOCUMENT_MAX_CHARS + 500) })!;
  assert.ok(big.includes('500 more characters not shown'));
  assert.ok(big.length < DOCUMENT_MAX_CHARS + 400);
});

test('images: validated, deduped, capped at 8, cached for a day, fallback only when thin', async () => {
  clearImageCache();
  let proposeCalls = 0;
  let fallbackCalls = 0;
  const propose = async (): Promise<ImageResult[]> => {
    proposeCalls++;
    return [
      { title: 'good one', imageUrl: 'https://img.example.com/a.jpg', pageUrl: 'https://example.com/a' },
      { title: 'dupe', imageUrl: 'https://img.example.com/a.jpg', pageUrl: null },
      { title: 'html page', imageUrl: 'https://example.com/not-an-image', pageUrl: null },
      { title: 'private', imageUrl: 'http://192.168.1.4/cam.jpg', pageUrl: null },
      { title: 'localhost', imageUrl: 'http://localhost:8787/x.png', pageUrl: null },
      { title: 'file', imageUrl: 'file:///etc/passwd', pageUrl: null },
    ];
  };
  const fallback = async (): Promise<ImageResult[]> => {
    fallbackCalls++;
    return Array.from({ length: 12 }, (_, i) => ({ title: `c${i}`, imageUrl: `https://upload.example.org/${i}.png`, pageUrl: `https://commons.example.org/${i}` }));
  };
  const checked: string[] = [];
  const isImage = async (u: string) => {
    checked.push(u);
    return !u.includes('not-an-image');
  };
  const deps = { propose, fallback, isImage };

  const db = openDb(':memory:');
  const app = await buildApp({ db, devMode: true, publicUrl: 'http://api.test', siteUrl: 'http://site.test', imageSearch: deps });
  const token = await signIn(app, 'pics@example.com');
  const auth = { authorization: `Bearer ${token}` };

  assert.equal((await app.inject({ method: 'GET', url: '/v1/images?q=quokka' })).statusCode, 401);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/images?q=', headers: auth })).statusCode, 400);

  const r = await app.inject({ method: 'GET', url: '/v1/images?q=Quokka%20%20smiling', headers: auth });
  assert.equal(r.statusCode, 200);
  const images = r.json().images as ImageResult[];
  assert.equal(images.length, 8);
  assert.equal(images[0].imageUrl, 'https://img.example.com/a.jpg');
  assert.equal(images[0].pageUrl, 'https://example.com/a');
  assert.ok(!images.some((i) => /192\.168|localhost|file:|not-an-image/.test(i.imageUrl)));
  assert.ok(!checked.some((u) => /192\.168|localhost|file:/.test(u)), 'private URLs are never fetched');
  assert.equal(fallbackCalls, 1, 'one validated result is thin → fallback');

  // same query, different spacing/case → cache hit, no provider calls
  const again = await app.inject({ method: 'GET', url: '/v1/images?q=quokka%20smiling', headers: auth });
  assert.deepEqual(again.json().images, images);
  assert.equal(proposeCalls, 1);

  // cache expires after a day
  await searchImages('quokka smiling', deps, Date.now() + 25 * 3600_000);
  assert.equal(proposeCalls, 2);

  // nothing validates → empty list (the app shows no card)
  clearImageCache();
  const none = await searchImages('nothing', { propose: async () => [{ title: 'x', imageUrl: 'https://a.example.com/x', pageUrl: null }], isImage: async () => false });
  assert.deepEqual(none, []);
  // a rich first source never calls the fallback
  let fb = 0;
  await searchImages('rich', { propose: fallback, fallback: async () => (fb++, []), isImage: async () => true });
  assert.equal(fb, 0);
});

test('images: model JSON is parsed leniently; only public http(s) URLs pass', () => {
  assert.deepEqual(parseImageJson('```json\n{"images":[{"title":"a","imageUrl":"https://x.example.com/a.jpg","pageUrl":"https://x.example.com"}]}\n```'), [
    { title: 'a', imageUrl: 'https://x.example.com/a.jpg', pageUrl: 'https://x.example.com' },
  ]);
  assert.equal(parseImageJson('[{"title":"b","imageUrl":"https://y.example.com/b.png"}]').length, 1);
  assert.deepEqual(parseImageJson('sorry, nothing'), []);
  assert.ok(isPublicHttpUrl('https://upload.wikimedia.org/a.jpg'));
  for (const bad of ['ftp://x.example.com/a', 'http://127.0.0.1/a', 'http://10.0.0.2/a', 'http://172.20.1.1/a', 'http://[::1]/a', 'http://printer.local/a', 'http://intranet/a', 'nope']) {
    assert.ok(!isPublicHttpUrl(bad), bad);
  }
});
