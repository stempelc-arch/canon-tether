import Foundation

/// The three-band read the focus badge shows. Deliberately not a bare pass/fail: a middle
/// "borderline" band keeps the indicator honest about the shots the heuristic genuinely can't call.
/// The badge draws one constant focus glyph and colours it by verdict (green / amber / red), so the
/// symbol itself is a UI concern and lives there, not on this enum.
public enum FocusVerdict: String, Sendable {
    case sharp        // a clearly-focused region — green
    case borderline   // ambiguous — amber
    case soft         // no crisp detail anywhere — red

    public var label: String {
        switch self {
        case .sharp: return "In focus"
        case .borderline: return "Check focus"
        case .soft: return "Soft"
        }
    }
}

/// The outcome of a focus check on one capture: a 0–100 confidence score, the band it falls in, and
/// where in the frame the sharpest region sat (normalised [0, 1], x right / y down) so the UI can
/// point at it if it wants to.
public struct FocusResult: Equatable, Sendable {
    public let score: Int
    public let verdict: FocusVerdict
    public let peak: ScopePoint?

    public init(score: Int, verdict: FocusVerdict, peak: ScopePoint?) {
        self.score = score
        self.verdict = verdict
        self.peak = peak
    }

    /// Rebuilds a result from a cached score (read back from the file's xattr) without re-analysing
    /// the pixels — the peak location isn't cached, only the number that drives the badge.
    public init(cachedScore score: Int, sharpThreshold: Int, softThreshold: Int) {
        let clamped = min(max(score, 0), 100)
        self.init(score: clamped,
                  verdict: FocusAnalyzer.verdict(for: clamped, sharpThreshold: sharpThreshold, softThreshold: softThreshold),
                  peak: nil)
    }
}

/// Estimates how confidently a capture is in focus, from the same downsampled RGBA grid the scopes
/// measure (`ScopeFrame`). This is a **sharpness heuristic, not a truth**: it looks for crisp
/// high-frequency detail in the *sharpest region* of the frame, so a sharp subject on a soft,
/// shallow-DOF background reads as focused rather than being dragged down by the blurred backdrop.
/// It can't perfectly tell a missed-focus soft frame from an intentionally soft one, and motion blur
/// or a textureless subject can fool it — so the UI presents it as a confidence, with a middle
/// "borderline" band.
///
/// Foundation-only and side-effect-free, so it's exercised by a `swiftc` harness / XCTest the same
/// way `ScopeRenderer` is.
public enum FocusAnalyzer {
    /// Rec.709 luma weights (same grid the waveform/vectorscope use).
    private static let lumaR = 0.2126, lumaG = 0.7152, lumaB = 0.0722

    /// How many tiles across and down the frame is split into. The sharpness read is per-tile so a
    /// small in-focus subject stands out from a soft surround; finer than this and a single tile
    /// starts to be dominated by noise, coarser and a small subject gets averaged away.
    private static let tilesPerAxis = 12

    /// Fraction of the sharpest tiles averaged into the "peak" sharpness — the focused region.
    /// Small enough that a subject filling a fraction of the frame still carries the score, large
    /// enough that one noisy tile can't. Calibrated against real 1DX II files (2026-08-13,
    /// `Aug 13 Tests/`): 0.08 (≈12 of 144 tiles) diluted small in-frame subjects — a car-key-fob
    /// product shot and tight portraits against a plain backdrop, both visibly in focus, scored in
    /// the teens because the sharp region was a handful of tiles averaged against much larger soft
    /// surrounding tiles. 0.03 (≈4 tiles) tracks the true peak closer without going so tight that a
    /// single noisy tile dominates.
    private static let peakFraction = 0.03

    /// A near-black tile has a mean luminance near zero; this floor (in luma², luma ∈ [0, 1]) keeps
    /// the mean-normalised ratio from blowing up on such tiles, where the gradient is tiny anyway.
    private static let meanSquareFloor = 4.0e-3

    /// Maps the dimensionless peak-sharpness ratio onto the 0–100 score through
    /// `100 · peak / (peak + halfScore)`, so `halfScore` is the ratio that reads as 50. Calibrated so
    /// a crisply-focused, textured region lands in the 70–90s and a defocused frame in the teens–30s.
    /// It sets the *shape*; the sharp/soft cut-offs (a user preference) set where the bands fall, so
    /// this needn't be perfect — only monotonic, which it is by construction. Worth re-checking
    /// against real 1DX II files once the camera's on hand.
    private static let halfScoreRatio = 3.0

    /// Evaluates `frame`, bucketing the score with the caller's thresholds (a photographer
    /// preference, since the right cut-off shifts with lens and subject). `score >= sharpThreshold`
    /// is sharp, `< softThreshold` is soft, between is borderline.
    public static func evaluate(_ frame: ScopeFrame, sharpThreshold: Int, softThreshold: Int) -> FocusResult {
        let (peakSharpness, peak) = measure(frame)
        let score = min(max(Int((100 * peakSharpness / (peakSharpness + halfScoreRatio)).rounded()), 0), 100)
        return FocusResult(
            score: score,
            verdict: verdict(for: score, sharpThreshold: sharpThreshold, softThreshold: softThreshold),
            peak: peak
        )
    }

