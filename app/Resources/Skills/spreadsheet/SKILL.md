---
name: spreadsheet
description: Create, edit, clean, analyse and format spreadsheets (.xlsx, .csv, .tsv) — shortlists, trackers, comparisons, budgets and models — with openpyxl and pandas, live formulas, and a visual check. Use whenever a spreadsheet is the input or the deliverable.
---

# Spreadsheet

## Sheets made for a person (most of them)

A shortlist, comparison, tracker or lead list is read and acted on, so make it high-signal:
- One sheet. Best option first, highlighted.
- Five to eight columns chosen for the decision — not every field you found.
- Every cell a few words or a number. Unknowns are "Ask" or "Quote", never a sentence.
- One link column (each item's own page). No sources tab, no notes sheet, no cell comments.
- Caveats go in your chat reply, briefly.

The model rules further down are for budgets, forecasts and financial models the user asked for.

## Tools

- `openpyxl` to create/edit `.xlsx` and keep formatting; `pandas` for analysis and CSV/TSV.
- Charts: `openpyxl.chart` (native Excel charts).
- openpyxl doesn't calculate formulas. To get cached values (and to look at the result), recalculate
  and render with LibreOffice: `soffice --headless --convert-to pdf --outdir tmp/sheets file.xlsx`
  then `pdftoppm -png` — or run `../doc/scripts/render_docx.sh file.xlsx`.
- Install if missing (prefer `uv`): `uv pip install openpyxl pandas`.
- A worked example lives in `examples/tracker.py`.

## Workflow

1. Confirm the goal: create, clean, analyse, or restyle.
2. Existing file: open it and look (render) before changing anything; preserve its styles, named
   ranges and formulas exactly. Fill new cells in the existing style.
3. Derived numbers are formulas (`=SUM(C2:C20)`, `=B4*(1+$B$1)`), not pasted results. Keep formulas
   short; use helper columns for complex logic.
4. Recalculate, render, look, fix, then deliver.

## Formatting (new sheets)

- Bold header row with a subtle fill, frozen panes under it, filters on.
- Column widths that fit the content; wrap only long text columns.
- Real number formats: dates as dates, currency with its symbol, percentages to one decimal,
  thousands separators. Right-align numbers.
- Borders sparingly; no border around every cell.

## Formulas

- Avoid dynamic-array functions (`FILTER`, `XLOOKUP`, `SORT`, `SEQUENCE`) unless the user uses Excel
  365 — they break in older Excel and LibreOffice. Avoid volatile `INDIRECT`/`OFFSET`.
- Absolute vs relative references on purpose (`$B$1` for inputs).
- Text starting with `=` gets a leading apostrophe.
- Check for `#REF!`, `#DIV/0!`, `#VALUE!`, `#NAME?`, circular references and off-by-one ranges after
  recalculating.

## Models (when asked for one)

- Inputs, calculations and outputs clearly separated; assumptions in one block.
- Colour convention unless the user has one: blue text = hard-coded input, black = formula, green =
  link to another sheet.
- Units in headers ("Revenue (RM)"), negatives in parentheses, zeros as "–".
- Cite external inputs (source URL in a note column or cell comment).

## Files

Scratch in `tmp/spreadsheets/`, finals in `output/spreadsheet/<slug>.xlsx` (or `.csv`).
End with `File: <absolute path>`.
