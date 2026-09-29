import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp } from '../src/app.ts';
import { openDb } from '../src/db.ts';
import { planFor } from '../src/plans.ts';
import { signStripePayload, type StripeConfig } from '../src/stripe.ts';
import type { FetchLike } from '../src/connectors.ts';

process.env.LOG = '0';

const WHSEC = 'whsec_test_secret';

/** A stand-in for api.stripe.com: records every request, knows one promotion code. */
function fakeStripe() {
  const calls: { method: string; path: string; params: URLSearchParams }[] = [];
  const fetch: FetchLike = async (input, init = {}) => {
    const url = new URL(String(input));
    const method = init.method ?? 'GET';
    const params = method === 'GET' ? url.searchParams : new URLSearchParams(String(init.body ?? ''));
    const path = url.pathname.replace('/v1/', '');
    calls.push({ method, path, params });
    const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    if (path === 'promotion_codes') return json(200, { data: params.get('code') === 'KAWAN20' ? [{ id: 'promo_123', code: 'KAWAN20' }] : [] });
    if (path === 'checkout/sessions') return json(200, { id: 'cs_test_1', url: 'https://checkout.stripe.test/c/cs_test_1' });
    if (path === 'billing_portal/sessions') return json(200, { url: `https://billing.stripe.test/p/${params.get('customer')}` });
    return json(404, { error: { message: 'no fake' } });
  };
  return { fetch, calls };
}

async function setup(opts: { devMode?: boolean; stripe?: Partial<StripeConfig> | null } = {}) {
  const db = openDb(':memory:');
  const app = await buildApp({
    db,
    devMode: opts.devMode ?? true,
    publicUrl: 'http://api.test',
    siteUrl: 'http://site.test',
    mailer: null,
    googleClient: null,
    connectorKey: null,
    composioApiKey: null,
    stripe: opts.stripe === null || opts.stripe === undefined ? { secretKey: null, webhookSecret: '' } : opts.stripe,
  });
  return { db, app };
}

type App = Awaited<ReturnType<typeof setup>>['app'];

async function signIn(app: App, email: string, db?: ReturnType<typeof openDb>) {
  let token: string;
  if (db) {
    // Production mode has no dev links: mint a token directly.
    const { issueToken, upsertUser } = await import('../src/auth.ts');
    token = issueToken(db, upsertUser(db, email, {}).user.id);
  } else {
    const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email } });
    const code = new URL(r.json().devLink).searchParams.get('code')!;
    const v = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
    token = decodeURIComponent(/token=([^"&]+)/.exec(v.body)![1]);
  }
  const headers = { authorization: `Bearer ${token}` };
  const id = (await app.inject({ method: 'GET', url: '/v1/me', headers })).json().user.id as string;
  return { headers, id };
}

async function team(app: App, db?: ReturnType<typeof openDb>) {
  const owner = await signIn(app, 'owner@kopi.co', db);
  const t = (await app.inject({ method: 'POST', url: '/v1/teams', headers: owner.headers, payload: { name: 'Kopi Senja' } })).json();
  const invite = async (seat: string, headers = owner.headers) =>
    app.inject({ method: 'POST', url: `/v1/teams/${t.team.id}/invites`, headers, payload: { seat } });
  return { owner, teamId: t.team.id as string, invite };
}

/** Runs the dev checkout end to end (API → page → submit). */
async function devCheckout(app: App, headers: Record<string, string>, teamId: string, body: Record<string, unknown>) {
  const r = await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers, payload: body });
  assert.equal(r.statusCode, 200, r.body);
  const url = new URL(r.json().url);
  const page = await app.inject({ method: 'GET', url: url.pathname + url.search });
  assert.equal(page.statusCode, 200);
  const ticket = url.searchParams.get('ticket')!;
  const done = await app.inject({ method: 'POST', url: '/billing/dev-team-checkout', headers: { 'content-type': 'application/x-www-form-urlencoded' }, payload: `ticket=${encodeURIComponent(ticket)}` });
  return { page, done, ticket };
}

