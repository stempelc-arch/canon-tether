import SwiftUI
import CanonTetherCore
import ImageIO
import AppKit

public struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @StateObject private var reviewModel = ReviewModel()
    @StateObject private var analysis = ShotAnalysisStore()
    @State private var keyMonitor: Any?
    @StateObject private var reviewWindow = ReviewWindowController()
    @StateObject private var sleepPreventer = SleepPreventer()
    @State private var showingPreferences = false
    /// When on, the filmstrip hides shots with Soft/Borderline focus or Over/Under exposure, showing
    /// only the good ones — a fast triage pass so the photographer's picks come from shots worth
    /// looking at.
    @State private var showingOnlyGood = false

    public init() {}

    public var body: some View {
        Group {
            if viewModel.gphotoInstalled {
                mainInterface
            } else {
                OnboardingView()
            }
        }
    }

    private var mainInterface: some View {
        VStack(spacing: 0) {
            HSplitView {
                captureColumn
                    .frame(minWidth: 600, maxWidth: .infinity)

                InspectorPanel(viewModel: viewModel, analysis: analysis,
                               previewURL: reviewModel.mainViewerURL(in: viewModel.captures))
                    // HSplitView settles at one end of this range rather than at `idealWidth`, and
                    // the inspector is the one that expands — so it comes to rest at its *maximum*
                    // and grows with the window, which is what keeps the vectorscope (square, so
                    // bounded by this width) big enough to read. Drag the divider to hand the width
                    // back to the photo; 344 is the narrowest the settings rows still fit whole at.
                    .frame(minWidth: 344, idealWidth: 480, maxWidth: 560)
            }

            Divider()

            SessionFilmstrip(viewModel: viewModel, reviewModel: reviewModel, analysis: analysis,
                              showingOnlyGood: showingOnlyGood)
        }
        .frame(minWidth: 960, minHeight: 700)
        .task { viewModel.connect() }
        .onAppear {
            installKeyMonitor()
            reviewModel.sync(with: viewModel.captures)
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: viewModel.captures) { newCaptures in
            reviewModel.sync(with: newCaptures)
        }
        .toolbar { presenterToolbar }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(viewModel: viewModel, reviewModel: reviewModel, analysis: analysis,
                            captureCount: viewModel.captures.count)
        }
    }

    @ToolbarContentBuilder
    private var presenterToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Client shows", selection: $reviewModel.mode) {
                ForEach(ReviewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose what the client monitor displays")
        }

        ToolbarItem {
            Menu {
                Picker("Interval", selection: $reviewModel.slideshowInterval) {
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("4 seconds").tag(4.0)
                    Text("6 seconds").tag(6.0)
                    Text("10 seconds").tag(10.0)
                }
            } label: {
                Label("Slideshow speed", systemImage: "timer")
            }
            .help("Slideshow interval")
        }

        ToolbarItem {
            Button {
                showingOnlyGood.toggle()
                if showingOnlyGood {
                    Task { await analysis.analyzeAll(viewModel.captures) }
                }
            } label: {
                Label("Show Good Shots Only", systemImage: showingOnlyGood ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(showingOnlyGood ? Color.green : Color.primary)
            }
            .help(showingOnlyGood
                  ? "Hiding soft-focus or bad-exposure shots — click to show everything"
                  : "Filter the filmstrip to sharp, well-exposed shots, to flag picks faster")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                reviewWindow.toggle(viewModel: viewModel, reviewModel: reviewModel)
            } label: {
                Label("Client Review", systemImage: "rectangle.on.rectangle.angled")
                    .foregroundStyle(reviewWindow.isPresented ? Color.green : Color.primary)
            }
            .help(reviewWindow.isPresented
                  ? "Client screen is on — click to turn it off (⌘R)"
                  : "Show the client screen, full-screen on the other monitor (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }

        ToolbarItem {
            CoffeeButton(isOn: sleepPreventer.isPreventingSleep) {
                sleepPreventer.toggle()
            }
            .help(sleepPreventer.isPreventingSleep
                  ? "Preventing sleep — click to allow the Mac to sleep again"
                  : "Keep the Mac awake during the session")
        }

        ToolbarItem {
            Button {
                showingPreferences = true
            } label: {
                Label("Preferences", systemImage: "gearshape")
            }
            .help("Preferences (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
        }

        ToolbarItem {
            Button {
                viewModel.exportPicks(reviewModel.flaggedOrdered(in: viewModel.captures))
            } label: {
                Label("Export Flagged", systemImage: "square.and.arrow.up")
            }
            .help("Copy the flagged picks to a folder")
            .disabled(reviewModel.flaggedOrdered(in: viewModel.captures).isEmpty)
        }
    }

    // MARK: - Capture column (preview + control bar)

    private var captureColumn: some View {
        let url = reviewModel.mainViewerURL(in: viewModel.captures)
        return VStack(spacing: 0) {
            if !viewModel.isConnected {
                ReconnectBanner(status: viewModel.statusText)
            }

            PreviewCanvas(url: url, isConnected: viewModel.isConnected)
                .overlay(alignment: .top) { mainViewerControl }

            Divider()

            MetaBar(url: url, errorMessage: viewModel.errorMessage)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: viewModel.isConnected)
    }

    /// Latest / Hold toggle for the assistant's own viewer — independent of what the client sees.
    /// "Hold" freezes the preview on the inspected shot so it can be studied and flagged while new
    /// frames keep arriving.
    private var mainViewerControl: some View {
        Picker("Main viewer", selection: $reviewModel.mainViewerMode) {
            ForEach(MainViewerMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 10)
        .help("Latest follows new shots; Hold stays on the selected shot so you can flag it")
    }

    // MARK: - Spacebar capture

    /// A local key-down monitor drives the shooting/reviewing shortcuts regardless of which control
    /// holds focus (a `Button` shortcut only works while the button is in the responder chain):
    /// Space captures, ←/→ scrub the selection cursor, and F flags the current pick. Returning `nil`
    /// swallows the event so macOS doesn't play the "no first responder" beep.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't hijack keys while the user is typing into a text field.
            if event.window?.firstResponder is NSTextView { return event }
            // Never fire shooting shortcuts from the client review window — a stray Space while
            // presenting shouldn't trip the shutter.
            if event.window?.identifier?.rawValue == "clientReview" { return event }
            switch event.keyCode {
            case 49: // space
                guard !event.isARepeat else { return nil }
                viewModel.capture()
                return nil
            case 123: // left arrow
                reviewModel.step(-1, in: viewModel.captures)
                return nil
            case 124: // right arrow
                reviewModel.step(1, in: viewModel.captures)
                return nil
            default:
                if event.charactersIgnoringModifiers?.lowercased() == "f", !event.isARepeat {
                    // Flag whatever the main viewer is currently showing (latest or the held shot).
                    reviewModel.toggleFlag(reviewModel.mainViewerURL(in: viewModel.captures))
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

}

// MARK: - Coffee (sleep prevention) toolbar button

private struct CoffeeButton: View {
    let isOn: Bool
    let action: () -> Void

    @State private var steaming = false

    var body: some View {
        Button(action: action) {
            ZStack {
                SteamWisp(visible: isOn).offset(x: -3, y: steaming ? -12 : -6)
                SteamWisp(visible: isOn).offset(x: 3, y: steaming ? -14 : -8)
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 14))
            }
            .frame(width: 20, height: 20)
        }
        .foregroundStyle(isOn ? Color.orange : Color.primary)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .onAppear { updateAnimation() }
        .onChange(of: isOn) { _ in updateAnimation() }
    }

    private func updateAnimation() {
        if isOn {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                steaming = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                steaming = false
            }
        }
    }
}

/// A small wavy steam wisp drawn above the coffee cup, visible only while sleep is being prevented.
private struct SteamWisp: View {
    let visible: Bool

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 6))
            path.addCurve(to: CGPoint(x: 0, y: 0),
                           control1: CGPoint(x: 2, y: 4),
                           control2: CGPoint(x: -2, y: 2))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round))
        .frame(width: 4, height: 6)
        .opacity(visible ? 0.7 : 0)
    }
}