    /// The raw, unmapped read: the peak-region sharpness ratio and where that region sits. Split out
    /// so both `evaluate` and the calibration tests work off the same numbers.
    static func measure(_ frame: ScopeFrame) -> (sharpness: Double, peak: ScopePoint?) {
        guard frame.isValid, frame.width >= 3, frame.height >= 3 else { return (0, nil) }
        let w = frame.width, h = frame.height

        // 1. Luminance grid.
        var luma = [Double](repeating: 0, count: w * h)
        frame.rgba.withUnsafeBufferPointer { src in
            luma.withUnsafeMutableBufferPointer { out in
                for i in 0..<(w * h) {
                    let p = i * 4
                    out[i] = lumaR * Double(src[p]) + lumaG * Double(src[p + 1]) + lumaB * Double(src[p + 2])
                }
            }
        }

        // 2. Per-tile accumulation: squared Sobel gradient (sharp edges dominate — a monotonic
        //    transition's *summed* L1 gradient is blur-invariant, but the sum of *squares* isn't,
        //    which is what lets this separate crisp edges from soft ones), plus the luma sum so each
        //    tile's mean brightness is known for the normalisation.
        let tiles = tilesPerAxis
        var energy = [Double](repeating: 0, count: tiles * tiles)   // Σ(Gx²+Gy²)
        var sum = [Double](repeating: 0, count: tiles * tiles)      // Σ luma
        var count = [Double](repeating: 0, count: tiles * tiles)

        luma.withUnsafeBufferPointer { L in
            for y in 0..<h {
                let ty = min(y * tiles / h, tiles - 1)
                for x in 0..<w {
                    let tx = min(x * tiles / w, tiles - 1)
                    let cell = ty * tiles + tx
                    sum[cell] += L[y * w + x]
                    count[cell] += 1
                    // Sobel needs a full 3×3 neighbourhood; the one-pixel frame border is skipped.
                    guard x > 0, x < w - 1, y > 0, y < h - 1 else { continue }
                    let tl = L[(y - 1) * w + x - 1], tc = L[(y - 1) * w + x], tr = L[(y - 1) * w + x + 1]
                    let ml = L[y * w + x - 1],                                 mr = L[y * w + x + 1]
                    let bl = L[(y + 1) * w + x - 1], bc = L[(y + 1) * w + x], br = L[(y + 1) * w + x + 1]
                    let gx = (tr + 2 * mr + br) - (tl + 2 * ml + bl)
                    let gy = (bl + 2 * bc + br) - (tl + 2 * tc + tr)
                    energy[cell] += gx * gx + gy * gy
                }
            }
        }

        // 3. Per-tile sharpness = mean squared gradient ÷ mean-luma². Numerator and denominator both
        //    scale with the square of luma amplitude, so the ratio is exposure-invariant (a dim sharp
        //    shot reads as sharp as a bright one) — but, unlike dividing by *variance*, this keeps
        //    the sharp-vs-blur signal: a blur drops the gradient without touching the mean, so it
        //    lowers the ratio, which is exactly what we want to detect.
        var sharpness = [Double](repeating: 0, count: tiles * tiles)
        for cell in 0..<(tiles * tiles) {
            let n = count[cell]
            guard n > 0 else { continue }
            let mean = sum[cell] / n
            sharpness[cell] = (energy[cell] / n) / (mean * mean + meanSquareFloor)
        }

        // 4. Peak = mean of the sharpest handful of tiles (the focused region), and the single
        //    sharpest tile's centre as the peak location, in normalised [0, 1] frame coords.
        let ranked = sharpness.enumerated().sorted { $0.element > $1.element }
        let take = max(1, Int((Double(tiles * tiles) * peakFraction).rounded()))
        let top = ranked.prefix(take)
        let peakSharpness = top.reduce(0) { $0 + $1.element } / Double(top.count)
        let peak = ranked.first.map { first -> ScopePoint in
            let tx = first.offset % tiles, ty = first.offset / tiles
            return ScopePoint(x: (Double(tx) + 0.5) / Double(tiles),
                              y: (Double(ty) + 0.5) / Double(tiles))
        }
        return (peakSharpness, peak)
    }

    /// Buckets a score into a band. Kept separate so a cached score (no pixels) can be rebucketed
    /// when the photographer moves the threshold.
    public static func verdict(for score: Int, sharpThreshold: Int, softThreshold: Int) -> FocusVerdict {
        if score >= sharpThreshold { return .sharp }
        if score < softThreshold { return .soft }
        return .borderline
    }
}
