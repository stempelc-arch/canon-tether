import Foundation

/// A focus range measured the only way this camera permits: by **counting nudges**.
///
/// There is no focus-position property in Canon's PTP — see `FocusStep`. So a range cannot be
/// expressed in millimetres, in focus distance, or in anything absolute. What it *can* be expressed
/// in is the exact unit the bracket will later be shot in: a signed count of `manualfocusdrive`
/// nudges from wherever focus happened to be when ranging started. Mark the near end, rack while
/// the app counts, mark the far end, and the span is known precisely — because it is measured in
/// the same steps that will reproduce it.
///
/// The axis runs **positive away from the camera** (Canon's "Far"), matching how a stack is shot.
///
/// One hard constraint: a range is only valid for the **step magnitude it was measured with**.
/// Canon offers three nudge sizes and never says how they relate — "Near 2" is not documented as any
/// particular multiple of "Near 1", and it differs by lens. Counts of different magnitudes therefore
/// cannot be added together or converted, so changing the step size invalidates the marks rather
/// than silently rescaling them into a number that would look authoritative and be wrong.
public struct FocusRange: Equatable, Sendable {
    /// The nudge size every count here is expressed in.
    public let magnitude: Int
    /// Cursor position, in nudges from where ranging began. Positive is away from the camera.
    public var position: Int
    /// The marked ends, in the same units. Either may be unset while ranging is in progress.
    public var nearMark: Int?
    public var farMark: Int?

    public init(magnitude: Int, position: Int = 0, nearMark: Int? = nil, farMark: Int? = nil) {
        self.magnitude = Swift.min(Swift.max(magnitude, 1), 3)
        self.position = position
        self.nearMark = nearMark
        self.farMark = farMark
    }

    /// Distance between the marks, in nudges. Nil until both ends are marked.
    public var span: Int? {
        guard let nearMark, let farMark else { return nil }
        return abs(farMark - nearMark)
    }

    public var isComplete: Bool { span != nil }

    /// A marked range of zero nudges is a mistake, not a one-frame stack — both marks landed on the
    /// same spot, which means the rack never happened.
    public var isUsable: Bool { (span ?? 0) > 0 }

    public mutating func move(by nudges: Int) {
        position += nudges
    }

    public mutating func markNear() { nearMark = position }
    public mutating func markFar() { farMark = position }

    public mutating func clearMarks() {
        nearMark = nil
        farMark = nil
    }

    /// Nudges from the current position back to the near mark — where the bracket has to start.
    /// Positive means "drive away from the camera", negative "drive toward it".
    public func offsetToNearMark() -> Int? {
        guard let nearMark else { return nil }
        return nearMark - position
    }

    /// Whether this range can still be trusted for a plan using `magnitude`. See the type comment:
    /// counts measured at one nudge size mean nothing at another.
    public func isValid(forMagnitude other: Int) -> Bool { magnitude == other }
}

/// How tightly consecutive frames are spaced within a marked range.
///
/// This is deliberately **not** a percentage of depth of field. Nothing in this pipeline knows the
/// depth of field: it depends on aperture, focal length, subject distance and the lens's own focus
/// throw, and the camera reports none of it in a form that maps onto nudges. What the app does know
/// exactly is how many nudges sit between two frames, so that is what this sets — presented as a
/// tightness rather than a raw count, with the safest setting as the default.
public enum FocusOverlap: Int, CaseIterable, Identifiable, Sendable {
    case maximum = 1   // a frame at every single nudge
    case tight = 2
    case moderate = 3
    case loose = 4

    public var id: Int { rawValue }

    /// Nudges between consecutive frames.
    public var stepsPerFrame: Int { rawValue }

    public var label: String {
        switch self {
        case .maximum: return "Maximum"
        case .tight: return "Tight"
        case .moderate: return "Moderate"
        case .loose: return "Loose"
        }
    }

