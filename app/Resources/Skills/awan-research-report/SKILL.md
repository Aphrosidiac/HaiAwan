---
name: awan-research-report
description: Research a company, market, competitor set, product, person or question and deliver sourced findings — in the chat reply by default, as a Markdown/PDF/DOCX/CSV file only when asked or when the result can't live in a message. Use for competitor scans, market maps, briefs, shortlists and "find out…" requests.
---

# Awan research report

The answer is the deliverable. Research properly, then hand over a clear, sourced result the user can
act on.

## 1. Frame it

Turn the ask into: the question, scope (who/what), geography and timeframe, depth, and output
format. If the user gave a minimum ("at least 20 sources"), meet it.

## 2. Gather

- Web search and fetch, public APIs, `curl`, and the user's own files first.
- Connected integrations for private data (their Drive, Notion, CRM…).
- `computer-use` only for pages that truly need a logged-in or interactive browser, and only in your
  own window.
- Keep a scratch list of sources with URLs and dates in `tmp/`; prefer primary sources (company
  pages, filings, pricing pages, official docs) over aggregators.

## 3. Deliver in chat

- Lead with the answer in one or two sentences.
- Comparisons and lists of things (competitors, products, people, options) go in one markdown table:
  five to eight columns chosen for the decision, short cells, one link column.
- Cite inline (linked source names). Mark estimates and inferences as such; separate verified facts
  from your read of them.
- Caveats and conflicting data: a sentence or two, not a section.

## 4. Files only when asked (or truly needed)

- The user asked for a PDF/DOCX/CSV/Markdown, or the result is dozens of rows they'll sort, filter or
  share → make the file with `pdf`, `doc` or `spreadsheet` under `output/reports/<slug>/`.
- The file is an export of the findings; the chat reply still carries the answer.
- If no format was named, answer in chat and offer the file as a next step.

## Don't

- Invent sources, numbers, quotes or people. If you couldn't verify something, say so.
- Use GUI browsing when search and fetch are enough.
- Pad the reply with methodology unless the user asked how you did it.

## Finish

Findings first; `File: <absolute path>` lines for any files made.
