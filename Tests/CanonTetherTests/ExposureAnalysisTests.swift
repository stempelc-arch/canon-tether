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
}