test('team checkout (dev): an incomplete team goes live with exactly the seats bought; tickets work once', async () => {
  const { app, db } = await setup();
  const { owner, teamId } = await team(app);
  db.prepare("UPDATE teams SET status = 'incomplete' WHERE id = ?").run(teamId); // as a production team starts
  assert.equal(planFor(db, owner.id).plan, 'free', 'an unpaid team seat gives nothing');
  const d0 = (await app.inject({ method: 'GET', url: '/v1/teams/me', headers: owner.headers })).json();
  assert.equal(d0.billing.needsCheckout, true);
  assert.equal(d0.paidSeats, null);

  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: 0, maxSeats: 0 } })).statusCode, 400);
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: 3, maxSeats: 0 } })).json().error, 'seats_below_members', 'the owner holds a Max seat');
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: -1, maxSeats: 1 } })).statusCode, 400);

  const { page, done, ticket } = await devCheckout(app, owner.headers, teamId, { proSeats: 2, maxSeats: 1, interval: 'month', promoCode: 'KAWAN20' });
  assert.match(page.body, /Pro seat × 2/);
  assert.match(page.body, /Max seat × 1/);
  assert.match(page.body, /\$140/, '2 × $20 + 1 × $100');
  assert.match(page.body, /promo KAWAN20/);
  assert.equal(done.statusCode, 303);
  assert.match(decodeURIComponent(String(done.headers.location)), /^\/team\?msg=Test checkout done: 2 Pro and 1 Max seats are live\./);
  const row = db.prepare('SELECT status, paid_pro_seats, paid_max_seats, billing_interval, promo_code FROM teams WHERE id = ?').get(teamId);
  assert.deepEqual({ ...row }, { status: 'active', paid_pro_seats: 2, paid_max_seats: 1, billing_interval: 'month', promo_code: 'KAWAN20' });
  assert.equal(planFor(db, owner.id).plan, 'max');
  const again = await app.inject({ method: 'POST', url: '/billing/dev-team-checkout', headers: { 'content-type': 'application/x-www-form-urlencoded' }, payload: `ticket=${encodeURIComponent(ticket)}` });
  assert.equal(again.statusCode, 400, 'a ticket works once');
  const d1 = (await app.inject({ method: 'GET', url: '/v1/teams/me', headers: owner.headers })).json();
  assert.deepEqual(d1.paidSeats, { pro: 2, max: 1 });
  assert.equal(d1.billing.amountCents, 14000);
  assert.equal(d1.billing.mode, 'dev');
});

