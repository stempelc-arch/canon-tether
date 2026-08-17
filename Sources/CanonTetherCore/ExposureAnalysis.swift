import Foundation

/// The exposure read the badge shows. Directional, because exposure fails two ways: too dark or too
/// bright. `good` is green; `under`/`over` are the red states, with the badge adding a ↓/↑ so the
/// photographer knows which way to correct. The glyph is a UI concern (drawn constant, tinted by
/// verdict), so it lives there, not on this enum.
public enum ExposureVerdict: String, Sendable {
    case good
    case under
    case over

    public var label: String {
        switch self {
        case .good: return "Good exposure"
        case .under: return "Underexposed"
        case .over: return "Overexposed"
        }
    }
}

/// The outcome of an exposure check: the verdict plus the three raw readings behind it, so the
/// tooltip can explain *why* and — like the focus score — a cached result can be re-bucketed against
/// new thresholds without re-reading the pixels.
public struct ExposureResult: Equatable, Sendable {
    /// Fraction of pixels [0, 1] blown at the highlight end (unrecoverable white).
    public let highlightClip: Double
    /// Fraction of pixels [0, 1] crushed at the shadow end (unrecoverable black).
    public let shadowClip: Double
    /// Fraction of pixels [0, 1] that are washed-out near-white — bright enough to have lost most of
    /// their texture/colour even though they haven't hit the hard clip cutoff `highlightClip` counts.
    /// A blown sky or backdrop routinely sits in the low-90s% luma without ever touching 98%, so this
    /// is what actually catches that case; `highlightClip` alone misses it. See
    /// `ShotAnalysisStore`'s calibration note.
    public let nearWhite: Double
    /// Median luminance [0, 1] — the overall brightness, robust to a few bright/dark outliers.
    public let median: Double
    public let verdict: ExposureVerdict

    public init(highlightClip: Double, shadowClip: Double, nearWhite: Double, median: Double, verdict: ExposureVerdict) {
        self.highlightClip = highlightClip
        self.shadowClip = shadowClip
        self.nearWhite = nearWhite
        self.median = median
        self.verdict = verdict
    }

    /// Rebuilds a result from the four cached readings (read back from the file's xattr) and the
    /// current thresholds — no pixels needed.
    public init(cachedHighlightClip highlightClip: Double, shadowClip: Double, nearWhite: Double, median: Double,
                highlightClipLimit: Double, shadowClipLimit: Double, nearWhiteLimit: Double) {
        self.init(highlightClip: highlightClip, shadowClip: shadowClip, nearWhite: nearWhite, median: median,
                  verdict: ExposureAnalyzer.verdict(highlightClip: highlightClip, shadowClip: shadowClip,
                                                    nearWhite: nearWhite, median: median,
                                                    highlightClipLimit: highlightClipLimit,
                                                    shadowClipLimit: shadowClipLimit,
                                                    nearWhiteLimit: nearWhiteLimit))
    }
}

/// Estimates whether a capture is well exposed, from the same downsampled RGBA grid the scopes and
/// focus check measure (`ScopeFrame`). Unlike focus this isn't a heuristic guess: clipped pixels are
/// objectively lost data, and the median is a plain brightness read. What's a *tolerable* amount of
/// clipping is a taste call, hence the tunable highlight/shadow clip limits. Foundation-only and
/// side-effect-free, so it's exercised by a `swiftc` harness / XCTest the same way `ScopeRenderer`
/// and `FocusAnalyzer` are.
public enum ExposureAnalyzer {
    /// Rec.709 luma weights (same grid the waveform/vectorscope/focus use).
    private static let lumaR = 0.2126, lumaG = 0.7152, lumaB = 0.0722

    /// A pixel at or above this luma counts as a blown highlight; at or below the other, a crushed
    /// shadow. Just inside the rails so genuinely clipped content is caught without flagging the
    /// merely-bright.
    private static let highlightLevel = 0.98
    private static let shadowLevel = 0.02
    /// The softer near-white band `nearWhite` measures: bright enough that fabric/sky/skin has
    /// visibly lost texture, well below the hard `highlightLevel` clip cutoff. Calibrated 2026-08-13
    /// (see `ShotAnalysisStore`) against real files — a genuinely washed-out sky sits in the low-90s%
    /// luma across a large chunk of the frame without ever reaching 98%, so a clip-only check misses
    /// it entirely.
    private static let nearWhiteLevel = 0.93

