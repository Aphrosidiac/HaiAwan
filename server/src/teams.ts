import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { type DB, now, tx } from './db.ts';
import { sha256, opaqueToken, type User } from './auth.ts';
import { PRICES } from './plans.ts';
import type { StripeClient, TeamSeats } from './stripe.ts';

/**
 * Teams v0 (the reference's Teams: seats are a mix of Pro and Max, a web dashboard of members / seats /
 * billing, team-shared skills). One team per user. Roles: owner > admin > member.
 *   owner  — everything; the only one who changes roles; can't be removed or demoted.
 *   admin  — invites, changes seats, removes members (not other admins or the owner).
 *   member — sees the team; can leave.
 */

export type TeamRole = 'owner' | 'admin' | 'member';
export type Seat = 'pro' | 'max';
export type TeamMembership = { id: string; name: string; owner_id: string; status: string; role: TeamRole; seat: Seat };

export const INVITE_DAYS = 7;
const SEATS: Seat[] = ['pro', 'max'];
const ROLE_ORDER: Record<TeamRole, number> = { owner: 0, admin: 1, member: 2 };

const httpError = (status: number, message: string) => Object.assign(new Error(message), { statusCode: status });

export function teamOf(db: DB, userId: string): TeamMembership | null {
  return (
    (db
      .prepare('SELECT t.id, t.name, t.owner_id, t.status, m.role, m.seat FROM team_members m JOIN teams t ON t.id = m.team_id WHERE m.user_id = ?')
      .get(userId) as TeamMembership | undefined) ?? null
  );
}

const isManager = (m: TeamMembership | null, teamId: string) => Boolean(m && m.id === teamId && (m.role === 'owner' || m.role === 'admin'));

// ───────────────────────────── seats & billing ─────────────────────────────

export type TeamBillingRow = {
  id: string;
  name: string;
  owner_id: string;
  status: string;
  paid_pro_seats: number | null;
  paid_max_seats: number | null;
  billing_interval: string | null;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  current_period_end: string | null;
  promo_code: string | null;
};

export function teamRow(db: DB, teamId: string): TeamBillingRow | null {
  return (db.prepare('SELECT * FROM teams WHERE id = ?').get(teamId) as TeamBillingRow | undefined) ?? null;
}

/** Seats a team has paid for; null until its first checkout (then nothing is capped). */
export function paidSeats(t: Pick<TeamBillingRow, 'paid_pro_seats' | 'paid_max_seats'> | null): TeamSeats | null {
  if (!t || t.paid_pro_seats === null || t.paid_max_seats === null) return null;
  return { pro: t.paid_pro_seats, max: t.paid_max_seats };
}

/** Seats held by members, and seats reserved by open (unused, unexpired) invites. */
export function seatUsage(db: DB, teamId: string): { members: TeamSeats; invites: TeamSeats } {
  const count = (sql: string, ...args: string[]) => {
    const out: TeamSeats = { pro: 0, max: 0 };
    for (const r of db.prepare(sql).all(...args) as { seat: Seat; n: number }[]) out[r.seat] = Number(r.n);
    return out;
  };
  return {
    members: count('SELECT seat, COUNT(*) AS n FROM team_members WHERE team_id = ? GROUP BY seat', teamId),
    invites: count('SELECT seat, COUNT(*) AS n FROM team_invites WHERE team_id = ? AND used_by IS NULL AND expires_at > ? GROUP BY seat', teamId, now()),
  };
}

/**
 * Refuses (409 no_free_seats) when one more `seat` would exceed what the team paid for. `reserveInvite` counts
 * open invites too (creating an invite or moving someone reserves a seat); a join redeems its own invite.
 */
function assertSeatFree(db: DB, teamId: string, seat: Seat, how: 'invite' | 'join' | 'move') {
  const paid = paidSeats(teamRow(db, teamId));
  if (!paid) return;
  const { members, invites } = seatUsage(db, teamId);
  const taken = members[seat] + (how === 'join' ? 0 : invites[seat]);
  if (taken >= paid[seat]) {
    throw Object.assign(httpError(409, 'no_free_seats'), { seat, paid: paid[seat], taken });
  }
}

export const MAX_TEAM_SEATS = 500;

export type CheckoutRequest = { proSeats: number; maxSeats: number; interval: 'month' | 'year'; promoCode: string | null };

/** Validates a checkout body; the owner pays, and never for fewer seats than people already hold. */
export function validateTeamCheckout(db: DB, actor: User, teamId: string, body: Record<string, unknown>): { team: TeamBillingRow; req: CheckoutRequest } {
  const t = teamRow(db, teamId);
  const mine = teamOf(db, actor.id);
  if (!t || !mine || mine.id !== teamId) throw httpError(403, 'not_in_this_team');
  if (mine.role !== 'owner') throw httpError(403, 'only_the_owner_pays');
  const int = (v: unknown) => {
    const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : typeof v === 'number' ? v : NaN;
    return Number.isInteger(n) && n >= 0 && n <= MAX_TEAM_SEATS ? n : null;
  };
  const pro = int(body.proSeats);
  const max = int(body.maxSeats);
  if (pro === null || max === null) throw httpError(400, 'bad_seat_count');
  if (pro + max < 1) throw httpError(400, 'at_least_one_seat');
  const interval = body.interval === 'year' ? 'year' : body.interval === 'month' || body.interval === undefined ? 'month' : null;
  if (!interval) throw httpError(400, 'bad_interval');
  const rawPromo = typeof body.promoCode === 'string' ? body.promoCode.trim() : '';
  if (rawPromo && !/^[A-Za-z0-9_-]{1,40}$/.test(rawPromo)) throw httpError(400, 'bad_promo_code');
  const { members } = seatUsage(db, teamId);
  if (members.pro > pro || members.max > max) {
    throw Object.assign(httpError(409, 'seats_below_members'), { members });
  }
  return { team: t, req: { proSeats: pro, maxSeats: max, interval, promoCode: rawPromo || null } };
}

