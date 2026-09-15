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

**Switching projects no longer touches the connection (fixed 2026-09-11).** gphoto2 downloads into
its launch cwd, fixed at spawn, so `setCaptureDirectory` used to tear the shell down and reconnect.
That was written when a reconnect looked cheap; it isn't — on this body one can mean re-pairing from
the camera's own screen, which is not an acceptable price for choosing a folder mid-shoot. The cwd
is now a fixed **staging** folder (`GPhotoSession.stagingDirectory`, in Caches) and
`importDownloaded` moves each file into whichever project is current, so a switch is a variable
assignment. Staging also keeps half-written downloads and live-view frames out of the photographer's
folder entirely. Consequence: the capture folder is no longer validated at connect time, so an
unwritable folder surfaces at import instead — the shot is held in staging and the status says so,
rather than the connection failing.

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

## Focus stacking (2026-09-11)

Toolbar → "Focus Stack" opens `FocusStackPanel`, a sheet: shoot a focus bracket, merge it to one
full-resolution all-in-focus TIFF beside the frames. Three layers, split so the maths is testable
without a camera:

- `CanonTetherCore/FocusStack.swift` — `StackImage` (interleaved float, any channel count) plus the
  Gaussian/Laplacian pyramid. Deliberately **not** `ScopeFrame`: the scopes measure a small display
  snapshot, stacking mutates real pixel data level by level.
- `FocusStackMerge.swift` — pyramid fusion, plus the `CoverageMap` ("which frame won where").
- `FocusStackAlign.swift` — `SimilarityTransform` (centre-anchored scale + translate) and the
  neighbour-chained registration.
- `FocusStackPlan.swift` — bracket arithmetic, `FocusStep`/`FocusDriveCapability`, and
  `FocusStackCritique` (advice for the *next* bracket).
- `CanonTetherLib/FocusStackRenderer.swift` — ImageIO decode, strip-wise merge, TIFF out.
- `FocusStackModel.swift` — its own `ObservableObject`, owned by `CameraViewModel` but separate from
  it for the same reason `LiveViewFeed` is: a bracket publishes on every frame and nudge, and a
  merge many times a second, which would otherwise invalidate toolbar/inspector/filmstrip throughout.

### Focus is open-loop — there is no position to read
Canon's PTP gives exactly one focus control, the vendor action `/main/actions/manualfocusdrive`,
taking Near/Far × 1/2/3. **Nothing reports where the lens actually is**, before, during or after. So
a bracket is a *count of nudges*, not a range between two distances; the settle time is a timeout,
not a handshake; and the only feedback loop is `FocusStackCritique` reading the coverage map after
the merge. The sequencer always walks focus back the same number of nudges on finish, error *or*
cancel — leaving the lens parked mid-rack after an abort is what makes a failed attempt expensive.

**Live view is started for the bracket if it isn't already running.** Focus drive is a live-view-mode
operation on this body; without it a bracket silently produces N identical frames, which is the worst
possible failure because it looks like it worked. `FocusStep.choice(for:in:)` matches the body's
advertised choice list on direction+magnitude rather than an exact string, since the spelling has
varied between libgphoto2 versions, and `isDrivable` requires *both* directions — a body listing only
"None" has the property but cannot drive.

**Not yet verified on this body.** The capability is probed at runtime over the session's existing
shell (`GPhotoSession.focusDriveCapability`) and the panel reports the three honest states rather
than assuming support. A second `gphoto2` was deliberately *not* run to check, since the app held a
live PTP/IP session — and per the pairing notes above, a forced reconnect can cost a re-pair from the
camera's own screen. Confirm with the panel's "Re-check", and read `~/Library/Logs/CanonTether.log`
for the parsed capability.

### Why the merge is built the way it is
Picking the sharper *pixel* seams and haloes. Instead each Laplacian level blends by **smoothed local
energy** (`selectivity = 4`), so a focus boundary crossfades over that band's own scale. Three
findings are load-bearing and were each caught by the harness, not by eye:

- **Energy must be pooled over a neighbourhood before comparing.** A single coefficient is noise-
  dominated; a blurred frame's noise beats a sharp frame's flat region pixel-for-pixel.
- **The base (coarsest) level is a plain average, never a contest.** Defocus barely touches the
  lowest frequencies, so there is no signal to choose on, and choosing anyway makes large flat areas
  take the brightness of whichever frame won — banding across skies and backdrops.
- **Coverage is read off the *finest* band, then pooled** — not off a mid level. Defocus is a
  high-frequency phenomenon: measured, a mid-level read attributed only ~67% of a synthetic
  half-blurred pair correctly, because by then the two frames carry nearly the same energy.

### Full resolution means strips, not one big buffer
A 20 MP frame is ~240 MB as interleaved RGB float, and the merge needs every frame resident *plus* a
pyramid each — a ten-frame stack asks ~6 GB naively. So: decode each frame **once** to a flat 16-bit
scratch file (decoding a CR2 is the expensive step; doing it per-tile would be fatal), align on
640 px previews and rescale the transforms, then merge in horizontal strips of 512 rows with **192
rows of overlap discarded each side**. The overlap must exceed the pyramid's reach (`2^levels`,
hence `pyramidLevels = 6`) or a seam appears at every strip boundary — there is a regression check
for exactly this, using a test pattern with horizontal sharpness bands so the strip edges are
guaranteed to cut through focus transitions.

Two CoreGraphics traps cost real time here:
- **There is no 16-bit-per-component `CGContext` without an alpha channel.** Asking for
  `CGImageAlphaInfo.none` at 16 bpc returns nil and the decode silently fails; draw into
  `noneSkipLast` RGBA16 and pack down to RGB.
- The strip **coverage accumulator must derive its row scale from each strip's actual band height**,
  not the nominal one. The first and last strips are shorter (overlap on one side only; truncated by
  the image edge), and assuming the nominal height slid the whole coverage map against the image —
  which showed up as bands being attributed to the neighbouring frame.

Colour ceiling: per the gamut notes above, ImageIO's RAW decode clamps to sRGB, so the merged TIFF is
sRGB-gamut 16-bit. That is the decode path's limit, not a choice made in the renderer.

### A bracket is one capture, not twelve (2026-09-11)
The bracket's frames are **never shown in the filmstrip** — a dozen near-identical rack-focus frames
are not a dozen photographs, and listing them buries the real shots. Instead:

- `GPhotoSession.stackGroupDirectory` is set for the duration of a bracket. While it is set,
  `importDownloaded` moves every downloaded frame into that folder *and skips the
  `captureContinuation.yield`* — which is what keeps them out of the gallery. This deliberately also
  captures a frame fired from the body's own shutter mid-bracket: a shot taken at one of the
  bracket's focus positions belongs with that stack.
- The folder is `<stamp> Focus Stack` in the project root (`CaptureLocation.stackFolderName`),
  sharing the capture filename stamp so it sorts among the shots around it. The merged image goes
  *inside* it as `<stamp>-stack.tif`.
- **Merging is automatic** once a bracket finishes (`FocusStackModel.startBracket` calls `merge()`).
  It has to be: the frames are hidden, so an unmerged bracket is a capture that produced nothing
  visible. The panel's Merge button is now only a retry for when that automatic merge failed.
- `FocusStackModel.onStackMerged` hands the finished TIFF to `CameraViewModel.registerMergedStack`,
  which is how a stack becomes a capture for the rest of the app. `loadExistingCaptures` reaches one
  level into each stack folder for exactly that one file, so stacks survive relaunch and project
  switches. A folder with no merged image yet (interrupted bracket) contributes nothing.

Verified with a `swiftc` harness that drives the real `CameraViewModel` over a seeded project
(ordinary shots + a finished stack + an interrupted stack + a stranded preview frame): 14 checks,
confirming the merged TIFF is listed and the source frames are not. Note `CaptureLocation` lives in
`CanonTetherLib`, which the XCTest target does **not** depend on — wiring that up would pull SwiftUI
into the test bundle, which is a risk to a CI signal that currently works, so it was left alone.

### Direction: default is *away* from the camera (2026-09-11)
The first build defaulted to stepping toward the camera and buried direction inside a six-way step
menu ("Fine — nearer"). A real test bracket was shot with focus already set near and racked further
in, off the subject — and nothing about that looks wrong while shooting. So: the default is now
`farSmall`, direction is its **own** control ("Focus moves: away / toward camera"), and the summary
line says where to put focus first. The defaults key is `focusStackPlan.v2` because v1's wrong
direction had already been persisted, and `loadPlan` no longer writes back what it reads — otherwise
a plan the photographer never touched gets saved on first launch and pins them to whatever the
default was that day.