    public var detail: String {
        switch self {
        case .maximum: return "A frame at every step — most frames, safest coverage."
        case .tight: return "A frame every 2 steps."
        case .moderate: return "A frame every 3 steps."
        case .loose: return "A frame every 4 steps — fewest frames, risks gaps."
        }
    }

    /// Defaults to the safest setting. A stack with gaps cannot be fixed afterwards — the missing
    /// focus was never recorded — whereas extra frames only cost time and disk, so the conservative
    /// choice is the right default even though it shoots more.
    public static let `default` = FocusOverlap.maximum

    /// The tightest spacing that covers `span` without exceeding what one bracket can hold.
    ///
    /// Chosen rather than asked. Overlap is a trade the app can make better than a person can: the
    /// only reason not to shoot every step is the frame limit, so take the finest spacing that
    /// fits. Falls back to the loosest if even that overruns, which the caller surfaces as a
    /// warning rather than silently truncating the range.
    public static func tightestThatFits(span: Int) -> FocusOverlap {
        for option in allCases where !FocusRangePlanner.exceedsFrameLimit(span: span, stepsPerFrame: option.stepsPerFrame) {
            return option
        }
        return .loose
    }
}

/// Turns a marked range plus an overlap setting into the bracket that covers it.
public enum FocusRangePlanner {
    /// Frames needed to walk `span` nudges in `stepsPerFrame`-sized strides, inclusive of both ends.
    /// Rounded **up**, so a span that doesn't divide evenly is over-covered rather than stopping
    /// short of the far mark — a bracket that ends early leaves the back of the subject soft.
    public static func frameCount(span: Int, stepsPerFrame: Int) -> Int {
        guard span > 0, stepsPerFrame > 0 else { return 2 }
        let strides = Int((Double(span) / Double(stepsPerFrame)).rounded(.up))
        return Swift.min(Swift.max(strides + 1, 2), FocusStackPlan.frameRange.upperBound)
    }

    /// Which end of a marked range a bracket should start from, given where focus is now.
    ///
    /// Whichever end is nearer. The scan leaves focus at one extreme of the range it just measured,
    /// so insisting the bracket always run near → far means walking the whole span back before
    /// shooting a single frame — tens of seconds of travel for nothing. A stack is order-agnostic:
    /// the merge aligns each frame to its neighbour, and neighbours are neighbours either way.
    public static func startEnd(for range: FocusRange) -> (start: Int, towardCamera: Bool)? {
        guard range.isUsable, let near = range.nearMark, let far = range.farMark else { return nil }
        let lowEnd = Swift.min(near, far), highEnd = Swift.max(near, far)
        let fromLow = abs(range.position - lowEnd), fromHigh = abs(range.position - highEnd)
        // Starting at the high end means stepping back toward the camera, and vice versa.
        return fromHigh < fromLow ? (highEnd, true) : (lowEnd, false)
    }

    /// Builds the plan for a completed range, running from whichever end focus is nearest.
    public static func plan(for range: FocusRange,
                            overlap: FocusOverlap,
                            settleSeconds: Double,
                            returnToStart: Bool) -> FocusStackPlan? {
        guard range.isUsable, let span = range.span, let end = startEnd(for: range) else { return nil }
        return FocusStackPlan(
            frameCount: frameCount(span: span, stepsPerFrame: overlap.stepsPerFrame),
            step: FocusStep.step(towardCamera: end.towardCamera, magnitude: range.magnitude),
            stepsPerFrame: overlap.stepsPerFrame,
            settleSeconds: settleSeconds,
            returnToStart: returnToStart
        )
    }

    /// Whether the plan would hit the frame cap and so **not** reach the far mark. Worth saying out
    /// loud: silently truncating a range the photographer explicitly marked is the kind of failure
    /// that only shows up in the merge.
    public static func exceedsFrameLimit(span: Int, stepsPerFrame: Int) -> Bool {
        guard span > 0, stepsPerFrame > 0 else { return false }
        return Int((Double(span) / Double(stepsPerFrame)).rounded(.up)) + 1
            > FocusStackPlan.frameRange.upperBound
    }
}

