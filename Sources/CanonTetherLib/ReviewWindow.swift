import SwiftUI
import AppKit
import ImageIO

/// Loads a downsized `NSImage` off the main thread. Uses `ImageIO`'s thumbnail path, which pulls
/// the embedded preview from RAW/CR2 files, so even 20 MB RAWs display near-instantly.
enum PreviewLoader {
    /// Decoded previews keyed by path+size. Capture files never change after import, so no
    /// invalidation is needed; NSCache evicts under memory pressure. Without this the filmstrip
    /// re-decoded RAW previews every time LazyHStack recycled a cell, and the client slideshow
    /// re-decoded the same flagged set at full hero size every interval, forever — constant disk
    /// and CPU burn across a multi-hour review.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 400_000_000 // ~400MB of decoded pixels, evicted under pressure
        return cache
    }()

    static func load(_ url: URL, maxPixel: Int) async -> NSImage? {
        // Size and modification date are part of the key, not just the path. Capture files don't
        // normally change, but a project folder re-shot into, or a camera whose file counter has
        // been reset, can reproduce a filename — and a path-only key would then serve the previous
        // photo indefinitely, which on a client monitor means showing the wrong person's picture.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)).map { attributes in
            let size = (attributes[.size] as? Int) ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)|\(Int(modified))"
        } ?? "nostat"
        let keyString = "\(url.path)|\(maxPixel)|\(stamp)"
        if let cached = cache.object(forKey: keyString as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil); return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil); return
                }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                // Actual decoded size, not an assumed 4 bytes per pixel: ImageIO hands back 16-bit
                // components for some RAW thumbnails, and undercounting by 2x let the cache hold
                // roughly double its limit before evicting anything.
                let bytes = cg.bytesPerRow * cg.height
                cache.setObject(image, forKey: keyString as NSString, cost: max(bytes, cg.width * cg.height * 4))
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - Client review window controller

/// Owns the separate, reusable AppKit window shown to the client. Kept as a plain controller (not a
/// SwiftUI scene) so it works on the macOS 12 deployment target and can be driven programmatically —
/// opened from a toolbar button and taken full-screen for presentation.
///
/// The client monitor is usually turned away from the operator, so there's no way to eyeball whether
/// it's actually showing anything: the toolbar button is the only feedback, and opening always targets
/// whichever screen the main window *isn't* on, full-screen, so there's nothing left to position by hand.
@MainActor
final class ReviewWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    private var window: NSWindow?

    /// Opens (full-screen, on the other monitor) if closed, or closes if already open — the toolbar
    /// button's only action, with `isPresented` driving its on/off appearance.
    func toggle(viewModel: CameraViewModel, reviewModel: ReviewModel) {
        if let window, window.isVisible {
            window.close()
            return
        }
        // `NSApp.mainWindow`/`keyWindow` are unreliable here — a toolbar button click doesn't
        // guarantee the main content window still holds either status. Find it by process of
        // elimination instead: the visible app window that isn't the review window itself.
        let mainScreen = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue != "clientReview" }?.screen
        let target = Self.targetScreen(avoiding: mainScreen)

        let win: NSWindow
        if let window {
            win = window
        } else {
            let root = ReviewView(viewModel: viewModel, reviewModel: reviewModel)
            win = NSWindow(contentViewController: NSHostingController(rootView: root))
            win.title = "Client Review"
            win.identifier = NSUserInterfaceItemIdentifier("clientReview")
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.backgroundColor = .black
            win.isReleasedWhenClosed = false // reuse across open/close
            win.delegate = self
            window = win
        }

        if let target {
            win.setFrame(target.frame, display: true)
        } else {
            win.setContentSize(NSSize(width: 1180, height: 760))
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        if !win.styleMask.contains(.fullScreen) {
            // A freshly created/ordered-front window ignores toggleFullScreen(nil) called in the same
            // run loop pass — it needs a beat after its initial display to actually enter fullscreen.
            DispatchQueue.main.async {
                win.toggleFullScreen(nil)
            }
        }
        isPresented = true
    }

    func windowWillClose(_ notification: Notification) {
        isPresented = false
    }

    /// The screen not hosting `mainScreen`, preferring a second display when one exists. Falls back to
    /// the only screen available (or `nil`, letting the caller center) on a single-monitor setup.
    private static func targetScreen(avoiding mainScreen: NSScreen?) -> NSScreen? {
        let screens = NSScreen.screens
        guard let mainScreen, screens.count > 1 else { return screens.first }
        return screens.first { $0 !== mainScreen } ?? screens.first
    }
}

// MARK: - Client review view (pure display, driven by ReviewModel)

struct ReviewView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var reviewModel: ReviewModel
    @State private var heroImage: NSImage?
    @State private var shownURL: URL?

    private var displayed: URL? { reviewModel.displayedURL(in: viewModel.captures) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let heroImage {
                Image(nsImage: heroImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(shownURL)
                    .transition(.opacity)
            } else {
                placeholder
            }

            statusOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.35), value: shownURL)
        .task(id: displayed) { await loadDisplayed() }
    }

    private func loadDisplayed() async {
        guard let displayed else {
            heroImage = nil
            shownURL = nil
            return
        }
        let image = await PreviewLoader.load(displayed, maxPixel: 2600)
        // Guard against a stale load landing after the target moved on (fast slideshow, new shot).
        guard displayed == reviewModel.displayedURL(in: viewModel.captures) else { return }
        heroImage = image
        shownURL = displayed
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: placeholderSymbol)
                .font(.system(size: 52, weight: .thin))
            Text(placeholderText)
                .font(.title3)
        }
        .foregroundStyle(.white.opacity(0.5))
    }

    private var placeholderSymbol: String {
        reviewModel.mode == .slideshow ? "flag.slash" : "photo.on.rectangle.angled"
    }

    private var placeholderText: String {
        if viewModel.captures.isEmpty { return "Photos will appear here as you shoot" }
        if reviewModel.mode == .slideshow { return "No flagged photos yet" }
        return "Waiting for a photo…"
    }

    /// A subtle, unobtrusive readout for the operator setting up the client screen — small enough
    /// not to distract the client.
    private var statusOverlay: some View {
        VStack {
            HStack {
                Label(modeCaption, systemImage: reviewModel.mode.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: Capsule())
                Spacer()
            }
            .padding(16)
            Spacer()
        }
        .opacity(0.9)
    }

    private var modeCaption: String {
        switch reviewModel.mode {
        case .latest:
            return "Latest"
        case .selected:
            return "Selected"
        case .slideshow:
            let n = reviewModel.flaggedOrdered(in: viewModel.captures).count
            guard n > 0 else { return "Slideshow" }
            return "Slideshow · \(reviewModel.slideshowIndex % n + 1) of \(n)"
        }
    }
}