/** Dev checkout (no Stripe): the team goes live with exactly the seats bought, for one period. */
export function activateTeamDev(db: DB, teamId: string, req: CheckoutRequest) {
  const end = new Date(Date.now() + (req.interval === 'year' ? 365 : 30) * 86_400_000);
  db.prepare(
    `UPDATE teams SET status = 'active', paid_pro_seats = ?, paid_max_seats = ?, billing_interval = ?, current_period_end = ?, promo_code = ? WHERE id = ?`,
  ).run(req.proSeats, req.maxSeats, req.interval, now(end), req.promoCode, teamId);
}

const seatsTotalCents = (seats: TeamSeats, interval: 'month' | 'year') => seats.pro * PRICES.pro[interval] + seats.max * PRICES.max[interval];

export function inviteCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const b = randomBytes(8);
  const chars = [...b].map((x) => alphabet[x % alphabet.length]).join('');
  return `AWN-${chars.slice(0, 4)}-${chars.slice(4)}`;
}

export function normaliseInviteCode(raw: string): string {
  const s = raw.trim().toUpperCase().replace(/\s+/g, '');
  const bare = s.replace(/^AWN-?/, '').replace(/-/g, '');
  return bare.length === 8 ? `AWN-${bare.slice(0, 4)}-${bare.slice(4)}` : s;
}

export function createTeam(db: DB, user: User, name: string, opts: { devMode: boolean }) {
  const clean = name.trim().slice(0, 60);
  if (!clean) throw httpError(400, 'team_name_required');
  return tx(db, () => {
    if (teamOf(db, user.id)) throw httpError(409, 'already_in_a_team');
    const id = randomUUID();
    const at = now();
    // In dev the team is live at once with a Max seat for the owner and no seat cap until its first checkout.
    // Elsewhere it stays 'incomplete' (seats don't apply) until the owner pays at /team → Seats & billing.
    db.prepare('INSERT INTO teams (id, name, owner_id, status, created_at) VALUES (?, ?, ?, ?, ?)').run(id, clean, user.id, opts.devMode ? 'active' : 'incomplete', at);
    db.prepare("INSERT INTO team_members (team_id, user_id, role, seat, joined_at) VALUES (?, ?, 'owner', ?, ?)").run(id, user.id, opts.devMode ? 'max' : 'pro', at);
    return teamOf(db, user.id)!;
  });
}

