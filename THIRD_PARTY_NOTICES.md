# Third-party notices

Awan is made by FF Dev Studio (FF DEV STUDIO, 202603234793). It includes, embeds, or adapts the
following third-party work. Each item keeps its own licence; the full licence texts are reproduced
or linked below.

## Shipped inside Awan.app

### OpenAI Codex CLI — Apache License 2.0
- Source: https://github.com/openai/codex
- Use: the embedded agent runtime (`Contents/Resources/CodexRuntime`, run as `codex app-server`).
  Unmodified binaries fetched by `app/scripts/fetch-codex.sh`.
- Licence: Apache-2.0 — the full text ships beside the runtime (`CodexRuntime/LICENSE`).
  Copyright OpenAI.

### Instrument Sans and Instrument Serif — SIL Open Font License 1.1
- Source: https://github.com/Instrument/instrument-sans, https://github.com/Instrument/instrument-serif
- Use: the app's typefaces (`Contents/Resources/Fonts`). Licence texts:
  `app/Resources/Fonts/OFL-InstrumentSans.txt`, `app/Resources/Fonts/OFL-InstrumentSerif.txt`.

## Adapted (rewritten in our own words or code)

### trycua/cua — Cua Driver — MIT License
- Source: https://github.com/trycua/cua (`libs/cua-driver`), Copyright (c) 2026 Cua AI, Inc.
- Use: Awan's computer-use MCP server (`app/Sources/Awan/Agents/ComputerUse/`) is our own Swift
  implementation, not a copy of Cua Driver. Its tool names and argument shapes (`get_window_state`,
  `element_token`, `delivery_mode`, `launch_app` with `creates_new_application_instance`…), the
  snapshot → act → verify workflow, the `effect`/`verified` honesty fields and the refused-shortcut
  policy follow Cua Driver's published design so agents can use one mental model. The
  `computer-use` skill (`app/Resources/Skills/computer-use/SKILL.md`) is rewritten from the ideas in
  Cua Driver's agent skill.

### openai/skills — licensed per skill (see each skill's LICENSE.txt in that repo)
- Source: https://github.com/openai/skills
- Use: the structure and topics of our `doc`, `pdf`, `spreadsheet` and `web-deploy` skills (tools to
  prefer, render-to-PNG review loops, spreadsheet formatting conventions, preview-before-production
  deploys) are adapted from the curated skills there. All text and the bundled helper scripts
  (`doc/scripts/render_docx.sh`, `spreadsheet/examples/tracker.py`) are written fresh for Awan; no
  vendor-specific deploy script is included.

### NousResearch/hermes-agent — MIT License
- Source: https://github.com/nousresearch/hermes-agent, Copyright (c) 2025 Nous Research
- Use: the filesystem-first approach of our `obsidian` skill (vault as a plain Markdown folder,
  wikilink and daily-note conventions) is adapted from the Hermes Agent Obsidian skill. Text rewritten.

### farzaa/clicky — MIT License
- Source: https://github.com/farzaa/clicky, Copyright (c) Farza
- Use: parts of the companion (cursor overlay, push-to-talk) are adapted from this open-source
  version; adapted files carry the comment `// Adapted from farzaa/clicky (MIT)`.

---

## MIT License (applies to the MIT items above, with their own copyright lines)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Apache License 2.0

Full text: https://www.apache.org/licenses/LICENSE-2.0 (also shipped as `CodexRuntime/LICENSE`).

## SIL Open Font License 1.1

Full text: https://openfontlicense.org (also shipped beside the fonts).

## Integration logos (app/Resources/Logos)
The app logos shown in Settings → Integrations are the trademarks of their respective owners (Notion, Linear, GitHub,
Google, Slack, LinkedIn, Asana, Atlassian, monday.com, Box, Canva, Figma, Webflow, Stripe, PayPal, Square, Intercom,
Sentry, Vercel, Supabase, Obsidian). They are used only to identify each service in the integrations list and do not
imply endorsement. Files were taken from each service's public favicon / touch icon.
