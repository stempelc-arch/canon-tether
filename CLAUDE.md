# Canon 1DX Mark II Tether App

## Goal
A lightweight, easy-to-use tethered-shooting macOS app for a Canon EOS-1D X Mark II, replacing Canon's clunky legacy software/drivers. No Apple Developer account and no Canon EDSDK developer registration — the app will be **unsigned** (right-click → Open to bypass Gatekeeper) and must use non-Canon-SDK tooling.

## Decided approach
**libgphoto2** (open source, no credentials needed) via Homebrew (`brew install libgphoto2 gphoto2`), driving the camera over **USB** using standard PTP. This is the proven path — the same library Linux tools like entangle/digiKam use, and the 1D X Mark II is well supported by it over USB.

## Ethernet/wired-LAN path: investigated and shelved (2026-07-22)
Spent a full session trying to get the camera's built-in wired-LAN "EOS Utility" pairing mode working so gphoto2 could connect over `ptpip:`, on a different Mac than this one. Findings:

- The 1D X Mark II's wired Ethernet uses PTP/IP, but wrapped in a proprietary Canon pairing/discovery layer (UPnP service `urn:schemas-canon-com:service:ICPO-WFTEOSSystemService:1`), not plain PTP/IP — `libgphoto2`'s `ptpip:` driver alone gets `Connection refused` because it never completes this handshake.
- An existing open-source helper (`reyalpchdk/ptpip-canon-helpers` on GitHub) does a similar UPnP pairing dance, but it's built for Canon **PowerShot/CHDK** cameras' Wi-Fi "Add a Device" flow — a different protocol/service than the EOS DSLR wired-LAN `WFTEOSSystemService`. Doesn't apply here.
- Even Canon's own official EOS Utility 3 hit real bugs: v3.16.11 hangs at 100% CPU browsing cameras on macOS Sequoia (known issue, fixed in v3.18.41+; Canon USA's 1DX Mark II page only lists old v3.13, and Canon Canada's download link is dead — used Canon Asia's support mirror instead: `asia.canon/en/support/0200721202`).
- Canon's "EOS Network Setting Tool" (separate app) turned out to be for configuring FTP/web-upload transfer profiles pushed onto the camera — **not** for EOS Utility pairing. Wrong tool, don't go down that path again.
- Correct pairing flow (in progress, not yet confirmed working end-to-end): camera must be in wired-LAN pairing mode showing "start EOS Utility on computer", EOS Utility must already be running/listening on the Mac, then the camera-side screen shows discovered computers to select and confirm — pairing is driven from the **camera's own screen**, not from any Mac-side menu (EOS Utility's File/Tool/View menus have no explicit "connect" action).

## Hardware/network quirks hit on the original dev Mac
On the original Mac (MacBook Pro, hostname Colbys-MacBook-Pro-2), the camera was connected via a USB-to-Ethernet adapter ("USB 10/100/1000 LAN", interface `en8`), not built-in Ethernet. That adapter was physically flaky — repeatedly disappeared from macOS entirely (not just link-down), needing reseating at both ends.

**Real footgun:** that adapter's network service was ranked *above* Wi-Fi in macOS's network service order. Once the camera gave the adapter link (even with just a private/manual IP and no real gateway), macOS started routing default internet traffic through it, killing real internet access. Fixed with:
```
networksetup -ordernetworkservices "Wi-Fi" <other services...>
```
If resuming Ethernet work with a USB-Ethernet dongle, check `networksetup -listnetworkserviceorder` first and make sure Wi-Fi outranks the camera adapter *before* plugging the camera in.

## Exposure increments: app can't set them, don't retry (2026-07-24)
Canon puts "exposure level increments" (1/3 vs 1/2 stop) on the body as custom function C.Fn I-1, and libgphoto2's PTP driver exposes no config for it — the only related knob is `customfuncex`, an opaque Canon hex blob. The camera reports *and accepts* only the values on whichever grid that C.Fn selects, so the app cannot invent the missing values: an app-side "1/2 stop" filter over a third-stop list leaves nothing but **whole** stops, because Canon's half-stop values (ISO 140/280, 1/45, 1/90, f/1.7, f/2.4) are absent from the third-stop list entirely. The reverse fails the same way.

