import SwiftUI

/// What the client monitor is currently showing, chosen by the photographer in the main window.
enum ReviewMode: String, CaseIterable, Identifiable {
    case latest      // always the newest capture as it lands
    case selected    // one shot the photographer picked
    case slideshow   // rolling loop through flagged shots

    var id: String { rawValue }

    var label: String {
        switch self {
        case .latest: return "Latest"
        case .selected: return "Selected"
        case .slideshow: return "Slideshow"
        }
    }

    var symbol: String {
        switch self {
        case .latest: return "bolt.fill"
        case .selected: return "hand.point.up.left.fill"
        case .slideshow: return "play.rectangle.fill"
        }
    }
}

/// What the assistant's MAIN viewer shows, chosen independently of the client monitor.
enum MainViewerMode: String, CaseIterable, Identifiable {
    case latest   // follow the newest capture as it lands
    case held     // stay on the inspected shot so it can be studied/flagged

    var id: String { rawValue }
    var label: String { self == .latest ? "Latest" : "Hold" }
    var symbol: String { self == .latest ? "bolt.fill" : "hand.raised.fill" }
}

/// Shared state bridging the photographer's controls (main window) and the client monitor (review
/// window). Both observe this object, so changing the mode/selection here is reflected live on the
/// client's screen. Flags are persisted as native macOS Finder tags, so picks also show up (and can
/// be filtered) in Finder and survive app restarts.
@MainActor
final class ReviewModel: ObservableObject {
    /// The Finder tag used to mark a photo as a client pick. Visible in Finder's sidebar/columns.
    static let flagTag = "Flagged"

    static let slideshowIntervalKey = "slideshowInterval"

    @Published var mode: ReviewMode = .latest {
        didSet {
            // Switching the picker to "Selected" puts the shot the assistant is currently inspecting
            // on the client screen right away — otherwise the mode reads as a no-op until they
            // happen to use "Show on Client Monitor". `showOnClient` relies on setting the mode
            // *before* the pin so its explicit choice wins over this seed.
            if mode == .selected, let selectedURL { clientPinnedURL = selectedURL }
            restartSlideshow()
        }
    }
    /// The assistant's inspect cursor in the MAIN window — what "Hold" shows and what F flags.
    /// Deliberately independent of the client monitor's pinned photo (`clientPinnedURL`).
    @Published var selectedURL: URL?
    /// Whether the main viewer follows the newest capture ("Latest") or stays on `selectedURL`
    /// ("Hold") so the assistant can inspect/flag a shot while new frames keep coming in.
    @Published var mainViewerMode: MainViewerMode = .latest {
        didSet {
            // Toggling back to Latest should snap the cursor (and so the filmstrip, which follows
            // `selectedURL`) to the newest shot right away — otherwise it only catches up once the
            // next capture lands and `sync` runs.
            if mainViewerMode == .latest { selectedURL = lastKnownCaptures.last }
        }
    }
    /// What the client monitor shows in its "Selected" mode. While that mode is active it tracks the
    /// assistant's inspect cursor; in Latest/Slideshow the cursor moves freely without disturbing
    /// the client's screen.
    @Published var clientPinnedURL: URL?
    @Published private(set) var flagged: Set<URL> = []
    @Published var slideshowInterval: Double = (UserDefaults.standard.object(forKey: slideshowIntervalKey) as? Double) ?? 4 {
        didSet {
            UserDefaults.standard.set(slideshowInterval, forKey: Self.slideshowIntervalKey)
            if mode == .slideshow { restartSlideshow() }
        }
    }
    @Published private(set) var slideshowIndex = 0

    private var slideshowTask: Task<Void, Never>?
    private var lastKnownCaptures: [URL] = []

    /// The single image the CLIENT monitor should display right now, given the session's captures.
    func displayedURL(in captures: [URL]) -> URL? {
        switch mode {
        case .latest:
            return captures.last
        case .selected:
            return clientPinnedURL ?? captures.last
        case .slideshow:
            let ordered = flaggedOrdered(in: captures)
            guard !ordered.isEmpty else { return nil }
            return ordered[slideshowIndex % ordered.count]
        }
    }

    /// The image the MAIN viewer (assistant's window) should show: the newest capture in Latest
    /// mode, or the held/inspected shot in Hold mode.
    func mainViewerURL(in captures: [URL]) -> URL? {
        switch mainViewerMode {
        case .latest: return captures.last
        case .held: return selectedURL ?? captures.last
        }
    }

