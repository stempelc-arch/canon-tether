# Canon Tether

A lightweight tethered-shooting macOS app for the Canon EOS-1D X Mark II over **wired Ethernet**
(PTP/IP) or USB, built on [libgphoto2](http://www.gphoto.org/) — no Canon SDK, no Apple Developer
account, and nothing to install alongside it.

- **Tethered capture** from either shutter — the app's or the camera's — down the same path.
- **Live view** (⌘L) for composing, with the **scopes measuring the live feed**, so exposure is set
  against a real waveform instead of by eye. Taking a shot drops back to reviewing it.
- **Settings from either end.** Change ISO, shutter, aperture and white balance in the app or on the
  camera's own dials; each side reflects the other within a second or two.
- **Waveform + vectorscope** (luma / parade / RGB) with sRGB, Adobe RGB and Display P3 gamut
  overlays, and automatic **focus and exposure checks** on every frame.
- **Client review monitor** — full-screen on a second display, with a slideshow of your picks.
- **Picks are Finder tags** on the files themselves, so they show up in Finder and come back when
  you reopen a project. No sidecar files.

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
exist on a direct cable.

Pairing is completed **on the camera's own screen** — that's Canon's design, not an app
limitation — so if the app says the camera is re-pairing, press "Start pairing devices" on the
body and it will connect on its own. After a short power cycle it reconnects hands-free; after the
camera has been off for hours, expect to confirm the pairing once.

The camera stays usable in your own hands while tethered — the app listens gently enough that the
body doesn't lock its dials, so you can adjust settings on either end and each side reflects the
other.

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
