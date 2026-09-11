import XCTest
@testable import CanonTetherCore

/// Exposure is objective where clipping is concerned, so these check the readings land where they
/// should — a blown frame reads over, a crushed one under, a mid-grey one good — and that the
/// verdict re-buckets against the tolerances the same way a cached result would.
final class ExposureAnalysisTests: XCTestCase {

    // The three tolerances are independent (see ShotAnalysisStore's calibration notes): highlights
    // are held tighter than shadows, and near-white catches a washed-out frame that never reaches
    // the hard clip point. Tests pass all three explicitly so a change to one can't silently
    // rewrite what another is asserting.
    private let highlight = 0.05
    private let shadow = 0.05
    private let nearWhite = 0.50   // deliberately loose here; exercised on its own below

    private func evaluate(_ frame: ScopeFrame,
                          highlightClipLimit: Double? = nil,
                          shadowClipLimit: Double? = nil,
                          nearWhiteLimit: Double? = nil) -> ExposureResult {
        ExposureAnalyzer.evaluate(frame,
                                  highlightClipLimit: highlightClipLimit ?? highlight,
                                  shadowClipLimit: shadowClipLimit ?? shadow,
                                  nearWhiteLimit: nearWhiteLimit ?? nearWhite)
    }

    /// A frame filled with one luma value (given 0–1).
    private func solid(_ v: Float, size: Int = 64) -> ScopeFrame {
        var rgba = [Float](repeating: v, count: size * size * 4)
        for i in 0..<(size * size) { rgba[i * 4 + 3] = 1 }
        return ScopeFrame(width: size, height: size, rgba: rgba)
    }

    /// A frame that's `fraction` blown white and the rest mid-grey.
    private func partlyBlown(_ fraction: Double, size: Int = 100) -> ScopeFrame {
        var rgba = [Float](repeating: 0.5, count: size * size * 4)
        for i in 0..<(size * size) { rgba[i * 4 + 3] = 1 }
        let blown = Int(Double(size * size) * fraction)
        for i in 0..<blown { rgba[i * 4] = 1; rgba[i * 4 + 1] = 1; rgba[i * 4 + 2] = 1 }
        return ScopeFrame(width: size, height: size, rgba: rgba)
    }

    func testMidGreyIsGood() {
        XCTAssertEqual(evaluate(solid(0.45)).verdict, .good)
    }

    func testAllWhiteIsOver() {
        XCTAssertEqual(evaluate(solid(1.0)).verdict, .over)
    }

    func testAllBlackIsUnder() {
        XCTAssertEqual(evaluate(solid(0.0)).verdict, .under)
    }

    /// Clipping past the tolerance flags over; the same frame under a looser one passes.
    func testHighlightClipRespectsTolerance() {
        let frame = partlyBlown(0.10)   // 10% blown
        XCTAssertEqual(evaluate(frame, highlightClipLimit: 0.05).verdict, .over)
        XCTAssertEqual(evaluate(frame, highlightClipLimit: 0.20).verdict, .good)
    }

    /// The near-white check exists to catch a washed-out frame that never hits the hard clip
    /// point — so a frame well inside the highlight tolerance still reads over once too much of it
    /// sits in the near-white band.
    func testNearWhiteFlagsWashedOutFrame() {
        let frame = partlyBlown(0.10)
        XCTAssertEqual(evaluate(frame, highlightClipLimit: 0.50, nearWhiteLimit: 0.05).verdict, .over)
        XCTAssertEqual(evaluate(frame, highlightClipLimit: 0.50, nearWhiteLimit: 0.50).verdict, .good)
    }

    func testMeasuredClipFractionIsAccurate() {
        let m = ExposureAnalyzer.measure(partlyBlown(0.10))
        XCTAssertEqual(m.highlightClip, 0.10, accuracy: 0.005)
        XCTAssertLessThan(m.shadowClip, 0.001)
    }

