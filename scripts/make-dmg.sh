#!/bin/bash
# Packages CanonTether.app into a distributable, drag-to-Applications .dmg.
# Run scripts/build-app.sh first (or this script will do it for you).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="CanonTether.app"
VERSION="$(source "$ROOT/scripts/version.sh" && echo "$CANONTETHER_VERSION")"
DMG_NAME="CanonTether-${VERSION}.dmg"
STAGING="dist/dmg-staging"

if [ ! -d "$APP" ]; then
  echo "==> $APP not found, building it first…"
  ./scripts/build-app.sh
fi

echo "==> Staging DMG contents…"
rm -rf "$STAGING" "dist/$DMG_NAME"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Building $DMG_NAME…"
mkdir -p dist
hdiutil create -volname "Canon Tether" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "dist/$DMG_NAME"

rm -rf "$STAGING"

echo "==> Done: $ROOT/dist/$DMG_NAME"
echo "    App is unsigned — after mounting, drag to Applications, then right-click → Open on first launch."
