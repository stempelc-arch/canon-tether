import XCTest
@testable import CanonTetherCore

/// Focus scoring is a heuristic, so what's asserted here is the *ordering* it has to get right — a
/// crisp frame outscores its blurred copy, the score doesn't move when you just change exposure, and
/// a single sharp region on an otherwise soft frame still reads as focused (the shallow-DOF case) —
/// rather than exact score values, which are calibrated against real camera files.
final class FocusAnalysisTests: XCTestCase {

    private let sharp = 60, soft = 35

    /// A checkerboard: hard edges every `cell` pixels — the sharpest thing a raster can hold.
    private func checkerboard(size: Int = 128, cell: Int = 8, low: Float = 0.1, high: Float = 0.9) -> ScopeFrame {
        var rgba = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let v = on ? high : low
                let p = (y * size + x) * 4
                rgba[p] = v; rgba[p + 1] = v; rgba[p + 2] = v; rgba[p + 3] = 1
            }
        }
        return ScopeFrame(width: size, height: size, rgba: rgba)
    }

    /// A cheap box blur, so the blurred frame carries the same tones spread over soft transitions.
    private func blurred(_ frame: ScopeFrame, radius: Int = 3) -> ScopeFrame {
        let w = frame.width, h = frame.height
        var out = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0, n: Float = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                        sum += frame.rgba[(yy * w + xx) * 4]; n += 1
                    }
                }
                let v = sum / n
                let p = (y * w + x) * 4
                out[p] = v; out[p + 1] = v; out[p + 2] = v; out[p + 3] = 1
            }
        }
        return ScopeFrame(width: w, height: h, rgba: out)
    }

    /// A frame that's soft everywhere except one crisp checkerboard patch — a subject in focus on a
    /// blurred background.
    private func sharpPatchOnSoft(size: Int = 144, patch: Int = 36) -> ScopeFrame {
        var rgba = [Float](repeating: 0.5, count: size * size * 4)
        for i in 0..<(size * size) { rgba[i * 4 + 3] = 1 }
        for y in 0..<patch {
            for x in 0..<patch {
                let on = ((x / 4) + (y / 4)) % 2 == 0
                let v: Float = on ? 0.9 : 0.1
                let p = ((y + 4) * size + (x + 4)) * 4
                rgba[p] = v; rgba[p + 1] = v; rgba[p + 2] = v
            }
        }
        return ScopeFrame(width: size, height: size, rgba: rgba)
    }

    func testSharpOutscoresBlurred() {
        let crisp = FocusAnalyzer.evaluate(checkerboard(), sharpThreshold: sharp, softThreshold: soft)
        let blur = FocusAnalyzer.evaluate(blurred(checkerboard()), sharpThreshold: sharp, softThreshold: soft)
        XCTAssertGreaterThan(crisp.score, blur.score)
        XCTAssertEqual(crisp.verdict, .sharp)
    }

    func testFlatFrameIsSoft() {
        var rgba = [Float](repeating: 0.5, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) { rgba[i * 4 + 3] = 1 }
        let result = FocusAnalyzer.evaluate(ScopeFrame(width: 64, height: 64, rgba: rgba),
                                            sharpThreshold: sharp, softThreshold: soft)
        XCTAssertEqual(result.verdict, .soft)
        XCTAssertLessThan(result.score, soft)
    }

    /// The contrast-normalised ratio is invariant to exposure: a dim sharp frame scores the same as
    /// a bright one, so the check doesn't punish a low-key shot.
    func testScoreIsExposureInvariant() {
        let bright = FocusAnalyzer.evaluate(checkerboard(low: 0.1, high: 0.9), sharpThreshold: sharp, softThreshold: soft)
        let dim = FocusAnalyzer.evaluate(checkerboard(low: 0.05, high: 0.45), sharpThreshold: sharp, softThreshold: soft)
        XCTAssertEqual(bright.score, dim.score, accuracy: 4)
    }

    /// Shallow depth of field: a sharp subject on a blurred background must still pass.
    func testSharpSubjectOnSoftBackgroundPasses() {
        let result = FocusAnalyzer.evaluate(sharpPatchOnSoft(), sharpThreshold: sharp, softThreshold: soft)
        XCTAssertEqual(result.verdict, .sharp)
        // The peak should point into the sharp patch (top-left region), not the soft surround.
        let peak = try? XCTUnwrap(result.peak)
        XCTAssertNotNil(peak)
        if let peak { XCTAssertLessThan(peak.x, 0.5); XCTAssertLessThan(peak.y, 0.5) }
    }

    func testCachedScoreRebuckets() {
        XCTAssertEqual(FocusResult(cachedScore: 80, sharpThreshold: 60, softThreshold: 35).verdict, .sharp)
        XCTAssertEqual(FocusResult(cachedScore: 45, sharpThreshold: 60, softThreshold: 35).verdict, .borderline)
        XCTAssertEqual(FocusResult(cachedScore: 20, sharpThreshold: 60, softThreshold: 35).verdict, .soft)
    }
}
