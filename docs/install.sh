#!/bin/sh
# OpenOTP installer — fetches the latest release DMG and installs to /Applications.
# Usage: curl -fsSL https://openotp.app/install.sh | sh
# curl-downloaded files carry no quarantine attribute, so the app opens without
# Gatekeeper prompts. The script needs no sudo (falls back to ~/Applications).
set -eu

REPO="jeninh/openotp"
APP="OpenOTP"

[ "$(uname -s)" = "Darwin" ] || { echo "OpenOTP is a macOS app; this installer only runs on macOS." >&2; exit 1; }

echo "==> finding the latest release"
DMG_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | grep -o 'https://[^"]*')
[ -n "$DMG_URL" ] || { echo "No DMG found in the latest release of $REPO." >&2; exit 1; }

TMP=$(mktemp -d)
MNT="$TMP/mnt"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "==> downloading $DMG_URL"
curl -fL --progress-bar "$DMG_URL" -o "$TMP/$APP.dmg"

echo "==> installing"
hdiutil attach "$TMP/$APP.dmg" -nobrowse -quiet -mountpoint "$MNT"

# Quit a running copy before replacing it (no-op on first install).
pkill -x "$APP" 2>/dev/null || true

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
rm -rf "${DEST:?}/$APP.app"
ditto "$MNT/$APP.app" "$DEST/$APP.app"
hdiutil detach "$MNT" -quiet

echo "==> installed $DEST/$APP.app"
open "$DEST/$APP.app"
echo "    look for the key icon in your menu bar"
