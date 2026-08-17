#!/bin/bash
# Packages CanonTether.app into a single-file, double-clickable macOS .pkg installer with the
# standard Apple installer wizard (Welcome → Install → admin password → Done). The app has gphoto2
# bundled inside (see bundle-gphoto2.sh), so the installer is fully self-contained — no Homebrew,
# no Terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="CanonTether.app"
VERSION="$(source "$ROOT/scripts/version.sh" && echo "$CANONTETHER_VERSION")"
PKG_NAME="CanonTether-${VERSION}-Installer.pkg"
STAGING="dist/pkg-staging"

if [ ! -d "$APP" ]; then
  echo "==> $APP not found, building it first…"
  ./scripts/build-app.sh
fi
[ -x "$APP/Contents/Frameworks/gphoto2/bin/gphoto2" ] \
  || { echo "error: app is missing the bundled gphoto2 — rebuild with build-app.sh"; exit 1; }

echo "==> Staging…"
rm -rf "$STAGING" "dist/$PKG_NAME"
mkdir -p "$STAGING/root" "$STAGING/resources" dist
cp -R "$APP" "$STAGING/root/"

cat > "$STAGING/resources/welcome.html" <<'HTML'
<!DOCTYPE html><html><body style="font-family: -apple-system, sans-serif; font-size: 13px;">
<h2>Canon Tether</h2>
<p>Tethered shooting for the Canon EOS-1D X Mark II over wired Ethernet or USB.</p>
<p>This installs the complete app — the camera engine is built in, nothing else to download or set up.</p>
<p><b>After installing:</b> because the app is from an independent developer (not the App Store),
the very first launch needs a <b>right-click on the app &rarr; Open</b>. Every launch after that is normal.</p>
</body></html>
HTML

cat > "$STAGING/resources/conclusion.html" <<'HTML'
<!DOCTYPE html><html><body style="font-family: -apple-system, sans-serif; font-size: 13px;">
<h2>Installed</h2>
<p>Canon Tether is now in your Applications folder.</p>
<p><b>First launch:</b> right-click the app &rarr; Open (one-time step for apps from independent developers).</p>
<p><b>Camera setup:</b> on the camera, choose the wired-LAN &ldquo;EOS Utility&rdquo; connection mode.
The app&rsquo;s <i>Manual Setup&hellip;</i> button shows the exact network values to enter, then the
app connects automatically once pairing completes.</p>
</body></html>
HTML

echo "==> Building component package…"
pkgbuild \
  --root "$STAGING/root" \
  --install-location /Applications \
  --identifier com.canontether.app \
  --version "$VERSION" \
  "$STAGING/CanonTether-component.pkg" >/dev/null

cat > "$STAGING/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Canon Tether ${VERSION}</title>
    <welcome file="welcome.html"/>
    <conclusion file="conclusion.html"/>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <domains enable_localSystem="true"/>
    <os-version min="12.0"/>
    <choices-outline>
        <line choice="default"><line choice="app"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false">
        <pkg-ref id="com.canontether.app"/>
    </choice>
    <pkg-ref id="com.canontether.app" version="${VERSION}">CanonTether-component.pkg</pkg-ref>
</installer-gui-script>
XML

echo "==> Building $PKG_NAME…"
productbuild \
  --distribution "$STAGING/distribution.xml" \
  --resources "$STAGING/resources" \
  --package-path "$STAGING" \
  "dist/$PKG_NAME" >/dev/null

rm -rf "$STAGING"

echo "==> Done: $ROOT/dist/$PKG_NAME"
echo "    Unsigned installer — users right-click → Open the .pkg once (same as the app itself)."