### Ranging: depth is measured in counted nudges (2026-09-11)
`FocusRange` (Core). **There is no focus position to read**, so depth cannot be expressed in
millimetres or focus distance — but a signed *count of nudges* is exact, and it is the same unit the
bracket walks, so a marked range reproduces precisely when shot. Mark near, rack while the app
counts, mark far; `FocusRangePlanner` turns span + overlap into the plan, and `startBracket` walks
focus to the near mark first (a marked range is meaningless if the bracket doesn't start there).

- **A range is only valid for the step magnitude it was measured at.** Canon never documents how
  Near 1/2/3 relate, and it differs by lens, so counts at one size cannot be converted to another.
  Changing step size therefore *retires the marks* rather than rescaling them into a number that
  would look authoritative and be wrong.
- **`FocusOverlap` is not a percentage of depth of field** — nothing here knows the DOF (aperture,
  focal length, subject distance, focus throw; the camera reports none of it in nudge terms). It is
  literally nudges-between-frames, presented as a tightness. Default is `maximum` (a frame at every
  step): gaps cannot be fixed afterwards because the missing focus was never recorded, while extra
  frames only cost time.
- **Auto-find** sweeps ±10 nudges scoring live view with the existing `FocusAnalyzer`, and
  `FocusScanReader` takes the run around the peak that clears **60% of the scan's own peak** —
  relative, because absolute sharpness depends entirely on subject texture. It walks outward from
  the peak rather than taking everything above threshold, so a second object can't stretch the range
  across a gap; a flat scan (<8 points of contrast) returns nothing rather than guessing; and a run
  reaching the window edge is flagged as a floor, not the whole subject. The scan always walks focus
  back to where it started, including on cancel — the cursor arithmetic depends on it.
- The panel's live view is its own `RangeLiveView` observing `LiveViewFeed` directly, so frames
  don't re-render the whole sheet several times a second.

Covered by `Tests/CanonTetherTests/FocusRangeTests.swift` and the harness (105 checks total).

### The command lock is the cost of a focus nudge, not the camera (2026-09-11)
Measured on the wire: one `set-config manualfocusdrive` completes in **21 ms**. But consecutive
nudges landed **1.1 s apart**, and the log says why — `command lock: capture-preview waited 1.0s`
against every command. One-lock-per-nudge made each one queue behind a full tether listening window.
This is exactly the batching problem `fetchSettings` already documents, and focus drive simply
hadn't been given the same treatment. `nudgeFocus` now takes the lock **once for the whole rack**
(5 steps: ~5.5 s → ~2 s; 10 steps: ~11 s → ~2.8 s), and pays the settle only at the end — settling
matters before something *reads* the result, not between two nudges going the same way.

The same bug broke auto-find in a way that looked like a bad algorithm. The scan read
`liveView.image` after each nudge — but the feed's next frame was still queued behind that same
lock, so **every sample scored a frame captured before the lens moved**, producing a focus curve
offset from reality. `GPhotoSession.scanFocus` now runs the entire sweep under one lock acquisition,
captures its own preview *immediately after* each nudge inside that lock (`fetchPreviewLocked`), and
pauses the live-view loop so it isn't competing for the lock it depends on. A stale frame is now
structurally impossible rather than merely unlikely.

### Focus distance: lens-dependent, and this lens doesn't have it (2026-09-11)
Canon records `FocusDistanceUpper`/`FocusDistanceLower` in MakerNotes ShotInfo (indices 19/20, cm).
Parsed straight out of a real bracket's CR2s: **both are 0 in every frame** with an EF 85mm f/1.8
USM, which has no distance encoder (a 1992 design predating E-TTL II distance reporting). The parse
was validated by checking ShotInfo's ISO and aperture against the standard Exif tags in the same
file, so the zeros are real, not misalignment.

So focus distance cannot be the basis of ranging: it is a **per-lens** capability, and even where a
lens supplies it the value is post-capture EXIF, coarse, and a near/far bracket rather than a
position. Counted nudges (`FocusRange`) stay the primary mechanism. `GPhotoSession.logConfigList`
dumps the body's whole config tree to the log on first capability probe, flagging any
focus/distance/lens path, so the "is anything available live over PTP?" question can be answered
from evidence — running a second `gphoto2` to check is not an option while the app holds the camera.

### CONFIRMED: focus drive works; the shutter's autofocus was undoing it (2026-09-11)
Settled by measurement on the camera (`Test Drive` in the panel → `diagnoseFocusDrive`), scoring
live-view sharpness after racking 20 coarse steps each way:

    start                     score 79
    after 10 toward camera    score 79   (pixel delta 0.003 — noise)
    after 20 toward camera    score 79
    back at start (20 away)   score 11   (pixel delta 0.071)
    after 10 away             score 11
    swing 68 → the lens is moving

So `manualfocusdrive` was working the whole time. Two separate things made it look broken:

1. **`capture-image-and-download` autofocuses first.** When AF fails (focus racked off the subject)
   the shot is refused — "Canon EOS Auto-Focus failed, could not capture". When it *succeeds* it is
   worse and silent: it pulls focus back onto the subject, cancelling the nudge, so every frame of
   the bracket lands at the same focus. Brackets now fire via `eosremoterelease` instead, which
   releases the shutter without AF (`captureWithoutAutofocusOnce`), collecting the frame with an
   explicit `wait-event-and-download` in the same lock.
2. **End stops are invisible.** In the run above the lens was already at its minimum focus distance,
   so 20 "Near" steps did nothing at all. The cursor in `FocusRange` counts nudges *sent*, not
   nudges that moved anything, so racking into a stop silently desynchronises it from the lens.
   Autofocus onto the subject before ranging so the lens sits mid-range.

Also calibrated here: 20 coarse (magnitude 3) steps take a subject from sharp to unrecognisable on
an EF 85/1.8, so coarse is far too big a step for a real stack — fine steps, 10–30 of them.

**Two measurement lessons.** The first version of this diagnostic drove only *away* from the camera,
which cannot distinguish "command ignored" from "already at that end stop". And it judged movement
by mean pixel difference, whose noise floor on live-view JPEGs (~0.007) is the same size as the
signal — it reported "MOVED, difference 0.0115" for frames that had not moved. Scoring *sharpness*
separates them by a factor of seven. When a metric's noise floor is the same order as the effect,
it produces confident wrong answers, which is worse than no answer.

### Bracket cycle time: 8.3 s → ~3 s per frame (2026-09-11)
First working bracket measured 8.3 s between frames. Where it went, and what each fix was worth:

- **~4 s: `wait-event-and-download 6s` ran its full six seconds** even though the RAW lands after
  about two — it collects events until the window expires, it does not return on the file. Now
  `waitForDownloadLocked` polls in 400 ms windows and returns the moment a filename appears. We
  already hold the lock, so the extra commands cost nothing.
- **~1.2 s: the inter-frame nudges were unbatched** — a lock acquisition *and* a full settle per
  nudge, three times a frame. They now go through `nudgeFocusInner` (one lock, one settle at the
  end): the lens only has to be still by the time the next frame is taken.
- **The return leg was the same mistake at bracket scale.** Walking back 21 steps at a lock and a
  settle each roughly doubled the duration of the whole bracket, for cleanup nobody watches. Also
  batched now.

**Bug the same log exposed: `Press Full AF` was being used to fire the shutter.** `releaseValues`
matched "press full" loosely against this body's list `["None", "Press Half AF", "Press Full AF",
"Press Half MF", "Press Full MF", "Release Half", "Release Full", "Release"]` and picked the
**autofocus** variant — reintroducing the exact behaviour this capture path exists to avoid. The MF
variants are now matched first and explicitly, and an AF fallback is logged as a warning. When a
choice list contains near-identical strings, match the distinguishing token, not a prefix.

First confirmed-good bracket (8 frames, fine steps, away from camera): sharpness 17.7 → 5.3 with the
sharp region migrating across the frame — a real focus rack, end to end.

### End stops are invisible and MUST be measured (2026-09-14)
The failure that kept producing identical brackets after auto-find. At an end of focus travel the
camera **still accepts and acknowledges every nudge**; nothing reports that the lens didn't move. So
a scan that walks 10 steps toward the camera, stalls against the near stop after 3, and then walks
10 back, ends up 7 steps *beyond* where it started — hard against the far stop. The bracket then
shoots a dozen frames there, all identical. Observed exactly this: auto-find, then a bracket whose
every frame measured sharpness 38.2–38.9 with the same peak tile (noise).

Both scan legs and interactive racking now **verify movement**: `previewSharpness` is compared
before and after every chunk of ~3 steps (`FocusMovement.moved`), and driving stops when sharpness
stops changing. Only steps that actually moved the lens are counted, so `FocusRange`'s cursor stays
tied to reality and the symmetric walk home lands where it started.

**The first attempt at this used pixel difference and was worthless** — it reported "stalled" in
both directions at once, which is physically impossible. Measured on real brackets: frames three
focus steps apart differ by 0.0048 in mean luma, frames where the lens never moved differ by
0.0039. The same number. Defocus is high-frequency, so any whole-frame average (or small thumbnail)
washes out exactly the signal being measured. Sharpness on the same frames: 6.5–20% change when
moving, ≤0.35% when static. `FocusMovement.minimumRelativeChange = 0.02` sits an order of magnitude
clear of both.

An unmeasurable reading reports **moved**, deliberately: a false stall mis-counts the range and
corrupts everything downstream, while a false "moved" merely keeps driving, and a static bracket is
caught by `FocusStackDiagnostics` at merge time.

**Never count a focus nudge as movement without evidence.** The camera's acknowledgement means the
command was received, nothing more.

`FocusStackDiagnostics.framesAreStatic` is sharpness-based too, for the same reason — it was
originally written on pixel difference, which cannot separate a real rack (0.0048) from a static
bracket (0.0039). Validated on both real brackets: the 15-frame static one reads 38.04→38.52 and is
flagged; the 8-frame rack reads 19.71→7.62 and is not.

### The live-view preview is too soft to measure focus on — scan magnified (2026-09-14)
The finding that explains why auto-find never worked. Instrumented sharpness through a real scan:

    start                0.719
    toward 0..3          0.711  (change 1.1%)
    toward 3..6          0.714  (change 0.4%)
    sweep offsets 0..4   0.715, 0.727, 0.743, 0.730, 0.719   ← a real peak at offset 2

The lens **was** moving and there **was** a focus curve — but at sharpness ~0.72, where the same
lens on an actual capture measures 17–38. Canon's fit-to-frame live view is small and heavily
processed, and defocus is a high-frequency effect, so there is almost nothing left to measure: a
real focus step moves the reading about 1%. Every threshold in this file drowns at that level, and
`FocusAnalyzer.evaluate` compresses it further (0.719 → score 19.4, 0.743 → 19.9), so
`FocusScanReader.minimumContrast` could never be met however long the sweep ran.

`scanFocusInner` now sets `eoszoom` to **5×** for the duration — a 1:1 crop of the centre, vastly
more high-frequency detail, and the same thing a photographer does by eye — restoring fit afterwards.
Stall detection is **gated on magnification succeeding**: unmagnified, every chunk looks flat and the
scan aborts before it starts, which is exactly what was observed (`stalled after 0 steps toward the
camera` immediately followed by `stalled at offset 1`, in the same scan — physically impossible and
the tell that the metric, not the lens, was the problem).

**Two readings that contradict each other are a broken metric, not a broken camera.** Both times
that has happened here (a "MOVED" verdict on unmoved frames; stalling in both directions at once) the
fault was measuring the wrong thing, and both times the fix was more signal rather than a tuned
threshold.

### Develop the scan OFFLINE against a recorded focus map (2026-09-14)
Tuning auto-find against the camera meant a full round trip per change — rebuild, relaunch, rack,
sweep, read the log — and the scan needed a dozen. The fix is a **focus map**: the panel's
"Record Map" button (`GPhotoSession.recordFocusMap`) walks the lens across its travel capturing one
live-view frame per step into `Focus Map <stamp>/step_<offset>.jpg`. A simulator then replays any
strategy against those real frames in a second. Build the map once per setup; iterate freely.

Two things the simulator found immediately, that months of camera round trips had not:

- **`maxClimb = 36` was stopping the climb 15–30 steps short of the peak** whenever it started from
  the far side. Raised to 110 — it is a runaway guard, not a design limit.
- **`FocusScanReader` returned a span of ZERO on a realistic subject.** It walked outward from the
  peak and stopped at the first below-threshold sample, and a real subject is several surfaces at
  different depths whose curve dips between them. Rewritten to take the above-threshold *run*
  containing the peak, tolerating dips of up to `gapTolerance = 4`, with `thresholdFraction`
  lowered 0.6 → 0.25.

**Synthetic test data must model depth of field.** The first generator placed discrete planes with
no DOF, so each was sharp at exactly one focus offset and the curve was a row of spikes — nothing a
lens produces. It made a correct algorithm look broken. Real subjects occupy a span of focus
positions and stay acceptably sharp for a few steps either side.

### Where a stack's wall-clock time actually goes (2026-09-14)
Timed end to end on a real 5-frame run, then attacked in order of size:

- **3.4 s per frame is a live-view preview, and it has to stay.** Taking a still **drops live
  view**, and focus drive does nothing without it, so something must restore it between frames.
  `set-config /main/actions/viewfinder=1` was tried, to avoid shipping a JPEG nobody looks at — it
  worked briefly and then **poisoned live view**: `capture-preview` started returning
  `*** Error (-1: 'Unspecified error')`, the feed hit its three-error limit, shut down and would not
  restart, because the camera and gphoto2 end up disagreeing about whether live view is running.
  Reverted to pulling a preview and discarding it. Do not reintroduce `viewfinder` without a way to
  prove the feed recovers afterwards. The bracket does still pass `verify: false`, skipping the
  measure-and-compare (end-of-travel is caught by the static-frame check at merge, for free).
- **0.6 s per frame was waiting for that frame's download** before focus could move. It doesn't have
  to be serial: the camera buffers. The bracket now fires every shot back to back and
  `drainDownloadsLocked` collects them afterwards, overlapping transfer with the next focus move.
- **The merge was 59 s single-threaded.** Strips are independent by construction — that is what the
  overlap is for — so they now run through `DispatchQueue.concurrentPerform`. 59 s → 22.7 s on 8
  cores, byte-identical output. Each worker reopens its own `ScratchPlane` handle: `readWarpedBand`
  seeks, so a shared handle across threads interleaves reads and returns scrambled rows.
- **`nudgeFocus` was not covering the walk to the near mark**, which happens in the model before the
  bracket — so that leg still fought the tether watch (`wait-event-and-download 1s waited 6.4s`).
  Now wrapped in `withTetherPaused` too.

### Position the lens by LOOKING, not by counting (2026-09-15)
The failure that made every other number a lie. Focus position was tracked by counting nudges sent —
open-loop — and a nudge the camera accepts at an end of travel moves nothing, so the count runs ahead
of the lens permanently. Proven by matching a bracket's frames back against its own sweep: the
bracket had been told to shoot **−48…44** and actually shot **+105…+11**. The subject was never
photographed, while the range, the coverage percentage and every log line looked correct.

The sweep already photographs the whole range, so its frames are labelled pictures of each offset.
`GPhotoSession.seekToOffset` compares a live preview against them (cosine similarity of tile
sharpness), reads off where the lens actually is, drives the error out, and looks again. Correlation
against the right frame measured 0.99 on real data, and survives 15% tile noise in the harness.

**Every measurement in this feature was correct and expressed in coordinates that had drifted.** No
amount of improving the depth map, the clustering or the thresholds could have fixed it — and
several rounds were spent doing exactly that. When results are wrong but every intermediate number
looks right, suspect the coordinate system, not the arithmetic.

### The sweep must measure the SAME FRAME the photographer drew on (2026-09-15)
The subject box is drawn on the fit-to-frame live view; the sweep was magnifying to 5× before
sampling. Those normalised box coordinates are meaningless against a centre crop, so the depth map
was measuring a different part of the scene than the box described — which is why ranges kept coming
back too narrow with the ends of the subject soft, through several rounds of threshold tuning that
could never have fixed it. Spotted by the photographer noticing the preview was punched in
mid-sweep, not by any of the measurements here.

Magnification was introduced when the measurement was *whole-frame* sharpness on a soft preview and
needed the signal. Per-tile analysis does not: each tile is read on its own terms. Both `scanFocus`
and `recordFocusMap` now hold the camera at 1× — the recorder especially, since a map is only useful
for replaying the real thing if it sees what the real thing sees.

**When a subsystem is given a region of interest, every stage must agree on the coordinate space.**

### Stop the sweep on TILES, not on aggregate sharpness (2026-09-15)
A sweep ended after 27 samples with `9 tiles pinned at the edge — subject may extend beyond it`,
giving a 12-step range for a subject that plainly ran further; the merged stack had its far end soft.
Two mistakes compounded:

- **The stop criterion was aggregate sharpness over the centre of the frame.** That is dominated by
  whatever is brightest and most textured, so it peaked and fell while individual tiles were still
  sharpening. A part of the scene still coming into focus is a part not yet measured. The sweep now
  also tracks how many tiles reach a new best each sample and will not stop while more than
  `scanImprovingTileFloor` are still improving.
- **The extension loop was gated on the sweep not having stopped early** — so a premature stop
  disabled the very check meant to catch it. It now runs regardless, and extends when tiles are
  still sharpening as well as when the aggregate peak sits at an edge.

**Whole-frame sharpness is the wrong measure whenever the scene has depth.** It misled the *diagnosis*
too: a bracket measured 19.6–19.8 across every frame and looked static, while a per-tile check showed
different tiles peaking in frames 2, 4, 7, 8 and 10 — focus had moved fine. Measure per tile.

### The bracket must WAIT for live view between frames (2026-09-15)
A stack came back as eleven identical exposures — sharpness 19.586–19.666 across the whole bracket —
while the log showed every focus nudge being sent and acknowledged. Taking a still drops live view;
`armLiveViewLocked` pulled **one** preview to bring it back and ignored failure. Right after a shot
the camera is busy writing and refuses `capture-preview`, so live view stayed down, and focus drive
does nothing without it. The bracket nudged between every frame and the lens never moved.

It now retries (up to `liveViewArmAttempts`) until a frame actually returns, and **fails the bracket
loudly** if it cannot — stepping a lens that cannot move only produces a stack that looks fine until
it is measured.

**This also reverses the fire-everything-then-drain optimisation.** Firing back to back keeps the
camera writing continuously, which is exactly the state in which it refuses the previews focus drive
depends on. Each frame is now collected before the next focus move. It was faster on paper and
produced identical frames in practice; a bracket of identical frames is not a saving.

### Stopping live view is not the same as ending it (2026-09-15)
Cancelling the preview loop only stops *this side* asking for frames. The camera stays in live-view
mode — mirror up, optical viewfinder blacked out — and libgphoto2's Canon driver engages the body's
**UI lock** on entering live view, so its buttons are dead as well. Neither is undone by cancelling
a loop, which is why the camera kept feeling "partially held" after live view was quit, with the
viewfinder and shutter unusable.

`releaseCameraToPhotographer` sets `viewfinder=0`, then `uilock=0`, then cancels autofocus — in that
order — and runs when the preview loop stops, when the focus-stacking panel closes, and after every
bracket. Closing the panel releases the camera **before** the busy check, since a merge is CPU work
on this side and has no claim on the body.

Note this is the same `viewfinder` config that poisoned live view when used to *enter* it
repeatedly mid-bracket. Using it once to *leave* is the documented counterpart and is a different
thing; entering is still done with `capture-preview`.

### NEVER leave anything held on the camera (2026-09-15)
`set-config /main/actions/autofocusdrive=1` engages autofocus and **holds** it — there is a matching
`/main/actions/cancelautofocus` for exactly that reason. Firing it without the cancel left the body
driving AF indefinitely: unresponsive to the app *and* to its own buttons, recoverable only by
killing the session. The same class of mistake as leaving the shutter half-pressed, which killed the
PTP link earlier the same day.

Focus is now taken with a **shutter half-press** (`Press Half AF` → `Release Half`), which is what a
photographer does and which unambiguously ends itself, followed by `cancelautofocus` regardless.
`releaseCameraControls` (release → `None`, then cancel autofocus) runs when the focus-stacking panel
closes, and a `cancelautofocus` runs after every bracket however it ended.

**Any camera action that can be *held* needs its release wired in before it is ever called.** A
held state is invisible from the app — it looks like a camera that has stopped responding, and the
photographer has no way to tell it apart from a crash.

### The UI was discarding frames the camera was sending (2026-09-15)
The real cause of "live view doesn't come back", after several wrong diagnoses. The session was
streaming — **2,550 frames at 20 ms** — while the panel sat on "Waiting for live view…". The frame
consumer filtered on the view model's own flag:

    guard self.isLiveViewOn else { continue }
    self.liveViewFeed.update(image)

and `restartLiveView` raised that flag *before* stopping the session. Stopping publishes "live view
inactive", whose observer sets the flag back to **false** — so every frame that followed was thrown
away by the app itself.

Two changes. The flag is now raised **after** the restart completes. And the consumer treats an
arriving frame as proof rather than filtering on intent: the flag is a *request*, frames are the
*fact*, so any future desync self-heals instead of silently blanking the feed.

**Frames arriving must never *set* the "live view is on" flag.** Tried as a self-healing measure,
it backfired at the one moment that matters: decoding is asynchronous, so a frame already in flight
lands after a stop and switches the flag back on — leaving the app showing LIVE over a stale frame
with nothing running. Fix desync at its source instead.

**A symptom that survives several plausible fixes is usually being diagnosed at the wrong layer.**
This was chased through the camera (refusing previews), the session (loop stopping itself), the
scheduler (merge starving the decode) and a stale flag — all real problems worth fixing, none of
them *this* one, which was in the last thirty lines of the pipeline.

### Ask what is running; do not trust a flag (2026-09-14)
After a bracket the feed was left dead with the panel showing "Waiting for live view…" even though
recovery had reported success. It *had* succeeded — live view restarted, then the loop died partway
through the merge, and the post-merge retry was gated on a `liveViewRestored` flag recorded a minute
earlier, so nothing looked again. `GPhotoSession.liveViewIsRunning` reports whether the loop actually
exists, and the end of the merge — the moment the photographer expects to shoot again — checks that
rather than the flag.

The merge also runs at `.utility` on `activeProcessorCount - 2` workers. Saturating every core at
`.userInitiated` starved the live-view decode, freezing the feed for the whole merge: frames were
arriving and none were being drawn, which is indistinguishable from a dead feed and was reported as
one twice.

### The sweep does not walk home; the bracket runs in whichever direction is nearer (2026-09-14)
The scan used to finish by walking all the way back to where it started, after which the bracket
walked out again to the near mark — roughly **90 steps of travel for nothing**, on top of a sweep
that had just covered the same ground.

`scanFocus` now leaves focus where the sweep ended and reports it. `FocusRangePlanner.startEnd`
picks whichever end of the marked range focus is already nearest, and the plan steps in whatever
direction that implies — so a sweep that ends at the far end simply shoots backwards. A stack is
order-agnostic: the merge aligns each frame to its neighbour, and neighbours are neighbours either
way round.

### The sweep hunts; being off-centre must not break it (2026-09-14)
The window is centred on wherever focus happens to start, so a subject at some other depth simply
fell outside it — three consecutive real runs produced a range starting exactly at the sweep's first
sample, and the stacks that followed left those surfaces soft. Assuming the photographer has already
focused nearby is not acceptable: any subject at any depth has to work.

After the initial window the sweep checks where its best reading sits. Still climbing at the far
end → keep going that way. Best reading is the *first* sample → the subject is nearer than the
sweep began, so go back past the start and carry on inward. Bracketed on both sides → stop. Bounded
by `scanMaxExtraSteps`, in `scanExtensionSteps` increments; the cost of an awkward starting point is
time, never failure.

There is also an **Autofocus button** in the panel now. The scan still autofocuses itself, but being
able to place focus deliberately — and see the result in live view before committing to a sweep — is
worth having when the subject is not what the camera would pick.

### The sweep stops when the subject falls away (2026-09-14)
Replaying eight recorded sweeps, most could have stopped between a quarter and half way through —
three recent ones after **12 of 46 samples**. Everything past the point where the subject has peaked
and is falling is time spent learning nothing. The sweep now tracks aggregate sharpness over the
middle of the frame and stops once it has sat below 70% of its peak for three consecutive samples,
never before `scanMinimumSamples` so a dip on the way *into* focus cannot end it early.

The window is also **symmetric** now (45 steps either side of where autofocus leaves the lens).
It used to reach 35 nearer and 55 further, and three consecutive real runs produced a range starting
exactly at the sweep's first sample — the subject carried on past where the scan looked.

### The panel takes the camera exclusively while it is open (2026-09-14)
Reported as "live view still didn't restart" after a bracket. It *had* restarted — frames were
flowing — but at roughly **one frame every 2.3 s**, because the tether watch resumed and every
`capture-preview` queued behind its listening window (`capture-preview waited 1.0s`, on every
frame). A feed that slow is indistinguishable from a dead one.

`beginExclusiveSession`/`endExclusiveSession` suspend the tether watch for as long as the focus
stacking window is open, not merely for the bracket. Nothing is lost: the panel drives the shutter
itself, so there are no body-shutter frames for the watcher to catch. `FocusStackModel` guards the
pair with `isInBracketingMode`, because SwiftUI can call `onAppear` more than once and an unbalanced
depth would leave the watcher suspended permanently.

**When a feature "doesn't work", check its rate before its existence.** Two separate reports in this
session were a working thing running too slowly to look like it was working.

### The shutter must be RELEASED, not just un-pressed (2026-09-14)
`Press Full MF` → `Release Full` looks like a complete shot and is not: on Canon, `Release Full`
only takes the button from fully-pressed back to **half**-pressed. Every frame of a bracket was
therefore leaving the shutter logically half-down, with metering and the camera's busy state still
engaged. Thirteen frames of that ended in `live view: stopping — camera link down` — the PTP session
itself died and the camera had to be reconnected by hand.

`GPhotoSession.releaseSequence` now emits `Press Full MF → Release Full → Release Half`, and there
is a `interFramePause` (350 ms) between shots: firing as fast as the link allows is a burst as far
as the body is concerned, and this one does not survive it. The choice logic is `static` and pure so
it is covered by the lib harness against the body's real list, including the fallbacks.

**The camera refuses previews for a long time after a burst of stills.** Measured: more than 12
seconds after a 13-frame bracket, with every frame successfully drained — so it is not a full
buffer. Every *fixed* pause tried here was a guess that proved too short and left the feed dead.
`waitForLiveViewReady` polls for a real frame (up to 30 attempts, 1.5 s apart) and runs **outside**
the bracket, after the merge has been kicked off, so the photographer never waits on it to see
their result.

**Force the restart only where it is needed.** Making every "ensure live view is on" a forced
stop-then-start turned repeat `onAppear` calls into a feed that thrashed and never settled
(`starting → stopped → starting`, one good burst, then down again). `onRestartLiveView` is the
forced path and is used *only* after a bracket; everywhere else the idempotent `onSetLiveView`
is correct.

**Live view must be *set*, not toggled, after a bracket.** The session stops it internally, so
`CameraViewModel.isLiveViewOn` is stale exactly when the restart matters, and a toggle that believes
it is already on does nothing — leaving the panel dark and focus drive dead for the next stack.

### Frame count comes from MEASURED depth of field (2026-09-14)
Shooting every focus step was massive over-coverage. One frame stays acceptably sharp over a
measurable number of steps, and `FocusDepthMap.depthOfFieldSteps` reads it straight off the same
sweep: the per-tile sharp width at 80% of that tile's peak, taken at the **lower quartile** (spacing
has to satisfy the narrowest part of the subject; a broad, low-detail tile would otherwise licence a
spacing that leaves the crisp parts with gaps). Spacing is three-quarters of that, so neighbouring
frames overlap rather than merely abut.

Measured on a real subject: depth of field 5–6 steps over an 18-step span → **7 frames instead of
19**, still 100% tile coverage. `FocusOverlap.tightestThatFits` remains only as a fallback for when
too few tiles can be measured.

### Sweep every OTHER step (2026-09-14)
Replaying a real sweep at decreasing sample rates: every 2nd step returns the **identical** range
(−11…7) from half the frames; every 3rd drifts 1 step; every 5th, 2 steps. The depth map only needs
the *shape* of each tile's focus curve, and the range gets a margin either side regardless. So
`GPhotoSession.scanStride = 2` — the driving is cheap, the preview is what costs, so sampling
halves the sweep for nothing given up.

Per-frame bracket cost also cut: one preview per *frame* rather than one per three steps (the
preview exists only to keep live view alive), settle 0.4 → 0.25 s, and the download poll window
400 → 200 ms. Together with the tether watch being paused, a stack of this subject went from ~113 s
to roughly 50 s.

### The panel is one button (2026-09-14)
Stripped to a large live view, a box drawn around the subject, and **Scan & Shoot Stack**. Removed:
rack buttons, Mark Near/Far, step size, frame count, overlap, settle, magnification. Every one of
those was a knob exposed because the app could not yet work the answer out — and each was a way to
get a stack wrong. What is left is the one thing only the photographer knows: which object in the
frame is the subject.

The bracket settles itself: span from the depth map, direction always away from the camera, spacing
from `FocusOverlap.tightestThatFits` (the finest that stays inside the frame cap — the only reason
not to shoot every step). Diagnostics (Record Focus Map, Test Focus Drive) moved behind an `⋯` menu;
they are needed when something is wrong and are noise the rest of the time.

**Live view is restarted after every bracket.** It is stopped for the bracket because the preview
loop costs ~3 s per frame in lock contention, and the panel is unusable without it — worse, focus
drive does not work at all when live view is down, so a second bracket would silently shoot N
identical frames.

Settle dropped 0.4 s → 0.25 s: the original figure was set when every step also queued behind the
tether watch for the command lock, which hid the real settling cost.

### Auto-find measures a DEPTH MAP, not a sharpness curve (2026-09-14)
The rewrite that finally made auto-find work, and the reason every earlier attempt could not.

**No single sharpness curve can answer the question a stack asks.** Measured on a real 91-frame
focus map of a real subject:
- A **whole-frame** curve (`FocusAnalyzer`, sharpest tile anywhere) never falls off — racking
  through a deep scene always leaves *something* sharp, so it had no near edge at all across the
  entire sweep, and the range covered the whole scene.
- A **single-region** curve gives a clean peak, but its width is the lens's **depth of field**, not
  the subject's depth. Restricting to the centre also moved the peak from −17 to +9, revealing the
  whole-frame measure had been tracking background, not the subject.

**Grid resolution matters, and finer is not automatically better.** With a box drawn around a
cylindrical subject, a 12×12 grid put only three tile-columns across it — too coarse to separate the
barrel's curved edges from the background behind, so the range stopped at the front face and the
sides merged soft. At 24×24 the subject's shape appears (centre columns −9, edge columns +5) and the
range covers it: span 18 against 14. But at 24×24 *without* a box the whole scene's depths risk
merging into one continuum, which is why the border exclusion scales with the grid and why the drawn
box is what makes the fine grid safe.

`FocusDepthMap` instead records **where every tile of the frame comes into focus**. Each tile looks
at scene at its own distance, so its peak offset *is* that part's focus position, and the spread of
those positions across the subject is exactly the range a bracket must cover. On the real map this
produced a legible picture — centre tiles peaking at −5…−21 with the flanking columns at +17…+38: a
curved object, nearest in the middle, receding at the sides.

Validated against that map: the range it picks (−14…+40, 54 steps) covers **90%** of the subject's
tiles, where the ranges the old curve-based scan produced covered **18–27%**. That number is the
whole "it didn't capture enough depth" complaint, quantified.

Border tiles are excluded rather than weighted (one distant corner coming into focus would stretch
a stack across the entire scene), and the range is percentile-trimmed then padded — a spare frame
costs a second, a gap cannot be recovered.

The scan now simply sweeps the travel (the same traversal `recordFocusMap` makes) and analyses. The
climb-to-peak and envelope-walk machinery is gone: three rounds of tuning could not rescue an
approach built on the wrong measurement.

### Superseded: the sweep walks the subject's falloff (2026-09-14)
Every real run reported `clipped: true`, meaning the subject ran past where the scan looked. A fixed
±radius window has to be guessed, and the guess is wrong whenever the subject is deeper than it or
the peak lands off-centre. Replayed against a focus map, a fixed ±20 window found the right range
from **5 of 9** starting positions; walking outward from the peak until sharpness has clearly fallen
off (`envelopeTailSteps` consecutive readings below threshold) found it from **all 9**, landing on
the identical range each time. There is no window left to be wrong.

### Auto-find: climb to the peak, tolerate noise, don't trust one reading (2026-09-14)
The scan no longer sweeps a fixed ±10 window around wherever focus happens to sit — that only works
if focus is already near the subject, and in a real run the sharpest point was at the very edge of
the window and still rising, so the sweep never contained the peak. It now **climbs** to the peak
(up to `maxClimb` steps, reversing once if it started on the far side), returns to the *best reading
seen*, backs off `radius`, and sweeps across it.

Three calibrations, all measured rather than guessed:

- **`climbNoiseMargin = 0.05`.** Adjacent readings on a real subject bounce 3–4% while the trend is
  under 1% per step. Treating any decrease as the peak stopped the climb ten steps early on a 1.8%
  dip (`4.250 → 4.172`) and put the whole sweep in the wrong place. The climb tracks the best value
  seen and needs a sustained fall clear of that band to stop.
- **End-of-travel compares against a reading 4 stops back, never the adjacent one.** At the peak the
  focus curve is stationary *by definition*, so adjacent steps differ ~1% and look exactly like a
  stopped lens — observed truncating a sweep to four samples right where the subject was sharpest.
- **The scan scores raw sharpness ×10, not the 0–100 badge score.** That score is compressed by
  `halfScoreRatio` to read as a confidence, which destroys the resolution a scan needs: a full sweep
  spanning sharpness 3.0–4.3 maps to 50–59, barely clearing `minimumContrast` of 8.

`clippedAtEdge` earns its keep: the run that exposed the climb bug reported `near -22, far -17,
peak -21, clipped true` — correctly saying the subject ran past where it looked rather than
presenting a truncated range as complete.

### The tether watch must be paused during a bracket (2026-09-14)
Measured on a working manual bracket: 7.8 s per frame, with `command lock: wait-event-and-download
50ms waited 6.6s` against every step. The tether watch is **pure contention** during a bracket — the
bracket fires the shutter and downloads each frame itself, so the watcher can only compete for the
command lock it needs. `withTetherPaused` (a depth counter checked at the top of `tetherTick`, same
shape as `liveViewPauseDepth`) wraps the bracket. A camera-shutter frame fired mid-bracket is not
downloaded by the watcher, which is correct: the bracket is driving the shutter.

### A single nudge cannot be judged (2026-09-14)
`rack: focus stalled after 0 of 1 steps` — the ±1 racking control, the one used for fine marking,
reported end-of-travel on essentially every press. Near the peak one step changes sharpness ~1%,
below any threshold that isn't noise. `nudgeFocusVerified` now carries its stall baseline **across
calls** (reset when direction reverses, since driving off a stop moves immediately) and needs
`minimumStepsToJudgeStall = 4` steps in one direction with no change before calling it. Steps that
produced nothing are subtracted from the reported movement, so the cursor stays tied to the lens.

Third instance of the same error shape: a threshold validated in one regime (multi-step chunks)
applied in another (single steps). Check the regime before reusing a calibration.

### Focus drive needs live view RUNNING — previews, not just live-view mode (2026-09-14)
The free-running preview loop costs ~3 s per bracket frame (measured: frames 4.2 s apart with the
loop running, 1.2 s after it errored out), so it is paused for the bracket. But pausing it *outright*
broke focus drive: with nothing fetching previews the body drops out of live view, after which
`manualfocusdrive` is accepted and acknowledged and moves nothing. Shipped exactly that and got a
15-frame bracket measuring 38.0–38.6 with the sharp region in one tile — while auto-find, which
previews at every step, had racked the same lens minutes earlier.

The bracket now steps with `nudgeFocusVerified`: **one preview per step**, which keeps live view
alive for ~170 ms instead of the loop's ~3 s, and reports how far the lens actually moved so a
bracket running into the end of travel stops and says so rather than shooting the rest at one focus.
Walking to the near mark is verified for the same reason.

`diagnoseFocusDrive` looked like counter-evidence (it racks fine with the loop paused) but is not —
it takes a preview between every drive, which is exactly what keeps live view up.

### Restoring camera settings must be retried and verified (2026-09-14)
`set-config imageformat` back to RAW after a bracket failed with `0x2019 PTP Device Busy` — the body
was still writing the last frame — and the single best-effort attempt gave up silently, **leaving
the camera on JPEG**. Exactly the surprise the restore exists to prevent. `restoreImageFormat` now
retries five times with a growing delay, **reads the value back** to confirm (the failing write
errored *and* left the old value, so only a read proves anything), and surfaces a status-bar warning
if it still can't. Any future "set it back afterwards" needs the same treatment.

### Brackets shoot JPEG (2026-09-11)
`GPhotoSession.withJPEGCapture` switches `/main/imgsettings/imageformat` to JPEG for the duration of
a bracket and restores the previous format as it unwinds — depth-counted and restored from a
detached task, so a cancelled or failed bracket still puts the body back. Leaving a photographer
silently on JPEG after a stack would be an expensive surprise on their next real shot. Ordinary
single shots are untouched; this is scoped to the bracket only. Toggle in the panel
("Shoot as JPEG"), on by default, persisted separately from the plan.

Why: a stack is a dozen-plus frames, the RAW download is ~2 s of the ~3 s per-frame cycle, and the
merge is clamped to sRGB by ImageIO's decode regardless — so RAW costs real time per frame and buys
the merged result almost nothing.

**Choice matching must be defensive here.** libgphoto2 only partly decodes this body's format list:
`["L", "0xff", "RAW", "RAW + 0x50", "RAW + 0x60", "RAW + 0x20", "mRAW", …]` — `L` is Large JPEG and
several entries are bare hex codes with no name. `GPhotoSession.jpegChoice` takes a named JPEG entry
where a build offers one, else a bare size letter, and **never** guesses at a hex code or picks
anything containing "raw". Covered in the lib harness against the real list.

### Superseded: focus stacking does NOT require the body in manual focus (2026-09-11)
**This section's theory was wrong — kept only so it isn't re-derived.** It claimed
`manualfocusdrive` is **accepted and acknowledged
while the body is in an AF mode, and the lens does not move** — no error, no refusal, nothing to
notice. It only drives the motor when the body's own `focusmode` is Manual, which is exactly what
EOS Utility does for its near/far focus buttons.

The same setting causes a second, louder failure: in an AF mode every `capture-image-and-download`
autofocuses first, which fails outright once focus has been deliberately racked off the subject
("Canon EOS Auto-Focus failed, could not capture") — and when it *succeeds* it is worse, because it
refocuses and silently destroys the position the bracket just stepped to.

In fact the drive works fine in One Shot, and on this body `focusmode` offers only
`["One Shot", "AI Servo"]` — there is **no Manual choice to switch to**, so the wrapper below is a
no-op on a 1DX II and was never the fix. It is harmless and left in place for bodies that do offer
it. `GPhotoSession.withManualFocus` wraps every focus operation (`nudgeFocus`, `scanFocus`,
`captureFocusStack`), switching `focusmode` to Manual once and restoring the previous mode as it
unwinds — depth-counted, so a bracket's inner racks don't thrash it. The restore runs on a detached
task so a *cancelled* bracket still puts the camera back; leaving the body in manual afterwards
would break ordinary shooting with no clue why.

**Diagnostic trap worth remembering.** The first read of this was wrong: `focusmode` reporting
Manual was taken as "the lens switch is on MF, we can't drive", and the app blocked on the very
state stacking needs. The two are distinguished by **`readOnly`** — with the lens switch on AF the
body lets `focusmode` be changed; with the switch on MF it is stuck reporting Manual. Only
read-only-and-Manual means the barrel switch (`FocusDriveCapability.lensSwitchInManualFocus`). The
evidence that settled it was the log line `focus mode: One Shot`, which falsified the MF theory
outright — always read the state before theorising about it.

The config dump (`logConfigList`) also turned up `/main/actions/eoszoom`, Canon's 5×/10× live-view
punch-in. Focus genuinely cannot be judged on a fit-to-window preview, so the panel exposes it.

### "The merge doesn't look stacked" is usually a bracket that never racked (2026-09-11)
Measured on a real 8-frame bracket shot with the body in One Shot: every frame scored **84**, the
sharpest region sat in the **same tile** (0.46, 0.21) in all eight, and consecutive frames differed
by **0.33%** — sensor noise. The lens had not moved at all, so the merge was blending eight copies
of one photograph. The output looks like a broken merge; the merge was fine.

`FocusStackDiagnostics.framesAreStatic` now checks this on the previews before any expensive work,
and `Render.framesAreStatic` drives a prominent warning in the panel. Validated against that exact
bracket (flags it) and against frames with genuine focus change (doesn't).

**Before debugging any focus-stacking symptom, check which build is actually running.** This whole
episode was a stale process: the app had been started at 13:59:58 and the binary carrying the fix
was written at 14:10:40, so the manual-focus change had never executed once — `grep -c "switched to
.* for focus stacking"` returned 0. The existing note about comparing `ps -o lstart` against the
binary's mtime applies to every fix here, not just reconnect work.

