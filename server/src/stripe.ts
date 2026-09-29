/**
 * Stripe (test mode in this build). No SDK: a handful of REST calls and a hand-rolled webhook signature check,
 * so there is nothing to keep in sync. Keys and HTTP are injectable (AppOptions.stripe) so tests never reach
 * Stripe.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { type DB, now } from './db.ts';
import { PRICES, setPlan, type Plan } from './plans.ts';
import type { User } from './auth.ts';
import type { FetchLike } from './connectors.ts';

export type StripeConfig = {
  secretKey: string | null;
  webhookSecret: string;
  /** Coupon for referred friends' first month (personal monthly plans). */
  referralCoupon: string | null;
  fetch: FetchLike;
};

export function stripeConfigFromEnv(over: Partial<StripeConfig> = {}): StripeConfig {
  return {
    secretKey: over.secretKey !== undefined ? over.secretKey : (process.env.STRIPE_SECRET_KEY ?? null),
    webhookSecret: over.webhookSecret ?? process.env.STRIPE_WEBHOOK_SECRET ?? '',
    referralCoupon: over.referralCoupon !== undefined ? over.referralCoupon : (process.env.STRIPE_REFERRAL_COUPON || null),
    fetch: over.fetch ?? ((input, init) => fetch(input, init)),
  };
}

/** Env-only check, kept for callers outside the app instance. */
export const stripeConfigured = () => Boolean(process.env.STRIPE_SECRET_KEY?.startsWith('sk_'));

export type TeamSeats = { pro: number; max: number };
export type TeamStatus = 'active' | 'incomplete' | 'past_due' | 'canceled';

/** Stripe subscription status → the team's status (which gates every seat). */
export function teamStatusFromStripe(status: string | undefined, deleted = false): TeamStatus {
  if (deleted) return 'canceled';
  switch (status) {
    case 'active':
    case 'trialing':
      return 'active';
    case 'past_due':
    case 'unpaid':
      return 'past_due';
    case 'canceled':
    case 'incomplete_expired':
      return 'canceled';
    default:
      return 'incomplete';
  }
}

/** Which seat a subscription item pays for: explicit metadata first, else the unit price. */
export function seatOfItem(item: any): 'pro' | 'max' | null {
  const meta = item?.price?.metadata?.seat ?? item?.price?.product?.metadata?.seat ?? item?.metadata?.seat;
  if (meta === 'pro' || meta === 'max') return meta;
  const amount = Number(item?.price?.unit_amount);
  if (amount === PRICES.pro.month || amount === PRICES.pro.year) return 'pro';
  if (amount === PRICES.max.month || amount === PRICES.max.year) return 'max';
  return null;
}

export class StripeClient {
  cfg: StripeConfig;
  constructor(cfg: StripeConfig) {
    this.cfg = cfg;
  }

  get configured() {
    return Boolean(this.cfg.secretKey?.startsWith('sk_'));
  }

  async post(path: string, params: Record<string, string>) {
    return this.request('POST', path, params);
  }

  async get(path: string, params: Record<string, string>) {
    return this.request('GET', path, params);
  }

