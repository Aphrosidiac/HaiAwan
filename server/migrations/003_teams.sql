-- Teams v0: one team per user, seats are Pro or Max, the team's subscription status applies to every seat.
-- A member's effective plan is the better of their personal plan and their seat (plans.ts planFor).

CREATE TABLE teams (
  id          TEXT PRIMARY KEY,                      -- uuid v4
  name        TEXT NOT NULL,
  owner_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','incomplete','past_due','canceled')),
  created_at  TEXT NOT NULL
);

CREATE TABLE team_members (
  team_id     TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,  -- one team per user in v0
  role        TEXT NOT NULL CHECK (role IN ('owner','admin','member')),
  seat        TEXT NOT NULL CHECK (seat IN ('pro','max')),
  joined_at   TEXT NOT NULL,
  PRIMARY KEY (team_id, user_id)
);

-- Single-use invite codes. used_by is set by a conditional UPDATE so two racing joins can't both win.
CREATE TABLE team_invites (
  code        TEXT PRIMARY KEY,                      -- AWN-XXXX-XXXX
  team_id     TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  email       TEXT COLLATE NOCASE,                   -- optional: only this address may redeem it
  seat        TEXT NOT NULL CHECK (seat IN ('pro','max')),
  created_by  TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  used_by     TEXT REFERENCES users(id) ON DELETE SET NULL,
  used_at     TEXT
);
CREATE INDEX team_invites_team ON team_invites(team_id);

-- The web dashboard (/team): the app mints a one-time link, the page swaps it for a short cookie session.
CREATE TABLE team_dashboard_links (
  code_hash   TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at  TEXT NOT NULL,
  used_at     TEXT
);

CREATE TABLE team_sessions (
  token_hash  TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  csrf        TEXT NOT NULL,
  expires_at  TEXT NOT NULL
);