    /// Brightness fallback: only when clipping is within tolerance does the median get a vote, and
    /// only at these extremes — so a legitimately low-key or high-key frame isn't nagged, but a badly
    /// mis-set exposure that somehow avoids hard clipping is still caught.
    private static let darkMedian = 0.10
    private static let brightMedian = 0.90

    private static let histogramBins = 256

    /// Evaluates `frame`, bucketing with the caller's clip tolerances. Highlight and shadow get
    /// separate tolerances (not one shared `clipLimit`) because blown highlights read as a much more
    /// visible mistake at the same clip fraction than crushed shadows do — a dark, moody backdrop
    /// crushing to black is often the deliberate look, but fabric or skin blowing out never is. See
    /// `ShotAnalysisStore`'s calibration note for the real-file evidence behind the asymmetry.
    public static func evaluate(_ frame: ScopeFrame, highlightClipLimit: Double, shadowClipLimit: Double,
                                 nearWhiteLimit: Double) -> ExposureResult {
        let (highlightClip, shadowClip, nearWhite, median) = measure(frame)
        return ExposureResult(highlightClip: highlightClip, shadowClip: shadowClip, nearWhite: nearWhite, median: median,
                              verdict: verdict(highlightClip: highlightClip, shadowClip: shadowClip,
                                               nearWhite: nearWhite, median: median,
                                               highlightClipLimit: highlightClipLimit,
                                               shadowClipLimit: shadowClipLimit,
                                               nearWhiteLimit: nearWhiteLimit))
    }

    /// The raw readings: highlight-clip fraction, shadow-clip fraction, near-white fraction, and
    /// median luminance. Split out so `evaluate`, the cache, and the calibration tests all work off
    /// the same numbers.
    static func measure(_ frame: ScopeFrame) -> (highlightClip: Double, shadowClip: Double, nearWhite: Double, median: Double) {
        guard frame.isValid else { return (0, 0, 0, 0) }
        let bins = histogramBins
        var histogram = [Int](repeating: 0, count: bins)
        let last = bins - 1

        frame.rgba.withUnsafeBufferPointer { src in
            for p in stride(from: 0, to: frame.pixelCount * 4, by: 4) {
                let y = lumaR * Double(src[p]) + lumaG * Double(src[p + 1]) + lumaB * Double(src[p + 2])
                // Extended-range values (wide gamut) can land outside [0, 1]; clamp into the rails,
                // which is the honest read for exposure — anything past 1 is blown either way.
                // Clamp BEFORE the Int conversion: Int(NaN) and Int(huge) both trap, so a single
                // corrupt pixel would otherwise crash the app mid-shoot.
                guard y.isFinite else { continue }
                let bin = Int(min(max(y, 0), 1) * Double(last))
                histogram[bin] += 1
            }
        }

        let total = frame.pixelCount
        guard total > 0 else { return (0, 0, 0, 0) }

        let highlightCutoff = Int(highlightLevel * Double(last))
        let nearWhiteCutoff = Int(nearWhiteLevel * Double(last))
        let shadowCutoff = Int(shadowLevel * Double(last))
        var highlightCount = 0, nearWhiteCount = 0, shadowCount = 0
        for bin in highlightCutoff...last { highlightCount += histogram[bin] }
        for bin in nearWhiteCutoff...last { nearWhiteCount += histogram[bin] }
        for bin in 0...shadowCutoff { shadowCount += histogram[bin] }

        // Median: walk the histogram to the half-count point.
        var cumulative = 0, medianBin = 0
        let half = total / 2
        for bin in 0..<bins {
            cumulative += histogram[bin]
            if cumulative >= half { medianBin = bin; break }
        }

        return (Double(highlightCount) / Double(total),
                Double(shadowCount) / Double(total),
                Double(nearWhiteCount) / Double(total),
                Double(medianBin) / Double(last))
    }

