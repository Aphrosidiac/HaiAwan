#!/bin/bash
# Render a .docx (or .xlsx/.pptx/.odt) to PNG pages for visual review: office → PDF (LibreOffice) → PNG (Poppler).
# Usage: render_docx.sh <file> [out_dir] [dpi]
# Prints one PNG path per line. Exits non-zero with a plain message when a tool is missing.
set -euo pipefail
in="${1:?usage: render_docx.sh <file> [out_dir] [dpi]}"
out="${2:-tmp/render}"
dpi="${3:-110}"
[[ -f "$in" ]] || { echo "no such file: $in" >&2; exit 2; }

soffice_bin="$(command -v soffice || true)"
[[ -z "$soffice_bin" && -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]] && soffice_bin=/Applications/LibreOffice.app/Contents/MacOS/soffice
[[ -n "$soffice_bin" ]] || { echo "LibreOffice isn't installed (brew install --cask libreoffice)" >&2; exit 3; }
command -v pdftoppm >/dev/null || { echo "Poppler isn't installed (brew install poppler)" >&2; exit 3; }

mkdir -p "$out"
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT
base="$(basename "${in%.*}")"
if [[ "${in##*.}" != "pdf" ]]; then
  "$soffice_bin" -env:UserInstallation="file://$profile" --headless --convert-to pdf --outdir "$out" "$in" >/dev/null 2>&1
  pdf="$out/$base.pdf"
else
  pdf="$in"
fi
[[ -s "$pdf" ]] || { echo "conversion to PDF failed for $in" >&2; exit 4; }
pdftoppm -r "$dpi" -png "$pdf" "$out/$base"
ls -1 "$out/$base"*.png
