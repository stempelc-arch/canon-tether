import Foundation

/// A small RGBA snapshot of a capture, cheap enough to walk pixel-by-pixel on every new shot.
/// Produced by the app layer (ImageIO) and consumed by `ScopeRenderer`, which is deliberately
/// Foundation-only so the scope maths can be exercised without a window.
public struct ScopeFrame: Equatable {
    public let width: Int
    public let height: Int
    /// Row-major, 4 floats per pixel (R, G, B, A), no row padding, in **extended-range sRGB**:
    /// nominally [0, 1], but a wide-gamut source (an Adobe RGB preview, say) lands outside that box,
    /// which is exactly what lets the vectorscope show colour reaching past the sRGB boundary.
    public let rgba: [Float]

    public init(width: Int, height: Int, rgba: [Float]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Convenience for 8-bit callers (tests, fixtures): 0–255 bytes scaled into [0, 1].
    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.init(width: width, height: height, rgba: bytes.map { Float($0) / 255 })
    }

    public var isValid: Bool {
        width > 0 && height > 0 && rgba.count >= width * height * 4
    }

    public var pixelCount: Int { width * height }
}

/// Which signal the waveform plots. Named the way colourists say them.
public enum WaveformMode: String, CaseIterable, Identifiable, Sendable {
    case luma      // single white trace of Rec.709 luminance
    case parade    // R, G and B side by side — the usual white-balance read
    case rgb       // the three channels overlaid in one panel

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .luma: return "Luma"
        case .parade: return "Parade"
        case .rgb: return "RGB"
        }
    }
}

/// An RGBA8 bitmap produced by the renderers, ready to be wrapped in a `CGImage`.
public struct ScopeRaster: Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// One of the six colour-bar boxes on a vectorscope graticule, in coordinates where the scope's
/// outer circle has radius 1, x runs right and y runs *down* (screen order, ready for drawing).
public struct VectorTarget: Equatable {
    public let name: String   // "R", "Mg", …
    public let x: Double
    public let y: Double
}

/// A point in the same scope coordinates as `VectorTarget`: unit-radius circle, x right, y down.
public struct ScopePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    /// Distance from the scope centre, in radii — handy for asserting one gamut sits outside another.
    public var radius: Double { (x * x + y * y).squareRoot() }
}

/// An RGB working space whose boundary the vectorscope can outline. sRGB and Rec.709 share primaries,
/// so one entry covers both; the two wider spaces are what a 1DX II can actually shoot to (Adobe RGB
/// as a JPEG setting; Display P3 is the camera preview's tagged display space).
public enum ColorGamut: String, CaseIterable, Identifiable, Sendable {
    case sRGB        // == Rec.709 primaries
    case adobeRGB
    case displayP3

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sRGB: return "sRGB"
        case .adobeRGB: return "Adobe RGB"
        case .displayP3: return "Display P3"
        }
    }
}

/// Just enough colour science to place a gamut's corners on the vectorscope: build each space's
/// linear-RGB→XYZ matrix from its primaries and white point, then compose with sRGB's inverse to get
/// gamut-linear → sRGB-linear. Foundation-only and self-contained, so it stays unit-testable.
enum Colorimetry {
    /// xy chromaticities of the primaries and the white point (all D65 here).
    private struct Primaries {
        let r: (Double, Double), g: (Double, Double), b: (Double, Double), white: (Double, Double)
    }