### The focus panel is a window, not a sheet (2026-09-11)
It shipped as a `.sheet` and that was the wrong container: sheets can't be resized and are sized by
their content, so it sat as a small panel in front of a large main window — useless for the one job
it has, looking closely at focus. It is now `FocusStackWindowController`, the same plain-AppKit shape
as `ReviewWindowController`, opening at 1180×820 and freely resizable. Layout is two columns: live
view + magnification + rack controls on the left with the room, settings on the right at a fixed
360 pt. Rack buttons are ±1/5/10/25 with large hit targets — racking a real range one nudge at a
time is dozens of clicks.

The magnification picker uses `.fixedSize()` and **never** an explicit width: a segmented control
framed below its intrinsic size is the SIGILL trap documented above.

### Tests
`Tests/CanonTetherTests/FocusStackTests.swift` (CI runs it; `swift test` still segfaults locally).
Two `swiftc` harnesses proved it out during the build: 54 checks on the pure maths (pyramid
roundtrip exactness at odd sizes, complementary-blur fusion, coverage attribution, alignment
recovery of known transforms, bad-link isolation), and an end-to-end one that writes real PNGs,
renders them and reads the TIFF back to check per-band sharpness, strip seams and coverage.

### Frame count: three margins stacked on one measurement (2026-09-15)

