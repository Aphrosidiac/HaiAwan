---
name: doc
description: Create, edit or review Word documents (.docx) — briefs, proposals, letters, reports, handouts — with python-docx, and check the real page layout by rendering DOCX → PDF → PNG. Use whenever the deliverable or input is a .docx file.
---

# DOCX

## Tools

- `python-docx` for reading and writing (styles, headings, lists, tables, images, page setup).
- Rendering for visual checks: LibreOffice (`soffice`) → PDF, Poppler (`pdftoppm`) → PNG.
  The bundled `scripts/render_docx.sh <file.docx> [out_dir]` does both and prints the PNG paths.
- Install what's missing (prefer `uv`): `uv pip install python-docx` or
  `python3 -m pip install --user python-docx`; `brew install --cask libreoffice` and
  `brew install poppler`. If you can't install, say which piece is missing.

## Workflow

1. **Reading**: extract text with python-docx for content; render pages when tables, columns,
   headers/footers or images matter.
2. **Creating**: build from styles, not ad-hoc formatting. Set page size (A4 unless the user is in
   the US/Canada → Letter), margins (2–2.5 cm), a heading hierarchy (Title, Heading 1–3), body 10.5–11 pt
   with 1.15–1.3 line spacing, and space-after instead of empty paragraphs.
3. **Editing an existing file**: keep its styles, numbering and section settings; change runs in
   place so formatting survives. Save as a new file unless asked to overwrite.
4. **Check**: render, then look at every page image. Fix clipped or overlapping text, orphaned
   headings, broken tables, wrong fonts, blank pages. Re-render after fixes.

## Quality

- Client-ready: consistent type, spacing and alignment; tables with a header row and sensible column
  widths; images sized to the text column.
- Plain ASCII hyphens and normal quotes unless the document's language needs otherwise; no stray
  Unicode dashes that render as boxes.
- Citations readable by a person — no tool tokens, placeholder brackets or TODOs left behind.

## Files

Scratch in `tmp/docs/`, finals in `output/doc/<slug>.docx` (and a PDF export beside it when useful).
Delete render scratch when done. End with `File: <absolute path>`.
