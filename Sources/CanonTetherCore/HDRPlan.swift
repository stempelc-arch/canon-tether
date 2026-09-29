import Foundation

/// How wide to bracket, and which shutter speeds that means on this body.
public struct HDRPlan: Equatable, Sendable {

    /// Stops either side of the metered exposure.
    public enum Spread: Int, CaseIterable, Identifiable, Sendable {
        /// The everyday case: recovers a bright sky or a lit window while keeping the frames close
        /// enough that every tone is well exposed in at least two of them.
        case twoStops = 2
        /// For genuinely harsh light — a dim interior against a bright window. Viable only because
        /// these are RAW: each frame carries enough range that a four-stop gap still overlaps.
        case fourStops = 4

        public var id: Int { rawValue }
        public var label: String { "±\(rawValue) stops" }
    }

    public var spread: Spread

    public init(spread: Spread = .twoStops) {
        self.spread = spread
    }

    /// Exposure offsets to shoot, in stops from the metered exposure, darkest first.
    ///
    /// Three frames, not five. The extra range a bracket buys comes from its *width*, and two more
    /// frames inside the same width buy overlap that the merge's weighting already handles — at the
    /// cost of two more RAW downloads and two more chances for something in the scene to move.
    /// Shot darkest first so the frame most likely to matter — the one holding the highlights —
    /// is captured before anything drifts.
    public var offsets: [Int] { [-spread.rawValue, 0, spread.rawValue] }

    /// Index of the metered frame, which the merge anchors the result to.
    public var referenceIndex: Int { offsets.firstIndex(of: 0) ?? 0 }

    public var frameCount: Int { offsets.count }

    // MARK: - Turning offsets into shutter speeds

    /// Picks the shutter speed `stops` away from `current`, from the list the body actually offers.
    ///
    /// **Shutter, never aperture or ISO.** Aperture would change depth of field between frames and
    /// the merge would blend differently-focused images; ISO would change the noise floor, which is
    /// the very thing the bracket is trying to improve. Only shutter changes exposure and nothing
    /// else — apart from motion blur, which is why a tripod is assumed.
    ///
    /// Returns `nil` when the body cannot go that far: at the ends of its shutter range the
    /// requested exposure does not exist, and a bracket quietly shot at the wrong offsets is worse
    /// than one that says it cannot.
    public static func shutter(stopsFrom current: String, stops: Int, in choices: [String]) -> String? {
        guard let currentStops = ExposureGrid.stops(of: current, path: ExposureGrid.shutterPath) else {
            return nil
        }
        // Mind the sign. `ExposureGrid.stops` measures shutter as `-log2(seconds)`, so its scale
        // *rises* as the shutter gets faster — that is, as the frame gets darker. An exposure offset
        // of +1 stop (more light) is therefore a step of -1 on that scale. Getting this backwards
        // silently shoots the bracket inside out: the "brighter" frame is the darker one, the merge
        // still runs, and the result quietly loses the range it was supposed to gain.
        let target = currentStops - Double(stops)
        var best: (choice: String, distance: Double)?
        for choice in choices {
            guard let value = ExposureGrid.stops(of: choice, path: ExposureGrid.shutterPath) else { continue }
            let distance = abs(value - target)
            if best == nil || distance < best!.distance { best = (choice, distance) }
        }
        // Within a third of a stop of what was asked for. Further than that and the bracket is not
        // the bracket the photographer chose — better to refuse and say the body ran out of range.
        guard let best, best.distance <= 0.34 else { return nil }
        return best.choice
    }

    /// The shutter speeds for the whole bracket, or `nil` if any offset is out of the body's reach.
    public func shutterSpeeds(metered: String, choices: [String]) -> [String]? {
        let speeds = offsets.map { Self.shutter(stopsFrom: metered, stops: $0, in: choices) }
        guard speeds.allSatisfy({ $0 != nil }) else { return nil }
        return speeds.map { $0! }
    }

    /// Plain description of what the bracket will do, for the panel.
    public func summary(metered: String?) -> String {
        let range = "\(offsets.count) frames, \(spread.label)"
        guard let metered else { return range }
        return "\(range) around \(metered)"
    }
}