export function createInvite(db: DB, actor: User, teamId: string, seat: string, email?: string | null) {
  if (!isManager(teamOf(db, actor.id), teamId)) throw httpError(403, 'not_a_team_manager');
  if (!SEATS.includes(seat as Seat)) throw httpError(400, 'bad_seat');
  const e = email?.trim() || null;
  if (e && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw httpError(400, 'bad_email');
  assertSeatFree(db, teamId, seat as Seat, 'invite');
  const code = inviteCode();
  const at = new Date();
  const expires = now(new Date(at.getTime() + INVITE_DAYS * 86_400_000));
  db.prepare('INSERT INTO team_invites (code, team_id, email, seat, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)').run(
    code,
    teamId,
    e,
    seat,
    actor.id,
    now(at),
    expires,
  );
  return { code, seat, email: e, expiresAt: expires };
}

/** Single use: the conditional UPDATE claims the code, so two racing joins can't both get in. */
export function joinTeam(db: DB, user: User, rawCode: string) {
  const code = normaliseInviteCode(rawCode);
  return tx(db, () => {
    const inv = db.prepare('SELECT * FROM team_invites WHERE code = ?').get(code) as
      | { code: string; team_id: string; email: string | null; seat: Seat; expires_at: string; used_by: string | null }
      | undefined;
    if (!inv) throw httpError(404, 'invalid_code');
    if (inv.used_by) throw httpError(409, 'code_already_used');
    if (new Date(inv.expires_at) < new Date()) throw httpError(410, 'code_expired');
    if (inv.email && inv.email.toLowerCase() !== user.email.toLowerCase()) throw httpError(403, 'invite_is_for_another_email');
    if (teamOf(db, user.id)) throw httpError(409, 'already_in_a_team');
    assertSeatFree(db, inv.team_id, inv.seat, 'join');
    const r = db.prepare('UPDATE team_invites SET used_by = ?, used_at = ? WHERE code = ? AND used_by IS NULL').run(user.id, now(), code);
    if (Number(r.changes) === 0) throw httpError(409, 'code_already_used');
    db.prepare("INSERT INTO team_members (team_id, user_id, role, seat, joined_at) VALUES (?, ?, 'member', ?, ?)").run(inv.team_id, user.id, inv.seat, now());
    return teamOf(db, user.id)!;
  });
}

export function updateMember(db: DB, actor: User, teamId: string, targetId: string, change: { seat?: string; role?: string }) {
  return tx(db, () => {
    const me = teamOf(db, actor.id);
    if (!isManager(me, teamId)) throw httpError(403, 'not_a_team_manager');
    const target = teamOf(db, targetId);
    if (!target || target.id !== teamId) throw httpError(404, 'member_not_found');
    if (change.seat !== undefined) {
      if (!SEATS.includes(change.seat as Seat)) throw httpError(400, 'bad_seat');
      if (change.seat !== target.seat) assertSeatFree(db, teamId, change.seat as Seat, 'move');
      db.prepare('UPDATE team_members SET seat = ? WHERE team_id = ? AND user_id = ?').run(change.seat, teamId, targetId);
    }
    if (change.role !== undefined) {
      if (me!.role !== 'owner') throw httpError(403, 'only_the_owner_changes_roles');
      if (target.role === 'owner') throw httpError(400, 'owner_role_is_fixed');
      if (change.role !== 'admin' && change.role !== 'member') throw httpError(400, 'bad_role');
      db.prepare('UPDATE team_members SET role = ? WHERE team_id = ? AND user_id = ?').run(change.role, teamId, targetId);
    }
    return teamOf(db, targetId)!;
  });
}

/** Remove someone (or yourself: leaving). Their team-shared skills stop being shared. */
export function removeMember(db: DB, actor: User, teamId: string, targetId: string) {
  tx(db, () => {
    const me = teamOf(db, actor.id);
    const target = teamOf(db, targetId);
    if (!target || target.id !== teamId) throw httpError(404, 'member_not_found');
    if (target.role === 'owner') throw httpError(400, 'owner_cannot_leave');
    const self = actor.id === targetId;
    if (!self) {
      if (!isManager(me, teamId)) throw httpError(403, 'not_a_team_manager');
      if (me!.role === 'admin' && target.role !== 'member') throw httpError(403, 'admins_remove_members_only');
    }
    db.prepare('DELETE FROM team_members WHERE team_id = ? AND user_id = ?').run(teamId, targetId);
    db.prepare('UPDATE skills SET team_id = NULL WHERE created_by = ? AND team_id = ?').run(targetId, teamId);
  });
}

/** Owner deleting their account takes the team with them (members fall back to their own plans). */
export function dissolveTeamsOf(db: DB, userId: string) {
  const t = teamOf(db, userId);
  if (!t) return;
  if (t.role === 'owner') {
    db.prepare('UPDATE skills SET team_id = NULL WHERE team_id = ?').run(t.id);
    db.prepare('DELETE FROM teams WHERE id = ?').run(t.id);
  } else {
    db.prepare('DELETE FROM team_members WHERE user_id = ?').run(userId);
    db.prepare('UPDATE skills SET team_id = NULL WHERE created_by = ? AND team_id = ?').run(userId, t.id);
  }
}

export function teamDetail(db: DB, viewerId: string, opts: { stripe?: boolean } = {}) {
  const t = teamOf(db, viewerId);
  if (!t) return { team: null };
  const row = teamRow(db, t.id)!;
  const paid = paidSeats(row);
  const interval = (row.billing_interval === 'year' ? 'year' : 'month') as 'month' | 'year';
  const members = db
    .prepare(
      `SELECT m.user_id, u.display_name, u.email, u.avatar_url, m.role, m.seat, m.joined_at
       FROM team_members m JOIN users u ON u.id = m.user_id WHERE m.team_id = ?`,
    )
    .all(t.id) as { user_id: string; display_name: string; email: string; avatar_url: string | null; role: TeamRole; seat: Seat; joined_at: string }[];
  members.sort((a, b) => ROLE_ORDER[a.role] - ROLE_ORDER[b.role] || a.joined_at.localeCompare(b.joined_at));
  const seats = { pro: members.filter((m) => m.seat === 'pro').length, max: members.filter((m) => m.seat === 'max').length };
  const manager = t.role === 'owner' || t.role === 'admin';
  const invites = manager
    ? (db
        .prepare('SELECT code, email, seat, created_at, expires_at FROM team_invites WHERE team_id = ? AND used_by IS NULL AND expires_at > ? ORDER BY created_at DESC')
        .all(t.id, now()) as { code: string; email: string | null; seat: Seat; created_at: string; expires_at: string }[])
    : [];
  const skills = db
    .prepare('SELECT slug, title, one_liner, symbol, color, author_name FROM skills WHERE team_id = ? ORDER BY title COLLATE NOCASE')
    .all(t.id) as { slug: string; title: string; one_liner: string; symbol: string; color: string; author_name: string }[];
  return {
    team: { id: t.id, name: t.name, status: t.status, ownerId: t.owner_id },
    me: { role: t.role, seat: t.seat, canManage: manager },
    members: members.map((m) => ({
      userId: m.user_id,
      name: m.display_name,
      email: m.email,
      avatarUrl: m.avatar_url,
      role: m.role,
      seat: m.seat,
      joinedAt: m.joined_at,
    })),
    seats,
    /** What the team paid for (null = never checked out: seats uncapped in dev, not live elsewhere). */
    paidSeats: paid,
    billing: {
      monthlyCents: seats.pro * PRICES.pro.month + seats.max * PRICES.max.month,
      interval: paid ? interval : null,
      /** The subscription amount per interval for the paid seats (null before checkout). */
      amountCents: paid ? seatsTotalCents(paid, interval) : null,
      currency: 'usd',
      mode: opts.stripe ? 'stripe' : 'dev',
      periodEnd: row.current_period_end,
      promoCode: t.role === 'owner' ? row.promo_code : null,
      canCheckout: t.role === 'owner',
      portal: Boolean(opts.stripe && row.stripe_customer_id && t.role === 'owner'),
      needsCheckout: row.status === 'incomplete',
    },
    invites: invites.map((i) => ({ code: i.code, email: i.email, seat: i.seat, createdAt: i.created_at, expiresAt: i.expires_at })),
    skills: skills.map((s) => ({ slug: s.slug, title: s.title, oneLiner: s.one_liner, symbol: s.symbol, color: s.color, author: s.author_name })),
  };
}

// ───────────────────────────── routes ─────────────────────────────

export function registerTeamRoutes(
  app: FastifyInstance,
  db: DB,
  opts: { devMode: boolean; publicUrl: string; stripe?: StripeClient; userForId: (id: string) => User | null },
) {
  const me = (req: FastifyRequest) => req.user as User;
  const stripeOn = () => Boolean(opts.stripe?.configured);
  const detail = (userId: string) => teamDetail(db, userId, { stripe: stripeOn() });

  /**
   * Where the owner pays for `req`: Stripe Checkout when STRIPE_SECRET_KEY is set; in dev a local page that
   * activates the team with exactly those seats. A team already billed by Stripe changes seats in the portal.
   */
  const checkoutUrl = async (actor: User, teamId: string, body: Record<string, unknown>): Promise<string> => {
    const { team, req } = validateTeamCheckout(db, actor, teamId, body);
    if (stripeOn()) {
      if (team.stripe_subscription_id && (team.status === 'active' || team.status === 'past_due')) throw httpError(409, 'use_billing_portal');
      return opts.stripe!.teamCheckout(team, actor, { pro: req.proSeats, max: req.maxSeats }, req.interval, req.promoCode, opts.publicUrl);
    }
    if (!opts.devMode) throw httpError(501, 'billing_unavailable');
    const ticket = randomBytes(24).toString('base64url');
    db.prepare(
      'INSERT INTO team_checkouts (ticket_hash, team_id, user_id, pro_seats, max_seats, interval, promo_code, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run(sha256(ticket), teamId, actor.id, req.proSeats, req.maxSeats, req.interval, req.promoCode, now(), now(new Date(Date.now() + 30 * 60_000)));
    return `${opts.publicUrl}/billing/dev-team-checkout?ticket=${encodeURIComponent(ticket)}`;
  };

  const portalUrl = async (actor: User, teamId: string): Promise<string> => {
    const mine = teamOf(db, actor.id);
    if (!mine || mine.id !== teamId || mine.role !== 'owner') throw httpError(403, 'only_the_owner_pays');
    if (!stripeOn()) throw httpError(501, 'billing_portal_unavailable');
    const t = teamRow(db, teamId);
    if (!t?.stripe_customer_id) throw httpError(409, 'no_stripe_customer');
    return opts.stripe!.teamPortal(t.stripe_customer_id, `${opts.publicUrl}/team`);
  };

  app.post('/v1/teams/:id/checkout', async (req) => ({ url: await checkoutUrl(me(req), (req.params as { id: string }).id, (req.body ?? {}) as Record<string, unknown>) }));
  app.post('/v1/teams/:id/portal', async (req) => ({ url: await portalUrl(me(req), (req.params as { id: string }).id) }));

  const ticketRow = (ticket: string | undefined) =>
    ticket
      ? ((db.prepare('SELECT * FROM team_checkouts WHERE ticket_hash = ?').get(sha256(ticket)) as
          | { team_id: string; user_id: string; pro_seats: number; max_seats: number; interval: 'month' | 'year'; promo_code: string | null; expires_at: string; used_at: string | null }
          | undefined) ?? null)
      : null;

  app.get('/billing/dev-team-checkout', async (req, reply) => {
    if (!opts.devMode) return reply.code(404).send();
    const q = req.query as { ticket?: string };
    const row = ticketRow(q.ticket);
    const t = row ? teamRow(db, row.team_id) : null;
    if (!row || !t || row.used_at || new Date(row.expires_at) < new Date()) {
      return reply.code(400).type('text/html').send(shell('Checkout expired', `<p class="lede">Start again from the team dashboard → Seats &amp; billing.</p>`));
    }
    return reply.type('text/html').send(devTeamCheckoutHtml(t.name, { pro: row.pro_seats, max: row.max_seats }, row.interval, row.promo_code, q.ticket!));
  });

  app.post('/billing/dev-team-checkout', async (req, reply) => {
    if (!opts.devMode) return reply.code(404).send();
    const ticket = String((req.body as { ticket?: unknown } | undefined)?.ticket ?? '');
    const row = tx(db, () => {
      const r = ticketRow(ticket);
      if (!r || r.used_at || new Date(r.expires_at) < new Date()) return null;
      db.prepare('UPDATE team_checkouts SET used_at = ? WHERE ticket_hash = ? AND used_at IS NULL').run(now(), sha256(ticket));
      // Seats may have filled up since the page opened: re-check against current members.
      const { members } = seatUsage(db, r.team_id);
      if (members.pro > r.pro_seats || members.max > r.max_seats) throw httpError(409, 'seats_below_members');
      activateTeamDev(db, r.team_id, { proSeats: r.pro_seats, maxSeats: r.max_seats, interval: r.interval, promoCode: r.promo_code });
      return r;
    });
    if (!row) return reply.code(400).type('text/html').send(shell('Checkout expired', `<p class="lede">That checkout was already used or expired. Start again from the team dashboard.</p>`));
    const msg = `Test checkout done: ${row.pro_seats} Pro and ${row.max_seats} Max seat${row.pro_seats + row.max_seats === 1 ? '' : 's'} are live.`;
    return reply.redirect(`/team?msg=${encodeURIComponent(msg)}`, 303);
  });

  app.post('/v1/teams', async (req) => {
    createTeam(db, me(req), String((req.body as { name?: unknown })?.name ?? ''), opts);
    return detail(me(req).id);
  });

  app.get('/v1/teams/me', async (req) => detail(me(req).id));

  app.post('/v1/teams/:id/invites', async (req) => {
    const b = (req.body ?? {}) as { email?: string; seat?: string };
    return { invite: createInvite(db, me(req), (req.params as { id: string }).id, b.seat ?? 'pro', b.email) };
  });

  app.post('/v1/teams/join', async (req) => {
    joinTeam(db, me(req), String((req.body as { code?: unknown })?.code ?? ''));
    return detail(me(req).id);
  });

  app.patch('/v1/teams/:id/members/:userId', async (req) => {
    const p = req.params as { id: string; userId: string };
    updateMember(db, me(req), p.id, p.userId, (req.body ?? {}) as { seat?: string; role?: string });
    return detail(me(req).id);
  });

  app.delete('/v1/teams/:id/members/:userId', async (req) => {
    const p = req.params as { id: string; userId: string };
    removeMember(db, me(req), p.id, p.userId);
    return detail(me(req).id);
  });

  /** One-time link (10 minutes) that opens the web dashboard signed in. */
  app.post('/v1/teams/dashboard-link', async (req, reply) => {
    const u = me(req);
    if (!teamOf(db, u.id)) return reply.code(409).send({ error: 'not_in_a_team' });
    const code = randomBytes(24).toString('base64url');
    db.prepare('INSERT INTO team_dashboard_links (code_hash, user_id, expires_at) VALUES (?, ?, ?)').run(sha256(code), u.id, now(new Date(Date.now() + 10 * 60_000)));
    return { url: `${opts.publicUrl}/team?code=${encodeURIComponent(code)}` };
  });

  // ───────── web dashboard ─────────
  const COOKIE = 'awan_team';
  const secure = opts.publicUrl.startsWith('https://');

  const session = (req: FastifyRequest): { user: User; csrf: string } | null => {
    const raw = String(req.headers.cookie ?? '')
      .split(';')
      .map((c) => c.trim())
      .find((c) => c.startsWith(`${COOKIE}=`));
    if (!raw) return null;
    const token = decodeURIComponent(raw.slice(COOKIE.length + 1));
    const row = db.prepare('SELECT user_id, csrf, expires_at FROM team_sessions WHERE token_hash = ?').get(sha256(token)) as
      | { user_id: string; csrf: string; expires_at: string }
      | undefined;
    if (!row || new Date(row.expires_at) < new Date()) return null;
    const user = opts.userForId(row.user_id);
    return user ? { user, csrf: row.csrf } : null;
  };

  app.get('/team', async (req, reply) => {
    const q = req.query as { code?: string; msg?: string; err?: string };
    if (q.code) {
      const used = tx(db, () => {
        const row = db.prepare('SELECT user_id, expires_at, used_at FROM team_dashboard_links WHERE code_hash = ?').get(sha256(q.code!)) as
          | { user_id: string; expires_at: string; used_at: string | null }
          | undefined;
        if (!row || row.used_at || new Date(row.expires_at) < new Date()) return null;
        db.prepare('UPDATE team_dashboard_links SET used_at = ? WHERE code_hash = ?').run(now(), sha256(q.code!));
        return row.user_id;
      });
      if (!used) return reply.code(400).type('text/html').send(shell('Link expired', `<p class="lede">That dashboard link has already been used or expired. Open it again from Awan → Settings → Account → Manage team.</p>`));
      const token = opaqueToken('tms');
      db.prepare('INSERT INTO team_sessions (token_hash, user_id, csrf, expires_at) VALUES (?, ?, ?, ?)').run(
        sha256(token),
        used,
        randomBytes(18).toString('base64url'),
        now(new Date(Date.now() + 12 * 3600_000)),
      );
      reply.header('Set-Cookie', `${COOKIE}=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Path=/team; Max-Age=43200${secure ? '; Secure' : ''}`);
      return reply.redirect('/team');
    }
    const s = session(req);
    if (!s) return reply.code(401).type('text/html').send(shell('Open this from Awan', `<p class="lede">For your safety the team dashboard only opens from the app: Awan → Settings → Account → Manage team.</p>`));
    return reply.type('text/html').send(dashboardHtml(detail(s.user.id), s.user, s.csrf, q.msg, q.err));
  });

  const formAction = (path: string, run: (s: { user: User }, body: Record<string, string>) => string) =>
    app.post(path, async (req, reply) => {
      const s = session(req);
      const body = (req.body ?? {}) as Record<string, string>;
      if (!s) return reply.code(401).type('text/html').send(shell('Session ended', `<p class="lede">Open the dashboard again from Awan.</p>`));
      if (body.csrf !== s.csrf) return reply.code(403).type('text/html').send(shell('Try again', `<p class="lede">That form was stale. Reload the dashboard and try again.</p>`));
      try {
        return reply.redirect(`/team?msg=${encodeURIComponent(run(s, body))}`);
      } catch (err) {
        return reply.redirect(`/team?err=${encodeURIComponent((err as Error).message)}`);
      }
    });

  // Checkout and portal leave the dashboard for Stripe (or the dev checkout page).
  const redirectAction = (path: string, run: (s: { user: User }, body: Record<string, string>) => Promise<string>) =>
    app.post(path, async (req, reply) => {
      const s = session(req);
      const body = (req.body ?? {}) as Record<string, string>;
      if (!s) return reply.code(401).type('text/html').send(shell('Session ended', `<p class="lede">Open the dashboard again from Awan.</p>`));
      if (body.csrf !== s.csrf) return reply.code(403).type('text/html').send(shell('Try again', `<p class="lede">That form was stale. Reload the dashboard and try again.</p>`));
      try {
        return reply.redirect(await run(s, body), 303);
      } catch (err) {
        return reply.redirect(`/team?err=${encodeURIComponent((err as Error).message)}`, 303);
      }
    });
  redirectAction('/team/checkout', (s, b) => checkoutUrl(s.user, teamOf(db, s.user.id)?.id ?? '', b));
  redirectAction('/team/portal', (s) => portalUrl(s.user, teamOf(db, s.user.id)?.id ?? ''));

  formAction('/team/invite', (s, b) => {
    const t = teamOf(db, s.user.id);
    const inv = createInvite(db, s.user, t?.id ?? '', b.seat, b.email);
    return `Invite code ${inv.code} (${inv.seat === 'max' ? 'Max' : 'Pro'} seat${inv.email ? `, for ${inv.email}` : ''}) — valid ${INVITE_DAYS} days, single use.`;
  });
  formAction('/team/member', (s, b) => {
    const t = teamOf(db, s.user.id);
    if (b.action === 'remove') {
      removeMember(db, s.user, t?.id ?? '', b.userId);
      return b.userId === s.user.id ? 'You left the team.' : 'Removed from the team.';
    }
    updateMember(db, s.user, t?.id ?? '', b.userId, { seat: b.seat || undefined, role: b.role || undefined });
    return 'Saved.';
  });
}

// ───────────────────────────── HTML ─────────────────────────────

function esc(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}

const CSS = `:root{color-scheme:dark;--ink:#0B0B0A;--graphite:#242421;--card:#1B1B19;--bone:#F3EFE4;--grey:#8B8981;--lime:#D9FF43;--line:rgba(255,255,255,.08);--danger:#FF6B5E}
*{box-sizing:border-box}body{margin:0;background:var(--ink);color:var(--bone);font:15px/1.5 "Instrument Sans",-apple-system,system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:40px 24px 80px}.mark{font-weight:700;letter-spacing:-.02em;color:var(--grey);font-size:14px}
h1{font-weight:600;font-size:34px;letter-spacing:-.02em;margin:14px 0 4px}h2{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--grey);margin:36px 0 12px;font-weight:600}
.lede{color:var(--grey);margin:0}.chip{display:inline-block;border:1px solid var(--line);border-radius:999px;padding:2px 10px;font-size:12px;color:var(--grey);margin-left:8px;vertical-align:middle}
.chip.on{color:var(--ink);background:var(--bone);border-color:var(--bone)}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px 18px}.stat b{display:block;font-size:30px;font-weight:600;letter-spacing:-.02em}.stat span{color:var(--grey);font-size:13px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:16px;overflow:hidden}th,td{text-align:left;padding:12px 14px;border-bottom:1px solid var(--line);font-size:14px;vertical-align:middle}
th{color:var(--grey);font-weight:500;font-size:12px}tr:last-child td{border-bottom:0}.who b{display:block;font-weight:600}.who span{color:var(--grey);font-size:12.5px}
select,input{background:var(--graphite);color:var(--bone);border:1px solid var(--line);border-radius:10px;padding:8px 10px;font:inherit;font-size:13.5px}
button{font:inherit;font-size:13.5px;border-radius:999px;border:1px solid var(--line);background:var(--graphite);color:var(--bone);padding:8px 14px;cursor:pointer}
button.key{background:var(--lime);color:var(--ink);border-color:var(--lime);font-weight:600}button.danger{color:var(--danger);background:transparent}
form.inline{display:inline-flex;gap:6px;align-items:center;margin:0}.invite{display:flex;gap:10px;flex-wrap:wrap;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px}
.invite input{flex:1;min-width:220px}.flash{border-radius:12px;padding:12px 14px;margin-top:20px;background:rgba(217,255,67,.1);border:1px solid rgba(217,255,67,.35)}.flash.err{background:rgba(255,107,94,.1);border-color:rgba(255,107,94,.4)}
code{font-family:ui-monospace,Menlo,monospace;background:var(--graphite);padding:2px 7px;border-radius:6px}.skills{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}
.skill{display:flex;gap:12px;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px}.dot{width:34px;height:34px;border-radius:10px;flex:none}.skill b{display:block}.skill span{color:var(--grey);font-size:13px}
.empty{color:var(--grey);background:var(--card);border:1px dashed var(--line);border-radius:16px;padding:18px}.stat small{font-size:16px;color:var(--grey);font-weight:500}
.buy{margin-top:14px;align-items:center}.buy label{display:flex;gap:8px;align-items:center;color:var(--grey);font-size:13px}.buy input[type=number]{width:74px}.buy input[name=promoCode]{flex:1;min-width:160px}.note{color:var(--grey);font-size:12.5px;margin-top:8px}
@media (max-width:640px){th:nth-child(4),td:nth-child(4){display:none}main{padding:28px 16px 60px}}`;

function shell(title: string, body: string) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)} · Awan Teams</title><style>${CSS}</style></head><body><main><div class="mark">//FF · Awan Teams</div><h1>${esc(title)}</h1>${body}</main></body></html>`;
}

