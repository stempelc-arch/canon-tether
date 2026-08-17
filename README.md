# Canon Tether

A lightweight tethered-shooting macOS app for the Canon EOS-1D X Mark II over **wired Ethernet**
(PTP/IP) or USB, built on [libgphoto2](http://www.gphoto.org/) — no Canon SDK, no Apple Developer
account. Tethered capture, live camera settings control, RGB/luma waveform + vectorscope with gamut
overlays, focus/exposure auto-checks, a client review monitor with slideshow, and Finder-tag-based
pick flagging that travels with the files.

## Install (prebuilt)

1. Download `CanonTether-<version>-Installer.pkg` from [Releases](../../releases).
2. Right-click the .pkg → **Open** (one-time Gatekeeper step for an unsigned installer), and follow
   the installer.
3. First app launch: **right-click → Open** (same one-time step).

The installer is fully self-contained — the camera engine (gphoto2/libgphoto2) is embedded in the
app, no Homebrew or Terminal needed.

## Camera setup (wired LAN)

On the camera: Network settings → wired LAN → EOS Utility mode. Use **Manual** IP configuration —
the app's "Manual Setup…" button (shown while disconnected) computes the exact values for your
machine. Auto/DHCP also works but wastes minutes timing out against a DHCP server that doesn't
exist on a direct cable. Pairing is driven from the camera's own screen; the app connects
automatically once the camera appears on the link.

## Build from source

Requirements: macOS 12+, Xcode command line tools, and Homebrew gphoto2 on the **build** machine
(`brew install libgphoto2 gphoto2`) — the build embeds it into the app, so installs need nothing.

```sh
git clone https://github.com/stempelc-arch/canon-tether.git
cd canon-tether
./scripts/build-app.sh   # → CanonTether.app (with gphoto2 bundled inside)
./scripts/make-pkg.sh    # → dist/CanonTether-<version>-Installer.pkg (guided installer)
./scripts/make-dmg.sh    # → dist/CanonTether-<version>.dmg (drag-install alternative)
```

`swift build` / `swift run CanonTether` work for development. The app version is set in
`scripts/version.sh`.

Note: `swift test` segfaults in SwiftPM's XCTest helper on some machines (see CLAUDE.md); the
project's convention is verifying logic with small standalone `swiftc` harnesses when that happens.

## Layout

- `Sources/CanonTetherCore` — Foundation-only logic (scope/colorimetry math, exposure/focus
  analysis, camera-setting parsing). Unit-tested.
- `Sources/CanonTetherLib` — the SwiftUI app: `GPhotoSession` (actor owning the persistent
  `gphoto2 --shell`), view models, views, scopes.
- `Sources/CanonTether` — app entry point.
- `CLAUDE.md` — engineering notes and hard-won gotchas (read before touching the connection code,
  especially the "never probe port 15740 during pairing" section).
