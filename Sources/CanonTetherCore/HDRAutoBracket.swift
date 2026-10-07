import Foundation

/// Decides how many exposures a scene needs, and where they go, by measuring rather than guessing.
///
/// A fixed ±2 or ±4 is a guess about a scene nobody has looked at yet: it over-shoots an evenly-lit
/// subject and falls short of a window in a dark room. This walks outward from the metered exposure
/// and stops when the frames in hand actually cover the scene — nothing important still clipping at
/// the dark end, nothing important still buried in noise at the bright end.
///
/// The measurement is deliberately about *coverage*, not about aesthetics. A frame is doing its job
/// when the merge has usable data for every part of the picture; how that data is then rendered is
/// `HDRToneCurve`'s problem.
public enum HDRAutoBracket {

    /// What one exposure managed to record.
    public struct Coverage: Equatable, Sendable {
        /// Fraction of pixels at or above this frame's white point — detail it could not hold.
        public let clipped: Double
        /// Fraction of pixels down in the noise, where the merge has nothing worth using.
        public let crushed: Double

        public init(clipped: Double, crushed: Double) {
            self.clipped = clipped
            self.crushed = crushed
        }
    }

    /// Below this fraction of clipped pixels, the highlights are covered.
    ///
    /// Not zero. A specular reflection off metal or glass has no detail to recover at any exposure,
    /// and chasing it would add frames forever — measured on a real window scene, driving clipping
    /// to zero would have meant four more exposures that recorded nothing but a darker glint.
    public static let clippedTarget = 0.001

    /// Below this fraction of crushed pixels, the shadows are covered.
    ///
    /// Looser than the highlight target, because deep shadow is often *meant* to be black. The cost
    /// of an unnecessary bright frame is a few seconds; the cost of a missing one is a noisy floor
    /// that cannot be fixed afterwards, so this errs toward shooting it.
    public static let crushedTarget = 0.02

    /// Stops between neighbouring exposures.
    ///
    /// Two, because the merge weights samples by how well exposed they are and needs each tone to
    /// appear usably in more than one frame. RAW carries enough range that two stops still overlaps
    /// generously; four would meet only at the edges of each frame's usable band, where the
    /// weighting is weakest and noise is worst.
    public static let step = 2

    /// Hard ceiling on frames, whatever the scene.
    ///
    /// Nine at two stops is sixteen stops of bracket — beyond any real scene, and past the point
    /// where the subject has likely moved. Reaching it means the measurement is being defeated
    /// (a light source in frame, usually), not that the scene truly needs more.
    public static let maximumFrames = 9

    /// Which exposure to shoot next, or `nil` when the scene is covered.
    ///
    /// - Parameter shot: what has been shot so far, as offsets in stops from the metered exposure
    ///   with what each recorded. Order does not matter.
    public static func next(after shot: [(offset: Int, coverage: Coverage)]) -> Int? {
        guard !shot.isEmpty else { return 0 }          // always start at the metered exposure
        guard shot.count < maximumFrames else { return nil }

        // The darkest frame is the one protecting the highlights; the brightest, the shadows.
        guard let darkest = shot.min(by: { $0.offset < $1.offset }),
              let brightest = shot.max(by: { $0.offset < $1.offset }) else { return nil }

        // Highlights first. A blown highlight is unrecoverable and obvious; a noisy shadow is
        // neither, so when frames are limited the dark end is the better place to spend them.
        if darkest.coverage.clipped > clippedTarget {
            return darkest.offset - step
        }
        if brightest.coverage.crushed > crushedTarget {
            return brightest.offset + step
        }
        return nil
    }

    /// Plain description of what the bracket ended up being, for the status line.
    public static func summary(offsets: [Int]) -> String {
        guard !offsets.isEmpty else { return "no exposures" }
        guard offsets.count > 1 else { return "1 exposure" }
        let low = offsets.min()!, high = offsets.max()!
        return "\(offsets.count) exposures, \(low >= 0 ? "+" : "")\(low) to +\(high) stops"
    }

    /// Why the bracket stopped where it did, when it stopped short.
    public static func warning(offsets: [Int], last: Coverage) -> String? {
        guard offsets.count >= maximumFrames else { return nil }
        if last.clipped > clippedTarget {
            return "Stopped at \(maximumFrames) exposures with highlights still clipping — "
                 + "there may be a light source in frame that no exposure can hold."
        }
        if last.crushed > crushedTarget {
            return "Stopped at \(maximumFrames) exposures with the shadows still in noise."
        }
        return nil
    }
}
