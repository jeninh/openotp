#!/bin/bash
# Assemble build/OpenOTP.app from the SwiftPM build product.
# Usage: Scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OpenOTP"
# Reverse-DNS of openotp.app (the domain we own). Changed from com.openotp.app
# pre-release: macOS on jenin's machine held an unfindable per-bundle-id state
# that permanently suppressed the old id's menu bar item.
BUNDLE_ID="app.openotp.mac"

cd "$ROOT"

# Release builds are universal (arm64 + x86_64) so Intel Macs can run the app;
# debug stays native-only for faster iteration. CLT-only SwiftPM can't do
# multi-arch in one invocation (--arch needs Xcode's xcbuild), so build each
# slice separately and lipo them together at the copy step below.
if [ "$CONFIG" = "release" ]; then
  echo "==> swift build -c release (arm64 + x86_64)"
  swift build -c release --triple arm64-apple-macosx
  swift build -c release --triple x86_64-apple-macosx
  BIN_ARM64="$(swift build -c release --triple arm64-apple-macosx --show-bin-path)"
  BIN_X86="$(swift build -c release --triple x86_64-apple-macosx --show-bin-path)"
else
  echo "==> swift build -c $CONFIG"
  swift build -c "$CONFIG"
  BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
fi
APP_DIR="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

if [ "$CONFIG" = "release" ]; then
  lipo -create "$BIN_ARM64/$APP_NAME" "$BIN_X86/$APP_NAME" -output "$CONTENTS/MacOS/$APP_NAME"
else
  cp "$BIN_PATH/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
fi

if [ -f "$ROOT/icons/AppIcon.icns" ]; then
  cp "$ROOT/icons/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>OpenOTP</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>OpenOTP</string>
</dict>
</plist>
PLIST

# Signing precedence:
#  1. SIGN_IDENTITY set          → Developer ID + hardened runtime (notarize+staple if NOTARY_PROFILE set)
#  2. "OpenOTP Dev" cert present → stable self-signed dev cert (keeps the Keychain grant across rebuilds)
#  3. otherwise                  → ad-hoc (identity changes each build → re-prompts)
DEV_IDENTITY="OpenOTP Dev"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> codesign (Developer ID, hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> notarize + staple"
    ZIP="$ROOT/build/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    rm -f "$ZIP"
  fi
elif security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_IDENTITY"; then

  echo "==> codesign (stable dev identity: $DEV_IDENTITY)"
  codesign --force --sign "$DEV_IDENTITY" "$APP_DIR"
else
  echo "==> ad-hoc codesign (set SIGN_IDENTITY or create the 'OpenOTP Dev' cert)"
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "   (codesign skipped)"
fi

# Privacy check: refuse to package if the signed app leaks anything personal —
# home paths, this machine's name, the account's full name, or a signature from
# an identity-bearing cert (e.g. "Apple Development: <real name>"). Project
# github.com URLs are expected in the binary and excluded from the scan.
echo "==> privacy check"
FULLNAME="$(id -F 2>/dev/null | tr -d '\n' || true)"
HOSTNAME1="$(scutil --get ComputerName 2>/dev/null || true)"
HOSTNAME2="$(scutil --get LocalHostName 2>/dev/null || true)"
PAT="/Users/${FULLNAME:+|$FULLNAME}${HOSTNAME1:+|$HOSTNAME1}${HOSTNAME2:+|$HOSTNAME2}"
LEAKS="$( { strings -a "$CONTENTS/MacOS/$APP_NAME"; cat "$CONTENTS/Info.plist"; } \
  | grep -iwE "$PAT" | grep -viE 'github\.com/' || true)"
AUTHORITY="$(codesign -dvv "$APP_DIR" 2>&1 | grep '^Authority=' | head -1 || true)"
case "$AUTHORITY" in
  *"Apple Development"*|*"Mac Developer"*)
    LEAKS="${LEAKS}${LEAKS:+
}identity-bearing signature: $AUTHORITY" ;;
esac
if [ -n "$LEAKS" ]; then
  echo "!! privacy check FAILED — artifact contains:" >&2
  printf '%s\n' "$LEAKS" | head -10 >&2
  exit 1
fi
echo "    clean: no home paths, hostname, full name, or identity certs"

# Package a drag-to-Applications DMG as the GitHub Release artifact. Built last,
# after signing/stapling, so the image carries the final verified app.
DMG="$ROOT/build/$APP_NAME.dmg"
STAGE="$ROOT/build/dmg-stage"
echo "==> packaging $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP_DIR" "$STAGE/$APP_NAME.app"
# Strip extended attributes (Finder info, resource forks) so stray metadata
# doesn't ship in the image. Note: com.apple.provenance survives this — it's
# SIP-protected and re-stamped by the kernel. It's an opaque machine-local
# token (no identity data); build on CI if releases must not carry it.
xattr -cr "$STAGE"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
rm -rf "$STAGE"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> codesign DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "==> release artifact: $DMG"
shasum -a 256 "$DMG" | sed 's/^/    sha256: /'

echo "==> done: $APP_DIR"
echo "    run with: open \"$APP_DIR\"   (look for the key icon in the menu bar)"
