import Foundation

/// Shutter arithmetic for exposure bracketing.
///
/// There is no plan type any more — no spread, no frame count. `HDRAutoBracket` decides those by
/// measuring the scene, and a chosen spread was a guess about a scene nobody had looked at: it
/// wasted frames on an evenly-lit subject and fell short of a window in a dark room. What is left is
/// the one thing that still has to be worked out, which shutter speed sits a given number of stops
/// from another.
public enum HDRPlan {

    /// Picks the shutter speed `stops` away from `current`, from the list the body actually offers.
    ///
    /// **Shutter, never aperture or ISO.** Aperture would change depth of field between frames and
    /// the blend would be mixing differently-focused images; ISO would change the noise floor, which
    /// is the very thing the bracket is trying to improve. Only shutter changes exposure and nothing
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
        // silently shoots the bracket inside out: the "brighter" frame is the darker one, the blend
        // still runs, and the result quietly loses the range it was supposed to gain.
        let target = currentStops - Double(stops)
        var best: (choice: String, distance: Double)?
        for choice in choices {
            guard let value = ExposureGrid.stops(of: choice, path: ExposureGrid.shutterPath) else { continue }
            let distance = abs(value - target)
            if best == nil || distance < best!.distance { best = (choice, distance) }
        }
        // Within a third of a stop of what was asked for. Further than that and the bracket is not
        // the bracket that was measured for — better to refuse and say the body ran out of range.
        guard let best, best.distance <= 0.34 else { return nil }
        return best.choice
    }
}
