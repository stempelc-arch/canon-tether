#!/bin/bash
# Builds CanonTether.app — a self-contained, double-clickable macOS app bundle.
#
# The app is intentionally UNSIGNED (no Apple Developer account): first launch needs a
# right-click → Open to get past Gatekeeper. Run this from anywhere:  ./scripts/build-app.sh
# Result: ./CanonTether.app in the project root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="CanonTether.app"
CONTENTS="$APP/Contents"
BUNDLE_ID="com.canontether.app"
VERSION="1.0"

echo "==> Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/CanonTether"
[ -f "$BIN_PATH" ] || { echo "error: built binary not found at $BIN_PATH"; exit 1; }

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH" "$CONTENTS/MacOS/CanonTether"

echo "==> Building app icon…"
( cd scripts && swift make-icon.swift >/dev/null )
ICONSET="scripts/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
SRC="scripts/icon-1024.png"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz          "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png"      >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$SRC"

echo "==> Writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Canon Tether</string>
    <key>CFBundleDisplayName</key>          <string>Canon Tether</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>           <string>CanonTether</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>       <string>12.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app runs without the "damaged" error on modern macOS (still unsigned re: Apple).
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: $ROOT/$APP"
echo "    First launch: right-click the app → Open (unsigned app, Gatekeeper bypass)."