    private static let d65 = (0.3127, 0.3290)
    private static let primaries: [ColorGamut: Primaries] = [
        .sRGB:      Primaries(r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060), white: d65),
        .adobeRGB:  Primaries(r: (0.640, 0.330), g: (0.210, 0.710), b: (0.150, 0.060), white: d65),
        .displayP3: Primaries(r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060), white: d65)
    ]

    /// gamut-linear-RGB → sRGB-linear-RGB. Identity for sRGB itself.
    static func gamutToSRGBLinear(_ gamut: ColorGamut) -> Mat3 {
        guard gamut != .sRGB else { return .identity }
        let toXYZ = rgbToXYZ(primaries[gamut] ?? primaries[.sRGB]!)
        let srgbToXYZ = rgbToXYZ(primaries[.sRGB]!)
        return srgbToXYZ.inverse.multiplied(by: toXYZ)
    }

    /// The sign-preserving sRGB transfer function, extended past [0, 1] so out-of-gamut corners
    /// (which arrive as values below 0 or above 1) still map somewhere sensible.
    static func encodeSRGB(_ value: Double) -> Double {
        let sign = value < 0 ? -1.0 : 1.0
        let a = abs(value)
        let encoded = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return sign * encoded
    }

    /// The RGB→XYZ matrix for a set of primaries + white point (Lindbloom's construction).
    private static func rgbToXYZ(_ p: Primaries) -> Mat3 {
        func xyz(_ c: (Double, Double)) -> (Double, Double, Double) {
            (c.0 / c.1, 1, (1 - c.0 - c.1) / c.1)
        }
        let r = xyz(p.r), g = xyz(p.g), b = xyz(p.b), w = xyz(p.white)
        // Columns are the primaries' XYZ; scale each so the primaries sum to the white point.
        let m = Mat3(rows: [(r.0, g.0, b.0), (r.1, g.1, b.1), (r.2, g.2, b.2)])
        let s = m.inverse.apply((w.0, w.1, w.2))
        return Mat3(rows: [
            (s.0 * r.0, s.1 * g.0, s.2 * b.0),
            (s.0 * r.1, s.1 * g.1, s.2 * b.1),
            (s.0 * r.2, s.1 * g.2, s.2 * b.2)
        ])
    }
}

/// A tiny 3×3 double matrix — enough for the gamut maths, so Core needn't pull in simd/Accelerate.
struct Mat3: Equatable {
    /// Row-major.
    let m: [[Double]]

    init(rows: [(Double, Double, Double)]) {
        m = rows.map { [$0.0, $0.1, $0.2] }
    }
    private init(_ m: [[Double]]) { self.m = m }

    static let identity = Mat3(rows: [(1, 0, 0), (0, 1, 0), (0, 0, 1)])

    func apply(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0][0] * v.0 + m[0][1] * v.1 + m[0][2] * v.2,
         m[1][0] * v.0 + m[1][1] * v.1 + m[1][2] * v.2,
         m[2][0] * v.0 + m[2][1] * v.1 + m[2][2] * v.2)
    }

    func multiplied(by other: Mat3) -> Mat3 {
        var result = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                result[i][j] = (0..<3).reduce(0) { $0 + m[i][$1] * other.m[$1][j] }
            }
        }
        return Mat3(result)
    }

    var inverse: Mat3 {
        let a = m
        let det =
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
            a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
            a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        guard abs(det) > 1e-12 else { return .identity }
        let invDet = 1 / det
        func cof(_ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int) -> Double {
            a[r0][c0] * a[r1][c1] - a[r0][c1] * a[r1][c0]
        }
        // Adjugate (transpose of cofactors) times 1/det.
        return Mat3([
            [ cof(1, 2, 1, 2) * invDet, -cof(0, 2, 1, 2) * invDet,  cof(0, 1, 1, 2) * invDet],
            [-cof(1, 2, 0, 2) * invDet,  cof(0, 2, 0, 2) * invDet, -cof(0, 1, 0, 2) * invDet],
            [ cof(1, 2, 0, 1) * invDet, -cof(0, 2, 0, 1) * invDet,  cof(0, 1, 0, 1) * invDet]
        ])
    }
}

/// Draws waveform and vectorscope bitmaps from a `ScopeFrame`.
///
/// Both are accumulation plots: every source pixel drops one hit into an output cell, and the hit
/// count is mapped to brightness through `1 - exp(-gain · count)`. That curve is what gives a
/// broadcast scope its look — a single stray pixel still registers faintly, while a few dozen
/// saturate — and the gain is derived from the sample count rather than from the data, so the same
/// image always reads at the same brightness regardless of the resolution it was sampled at.
public enum ScopeRenderer {
    /// Near-black, matching the panel's scope well rather than pure black so the trace floor is visible.
    private static let background: (r: Double, g: Double, b: Double) = (12, 14, 17)

    /// Rec.709 luma weights, and the CbCr denominators that follow from them.
    private static let lumaR = 0.2126, lumaG = 0.7152, lumaB = 0.0722
    private static let cbScale = 1.8556, crScale = 1.5748

