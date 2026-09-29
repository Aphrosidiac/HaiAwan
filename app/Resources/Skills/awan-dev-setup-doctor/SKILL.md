---
name: awan-dev-setup-doctor
description: Diagnose and fix broken developer setups — Node/npm/pnpm, Python/pip/uv, Homebrew, PATH, ports and localhost servers, .env and API keys, MCP servers, Codex/Claude Code CLIs, Supabase, Wrangler/Cloudflare, Git auth. Diagnose first, explain in plain words, then apply the smallest safe fix.
---

# Awan dev setup doctor

Many users aren't engineers. Find out what's actually wrong, say it in one plain sentence, fix the
smallest thing, and prove it's fixed.

## 1. Look before touching

Collect facts, read-only:
- Where: the project folder, `git status -sb`, which package manager (lockfile), `.nvmrc`/`.python-version`.
- Versions: `node -v`, `npm -v`, `python3 -V`, `brew -v`, the CLI in question `--version`.
- PATH and which binary runs: `command -v <tool>`, `echo $PATH | tr : '\n'`.
- Ports: `lsof -nP -iTCP:<port> -sTCP:LISTEN`.
- Logs: the failing command's full output, `tmp/*.log`, the tool's own log dir.
- Env: which keys the app expects (`.env.example`, config files) vs what's set — print **names only**,
  never values.

## 2. Explain

One sentence: "The server can't start because port 3000 is already used by an older copy of it."
Then the fix you'll apply.

## 3. Fix the smallest thing

Common fixes:
- Wrong Node version → use the version file (`nvm use`, `fnm use`, `volta`), don't upgrade globally.
- Missing deps → install with the project's own manager (`npm ci`, `pnpm i`, `uv sync`).
- Port busy → stop only the process you can identify as a stale copy of this project; otherwise pick
  another port.
- Command not found → install via Homebrew/npm/pipx, or fix PATH in the shell profile (show the line
  you'll add).
- MCP server won't connect → run its command by hand to see the error; check the URL answers; for
  Awan connectors, the user manages them in Awan → Settings → Integrations.
- Auth expired (gh, wrangler, supabase) → tell the user the exact login command to run themselves;
  don't paste their secrets anywhere.

## Never

- Overwrite or print `.env` values, keys or tokens. Create `.env` from `.env.example` only when asked.
- Run destructive resets (`rm -rf node_modules` is fine; dropping databases, `git reset --hard`,
  deleting user data is not) without an explicit yes.
- Touch production services, deploy, or change system settings.

## 4. Prove it

Re-run the command that failed. For servers, curl the port. For MCP, list the server's tools.
Report: what was wrong, what you changed (files/commands), and the result — plus the URL or command
to use now.
