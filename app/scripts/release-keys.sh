#!/bin/zsh
# Creates Awan's update-signing keypair once. The private key lives OUTSIDE the repo in
# ~/.awan-release/ed25519.key (mode 0600) — never commit it, never copy it into the app.
# Prints the public key; build-app.sh embeds it in Info.plist (AwanUpdatePublicKey / SUPublicEDKey).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="${AWAN_RELEASE_DIR:-$HOME/.awan-release}"
KEY="$KEYDIR/ed25519.key"
TOOL="$ROOT/build/ed25519"
mkdir -p "$ROOT/build"
if [[ ! -x "$TOOL" || "$ROOT/scripts/ed25519.swift" -nt "$TOOL" ]]; then
  swiftc -O "$ROOT/scripts/ed25519.swift" -o "$TOOL" 2>&1 | grep -v "search path" || true
fi
if [[ -f "$KEY" ]]; then
  "$TOOL" public "$KEY"
else
  mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
  "$TOOL" generate "$KEY"
  chmod 600 "$KEY"
  echo "new signing key written to $KEY (keep a backup somewhere safe)" >&2
fi
