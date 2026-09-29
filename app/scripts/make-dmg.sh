#!/bin/zsh
# Packages build/Awan.app into build/Awan.dmg (drag-to-Applications layout).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Awan.app"
[[ -d "$APP" ]] || "$ROOT/scripts/build-app.sh" release
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
VERSION="${AWAN_VERSION:-$(cat "$ROOT/VERSION")}"
rm -f "$ROOT/build/Awan.dmg"
hdiutil create -volname "Awan $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/build/Awan.dmg" >/dev/null
rm -rf "$STAGE"
echo "built $ROOT/build/Awan.dmg ($(du -h "$ROOT/build/Awan.dmg" | cut -f1))"
