---
name: web-deploy
description: Put a site or web app online, or make a shareable preview — pick a host the user already has (Cloudflare Pages, Netlify, Vercel, GitHub Pages, their own server), build, deploy as a preview first, and hand back the URL. Use for "deploy this", "put it live", "give me a link to share". Never deploys without the user asking.
---

# Web deploy

Deploying publishes the user's work to the internet under their account. Do it only when they asked,
default to a **preview**, and never pick a paid plan or a production domain on their behalf.

## 1. Build and check locally first

- Static site: the folder with `index.html` (for single files from `awan-build-preview`, that's
  `output/builds/<slug>/`).
- Framework project: run its build (`npm run build`) and find the output dir (`dist/`, `build/`,
  `out/`, `.next/` for Next with a server).
- Serve the output locally once and curl it; don't deploy something that doesn't load.
- Check nothing secret is in the output (`.env`, keys, private data): `rg -n "sk-|SECRET|PRIVATE KEY" <dir>`.

## 2. Pick the host the user already uses

Look for signs, in this order, and ask if none:
- Project config: `wrangler.toml`/`wrangler.jsonc` (Cloudflare), `netlify.toml`, `vercel.json`,
  `.github/workflows/*pages*`, a `deploy` script in `package.json`.
- Logged-in CLIs: `wrangler whoami`, `netlify status`, `vercel whoami`, `gh auth status`.
- Their own server (VPS): an existing deploy script or documented `rsync`/`scp` target.

No account anywhere → offer the zero-account option: zip the output (`output/builds/<slug>.zip`) for
them to drag into a host's dashboard, and name two free hosts. Don't create accounts for them.

## 3. Deploy a preview

| Host | Preview command |
|---|---|
| Cloudflare Pages | `npx wrangler pages deploy <dir> --project-name <name> --branch preview` |
| Netlify | `npx netlify deploy --dir <dir>` (no `--prod`) |
| Vercel | `npx vercel deploy <dir> -y` (no `--prod`) |
| GitHub Pages | push to the Pages branch/workflow the repo already uses — only with an explicit yes, since it's public |
| Own server | the project's deploy script, or `rsync -avz --delete <dir>/ user@host:/path/` to a staging path |

- Builds can take minutes; allow up to 10.
- A CLI asking to log in → tell the user the exact login command to run themselves; don't type their
  credentials.
- Production (`--prod`, the main branch, the real domain) only when the user explicitly says so.

## 4. Verify and report

- Fetch the returned URL and confirm it answers 200 with the expected title/text (a preview may take
  a few seconds to go live — retry briefly).
- Report: the URL, preview or production, which host/project, and how to take it down or promote it.
- Never paste tokens, API keys or account IDs into the chat.