    /// Buckets the raw readings into a verdict. Clipping is the primary signal (it's lost data);
    /// brightness only gets a vote when clipping is within tolerance. Kept separate so a cached
    /// result can be re-bucketed when the photographer moves the tolerance.
    public static func verdict(highlightClip: Double, shadowClip: Double, nearWhite: Double, median: Double,
                                highlightClipLimit: Double, shadowClipLimit: Double, nearWhiteLimit: Double) -> ExposureVerdict {
        let blown = highlightClip > highlightClipLimit || nearWhite > nearWhiteLimit
        let crushed = shadowClip > shadowClipLimit
        if blown && crushed {
            // High-contrast frame losing both ends; flag whichever is worse *relative to its own
            // tolerance* (the limits differ, so comparing raw fractions would unfairly favour
            // the side with the looser limit).
            let highlightSeverity = max(highlightClip / highlightClipLimit, nearWhite / nearWhiteLimit)
            return highlightSeverity >= shadowClip / shadowClipLimit ? .over : .under
        }
        if blown { return .over }
        if crushed { return .under }
        if median > brightMedian { return .over }
        if median < darkMedian { return .under }
        return .good
    }
}

/// Builds the full-sentence explanation behind an exposure verdict — not just "Overexposed" but
/// *how much* and *why*, so the photographer can judge whether it's worth a second look rather than
/// trusting the badge blind. Shared by every place `ExposureResult` shows a tooltip.
public enum ExposureExplanation {
    public static func text(for result: ExposureResult, highlightClipLimit: Double, shadowClipLimit: Double,
                             nearWhiteLimit: Double) -> String {
        let hi = pct(result.highlightClip), lo = pct(result.shadowClip), nw = pct(result.nearWhite), med = pct(result.median)
        let hiLimit = pct(highlightClipLimit), loLimit = pct(shadowClipLimit), nwLimit = pct(nearWhiteLimit)
        let hardBlown = result.highlightClip > highlightClipLimit
        let washedOut = result.nearWhite > nearWhiteLimit
        let blown = hardBlown || washedOut
        let crushed = result.shadowClip > shadowClipLimit

        // A broad washed-out sky/backdrop and a small hard-clipped hotspot read as different mistakes
        // to a photographer, so they get different wording even though both mean "overexposed".
        let highlightPhrase: String
        if hardBlown && washedOut {
            highlightPhrase = "\(hi)% of the frame is fully blown out (limit \(hiLimit)%), and \(nw)% is washed-out near-white (limit \(nwLimit)%)"
        } else if hardBlown {
            highlightPhrase = "\(hi)% of the frame is fully blown out, past the \(hiLimit)% limit"
        } else {
            highlightPhrase = "\(nw)% of the frame is washed-out near-white, past the \(nwLimit)% limit — a hazy sky or hot backdrop, even though only \(hi)% is fully clipped"
        }

        if blown && crushed {
            return "Overexposed and underexposed — \(highlightPhrase), and \(lo)% is crushed shadows (limit \(loLimit)%). High-contrast scene losing both ends."
        }
        if blown {
            return "Overexposed — \(highlightPhrase). That detail is gone for good, not recoverable by editing."
        }
        if crushed {
            return "Underexposed — \(lo)% of the frame is crushed shadows, past the \(loLimit)% limit. That detail is gone for good, not recoverable by editing."
        }
        switch result.verdict {
        case .over:
            return "Overexposed — no hard clipping, but the frame reads very bright overall (median \(med)%). Likely a high-key look rather than blown detail; check it's intentional."
        case .under:
            return "Underexposed — no hard clipping, but the frame reads very dark overall (median \(med)%). Likely a low-key look rather than lost detail; check it's intentional."
        case .good:
            return "Good exposure — highlights \(hi)% (limit \(hiLimit)%), near-white \(nw)% (limit \(nwLimit)%), shadows \(lo)% (limit \(loLimit)%), all within tolerance."
        }
    }

    private static func pct(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }
}