test('team checkout: only the owner pays; without Stripe outside dev it is a 501', async () => {
  const { app } = await setup();
  const { owner, teamId, invite } = await team(app);
  const member = await signIn(app, 'm@kopi.co');
  await app.inject({ method: 'POST', url: '/v1/teams/join', headers: member.headers, payload: { code: (await invite('pro')).json().invite.code } });
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: member.headers, payload: { proSeats: 1, maxSeats: 1 } })).json().error, 'only_the_owner_pays');
  const outsider = await signIn(app, 'x@y.co');
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: outsider.headers, payload: { proSeats: 1, maxSeats: 1 } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/portal`, headers: owner.headers })).statusCode, 501);

  const prod = await setup({ devMode: false });
  const p = await team(prod.app, prod.db);
  const r = await prod.app.inject({ method: 'POST', url: `/v1/teams/${p.teamId}/checkout`, headers: p.owner.headers, payload: { proSeats: 1, maxSeats: 0 } });
  assert.equal(r.statusCode, 501);
  assert.equal(r.json().error, 'billing_unavailable');
  assert.equal((await prod.app.inject({ method: 'GET', url: '/billing/dev-team-checkout?ticket=x' })).statusCode, 404);
});

test('seat caps: invites reserve paid seats, joins and seat moves past the cap are refused with 409', async () => {
  const { app, db } = await setup();
  const { owner, teamId, invite } = await team(app);
  // Before any checkout a dev team is uncapped.
  const pre = await invite('pro');
  assert.equal(pre.statusCode, 200);
  db.prepare('DELETE FROM team_invites WHERE team_id = ?').run(teamId);

  await devCheckout(app, owner.headers, teamId, { proSeats: 2, maxSeats: 1 });
  const a = (await invite('pro')).json().invite.code;
  const b = (await invite('pro')).json().invite.code;
  const third = await invite('pro');
  assert.equal(third.statusCode, 409, 'two Pro seats, two open invites');
  assert.equal(third.json().error, 'no_free_seats');
  assert.equal((await invite('max')).statusCode, 409, 'the owner holds the only Max seat');

  const m1 = await signIn(app, 'm1@kopi.co');
  const m2 = await signIn(app, 'm2@kopi.co');
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m1.headers, payload: { code: a } })).statusCode, 200);
  // Moving a member to Max: no Max seat free.
  const move = await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${m1.id}`, headers: owner.headers, payload: { seat: 'max' } });
  assert.equal(move.statusCode, 409);
  assert.equal(move.json().error, 'no_free_seats');
  // Setting the same seat again is not a move.
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${m1.id}`, headers: owner.headers, payload: { seat: 'pro' } })).statusCode, 200);

  // Seats reduced after the invite went out (e.g. quantity lowered in the billing portal): the join is refused.
  db.prepare('UPDATE teams SET paid_pro_seats = 1 WHERE id = ?').run(teamId);
  const late = await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m2.headers, payload: { code: b } });
  assert.equal(late.statusCode, 409);
  assert.equal(late.json().error, 'no_free_seats');
  assert.equal(db.prepare('SELECT used_by FROM team_invites WHERE code = ?').get(b)!.used_by, null, 'a refused join leaves the code usable');
  const d = (await app.inject({ method: 'GET', url: '/v1/teams/me', headers: owner.headers })).json();
  assert.deepEqual(d.seats, { pro: 1, max: 1 });
  assert.deepEqual(d.paidSeats, { pro: 1, max: 1 });

  // Buying more seats reopens the door.
  await devCheckout(app, owner.headers, teamId, { proSeats: 3, maxSeats: 2 });
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m2.headers, payload: { code: b } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${m1.id}`, headers: owner.headers, payload: { seat: 'max' } })).statusCode, 200);
});

test('stripe team checkout: two line items, quantities = seats, team metadata, promo code passed through', async () => {
  const stripe = fakeStripe();
  const { app } = await setup({ stripe: { secretKey: 'sk_test_fake', webhookSecret: WHSEC, fetch: stripe.fetch } });
  const { owner, teamId } = await team(app);
  const r = await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: 4, maxSeats: 2, interval: 'year', promoCode: 'KAWAN20' } });
  assert.equal(r.statusCode, 200, r.body);
  assert.equal(r.json().url, 'https://checkout.stripe.test/c/cs_test_1');
  const lookup = stripe.calls.find((c) => c.path === 'promotion_codes')!;
  assert.equal(lookup.params.get('code'), 'KAWAN20');
  const s = stripe.calls.find((c) => c.path === 'checkout/sessions')!.params;
  assert.equal(s.get('mode'), 'subscription');
  assert.equal(s.get('line_items[0][quantity]'), '4');
  assert.equal(s.get('line_items[0][price_data][unit_amount]'), '19200');
  assert.equal(s.get('line_items[0][price_data][recurring][interval]'), 'year');
  assert.equal(s.get('line_items[0][price_data][product_data][metadata][seat]'), 'pro');
  assert.equal(s.get('line_items[1][quantity]'), '2');
  assert.equal(s.get('line_items[1][price_data][unit_amount]'), '96000');
  assert.equal(s.get('metadata[team_id]'), teamId);
  assert.equal(s.get('subscription_data[metadata][team_id]'), teamId);
  assert.equal(s.get('discounts[0][promotion_code]'), 'promo_123');
  assert.equal(s.get('allow_promotion_codes'), null, 'Stripe forbids both at once');
  assert.equal(s.get('customer_email'), 'owner@kopi.co');

  await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: 0, maxSeats: 1 } });
  const plain = stripe.calls.filter((c) => c.path === 'checkout/sessions')[1].params;
  assert.equal(plain.get('allow_promotion_codes'), 'true', 'no code typed → the buyer can enter one on Stripe');
  assert.equal(plain.get('line_items[0][quantity]'), '1');
  assert.equal(plain.get('line_items[0][price_data][product_data][metadata][seat]'), 'max');
  assert.equal(plain.get('line_items[1][quantity]'), null, 'a zero-seat line is left out');
  const bad = await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: 1, maxSeats: 1, promoCode: 'NOPE' } });
  assert.equal(bad.statusCode, 400);
  assert.equal(bad.json().error, 'promo_code_not_found');
});