So there is no app preference for this. `ExposureGrid` (in `CanonTetherCore`) instead *detects* which grid the body is on — median gap in stops between adjacent shutter/aperture values, ±0.09 tolerance — and the inspector shows every value the camera reports plus a small read-only readout ("1/3-stop increments"). ISO is excluded from detection on purpose: it follows a separate C.Fn ("ISO speed setting increments", 1/3 or 1 stop) and would skew the reading.

## Inspector + scopes (2026-07-24)
The right-hand column is `InspectorPanel.swift` (no longer inside `ContentView`): iOS-style inset
grouped cards — `SettingsSection` (caption + card + footnote), `SectionCard`, rows split into
Exposure and Image — with native Mac controls inside (real pop-up menus, semantic colours, tooltips).

**Crash gotcha (cost a full app crash on launch):** never pin an AppKit-backed control to a size
below its intrinsic one — `ProgressView().frame(height: 12)` wraps an `NSProgressIndicator` whose
minimum height is larger, so SwiftUI's `NSView.intrinsicLayoutTraits()` built min > max and
`validateDimension(min:ideal:max:)` trapped with **SIGILL / EXC_BAD_INSTRUCTION** a few seconds
after launch. The crash report points only at SwiftUI's layout engine, never at our code; find it by
looking for a frame/`fixedSize` clamped tighter than a platform control's intrinsic size.

Layout constraints worth knowing before touching it:
- A `.menuStyle(.borderlessButton)` Menu **ignores alignment inside its own label** (a leading
  `Spacer` does nothing), so `.fixedSize()` is what right-aligns the value column. That makes the
  menu rigid, so a long value squeezes the setting's *name* instead of truncating itself — hence
  the panel's 344 pt minimum width, and why only sections that have steppers reserve the 52 pt
  stepper gutter.
- A `frame(maxWidth:)` inside a `fixedSize`'d menu label reports the *max*, not the content width,
  so it can't be used to cap value width — it just truncates every row's name. Row values are
  instead capped by `rowLabel` at 24 characters, which keeps that rigid width bounded so it can
  never set a floor under the pane's minimum width and jam the divider.
- **HSplitView comes to rest at one extreme, never at `idealWidth`.** Whichever pane is greedy wins,
  and the inspector is: it rests at its **maximum** (560) and grows with the window, which is what
  keeps the vectorscope — square, so bounded by the column width — big enough to read. Giving the
  capture column `layoutPriority(1)` flips this, parking the inspector at its minimum instead; that
  was tried and reverted, since the scopes matter more than the extra photo width. Either way the
  divider only drags *away* from the resting end. Verified with synthetic drags, reading the
  splitter position back out of the accessibility tree.
- A greedy `ScrollView` sibling will happily eat a flexible scope: the vectorscope stayed ~250 pt in
  a 560 pt column until it was given a **definite** `frame(width:height:)` instead of an
  `aspectRatio` inside a flexible box.

`ScopesPanel.swift` draws a Resolve-style waveform (Luma / Parade / RGB, `@AppStorage`-persisted)
with the vectorscope stacked beneath it, measuring whatever the main viewer shows. The pair is
pinned to the bottom of the column, outside the settings scroll view, so it's always on screen.
`ScopeLayout` sizes both from the column's measured size, so they grow with the window and with the
divider; it also picks the raster resolution and how finely the photo is sampled. The maths is
Foundation-only in `CanonTetherCore/ScopeAnalysis.swift` (`ScopeRenderer`) and unit-tested.

Both scopes are accumulation plots brightened by `1 - exp(-gain · count)`, with gain derived from
the sample count (and, for the vectorscope, from cell area) so brightness never depends on the
resolution either side is rendered at. Three findings sit behind the current numbers:
- `vectorGain` is **1.5, not 1.8**: the furthest any sRGB pixel can reach is 100 % green/magenta at
  0.596 CbCr, so 1.8 threw them outside the graticule ring, clipped off the plot and silently lost.
- The trace is **colourised** — each cell drawn in the colour its position encodes (inverse Rec.709,
  luma chosen to saturate the top channel, which keeps neutrals white at the centre rather than
  black). Colour comes from the cell, not from the pixels landing in it, so a shadow and a highlight
  of one hue draw the same colour.