    /// How far chroma is thrown from the centre of the vectorscope, in radii per unit of CbCr.
    /// The furthest any sRGB pixel can reach is 100 % green (and its opposite, magenta) at 0.596,
    /// so 1.5 puts that at 0.89 of the radius: everything the camera can produce stays inside the
    /// graticule ring instead of being clipped off the plot, and the 75 % colour-bar boxes land at
    /// the ~0.58 a broadcast graticule puts them at.
    private static let vectorGain = 1.5

    // MARK: - Waveform

    /// Plots `frame` as a waveform `width` × `height` pixels. Columns map to image columns (per
    /// panel in parade mode); rows map to code value, 255 at the top.
    public static func waveform(_ frame: ScopeFrame, mode: WaveformMode, width: Int, height: Int) -> ScopeRaster {
        let panels = (mode == .parade) ? 3 : 1
        let panelWidth = max(width / panels, 1)
        // Three accumulation layers so overlaid channels stay separable when they're colourised.
        var accum = [Double](repeating: 0, count: width * height * 3)

        guard frame.isValid, width > 0, height > 0 else {
            return blank(width: width, height: height)
        }

        frame.rgba.withUnsafeBufferPointer { src in
            accum.withUnsafeMutableBufferPointer { out in
                for sy in 0..<frame.height {
                    let rowStart = sy * frame.width * 4
                    for sx in 0..<frame.width {
                        let i = rowStart + sx * 4
                        // Code values, extended-range: anything below 0 or above 1 clips at the
                        // waveform's rails, which is the honest read for out-of-range content.
                        let r = Double(src[i]), g = Double(src[i + 1]), b = Double(src[i + 2])
                        let column = sx * panelWidth / frame.width

                        switch mode {
                        case .luma:
                            plot(out, width: width, height: height, x: column, value: lumaR * r + lumaG * g + lumaB * b, layer: 0)
                        case .rgb:
                            plot(out, width: width, height: height, x: column, value: r, layer: 0)
                            plot(out, width: width, height: height, x: column, value: g, layer: 1)
                            plot(out, width: width, height: height, x: column, value: b, layer: 2)
                        case .parade:
                            plot(out, width: width, height: height, x: column, value: r, layer: 0)
                            plot(out, width: width, height: height, x: panelWidth + column, value: g, layer: 1)
                            plot(out, width: width, height: height, x: 2 * panelWidth + column, value: b, layer: 2)
                        }
                    }
                }
            }
        }

        // Every panel column collects one hit per source pixel in the image columns feeding it,
        // spread over however many rows the plot is tall.
        let samplesPerColumn = Double(frame.pixelCount) / Double(panelWidth)
        let gain = 36 / max(samplesPerColumn, 1) * (Double(height) / 250)
        let tints: [(Double, Double, Double)] = mode == .luma
            ? [(214, 236, 224), (0, 0, 0), (0, 0, 0)]
            : [(255, 72, 72), (72, 236, 112), (96, 148, 255)]

        return colourise(accum, width: width, height: height, gain: gain, tints: tints)
    }

    private static func plot(
        _ out: UnsafeMutableBufferPointer<Double>,
        width: Int, height: Int,
        x: Int, value: Double, layer: Int
    ) {
        guard x >= 0, x < width else { return }
        let clamped = min(max(value, 0), 1)
        let row = Int((1 - clamped) * Double(height - 1))
        out[(row * width + x) * 3 + layer] += 1
    }

    // MARK: - Vectorscope

