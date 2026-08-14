import SwiftUI
import AppKit
import ImageIO
import CanonTetherCore

// MARK: - Sampling

/// Pulls a small pixel grid out of a capture for the scopes to measure. Uses the same ImageIO
/// thumbnail path as `PreviewLoader` — so RAWs come back at embedded-preview speed — then flattens
/// it into the float RGBA buffer `ScopeRenderer` walks.
///
/// Sampling is done in **extended-range sRGB** (float, Rec.709 primaries, *unclamped*): a preview
/// wider than sRGB — an Adobe RGB JPEG, say — keeps its out-of-gamut colour as channel values below
/// 0 or above 1 instead of being crushed into the sRGB box. That's what lets the vectorscope show
/// the trace reaching past the sRGB gamut outline. (The camera's own embedded previews are sRGB, so
/// on those the trace stays inside sRGB — correctly.)
enum ScopeSampler {
    /// `maxPixel` comes from `ScopeLayout`: the bigger the scopes are drawn, the more of the photo
    /// has to be measured to fill them. 1280 px is ~1.1 M samples and takes ~70 ms for both scopes,
    /// which is nothing against the rate shots actually arrive at.
    static func sample(_ url: URL, maxPixel: Int = 800) async -> ScopeFrame? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: load(url, maxPixel: maxPixel))
            }
        }
    }

    private static func load(_ url: URL, maxPixel: Int) -> ScopeFrame? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }

        var floats = [Float32](repeating: 0, count: width * height * 4)
        // Extended-range sRGB float context preserves wide-gamut values (outside [0, 1]) that an
        // 8-bit sRGB context would clip away.
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB) ?? CGColorSpaceCreateDeviceRGB()
        // `byteOrder32Little` is mandatory for a 32-bit-float context — without it CGContext refuses
        // the format and the buffer stays all-zero (a silently black scope).
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            .union(.floatComponents)
            .union(.byteOrder32Little)
        var drew = false
        floats.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 32,
                bytesPerRow: width * 16,
                space: space,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            drew = true
        }
        guard drew else { return nil }
        return ScopeFrame(width: width, height: height, rgba: floats)
    }
}

/// Wraps a rendered scope bitmap for SwiftUI.
private enum ScopeImage {
    static func make(_ raster: ScopeRaster) -> NSImage? {
        let data = Data(raster.rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(
            width: raster.width,
            height: raster.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: raster.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: raster.width, height: raster.height))
    }
}

// MARK: - Panel

/// Waveform + vectorscope for whatever the main viewer is showing — the objective read on exposure
/// and white balance that a photo on a laptop screen can't give you. Both are measured off the
/// downsampled preview, and both re-render whenever the displayed shot (or the waveform mode) changes.
/// How big to draw the scopes in the space the column currently has. Derived from the panel's
/// measured size so both grow when the window (or the split-view divider) does.
struct ScopeLayout: Equatable {
    let waveformHeight: CGFloat
    /// The largest square the vectorscope may be drawn at.
    let vectorLimit: CGFloat

    /// Vertical room kept for the header and the settings list before the scopes may claim any.
    /// Deliberately small: the camera reports five adjustable settings and that list isn't going to
    /// grow much, so the space is worth more to the scopes — the settings scroll if they need to.
    private static let reservedForSettings: CGFloat = 180

    init(available: CGSize) {
        // Panel padding (16 each side) plus the card's own inset (10 each side).
        let contentWidth = max(available.width - 52, 120)
        waveformHeight = min(max(available.height * 0.2, 110), 260)
        let heightLimit = available.height - waveformHeight - Self.reservedForSettings
        // Square, so however much height it's given it can never be wider than the column.
        vectorLimit = max(150, min(contentWidth, heightLimit))
    }

    /// Whether the panel is large enough to warrant the higher-resolution pass. Stepped rather than
    /// continuous so dragging a window edge doesn't re-render the scopes on every frame.
    private var isLarge: Bool { vectorLimit > 300 }

