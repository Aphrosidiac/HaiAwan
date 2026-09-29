---
name: pdf
description: Create, read, extract from, fill or review PDF files — reports, one-pagers, invoices-style layouts, form filling, text and table extraction — with reportlab, pdfplumber/pypdf, and a render-to-PNG check before delivery. Use whenever a PDF is the input or the deliverable.
---

# PDF

## Tools

- Create: `reportlab` (platypus for flowing documents, canvas for exact layouts). For designed
  pages, an HTML page printed to PDF with a headless browser is often faster and prettier.
- Read / extract: `pdfplumber` (text with positions, tables), `pypdf` (pages, merge/split, rotate,
  forms, metadata).
- Render for review: `pdftoppm -r 110 -png in.pdf tmp/pdfs/page` (Poppler).
- Install what's missing (prefer `uv`): `uv pip install reportlab pdfplumber pypdf`, `brew install
  poppler`. If you can't install, say exactly what's missing.

## Workflow

1. **Reading**: extract text/tables; when layout matters (forms, columns, scanned pages), render and
   look. Scanned PDFs have no text layer — say so, and OCR (`tesseract`) only if available.
2. **Creating**: set page size (A4 unless the user is in the US/Canada → Letter), margins, a type
   scale (title / heading / body / caption), and register a real font if the text needs non-Latin
   glyphs. Tables get a header row and aligned numbers.
3. **Editing**: prefer regenerating from source. For small changes to an existing PDF, overlay with
   reportlab + merge with pypdf; for forms, fill fields with pypdf and flatten if asked.
4. **Check**: render every page and inspect before delivering. Fix clipped text, overflow, black
   boxes (missing glyphs), misaligned tables, blank pages. Re-render after each fix.

## Quality

- Consistent spacing and hierarchy, page numbers on multi-page documents, sharp images.
- Plain hyphens and quotes; no tool tokens or placeholders left in the text.
- Links clickable when the source had URLs.

## Files

Scratch in `tmp/pdfs/`, finals in `output/pdf/<slug>.pdf`. End with `File: <absolute path>`.
