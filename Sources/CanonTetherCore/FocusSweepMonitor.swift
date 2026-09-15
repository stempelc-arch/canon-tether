import Foundation

/// Decides when a focus sweep has seen enough and may stop.
///
/// Extracted from `GPhotoSession.scanFocus` so it can be tested without a camera. Every rule here
/// has misfired on real hardware at least once, and each time the only way to find out was to shoot
/// a sweep and read the log — a round trip of minutes per attempt, on a body that cannot be shared
/// with a second process. The logic is pure and sample-driven so a recorded sweep can be replayed
/// through it in milliseconds instead.
///
/// The monitor never drives focus and never reads a camera: it is fed one observation per sample
/// and answers whether to keep going.
public struct FocusSweepMonitor {

    /// Why a sweep stopped. Distinguishing these matters — "the lens ran out of travel" and "the
    /// subject has been measured" call for different follow-up, and conflating them once produced a
    /// 12-step range for a subject that ran much further.
    public enum Stop: Equatable {
        /// The picture stopped changing: the lens is against a stop.
        case endOfTravel
        /// The subject has peaked, fallen away, and nothing is still sharpening.
        case measured
    }

    // MARK: Calibration

    /// Fraction of the peak below which the aggregate counts as having fallen away.
    public static let falloffFraction = 0.7
    /// Consecutive fallen-away samples that end a sweep.
    public static let falloffSamples = 3
    /// Consecutive unchanged frames that mean the lens is against a stop.
    ///
    /// Much larger than `falloffSamples`, and deliberately so. A *defocused* subject also barely
    /// changes between two focus steps, so a short run of near-identical frames is the ordinary
    /// look of the blurred end of a sweep, not an end of travel. At three, real sweeps aborted four
    /// samples in and reported a well-textured subject as having no usable tiles at all.
    public static let endOfTravelSamples = 8
    /// A sweep may not stop itself before this many samples, whatever else it thinks.
    public static let minimumSamples = 12
    /// Share of the judged tiles that must reach a new best for the scene to count as still
    /// sharpening.
    ///
    /// A *fraction*, not the fixed count of 3 it replaced. Replayed against a recorded sweep, the
    /// improving-tile count inside a 306-tile box decays from 306 to about 14 by the point the
    /// subject ends — and then flickers between 3 and 11 for the rest of the travel, as individual
    /// tiles beat their own previous best by the 5% margin on noise alone. A fixed floor of 3 is
    /// cleared by that flicker at almost every sample, so the sweep extended to +145 for a subject
    /// that ended at +46: 190 steps and 96 samples where 88 steps and 45 would have done.
    ///
    /// 3% of the judged tiles sits above the flicker and below the real signal.
    public static let improvingTileFraction = 0.03
    /// Never fewer than this, however small the box.
    public static let improvingTileMinimum = 3
    /// How much a tile must beat its own best by to count as improving, rather than as noise.
    public static let improvementRatio = 1.05

    // MARK: State

    /// Aggregate sharpness at each sampled offset, in sample order.
    public private(set) var readings: [(offset: Int, value: Double)] = []
    /// Whether the most recent sample brought new parts of the scene into focus.
    public private(set) var stillImproving = false
    /// Whether the picture has stopped changing — the lens is against a stop.
    ///
    /// Exposed because the caller must not extend a sweep that has run out of travel: extending
    /// further only re-photographs the same frame.
    public var isAtEndOfTravel: Bool {
        hasMoved && identicalFrames >= Self.endOfTravelSamples
    }

    /// The subject box, if one was drawn — in normalised frame coordinates.
    private let region: FocusDepthMap.Region?
    private var peakValue = 0.0
    private var samplesPastPeak = 0
    private var tileBest: [Double] = []
    private var samplesWithoutImprovement = 0
    private var identicalFrames = 0
    private var hasMoved = false

    /// - Parameter region: the subject box. **Every stage must agree on the coordinate space**:
    ///   the depth map honours this box, so the sweep's stop rules must too. Judging improvement
    ///   over the whole frame meant that as focus racked past the subject, the *background* came
    ///   into focus, the sweep read that as "the subject is still sharpening", and kept extending.
    ///   Measured on a real run: 190 steps of travel and 96 samples for a subject that occupied 80
    ///   steps and 40 of them — 59% of the sweep spent photographing past where it needed to look.
    public init(region: FocusDepthMap.Region? = nil) {
        self.region = region
    }