    /// Raster resolution for the vectorscope, so a large plot still has pixels to spare.
    var vectorRaster: Int { isLarge ? 768 : 512 }

    /// How finely to sample the photo. This has to rise with the raster: chroma spreads over a wide
    /// area, and a plot with more cells than the sample has pixels comes out stippled and dim
    /// however the trace is brightened.
    var sampleSize: Int { isLarge ? 1280 : 800 }
}

struct ScopesPanel: View {
    let url: URL?
    let layout: ScopeLayout

    @AppStorage("waveformMode") private var storedMode = WaveformMode.parade.rawValue
    /// Empty = no gamut outline; otherwise a `ColorGamut.rawValue`.
    @AppStorage("gamutOverlay") private var storedGamut = ""
    @State private var waveform: NSImage?
    @State private var vector: NSImage?
    @State private var isRendering = false

    private var mode: WaveformMode {
        get { WaveformMode(rawValue: storedMode) ?? .parade }
        nonmutating set { storedMode = newValue.rawValue }
    }

    private var modeBinding: Binding<WaveformMode> {
        Binding(get: { mode }, set: { mode = $0 })
    }

    /// The gamut whose boundary is outlined on the vectorscope, or nil for none.
    private var gamut: ColorGamut? { ColorGamut(rawValue: storedGamut) }

