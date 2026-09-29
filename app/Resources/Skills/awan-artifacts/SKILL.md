---
name: awan-artifacts
description: Find, open, reveal, rename, move, export or tidy files an Awan already made (reports, PDFs, spreadsheets, decks, pages, images). Use for "where did it save?", "open it again", "show it in Finder", "export that as PDF", or the final hand-off step of another workflow. Not for creating the content in the first place.
---

# Awan artifacts

Every file job ends with an exact path the user can click — or a clear reason there isn't one.

## Where things live

- Your workspace is your working directory. Finished files go in `output/`, scratch in `tmp/`.
- Stable layout: `output/<kind>/<slug>/` — e.g. `output/reports/competitor-scan/`, `output/pdf/`,
  `output/spreadsheet/`, `output/builds/<slug>/`.
- The user's Desktop, Documents and Downloads trigger macOS permission prompts. Look there only
  when the user points you at them, and only in the one folder you need.

## Finding a file

1. Start from what this thread made: your last reply's `File:` lines, then `output/`.
2. Search by name and recency: `find output -type f -newer <ref>`, `rg --files output | rg -i <word>`,
   `ls -lt output/**/ | head`.
3. Several matches → take the newest relevant one and say how many candidates there were.
4. Never guess. If a path is inferred, say "probably"; if the file was never made, say so and offer
   to make it.

## Opening and revealing

- Check the file exists and isn't empty (`test -s`) before claiming it's there.
- Awan shows returned files as cards the user can open, so usually the path is enough.
- If the user explicitly asks to open or reveal it: `open "<path>"` (default app) or
  `open -R "<path>"` (Finder). Don't force a specific browser (`open -a "Google Chrome"`) and don't use
  computer use for this.

## Changing files

- Rename/move/export: copy first when unsure, keep the original unless the user asked to replace it.
- Deletes, overwrites of files you didn't make, and bulk moves: list exactly what will change and wait
  for a yes.
- Exports: DOCX/XLSX → PDF with `soffice --headless --convert-to pdf --outdir <dir> <file>`; Markdown →
  PDF via the `pdf` skill. Render a page to PNG and look at it when layout matters.

## Finish

End with the absolute path(s), one per line, each prefixed `File: `. If opening failed, still give
the path and the error.