const money = (cents: number) => `$${(cents / 100).toLocaleString('en-US', { maximumFractionDigits: 0 })}`;
const seatName = (s: string) => (s === 'max' ? 'Max' : 'Pro');

function friendlyError(code: string): string {
  switch (code) {
    case 'no_free_seats': return 'Every paid seat of that kind is taken (open invites hold a seat too). Buy more seats below, or move someone.';
    case 'seats_below_members': return 'That’s fewer seats than people already hold. Pick at least as many as your team uses, or move or remove someone first.';
    case 'only_the_owner_pays': return 'Only the team owner can change billing.';
    case 'use_billing_portal': return 'Your team is already billed through Stripe. Change seat counts in Manage billing.';
    case 'promo_code_not_found': return 'That promo code isn’t valid.';
    case 'billing_unavailable': return 'Billing isn’t set up on this Awan server yet.';
    default: return code.replace(/_/g, ' ');
  }
}

function billingSection(d: ReturnType<typeof teamDetail>, hidden: string): string {
  const b = d.billing!;
  const paid = d.paidSeats ?? null;
  const used = d.seats!;
  const per = b.interval === 'year' ? 'year' : 'month';
  const seatStat = (seat: 'pro' | 'max') =>
    `<div class="stat"><b>${paid ? `${used[seat]}<small> / ${paid[seat]}</small>` : used[seat]}</b><span>${seatName(seat)} seats${paid ? ' used / paid' : ''} · ${money(PRICES[seat].month)}/mo each</span></div>`;
  const amount = paid
    ? `<div class="stat"><b>${money(b.amountCents!)}</b><span>Per ${per}${b.mode === 'stripe' ? '' : ' · test checkout, nothing is charged'}</span></div>`
    : `<div class="stat"><b>${money(b.monthlyCents)}</b><span>${b.needsCheckout ? 'Per month once you check out' : 'Per month at today’s seats · not billed yet'}</span></div>`;
  const status = d.team!.status;
  const banner =
    status === 'incomplete'
      ? `<div class="flash">Seats switch on once checkout is done. Pick the seats you need below.</div>`
      : status === 'past_due'
        ? `<div class="flash err">The last payment didn’t go through. Seats keep working for now — update the card in Manage billing.</div>`
        : status === 'canceled'
          ? `<div class="flash err">This team’s subscription has ended, so its seats are off. Check out again to switch them back on.</div>`
          : '';
  const renews = paid && b.periodEnd ? `<p class="note">Current period ends ${esc(b.periodEnd.slice(0, 10))}${b.promoCode ? ` · promo ${esc(b.promoCode)}` : ''}.</p>` : '';
  const stripeBilled = b.portal && (status === 'active' || status === 'past_due');
  const buy = !b.canCheckout
    ? `<p class="note">Only the team owner can change seats and billing.</p>`
    : stripeBilled
      ? ''
      : `<form class="invite buy" method="post" action="/team/checkout">${hidden}
        <label>Pro seats <input name="proSeats" type="number" min="0" max="500" value="${Math.max(used.pro, paid?.pro ?? 0)}"></label>
        <label>Max seats <input name="maxSeats" type="number" min="0" max="500" value="${Math.max(used.max, paid?.max ?? 0)}"></label>
        <select name="interval"><option value="month"${b.interval !== 'year' ? ' selected' : ''}>Monthly</option><option value="year"${b.interval === 'year' ? ' selected' : ''}>Yearly (20% off)</option></select>
        <input name="promoCode" placeholder="Promo code (optional)" maxlength="40" autocomplete="off">
        <button${status === 'incomplete' || status === 'canceled' ? ' class="key"' : ''}>${paid ? 'Change seats' : 'Buy seats'}</button>
      </form>
      <p class="note">${b.mode === 'stripe' ? 'You’ll finish on Stripe’s secure checkout. Seats switch on as soon as the payment clears.' : 'Test mode: a local checkout page stands in for Stripe and no card is charged.'} Everyone keeps their seat; you can’t buy fewer seats than people already hold.</p>`;
  const portal = stripeBilled
    ? `<form class="inline" method="post" action="/team/portal" style="margin-top:12px">${hidden}<button class="key">Manage billing</button></form>
       <p class="note">Change seat counts, the card or invoices on Stripe’s billing page.</p>`
    : '';
  return `<h2>Seats &amp; billing</h2>${banner}
    <div class="stats" style="margin-top:12px">
      <div class="stat"><b>${d.members!.length}</b><span>Members</span></div>
      ${seatStat('pro')}
      ${seatStat('max')}
      ${amount}
    </div>${renews}
    ${buy}${portal}`;
}