    /// Plots `frame`'s chroma as a square vectorscope `size` × `size` pixels: Cb right, Cr up.
    ///
    /// The trace is colourised — every cell is drawn in the colour it represents, so the plot reads
    /// as the familiar hue wheel: neutrals stay white at the centre and the arms take the colour of
    /// whatever is pushing them out. The hue comes from the cell's own position rather than from
    /// the pixels that landed in it, so a shadow and a highlight of the same hue draw the same
    /// colour instead of one of them coming out muddy.
    public static func vectorscope(_ frame: ScopeFrame, size: Int) -> ScopeRaster {
        guard frame.isValid, size > 0 else { return blank(width: size, height: size) }

        var accum = [Double](repeating: 0, count: size * size)
        let radius = Double(size) / 2

        frame.rgba.withUnsafeBufferPointer { src in
            accum.withUnsafeMutableBufferPointer { out in
                for p in stride(from: 0, to: frame.pixelCount * 4, by: 4) {
                    // Already normalised, and extended-range: wide-gamut pixels sit outside [0, 1]
                    // and so plot beyond the sRGB hexagon — which is the whole point of the overlay.
                    let r = Double(src[p]), g = Double(src[p + 1]), b = Double(src[p + 2])
                    let y = lumaR * r + lumaG * g + lumaB * b
                    let cb = (b - y) / cbScale
                    let cr = (r - y) / crScale

                    // Splat each sample bilinearly across the four cells it falls between. A plot
                    // this size has far more cells than the frame has pixels, so dropping each hit
                    // into a single cell leaves the trace stippled and dark; spreading it lays down
                    // continuous coverage for the same total energy.
                    let fx = radius + cb * vectorGain * radius
                    let fy = radius - cr * vectorGain * radius
                    let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                    let tx = fx - Double(x0), ty = fy - Double(y0)
                    for (dx, dy, weight) in [(0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)),
                                             (0, 1, (1 - tx) * ty), (1, 1, tx * ty)] {
                        let x = x0 + dx, y = y0 + dy
                        guard weight > 0, x >= 0, x < size, y >= 0, y < size else { continue }
                        out[y * size + x] += weight
                    }
                }
            }
        }

