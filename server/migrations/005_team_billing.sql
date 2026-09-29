-- Team checkout (ACC-09): a team buys N Pro + M Max seats as one subscription. Paid seat counts cap how many
-- members (plus open invites) may hold each seat. NULL counts = never checked out: dev-seeded teams stay
-- uncapped until their first checkout; production teams are 'incomplete' (seats don't apply) until then.
ALTER TABLE teams ADD COLUMN paid_pro_seats INTEGER;
ALTER TABLE teams ADD COLUMN paid_max_seats INTEGER;
ALTER TABLE teams ADD COLUMN billing_interval TEXT;
ALTER TABLE teams ADD COLUMN stripe_customer_id TEXT;
ALTER TABLE teams ADD COLUMN stripe_subscription_id TEXT;
ALTER TABLE teams ADD COLUMN current_period_end TEXT;
ALTER TABLE teams ADD COLUMN promo_code TEXT;
CREATE INDEX teams_stripe_subscription ON teams(stripe_subscription_id);

-- Dev-mode checkout tickets (no Stripe keys): single use, 30 minutes, owner only.
CREATE TABLE team_checkouts (
  ticket_hash  TEXT PRIMARY KEY,
  team_id      TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  pro_seats    INTEGER NOT NULL,
  max_seats    INTEGER NOT NULL,
  interval     TEXT NOT NULL CHECK (interval IN ('month','year')),
  promo_code   TEXT,
  created_at   TEXT NOT NULL,
  expires_at   TEXT NOT NULL,
  used_at      TEXT
);