Brackets were shooting ~25 frames where 19 covered the subject. None of it was in the merge — the
folder held exactly as many JPEGs as the merge reported, and `FocusStackRenderer` throws rather than
skipping a frame, so nothing was ever captured-and-discarded. The waste was frames that *were*
merged and contributed nothing.

- **The padding was applied twice.** `FocusDepthMap.subjectRange` adds its own `margin: 2` at each
  end, and `FocusStackModel` then added a **full** depth of field on top — 7 steps past the
  outermost measured tile on each side. A subject clustered at −41…39 became a −48…46 bracket, and
  the two nearest frames of the resulting ladder won **zero** subject tiles. Now padded once, by
  **half** a depth of field, which is the geometrically correct amount: the last frame is centred on
  the padded end and reaches half its depth of field either side, so half is exactly what brings the
  outermost tile inside it. Measured: 24 frames / 3 dead → 22 / 1.
- **Spacing was 85% of a figure already discounted twice.** `depthOfFieldSteps` takes the *lower
  quartile* of per-tile sharp width (spacing satisfies the narrowest-peaked part of the subject, not
  the typical one) and measures that width at 80% of each tile's peak, not where it visibly softens.
  A further 15% haircut was a third margin on two. Now 95% → 23 frames became 19 on a real subject,
  with the output confirmed good. The original 75% dates from open-loop positioning, when a frame
  could land somewhere other than intended; `seekToOffset` removed that risk.

