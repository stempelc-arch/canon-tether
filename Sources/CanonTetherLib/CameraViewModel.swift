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
    /// The current live-view frame, or nil when live view is off (or hasn't produced a frame yet).
    @Published private(set) var liveViewImage: NSImage?
    @Published private(set) var isLiveViewOn = false

    /// False if the gphoto2 CLI isn't installed — the UI shows setup instructions instead of
    /// silently sitting on "waiting for camera".
    let gphotoInstalled = GPhotoSession.isInstalled

    private let session = GPhotoSession()

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
            guard let self else { return }
            for await message in self.session.progressStream() {
                self.statusText = message
            }
        }
        // Every downloaded frame — app shutter or camera shutter — arrives here.
        Task { [weak self] in
            guard let self else { return }
            for await url in self.session.captureStream() {
                self.handleNewCapture(url)
            }
        }
        // Live connection state, so the UI reflects the frequent wired-LAN drops/reconnects.
        Task { [weak self] in
            guard let self else { return }
            for await connected in self.session.connectionStream() {
                self.isConnected = connected
            }
        }
        // Live view frames arrive as JPEG data and are decoded off the main actor — decoding every
        // frame on the main thread would stutter the whole UI at streaming rates.
        Task { [weak self] in
            guard let self else { return }
            for await data in self.session.liveViewStream() {
                let image = await Task.detached { NSImage(data: data) }.value
                guard self.isLiveViewOn else { continue }
                self.liveViewImage = image
            }
        }
        // Periodically re-read the camera's settings so the inspector tracks changes made on the
        // camera body (dials, mode switches). Skipped while a capture or in-app set is in flight.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                await self.refreshSettingsIfIdle()
            }
        }
    }

    private func refreshSettingsIfIdle() async {
        guard isConnected, !isBusy else { return }
        guard let latest = try? await session.fetchSettings(), !latest.isEmpty else { return }
        // Re-check after the await: a user-initiated change can start (and finish) while the fetch
        // was in flight, and applying the stale snapshot would snap the just-changed value back in
        // the inspector until the next poll.
        guard !isBusy else { return }
        // Equatable guard avoids churning the inspector (and closing open menus) when nothing changed.
        if latest != settings {
            settings = latest
        }
    }

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
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let images = urls.filter {
            CaptureLocation.imageExtensions.contains($0.pathExtension.lowercased())
                // A live-view frame stranded by a crash is not a shot; never list it as one.
                && !$0.lastPathComponent.hasPrefix(GPhotoSession.previewFilenamePrefix)
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
        isLiveViewOn.toggle()
        let on = isLiveViewOn
        if !on { liveViewImage = nil }
        Task { [session] in
            if on { await session.startLiveView() } else { await session.stopLiveView() }
        }
    }

    func capture() {
        // Ignore shutter presses while the link is down — Space has no disabled state to
        // respect — so we don't leave the busy spinner hung waiting on a reconnect.
        guard isConnected else { return }
        run {
            // Fire the shutter; the downloaded frame arrives asynchronously via the capture stream
            // (handleNewCapture), the same path camera-shutter shots take.
            try await self.session.capture()
        }
    }

    /// Applies a new value to one setting and patches the returned authoritative state back into
    /// place, leaving the other settings untouched.
    func updateSetting(_ setting: CameraSetting, to value: String) {
        guard value != setting.current else { return }
        run {
            self.statusText = "Setting \(setting.label)…"
            if let updated = try await self.session.updateSetting(setting.path, to: value),
               let index = self.settings.firstIndex(where: { $0.id == updated.id }) {
                self.settings[index] = updated
                self.statusText = "\(updated.label): \(updated.current)"
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
