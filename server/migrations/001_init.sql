-- Awan API — initial schema.
-- Tenancy: per user. Every user-owned row carries user_id and every query filters on it.
-- Time: ISO-8601 UTC text ('YYYY-MM-DDTHH:MM:SS.sssZ'). Money: integer cents (USD).

CREATE TABLE users (
  id               TEXT PRIMARY KEY,                 -- uuid v4
  email            TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name     TEXT NOT NULL DEFAULT '',
  avatar_url       TEXT,
  referral_handle  TEXT NOT NULL UNIQUE COLLATE NOCASE, -- awan.ffdev.studio/@handle
  referred_by      TEXT REFERENCES users(id) ON DELETE SET NULL,
  discovery_channel TEXT,                            -- onboarding "where did you hear about us"
  created_at       TEXT NOT NULL,
  deleted_at       TEXT
);

-- Opaque bearer tokens; only the SHA-256 is stored.
CREATE TABLE api_tokens (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  label       TEXT NOT NULL DEFAULT 'app',
  created_at  TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at  TEXT
);
CREATE INDEX api_tokens_user ON api_tokens(user_id);

CREATE TABLE magic_links (
  token_hash  TEXT PRIMARY KEY,
  email       TEXT NOT NULL COLLATE NOCASE,
  redirect    TEXT NOT NULL,                         -- awan://auth or web callback
  referral    TEXT,                                  -- referral handle captured at sign-up
  created_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  used_at     TEXT
);

-- One row per user. plan in ('free','pro','max'); interval in ('month','year').
CREATE TABLE subscriptions (
  user_id            TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  plan               TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free','pro','max')),
  interval           TEXT CHECK (interval IN ('month','year')),
  status             TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','past_due','canceled')),
  current_period_end TEXT,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT UNIQUE,
  updated_at         TEXT NOT NULL
);

-- Append-only usage ledger. The count per (user, kind, window) is the quota truth.
-- kind in ('talk','agent_message','dictation','realtime_minute')
CREATE TABLE usage_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('talk','agent_message','dictation','realtime_minute')),
  window_start TEXT NOT NULL,                        -- start of the 30-day window it counts against
  ref         TEXT,                                  -- thread id / request id, for idempotency
  created_at  TEXT NOT NULL,
  UNIQUE (user_id, kind, ref)
);
CREATE INDEX usage_events_window ON usage_events(user_id, kind, window_start);

-- Server-side record of a user's agents (the "roster"): the app is the source of truth for
-- local threads; the server keeps what it generated so suggestions can target them.
CREATE TABLE awans (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slug        TEXT NOT NULL,
  name        TEXT NOT NULL,
  role_text   TEXT NOT NULL,
  one_liner   TEXT NOT NULL,
  spec_json   TEXT NOT NULL,                         -- full generated spec (asks, intro, hue, portrait)
  created_at  TEXT NOT NULL,
  archived_at TEXT,
  PRIMARY KEY (user_id, slug)
);

-- Suggested agent tasks ("Suggested for you"). status: pending → accepted | declined | expired.
CREATE TABLE suggestions (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  awan_slug     TEXT NOT NULL,
  title         TEXT NOT NULL,
  description   TEXT NOT NULL,
  agent_prompt  TEXT NOT NULL,
  app_hint      TEXT,                                -- e.g. 'Safari' chip on the card
  routine_every_minutes INTEGER,
  routine_title TEXT,
  check_reason  TEXT NOT NULL CHECK (check_reason IN ('onboarding','morning','manual')),
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','declined','expired')),
  created_at    TEXT NOT NULL,
  decided_at    TEXT
);
CREATE INDEX suggestions_user ON suggestions(user_id, status);

-- User profile answers from the onboarding interview (goal, role, tools).
CREATE TABLE profiles (
  user_id     TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  answers_json TEXT NOT NULL DEFAULT '{}',
  goal_summary TEXT,
  updated_at  TEXT NOT NULL
);

-- Referral ledger: one row per paid invoice of a referred user within 12 months.
CREATE TABLE referral_earnings (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  referrer_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  referred_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invoice_ref   TEXT NOT NULL UNIQUE,
  amount_cents  INTEGER NOT NULL,                    -- 25% of the paid amount, floor to the cent
  created_at    TEXT NOT NULL
);

CREATE TABLE feedback (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id     TEXT REFERENCES users(id) ON DELETE SET NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('bug','feature')),
  body        TEXT NOT NULL,
  diagnostics TEXT,
  created_at  TEXT NOT NULL
);

CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL);
