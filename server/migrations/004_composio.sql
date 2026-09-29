-- Composio broker (active when COMPOSIO_API_KEY is set). Composio holds every OAuth grant; Awan keeps only
-- the ids it needs to find them again. Composio's user id is our users.id.

-- One Composio-managed auth config per toolkit, created on first connect and reused for every user.
CREATE TABLE composio_auth_configs (
  toolkit         TEXT PRIMARY KEY,                  -- Composio toolkit slug (gmail, slack, notion…)
  auth_config_id  TEXT NOT NULL,
  created_at      TEXT NOT NULL
);

-- The user's current Composio session (its MCP URL is reached only through Awan's /mcp/composio proxy,
-- because Composio's MCP endpoint takes the project API key). Recreated when the connected set changes.
CREATE TABLE composio_sessions (
  user_id     TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  session_id  TEXT NOT NULL,
  mcp_url     TEXT NOT NULL,
  toolkits    TEXT NOT NULL,                         -- comma-separated, sorted: the allowlist it was made with
  created_at  TEXT NOT NULL
);

-- One-shot state for the OAuth bounce (Composio → /v1/composio/callback → awan://connectors).
CREATE TABLE composio_link_states (
  state_hash            TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  toolkit               TEXT NOT NULL,
  connected_account_id  TEXT,
  redirect              TEXT NOT NULL,
  created_at            TEXT NOT NULL,
  expires_at            TEXT NOT NULL,
  used_at               TEXT
);
