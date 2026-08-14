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
        // Equatable guard avoids churning the inspector (and closing open menus) when nothing changed.
        if latest != settings {
            settings = latest
        }
    }

    private func handleNewCapture(_ url: URL) {
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
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
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

        let images = urls.filter { CaptureLocation.imageExtensions.contains($0.pathExtension.lowercased()) }
        captures = images.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate < rDate
        }
        lastCaptureURL = captures.last
    }

    func connect() {
        run {
            try await self.session.connect()
            self.isConnected = true
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
    func changeCaptureFolder(_ url: URL) {
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

        // Route through `run` so this can't race a concurrent capture/settings update — both
        // write `isConnected`/`settings`/`errorMessage`, and only `run` gates that with `isBusy`.
        run {
            let wasConnected = self.isConnected
            await self.session.setCaptureDirectory(url)
            // Proactively relaunch against the new working directory when we had a live session;
            // otherwise the normal connect flow (and the self-healing tether loop) will pick it up.
            guard wasConnected else { return }
            try await self.session.connect()
            self.isConnected = true
            self.settings = try await self.session.fetchSettings()
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