`auto-find` now logs how many planned frames sit where no subject tile does, and
`FocusDepthMap.depthOfFieldSpread` reports the lower-quartile/median/upper spread behind the frame
count — so "too many frames" is a measurement rather than an argument.

**A deep subject is allowed to need a lot of frames.** Plotting the tile depths of the subject that
prompted this showed them running *continuously* from −41 to +39 — genuinely 80 focus steps deep, no
gap, background correctly excluded. At that point the frame count is honest arithmetic and the only
way down is giving up depth. Check the depth distribution before assuming a large bracket is a bug.

### End of travel and a defocused plateau look identical (2026-09-15)

The sweep gained an end-of-travel check — stop when consecutive previews stop changing — and it
aborted real sweeps **four samples in**, reporting a textured subject as having 0 usable tiles. Two
distinct causes, both worth keeping in mind:

1. The sweep *opens* by driving into the near stop, so its first frames are identical **by design**.
   Fixed by requiring movement to have been seen first (`hasMoved`).
2. That was not enough. A **defocused** subject also barely changes between two focus steps — a short
   run of near-identical frames is simply what the blurred end of a sweep looks like. Three samples
   sat well inside that plateau.

So end of travel now needs `scanEndOfTravelSamples = 8` consecutive unchanged frames **and** a sweep
that has already collected its `scanMinimumSamples`. Both, because either alone has a false positive.
The case the check exists for (the lens stopping around +46 while the sweep drove on to +147, fifty
samples spent re-photographing one frame) is still caught, a few samples later.

