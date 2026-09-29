-- First-party connectors: Awan hosts the MCP servers for Google Workspace and holds the user's
-- Google OAuth tokens. Tokens are AES-256-GCM encrypted with CONNECTOR_KEY (never stored in clear);
-- the ciphertext is bound to (user_id, provider) so a row copied to another user will not decrypt.

CREATE TABLE connector_accounts (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider    TEXT NOT NULL,                         -- 'google'
  scopes      TEXT NOT NULL DEFAULT '',              -- space-separated, as granted by the provider
  email       TEXT,                                  -- the provider account's address
  token_enc   TEXT NOT NULL,                         -- v1:<iv>:<tag>:<ciphertext> of {"access_token","refresh_token"}
  expires_at  TEXT,                                  -- access token expiry
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (user_id, provider)
);

-- One-shot OAuth state: minted by an authenticated app call, redeemed once by the provider callback.
CREATE TABLE connector_oauth_states (
  state_hash  TEXT PRIMARY KEY,                      -- sha256 of the state sent to the provider
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider    TEXT NOT NULL,
  toolkits    TEXT NOT NULL,                         -- comma-separated toolkit ids
  redirect    TEXT NOT NULL,                         -- awan://connectors or an https page
  created_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  used_at     TEXT
);
CREATE INDEX connector_oauth_states_user ON connector_oauth_states(user_id);
