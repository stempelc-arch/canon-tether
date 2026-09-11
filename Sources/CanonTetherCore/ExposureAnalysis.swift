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

    /// How far off the exposure is, in thirds of a stop — derived from `median`, so a cached
    /// result carries it without re-reading pixels. Only meaningful alongside a non-`good`
    /// verdict; see `ExposureAnalyzer.offset`.
    public var offset: ExposureOffset { ExposureAnalyzer.offset(median: median) }

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

/// How far the exposure is off, in stops — the actionable form of a highlight/shadow warning, since
/// "overexposed" doesn't tell a photographer whether to pull a third of a stop or two stops.
public struct ExposureOffset: Equatable, Sendable {
    /// Positive = overexposed by this many stops (pull down); negative = underexposed (push up).
    /// Already quantised to thirds, matching how exposure is actually dialled on the camera.
    public let stops: Double
    /// True when clipping destroyed the data needed to measure exactly, so `stops` is a floor
    /// rather than a figure. Every pixel past the sensor's white point records the same value, so
    /// once a meaningful part of the frame is clipped there is no way to know how far past it went
    /// — the honest statement is "at least this much".
    public let isAtLeast: Bool

    /// Thirds of a stop, as a photographer reads them: "1⅓", "⅔", "2".
    public var label: String {
        let magnitude = abs(stops)
        let whole = Int(magnitude)
        let third = Int(((magnitude - Double(whole)) * 3).rounded())
        // A rounded-up third carries into the whole number (2 + 3/3 reads as 3).
        let carriedWhole = third == 3 ? whole + 1 : whole
        let fraction = third == 3 ? 0 : third
        let fractionText = ["", "⅓", "⅔"][fraction]
        if carriedWhole == 0 && fraction == 0 { return "0" }
        if carriedWhole == 0 { return fractionText }
        return fractionText.isEmpty ? "\(carriedWhole)" : "\(carriedWhole)\(fractionText)"
    }

    /// The phrase the badge and tooltip show, e.g. "1⅓ stops over" or "at least 2 stops over".
    public var summary: String {
        guard stops != 0 else { return "correctly exposed" }
        let direction = stops > 0 ? "over" : "under"
        let unit = abs(stops) == 1 ? "stop" : "stops"
        return "\(isAtLeast ? "at least " : "")\(label) \(unit) \(direction)"
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

    /// Luma [0,1] at a given percentile of the frame — the level below which `fraction` of pixels
    /// fall. Used to ask "how bright is the content that's blowing out", which is what turns a
    /// clipping warning into a stop count.
    static func percentileLevel(_ histogram: [Int], total: Int, fraction: Double) -> Double {
        guard total > 0, !histogram.isEmpty else { return 0 }
        let target = Int((Double(total) * fraction).rounded())
        var cumulative = 0
        for (bin, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= target { return Double(bin) / Double(histogram.count - 1) }
        }
        return 1
    }

    /// sRGB → linear light. Stops are ratios of *light*, and the frame is gamma-encoded, so
    /// measuring stops on the encoded values would overstate shadows and understate highlights.
    static func linearize(_ value: Double) -> Double {
        let v = min(max(value, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Mid-grey in linear light — the reference every reflected-light meter renders to, and the
    /// same one the camera's own meter uses.
    private static let middleGrey = 0.18

    /// How far `frame` is off, in thirds of a stop: the frame's overall brightness measured against
    /// a neutral mid-grey rendering, exactly as the camera's meter reads it.
    ///
    /// An earlier version tried to answer the more specific question a clipping warning raises —
    /// "how far do I pull to stop losing these highlights" — by measuring where the blown content
    /// sits. That cannot work, and the failure is physical rather than a bug: every pixel past the
    /// white point records the identical value, so once the highlights clip, *how far* past they
    /// went is unrecoverable. Measured against real tone curves it collapsed to "at least ⅓ stops"
    /// for everything from a ⅔-stop push to a two-stop one, which is worse than saying nothing.
    ///
    /// The median is always measurable and shifts stop-for-stop with exposure, so it recovers a
    /// mis-exposure faithfully. Its known limit is the one every reflected meter has: a deliberately
    /// low-key or high-key frame reads off-neutral because it *is* off-neutral. That's why this is
    /// only ever shown alongside a clipping verdict — it quantifies a warning the clipping already
    /// justified, rather than second-guessing an intentional look.
    public static func offset(median medianLevel: Double) -> ExposureOffset {
        guard medianLevel.isFinite else { return ExposureOffset(stops: 0, isAtLeast: false) }
        // A median pinned at either rail means more than half the frame is clipped; the true
        // brightness is past what was recorded, so the figure becomes a floor.
        let saturated = medianLevel >= 1 || medianLevel <= 0
        let floored = min(max(medianLevel, Double(1) / Double(histogramBins - 1)), 1)
        let stops = log2(linearize(floored) / middleGrey)
        return ExposureOffset(stops: quantiseToThirds(stops), isAtLeast: saturated)
    }

    /// Convenience for measuring a frame directly (tests, live view).
    public static func offset(_ frame: ScopeFrame) -> ExposureOffset {
        guard frame.isValid else { return ExposureOffset(stops: 0, isAtLeast: false) }
        return offset(median: measure(frame).median)
    }

    private static let oneThird = 1.0 / 3.0

    /// Exposure is dialled in thirds, so a reading of "0.41 stops" is noise dressed as precision.
    static func quantiseToThirds(_ stops: Double) -> Double {
        guard stops.isFinite else { return 0 }
        return (stops * 3).rounded() / 3
    }

    private static func histogramOf(_ frame: ScopeFrame) -> ([Int], Int) {
        var histogram = [Int](repeating: 0, count: histogramBins)
        let last = histogramBins - 1
        frame.rgba.withUnsafeBufferPointer { src in
            for p in stride(from: 0, to: frame.pixelCount * 4, by: 4) {
                let y = lumaR * Double(src[p]) + lumaG * Double(src[p + 1]) + lumaB * Double(src[p + 2])
                guard y.isFinite else { continue }
                histogram[Int(min(max(y, 0), 1) * Double(last))] += 1
            }
        }
        return (histogram, frame.pixelCount)
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

        // The stop figure is what makes a warning actionable — "overexposed" leaves the
        // photographer guessing between a third of a stop and two.
        let offset = result.offset
        let correction = offset.stops == 0 ? "" : " The frame reads \(offset.summary) overall."

        if blown && crushed {
            return "Overexposed and underexposed — \(highlightPhrase), and \(lo)% is crushed shadows (limit \(loLimit)%). High-contrast scene losing both ends, so no single exposure change fixes it."
        }
        if blown {
            return "Overexposed — \(highlightPhrase). That detail is gone for good, not recoverable by editing.\(correction)"
        }
        if crushed {
            return "Underexposed — \(lo)% of the frame is crushed shadows, past the \(loLimit)% limit. That detail is gone for good, not recoverable by editing.\(correction)"
        }
        switch result.verdict {
        case .over:
            return "Overexposed — no hard clipping, but the frame reads very bright overall (median \(med)%, \(offset.summary)). Likely a high-key look rather than blown detail; check it's intentional."
        case .under:
            return "Underexposed — no hard clipping, but the frame reads very dark overall (median \(med)%, \(offset.summary)). Likely a low-key look rather than lost detail; check it's intentional."
        case .good:
            return "Good exposure — highlights \(hi)% (limit \(hiLimit)%), near-white \(nw)% (limit \(nwLimit)%), shadows \(lo)% (limit \(loLimit)%), all within tolerance."
        }
    }

    private static func pct(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }
}
