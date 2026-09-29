import Foundation
import CanonTetherCore
import AppKit

/// UI-facing state for the capture screen. Wraps `GPhotoSession` (an actor) so SwiftUI only
/// ever touches `@Published` properties on the main actor.
@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "Not connected"
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var settings: [CameraSetting] = []
    @Published private(set) var isConnected = false
    @Published private(set) var captureCount = 0
    /// Every reviewable capture in the download folder, oldest first — the session gallery the
    /// client review window browses. Seeded from disk at launch, appended to as new shots arrive.
    @Published private(set) var captures: [URL] = []
    /// Frames live on their own observable object, deliberately *not* on this one. Publishing them
    /// here invalidated every view that observes the view model — the toolbar, inspector,
    /// filmstrip and the client review window — eight times a second, which re-ran the
    /// filmstrip's "good shots only" filter over the whole session on every frame. Only the
    /// preview canvas observes the feed, so only the preview canvas redraws.
    let liveViewFeed = LiveViewFeed()
    /// Whether live view is running. Changes rarely, so it stays here where the toolbar can see it.
    @Published private(set) var isLiveViewOn = false

    /// False if the gphoto2 CLI isn't installed — the UI shows setup instructions instead of
    /// silently sitting on "waiting for camera".
    let gphotoInstalled = GPhotoSession.isInstalled

    // Internal rather than private: `FocusStackModel` drives brackets over the same session, so
    // a bracket shares the one shell (and one command lock) with everything else. A second session
    // would mean a second gphoto2 claiming the camera — which on this body can cost a re-pair.
    let session = GPhotoSession()

    /// Focus stacking runs on its own observable object (see `FocusStackModel`) but is owned here,
    /// so it shares this view model's session and outlives the sheet that presents it — a bracket
    /// keeps shooting if the photographer closes and reopens the panel.
    private(set) lazy var focusStack: FocusStackModel = {
        let model = FocusStackModel(session: session, liveView: liveViewFeed)
        model.onStackMerged = { [weak self] url in self?.registerMergedStack(url) }
        // Ranging drives focus, which is a live-view operation, and the photographer has to see
        // what they're marking — so it routes through the same toggle the toolbar uses rather than
        // starting live view behind the view model's back and desyncing the button.
        // Set, never toggle. The session stops live view itself around a bracket, so this object's
        // `isLiveViewOn` can be stale at exactly the moment the restart matters — and a toggle that
        // believes it is already on does nothing, leaving the panel dark and focus drive dead.
        model.onSetLiveView = { [weak self] on in self?.setLiveView(on) }
        model.onRestartLiveView = { [weak self] in self?.restartLiveView() }
        return model
    }()

    /// Drives the status indicator dot: red on error, green when the camera is live, amber while
    /// still working toward a connection.
    var statusColor: StatusColor {
        if errorMessage != nil { return .error }
        if isConnected { return .connected }
        return .connecting
    }

    enum StatusColor { case connected, connecting, error }

    /// The stop grid the camera's own exposure-increment custom function has it reporting on, shown
    /// as a readout in the inspector. Read from the live choice lists rather than stored, so it
    /// tracks the body the moment the photographer changes C.Fn I-1. Nil until settings arrive.
    var exposureGrid: ExposureGrid? { ExposureGrid.detect(in: settings) }

    init() {
        loadExistingCaptures()
        Task { [weak self] in
            guard let session = self?.session else { return }
            for await message in session.progressStream() {
                guard let self else { return }
                self.statusText = message
            }
        }
        // Every downloaded frame — app shutter or camera shutter — arrives here.
        Task { [weak self] in
            guard let session = self?.session else { return }
            for await url in session.captureStream() {
                guard let self else { return }
                self.handleNewCapture(url)
            }
        }
        // Live connection state, so the UI reflects the frequent wired-LAN drops/reconnects.
        Task { [weak self] in
            guard let session = self?.session else { return }
            for await connected in session.connectionStream() {
                guard let self else { return }
                self.isConnected = connected
            }
        }
        // Live view frames arrive as JPEG data and are decoded off the main actor — decoding every
        // frame on the main thread would stutter the whole UI at streaming rates.
        // The session is the single writer of live-view state, mirroring how connectionStream owns
        // isConnected. Without this, live view stopping itself (the camera stops supplying frames)
        // left the UI lit up over a frozen frame with no way back except guessing, and pinned the
        // settings poll to its exposure-only fast path for the rest of the session.
        Task { [weak self] in
            guard let session = self?.session else { return }
            for await active in session.liveViewActiveStream() where !active {
                guard let self else { return }
                self.isLiveViewOn = false
                self.liveViewFeed.clear()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await data in self.session.liveViewStream() {
                // `NSImage(data:)` only *wraps* the bytes — the actual JPEG decode is deferred to
                // draw time, i.e. onto the main thread, every frame. At streaming rates that
                // buries the main thread in decode work and the feed lags badly. Decoding through
                // ImageIO with `shouldCacheImmediately` forces the work to happen here, off the
                // main actor, so the main thread only ever blits an already-decoded bitmap.
                let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cg = CGImageSourceCreateImageAtIndex(source, 0, [
                              kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary)
                    else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }.value
                // Frames are dropped once live view is off, and must **not** switch it back on.
                //
                // An earlier version treated an arriving frame as proof the feed was live and
                // raised the flag. That is wrong at the one moment it matters: decoding is
                // asynchronous, so a frame already in flight lands *after* a stop and resurrects
                // the flag — leaving the app showing LIVE over a stale frame with nothing running.
                // The genuine desync this was guarding against is fixed at its source, in
                // `restartLiveView`, by raising the flag only once the restart has completed.
                guard self.isLiveViewOn else { continue }
                self.liveViewFeed.update(image)
            }
        }
        // Periodically re-read the camera's settings so the inspector tracks changes made on the
        // camera body (dials, mode switches). Skipped while a capture or in-app set is in flight.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Track the body closely while composing: turning a dial on the camera should
                // show up in the inspector (and be judged against the live view) more or less as
                // it happens, not up to four seconds later.
                let interval = self.isLiveViewOn ? Self.liveSettingsPoll : Self.idleSettingsPoll
                try? await Task.sleep(nanoseconds: interval)
                await self.refreshSettingsIfIdle()
            }
        }
    }

    private func refreshSettingsIfIdle() async {
        guard isConnected, !isBusy else { return }
        // While composing, read only the exposure triangle: polling every property at this rate
        // would cost live view frames for values that don't change mid-shot.
        let paths = isLiveViewOn ? GPhotoSession.exposurePaths : nil
        let generation = settingsGeneration
        guard let latest = try? await session.fetchSettings(paths: paths), !latest.isEmpty else { return }
        // A generation counter, not an `isBusy` re-check: a user's change can both start *and
        // finish* inside this fetch, leaving isBusy false again by the time we resume, and the
        // stale snapshot would then overwrite the value they just set — the exact bug the old
        // re-check was meant to prevent.
        guard settingsGeneration == generation else { return }
        // A partial read patches the settings it covers and leaves the rest alone; a full read
        // replaces outright. Equatable guards avoid churning the inspector (and closing an open
        // menu) when nothing actually changed.
        if paths == nil {
            if latest != settings { settings = latest }
        } else {
            let readPaths = Set(paths ?? [])
            let returned = Set(latest.map(\.path))
            var merged: [CameraSetting] = []
            for setting in settings {
                if let fresh = latest.first(where: { $0.path == setting.path }) {
                    merged.append(fresh)
                } else if readPaths.contains(setting.path) && !returned.contains(setting.path) {
                    // The camera was asked for this one and declined to report it — it isn't
                    // exposed in the body's current mode. Drop it, as a full read would: keeping
                    // it left the inspector offering a stale value (and a stale choice list) that
                    // the camera would now reject.
                    continue
                } else {
                    merged.append(setting)
                }
            }
            // Anything newly reported that we weren't already showing.
            merged.append(contentsOf: latest.filter { new in !settings.contains { $0.path == new.path } })
            if merged != settings { settings = merged }
        }
    }

    /// Settings poll cadence: brisk while live view is up so camera-side dial changes register
    /// against what's on screen, relaxed otherwise.
    private static let liveSettingsPoll: UInt64 = 1_200_000_000
    /// Brisk enough that turning a dial on the camera shows up in the inspector while the
    /// photographer is still looking at it. Affordable now that a whole settings read costs one
    /// lock acquisition rather than five.
    private static let idleSettingsPoll: UInt64 = 1_500_000_000
    /// Bumped whenever the photographer changes a setting, so an in-flight poll that started
    /// before the change discards its now-stale snapshot instead of publishing it.
    private var settingsGeneration: UInt64 = 0

    private func handleNewCapture(_ url: URL) {
        // A frame downloaded just before a project switch can arrive after the gallery was
        // repointed — dropping it keeps an old project's photo (and the client monitor) from
        // leaking into the new project's session. The file itself is safe in its own folder.
        guard url.deletingLastPathComponent() == CaptureLocation.directory else { return }
        captures.append(url)
        lastCaptureURL = url
        captureCount += 1
        statusText = "Captured \(url.lastPathComponent)"
    }

    /// Puts a freshly merged focus stack into the gallery. The bracket's own frames never appear —
    /// only this one file does, which is what makes a focus stack read as a single capture.
    private func registerMergedStack(_ url: URL) {
        // Same project check as `handleNewCapture`, one level deeper: the merged image lives inside
        // the bracket's subfolder, so it is the *folder* that must belong to the current project.
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent() == CaptureLocation.directory else { return }
        if let existing = captures.firstIndex(of: url) {
            // A re-merge writes the same path. Remove and re-append so SwiftUI sees a change and
            // views holding a cached thumbnail of the previous render reload it.
            captures.remove(at: existing)
            captures.append(url)
        } else {
            captures.append(url)
            captureCount += 1
        }
        lastCaptureURL = url
        statusText = "Merged focus stack \(url.lastPathComponent)"
    }

    // MARK: - Gallery actions

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Moves a capture to the Trash (recoverable) and drops it from the session gallery. The review
    /// model re-syncs off the resulting `captures` change, so selection/flags stay consistent.
    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            // Don't drop it from the gallery if it wasn't actually trashed (volume without a
            // .Trashes, permissions) — the photo would vanish from the UI while staying on disk.
            statusText = "Couldn't move \(url.lastPathComponent) to Trash"
            return
        }
        captures.removeAll { $0 == url }
        if lastCaptureURL == url {
            lastCaptureURL = captures.last
        }
        statusText = "Moved \(url.lastPathComponent) to Trash"
    }

    /// Copies the given picks into a chosen folder. Returns the number copied (0 if none/cancelled).
    @discardableResult
    func exportPicks(_ urls: [URL]) -> Int {
        guard !urls.isEmpty else {
            statusText = "No flagged photos to export"
            return 0
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to copy the \(urls.count) flagged photo(s) into"
        guard panel.runModal() == .OK, let destination = panel.url else { return 0 }

        var copied = 0
        for url in urls {
            var target = destination.appendingPathComponent(url.lastPathComponent)
            // Never delete what's already at the destination: the old remove-then-copy destroyed
            // any same-named file (unrecoverably — removed, not trashed), and exporting into the
            // capture folder itself made target == source, deleting the original pick outright.
            if target == url { continue }
            if FileManager.default.fileExists(atPath: target.path) {
                let base = url.deletingPathExtension().lastPathComponent
                target = destination.appendingPathComponent(
                    base + "-" + UUID().uuidString.prefix(4) + "." + url.pathExtension)
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
                copied += 1
            } catch {
                continue
            }
        }
        statusText = "Exported \(copied) photo(s)"
        return copied
    }

    /// Populates the gallery from any captures already on disk so the review window (and the main
    /// preview) have content the moment the app opens, before the first shot of this session.
    private func loadExistingCaptures() {
        let dir = CaptureLocation.directory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var images = urls.filter {
            CaptureLocation.imageExtensions.contains($0.pathExtension.lowercased())
                // A live-view frame stranded by a crash is not a shot; never list it as one.
                && !$0.lastPathComponent.hasPrefix(GPhotoSession.previewFilenamePrefix)
        }
        // Focus-stack folders contribute exactly one entry each: the merged image. The listing
        // above is non-recursive, so the bracket's source frames are already excluded by living a
        // level down — this reaches in for the one file that *is* a photograph. A folder with no
        // merged image yet (interrupted bracket) contributes nothing, which is correct.
        // "Focus Scan"/"Focus Map" folders hold diagnostic sweeps, not photographs; only stack
        // folders contribute a capture (their merged image).
        for url in urls where CaptureLocation.isStackFolder(url) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory, let merged = CaptureLocation.mergedImage(inStackFolder: url) else { continue }
            images.append(merged)
        }
        // Fetch each date once before sorting — stat-ing inside the comparator did O(n log n)
        // syscalls (10,000+ for a 1,000-file folder) on the main actor, a visible beachball on
        // every launch and project switch.
        let dated = images.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        captures = dated.sorted { $0.1 < $1.1 }.map(\.0)
        lastCaptureURL = captures.last
    }

    func connect() {
        run {
            try await self.session.connect()
            // isConnected is deliberately NOT set here: connectionStream is the single writer.
            // Setting it directly could overwrite a `false` the stream just delivered (the link
            // can drop in the window between connect() returning and this continuation resuming),
            // showing "connected" against a dead session.
            self.statusText = "Connected"
            self.settings = try await self.session.fetchSettings()
        }
    }

    /// The folder captures currently download to — the active project.
    var captureFolder: URL { CaptureLocation.directory }

    /// Switches to a different project folder at runtime. Repoints downloads there, clears the
    /// current gallery, and repopulates from whatever is already in the new folder — so a fresh
    /// folder opens an empty session, and returning to a folder brings its shots back. Their flags
    /// come with them: flags are stored as macOS Finder tags on the files themselves, so reloading
    /// the folder reloads the picks with no sidecar files to keep in sync. Relaunches the camera
    /// shell against the new folder if it was connected, so future shots land in the right place.
    func changeCaptureFolder(_ rawURL: URL) {
        let url = rawURL.resolvingSymlinksInPath()
        guard url != CaptureLocation.directory else { return }
        UserDefaults.standard.set(url.path, forKey: CaptureLocation.userDefaultsKey)

        // Clear synchronously so the gallery empties right away, even before (or if) the new folder
        // can be read. `loadExistingCaptures` then repopulates from disk — nothing for a new folder,
        // the existing shots for a folder revisited.
        captures = []
        lastCaptureURL = nil
        captureCount = 0
        errorMessage = nil
        statusText = "Switched to \(url.lastPathComponent)"
        loadExistingCaptures()

        // Deliberately NOT routed through `run`: its isBusy guard silently *discarded* the repoint
        // whenever a connect/capture was in flight — the gallery showed the new project while every
        // subsequent shot kept downloading into the old folder. The session actor serializes with
        // any in-flight command on its own, and the self-healing tether loop relaunches the shell
        // against the new folder within ~1s, so no reconnect choreography is needed here.
        Task {
            await self.session.setCaptureDirectory(url)
        }
    }

    /// Starts/stops the camera's live view feed. Not routed through `run`: live view is a
    /// long-running stream rather than a one-shot operation, and gating it behind `isBusy` would
    /// let a capture in flight swallow the toggle.
    func toggleLiveView() {
        setLiveView(!isLiveViewOn)
    }

    /// Starts live view whether or not this object thinks it is already running.
    ///
    /// Needed after a bracket: the session stops the feed itself (and the loop can stop *itself*
    /// after the camera refuses previews for a moment), so `isLiveViewOn` here can say "on" while
    /// nothing is running — and the ordinary guarded path would then do nothing at all, leaving the
    /// panel dark and focus drive dead for the next stack.
    func restartLiveView() {
        let previous = liveViewToggleTask
        liveViewToggleTask = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            await self.session.stopLiveView()
            await self.session.startLiveView()
            // The flag is raised **after** the restart, not before.
            //
            // Stopping makes the session publish "live view inactive", and the observer above sets
            // `isLiveViewOn = false` in response — so a flag raised beforehand was immediately
            // lowered again. The frame consumer then dropped every arriving frame
            // (`guard self.isLiveViewOn else { continue }`), which is why the session could be
            // streaming 2,500 frames while the panel sat on "Waiting for live view…".
            self.isLiveViewOn = true
        }
    }

    private func setLiveView(_ on: Bool) {
        guard on != isLiveViewOn else { return }
        isLiveViewOn = on
        if !on { liveViewFeed.clear() }
        // Chained onto the previous toggle rather than spawned independently: two unstructured
        // tasks have no ordering guarantee, so a quick off-then-on could arrive as on-then-off,
        // leaving the frame loop running forever with the button showing "off" and no way to
        // stop it.
        let previous = liveViewToggleTask
        liveViewToggleTask = Task { [session] in
            _ = await previous?.result
            if on { await session.startLiveView() } else { await session.stopLiveView() }
        }
    }

    private var liveViewToggleTask: Task<Void, Never>?

    // MARK: - HDR

    /// Spread for the next HDR bracket, remembered between shots. Plain `UserDefaults` rather than
    /// `@AppStorage`, which is a SwiftUI property wrapper and not available on a view model.
    static let hdrSpreadKey = "hdrSpread"
    @Published var hdrSpread: HDRPlan.Spread = HDRPlan.Spread(
        rawValue: UserDefaults.standard.object(forKey: CameraViewModel.hdrSpreadKey) as? Int ?? 2) ?? .twoStops {
        didSet { UserDefaults.standard.set(hdrSpread.rawValue, forKey: Self.hdrSpreadKey) }
    }

    /// Shoots an exposure bracket and merges it, publishing only the merged result.
    ///
    /// The merge runs off the main actor at `.utility`: it is several seconds of CPU on full-
    /// resolution RAW, and the same lesson as the focus-stack merge applies — saturating the
    /// machine at a higher priority starves the live-view decode and freezes the UI, which is
    /// indistinguishable from a hang.
    func captureHDR() {
        guard isConnected, !isBusy else { return }
        let plan = HDRPlan(spread: hdrSpread)
        isBusy = true
        statusText = "HDR — \(plan.summary(metered: nil))"
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let result = try await session.captureHDRBracket(plan: plan) { message in
                    Task { @MainActor [weak self] in self?.statusText = message }
                }
                await MainActor.run { self.statusText = "Merging \(result.frames.count) exposures…" }

                let output = result.folder.appendingPathComponent(
                    CaptureLocation.mergedFileName(inStackFolder: result.folder))
                let frames = result.frames
                let reference = result.referenceIndex
                let render = try await Task.detached(priority: .utility) {
                    try HDRRenderer.render(urls: frames, referenceIndex: reference, outputURL: output)
                }.value

                await MainActor.run {
                    self.registerMergedHDR(render.outputURL, recoveredStops: render.recoveredStops)
                }
            } catch is CancellationError {
                await MainActor.run { self.statusText = "HDR cancelled" }
            } catch {
                await MainActor.run { self.statusText = error.localizedDescription }
            }
        }
    }

    /// Publishes the merged HDR, and says what the bracket actually bought.
    ///
    /// Reporting the recovered stops matters: a bracket of a scene that fitted in one frame recovers
    /// nothing, and the photographer should learn that from the app rather than by comparing files.
    private func registerMergedHDR(_ url: URL, recoveredStops: Double) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent() == CaptureLocation.directory else { return }
        if let existing = captures.firstIndex(of: url) {
            captures.remove(at: existing)
            captures.append(url)
        } else {
            captures.append(url)
            captureCount += 1
        }
        lastCaptureURL = url
        statusText = recoveredStops >= 0.25
            ? String(format: "HDR merged — %.1f stops of highlight recovered", recoveredStops)
            : "HDR merged — the scene already fitted in one exposure"
    }

    func capture() {
        // Ignore shutter presses while the link is down — Space has no disabled state to
        // respect — so we don't leave the busy spinner hung waiting on a reconnect.
        guard isConnected else { return }
        // Taking the shot ends composing: drop out of live view so the viewer goes back to
        // whatever review mode is set (in Latest, that means the shot just taken appears the
        // moment it lands). Also hands the camera back to the capture, rather than having it
        // stream preview frames through the exposure.
        let wasLive = isLiveViewOn
        if wasLive {
            isLiveViewOn = false
            liveViewFeed.clear()
        }
        run {
            // Stopped *before* the shutter command in the same task, not fired off separately:
            // two independent tasks have no ordering guarantee, so the capture could otherwise
            // reach the camera while the preview loop was still pulling frames.
            if wasLive { await self.session.stopLiveView() }
            // Fire the shutter; the downloaded frame arrives asynchronously via the capture stream
            // (handleNewCapture), the same path camera-shutter shots take.
            try await self.session.capture()
        }
    }

    /// Applies a new value to one setting and patches the returned authoritative state back into
    /// place, leaving the other settings untouched.
    func updateSetting(_ setting: CameraSetting, to value: String) {
        // Logged end to end: a settings change had three separate ways to vanish silently (the
        // control disabled while busy, this equality guard, and `run`'s busy gate), which made
        // "I can't change the shutter speed" impossible to tell apart from "the camera refused".
        FileHandle.appendLog("UI: updateSetting \(setting.path) \(setting.current) -> \(value)")
        guard value != setting.current else {
            FileHandle.appendLog("UI: updateSetting ignored — value already \(value)")
            return
        }
        run {
            self.statusText = "Setting \(setting.label)…"
            if let updated = try await self.session.updateSetting(setting.path, to: value),
               let index = self.settings.firstIndex(where: { $0.id == updated.id }) {
                self.settings[index] = updated
                self.settingsGeneration &+= 1
                self.statusText = "\(updated.label): \(updated.current)"
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        // A dropped action used to vanish without a trace, so a shutter press that arrived while
        // something else was in flight simply did nothing and said nothing. Surface it.
        guard !isBusy else {
            FileHandle.appendLog("UI: action dropped — busy")
            statusText = "Camera is busy — try again in a moment"
            return
        }
        isBusy = true
        errorMessage = nil
        let token = UUID()
        busyToken = token
        // Watchdog. `isBusy` disables every camera control, so a single operation that never
        // returns — a capture starved behind another command, a reconnect waiting on a camera
        // that's gone — used to leave the whole inspector greyed out until the app was
        // relaunched, with no clue why. Nothing legitimate here runs this long: capture has its
        // own 60s ceiling and settings reads 15s.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.busyWatchdog)
            guard let self, self.busyToken == token, self.isBusy else { return }
            FileHandle.appendLog("UI: busy watchdog fired — releasing a stuck operation")
            self.statusText = "That took too long — the camera may need reconnecting"
            self.isBusy = false
        }
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            if busyToken == token { isBusy = false }
        }
    }

    private var busyToken = UUID()
    /// Longer than any legitimate operation (capture tops out at 60s, settings reads at 15s).
    private static let busyWatchdog: UInt64 = 90_000_000_000
}