    /// A cached result re-buckets against new tolerances with no pixels — the path that lets a
    /// revisited project reuse readings stored in the file's xattrs.
    func testCachedResultRebuckets() {
        let over = ExposureResult(cachedHighlightClip: 0.10, shadowClip: 0, nearWhite: 0.10, median: 0.5,
                                  highlightClipLimit: 0.05, shadowClipLimit: 0.05, nearWhiteLimit: 0.50)
        XCTAssertEqual(over.verdict, .over)
        let good = ExposureResult(cachedHighlightClip: 0.10, shadowClip: 0, nearWhite: 0.10, median: 0.5,
                                  highlightClipLimit: 0.20, shadowClipLimit: 0.05, nearWhiteLimit: 0.50)
        XCTAssertEqual(good.verdict, .good)
    }

    /// Non-finite samples reach here from corrupt or truncated files; they must not trap.
    func testNonFinitePixelsDoNotCrash() {
        var rgba = [Float](repeating: .nan, count: 16 * 16 * 4)
        for i in 0..<(16 * 16) { rgba[i * 4 + 3] = 1 }
        let frame = ScopeFrame(width: 16, height: 16, rgba: rgba)
        _ = evaluate(frame)
    }

    // MARK: - Exposure offset (stops over/under)

    /// A neutral scene centred on mid-grey, then deliberately mis-exposed by `stops`.
    private func scene(misExposedBy stops: Double, size: Int = 120) -> ScopeFrame {
        func encode(_ linear: Double) -> Float {
            let c = min(max(linear, 0), 1)
            return Float(c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        var rgba = [Float](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let t = Double(i) / Double(size * size - 1)
            let linear = 0.18 * pow(2.0, (t - 0.5) * 6)     // ±3 stops around mid-grey
            let v = encode(linear * pow(2.0, stops))
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v; rgba[i * 4 + 3] = 1
        }
        return ScopeFrame(width: size, height: size, rgba: rgba)
    }

    /// The reading has to recover a known mis-exposure, or the number on the badge is decoration.
    func testOffsetRecoversKnownMisExposure() {
        for applied in [-2.0, -1.0, -2.0 / 3, 0.0, 1.0 / 3, 1.0, 2.0] {
            let measured = ExposureAnalyzer.offset(scene(misExposedBy: applied)).stops
            XCTAssertEqual(measured, applied, accuracy: 0.34,
                           "a \(applied)-stop error should read back as roughly that")
        }
    }

    /// Exposure is dialled in thirds, so the reading is quantised to thirds — never 0.41 stops.
    func testOffsetIsQuantisedToThirds() {
        for raw in [0.05, 0.4, 0.9, 1.7] {
            let thirds = ExposureAnalyzer.quantiseToThirds(raw) * 3
            XCTAssertEqual(thirds, thirds.rounded(), accuracy: 1e-9)
        }
    }

    /// More than half the frame clipped means the true brightness is past what was recorded, so
    /// the figure must present itself as a floor rather than a measurement.
    func testFullyClippedFrameReportsALowerBound() {
        var white = [Float](repeating: 1, count: 32 * 32 * 4)
        for i in 0..<(32 * 32) { white[i * 4 + 3] = 1 }
        let over = ExposureAnalyzer.offset(ScopeFrame(width: 32, height: 32, rgba: white))
        XCTAssertTrue(over.isAtLeast)
        XCTAssertGreaterThan(over.stops, 0)
        XCTAssertTrue(over.summary.hasPrefix("at least"))
    }

    /// Thirds are written the way a photographer writes them.
    func testOffsetLabels() {
        XCTAssertEqual(ExposureOffset(stops: 1.0 / 3, isAtLeast: false).label, "\u{2153}")
        XCTAssertEqual(ExposureOffset(stops: 2.0 / 3, isAtLeast: false).label, "\u{2154}")
        XCTAssertEqual(ExposureOffset(stops: 1.0, isAtLeast: false).label, "1")
        XCTAssertEqual(ExposureOffset(stops: 4.0 / 3, isAtLeast: false).label, "1\u{2153}")
        XCTAssertEqual(ExposureOffset(stops: 2.0, isAtLeast: false).label, "2")
        XCTAssertEqual(ExposureOffset(stops: 1.0, isAtLeast: false).summary, "1 stop over")
        XCTAssertEqual(ExposureOffset(stops: -2.0, isAtLeast: false).summary, "2 stops under")
    }
}
