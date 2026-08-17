# Canon Tether

A lightweight tethered-shooting macOS app for the Canon EOS-1D X Mark II over **wired Ethernet**
(PTP/IP) or USB, built on [libgphoto2](http://www.gphoto.org/) — no Canon SDK, no Apple Developer
account. Tethered capture, live camera settings control, RGB/luma waveform + vectorscope with gamut
overlays, focus/exposure auto-checks, a client review monitor with slideshow, and Finder-tag-based
pick flagging that travels with the files.

## Install (prebuilt)

1. Download `CanonTether-<version>.dmg` from [Releases](../../releases).
2. Install gphoto2: `brew install libgphoto2 gphoto2`
3. Mount the DMG, drag the app to Applications.
4. First launch: **right-click → Open** (the app is unsigned; Gatekeeper needs the explicit bypass once).

## Camera setup (wired LAN)

On the camera: Network settings → wired LAN → EOS Utility mode. Use **Manual** IP configuration —
the app's "Manual Setup…" button (shown while disconnected) computes the exact values for your
machine. Auto/DHCP also works but wastes minutes timing out against a DHCP server that doesn't
exist on a direct cable. Pairing is driven from the camera's own screen; the app connects
automatically once the camera appears on the link.

## Build from source

Requirements: macOS 12+, Xcode command line tools, Homebrew gphoto2 (runtime dependency only —
nothing links against it; the app drives the `gphoto2` CLI).

```sh
git clone https://github.com/stempelc-arch/canon-tether.git
cd canon-tether
./scripts/build-app.sh   # → CanonTether.app
./scripts/make-dmg.sh    # → dist/CanonTether-<version>.dmg
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