    /// Whether a tile on the `grid` lattice lies inside the subject box.
    private func isInsideRegion(row: Int, column: Int, grid: Int) -> Bool {
        guard let region else {
            // No box: the middle of the frame, as before. The edges are excluded for the same
            // reason the depth map excludes them — a distant corner coming into focus is not the
            // subject.
            return row >= grid / 4 && row < grid - grid / 4
                && column >= grid / 4 && column < grid - grid / 4
        }
        // The depth map's own containment test, so the two cannot drift apart.
        return region.contains(column: column, row: row)
    }

    /// Records one sample and says whether the sweep should continue.
    ///
    /// - Parameters:
    ///   - offset: where focus is, in nudges from the sweep's start.
    ///   - tiles: per-tile sharpness over the whole frame, row-major on a `grid` × `grid` lattice.
    ///   - unchanged: whether this frame is indistinguishable from the one before it. `nil` for the
    ///     first sample, or whenever the comparison could not be made — an unmeasurable frame counts
    ///     as *changed*, because a false end-of-travel truncates the sweep while a false "moved"
    ///     merely costs a sample.
    /// - Returns: `nil` to keep sweeping, or why it should stop.
    public mutating func record(offset: Int, tiles: [Double], unchanged: Bool?) -> Stop? {
        // Aggregate over the middle of the frame. The edges are excluded for the same reason the
        // depth map excludes them: a distant corner coming into focus is not the subject.
        let grid = FocusDepthMap.grid
        var total = 0.0
        var inRegion: [Int] = []
        if tiles.count == grid * grid {
            for row in 0..<grid {
                for column in 0..<grid where isInsideRegion(row: row, column: column, grid: grid) {
                    total += tiles[row * grid + column]
                    inRegion.append(row * grid + column)
                }
            }
        } else {
            total = tiles.reduce(0, +)
            inRegion = Array(0..<tiles.count)
        }
        readings.append((offset, total))

        if total > peakValue {
            peakValue = total
            samplesPastPeak = 0
        } else if total < peakValue * Self.falloffFraction {
            samplesPastPeak += 1
        } else {
            samplesPastPeak = 0
        }

        // How many tiles just reached a new best?
        //
        // Aggregate sharpness alone is not enough to stop on: it is dominated by whatever is
        // brightest and most textured, and a real sweep ended while nine tiles were still improving
        // — the range came out 12 steps wide for a subject that plainly ran further, and the far end
        // of the stack was soft. A part of the scene still sharpening is a part not yet measured.
        // Counted over the subject only, for the reason given on `init(region:)`.
        if tileBest.count != tiles.count { tileBest = [Double](repeating: 0, count: tiles.count) }
        var improved = 0
        for index in inRegion where tiles[index] > tileBest[index] * Self.improvementRatio {
            tileBest[index] = tiles[index]
            improved += 1
        }
        let floor = Swift.max(Self.improvingTileMinimum,
                              Int(Double(inRegion.count) * Self.improvingTileFraction))
        stillImproving = improved > floor
        samplesWithoutImprovement = stillImproving ? 0 : samplesWithoutImprovement + 1

        // End of travel, guarded twice over.
        //
        // The sweep *opens* by driving into the near stop, so its first frames are identical by
        // design; reading that as travel exhausted stopped a sweep after four samples. Requiring
        // movement first was still not enough, because the blurred end of a sweep holds steady too
        // — hence also a minimum length before the sweep is allowed to stop itself.
        if unchanged == true {
            identicalFrames += 1
            if hasMoved, readings.count >= Self.minimumSamples,
               identicalFrames >= Self.endOfTravelSamples {
                return .endOfTravel
            }
        } else if unchanged == false {
            identicalFrames = 0
            hasMoved = true
        }

        if readings.count >= Self.minimumSamples,
           samplesPastPeak >= Self.falloffSamples,
           samplesWithoutImprovement >= Self.falloffSamples {
            return .measured
        }
        return nil
    }
}