// MARK: - Preview canvas

private struct PreviewCanvas: View {
    let url: URL?
    let isConnected: Bool

    var body: some View {
        ZStack {
            // A neutral, slightly-recessed canvas so photos read accurately (like Preview/Photos).
            LinearGradient(
                colors: [Color(white: 0.11), Color(white: 0.07)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if let url {
                ZoomableImageView(url: url)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: isConnected ? "camera.aperture" : "cable.connector")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.secondary)
            Text(isConnected ? "Ready — press Space to capture" : "Waiting for camera…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

/// A pill wrapper shared by the focus and exposure badges so they read as one system.
private struct BadgeChrome<Content: View>: View {
    let compact: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(compact ? .system(size: 11, weight: .bold) : .callout.monospacedDigit().weight(.semibold))
            .padding(.horizontal, compact ? 5 : 9)
            .padding(.vertical, compact ? 3 : 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }
}

/// The focus-confidence read: a constant viewfinder glyph, tinted green/amber/red by verdict, plus
/// the 0–100 score. It's a sharpness *estimate* (see `FocusAnalyzer`), not a guarantee — the tooltip
/// says so and the middle "check focus" band keeps it from over-claiming. `compact` drops the number
/// for the tiny filmstrip badge.
private struct FocusBadge: View {
    let result: FocusResult
    var compact: Bool = false

    private var tint: Color {
        switch result.verdict {
        case .sharp: return .green
        case .borderline: return .yellow
        case .soft: return .red
        }
    }

    var body: some View {
        BadgeChrome(compact: compact) {
            HStack(spacing: 4) {
                Image(systemName: "dot.viewfinder")
                    .foregroundStyle(tint)
                if !compact {
                    Text("\(result.score)%").foregroundStyle(.primary)
                }
            }
        }
        .help("Focus confidence \(result.score)% — \(result.verdict.label). A sharpness estimate of the in-focus region, not a guarantee.")
    }
}

/// The exposure read: a constant metering glyph, tinted green (good) or red (under/over), with a
/// ↓/↑ chevron pointing the way to correct. Backed by clipping + brightness (see `ExposureAnalyzer`).
private struct ExposureBadge: View {
    let result: ExposureResult
    var compact: Bool = false

    private var tint: Color { result.verdict == .good ? .green : .red }

    /// The correction direction: down when underexposed, up when over; none when good.
    private var chevron: String? {
        switch result.verdict {
        case .good: return nil
        case .under: return "chevron.down"
        case .over: return "chevron.up"
        }
    }

    private var tooltip: String {
        ExposureExplanation.text(for: result,
                                  highlightClipLimit: ShotAnalysisStore.exposureHighlightClipLimit,
                                  shadowClipLimit: ShotAnalysisStore.exposureShadowClipLimit,
                                  nearWhiteLimit: ShotAnalysisStore.exposureNearWhiteLimit)
    }

    var body: some View {
        BadgeChrome(compact: compact) {
            HStack(spacing: compact ? 1 : 3) {
                Image(systemName: "camera.metering.center.weighted")
                    .foregroundStyle(tint)
                if let chevron {
                    Image(systemName: chevron)
                        .font(.system(size: compact ? 8 : 10, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
        }
        .help(tooltip)
    }
}

/// A fit-to-window image that the photographer can pinch or double-click to zoom into for a focus
/// check, then drag to pan. Loads a fast fit-size preview first, then a full-resolution version in
/// the background so zoomed pixels are crisp. Resets when the displayed photo changes.
///
/// Press-and-hold (while at the default fit scale) instead shows a floating 1:1 loupe under the
/// cursor — a quick pixel check without committing to the pinch-zoom/pan mode above. It tracks the
/// cursor while the mouse button is down and disappears on release.
private struct ZoomableImageView: View {
    let url: URL

    @State private var fitImage: NSImage?
    @State private var fullImage: NSImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loupeCursor: CGPoint?

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                if let image = isZoomed ? (fullImage ?? fitImage) : fitImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(magnification(in: geo.size))
                        .simultaneousGesture(pan(in: geo.size))
                        .simultaneousGesture(loupePress(in: geo.size))
                        .onTapGesture(count: 2) { toggleZoom() }
                        .animation(.easeInOut(duration: 0.18), value: scale)
                        .animation(.easeInOut(duration: 0.25), value: fitImage)
                } else {
                    ProgressView().tint(.white)
                }

                if isZoomed {
                    Text("\(Int(scale * 100))%")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(14)
                }

                if !isZoomed, let loupeCursor, let fitImage {
                    Loupe(image: fullImage ?? fitImage,
                          fitSize: fitImage.size,
                          cursor: loupeCursor,
                          containerSize: geo.size)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: url) { await load() }
    }

    /// Tracks press-and-hold at the default (unzoomed) scale to drive the loupe; a no-op once zoomed,
    /// where dragging already pans instead.
    private func loupePress(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isZoomed else { return }
                loupeCursor = value.location
            }
            .onEnded { _ in loupeCursor = nil }
    }

    private func magnification(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = clampScale(lastScale * value) }
            .onEnded { _ in
                lastScale = scale
                if !isZoomed { resetPan() } else { offset = clampOffset(offset, in: size); lastOffset = offset }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard isZoomed else { return }
                offset = clampOffset(
                    CGSize(width: lastOffset.width + value.translation.width,
                           height: lastOffset.height + value.translation.height),
                    in: size)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        if isZoomed {
            scale = 1; lastScale = 1; resetPan()
        } else {
            scale = 2.5; lastScale = 2.5
        }
    }

    private func clampScale(_ s: CGFloat) -> CGFloat { s.clamped(to: 1...8) }
    private func resetPan() { offset = .zero; lastOffset = .zero }

    /// Keeps the zoomed image from being dragged completely out of view.
    private func clampOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, size.width * (scale - 1) / 2)
        let maxY = max(0, size.height * (scale - 1) / 2)
        return CGSize(width: proposed.width.clamped(to: -maxX...maxX),
                      height: proposed.height.clamped(to: -maxY...maxY))
    }

    private func load() async {
        scale = 1; lastScale = 1; resetPan()
        fullImage = nil
        fitImage = await PreviewLoader.load(url, maxPixel: 2200)
        // Full-resolution copy for crisp pixel-peeping; loaded after the quick preview is showing.
        fullImage = await PreviewLoader.load(url, maxPixel: 6000)
    }
}

/// A floating circular 1:1 pixel-peek that tracks the cursor while the mouse is held down over the
/// (unzoomed) preview. `fitSize` is the aspect-fit preview's point size — used only to work out the
/// letterboxed rect the image actually occupies within `containerSize`, since `.aspectRatio(.fit)`
/// centers the image rather than filling the frame. `image` is the highest-resolution copy loaded so
/// far (`fullImage` once it lands, `fitImage` before that) and is drawn at its native pixel size, so
/// one image pixel maps to one point inside the loupe — actual detail, not an interpolated zoom.
private struct Loupe: View {
    let image: NSImage
    let fitSize: CGSize
    let cursor: CGPoint
    let containerSize: CGSize

    private let diameter: CGFloat = 440

    /// Where the aspect-fit image is actually drawn within `containerSize` (letterboxed, centered).
    private var displayRect: CGRect {
        guard fitSize.width > 0, fitSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let imageAspect = fitSize.width / fitSize.height
        let containerAspect = containerSize.width / containerSize.height
        var size = containerSize
        if imageAspect > containerAspect {
            size.height = containerSize.width / imageAspect
        } else {
            size.width = containerSize.height * imageAspect
        }
        return CGRect(x: (containerSize.width - size.width) / 2,
                      y: (containerSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The cursor's position in the full-resolution image's own pixel coordinates.
    private var centerPixel: CGPoint {
        let rect = displayRect
        let nx = ((cursor.x - rect.minX) / rect.width).clamped(to: 0...1)
        let ny = ((cursor.y - rect.minY) / rect.height).clamped(to: 0...1)
        return CGPoint(x: nx * image.size.width, y: ny * image.size.height)
    }

    /// What's *magnified* is always centered on the cursor (`centerPixel`, above) — this only decides
    /// where the loupe widget itself is drawn on screen. It deliberately sits off to the side (above
    /// the cursor by default, flipping below if that would run off the top of the canvas) so it never
    /// covers the exact spot being inspected: with the loupe parked on top of the cursor, there's
    /// nothing left on screen to visually cross-check it against.
    private var loupeCenter: CGPoint {
        let half = diameter / 2
        let gap: CGFloat = 40
        let x = min(max(cursor.x, half), containerSize.width - half)
        let preferredY = cursor.y - half - gap
        let y = preferredY > half ? preferredY : min(cursor.y + half + gap, containerSize.height - half)
        return CGPoint(x: x, y: y)
    }

    /// Where to crop *from* — `centerPixel` pulled in from the image edges by at least `diameter/2`,
    /// so the crop is always a full `diameter`×`diameter` square and the circle is always completely
    /// filled. Cropping a *smaller* square near an edge (the previous approach) left the uncropped
    /// remainder of the circle showing bare background, which read as a square glitch cutting across
    /// the circle rather than a loupe reaching the edge of the photo. The crosshair (in `body`) makes
    /// up the difference: it shifts off-center by exactly how far this pulled the crop, so it still
    /// marks the true cursor pixel even though the crop itself is no longer centered on it.
    private var cropCenter: CGPoint {
        let half = diameter / 2
        let center = centerPixel
        let maxX = max(half, image.size.width - half)
        let maxY = max(half, image.size.height - half)
        return CGPoint(x: center.x.clamped(to: half...maxX), y: center.y.clamped(to: half...maxY))
    }

    /// A `diameter`×`diameter` crop cut with CoreGraphics.
    ///
    /// Earlier this laid out the *entire* full-resolution `Image` (up to ~3648×5472 **points** — not
    /// pixels) and used `.offset` to slide it behind a small clipped circle. That's the kind of view
    /// SwiftUI/Core Animation doesn't reliably rasterize: verified by sampling a source file directly
    /// with CoreGraphics and comparing to what the loupe rendered for that exact cursor position — the
    /// math (`centerPixel`) was correct, but the rendered content was wrong, consistent with the giant
    /// backing layer breaking down. Cropping to a handful of pixels *before* handing it to SwiftUI
    /// sidesteps the giant-layer case entirely, and is cheap since it runs on the already-decoded image.
    private func crop(center: CGPoint) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let half = diameter / 2
        let rect = CGRect(x: center.x - half, y: center.y - half, width: diameter, height: diameter)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        guard rect.width > 0, rect.height > 0, let cropped = cgImage.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    var body: some View {
        let center = centerPixel
        let cropAt = cropCenter
        let cropped = crop(center: cropAt)
        // How far the crosshair sits from the loupe's visual center — zero away from edges, shifting
        // outward near them since the crop itself can no longer follow the cursor past the edge.
        let crosshairOffset = CGSize(width: center.x - cropAt.x, height: center.y - cropAt.y)

        ZStack {
            Group {
                if let cropped {
                    Image(nsImage: cropped)
                }
            }
            .frame(width: diameter, height: diameter)
            .background(Color.black.opacity(0.6))
            .clipShape(Circle())

            // Crosshair marking the exact pixel under the cursor.
            ZStack {
                Rectangle().fill(.white.opacity(0.8)).frame(width: 1, height: 10)
                Rectangle().fill(.white.opacity(0.8)).frame(width: 10, height: 1)
            }
            .offset(crosshairOffset)
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
        .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1).padding(1))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .frame(width: diameter, height: diameter)
        .position(loupeCenter)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Control bar (status + shutter)

/// The bar between the preview canvas and the filmstrip: this shot's EXIF readout, plus any error.
private struct MetaBar: View {
    let url: URL?
    let errorMessage: String?
    @State private var metadata = PhotoMetadata()

    var body: some View {
        HStack {
            Spacer()
            if !metadata.isEmpty {
                MetadataBar(metadata: metadata)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            if let errorMessage {
                ErrorBanner(text: errorMessage)
                    .padding(.horizontal, 20)
                    .offset(y: -8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .task(id: url) {
            metadata = PhotoMetadata()
            if let url { metadata = await PhotoMetadata.load(url) }
        }
    }
}

/// Shown whenever the camera link is down. The 1DX II resets its wired-LAN connection every couple
/// of minutes and drops off the network, so this makes the state obvious and tells the operator the
/// one action that brings it back — re-entering pairing mode — while the app auto-reconnects.
private struct ReconnectBanner: View {
    let status: String
    @State private var showingNetworkSetup = false

    // `status` already carries the live wait/connect wording ("Waiting for camera…",
    // "Connecting to camera…"); using it as the title (instead of a fixed "Waiting for camera")
    // avoids saying the same thing twice in one banner.
    private var title: String {
        status.isEmpty || status == "Not connected" ? "Waiting for camera" : status
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text("On the camera, re-enter the EOS Utility (wired-LAN) pairing screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            // A camera set to require DHCP over a direct Mac-to-camera cable (no DHCP server on that
            // link) waits indefinitely for an address it will never get. Manual settings skip that
            // negotiation entirely — this surfaces the exact values to type in, computed from the
            // Mac's own self-assigned address on the same cable.
            Button("Manual Setup…") { showingNetworkSetup = true }
                .controlSize(.small)
            Image(systemName: "cable.connector.slash")
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showingNetworkSetup) {
            CameraNetworkSetupView()
        }
    }
}

private struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ScrollView {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
    }
}

// MARK: - Session filmstrip (photographer's select + flag controls)

/// The photographer-facing strip of this session's shots. Clicking a shot selects it (and switches
/// the client to "Selected"); the flag button toggles the macOS "Flagged" tag that feeds the
/// client slideshow. Auto-scrolls to keep the current selection in view as ←/→ scrub through it.
private struct SessionFilmstrip: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var reviewModel: ReviewModel
    @ObservedObject var analysis: ShotAnalysisStore
    let showingOnlyGood: Bool

    /// Shots with a sharp focus verdict and a good exposure verdict. A capture not yet analyzed is
    /// kept out rather than assumed good, so the filter never shows an unscored bad shot — it
    /// settles in as analysis catches up (triggered eagerly when the filter is switched on).
    private var displayedCaptures: [URL] {
        guard showingOnlyGood else { return viewModel.captures }
        return viewModel.captures.filter { url in
            let goodFocus = analysis.focus[url].map { $0.verdict == .sharp } ?? false
            let goodExposure = analysis.exposure[url].map { $0.verdict == .good } ?? false
            return goodFocus && goodExposure
        }
    }

    var body: some View {
        Group {
            if viewModel.captures.isEmpty {
                HStack {
                    Image(systemName: "photo.stack")
                    Text("No captures yet — press Space to shoot")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if showingOnlyGood && displayedCaptures.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("No sharp, well-exposed shots yet")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(displayedCaptures, id: \.self) { url in
                                SessionThumb(
                                    url: url,
                                    isSelected: url == reviewModel.selectedURL,
                                    isFlagged: reviewModel.isFlagged(url),
                                    isOnClient: url == reviewModel.displayedURL(in: viewModel.captures),
                                    focusResult: analysis.focus[url],
                                    exposureResult: analysis.exposure[url],
                                    onSelect: { reviewModel.hold(url) },
                                    onToggleFlag: { reviewModel.toggleFlag(url) },
                                    onAppear: { analysis.analyze(url) }
                                )
                                .id(url)
                                .contextMenu {
                                    Button(reviewModel.isFlagged(url) ? "Remove Flag" : "Flag for Slideshow") {
                                        reviewModel.toggleFlag(url)
                                    }
                                    Button("Show on Client Monitor") { reviewModel.showOnClient(url) }
                                    Divider()
                                    Button("Reveal in Finder") { viewModel.revealInFinder(url) }
                                    Button("Move to Trash", role: .destructive) { viewModel.moveToTrash(url) }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: reviewModel.selectedURL) { newSelection in
                        guard let newSelection else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newSelection, anchor: .center) }
                    }
                }
            }
        }
        .frame(height: 132)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct SessionThumb: View {
    let url: URL
    let isSelected: Bool
    let isFlagged: Bool
    let isOnClient: Bool
    let focusResult: FocusResult?
    let exposureResult: ExposureResult?
    let onSelect: () -> Void
    let onToggleFlag: () -> Void
    let onAppear: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(width: 140, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.15),
                                          lineWidth: isSelected ? 3 : 1)
                    )
                    .onTapGesture(perform: onSelect)

                Button(action: onToggleFlag) {
                    Image(systemName: isFlagged ? "flag.fill" : "flag")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isFlagged ? Color.orange : .white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .help(isFlagged ? "Remove flag (F)" : "Flag for slideshow (F)")

                // Badge marking the shot currently on the client monitor.
                if isOnClient {
                    Label("On Client", systemImage: "tv")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.green.opacity(0.9), in: Circle())
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .help("Currently shown on the client monitor")
                }

                // At-a-glance focus + exposure read, bottom-trailing (clears the flag and On-Client badges).
                if focusResult != nil || exposureResult != nil {
                    HStack(spacing: 3) {
                        if let focusResult { FocusBadge(result: focusResult, compact: true) }
                        if let exposureResult { ExposureBadge(result: exposureResult, compact: true) }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .task(id: url) {
            onAppear()
            image = await PreviewLoader.load(url, maxPixel: 300)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(white: 0.2)
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Onboarding (gphoto2 not installed)

/// Shown on first run when the gphoto2 CLI is missing, so the app explains the one setup step
/// instead of silently sitting on "waiting for camera".
private struct OnboardingView: View {
    private let installCommand = "brew install libgphoto2 gphoto2"
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)

            Text("One-time setup")
                .font(.title.weight(.semibold))
            Text("Canon Tether drives the camera through gphoto2, which isn't installed yet.\nInstall it with Homebrew, then relaunch this app.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(installCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(installCommand, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }

            Text("Don't have Homebrew? Install it from brew.sh first.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 460)
    }
}

// MARK: - Preferences

private struct PreferencesView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var reviewModel: ReviewModel
    @ObservedObject var analysis: ShotAnalysisStore
    let captureCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var captureFolder = CaptureLocation.directory
    // Keys mirror ShotAnalysisStore's key constants (string literals so they can key @AppStorage).
    @AppStorage("focusCheckEnabled") private var focusEnabled = true
    @AppStorage("exposureCheckEnabled") private var exposureEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.title2.weight(.semibold))

            // Capture folder
            VStack(alignment: .leading, spacing: 8) {
                Text("Capture Folder").font(.headline)
                HStack {
                    Text(captureFolder.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([captureFolder]) }
                    Button("Choose…") { chooseFolder() }
                }
                Text("The current project. Choosing a folder switches projects right away — the gallery clears and repopulates from that folder, and your flags come back with it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Slideshow default
            VStack(alignment: .leading, spacing: 8) {
                Text("Client Slideshow").font(.headline)
                HStack {
                    Text("Interval")
                    Slider(value: $reviewModel.slideshowInterval, in: 2...15, step: 1)
                    Text("\(Int(reviewModel.slideshowInterval))s")
                        .font(.callout.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Divider()

            // Focus check
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $focusEnabled) {
                    Text("Focus Check").font(.headline)
                }
                Text("Scores each shot's sharpness and shows a green check / red ✗ with a confidence %. The verdict is written to the file as a Sharp/Soft Finder tag, so it shows up in Finder and returns with the project. The cut-off is fixed and calibrated — no dial to get wrong.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Exposure check
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $exposureEnabled) {
                    Text("Exposure Check").font(.headline)
                }
                Text("Flags blown highlights, crushed shadows, and over-/under-exposure with a green/red meter (↑ too bright, ↓ too dark). Problem shots get an Overexposed/Underexposed Finder tag. The clipping tolerance is fixed and calibrated — no dial to get wrong.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Text("\(captureCount) photo\(captureCount == 1 ? "" : "s") in this session")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 580)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = captureFolder
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url != captureFolder else { return }
        captureFolder = url
        // Order matters: drop the old project's pointers first (so the client monitor doesn't linger
        // on an old-folder photo), then repoint and reload — the reload's `captures` change drives
        // `reviewModel.sync`, which reloads the new folder's flags from Finder tags.
        reviewModel.resetForNewProject()
        analysis.resetForNewProject()
        viewModel.changeCaptureFolder(url)
    }
}
