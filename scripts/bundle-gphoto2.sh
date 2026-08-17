#!/bin/bash
# Embeds gphoto2 + libgphoto2 (and their full dylib closure + camera/IO plugins) inside
# CanonTether.app, rewriting every library path to be bundle-relative. After this, the app has no
# Homebrew dependency at all — GPhotoSession prefers the bundled binary and points CAMLIBS/IOLIBS
# at the bundled plugin dirs.
#
# Called by build-app.sh. Requires a Homebrew gphoto2 install on the *build* machine only.
set -euo pipefail

APP="${1:?usage: bundle-gphoto2.sh <path/to/CanonTether.app>}"

PREFIX=""
for p in /opt/homebrew /usr/local; do
  [ -x "$p/bin/gphoto2" ] && PREFIX="$p" && break
done
[ -n "$PREFIX" ] || { echo "error: Homebrew gphoto2 not found (needed to build the bundle)"; exit 1; }

DEST="$APP/Contents/Frameworks/gphoto2"
rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/camlibs" "$DEST/iolibs"

cp -L "$PREFIX/bin/gphoto2" "$DEST/bin/gphoto2"

# Camera drivers and port drivers live in versioned plugin dirs and are dlopen()ed at runtime.
CAMLIB_DIR=$(find -L "$PREFIX/lib/libgphoto2" -maxdepth 1 -type d -name '[0-9]*' | sort | tail -1)
IOLIB_DIR=$(find -L "$PREFIX/lib/libgphoto2_port" -maxdepth 1 -type d -name '[0-9]*' | sort | tail -1)
[ -n "$CAMLIB_DIR" ] && [ -n "$IOLIB_DIR" ] || { echo "error: camlibs/iolibs dirs not found"; exit 1; }
cp -L "$CAMLIB_DIR"/*.so "$DEST/camlibs/"
cp -L "$IOLIB_DIR"/*.so "$DEST/iolibs/"

# Walk the dylib dependency closure of the binary and every plugin, copying each Homebrew dylib
# into lib/ under its install-name basename.
is_local() { case "$1" in /usr/local/*|/opt/homebrew/*) return 0;; *) return 1;; esac; }

deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

queue=("$DEST/bin/gphoto2")
while IFS= read -r -d '' so; do queue+=("$so"); done < <(find "$DEST/camlibs" "$DEST/iolibs" -name '*.so' -print0)

seen=""
i=0
while [ $i -lt ${#queue[@]} ]; do
  file="${queue[$i]}"; i=$((i+1))
  while IFS= read -r dep; do
    is_local "$dep" || continue
    base=$(basename "$dep")
    case "$seen" in *"|$base|"*) continue;; esac
    seen="$seen|$base|"
    cp -L "$dep" "$DEST/lib/$base"
    queue+=("$DEST/lib/$base")
  done < <(deps_of "$file")
done

# Rewrite: every embedded image gets @rpath install names, and every reference to a Homebrew path
# becomes @rpath/<basename>. The main binary carries the one rpath (@executable_path/../lib) that
# resolves them all — dlopen()ed plugins inherit the executable's rpath stack.
rewrite() {
  local file="$1"
  while IFS= read -r dep; do
    if is_local "$dep"; then
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null
    fi
  done < <(deps_of "$file")
}

install_name_tool -add_rpath "@executable_path/../lib" "$DEST/bin/gphoto2"
rewrite "$DEST/bin/gphoto2"
for lib in "$DEST/lib/"*.dylib; do
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib"
  rewrite "$lib"
done
for so in "$DEST/camlibs/"*.so "$DEST/iolibs/"*.so; do
  rewrite "$so"
done

# install_name_tool invalidates signatures; ad-hoc re-sign every embedded image (the final
# whole-app codesign in build-app.sh covers nesting, but each Mach-O must be individually valid).
find "$DEST" -type f \( -name '*.dylib' -o -name '*.so' -o -name 'gphoto2' \) \
  -exec codesign --force --sign - {} \; 2>/dev/null

# Smoke-test the bundled binary in isolation: it must run with NO Homebrew paths involved.
CAMLIBS="$DEST/camlibs" IOLIBS="$DEST/iolibs" DYLD_LIBRARY_PATH="" "$DEST/bin/gphoto2" --version >/dev/null \
  || { echo "error: bundled gphoto2 failed its smoke test"; exit 1; }

echo "    bundled gphoto2 $(CAMLIBS="$DEST/camlibs" IOLIBS="$DEST/iolibs" "$DEST/bin/gphoto2" --version | head -1) + $(ls "$DEST/lib" | wc -l | tr -d ' ') dylibs + $(ls "$DEST/camlibs" | wc -l | tr -d ' ') camlibs"
