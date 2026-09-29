import Foundation

/// Keeps a timelapse correctly exposed as the light changes, without the brightness steps that make
/// a day-to-night sequence flicker.
///
/// The problem is not exposure — metering a frame is easy. It is that a body can only change
/// exposure in **1/3-stop clicks**, and a 1/3-stop jump between two consecutive frames of a 24 fps
/// sequence is a visible flash. The classic hardware answer was a bulb timer: hold the shutter open
/// for a continuously variable time, so exposure can move in arbitrarily small amounts. This body
/// exposes no bulb control at all, and the PTP/IP link's command latency runs from 0.2 s to over
/// 2 s, so timing a bulb exposure precisely enough is not possible here either.
///
/// Software gets a better answer for free, because every frame is RAW and its exact exposure is
/// recorded in EXIF. The step *is* taken in 1/3-stop clicks, and then removed afterwards: a frame
/// shot 1/3 stop darker is developed 1/3 stop brighter, and the seam disappears. That also corrects
/// what bulb ramping cannot — shutter timing error, and the light changing between one frame and
/// the next.
///
/// So this controller has two jobs: hold the exposure roughly right, and change it as rarely and as
/// predictably as possible, because every change is something the deflicker pass has to undo.
public struct ExposureRamp: Equatable, Sendable {

    // MARK: - Calibration

    /// How far the measured brightness may drift from target before the exposure moves, in stops.
    ///
    /// A deadband, not a threshold — without one, a metric hovering near the boundary toggles the
    /// exposure back and forth every frame, which is the worst possible input to a deflicker pass:
    /// many small corrections rather than a few clean ones.
    public static let deadband = 0.35

    /// The most the exposure may move in one frame, in stops.
    ///
    /// One click. Even though the step gets corrected afterwards, a large correction stretches the
    /// noise and the highlight roll-off differently from its neighbours, which no gain can undo.
    /// Light changes slowly enough — a sunset is roughly a stop every few minutes — that one click
    /// per frame keeps up comfortably.
    public static let maximumStep = 1.0 / 3.0

    /// How strongly each new measurement moves the running estimate, 0…1.
    ///
    /// The controller reacts to a *smoothed* reading so that a bird, a passing car's headlights or
    /// a gap in cloud does not drive a permanent exposure change. Low enough to ignore a one-frame
    /// event, high enough to follow a sunset.
    public static let smoothing = 0.25

    // MARK: - State

    /// Smoothed brightness in stops relative to target. Positive means too bright.
    public private(set) var error: Double = 0
    /// Whether any measurement has been taken yet.
    public private(set) var hasMeasurement = false
    /// Exposure changes made so far — what the deflicker pass will have to undo.
    public private(set) var adjustments = 0

    public init() {}

    // MARK: - Control

    /// Folds in one frame's measurement.
    ///
    /// - Parameter stopsFromTarget: how far this frame sits from the wanted brightness, in stops.
    ///   Positive is too bright.
    public mutating func record(stopsFromTarget: Double) {
        guard stopsFromTarget.isFinite else { return }
        if hasMeasurement {
            error += (stopsFromTarget - error) * Self.smoothing
        } else {
            // The first frame sets the estimate outright: there is nothing to smooth against, and
            // starting from zero would spend several frames climbing out of an error the very first
            // measurement already told us about.
            error = stopsFromTarget
            hasMeasurement = true
        }
    }

    /// How much to change exposure before the next frame, in stops. Positive means *more* light.
    ///
    /// Zero whenever the drift is inside the deadband, which is most frames.
    public mutating func nextAdjustment() -> Double {
        guard hasMeasurement, abs(error) > Self.deadband else { return 0 }
        let wanted = -error                                     // too bright means give less light
        let step = max(-Self.maximumStep, min(Self.maximumStep, wanted))
        // Credit the correction immediately. Without this the controller keeps seeing the old error
        // until new frames have worked through the smoothing, and over-corrects by several clicks —
        // the classic integrator wind-up, which in a timelapse reads as the exposure surging past
        // the light and then coming back.
        error += step
        adjustments += 1
        return step
    }

    // MARK: - Deflicker

    /// The gain each frame needs so the sequence reads smoothly, in stops.
    ///
    /// A frame shot 1/3 stop darker than its neighbour is developed 1/3 stop brighter, and the seam
    /// disappears. The correction is built from what each frame *actually* received — the EXIF
    /// exposure — rather than from what it was asked for, so a click the body did not take, or took
    /// differently from the plan, is corrected rather than believed.
    ///
    /// - Parameters:
    ///   - exposures: relative exposure of each frame, in the order shot. Any consistent scale.
    ///   - brightness: measured brightness of each frame, same order and scale as each other.
    /// - Returns: gain per frame in stops, to be applied when developing.
    public static func deflicker(exposures: [Double], brightness: [Double]) -> [Double] {
        let count = min(exposures.count, brightness.count)
        guard count > 1 else { return [Double](repeating: 0, count: count) }

        // Smooth the **rendered** brightness, which is what the viewer actually sees.
        //
        // The obvious thing — divide brightness by exposure to recover the scene's own light and
        // smooth that — does nothing at all, and the first version shipped it. Dividing the exposure
        // back out removes precisely the steps that need correcting, leaving the light curve, which
        // is smooth by construction; the correction then comes out as zero everywhere. What flickers
        // is the sequence as projected, so that is what has to be smoothed.
        var rendered = [Double](repeating: 0, count: count)
        for i in 0..<count {
            guard exposures[i] > 0, brightness[i] > 0 else { return [Double](repeating: 0, count: count) }
            rendered[i] = log2(brightness[i])
        }

        // The window must be wider than the gap between exposure changes, or a step is merely
        // softened rather than spread: with a click every ten frames, a five-frame window leaves
        // most of each step standing.
        var smoothed = rendered
        let window = 11
        for i in 0..<count {
            let low = max(0, i - window / 2), high = min(count - 1, i + window / 2)
            smoothed[i] = rendered[low...high].reduce(0, +) / Double(high - low + 1)
        }

        // Each frame is corrected by the difference between the smooth curve and where it landed.
        return (0..<count).map { smoothed[$0] - rendered[$0] }
    }
}
