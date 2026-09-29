import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { FastifyRequest } from 'fastify';
import { type DB, now, tx } from './db.ts';

export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');
export const opaqueToken = (prefix: string) => `${prefix}_${randomBytes(32).toString('base64url')}`;

export type User = {
  id: string;
  email: string;
  display_name: string;
  avatar_url: string | null;
  referral_handle: string;
  referred_by: string | null;
  discovery_channel: string | null;
  created_at: string;
};

const HANDLE_RE = /^[a-z0-9][a-z0-9_]{2,23}$/;

export function normaliseHandle(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9_]/g, '').slice(0, 24);
}

export function isValidHandle(h: string) {
  return HANDLE_RE.test(h);
}

function uniqueHandle(db: DB, seed: string): string {
  let base = normaliseHandle(seed) || 'friend';
  if (base.length < 3) base = `${base}awan`.slice(0, 24);
  for (let i = 0; i < 50; i++) {
    const candidate = i === 0 ? base : `${base.slice(0, 20)}${Math.floor(Math.random() * 9000 + 1000)}`;
    if (!db.prepare('SELECT 1 FROM users WHERE referral_handle = ?').get(candidate)) return candidate;
  }
  return `u${randomBytes(6).toString('hex')}`;
}

/** Find the user for an email, or create one (with a free subscription) inside one transaction. */
export function upsertUser(
  db: DB,
  email: string,
  profile: { displayName?: string; avatarUrl?: string | null; referral?: string | null } = {},
): { user: User; created: boolean } {
  return tx(db, () => {
    const existing = db.prepare('SELECT * FROM users WHERE email = ? AND deleted_at IS NULL').get(email) as User | undefined;
    if (existing) {
      if (profile.avatarUrl && !existing.avatar_url) {
        db.prepare('UPDATE users SET avatar_url = ? WHERE id = ?').run(profile.avatarUrl, existing.id);
        existing.avatar_url = profile.avatarUrl;
      }
      return { user: existing, created: false };
    }
    const id = randomUUID();
    const display = profile.displayName?.trim() || email.split('@')[0];
    const handle = uniqueHandle(db, email.split('@')[0]);
    let referredBy: string | null = null;
    if (profile.referral) {
      const ref = db
        .prepare('SELECT id FROM users WHERE referral_handle = ? AND deleted_at IS NULL')
        .get(normaliseHandle(profile.referral)) as { id: string } | undefined;
      referredBy = ref?.id ?? null;
    }
    db.prepare(
      'INSERT INTO users (id, email, display_name, avatar_url, referral_handle, referred_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    ).run(id, email, display, profile.avatarUrl ?? null, handle, referredBy, now());
    db.prepare("INSERT INTO subscriptions (user_id, plan, status, updated_at) VALUES (?, 'free', 'active', ?)").run(id, now());
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(id) as User;
    return { user, created: true };
  });
}

export function issueToken(db: DB, userId: string, label = 'app'): string {
  const token = opaqueToken('awn');
  db.prepare('INSERT INTO api_tokens (id, user_id, token_hash, label, created_at) VALUES (?, ?, ?, ?, ?)').run(
    randomUUID(),
    userId,
    sha256(token),
    label,
    now(),
  );
  return token;
}

export function revokeToken(db: DB, token: string) {
  db.prepare('UPDATE api_tokens SET revoked_at = ? WHERE token_hash = ?').run(now(), sha256(token));
}

export function userForToken(db: DB, token: string | undefined): User | null {
  if (!token) return null;
  const row = db
    .prepare(
      `SELECT u.* FROM api_tokens t JOIN users u ON u.id = t.user_id
       WHERE t.token_hash = ? AND t.revoked_at IS NULL AND u.deleted_at IS NULL`,
    )
    .get(sha256(token)) as User | undefined;
  if (!row) return null;
  db.prepare('UPDATE api_tokens SET last_used_at = ? WHERE token_hash = ?').run(now(), sha256(token));
  return row;
}

export function bearer(req: FastifyRequest): string | undefined {
  const h = req.headers.authorization;
  if (h?.startsWith('Bearer ')) return h.slice(7).trim();
  const k = req.headers['x-api-key'];
  return typeof k === 'string' ? k : undefined;
}

export function createMagicLink(db: DB, email: string, redirect: string, referral?: string | null): string {
  const code = randomBytes(24).toString('base64url');
  const created = new Date();
  db.prepare('INSERT INTO magic_links (token_hash, email, redirect, referral, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)').run(
    sha256(code),
    email,
    redirect,
    referral ?? null,
    now(created),
    now(new Date(created.getTime() + 15 * 60_000)),
  );
  return code;
}

/** Single-use: the UPDATE only succeeds once, so a double-click cannot mint two sessions. */
export function redeemMagicLink(db: DB, code: string): { email: string; redirect: string; referral: string | null } | null {
  return tx(db, () => {
    const row = db.prepare('SELECT * FROM magic_links WHERE token_hash = ?').get(sha256(code)) as
      | { email: string; redirect: string; referral: string | null; expires_at: string; used_at: string | null }
      | undefined;
    if (!row || row.used_at || new Date(row.expires_at) < new Date()) return null;
    db.prepare('UPDATE magic_links SET used_at = ? WHERE token_hash = ? AND used_at IS NULL').run(now(), sha256(code));
    return { email: row.email, redirect: row.redirect, referral: row.referral };
  });
}

export function publicUser(u: User) {
  return {
    id: u.id,
    email: u.email,
    displayName: u.display_name,
    avatarUrl: u.avatar_url,
    referralHandle: u.referral_handle,
    createdAt: u.created_at,
    discoveryChannel: u.discovery_channel,
  };
}
