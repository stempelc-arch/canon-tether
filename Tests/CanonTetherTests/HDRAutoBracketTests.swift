import XCTest
@testable import CanonTetherCore

/// Automatic bracketing: the scene decides the count and spacing, not a setting chosen before
/// anyone looked at it.
final class HDRAutoBracketTests: XCTestCase {

    private typealias Coverage = HDRAutoBracket.Coverage
    private func shot(_ offset: Int, clipped: Double = 0, crushed: Double = 0)
    -> (offset: Int, coverage: Coverage) {
        (offset, Coverage(clipped: clipped, crushed: crushed))
    }

    func testStartsAtTheMeteredExposure() {
        XCTAssertEqual(HDRAutoBracket.next(after: []), 0)
    }

    func testAnEasySceneNeedsNoBracket() {
        XCTAssertNil(HDRAutoBracket.next(after: [shot(0)]))
    }

    func testWalksDownUntilHighlightsAreHeld() {
        XCTAssertEqual(HDRAutoBracket.next(after: [shot(0, clipped: 0.08)]), -2)
        XCTAssertEqual(HDRAutoBracket.next(after: [shot(0, clipped: 0.08), shot(-2, clipped: 0.03)]), -4)
        XCTAssertNil(HDRAutoBracket.next(after: [shot(0, clipped: 0.08),
                                                shot(-2, clipped: 0.03),
                                                shot(-4, clipped: 0.0002)]))
    }

    func testWalksUpUntilShadowsAreOutOfTheNoise() {
        XCTAssertEqual(HDRAutoBracket.next(after: [shot(0, crushed: 0.3)]), 2)
        XCTAssertNil(HDRAutoBracket.next(after: [shot(0, crushed: 0.3), shot(2, crushed: 0.01)]))
    }

    /// A blown highlight is unrecoverable and obvious; a noisy shadow is neither. When frames are
    /// limited, the dark end is the better place to spend them.
    func testHighlightsAreSpentFirst() {
        XCTAssertEqual(HDRAutoBracket.next(after: [shot(0, clipped: 0.09, crushed: 0.4)]), -2)
        XCTAssertEqual(HDRAutoBracket.next(after: [shot(0, clipped: 0.09, crushed: 0.4),
                                                  shot(-2, clipped: 0.0001)]), 2)
    }

    /// Only the extremes decide: a clipping middle frame is already covered by the darker one.
    func testOnlyTheOutermostFramesMatter() {
        XCTAssertNil(HDRAutoBracket.next(after: [shot(-2, clipped: 0.0001),
                                                 shot(0, clipped: 0.5),
                                                 shot(2, crushed: 0.001)]))
    }

    func testStopsAtTheFrameCapAndSaysWhy() {
        var many: [(offset: Int, coverage: Coverage)] = []
        for i in 0..<HDRAutoBracket.maximumFrames { many.append(shot(-2 * i, clipped: 0.5)) }
        XCTAssertNil(HDRAutoBracket.next(after: many))
        let warning = HDRAutoBracket.warning(offsets: many.map(\.offset),
                                             last: Coverage(clipped: 0.5, crushed: 0))
        XCTAssertTrue(warning?.contains("light source") == true)
        XCTAssertNil(HDRAutoBracket.warning(offsets: [0, -2], last: Coverage(clipped: 0.5, crushed: 0)),
                     "no warning when it stopped because it was finished")
    }

    /// Measured coverage from a real window-in-a-room bracket shot on the 1D X Mark II.
    func testARealWindowSceneResolvesToFiveExposures() {
        let scene: [Int: Coverage] = [
             0: Coverage(clipped: 0.121, crushed: 0.256),
            -2: Coverage(clipped: 0.021, crushed: 0.33),
            -4: Coverage(clipped: 0.0000, crushed: 0.773),
             2: Coverage(clipped: 0.20, crushed: 0.05),
             4: Coverage(clipped: 0.261, crushed: 0.0000),
        ]
        var shots: [(offset: Int, coverage: Coverage)] = []
        while let next = HDRAutoBracket.next(after: shots), let coverage = scene[next] {
            shots.append((next, coverage))
            if shots.count > 12 { break }
        }
        XCTAssertEqual(shots.map(\.offset).sorted(), [-4, -2, 0, 2, 4])
        XCTAssertEqual(HDRAutoBracket.summary(offsets: shots.map(\.offset).sorted()),
                       "5 exposures, -4 to +4 stops")
    }
}
