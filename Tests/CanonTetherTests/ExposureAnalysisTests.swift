import XCTest
@testable import CanonTetherCore

/// Exposure is objective where clipping is concerned, so these check the readings land where they
/// should — a blown frame reads over, a crushed one under, a mid-grey one good — and that the
/// verdict re-buckets against the clip tolerance the same way a cached result would.
final class ExposureAnalysisTests: XCTestCase {

    private let clip = 0.05

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
        XCTAssertEqual(ExposureAnalyzer.evaluate(solid(0.45), clipLimit: clip).verdict, .good)
    }

    func testAllWhiteIsOver() {
        XCTAssertEqual(ExposureAnalyzer.evaluate(solid(1.0), clipLimit: clip).verdict, .over)
    }

    func testAllBlackIsUnder() {
        XCTAssertEqual(ExposureAnalyzer.evaluate(solid(0.0), clipLimit: clip).verdict, .under)
    }

    /// Clipping past the tolerance flags over; the same frame under a looser tolerance passes.
    func testHighlightClipRespectsTolerance() {
        let frame = partlyBlown(0.10)   // 10% blown
        XCTAssertEqual(ExposureAnalyzer.evaluate(frame, clipLimit: 0.05).verdict, .over)
        XCTAssertEqual(ExposureAnalyzer.evaluate(frame, clipLimit: 0.20).verdict, .good)
    }

    func testMeasuredClipFractionIsAccurate() {
        let m = ExposureAnalyzer.measure(partlyBlown(0.10))
        XCTAssertEqual(m.highlightClip, 0.10, accuracy: 0.005)
        XCTAssertLessThan(m.shadowClip, 0.001)
    }

    /// A cached result re-buckets against a new tolerance with no pixels.
    func testCachedResultRebuckets() {
        let over = ExposureResult(cachedHighlightClip: 0.10, shadowClip: 0, median: 0.5, clipLimit: 0.05)
        XCTAssertEqual(over.verdict, .over)
        let good = ExposureResult(cachedHighlightClip: 0.10, shadowClip: 0, median: 0.5, clipLimit: 0.20)
        XCTAssertEqual(good.verdict, .good)
    }
}
