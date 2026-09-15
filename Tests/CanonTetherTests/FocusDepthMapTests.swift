import XCTest
@testable import CanonTetherCore

final class FocusDepthMapSeeThroughTests: XCTestCase {

    // MARK: - Seeing through a subject

    /// A main peak plus a smaller, well-separated second one: a tile looking through a mesh at
    /// something behind it.
    private func twoPeakCurve(front: Int, behind: Int) -> [(offset: Int, value: Double)] {
        stride(from: -40, through: 80, by: 2).map { offset in
            let near = exp(-pow(Double(offset - front) / 6, 2))
            let far = exp(-pow(Double(offset - behind) / 6, 2)) * 0.35
            return (offset, near + far + 0.01)
        }
    }

    private func onePeakCurve(front: Int) -> [(offset: Int, value: Double)] {
        stride(from: -40, through: 80, by: 2).map { offset in
            (offset, exp(-pow(Double(offset - front) / 6, 2)) + 0.01)
        }
    }

    private func surface(_ cells: Int) -> (surface: [Int],
                                           tiles: [FocusDepthMap.TilePeak]) {
        var tiles: [FocusDepthMap.TilePeak] = []
        for cell in 0..<cells {
            tiles.append(FocusDepthMap.TilePeak(cell: cell, offset: 0, peak: 1, floor: 0))
        }
        return (Array(repeating: 0, count: cells), tiles)
    }

    func testProminentPeaksFindsASecondSurfaceButNotAShoulder() {
        let peaks = FocusDepthMap.prominentPeaks(twoPeakCurve(front: 0, behind: 40))
        XCTAssertTrue(peaks.contains { abs($0 - 40) <= 4 }, "the second surface is a prominent peak")
        XCTAssertTrue(FocusDepthMap.prominentPeaks(onePeakCurve(front: 0)).isEmpty,
                      "a single smooth peak has no second surface")
    }

    /// A mesh basket: most of the front surface can see something behind it, and those contents are
    /// part of the subject. Taking only the nearest depth group left a mesh pen cup stacked as its
    /// front wires with the pens inside soft.
    func testDepthBehindFindsContentsOfASeeThroughSubject() {
        let (front, tiles) = surface(40)
        var curves: [Int: [(offset: Int, value: Double)]] = [:]
        for cell in 0..<40 { curves[cell] = twoPeakCurve(front: 0, behind: 40) }
        let behind = FocusDepthMap.depthBehind(surface: front, tiles: tiles, curves: curves)
        XCTAssertNotNil(behind, "a subject most of whose surface sees through is see-through")
        XCTAssertEqual(Double(behind ?? 0), 40, accuracy: 6)
    }

    func testDepthBehindReportsNothingForAnOpaqueSubject() {
        let (front, tiles) = surface(40)
        var curves: [Int: [(offset: Int, value: Double)]] = [:]
        for cell in 0..<40 { curves[cell] = onePeakCurve(front: 0) }
        XCTAssertNil(FocusDepthMap.depthBehind(surface: front, tiles: tiles, curves: curves))
    }

    /// A few tiles glimpsing past the outline is what *background* looks like. Following it would
    /// stretch every stack to the far wall.
    func testDepthBehindIgnoresAFewStrayGlimpses() {
        let (front, tiles) = surface(40)
        var curves: [Int: [(offset: Int, value: Double)]] = [:]
        for cell in 0..<40 {
            curves[cell] = cell < 3 ? twoPeakCurve(front: 0, behind: 40) : onePeakCurve(front: 0)
        }
        XCTAssertNil(FocusDepthMap.depthBehind(surface: front, tiles: tiles, curves: curves),
                     "3 of 40 tiles is a glimpse, not a subject you can look into")
    }

    // MARK: - Ranges

    /// Depths are clustered so a subject is separated from what shows around its outline.
    func testClusterSeparatesSubjectFromBackground() {
        let groups = FocusDepthMap.cluster([-20, -18, -16, -14, 60, 62, 64])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.contains(-20) }?.max(), -14)
        XCTAssertEqual(groups.first { $0.contains(60) }?.min(), 60)
    }

    func testClusterToleratesGapsInsideOneSurface() {
        // A real subject's tiles do not form an unbroken run; dips between surfaces are normal.
        XCTAssertEqual(FocusDepthMap.cluster([0, 2, 8, 10, 16]).count, 1)
    }
}
