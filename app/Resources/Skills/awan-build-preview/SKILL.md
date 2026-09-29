---
name: awan-build-preview
description: Build and preview websites, landing pages, web apps, dashboards, HTML prototypes and front-end components, then iterate until they visibly work. Use when the user wants a working thing they can look at, not just code. Pair with frontend-design for taste; hand setup failures to awan-dev-setup-doctor.
---

# Awan build & preview

Make the thing, prove it works, hand over a path or a live local URL.

## Decide the format first

- **Default: one self-contained HTML file** (inline CSS/JS, or pinned CDN links). Save it to
  `output/builds/<slug>/index.html`. It opens straight from disk — no server, nothing to keep running.
- Use a framework project (Vite, Next, Astro, SvelteKit…) only when the request truly needs one:
  several routes, a build step, JSX/TSX, server code, or an existing project that already uses one.
- Editing an existing project? Detect its stack, package manager and conventions, and change only
  what the request needs.

## When a dev server is unavoidable

A server started in the foreground dies when your command returns, so the URL you report would
already be dead. Always:

1. Reuse one that's already listening: `lsof -nP -iTCP:4173 -sTCP:LISTEN`.
2. Start detached with a fixed host and port, logging to a file:
   `nohup npm run dev -- --host 127.0.0.1 --port 4173 > tmp/preview.log 2>&1 &`
3. Wait until it answers: `for i in {1..40}; do curl -fsS -o /dev/null http://127.0.0.1:4173/ && break; sleep 0.5; done`
4. If it never answers, read `tail -n 40 tmp/preview.log` and report the real error.

Never hand back a `127.0.0.1` URL you haven't just seen respond.

## Quality bar

- Follow the `frontend-design` skill: real content, clear hierarchy, responsive from 360 px up,
  accessible controls, restrained motion.
- No lorem ipsum, fake testimonials or invented stats unless the user asked for placeholders.
- Forms and buttons do something visible (even if it's a local-only success state).

## Verify before you say "done"

- Static file: it exists, opens, and has no console errors you can detect (load it with a headless
  check if one is available, or at least validate the HTML/JS parses).
- Project: run its build or type-check (`npm run build`, `tsc --noEmit`) when reasonable, then curl the
  page and check the key text is in the response.
- Look at it when you can: a headless browser screenshot at ~390 px and ~1280 px wide. Say what you
  checked and what you couldn't.

## Don't

- Don't foreground or take over the user's browser to preview; give the path or URL. If the user asks
  to see it, `open "<file or url>"` once at the end.
- Don't refactor unrelated code or overwrite the user's files without asking.
- Deploying publicly is a separate step: see `web-deploy`, and only when asked.

## Finish

Lead with what was built. Then the local URL (if any) and `File: <absolute path>` lines.