test('stripe team webhooks: signature checked; completed → active with seats; updates follow quantities and status; delete cancels', async () => {
  const stripe = fakeStripe();
  const { app, db } = await setup({ stripe: { secretKey: 'sk_test_fake', webhookSecret: WHSEC, fetch: stripe.fetch } });
  const { owner, teamId, invite } = await team(app);
  db.prepare("UPDATE teams SET status = 'incomplete' WHERE id = ?").run(teamId);
  const member = await signIn(app, 'mem@kopi.co');
  await app.inject({ method: 'POST', url: '/v1/teams/join', headers: member.headers, payload: { code: (await invite('pro')).json().invite.code } });
  const send = (event: unknown, secret = WHSEC) => {
    const raw = JSON.stringify(event);
    return app.inject({ method: 'POST', url: '/v1/billing/webhook', headers: { 'content-type': 'application/json', 'stripe-signature': signStripePayload(raw, secret) }, payload: raw });
  };

  const completed = {
    type: 'checkout.session.completed',
    data: { object: { mode: 'subscription', payment_status: 'paid', client_reference_id: owner.id, customer: 'cus_team', subscription: 'sub_team', metadata: { team_id: teamId, pro_seats: '3', max_seats: '1', interval: 'month' } } },
  };
  assert.equal((await send(completed, 'whsec_wrong')).statusCode, 400, 'a forged event is refused');
  assert.equal(db.prepare('SELECT status FROM teams WHERE id = ?').get(teamId)!.status, 'incomplete');
  const ok = await send(completed);
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.json().team, true);
  assert.deepEqual({ ...db.prepare('SELECT status, paid_pro_seats, paid_max_seats, stripe_customer_id, stripe_subscription_id FROM teams WHERE id = ?').get(teamId) }, {
    status: 'active',
    paid_pro_seats: 3,
    paid_max_seats: 1,
    stripe_customer_id: 'cus_team',
    stripe_subscription_id: 'sub_team',
  });
  assert.equal(planFor(db, member.id).plan, 'pro');
  assert.deepEqual({ ...db.prepare('SELECT plan, stripe_customer_id FROM subscriptions WHERE user_id = ?').get(owner.id) }, { plan: 'free', stripe_customer_id: null }, 'the owner’s personal plan is untouched');

  // Quantity changed in the portal, payment failing: seats follow the items, status goes past_due.
  const updated = {
    type: 'customer.subscription.updated',
    data: {
      object: {
        id: 'sub_team',
        customer: 'cus_team',
        status: 'past_due',
        current_period_end: 1_790_000_000,
        metadata: { team_id: teamId },
        items: { data: [{ quantity: 5, price: { unit_amount: 2000, recurring: { interval: 'month' } } }, { quantity: 2, price: { unit_amount: 10000, recurring: { interval: 'month' } } }] },
      },
    },
  };
  assert.equal((await send(updated)).statusCode, 200);
  assert.deepEqual({ ...db.prepare('SELECT status, paid_pro_seats, paid_max_seats FROM teams WHERE id = ?').get(teamId) }, { status: 'past_due', paid_pro_seats: 5, paid_max_seats: 2 });
  assert.equal(planFor(db, member.id).plan, 'pro', 'past due keeps seats working');

  // With a live Stripe subscription, seat changes go through the portal.
  const again = await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/checkout`, headers: owner.headers, payload: { proSeats: 6, maxSeats: 2 } });
  assert.equal(again.json().error, 'use_billing_portal');
  const portal = await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/portal`, headers: owner.headers });
  assert.equal(portal.json().url, 'https://billing.stripe.test/p/cus_team');
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/portal`, headers: member.headers })).statusCode, 403);

  // Deleted, no metadata on the event: the team is found by its subscription id.
  const deleted = { type: 'customer.subscription.deleted', data: { object: { id: 'sub_team', customer: 'cus_team', status: 'canceled', items: { data: [] } } } };
  assert.equal((await send(deleted)).statusCode, 200);
  assert.equal(db.prepare('SELECT status FROM teams WHERE id = ?').get(teamId)!.status, 'canceled');
  assert.equal(planFor(db, member.id).plan, 'free', 'a canceled team gives no seats');

  // A personal subscription event still reaches the personal handler.
  const personal = { type: 'checkout.session.completed', data: { object: { client_reference_id: member.id, customer: 'cus_me', subscription: 'sub_me', metadata: { plan: 'max', interval: 'month' } } } };
  assert.equal((await send(personal)).json().team, undefined);
  assert.equal(planFor(db, member.id).plan, 'max');
});

test('team dashboard: Seats & billing shows paid vs used seats; owners get Buy seats, which leads to checkout', async () => {
  const { app } = await setup();
  const { owner, teamId, invite } = await team(app);
  const member = await signIn(app, 'dash@kopi.co');
  await app.inject({ method: 'POST', url: '/v1/teams/join', headers: member.headers, payload: { code: (await invite('pro')).json().invite.code } });
  const open = async (headers: Record<string, string>) => {
    const link = (await app.inject({ method: 'POST', url: '/v1/teams/dashboard-link', headers })).json().url as string;
    const first = await app.inject({ method: 'GET', url: link.replace('http://api.test', '') });
    const cookie = String(first.headers['set-cookie']).split(';')[0];
    const page = await app.inject({ method: 'GET', url: '/team', headers: { cookie } });
    return { cookie, page, csrf: /name="csrf" value="([^"]+)"/.exec(page.body)?.[1] ?? '' };
  };
  const o = await open(owner.headers);
  assert.match(o.page.body, /Seats &amp; billing/);
  assert.match(o.page.body, /Buy seats/);
  assert.match(o.page.body, /name="promoCode"/);
  const go = await app.inject({
    method: 'POST',
    url: '/team/checkout',
    headers: { cookie: o.cookie, 'content-type': 'application/x-www-form-urlencoded' },
    payload: `proSeats=2&maxSeats=1&interval=month&promoCode=&csrf=${encodeURIComponent(o.csrf)}`,
  });
  assert.equal(go.statusCode, 303);
  assert.match(String(go.headers.location), /^http:\/\/api\.test\/billing\/dev-team-checkout\?ticket=/);
  const tooFew = await app.inject({
    method: 'POST',
    url: '/team/checkout',
    headers: { cookie: o.cookie, 'content-type': 'application/x-www-form-urlencoded' },
    payload: `proSeats=0&maxSeats=1&interval=month&csrf=${encodeURIComponent(o.csrf)}`,
  });
  assert.equal(String(tooFew.headers.location), '/team?err=seats_below_members');
  const shown = await app.inject({ method: 'GET', url: '/team?err=seats_below_members', headers: { cookie: o.cookie } });
  assert.match(shown.body, /fewer seats than people already hold/);
  const forged = await app.inject({ method: 'POST', url: '/team/checkout', headers: { cookie: o.cookie }, payload: { proSeats: 2, maxSeats: 1, csrf: 'nope' } });
  assert.equal(forged.statusCode, 403);

  // Paid: used / paid on the stats.
  const url = new URL(String(go.headers.location));
  await app.inject({ method: 'POST', url: '/billing/dev-team-checkout', headers: { 'content-type': 'application/x-www-form-urlencoded' }, payload: `ticket=${encodeURIComponent(url.searchParams.get('ticket')!)}` });
  const paid = await app.inject({ method: 'GET', url: '/team', headers: { cookie: o.cookie } });
  assert.match(paid.body, /1<small> \/ 2<\/small><\/b><span>Pro seats used \/ paid/);
  assert.match(paid.body, /Change seats/);

  const m = await open(member.headers);
  assert.match(m.page.body, /Only the team owner can change seats and billing/);
  assert.doesNotMatch(m.page.body, /action="\/team\/checkout"/);
  assert.equal(teamId.length > 0, true);
});
