import { type DB, now, tx } from './db.ts';

export type Plan = 'free' | 'pro' | 'max';
export type UsageKind = 'talk' | 'agent_message' | 'dictation' | 'realtime_minute';

/** null = unlimited. Mirrors the reference's plan snapshot (free 25/25, pro 150 agents, max 1000). */
export const PLAN_CAPS: Record<Plan, Record<UsageKind, number | null>> = {
  free: { talk: 25, agent_message: 25, dictation: 50, realtime_minute: 10 },
  pro: { talk: null, agent_message: 150, dictation: null, realtime_minute: 300 },
  max: { talk: null, agent_message: 1000, dictation: null, realtime_minute: 1200 },
};

/** Prices in USD cents. Yearly = 20% off, billed annually. */
export const PRICES = {
  pro: { month: 2000, year: 19200 },
  max: { month: 10000, year: 96000 },
} as const;

export const WINDOW_DAYS = 30;

export class QuotaExceeded extends Error {
  kind: UsageKind;
  cap: number;
  constructor(kind: UsageKind, cap: number) {
    super(`quota_exceeded:${kind}`);
    this.kind = kind;
    this.cap = cap;
  }
}

/** The current 30-day window, anchored on the account's sign-up instant (rolling, like the reference). */
export function currentWindow(createdAt: string, at = new Date()): { start: Date; end: Date } {
  const anchor = new Date(createdAt).getTime();
  const span = WINDOW_DAYS * 86_400_000;
  const n = Math.max(0, Math.floor((at.getTime() - anchor) / span));
  const start = new Date(anchor + n * span);
  return { start, end: new Date(start.getTime() + span) };
}

const RANK: Record<Plan, number> = { free: 0, pro: 1, max: 2 };

export type PlanSource = 'personal' | 'team';

/** The team seat that applies to a user right now (only while the team's subscription is active or past due). */
export function teamSeatFor(db: DB, userId: string): { teamId: string; name: string; seat: Plan; role: string; status: string } | null {
  const row = db
    .prepare('SELECT t.id AS teamId, t.name, t.status, m.seat, m.role FROM team_members m JOIN teams t ON t.id = m.team_id WHERE m.user_id = ?')
    .get(userId) as { teamId: string; name: string; status: string; seat: Plan; role: string } | undefined;
  if (!row || (row.status !== 'active' && row.status !== 'past_due')) return null;
  return row;
}

/**
 * Effective plan: a team member gets their seat's plan (with the team's subscription status); if their own
 * personal plan is better, that one wins, so joining a team never downgrades anyone.
 */
export function planFor(db: DB, userId: string): { plan: Plan; interval: string | null; status: string; source: PlanSource } {
  const personal = personalPlan(db, userId);
  const seat = teamSeatFor(db, userId);
  if (seat && RANK[seat.seat] > RANK[personal.plan]) return { plan: seat.seat, interval: 'month', status: seat.status, source: 'team' };
  return { ...personal, source: 'personal' };
}

function personalPlan(db: DB, userId: string): { plan: Plan; interval: string | null; status: string } {
  const row = db.prepare('SELECT plan, interval, status, current_period_end FROM subscriptions WHERE user_id = ?').get(userId) as
    | { plan: Plan; interval: string | null; status: string; current_period_end: string | null }
    | undefined;
  if (!row) return { plan: 'free', interval: null, status: 'active' };
  // A canceled or lapsed paid plan falls back to free caps; history is never deleted.
  const lapsed = row.current_period_end && new Date(row.current_period_end) < new Date();
  if (row.plan !== 'free' && (row.status === 'canceled' || lapsed)) return { plan: 'free', interval: null, status: row.status };
  return { plan: row.plan, interval: row.interval, status: row.status };
}

function userCreatedAt(db: DB, userId: string): string {
  const u = db.prepare('SELECT created_at FROM users WHERE id = ?').get(userId) as { created_at: string } | undefined;
  if (!u) throw new Error('unknown_user');
  return u.created_at;
}

export function usedInWindow(db: DB, userId: string, kind: UsageKind, windowStart: string): number {
  const r = db
    .prepare('SELECT COUNT(*) AS n FROM usage_events WHERE user_id = ? AND kind = ? AND window_start = ?')
    .get(userId, kind, windowStart) as { n: number };
  return r.n;
}