- Chroma spreads over a wide area, so a big vectorscope goes **stippled and dark** if it's fed like
  a small one. Three things fix that together: bilinear splatting of each sample across the four
  cells it falls between, a 0.55 gamma lift on the intensity curve, and — the one that matters most
  — raising the *source* sample with the plot size (`ScopeLayout.sampleSize`, 800 → 1280 px). At
  1280 px both scopes take ~70 ms off the main thread, which is nothing against the rate shots land.

When a trace looks wrong, check the photo before the renderer: `scratchpad`-style probes showed a
suspiciously dull plot was simply a dull frame (median chroma 0.08), while the yellow-backdrop
shots measure median 0.67 with rgb(248,248,0) out at 0.73 of the ring.

### Gamut boundary overlay (2026-07-27)
The vectorscope can outline a colour-space boundary (Scopes header → hexagon menu: None / sRGB /
Adobe RGB / Display P3, persisted in `@AppStorage("gamutOverlay")`). `ScopeRenderer.gamutBoundary`
computes each space's six primary/secondary vertices in the scope's own coordinates via
`Colorimetry` (primaries+white → RGB→XYZ, compose with sRGB's inverse, extended-sRGB gamma → Rec.709
Cb/Cr). The sRGB hexagon lands exactly where 100 % sRGB pixels plot (verified against the trace), so
it reads as an "inside = legal" line; wider gamuts' green corners reach ~1.3× the ring.

For this to be *meaningful* the trace must be able to exceed sRGB, so sampling is **extended-range
sRGB float** (`ScopeFrame.rgba` is now `[Float]`, not `[UInt8]`): wide-gamut content survives as
values outside [0,1] and plots past the sRGB hexagon. Two hard-won facts:
- **The camera's data is sRGB.** Embedded previews are sRGB-gamut, and ImageIO's RAW decode clamps
  to sRGB at every thumbnail size (a full `CGImageSourceCreateImageAtIndex` into a float context
  returns garbage). So on these files the trace stays inside sRGB by construction — the wider
  hexagons are correct reference geometry but only come alive if the body is set to shoot Adobe RGB.
  Don't chase this as a bug; it's the sensor/ImageIO pipeline.
- **A 32-bit-float `CGContext` needs `byteOrder32Little`** in its `bitmapInfo` alongside
  `.floatComponents`, or context creation fails and the buffer stays **all zero — a silently black
  scope**. This bit once; the probe that "verified" wide-gamut data had initialised its min/max to
  [0,1] and so masked the all-black buffer. Always measure a real mean, not just the range.

The scope is **always drawn at full/maximum size and never resizes between gamuts** (an earlier
version zoomed out by a `fit` factor to keep a wide hexagon in view — removed, the size-change was
disliked). A wide gamut's hexagon (Adobe/P3 green ~1.3× the ring) simply extends past the ring and
clips at the view edge, which reads fine as "this gamut is wider than the scope shows"; the trace,
being sRGB, never clips. Menu is None(="Off")/sRGB/Adobe RGB/Display P3. Tests: the `swiftc` harness
covers the float path (37 checks) and a separate colorimetry harness checks the vertices; XCTest has
gamut cases too (via `@testable import` for the internal `Colorimetry`).

## Projects = capture folders, switchable live (2026-07-27)
The capture folder *is* the project. Preferences → "Choose…" switches it at runtime
(`CameraViewModel.changeCaptureFolder`): the gallery clears immediately, then repopulates from the
chosen folder — empty for a new folder, the existing shots for one revisited. `ReviewModel`'s
`resetForNewProject()` runs first so the client monitor doesn't linger on an old-folder photo (its
`clientPinnedURL` fallback), then the `captures` change drives `sync`, which reloads that folder's
flags. **Flags are macOS Finder tags** (`URLResourceValues.tagNames` read / `NSURL
setResourceValue(_,forKey:.tagNamesKey)` write) — stored in the file's own
`com.apple.metadata:_kMDItemUserTags` xattr, no sidecar — which is the whole reason picks survive a
project switch and come back on return. Don't replace this with a sidecar/JSON scheme; that xattr is
the persistence.

Gotcha: gphoto2's shell downloads into its **launch cwd**, fixed at spawn, so `setCaptureDirectory`
tears the shell down — the self-healing tether loop (or the next `connect()`) relaunches it against
the new folder within ~1s. So a live switch costs a camera reconnect; switching between shoots
(camera idle) is free.

