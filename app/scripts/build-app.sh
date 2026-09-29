#!/bin/zsh
# Assembles build/Awan.app from the SwiftPM product, bundles fonts, sounds, skills and the Codex runtime,
# and signs it (ad-hoc unless AWAN_SIGN_IDENTITY is set).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
cd "$ROOT"
swift build -c "$CONFIG" 2>&1 | grep -E "error|warning: unreachable|Compiling|Build complete" | grep -v "^$" | tail -20
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Awan"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }
[[ -x Vendor/codex/bin/codex ]] || ./scripts/fetch-codex.sh

APP="$ROOT/build/Awan.app"
VERSION="${AWAN_VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
BUILD_NUMBER="${AWAN_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
# Updates: Sparkle checks this appcast hourly and verifies every download against this Ed25519 key.
# The private half never leaves ~/.awan-release (see scripts/release-keys.sh and scripts/release.sh).
UPDATE_PUBLIC_KEY="${AWAN_UPDATE_PUBLIC_KEY:-H5SmaXxH5pdsosAmGflYsOQKxVHjUvt6oqY2C1S5m3U=}"
APPCAST_URL="${AWAN_APPCAST_URL:-https://awan.ffdev.studio/appcast.xml}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Awan"
mkdir -p "$APP/Contents/Frameworks"
rsync -a --delete "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
rsync -a --delete Resources/Fonts/ "$APP/Contents/Resources/Fonts/"
rsync -a --delete Resources/Sounds/ "$APP/Contents/Resources/Sounds/"
rsync -a --delete Resources/Skills/ "$APP/Contents/Resources/Skills/"
rsync -a --delete Resources/Logos/ "$APP/Contents/Resources/Logos/"
rsync -a --delete Resources/SpeechCache/ "$APP/Contents/Resources/SpeechCache/"
mkdir -p "$APP/Contents/Resources/CodexRuntime"
rsync -a --delete Vendor/codex/ "$APP/Contents/Resources/CodexRuntime/"
[[ -d Resources/Helpers ]] && rsync -a Resources/Helpers/ "$APP/Contents/Resources/Helpers/"
cp "$ROOT/../THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Awan</string>
  <key>CFBundleExecutable</key><string>Awan</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>studio.ffdev.awan</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Awan</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>studio.ffdev.awan.auth</string>
    <key>CFBundleURLSchemes</key><array><string>awan</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Awan listens while you hold your talk shortcut so you can talk to it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Awan turns what you say into text when you talk or dictate.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Awan looks at your screen when you ask it something, so it can point at things and help.</string>
  <key>NSAppleEventsUsageDescription</key><string>Awan's agents can control apps you ask them to use.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Awan reads the document you're asking about so it can answer about the whole file.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Awan reads the document you're asking about so it can answer about the whole file.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Awan reads the document you're asking about so it can answer about the whole file.</string>
  <key>NSCalendarsUsageDescription</key><string>Awan can show your upcoming meetings.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Awan shows a countdown with a Join button before meetings that have a video link. Your calendar stays on this Mac.</string>
  <key>SUFeedURL</key><string>${APPCAST_URL}</string>
  <key>AwanAppcastURL</key><string>${APPCAST_URL}</string>
  <key>SUPublicEDKey</key><string>${UPDATE_PUBLIC_KEY}</string>
  <key>AwanUpdatePublicKey</key><string>${UPDATE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>AwanAPIBaseURL</key><string>${AWAN_API_URL:-http://127.0.0.1:8787}</string>
</dict>
</plist>
PLIST
printf "APPL????" > "$APP/Contents/PkgInfo"

# A stable identity keeps macOS permissions (Screen Recording, Accessibility, Mic) across rebuilds.
# Uses "Awan Dev" (a self-signed Code Signing certificate you create once in Keychain Access) when present.
if [[ -z "${AWAN_SIGN_IDENTITY:-}" ]] && security find-certificate -c "Awan Dev" >/dev/null 2>&1; then AWAN_SIGN_IDENTITY="Awan Dev"; fi
IDENTITY="${AWAN_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "built $APP ($(du -sh "$APP" | cut -f1)), signed with ${IDENTITY}"