**Same shape as the pixel-difference failures above:** a threshold calibrated on one regime (frames
far apart in focus) applied to another (frames a couple of steps apart at the blurred end).

### The coverage score falls as the stack gets better (2026-09-15)

Two brackets of the same subject, minutes apart, one variable changed:

| spacing | frames | "coverage" | measured sharpness |
|---|---|---|---|
| 5 | 20 | 67% | baseline |
| 4 | 24 | 68% | **+14.7% median tile sharpness**, better in 180 of 263 tiles |

`CoverageMap.confidence` is *the winning frame's share of the total sharpness at a cell*. Add frames
and more of them are nearly sharp anywhere, so every winner's share shrinks — the number is a
function of frame count as much as of quality, and it rated a visibly and measurably better stack as
no better. It also told the photographer that **33% of an excellent stack "was never sharp"**,
advising more frames, which was the very thing they had asked to stop doing.

No threshold fixes this. **A single merge cannot know whether a denser bracket would have been
sharper**, because the sharpest frame it holds is the only evidence it has. That question is
answerable by shooting two brackets and comparing them — an A/B, which is how the table above was
produced — and not otherwise. So `FocusStackCritique` no longer judges coverage at all. It reports
only what one merge can establish: frames that contributed nothing, and a **range clipped at either
end**, which *is* visible in one merge because an end frame that keeps winning instead of handing
over to a neighbour means the subject ran past the bracket.