    /// The waveform's raster is fixed: it's stretched to the panel width either way, and a plot
    /// that wide never wants for pixels. The vectorscope's comes from `ScopeLayout`, since that one
    /// is drawn square and can get big.
    private static let waveformSize = (width: 640, height: 300)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            SectionCard {
                // Stacked: a wide waveform, the vectorscope centred below it.
                VStack(spacing: 0) {
                    WaveformView(image: waveform, mode: mode, hasContent: url != nil)
                        .frame(height: layout.waveformHeight)
                    Divider()
                    VectorscopeView(image: vector, hasContent: url != nil,
                                    limit: layout.vectorLimit, gamut: gamut)
                }
            }
        }
        .task(id: RenderKey(url: url, mode: mode, vectorRaster: layout.vectorRaster)) { await render() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SectionLabel("Scopes")

            Spacer(minLength: 4)

            if isRendering {
                // Left at its natural size on purpose: pinning an NSProgressIndicator to a height
                // smaller than its intrinsic one makes SwiftUI's layout traits invalid (min > max),
                // which traps at runtime rather than just clipping.
                ProgressView().controlSize(.small)
            }

            gamutMenu

            Picker("Waveform", selection: modeBinding) {
                ForEach(WaveformMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("What the waveform plots: luminance, the channels side by side, or overlaid")
        }
        .padding(.horizontal, 4)
    }

    /// Chooses which gamut outline the vectorscope draws (or none). The camera's own previews are
    /// sRGB, so on those the trace stays inside the sRGB hexagon; shooting Adobe RGB pushes it out.
    private var gamutMenu: some View {
        Menu {
            Button {
                storedGamut = ""
            } label: {
                Label("Off", systemImage: gamut == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ColorGamut.allCases) { option in
                Button {
                    storedGamut = option.rawValue
                } label: {
                    Label(option.label, systemImage: gamut == option ? "checkmark" : "")
                }
            }
        } label: {
            Label(gamut?.label ?? "Gamut", systemImage: "hexagon")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Outline a colour-space boundary on the vectorscope. The trace can only exceed sRGB if the source is wide-gamut (e.g. an Adobe RGB JPEG); the camera's own previews are sRGB.")
    }

    /// One identity for "what should be on screen", so switching modes re-renders without a
    /// second piece of state to keep in sync.
    private struct RenderKey: Equatable {
        let url: URL?
        let mode: WaveformMode
        let vectorRaster: Int
    }

    private func render() async {
        guard let url else {
            waveform = nil
            vector = nil
            return
        }
        isRendering = true
        defer { isRendering = false }

        guard let frame = await ScopeSampler.sample(url, maxPixel: layout.sampleSize) else {
            waveform = nil
            vector = nil
            return
        }
        guard !Task.isCancelled else { return }

        let mode = self.mode
        let vectorSize = layout.vectorRaster
        let (wave, vec) = await withCheckedContinuation { (continuation: CheckedContinuation<(NSImage?, NSImage?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let waveRaster = ScopeRenderer.waveform(
                    frame, mode: mode,
                    width: Self.waveformSize.width, height: Self.waveformSize.height
                )
                let vectorRaster = ScopeRenderer.vectorscope(frame, size: vectorSize)
                continuation.resume(returning: (ScopeImage.make(waveRaster), ScopeImage.make(vectorRaster)))
            }
        }
        guard !Task.isCancelled else { return }
        waveform = wave
        vector = vec
    }
}

// MARK: - Waveform

private struct WaveformView: View {
    let image: NSImage?
    let mode: WaveformMode
    let hasContent: Bool

    /// Room on the left for the 0–100 % scale, outside the plot so it never covers the trace.
    private static let gutter: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            scale
            plot
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(9)
    }

    private var scale: some View {
        GeometryReader { geo in
            ForEach(Graticule.levels, id: \.self) { level in
                Text("\(level)")
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.gutter - 6, alignment: .trailing)
                    .position(x: (Self.gutter - 6) / 2,
                              y: Graticule.y(for: level, in: geo.size.height))
            }
        }
        .frame(width: Self.gutter)
    }

    private var plot: some View {
        ZStack {
            ScopeWell {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    ScopePlaceholder(hasContent: hasContent)
                }
            }
            .overlay { graticule }
        }
    }

    private var graticule: some View {
        Canvas { context, size in
            for level in Graticule.levels {
                let y = Graticule.y(for: level, in: size.height)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                // The clipping levels get a slightly firmer line than the mid-tone guides.
                let edge = (level == 0 || level == 100)
                context.stroke(line,
                               with: .color(.white.opacity(edge ? 0.22 : 0.10)),
                               style: StrokeStyle(lineWidth: 1, dash: edge ? [] : [2, 3]))
            }
            // Parade panels are three separate plots; mark where each channel starts.
            if mode == .parade {
                for third in 1...2 {
                    let x = size.width * CGFloat(third) / 3
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.black.opacity(0.55)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private enum Graticule {
        static let levels = [100, 75, 50, 25, 0]

        /// The renderer puts code value 255 on the top row and 0 on the bottom one.
        static func y(for level: Int, in height: CGFloat) -> CGFloat {
            (1 - CGFloat(level) / 100) * max(height - 1, 0) + 0.5
        }
    }
}

// MARK: - Vectorscope

private struct VectorscopeView: View {
    let image: NSImage?
    let hasContent: Bool
    /// Largest square it may be drawn at, from `ScopeLayout`.
    let limit: CGFloat
    /// The gamut boundary to outline, or nil for none.
    let gamut: ColorGamut?

    var body: some View {
        ScopeWell {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    ScopePlaceholder(hasContent: hasContent)
                }
                graticule
            }
        }
        // A *definite* square rather than an aspect ratio inside a flexible box: the settings
        // ScrollView above is greedy, and against a flexible sibling it takes half the column,
        // which is what kept the vectorscope small no matter how much room the panel had.
        .frame(width: limit, height: limit)
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    private var graticule: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The scope is always drawn at full size; a wide gamut's hexagon simply extends toward
            // (and past) the view edge rather than shrinking everything to fit — the trace stays as
            // large as possible and the size never changes between gamuts.
            let radius = min(size.width, size.height) / 2 - 1
            let line = Color.white.opacity(0.16)

            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(line), lineWidth: 1)

            // Crosshair: short ticks rather than full axes, so the centre stays readable.
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + dx * radius * 0.08, y: center.y + dy * radius * 0.08))
                tick.addLine(to: CGPoint(x: center.x + dx * radius * 0.22, y: center.y + dy * radius * 0.22))
                context.stroke(tick, with: .color(line), lineWidth: 1)
            }

            // Skin-tone line: faces sit along it when white balance and tint are right.
            let angle = ScopeRenderer.skinToneAngleDegrees * .pi / 180
            var skin = Path()
            skin.move(to: center)
            skin.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 0.92,
                                     y: center.y - sin(angle) * radius * 0.92))
            context.stroke(skin, with: .color(.white.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // 75 % colour-bar targets, each labelled just outside its box on the line back to the
            // centre — a fixed step along the *unit* direction, so the labels sit the same distance
            // out however far from the centre the target is. Box and type scale with the plot, so
            // the graticule reads the same whether the panel is narrow or dragged out wide.
            let boxHalf = max(4, radius * 0.026)
            let labelSize = max(8, radius * 0.046)
            for target in ScopeRenderer.vectorTargets {
                let magnitude = max((target.x * target.x + target.y * target.y).squareRoot(), 0.0001)
                let unit = CGPoint(x: CGFloat(target.x / magnitude), y: CGFloat(target.y / magnitude))
                let point = CGPoint(x: center.x + CGFloat(target.x) * radius,
                                    y: center.y + CGFloat(target.y) * radius)
                let box = CGRect(x: point.x - boxHalf, y: point.y - boxHalf,
                                 width: boxHalf * 2, height: boxHalf * 2)
                context.stroke(Path(roundedRect: box, cornerRadius: boxHalf / 3),
                               with: .color(.white.opacity(0.35)), lineWidth: 1)
                context.draw(
                    Text(target.name)
                        .font(.system(size: labelSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5)),
                    at: CGPoint(x: point.x + unit.x * (boxHalf + labelSize),
                                y: point.y + unit.y * (boxHalf + labelSize))
                )
            }

            if let gamut { drawGamut(gamut, in: &context, center: center, radius: radius, labelSize: labelSize) }
        }
        .allowsHitTesting(false)
    }

    /// Draws the selected gamut's boundary hexagon (the six primaries/secondaries joined) plus a
    /// small label at its outermost vertex, in the same scope coordinates as everything else.
    private func drawGamut(_ gamut: ColorGamut, in context: inout GraphicsContext,
                           center: CGPoint, radius: CGFloat, labelSize: CGFloat) {
        let vertices = ScopeRenderer.gamutBoundary(gamut)
        guard vertices.count == 6 else { return }
        let points = vertices.map { CGPoint(x: center.x + CGFloat($0.x) * radius,
                                            y: center.y + CGFloat($0.y) * radius) }
        var hexagon = Path()
        hexagon.addLines(points)
        hexagon.closeSubpath()
        let tint = Color(red: 0.36, green: 0.82, blue: 0.95)   // cool cyan, distinct from the white graticule
        context.stroke(hexagon, with: .color(tint.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

        // Label at the outermost vertex (the green corner), nudged further out.
        if let outer = vertices.enumerated().max(by: { $0.element.radius < $1.element.radius }) {
            let v = vertices[outer.offset]
            let mag = max(v.radius, 0.0001)
            context.draw(
                Text(gamut.label)
                    .font(.system(size: labelSize, weight: .semibold))
                    .foregroundColor(tint),
                at: CGPoint(x: points[outer.offset].x + CGFloat(v.x / mag) * (labelSize * 1.6),
                            y: points[outer.offset].y + CGFloat(v.y / mag) * (labelSize * 1.6))
            )
        }
    }
}

// MARK: - Shared chrome

/// The recessed black well both scopes sit in.
private struct ScopeWell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.047, green: 0.055, blue: 0.067))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct ScopePlaceholder: View {
    let hasContent: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hasContent ? "waveform" : "photo")
                .font(.system(size: 15, weight: .light))
            Text(hasContent ? "Measuring…" : "No photo")
                .font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