    func flaggedOrdered(in captures: [URL]) -> [URL] {
        captures.filter { flagged.contains($0) }.reversed()
    }

    func isFlagged(_ url: URL) -> Bool { flagged.contains(url) }

    /// Drops every pointer into the current project's photos, for a project (capture-folder) switch.
    /// Without this the client monitor's `clientPinnedURL` — which `displayedURL` falls back to —
    /// would keep showing a photo from the old folder after the gallery has cleared. Flags aren't
    /// restored here; the `sync` that follows the new folder's `captures` reloads them from the
    /// files' Finder tags.
    func resetForNewProject() {
        selectedURL = nil
        clientPinnedURL = nil
        flagged = []
        flagKnown = []
        slideshowIndex = 0
        lastKnownCaptures = []
        restartSlideshow()
    }

    /// Keeps flags and the inspect cursor in sync as new shots arrive. While following Latest, the
    /// cursor tracks the newest frame so F flags the shot currently on screen.
    func sync(with captures: [URL]) {
        lastKnownCaptures = captures
        loadFlags(from: captures)
        if selectedURL == nil || mainViewerMode == .latest {
            selectedURL = captures.last
        }
        if mode == .slideshow {
            restartSlideshow()
        }
    }

    /// The assistant taps/scrubs to a shot to inspect and flag it: holds the main viewer on it. In
    /// Latest/Slideshow this leaves the client monitor untouched; in "Selected" the client is
    /// following the cursor by definition, so it moves with them.
    func hold(_ url: URL?) {
        guard let url else { return }
        selectedURL = url
        mainViewerMode = .held
        if mode == .selected { clientPinnedURL = url }
    }

    /// Explicitly pushes a shot to the client monitor's "Selected" mode — the deliberate "show the
    /// client this one" action, which doesn't move the assistant's own inspect cursor.
    func showOnClient(_ url: URL?) {
        guard let url else { return }
        // Order matters: entering `.selected` seeds the pin from `selectedURL`, so pin afterwards.
        mode = .selected
        clientPinnedURL = url
    }

    func step(_ delta: Int, in captures: [URL]) {
        guard !captures.isEmpty else { return }
        let current = selectedURL.flatMap { captures.firstIndex(of: $0) } ?? captures.count - 1
        let next = min(max(current + delta, 0), captures.count - 1)
        hold(captures[next])
    }

    // MARK: - Finder tags

    /// Reads the "Flagged" Finder tag off each *newly seen* capture and merges it into `flagged`.
    /// `sync` only ever appends to the capture list within a project (a project switch clears
    /// `flagged`/`flagKnown` via `resetForNewProject` first), so this does O(1) filesystem reads per
    /// new capture rather than re-reading every shot in the session on every arrival.
    private var flagKnown: Set<URL> = []

    func loadFlags(from captures: [URL]) {
        for url in captures where !flagKnown.contains(url) {
            flagKnown.insert(url)
            if let tags = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames,
               tags.contains(Self.flagTag) {
                flagged.insert(url)
            }
        }
    }

    /// Toggles the "Flagged" Finder tag on a capture and mirrors it into the in-memory set.
    func toggleFlag(_ url: URL?) {
        guard let url else { return }
        var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        if flagged.contains(url) {
            tags.removeAll { $0 == Self.flagTag }
            flagged.remove(url)
        } else {
            if !tags.contains(Self.flagTag) { tags.append(Self.flagTag) }
            flagged.insert(url)
        }
        // `URLResourceValues.tagNames` is read-only; the writable path is NSURL's key-based setter.
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)

        if mode == .slideshow {
            restartSlideshow()
        }
    }

    // MARK: - Slideshow

    func restartSlideshow() {
        slideshowTask?.cancel()
        guard mode == .slideshow else { return }

        slideshowIndex = 0

        let interval = max(1, slideshowInterval)
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // Wrap against the *current* ordered count rather than letting the index grow
                // unbounded — otherwise this is a theoretical Int overflow after a very long
                // session, since only `% ordered.count` at display time was ever bounding it.
                let count = self.flaggedOrdered(in: self.lastKnownCaptures).count
                self.slideshowIndex = count > 0 ? (self.slideshowIndex + 1) % count : 0
            }
        }
    }
}