        // Chroma clusters far more tightly than luma does, so the curve is tuned off the whole
        // frame rather than per column, and scaled by cell area so that enlarging the plot spreads
        // the same hits over more cells without the trace fading out.
        let gain = 9000 / Double(max(frame.pixelCount, 1)) * cellAreaScale(size: size, reference: 320)

        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            accum.withUnsafeBufferPointer { hits in
                for row in 0..<size {
                    for column in 0..<size {
                        let cell = row * size + column
                        let offset = cell * 4
                        let count = hits[cell]
                        guard count > 0 else {
                            out[offset] = clampByte(background.r)
                            out[offset + 1] = clampByte(background.g)
                            out[offset + 2] = clampByte(background.b)
                            continue
                        }
                        // Gamma-lifted: chroma spreads over a wide area, so the thin outer parts of
                        // a trace sit at a hit count that the bare exponential renders almost black.
                        // Raising it brings the sparse edges up without flattening the dense core.
                        let intensity = pow(1 - exp(-gain * count), 0.55)
                        let colour = hue(atX: Double(column), y: Double(row), radius: radius)
                        out[offset] = clampByte(background.r + intensity * colour.r)
                        out[offset + 1] = clampByte(background.g + intensity * colour.g)
                        out[offset + 2] = clampByte(background.b + intensity * colour.b)
                    }
                }
            }
        }
        return ScopeRaster(width: size, height: size, rgba: pixels)
    }

    /// The colour a vectorscope cell stands for, 0–255 per channel: the chroma its position encodes,
    /// taken to the brightest version of itself that is still inside the RGB cube. Picking the luma
    /// that puts the *strongest* channel at full keeps the centre white and every arm luminous —
    /// balancing on the weakest channel instead would drive the neutral centre to black.
    private static func hue(atX x: Double, y: Double, radius: Double) -> (r: Double, g: Double, b: Double) {
        let cb = (x - radius) / (vectorGain * radius)
        let cr = (radius - y) / (vectorGain * radius)
        // Inverse Rec.709, split into the luma-independent part…
        let dR = 1.5748 * cr
        let dG = -0.1873 * cb - 0.4681 * cr
        let dB = 1.8556 * cb
        // …then the luma that just saturates the top channel.
        let luma = 1 - max(dR, max(dG, dB))
        let r = min(max(luma + dR, 0), 1)
        let g = min(max(luma + dG, 0), 1)
        let b = min(max(luma + dB, 0), 1)
        return (r * 255, g * 255, b * 255)
    }

    /// How much brighter each cell must be drawn when the plot is rendered larger than the size its
    /// gain was tuned at — the same hits spread over more, smaller cells.
    private static func cellAreaScale(size: Int, reference: Int) -> Double {
        let ratio = Double(size) / Double(reference)
        return ratio * ratio
    }

    /// The six 75 %-colour-bar boxes, positioned exactly the way the trace is, so a shot of real
    /// bars lands in them.
    public static var vectorTargets: [VectorTarget] {
        let bars: [(String, Double, Double, Double)] = [
            ("R",  0.75, 0,    0),
            ("Yl", 0.75, 0.75, 0),
            ("G",  0,    0.75, 0),
            ("Cy", 0,    0.75, 0.75),
            ("B",  0,    0,    0.75),
            ("Mg", 0.75, 0,    0.75)
        ]
        return bars.map { name, r, g, b in
            let y = lumaR * r + lumaG * g + lumaB * b
            let cb = (b - y) / cbScale
            let cr = (r - y) / crScale
            return VectorTarget(name: name, x: cb * vectorGain, y: -cr * vectorGain)
        }
    }

    /// The skin-tone ("I") line every colourist lines faces up against, as a compass angle in the
    /// scope's own coordinates: 123° counter-clockwise from the +Cb (right) axis.
    public static let skinToneAngleDegrees = 123.0

    // MARK: - Gamut boundary

    /// The gamut's edge on the vectorscope: its six fully-saturated primaries and secondaries, in
    /// the same scope coordinates the trace uses, ordered R→Yl→G→Cy→B→Mg so joining them (and
    /// closing back to the start) draws the boundary hexagon.
    ///
    /// Each vertex is that gamut's 100 % corner (e.g. its red primary) taken through the same path a
    /// pixel of it would travel to reach the scope: gamut linear RGB → sRGB linear (a 3×3 built from
    /// the gamut's primaries) → extended sRGB gamma → Rec.709 Cb/Cr. So sRGB's hexagon passes
    /// through where 100 % sRGB pixels land, and a wider gamut's corners fall outside it — the wider
    /// green especially — which is where a wide-gamut trace would reach.
    public static func gamutBoundary(_ gamut: ColorGamut) -> [ScopePoint] {
        let toSRGB = Colorimetry.gamutToSRGBLinear(gamut)
        let corners: [(Double, Double, Double)] = [
            (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 1, 1), (0, 0, 1), (1, 0, 1)
        ]
        return corners.map { corner in
            let lin = toSRGB.apply(corner)
            let r = Colorimetry.encodeSRGB(lin.0)
            let g = Colorimetry.encodeSRGB(lin.1)
            let b = Colorimetry.encodeSRGB(lin.2)
            let y = lumaR * r + lumaG * g + lumaB * b
            let cb = (b - y) / cbScale
            let cr = (r - y) / crScale
            return ScopePoint(x: cb * vectorGain, y: -cr * vectorGain)
        }
    }

    // MARK: - Shared

    private static func colourise(
        _ accum: [Double],
        width: Int, height: Int,
        gain: Double,
        tints: [(Double, Double, Double)]
    ) -> ScopeRaster {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            accum.withUnsafeBufferPointer { hits in
                for cell in 0..<(width * height) {
                    var r = background.r, g = background.g, b = background.b
                    for layer in 0..<3 {
                        let count = hits[cell * 3 + layer]
                        guard count > 0 else { continue }
                        let intensity = 1 - exp(-gain * count)
                        r += intensity * tints[layer].0
                        g += intensity * tints[layer].1
                        b += intensity * tints[layer].2
                    }
                    let o = cell * 4
                    out[o] = clampByte(r)
                    out[o + 1] = clampByte(g)
                    out[o + 2] = clampByte(b)
                    out[o + 3] = 255
                }
            }
        }
        return ScopeRaster(width: width, height: height, rgba: pixels)
    }

    private static func clampByte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 255))
    }

    private static func blank(width: Int, height: Int) -> ScopeRaster {
        let w = max(width, 1), h = max(height, 1)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for cell in 0..<(w * h) {
            pixels[cell * 4] = clampByte(background.r)
            pixels[cell * 4 + 1] = clampByte(background.g)
            pixels[cell * 4 + 2] = clampByte(background.b)
        }
        return ScopeRaster(width: w, height: h, rgba: pixels)
    }
}