  private async request(method: 'GET' | 'POST', path: string, params: Record<string, string>) {
    const url = new URL(`https://api.stripe.com/v1/${path}`);
    if (method === 'GET') url.search = new URLSearchParams(params).toString();
    const res = await this.cfg.fetch(url, {
      method,
      headers: { Authorization: `Bearer ${this.cfg.secretKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: method === 'POST' ? new URLSearchParams(params).toString() : undefined,
    });
    const j = (await res.json()) as Record<string, any>;
    if (!res.ok) throw Object.assign(new Error(`stripe_error:${JSON.stringify(j.error ?? j).slice(0, 200)}`), { statusCode: 502 });
    return j;
  }

  async checkout(u: User, plan: Plan, interval: 'month' | 'year', siteUrl: string): Promise<string> {
    const cents = PRICES[plan as 'pro' | 'max'][interval];
    const params: Record<string, string> = {
      mode: 'subscription',
      customer_email: u.email,
      client_reference_id: u.id,
      success_url: 'awan://billing/success',
      cancel_url: `${siteUrl}/pricing`,
      'line_items[0][quantity]': '1',
      'line_items[0][price_data][currency]': 'usd',
      'line_items[0][price_data][unit_amount]': String(cents),
      'line_items[0][price_data][recurring][interval]': interval,
      'line_items[0][price_data][product_data][name]': plan === 'pro' ? 'Awan Pro' : 'Awan Max',
      'metadata[plan]': plan,
      'metadata[interval]': interval,
      'subscription_data[metadata][user_id]': u.id,
      'subscription_data[metadata][plan]': plan,
    };
    // Referred friends get 25% off their first month (monthly plans only).
    if (u.referred_by && interval === 'month' && this.cfg.referralCoupon) params['discounts[0][coupon]'] = this.cfg.referralCoupon;
    const session = await this.post('checkout/sessions', params);
    return String(session.url);
  }

  async portal(db: DB, u: User, siteUrl: string): Promise<string> {
    const row = db.prepare('SELECT stripe_customer_id FROM subscriptions WHERE user_id = ?').get(u.id) as { stripe_customer_id: string | null } | undefined;
    if (!row?.stripe_customer_id) throw Object.assign(new Error('no_stripe_customer'), { statusCode: 409 });
    const s = await this.post('billing_portal/sessions', { customer: row.stripe_customer_id, return_url: `${siteUrl}/account` });
    return String(s.url);
  }

  /**
   * Team checkout: one subscription, one line item per seat type (quantity = seats). A typed promo code is
   * resolved to its Stripe promotion code and applied; without one the Checkout page lets the buyer enter one.
   */
  async teamCheckout(
    team: { id: string; name: string; stripe_customer_id: string | null },
    owner: User,
    seats: TeamSeats,
    interval: 'month' | 'year',
    promoCode: string | null,
    publicUrl: string,
  ): Promise<string> {
    const params: Record<string, string> = {
      mode: 'subscription',
      client_reference_id: owner.id,
      success_url: `${publicUrl}/team?msg=${encodeURIComponent('Payment received. Seats switch on in a moment.')}`,
      cancel_url: `${publicUrl}/team`,
      'metadata[team_id]': team.id,
      'metadata[pro_seats]': String(seats.pro),
      'metadata[max_seats]': String(seats.max),
      'metadata[interval]': interval,
      'subscription_data[metadata][team_id]': team.id,
      'subscription_data[metadata][pro_seats]': String(seats.pro),
      'subscription_data[metadata][max_seats]': String(seats.max),
    };
    if (team.stripe_customer_id) params.customer = team.stripe_customer_id;
    else params.customer_email = owner.email;
    let i = 0;
    for (const seat of ['pro', 'max'] as const) {
      if (!seats[seat]) continue;
      params[`line_items[${i}][quantity]`] = String(seats[seat]);
      params[`line_items[${i}][price_data][currency]`] = 'usd';
      params[`line_items[${i}][price_data][unit_amount]`] = String(PRICES[seat][interval]);
      params[`line_items[${i}][price_data][recurring][interval]`] = interval;
      params[`line_items[${i}][price_data][product_data][name]`] = `Awan ${seat === 'pro' ? 'Pro' : 'Max'} seat · ${team.name}`;
      params[`line_items[${i}][price_data][product_data][metadata][seat]`] = seat;
      i++;
    }
    if (promoCode) {
      const found = await this.get('promotion_codes', { code: promoCode, active: 'true', limit: '1' });
      const id = found.data?.[0]?.id;
      if (!id) throw Object.assign(new Error('promo_code_not_found'), { statusCode: 400 });
      params['discounts[0][promotion_code]'] = String(id);
    } else {
      params.allow_promotion_codes = 'true';
    }
    const session = await this.post('checkout/sessions', params);
    return String(session.url);
  }

  async teamPortal(customerId: string, returnUrl: string): Promise<string> {
    const s = await this.post('billing_portal/sessions', { customer: customerId, return_url: returnUrl });
    return String(s.url);
  }

  async webhook(db: DB, req: FastifyRequest, reply: FastifyReply, onPaid: (db: DB, userId: string, invoiceRef: string, cents: number) => void) {
    const raw = (req as FastifyRequest & { rawBody?: string }).rawBody ?? '';
    if (!this.cfg.webhookSecret || !verifyStripeSignature(raw, req.headers['stripe-signature'] as string, this.cfg.webhookSecret)) {
      return reply.code(400).send({ error: 'bad_signature' });
    }
    const event = JSON.parse(raw) as { type: string; data: { object: Record<string, any> } };
    if (applyTeamEvent(db, event)) return reply.send({ received: true, team: true });
    const o = event.data.object;
    switch (event.type) {
      case 'checkout.session.completed': {
        const userId = o.client_reference_id as string;
        setPlan(db, userId, o.metadata.plan as Plan, o.metadata.interval, { stripeCustomerId: o.customer, stripeSubscriptionId: o.subscription });
        break;
      }
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted': {
        const userId = o.metadata?.user_id as string;
        if (!userId) break;
        const status = event.type.endsWith('deleted') || o.status === 'canceled' ? 'canceled' : o.status === 'past_due' ? 'past_due' : 'active';
        setPlan(db, userId, (o.metadata.plan as Plan) ?? 'pro', o.items?.data?.[0]?.price?.recurring?.interval ?? 'month', {
          status,
          periodEnd: o.current_period_end ? now(new Date(o.current_period_end * 1000)) : null,
          stripeSubscriptionId: o.id,
        });
        break;
      }
      case 'invoice.paid': {
        const sub = db.prepare('SELECT user_id FROM subscriptions WHERE stripe_customer_id = ?').get(o.customer) as { user_id: string } | undefined;
        if (sub && o.amount_paid > 0) onPaid(db, sub.user_id, o.id, o.amount_paid);
        break;
      }
    }
    return reply.send({ received: true });
  }
}

/** The team an event belongs to: metadata first, then the stored subscription id. */
function teamIdOf(db: DB, type: string, o: Record<string, any>): string | null {
  const meta = o.metadata?.team_id ?? o.subscription_details?.metadata?.team_id ?? o.parent?.subscription_details?.metadata?.team_id;
  if (typeof meta === 'string' && meta) return meta;
  const subId = type.startsWith('customer.subscription.') ? o.id : o.subscription;
  if (typeof subId !== 'string' || !subId) return null;
  return (db.prepare('SELECT id FROM teams WHERE stripe_subscription_id = ?').get(subId) as { id: string } | undefined)?.id ?? null;
}

const seatCount = (v: unknown) => {
  const n = Number(v);
  return Number.isInteger(n) && n >= 0 && n <= 10_000 ? n : null;
};

/**
 * Team subscription events → the team row. Returns false when the event isn't a team's (personal handling
 * continues). Seat counts come from the checkout metadata, then from the subscription's items (so a quantity
 * changed in the billing portal is honoured).
 */
export function applyTeamEvent(db: DB, event: { type: string; data: { object: Record<string, any> } }): boolean {
  const o = event.data.object;
  const teamId = teamIdOf(db, event.type, o);
  if (!teamId) return false;
  const team = db.prepare('SELECT id FROM teams WHERE id = ?').get(teamId);
  if (!team) return true; // a team's event for a team that no longer exists: acknowledge, change nothing
  const set = (fields: Record<string, unknown>) => {
    const keys = Object.keys(fields).filter((k) => fields[k] !== undefined);
    if (!keys.length) return;
    db.prepare(`UPDATE teams SET ${keys.map((k) => `${k} = ?`).join(', ')} WHERE id = ?`).run(...keys.map((k) => fields[k] as string | number | null), teamId);
  };
  switch (event.type) {
    case 'checkout.session.completed': {
      if (o.mode && o.mode !== 'subscription') return true;
      const paid = o.payment_status === undefined || o.payment_status === 'paid' || o.payment_status === 'no_payment_required';
      set({
        status: paid ? 'active' : 'incomplete',
        paid_pro_seats: seatCount(o.metadata?.pro_seats) ?? undefined,
        paid_max_seats: seatCount(o.metadata?.max_seats) ?? undefined,
        billing_interval: o.metadata?.interval === 'year' ? 'year' : o.metadata?.interval === 'month' ? 'month' : undefined,
        stripe_customer_id: typeof o.customer === 'string' ? o.customer : undefined,
        stripe_subscription_id: typeof o.subscription === 'string' ? o.subscription : undefined,
      });
      return true;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const seats: TeamSeats = { pro: 0, max: 0 };
      let counted = false;
      for (const item of (o.items?.data ?? []) as any[]) {
        const seat = seatOfItem(item);
        if (!seat) continue;
        seats[seat] += Number(item.quantity ?? 1);
        counted = true;
      }
      set({
        status: teamStatusFromStripe(o.status, event.type.endsWith('deleted')),
        ...(counted ? { paid_pro_seats: seats.pro, paid_max_seats: seats.max } : {}),
        billing_interval: o.items?.data?.[0]?.price?.recurring?.interval ?? undefined,
        current_period_end: o.current_period_end ? now(new Date(o.current_period_end * 1000)) : undefined,
        stripe_customer_id: typeof o.customer === 'string' ? o.customer : undefined,
        stripe_subscription_id: typeof o.id === 'string' ? o.id : undefined,
      });
      return true;
    }
    case 'invoice.payment_failed':
      set({ status: 'past_due' });
      return true;
    case 'invoice.paid':
      set({ status: 'active' });
      return true;
    default:
      return true;
  }
}

export function verifyStripeSignature(raw: string, header: string | undefined, secret: string, toleranceSec = 300): boolean {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(',').map((p) => p.split('=') as [string, string]));
  const t = Number(parts.t);
  if (!t || Math.abs(Date.now() / 1000 - t) > toleranceSec) return false;
  const expected = createHmac('sha256', secret).update(`${t}.${raw}`).digest('hex');
  const got = header
    .split(',')
    .filter((p) => p.startsWith('v1='))
    .map((p) => p.slice(3));
  return got.some((g) => g.length === expected.length && timingSafeEqual(Buffer.from(g), Buffer.from(expected)));
}

/** `Stripe-Signature` header for a payload (tests and local webhook replays). */
export function signStripePayload(raw: string, secret: string, t = Math.floor(Date.now() / 1000)): string {
  return `t=${t},v1=${createHmac('sha256', secret).update(`${t}.${raw}`).digest('hex')}`;
}
