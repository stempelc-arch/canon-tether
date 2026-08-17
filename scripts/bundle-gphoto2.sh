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
# sort -V, not sort: these are version directories, and a lexical sort picks 2.5.9 over 2.5.34
# when an older keg is left behind.
CAMLIB_DIR=$(find -L "$PREFIX/lib/libgphoto2" -maxdepth 1 -type d -name '[0-9]*' | sort -V | tail -1)
IOLIB_DIR=$(find -L "$PREFIX/lib/libgphoto2_port" -maxdepth 1 -type d -name '[0-9]*' | sort -V | tail -1)
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
      # Hard-fail rather than swallow: a rewrite can genuinely fail (too little header padding
      # for the longer @rpath name is the classic), and a silently-skipped one leaves an absolute
      # Homebrew path that works here and breaks on the user's Mac.
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" \
        || { echo "error: failed to rewrite $dep in $file"; exit 1; }
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
# Must hard-fail: an unsigned dylib is refused by the kernel on Apple Silicon, and `find` returns
# success no matter what -exec did, so the status is checked explicitly.
while IFS= read -r -d '' image; do
  codesign --force --sign - "$image" || { echo "error: codesign failed for $image"; exit 1; }
done < <(find "$DEST" -type f \( -name '*.dylib' -o -name '*.so' -o -name 'gphoto2' \) -print0)

# --- Verification -----------------------------------------------------------------------------
# `gphoto2 --version` is NOT a valid check: it never dlopen()s a camera or port driver, so it
# exits 0 even with both plugin directories empty. A build could therefore ship with no drivers
# at all and every user would see "No camera detected" forever, with nothing in the log.
# `--list-cameras` does load the camlibs, so it actually discriminates: ~2800 lines when the
# drivers are present, 2 when they aren't.
# Captured into variables rather than piped: under `set -o pipefail`, `grep -q` exits on its first
# match and SIGPIPEs gphoto2, which fails the pipeline and would abort a perfectly good build.
CAMERA_LIST=$(CAMLIBS="$DEST/camlibs" IOLIBS="$DEST/iolibs" "$DEST/bin/gphoto2" --list-cameras 2>/dev/null || true)
PORT_LIST=$(CAMLIBS="$DEST/camlibs" IOLIBS="$DEST/iolibs" "$DEST/bin/gphoto2" --list-ports 2>/dev/null || true)
CAMERAS=$(printf '%s\n' "$CAMERA_LIST" | wc -l | tr -d ' ')
PORTS=$(printf '%s\n' "$PORT_LIST" | wc -l | tr -d ' ')
[ "$CAMERAS" -gt 100 ] || { echo "error: bundled gphoto2 lists only $CAMERAS cameras — camlibs missing/broken"; exit 1; }
[ "$PORTS" -gt 4 ] || { echo "error: bundled gphoto2 lists only $PORTS ports — iolibs missing/broken"; exit 1; }
# The camera driver this app exists for, and the transport it uses over wired LAN.
# gphoto2 spells it "Canon EOS 1D X MarkII" — no space before the numeral.
case "$CAMERA_LIST" in
  *"1D X MarkII"*) ;;
  *) echo "error: bundled gphoto2 does not list the EOS-1D X MarkII"; exit 1 ;;
esac
case "$PORT_LIST" in
  *ptpip*) ;;
  *) echo "error: ptpip port driver missing — wired-LAN tethering would not work"; exit 1 ;;
esac

# Static check that nothing still points at Homebrew. This is the real "works here but not on the
# user's Mac" guard: an unrewritten dep is an *absolute* path, which resolves fine on this machine
# and is unaffected by DYLD_LIBRARY_PATH, so no amount of running it here would reveal the problem.
LEAKS=$(find "$DEST" -type f \( -name '*.dylib' -o -name '*.so' -o -name 'gphoto2' \) -exec otool -L {} \; \
        | grep -cE '/usr/local/|/opt/homebrew/' || true)
[ "$LEAKS" -eq 0 ] || {
  echo "error: $LEAKS embedded reference(s) still point at Homebrew — the bundle would break on a Mac without it"
  find "$DEST" -type f \( -name '*.dylib' -o -name '*.so' -o -name 'gphoto2' \) -exec otool -L {} \; \
    | grep -E '/usr/local/|/opt/homebrew/' | sort -u | head
  exit 1
}

echo "    bundled gphoto2 $(CAMLIBS="$DEST/camlibs" IOLIBS="$DEST/iolibs" "$DEST/bin/gphoto2" --version | head -1) + $(ls "$DEST/lib" | wc -l | tr -d ' ') dylibs + $(ls "$DEST/camlibs" | wc -l | tr -d ' ') camlibs"
