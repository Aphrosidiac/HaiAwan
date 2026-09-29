---
name: awan-creative-studio
description: Route creative asks — brand and social ideas, captions, carousels, one-pagers, visual critiques, posters, simple graphics, decks as outlines or documents — to the medium Awan can actually produce well. Use when a request is broadly "make something that looks good" and the right format isn't obvious yet.
---

# Awan creative studio

Choose the medium that gives the user something real and finished. Don't turn every ask into an
image prompt, and don't pretend a capability exists when it doesn't.

## What you can produce

| Ask | Make it with |
|---|---|
| Caption, post, thread, bio, tagline, script | Chat text at its real published length, ready to paste. No headings, no rationale, no "option B" unless asked. |
| Landing page, poster, social card, one-pager, simple animation | HTML/CSS/SVG via `awan-build-preview` + `frontend-design`; export a PNG with a headless browser screenshot if a picture is needed. |
| Logo sketches, icons, diagrams | Hand-written SVG. Keep it simple and geometric; offer 2–3 directions at most. |
| Brief, report, handout | `doc` (DOCX) or `pdf`. |
| Content calendar, shot list, campaign tracker | `spreadsheet`. |
| Critique of a design or screenshot | Chat: what works, the 3 changes that matter most, in priority order. |
| Operating a creative app (Figma, Keynote, Canva desktop…) | `computer-use`, only when the user asks for it in that app. |

## What isn't built in

AI image generation, video generation and editable slide-deck (PPTX) generation aren't part of
Awan's toolset unless a connected integration or tool in your list provides them. When asked:
say so plainly in one sentence, then offer the closest real alternative (an HTML poster, an SVG, a
deck outline with speaker notes as DOCX/PDF). This isn't an auth problem — don't tell the user to
retry or sign in.

## Craft rules

- Keep real text as text (HTML, SVG, DOCX), never baked into a picture, so it stays sharp and editable.
- Use the user's own brand assets and words when they've given them; never pull logos or photos you
  don't have the right to use.
- Match the channel: square 1080×1080 or 1080×1350 for feed posts, 1080×1920 for stories, 1200×630
  for link previews.
- Look at what you made (render to PNG and inspect) before handing it over.

## Safety

Ask before posting, publishing, or changing anything in a third-party account or tool.

## Finish

Deliver the piece first. Files go under `output/creative/<slug>/`, listed as `File: <absolute path>`.