## Testing gotcha
`swift test` dies with `error: Exited with signal code 11` on this Mac — a segfault in the XCTest
runner, not in the app code (confirmed 2026-08-19: `xcrun xctest` run directly against the built
`.xctest` bundle segfaults identically, so it is the environment, not SwiftPM's wrapper).

**Because of that the suite silently rotted**: by 2026-08-19 the XCTest files no longer even
*compiled* against the current API (`ExposureAnalyzer` had gained separate highlight/shadow/
near-white limits months earlier), and nothing surfaced it. GitHub Actions (`.github/workflows/
ci.yml`) now builds and runs the tests on a clean runner on every push, and also rebuilds the app
bundle and asserts the embedded gphoto2 has zero Homebrew references — the "works here, breaks on
the user's Mac" check that no local run can make. To verify logic, compile the sources plus a throwaway
`main.swift` directly with `swiftc` and run that. Two such harnesses proved out the project-switch
work: one exercises the Finder-tag flag round-trip on real files (tag lands in the xattr, no sidecar,
follows the file, reloads per-folder); one drives the real `CameraViewModel`+`ReviewModel` through
A→empty B→A, checking the gallery clears and repopulates with flags. When comparing URLs in these,
resolve symlinks — `contentsOfDirectory` returns `/private/var` while seeds are `/var`.

## NEVER probe port 15740 during pairing (2026-08-17)
The 1DX II **aborts its own wired-LAN pairing negotiation** if anything TCP-connects and
immediately closes on port 15740 mid-announce (ssdp:byebye → 3x mDNS probe → ssdp:alive, ~5-8s):
it `igmp leave`s both multicast groups and never becomes connectable, staying on "pairing in
progress" forever. This caused days of failed pairing that survived firmware 1.1.8 *and* a full
factory reset — the app's own `isReachable()` fast-reconnect probe was re-triggering the abort on
every retry. A real client that stays connected (gphoto2's `openShell`) is fine even mid-announce.
The guard lives in `GPhotoSession.swift`: `hasEverConnected` disables the probe until the session
has paired once, and 5 consecutive probe refusals clear it again (a camera refusing 15740 at an
ARP-vouched address is re-pairing). Do not "optimize" reconnects by adding any probe/healthcheck
that opens-then-closes 15740 without this gating. Also: a rebuilt binary does nothing until the app
process is actually quit and relaunched — compare `ps -o lstart` against the binary's mtime before
concluding a fix failed.

## The camera does not always announce itself — solicit it (2026-08-17)
**A silent camera is not a broken camera.** The body can sit fully powered, on its manual IP, and
answering pings in 0.2 ms while sending *nothing* unsolicited — no gratuitous ARP, no announcement.
Since `networkCameraIP()` reads the ARP table, and the ARP table only lists hosts this Mac has
actually exchanged packets with, the app was blind to it: nine minutes of "waiting for camera"
across three power cycles and a battery pull, with the camera reachable the whole time. One `ping`
populated ARP and the app connected within seconds.

So `cameraIP()` now *solicits* (see `solicitCamera`): pings the last address the camera answered at
(persisted in UserDefaults) plus neighbours of this Mac's own link-local address. **ICMP is safe
during pairing — a TCP probe is not.** The footgun below is specifically connect-then-close on
15740; a ping was verified live against a mid-pairing camera with no disruption.

Diagnostic lesson worth keeping: "link active, zero inbound packets" reads like a wedged device and
isn't. Before concluding a network device is dead, *address* it (ping it, ARP for it) — passive
observation cannot distinguish "absent" from "quiet". `netstat -ib` deltas and `ifconfig <if> |
grep status` tell you about the link; only a solicited reply tells you about the device.

## Bonjour discovery: investigated and rejected (2026-08-17)
The camera **does** advertise `_ptp._tcp` (instance name `ICPO-WFTEOSSystemService<serial>`, the
same Canon service seen in the July UPnP investigation) — `dns-sd -B _ptp._tcp local.` finds it
immediately. But **resolving that service to an address always fails**: `NetServiceBrowser` reports
`didFind` and then `didNotResolve` with `NSNetServicesTimeoutError` (-72007) after an 8s timeout,
and `dns-sd -L` returns nothing either. The body announces its PTR record but won't answer the
follow-up SRV/A queries, so mDNS can tell you a camera exists and never tell you where it is.
Discovery therefore stays on the ARP table (`arp -an`, see `networkCameraIP`). Don't rebuild a
Bonjour path expecting faster discovery; the announcement is real but useless for addressing.

## "Camera busy" is us, not the camera (2026-08-17)
The body reports **busy and locks its own dials whenever the app polls hard**. It isn't a Canon
policy about tethering — EOS Utility manages both ends fine. The old tether watch asked
`wait-event-and-download 50ms` on a 30ms loop, i.e. ~12 commands/second, leaving no idle moment in
which the camera could accept input. The listening window is now **adaptive** (`tetherWindow`):
50ms while frames are arriving so bursts stay immediate, 1s once shooting goes quiet. Crucially a
longer window is *not* slower listening — gphoto2 downloads a frame the instant the event arrives
either way, and only the app's notification waits for the window to close — so the cost is up to a
second of gallery delay on an idle body-shutter shot, and the gain is a camera usable in the
photographer's hands. A manual "stop polling" button was built and then **removed**: needing to
press something is not the app working as intended, and adaptive listening made it unnecessary.

**Discovery must be self-healing and must log.** Observed 2026-08-19: after a dropped session the
reconnect loop ran **19.5 hours** without once logging "found camera", and a fresh process
connected in 10 seconds — the app appeared to need quitting and reopening to reconnect. Discovery
logged nothing about what it solicited or what ARP held, so the cause could not be established
after the fact. It now logs both (rate-limited), sweeps neighbouring addresses every cycle once the
remembered address stops working (a camera back on a different self-assigned address is otherwise
invisible forever, since this body doesn't reliably announce itself), and every ~120 failed cycles
restores the state a relaunch would give it: `closeShell`, `hasEverConnected = false`, fresh
solicit rhythm, cleared buffer.

**Batch multi-command reads.** A settings read is five `get-config`s; with one lock acquisition
each, every one queued behind a full tether window — the read cost ~5s and polls landed 6.3s apart,
so a dial turned on the body reached the inspector six seconds later. `withCommandLock` +
`sendCommandLocked` take the lock once for the whole batch (one wait, five fast commands), which
also holds the camera for a single contiguous window instead of interleaving five times. That made
a 1.5s poll affordable. Verified live: shutter changes made on the body now appear with no
`set-config` behind them, ~1.6s apart.

## Live scopes (2026-08-17)
The waveform/vectorscope measure the live view feed while it's running, not just captures —
`ScopeSampler.sample(_ image: CGImage,…)` shares the same float pipeline as the file path, so a
live reading and the reading off the resulting capture are comparable rather than two different
measurements. Sampled a few times a second at a smaller size (`liveScopeInterval`,
`liveSampleSize`), because exposure doesn't change 8×/second and the plot has to be *read*.
`ScopesPanel` holds `LiveViewFeed` as a **plain reference, not `@ObservedObject`** — observing it
would reinstate the per-frame invalidation described below.

**Never publish live view frames from `CameraViewModel`.** They live on their own `LiveViewFeed`
object. On the shared view model, each frame invalidated the toolbar, inspector, filmstrip and the
client review window — re-running the filmstrip's "good shots only" filter across the whole session
8×/second.

## Live view (2026-08-17)
`capture-preview` over the persistent shell, looped: each frame lands as a JPEG in the shell's cwd
(the capture folder, since the interactive shell ignores `--filename`), is read, **deleted
immediately**, and yielded as `Data` on `liveViewStream()`. Deleting matters twice over — a preview
is not a capture and must never reach the gallery, and leaving the file there makes the next frame
hit gphoto2's overwrite prompt. Stranded frames (crash mid-stream) are swept on stop and filtered
out of `loadExistingCaptures` by the `capture_preview` prefix.

The tether watch keeps running during live view on purpose: frames and camera-shutter downloads
interleave over the one shell via the command lock, which costs frame rate but means a shot fired
while composing is still captured. Frames are decoded off the main actor (`Task.detached`) — at
streaming rates, decoding on the main thread stutters the whole UI.

## Next steps
- Confirm how the "other Mac" (where this was reopened) currently connects to the camera — USB or Ethernet — since that determines whether to resume the Ethernet investigation or go straight to USB + libgphoto2.
- If USB: install `libgphoto2`/`gphoto2` via Homebrew, confirm `gphoto2 --auto-detect` sees the camera, then start building the app (SwiftUI native app was the agreed shape; scope included tethered capture, live view, camera settings control, and post-capture preview — build capture first, layer in the rest).
