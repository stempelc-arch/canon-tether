import XCTest
@testable import CanonTetherCore

/// Timelapse exposure ramping. The hard requirement is smoothness, not accuracy: a 1/3-stop jump
/// between consecutive frames is a visible flash, so the controller changes exposure as rarely and
/// as predictably as it can, and the steps are removed afterwards.
final class ExposureRampTests: XCTestCase {

    /// Every needless click is a seam for the deflicker pass to repair.
    func testSteadyLightNeverMovesTheExposure() {
        var ramp = ExposureRamp()
        for _ in 0..<200 {
            ramp.record(stopsFromTarget: 0.05)
            XCTAssertEqual(ramp.nextAdjustment(), 0)
        }
    }

    /// A bird, a car's headlights, a gap in cloud: none of these should drive a permanent change.
    func testASuddenEventDoesNotDriveAPermanentChange() {
        var ramp = ExposureRamp()
        for _ in 0..<10 { ramp.record(stopsFromTarget: 0); _ = ramp.nextAdjustment() }
        ramp.record(stopsFromTarget: 4)
        XCTAssertLessThanOrEqual(abs(ramp.nextAdjustment()), ExposureRamp.maximumStep + 1e-9)
        for _ in 0..<10 { ramp.record(stopsFromTarget: 0); _ = ramp.nextAdjustment() }
        XCTAssertLessThan(abs(ramp.error), ExposureRamp.deadband)
    }

    func testTracksATenStopSunset() {
        var ramp = ExposureRamp()
        var exposure = 0.0
        var worst = 0.0
        var clicks = 0
        for frame in 0..<600 {
            let measured = -10.0 * Double(frame) / 600.0 + exposure
            ramp.record(stopsFromTarget: measured)
            let step = ramp.nextAdjustment()
            if step != 0 {
                clicks += 1
                XCTAssertLessThanOrEqual(abs(step), ExposureRamp.maximumStep + 1e-9)
            }
            exposure += step
            if frame > 20 { worst = max(worst, abs(measured)) }
        }
        XCTAssertLessThan(worst, 1.0, "holds within a stop through a 10-stop ramp")
        XCTAssertTrue((25...60).contains(clicks), "about as many clicks as stops, not hundreds")
    }

    /// Integrator wind-up in a timelapse reads as the exposure surging past the light and returning.
    func testDoesNotOverCorrect() {
        var ramp = ExposureRamp()
        ramp.record(stopsFromTarget: 3)
        var total = 0.0
        for _ in 0..<5 { total += ramp.nextAdjustment() }
        XCTAssertLessThanOrEqual(abs(total), 3 + 1e-9)
    }

    // MARK: - Deflicker

    /// Dividing the exposure back out to recover the scene's light and smoothing *that* does
    /// nothing — it removes exactly the steps that need correcting. What flickers is the rendered
    /// sequence, so that is what gets smoothed.
    func testRemovesExposureStepsAndKeepsTheTrend() {
        var exposures: [Double] = [], brightness: [Double] = []
        var exposureStops = 0.0
        for frame in 0..<60 {
            let sceneStops = -3.0 * Double(frame) / 60
            if frame % 10 == 0 && frame > 0 { exposureStops += 1.0 / 3.0 }
            exposures.append(pow(2, exposureStops))
            brightness.append(pow(2, sceneStops + exposureStops))
        }
        let gains = ExposureRamp.deflicker(exposures: exposures, brightness: brightness)
        XCTAssertEqual(gains.count, 60)

        let trendPerFrame = 3.0 / 60
        var worstCorrected = 0.0, worstRaw = 0.0
        for i in 1..<60 {
            let raw = log2(brightness[i]) - log2(brightness[i - 1])
            worstRaw = max(worstRaw, abs(raw))
            worstCorrected = max(worstCorrected, abs(raw + gains[i] - gains[i - 1]))
        }
        XCTAssertGreaterThan(worstRaw, trendPerFrame * 4, "the clicks were plainly visible")
        XCTAssertLessThan(worstCorrected, trendPerFrame * 2.5, "and are not any more")
    }

    func testDegenerateInputIsRefused() {
        XCTAssertEqual(ExposureRamp.deflicker(exposures: [1], brightness: [1]), [0])
        XCTAssertEqual(ExposureRamp.deflicker(exposures: [1, 0], brightness: [1, 1]), [0, 0])
    }
}