/// One sample from the auto-find scan: a cursor position and how sharp the live view looked there.
public struct FocusScanSample: Equatable, Sendable {
    public let position: Int
    public let score: Int

    public init(position: Int, score: Int) {
        self.position = position
        self.score = score
    }
}

/// Reads a focus scan back into a suggested range.
///
/// The scan drives focus across a window, scoring each stop with the same sharpness heuristic the
/// focus badge uses (`FocusAnalyzer`). Where the subject is in focus, some region of the frame is
/// crisp and the score is high; past both ends of the subject nothing is crisp and it falls away.
/// The range is the run of positions whose score clears a fraction of the scan's own peak —
/// **relative**, not absolute, because the peak score depends entirely on how much texture the
/// subject has, and a fixed threshold would find nothing on a smooth subject and everything on a
/// detailed one.
public enum FocusScanReader {
    /// Fraction of the peak-above-floor a position must clear to count as "the subject is sharp
    /// here". Measured against recorded focus maps: 0.25 recovers a subject's true extent, while
    /// the 0.6 this started at cut the range down to a few steps.
    public static let thresholdFraction = 0.25

    /// How many consecutive below-threshold steps may sit *inside* a range without ending it.
    ///
    /// This is the fix for the defect that made auto-find useless. A real subject is several
    /// surfaces at different depths, so its sharpness curve dips between them — and the original
    /// "walk outward from the peak until something falls below threshold" stopped at the first dip.
    /// Replayed against a recorded map of a subject spanning 24 steps, that returned a span of
    /// **zero**; allowing short dips returns the true extent.
    ///
    /// Erring toward inclusion is deliberate. Extra frames cost time; a gap in a stack cannot be
    /// fixed afterwards because the missing focus was never recorded.
    public static let gapTolerance = 4

    /// A scan that never rises must not be read as a range. If the best and worst positions are
    /// this close, the scan saw no focus transition at all: a textureless subject, a dark frame, or
    /// a lens that never moved. Suggesting a range from that is worse than admitting nothing.
    public static let minimumContrast = 8

    public struct Suggestion: Equatable, Sendable {
        public let nearMark: Int
        public let farMark: Int
        public let peakPosition: Int
        /// True when the sharp run reaches an end of the scanned window — the subject probably
        /// extends past where the scan looked, so the range is a floor, not the whole subject.
        public let clippedAtEdge: Bool
    }

    public static func read(_ samples: [FocusScanSample]) -> Suggestion? {
        guard samples.count >= 3 else { return nil }
        let ordered = samples.sorted { $0.position < $1.position }
        guard let peak = ordered.max(by: { $0.score < $1.score }),
              let trough = ordered.min(by: { $0.score < $1.score }) else { return nil }
        guard peak.score - trough.score >= minimumContrast else { return nil }

        let threshold = Double(trough.score) + Double(peak.score - trough.score) * thresholdFraction
        let above = ordered.filter { Double($0.score) >= threshold }
        guard let first = above.first else { return nil }

        // Group the above-threshold positions into runs, letting a run survive short dips, then
        // take the run holding the peak — the subject — rather than merely the longest, so a
        // separate object elsewhere in the frame cannot claim the range.
        var runs: [(start: Int, end: Int)] = []
        var runStart = first.position
        var previous = first.position
        for sample in above.dropFirst() {
            if sample.position - previous > gapTolerance + 1 {
                runs.append((runStart, previous))
                runStart = sample.position
            }
            previous = sample.position
        }
        runs.append((runStart, previous))

        let chosen = runs.first { $0.start <= peak.position && peak.position <= $0.end }
            ?? runs.max { ($0.end - $0.start) < ($1.end - $1.start) }
        guard let chosen else { return nil }

        return Suggestion(nearMark: chosen.start,
                          farMark: chosen.end,
                          peakPosition: peak.position,
                          clippedAtEdge: chosen.start == ordered.first!.position
                              || chosen.end == ordered.last!.position)
    }
}