function devTeamCheckoutHtml(teamName: string, seats: TeamSeats, interval: 'month' | 'year', promo: string | null, ticket: string) {
  const total = seatsTotalCents(seats, interval);
  const line = (seat: 'pro' | 'max') =>
    seats[seat] ? `<tr><td>${seatName(seat)} seat × ${seats[seat]}</td><td style="text-align:right">${money(PRICES[seat][interval] * seats[seat])}</td></tr>` : '';
  return shell(
    `Checkout · ${teamName}`,
    `<p class="lede">Test mode — no card is charged. This page stands in for Stripe Checkout.</p>
    <table style="margin-top:20px">${line('pro')}${line('max')}<tr><td><b>Total per ${interval}</b>${promo ? `<span class="chip">promo ${esc(promo)} · applied by Stripe in live mode</span>` : ''}</td><td style="text-align:right"><b>${money(total)}</b></td></tr></table>
    <form method="post" action="/billing/dev-team-checkout" style="margin-top:20px"><input type="hidden" name="ticket" value="${esc(ticket)}"><button class="key">Subscribe (test)</button></form>`,
  );
}

function dashboardHtml(d: ReturnType<typeof teamDetail>, viewer: User, csrf: string, msg?: string, err?: string) {
  if (!d.team) return shell('No team yet', `<p class="lede">You're not in a team any more. Create or join one from Awan → Settings → Account.</p>`);
  const canManage = d.me!.canManage;
  const isOwner = d.me!.role === 'owner';
  const hidden = `<input type="hidden" name="csrf" value="${esc(csrf)}">`;
  const rows = d.members!
    .map((m) => {
      const self = m.userId === viewer.id;
      const editable = canManage && m.role !== 'owner';
      const seatCell = editable
        ? `<form class="inline" method="post" action="/team/member">${hidden}<input type="hidden" name="userId" value="${esc(m.userId)}"><input type="hidden" name="action" value="seat">
             <select name="seat" onchange="this.form.submit()">${['pro', 'max'].map((s) => `<option value="${s}"${s === m.seat ? ' selected' : ''}>${seatName(s)}</option>`).join('')}</select></form>`
        : seatName(m.seat);
      const roleCell =
        isOwner && m.role !== 'owner'
          ? `<form class="inline" method="post" action="/team/member">${hidden}<input type="hidden" name="userId" value="${esc(m.userId)}"><input type="hidden" name="action" value="role">
             <select name="role" onchange="this.form.submit()">${['member', 'admin'].map((r) => `<option value="${r}"${r === m.role ? ' selected' : ''}>${r[0].toUpperCase() + r.slice(1)}</option>`).join('')}</select></form>`
          : m.role[0].toUpperCase() + m.role.slice(1);
      const canRemove = m.role !== 'owner' && (self || (canManage && (isOwner || m.role === 'member')));
      const remove = canRemove
        ? `<form class="inline" method="post" action="/team/member" onsubmit="return confirm('${self ? 'Leave the team?' : 'Remove this member?'}')">${hidden}<input type="hidden" name="userId" value="${esc(m.userId)}"><input type="hidden" name="action" value="remove"><button class="danger">${self ? 'Leave' : 'Remove'}</button></form>`
        : '';
      return `<tr><td class="who"><b>${esc(m.name)}${self ? ' (you)' : ''}</b><span>${esc(m.email)}</span></td><td>${roleCell}</td><td>${seatCell}</td><td>${esc(m.joinedAt.slice(0, 10))}</td><td style="text-align:right">${remove}</td></tr>`;
    })
    .join('');
  const invites = canManage
    ? `<h2>Invite</h2>
      <form class="invite" method="post" action="/team/invite">${hidden}
        <input name="email" type="email" placeholder="Their email (optional — leave blank for a code anyone can use once)">
        <select name="seat"><option value="pro">Pro seat</option><option value="max">Max seat</option></select>
        <button class="key">Create invite</button>
      </form>
      <p class="note">They join from Awan → Settings → Account → Join a team. Codes work once and last 7 days.</p>
      ${
        d.invites!.length
          ? `<table style="margin-top:12px"><tr><th>Code</th><th>For</th><th>Seat</th><th>Expires</th></tr>${d.invites!
              .map((i) => `<tr><td><code>${esc(i.code)}</code></td><td>${esc(i.email ?? 'Anyone')}</td><td>${seatName(i.seat)}</td><td>${esc(i.expiresAt.slice(0, 10))}</td></tr>`)
              .join('')}</table>`
          : ''
      }`
    : '';
  const skills = d.skills!.length
    ? `<div class="skills">${d.skills!
        .map((s) => `<div class="skill"><div class="dot" style="background:${esc(s.color)}"></div><div><b>${esc(s.title)}</b><span>${esc(s.oneLiner)}</span><span> · by ${esc(s.author)}</span></div></div>`)
        .join('')}</div>`
    : `<div class="empty">No team skills yet. In Awan, open Skills → My skills and choose “Share with team”.</div>`;
  const flash = msg ? `<div class="flash">${esc(msg)}</div>` : err ? `<div class="flash err">${esc(friendlyError(err))}</div>` : '';
  const body = `<p class="lede">${esc(seatName(d.me!.seat))} seat · ${esc(d.me!.role)}<span class="chip${d.team.status === 'active' ? ' on' : ''}">${esc(d.team.status)}</span></p>${flash}
    ${billingSection(d, hidden)}
    <h2>Members</h2>
    <table><tr><th>Member</th><th>Role</th><th>Seat</th><th>Joined</th><th></th></tr>${rows}</table>
    ${invites}
    <h2>Team skills</h2>${skills}`;
  return shell(d.team.name, body);
}
