#!/bin/zsh
# Builds a release of Awan, packages the DMG, signs it and publishes it into the site:
#   site/public/download/Awan-<version>.dmg   (git-ignored)
#   site/public/appcast.xml                    (Sparkle appcast listing every DMG in download/, newest first)
#
# usage: scripts/release.sh [version]          version defaults to app/VERSION
#   AWAN_SITE_URL      public site the appcast points at (default https://awan.ffdev.studio)
#   AWAN_RELEASE_DIR   where the private key lives (default ~/.awan-release)
#   AWAN_SKIP_BUILD=1  only re-sign and rewrite the appcast from the DMGs already in download/
#
# Nothing is uploaded — deploying the site is a separate, deliberate step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(cat VERSION)}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must be X.Y.Z (got $VERSION)"; exit 1; }
SITE_URL="${AWAN_SITE_URL:-https://awan.ffdev.studio}"
SITE_URL="${SITE_URL%/}"
KEYDIR="${AWAN_RELEASE_DIR:-$HOME/.awan-release}"
KEY="$KEYDIR/ed25519.key"
DOWNLOADS="$REPO/site/public/download"
APPCAST="$REPO/site/public/appcast.xml"
TOOL="$ROOT/build/ed25519"

# Sparkle compares sparkle:version with CFBundleVersion, so the build number is derived from the
# version itself (1.2.3 → 10203): monotonic, and the same on every machine.
build_number() { local IFS=.; local -a p=(${=1}); echo $(( p[1] * 10000 + p[2] * 100 + p[3] )); }

PUBLIC_KEY="$("$ROOT/scripts/release-keys.sh")"   # compiles the tool; makes the key on first run
[[ -f "$KEY" ]] || { echo "no signing key at $KEY"; exit 1; }
[[ "$(stat -f %Lp "$KEY")" == "600" ]] || { echo "refusing: $KEY must be mode 600"; exit 1; }

mkdir -p "$DOWNLOADS"
if [[ "${AWAN_SKIP_BUILD:-0}" != "1" ]]; then
  AWAN_VERSION="$VERSION" AWAN_BUILD_NUMBER="$(build_number "$VERSION")" AWAN_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
    AWAN_APPCAST_URL="${AWAN_APPCAST_URL:-$SITE_URL/appcast.xml}" "$ROOT/scripts/build-app.sh" release
  AWAN_VERSION="$VERSION" "$ROOT/scripts/make-dmg.sh"
  cp "$ROOT/build/Awan.dmg" "$DOWNLOADS/Awan-$VERSION.dmg"
  echo "published $DOWNLOADS/Awan-$VERSION.dmg"
fi

# Rewrite the appcast from every DMG we have, newest first.
items=""
for name in $(cd "$DOWNLOADS" && ls Awan-*.dmg 2>/dev/null | sort -V -r); do
  dmg="$DOWNLOADS/$name"
  v="${name%.dmg}"; v="${v#Awan-}"
  sig="$("$TOOL" sign "$KEY" "$dmg")"
  "$TOOL" verify "$PUBLIC_KEY" "$dmg" "$sig" >/dev/null
  len="$(stat -f %z "$dmg")"
  date="$(LC_ALL=C date -r "$(stat -f %m "$dmg")" '+%a, %d %b %Y %H:%M:%S %z')"
  items+="
    <item>
      <title>Awan ${v}</title>
      <pubDate>${date}</pubDate>
      <sparkle:version>$(build_number "$v")</sparkle:version>
      <sparkle:shortVersionString>${v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${SITE_URL}/changelog/</sparkle:releaseNotesLink>
      <enclosure url=\"${SITE_URL}/download/Awan-${v}.dmg\" length=\"${len}\" type=\"application/octet-stream\"
                 sparkle:edSignature=\"${sig}\" />
    </item>"
done

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Awan</title>
    <link>${SITE_URL}/appcast.xml</link>
    <description>Updates for Awan by FF Dev Studio.</description>
    <language>en</language>${items}
  </channel>
</rss>
XML
echo "wrote $APPCAST ($(grep -c '<item>' "$APPCAST") release(s), feed base $SITE_URL)"
