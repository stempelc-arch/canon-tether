import XCTest
@testable import CanonTetherCore

/// The cases here are mostly about what the merge must *not* do.
///
/// The cliché "HDR look" — grey flat midtones, haloed edges, crunchy local contrast — comes from
/// local tone mapping. This merge has no local operator at all, and these tests pin the properties
/// that keep it that way: midtones pass through untouched, the curve is smooth and monotonic, and
/// detail the bracket never reached is never invented.
final class HDRMergeTests: XCTestCase {

    func testTransferRoundTrips() {
        for step in 0...20 {
            let v = Float(step) / 20
            XCTAssertEqual(HDRMerge.encode(HDRMerge.linearize(v)), v, accuracy: 1e-4)
        }
    }

    func testReliabilityDiscardsClippedAndCrushedSamples() {
        XCTAssertEqual(HDRMerge.reliability(of: 0), 0, "a black sample carries no information")
        XCTAssertEqual(HDRMerge.reliability(of: 1), 0, "a clipped sample carries no information")
        XCTAssertGreaterThan(HDRMerge.reliability(of: 0.5), 0.9)
        XCTAssertEqual(HDRMerge.reliability(of: 0.3), HDRMerge.reliability(of: 0.7), accuracy: 1e-3)
    }

    /// A triangular weight has a corner at the midpoint, so two overlapping exposures cross with a
    /// discontinuous derivative — visible as banding across a smooth sky, which is exactly where an
    /// HDR merge gets looked at hardest.
    func testReliabilityHasNoCorner() {
        var maxJump: Float = 0
        var previous = HDRMerge.reliability(of: 0.02)
        for step in 1...1000 {
            let v = 0.02 + Float(step) / 1000 * 0.96
            let w = HDRMerge.reliability(of: v)
            maxJump = max(maxJump, abs(w - previous))
            previous = w
        }
        XCTAssertLessThan(maxJump, 0.01)
    }

    /// The headline property: everything a normal exposure renders well is left exactly alone.
    func testMidtonesAndShadowsPassThroughUntouched() {
        for step in 0...37 {
            let v = Float(step) / 50
            guard v <= HDRMerge.defaultKnee else { break }
            XCTAssertEqual(HDRMerge.shoulder(v), v, accuracy: 1e-6)
        }
    }

    func testShoulderRollsOffInsteadOfClipping() {
        XCTAssertLessThan(HDRMerge.shoulder(1), 1)
        XCTAssertLessThan(HDRMerge.shoulder(8), 1, "even three stops over stays in range")
        XCTAssertLessThan(HDRMerge.shoulder(100), 1, "the curve is asymptotic")

        var last = HDRMerge.shoulder(0)
        for step in 0...2000 {
            let s = HDRMerge.shoulder(Float(step) / 100)
            XCTAssertGreaterThanOrEqual(s, last - 1e-6, "brighter input is never darker output")
            last = s
        }
    }

    /// A slope discontinuity at the knee draws a visible line across a gradient.
    func testCurveIsSmoothThroughTheKnee() {
        let k = HDRMerge.defaultKnee
        let below = (HDRMerge.shoulder(k) - HDRMerge.shoulder(k - 0.001)) / 0.001
        let above = (HDRMerge.shoulder(k + 0.001) - HDRMerge.shoulder(k)) / 0.001
        XCTAssertEqual(below, above, accuracy: 0.02)
    }

    // MARK: - Merging a bracket

    private func bracket(width: Int) -> (frames: [HDRMerge.Frame], scene: [Float]) {
        let scene = (0..<width).map { Float($0) / Float(width - 1) * 6 }
        func frame(_ exposure: Double) -> HDRMerge.Frame {
            var image = StackImage(width: width, height: 1, channels: 1)
            for i in 0..<width {
                image.data[i] = HDRMerge.encode(min(scene[i] * Float(exposure), 1))
            }
            return HDRMerge.Frame(image: image, exposure: exposure)
        }
        return ([frame(0.25), frame(1), frame(4)], scene)
    }

    func testRecoversRadianceTheReferenceFrameCouldNotHold() throws {
        let width = 64
        let (frames, scene) = bracket(width: width)
        let radiance = try HDRMerge.radiance(from: frames, reference: 1)

        // The darkest frame is -2 stops, so the bracket reaches 4x the reference white point.
        let ceiling: Float = 4
        for i in 0..<width where scene[i] > 0.05 && scene[i] < ceiling * 0.9 {
            XCTAssertEqual(radiance.data[i], scene[i], accuracy: scene[i] * 0.12)
        }
        XCTAssertGreaterThan(radiance.data[width - 1], 3,
                             "detail above the reference's white point survives rather than clipping to 1")
    }

    /// Past what the bracket photographed, the merge must not extrapolate — inventing detail that
    /// was never captured is how a merge produces convincing nonsense.
    func testDoesNotInventDetailBeyondTheBracket() throws {
        let width = 64
        let (frames, scene) = bracket(width: width)
        let radiance = try HDRMerge.radiance(from: frames, reference: 1)
        let ceiling: Float = 4
        let beyond = (0..<width).filter { scene[$0] > ceiling * 1.2 }
        XCTAssertFalse(beyond.isEmpty)
        for i in beyond {
            XCTAssertLessThanOrEqual(radiance.data[i], ceiling * 1.05)
            XCTAssertGreaterThan(radiance.data[i], 2, "but it is still carried above white")
        }
    }

    /// The rendered result keeps the metered exposure's own rendering in the midtones.
    func testRenderKeepsTheReferenceExposuresMidtones() throws {
        let width = 64
        let (frames, scene) = bracket(width: width)
        let shown = HDRMerge.render(try HDRMerge.radiance(from: frames, reference: 1))
        XCTAssertTrue(shown.data.allSatisfy { $0 >= 0 && $0 <= 1 })

        let mid = (0..<width).min { abs(scene[$0] - 0.4) < abs(scene[$1] - 0.4) }!
        XCTAssertEqual(shown.data[mid], HDRMerge.encode(scene[mid]), accuracy: 0.02)
    }

    func testReportsTheStopsItRecovered() throws {
        let (frames, _) = bracket(width: 64)
        let radiance = try HDRMerge.radiance(from: frames, reference: 1)
        XCTAssertGreaterThan(HDRMerge.recoveredStops(radiance), 1.5)
    }

    func testRejectsAnUnusableBracket() {
        var image = StackImage(width: 4, height: 1, channels: 1)
        image.data = [0.5, 0.5, 0.5, 0.5]
        let one = [HDRMerge.Frame(image: image, exposure: 1)]
        XCTAssertThrowsError(try HDRMerge.radiance(from: one, reference: 0)) { error in
            XCTAssertEqual(error as? HDRMerge.MergeError, .needsTwoFrames)
        }
    }
}