The number is still logged, labelled as the winner share it is, with the warning that it falls as
frames are added.

**Spacing stays at 75% of the measured depth of field.** It was briefly raised to 95% on the
argument that `depthOfFieldSteps` is already conservative (lower quartile, 80% sharpness threshold)
so the extra margin was a third one stacked on two. The A/B refutes it: 24 frames are measurably
sharper than 20 on the same subject. The margin is not redundant with the quartile — it is what
covers the tiles *below* the quartile. **Anything derived from a percentile needs headroom under
that percentile.**

Note the first diagnosis of the 67% was also wrong, and in an instructive way: the mechanism
proposed (spacing equal to the lower quartile leaves the narrower quartile of tiles with gaps)
predicted 25% uncovered against 33% observed, which looked like confirmation. Shooting the control
showed coverage unmoved at 68%. **A mechanism that predicts the observed number is not thereby
true** — the control is what tests it.

### Compare merges by measuring them, not by looking (2026-09-15)

The two stacks above are indistinguishable by eye at screen size; the difference is 14.7% in median
per-tile sharpness. A throwaway `swiftc` tool that loads two TIFFs, computes per-tile Laplacian
energy on a 24×24 grid inside the subject box and reports better/same/worse tile counts settles in
seconds what staring cannot settle at all. Tiles with almost no detail in either image are excluded
— they have no focus to get right and only dilute the comparison.

### Driving the app from outside to run a test (2026-09-15)

The app holds the only camera session, so a test cannot be run by launching a second `gphoto2`. It
*can* be driven through the accessibility API, which is how the runs above were made:

```
osascript -e 'tell application "System Events" to tell process "CanonTether" \
  to click button "Focus Stack" of group 6 of toolbar 1 of window "Canon Tether"'
osascript -e '… to get {position, size} of image 1 of window "Focus Stacking"'
screencapture -x -R <x>,<y>,<w>,<h> shot.png      # see what the camera sees
```

The subject box is a drag, which System Events cannot do — a few lines of `CGEvent` posting
`leftMouseDown` / interpolated `leftMouseDragged` / `leftMouseUp` does it (a single jump reads as a
click). `subjectRegion` is not persisted, so a relaunched app has no box and must be redrawn before
any comparison run, or the scan measures the whole scene and the runs are not comparable.

A rebuilt binary still requires the photographer to quit and relaunch the app.

### The merge is the biggest phase, and it was 87% one loop (2026-09-15)

Timed end to end, the merge had quietly become *larger than the bracket* — 5.6s per frame against
the bracket's 3.7 — and CLAUDE.md's "59s → 22.7s on 8 cores" was long out of date. Instrumenting its
phases on a real 24-frame stack (replayed offline through `FocusStackRenderer` in a `swiftc`
harness, no camera needed):

    align 16.1s | decode 12.6s | strips 199.3s | write 0.7s   = 228.7s

So the strips were **87%** of it, and parallelising the decode — the obvious-looking target — would
have bought 5%. Three changes, in order of what they were worth:

- **`StackPyramid.convolve` split clamped borders from an unclamped interior.** It tested
  `min(max(…))` per tap, per channel, per pixel — two branches in the innermost loop of the entire
  merge — when only the first and last `radius` columns can fall outside. Strips 199s → 78s.
- **`stripRows` 512 → 1024.** Every strip also processes `stripOverlap` rows either side and throws
  them away: 512 rows of result cost 896 rows of work (1.75×), 1024 cost 1408 (1.375×). Strips
  80s → 59s for 2% more peak memory.
- **Preview and full-resolution decode run in parallel** (decode capped at 4 — it is bound by
  ImageIO and the disk, not arithmetic). Decode 12.6s → 4.7s.

**229s → 85s, with byte-identical output.** The accumulation order in `convolve` was deliberately
left alone so the result stays bit-for-bit the same, which is what makes that claim checkable: the
merged TIFF has the same SHA-256 after every one of these changes. Keep that property — it is the
only cheap way to refactor this code safely. `FocusStackTests.testConvolveMatchesTheNaiveImplementation`
pins it against a reference implementation, including sizes narrower than the kernel where the
interior is empty and every column is a border.

### The merge's memory scales with the bracket, and nothing was watching it (2026-09-15)

Measured peak RSS on the same 24-frame stack: **22.6 GB, on a 32 GB machine.** Each strip worker
holds *every frame's* band at once plus the pyramid built from it, so the footprint scales with
frame count — and frame count is chosen by the subject, not by the machine. The same stack on a
16 GB Mac would have swapped itself to a standstill or been killed, and nothing in the code noticed
how much it was asking for.

Workers are now bounded by memory as well as by cores: half of physical memory as the budget,
divided by an estimate of per-worker bytes (`frames × bandRows × width × 3 × 4 × 2.4`), never below
one — finishing slowly beats refusing to finish. On this machine that is 3 workers instead of 4,
costing ~6s and bounding the peak.