/**
 * The single door for spending quota. Check-and-insert happens inside BEGIN IMMEDIATE, so two
 * concurrent requests can never both take the last unit. `ref` makes a retry idempotent.
 */
export function consume(db: DB, userId: string, kind: UsageKind, ref?: string): { used: number; cap: number | null } {
  return tx(db, () => {
    const { plan } = planFor(db, userId);
    const cap = PLAN_CAPS[plan][kind];
    const { start } = currentWindow(userCreatedAt(db, userId));
    const ws = now(start);
    if (ref) {
      const dup = db.prepare('SELECT 1 FROM usage_events WHERE user_id = ? AND kind = ? AND ref = ?').get(userId, kind, ref);
      if (dup) return { used: usedInWindow(db, userId, kind, ws), cap };
    }
    const used = usedInWindow(db, userId, kind, ws);
    if (cap !== null && used >= cap) throw new QuotaExceeded(kind, cap);
    db.prepare('INSERT INTO usage_events (user_id, kind, window_start, ref, created_at) VALUES (?, ?, ?, ?, ?)').run(
      userId,
      kind,
      ws,
      ref ?? null,
      now(),
    );
    return { used: used + 1, cap };
  });
}

/** Whether one more unit is allowed right now (used by the model proxy, which must not spend). */
export function hasHeadroom(db: DB, userId: string, kind: UsageKind): boolean {
  const { plan } = planFor(db, userId);
  const cap = PLAN_CAPS[plan][kind];
  if (cap === null) return true;
  const { start } = currentWindow(userCreatedAt(db, userId));
  return usedInWindow(db, userId, kind, now(start)) <= cap;
}

/** Same shape as the reference's `lastKnownPlanSnapshot` so the app renders it 1:1. */
export function planSnapshot(db: DB, userId: string) {
  const { plan, interval, status, source } = planFor(db, userId);
  const seat = teamSeatFor(db, userId);
  const { start, end } = currentWindow(userCreatedAt(db, userId));
  const ws = now(start);
  const caps = PLAN_CAPS[plan];
  const entry = (kind: UsageKind) => ({ cap: caps[kind], used: usedInWindow(db, userId, kind, ws) });
  return {
    tier: plan,
    plan,
    interval,
    status,
    /** 'team' when the caps come from a team seat (the app shows "Included with your team plan"). */
    plan_source: source,
    team: seat ? { id: seat.teamId, name: seat.name, seat: seat.seat, role: seat.role } : null,
    billing_enforcement: 'on',
    usage: {
      window_resets_at: now(end),
      messages: entry('talk'),
      agents: entry('agent_message'),
      dictation: entry('dictation'),
      realtime_minutes: entry('realtime_minute'),
    },
    pro_yearly_available: true,
    max_yearly_available: true,
    pro_agents_cap: PLAN_CAPS.pro.agent_message,
    max_agents_cap: PLAN_CAPS.max.agent_message,
    prices: PRICES,
  };
}

export function setPlan(
  db: DB,
  userId: string,
  plan: Plan,
  interval: 'month' | 'year' | null,
  opts: { periodEnd?: string | null; stripeCustomerId?: string | null; stripeSubscriptionId?: string | null; status?: string } = {},
) {
  db.prepare(
    `INSERT INTO subscriptions (user_id, plan, interval, status, current_period_end, stripe_customer_id, stripe_subscription_id, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET plan = excluded.plan, interval = excluded.interval, status = excluded.status,
       current_period_end = excluded.current_period_end,
       stripe_customer_id = COALESCE(excluded.stripe_customer_id, subscriptions.stripe_customer_id),
       stripe_subscription_id = COALESCE(excluded.stripe_subscription_id, subscriptions.stripe_subscription_id),
       updated_at = excluded.updated_at`,
  ).run(
    userId,
    plan,
    interval,
    opts.status ?? 'active',
    opts.periodEnd ?? null,
    opts.stripeCustomerId ?? null,
    opts.stripeSubscriptionId ?? null,
    now(),
  );
}
