#!/bin/zsh
# Vendors the OpenAI Codex CLI (Apache-2.0) runtime into app/Vendor/codex for bundling.
set -euo pipefail
VERSION="${CODEX_VERSION:-0.158.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/codex"
if [[ -x "$DEST/bin/codex" ]] && [[ "$(cat "$DEST/VERSION" 2>/dev/null)" == "$VERSION" ]]; then echo "codex $VERSION already vendored"; exit 0; fi
TMP="$(mktemp -d)"
cd "$TMP"
npm pack "@openai/codex@${VERSION}-darwin-arm64" --silent >/dev/null
tar xzf "openai-codex-${VERSION}-darwin-arm64.tgz"
V="package/vendor/aarch64-apple-darwin"
rm -rf "$DEST"; mkdir -p "$DEST/bin" "$DEST/path" "$DEST/resources"
cp "$V/bin/codex" "$V/bin/codex-code-mode-host" "$DEST/bin/"
cp "$V/codex-path/rg" "$DEST/path/"
cp -R "$V/codex-resources/zsh" "$DEST/resources/" 2>/dev/null || true
echo "$VERSION" > "$DEST/VERSION"
curl -fsSL "https://raw.githubusercontent.com/openai/codex/main/LICENSE" -o "$DEST/LICENSE" || true
rm -rf "$TMP"
echo "vendored codex $VERSION → $DEST"