**A benchmark that only reports wall time hides this entirely.** `/usr/bin/time -l` and its
`maximum resident set size` is what turned a pure speed win into a portability fix.

### The sweep must judge the SUBJECT, not the frame (2026-09-15)

Measured on a real run: the sweep travelled **190 steps taking 96 samples**, for a subject that
occupied **80 steps and 40 of them**. 59% of a 46-second sweep was spent looking past where it
needed to.

The extension loop keeps going while tiles are still reaching new bests — but that was counted over
the **whole frame**, while the depth map that follows honours the drawn box. So as focus racked past
the subject, the *background* came into focus, the sweep read it as "the subject is still
sharpening", and extended: out to +145 for a subject that ended at +46. `FocusSweepMonitor` now
takes the `Region` and judges both the aggregate and the improving-tile count inside it, using
`Region.contains` so the two cannot drift apart.

**Fourth instance of the same error shape** (see the 5× magnification note above): a subsystem given
a region of interest, with one stage still working on the whole frame. When something is measured
against a box, check *every* stage that reads pixels.

### "Merging 1 of 4" is not four frames (2026-09-15)

The merge progress counted **strips** — horizontal bands the image is divided into for memory —
directly beneath a status line counting frames. Raising `stripRows` 512 → 1024 halved the strip
count, so a 21-frame stack reported "Merging 1 of 4" and read as though 17 frames had been thrown
away. It now reports a percentage. Strip count is an implementation detail of memory management and
must never appear next to a frame count.

### The download was never slow — the app waited after it (2026-09-15)

`drainDownloadsLocked` was asked for *every frame still outstanding* (21, then 20, …). One shutter
release produces one file, so that request could never be satisfied: having collected the frame, the
loop kept polling `wait-event-and-download 600ms` until three empty rounds proved nothing more was
coming. **1.8s of dead waiting on every frame of every bracket.**

The tell was already in the per-frame timings, and is worth remembering as a diagnostic shape:

    frame 20 took 3.74s (shutter 0.21, download 2.47, focus 1.05)
    frame 21 took 1.06s (shutter 0.37, download 0.69)

Identical file, identical link, 1.8s apart — exactly 3 × 600ms — because on the last frame the
remaining count happened to be 1. **When one iteration of a loop is much faster than the rest, the
difference is the loop's own bookkeeping, not the work.**

It now asks for one frame per shot. The earlier note warning that "exactly one" caused count drift
still holds and is still handled: the drain keeps *every* filename it sees, so a wait returning two
loses neither, and the end-of-bracket sweep-up catches anything that missed its window.

Measured on a real 21-frame bracket: **3.9s → 1.85s per frame** (download 2.47 → 0.61), the bracket
82s → 38s.

### "Still sharpening" must be a share of the subject, not a count (2026-09-15)

Giving the sweep the subject box was necessary and not sufficient — it still ran 190 steps and 96
samples for a subject occupying 80. Replaying the recorded sweep offline showed why: the
improving-tile count inside a 306-tile box decays from 306 to about 14 by the point the subject
ends, then **flickers between 3 and 11 for the remaining travel**, as individual tiles beat their own
previous best by the 5% margin on noise alone. A fixed floor of 3 is cleared by that flicker at
almost every sample, so the sweep never stopped.

`improvingTileFraction = 0.03` — 3% of the judged tiles — sits above the flicker and below the real
signal. Replayed against three recorded sweeps of the same subject it stops at +47/+51/+49, just past
the subject's far end of +46, using **~48 samples instead of 96** and 93 steps instead of 190, with
no depth given up.

**A threshold on a count breaks when the population size changes.** The floor of 3 was set when the
sweep judged the middle of the frame; a photographer-drawn box can hold twice as many tiles, and the
same number then means something entirely different.

### Replaying a sweep offline needs only two files (2026-09-15)

`GPhotoSession.previewTileSharpness` is `static` and depends on nothing but `ImageThumbnail`, so a
recorded `Focus Scan` folder can be pushed through the *real* `FocusSweepMonitor` in a `swiftc`
harness — extract the function, add `FocusDepthMap` and the monitor, and a sweep replays in seconds.
Both sweep calibrations above were settled that way, against three real recordings, without a camera.

### Seeing *through* a subject: the mesh basket (2026-09-15)

A wire pen cup stacked as its front wires only — mesh sharp, pens inside soft. Six plausible fixes
were tried and rejected against real recorded sweeps before the actual mechanism turned up:

| attempt | why it failed |
|---|---|
| multi-peak at 0.55 share | 20/138 tiles, peaks scattered −1…+103, no coherent surface |
| finer grid (36/48) | fixes cup, inflates the mask 74 → 102 steps; grid 64 merges everything into one cluster |
| radial distance from box centre | contents and wall both sit at median 0.81 — no separation |
| widen past nearest cluster, dropping sweep-edge groups | fixes cup, takes the mask to +117 (50 frames) |
| enclosure by the front silhouette (primary peaks) | 0% of the cup's deeper tiles are enclosed |
| shooting wider by default | 50 frames on an opaque subject |

**The contents are not a separate group of tiles — they are a second peak inside the subject's own
tiles.** A mesh's hard edges carry far more Laplacian energy than anything behind them, so every tile
covering both peaks on the mesh. Measured on the raw curve over the cup's interior: a single peak at
−11 decaying monotonically, no bump at +20/+40/+60 at any grid. Yet the sweep frames themselves show
the pens **sharp at +29**, where the out-of-focus mesh blurs to near-invisibility — the subject was
photographable all along and the measurement could not represent it.

`FocusDepthMap.depthBehind` therefore asks a different question: among the tiles of the *front
surface*, how many show a prominent second peak further back? That is also what separates contents
from background — background is seen **around** an outline, in its own tiles, one peak each;
contents are seen **through** it, in tiles that belong to the subject. Prominence is measured against
the valley between the candidate and the global peak, so a shoulder does not count, and a tenth of
the surface must agree, so a glimpse through a gap does not either.

Validated on four real sweeps:

    mesh cup  -21…+3  (9 frames)  ->  -21…+67  (30 frames)
    mesh cup  -43…+3 (16 frames)  ->  -43…+21  (22 frames)
    mask      -31…+43 (25 frames) ->  unchanged
    mask      -31…+41 (25 frames) ->  unchanged

**The lesson worth keeping: when a measurement cannot see something, check whether the thing is
visible in the raw frames before rebuilding the measurement.** Five of the six failed attempts were
rules layered on a signal that was not there; the crop that showed the pens sharp at +29 took a
minute and pointed straight at the mechanism.

Also: the extension is bounded by how far the sweep looked. The second cup run swept only to +25, so
its range stops at +21 — correct given the evidence, but short. The sweep's own stop rule and this
rule want reconciling.

Note `Tests/CanonTetherTests/FocusDepthMapTests.swift` had been committed **empty** and now holds the
see-through and clustering cases.

### The sweep has to still be running when the contents come into focus (2026-09-15)

`depthBehind` was shipped and the next real run still missed the cup's pens — because the sweep
stopped at **+9** and the pens come sharp at **+29**. The detection was starved of data: it looks for
second peaks beyond the front surface, and the recording contained nothing past it.

The cause is the stop rule counting only tiles that set a **new best**. A second surface behind a
mesh never beats the mesh's own peak, so by that measure nothing is improving the moment the wires
go soft. The monitor now also counts tiles climbing back out of their own trough
(`risingAgainProminence = 0.10`, matching the prominence `depthBehind` requires), and keeps sweeping
while enough of them are.

**`risingAgainFraction` is 0.15, five times `improvingTileFraction`.** "Above my own trough" is a far
weaker statement than "better than I have ever been", and noise clears it constantly — measured
across the whole travel, an opaque mask runs 5–7% of tiles rising again (peaking at 11% just past
focus) while the mesh cup runs 16–24%. The first threshold tried, reusing the 3% floor, never stopped
any sweep at all.

Replayed: the mask still stops at +49 after 48 of 96 samples, so the sweep halving is kept; the cup
keeps running through the depth where its pens live.

**Two rules that have to agree.** `FocusSweepMonitor` decides how far to look and
`FocusDepthMap.depthBehind` decides what was found; shipping only the second left it correct and
useless. When a feature spans a measurement and a decision made from it, check the measurement is
still collecting where the decision needs to look.

## Next steps
- Confirm how the "other Mac" (where this was reopened) currently connects to the camera — USB or Ethernet — since that determines whether to resume the Ethernet investigation or go straight to USB + libgphoto2.
- If USB: install `libgphoto2`/`gphoto2` via Homebrew, confirm `gphoto2 --auto-detect` sees the camera, then start building the app (SwiftUI native app was the agreed shape; scope included tethered capture, live view, camera settings control, and post-capture preview — build capture first, layer in the rest).
