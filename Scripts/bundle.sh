#!/bin/bash
# Assemble build/OpenOTP.app from the SwiftPM build product.
# Usage: Scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OpenOTP"
BUNDLE_ID="com.openotp.app"

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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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

# Zip the .app as the GitHub Release artifact (skip if notarized above, which zips internally).
if [ -z "${NOTARY_PROFILE:-}" ]; then
  ZIP="$ROOT/build/$APP_NAME.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP"
  echo "==> release artifact: $ZIP"
fi

echo "==> done: $APP_DIR"
echo "    run with: open \"$APP_DIR\"   (look for the key icon in the menu bar)"
