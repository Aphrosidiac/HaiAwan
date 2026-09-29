-- Skills library ("power ups"): official skills written by FF, skills users create or import,
-- published to everyone or shared with a team. A user keeps at most 3 active at once.

CREATE TABLE skills (
  slug          TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  one_liner     TEXT NOT NULL,
  whats_inside  TEXT NOT NULL DEFAULT '[]',          -- JSON array of short bullets
  content       TEXT NOT NULL,                       -- SKILL.md body (no front matter)
  category      TEXT NOT NULL,                       -- writing | research | design | dev | marketing | productivity | learning | fun
  symbol        TEXT NOT NULL DEFAULT 'sparkles',    -- SF Symbol name
  color         TEXT NOT NULL DEFAULT '#8B8981',     -- hex
  author_name   TEXT NOT NULL,
  is_official   INTEGER NOT NULL DEFAULT 0,
  origin        TEXT NOT NULL DEFAULT 'library' CHECK (origin IN ('library','created','imported')),
  created_by    TEXT REFERENCES users(id) ON DELETE CASCADE,  -- NULL for official skills
  team_id       TEXT,                                -- set by share-to-team (teams arrive in 003)
  published     INTEGER NOT NULL DEFAULT 0,          -- visible to everyone in the library
  users_count   INTEGER NOT NULL DEFAULT 0,          -- distinct users who ever switched it on
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX skills_owner ON skills(created_by);
CREATE INDEX skills_team ON skills(team_id);

-- Currently active skills. The 3-slot cap is enforced inside BEGIN IMMEDIATE (see skills.ts).
CREATE TABLE skill_activations (
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slug          TEXT NOT NULL REFERENCES skills(slug) ON DELETE CASCADE,
  activated_at  TEXT NOT NULL,
  UNIQUE (user_id, slug)
);
CREATE INDEX skill_activations_user ON skill_activations(user_id);

-- Everyone who ever switched a skill on (drives users_count; never double-counts a re-activation).
CREATE TABLE skill_users (
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slug          TEXT NOT NULL REFERENCES skills(slug) ON DELETE CASCADE,
  first_at      TEXT NOT NULL,
  PRIMARY KEY (user_id, slug)
);
