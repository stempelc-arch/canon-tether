import XCTest
@testable import CanonTetherCore

/// Ranging: measuring focus depth in counted nudges, and turning that into a bracket.
/// Mirrors the `swiftc` harness used during development, since CI is what actually runs this.
final class FocusRangeTests: XCTestCase {

    // MARK: - Marking

    func testSpanIsTheCountedNudges() {
        var range = FocusRange(magnitude: 1)
        XCTAssertFalse(range.isComplete)
        range.markNear()
        range.move(by: 12)
        range.markFar()
        XCTAssertEqual(range.span, 12)
        XCTAssertTrue(range.isUsable)
        XCTAssertEqual(range.offsetToNearMark(), -12, "racking back is how the bracket reaches its start")
    }

    /// Which end gets marked first is not something the photographer should have to think about.
    func testSpanIsDirectionAgnostic() {
        var range = FocusRange(magnitude: 1)
        range.markFar()
        range.move(by: -12)
        range.markNear()
        XCTAssertEqual(range.span, 12)
    }

    /// Both marks in one place means the rack never happened — that's a mistake, not a one-frame
    /// stack, and it must not produce a plan.
    func testZeroWidthRangeIsNotUsable() {
        var range = FocusRange(magnitude: 1)
        range.markNear()
        range.markFar()
        XCTAssertTrue(range.isComplete)
        XCTAssertFalse(range.isUsable)
        XCTAssertNil(FocusRangePlanner.plan(for: range, overlap: .maximum,
                                            settleSeconds: 0.4, returnToStart: true))
    }

    /// Canon never says how its three nudge sizes relate, and it differs by lens — so counts taken
    /// at one size cannot be converted to another, and the range must refuse rather than rescale.
    func testRangeIsOnlyValidAtItsOwnMagnitude() {
        let range = FocusRange(magnitude: 1)
        XCTAssertTrue(range.isValid(forMagnitude: 1))
        XCTAssertFalse(range.isValid(forMagnitude: 2))
        XCTAssertEqual(FocusRange(magnitude: 9).magnitude, 3, "magnitude clamps")
    }

    // MARK: - Planning

    func testFrameCountCoversTheSpanInclusively() {
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 12, stepsPerFrame: 1), 13)
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 12, stepsPerFrame: 2), 7)
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 12, stepsPerFrame: 4), 4)
        // Uneven division rounds up: stopping short leaves the back of the subject soft.
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 10, stepsPerFrame: 4), 4)
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 1, stepsPerFrame: 4), 2)
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 0, stepsPerFrame: 1), 2)
    }

    func testPlanAlwaysRunsNearToFar() {
        var forward = FocusRange(magnitude: 1)
        forward.markNear()
        forward.move(by: 12)
        forward.markFar()

        var backward = FocusRange(magnitude: 1)
        backward.markFar()
        backward.move(by: -12)
        backward.markNear()

        for range in [forward, backward] {
            let plan = FocusRangePlanner.plan(for: range, overlap: .tight,
                                              settleSeconds: 0.4, returnToStart: true)
            XCTAssertNotNil(plan)
            XCTAssertFalse(plan!.step.isNear, "a bracket always walks away from the camera")
            XCTAssertEqual(plan!.step.magnitude, range.magnitude)
            XCTAssertEqual(plan!.stepsPerFrame, 2)
            XCTAssertEqual(plan!.frameCount, 7)
        }
    }

    /// A range needing more frames than a bracket holds must be reported, not silently truncated —
    /// a bracket that quietly stops short only shows up as a soft patch in the merge.
    func testFrameLimitIsReported() {
        XCTAssertTrue(FocusRangePlanner.exceedsFrameLimit(span: 200, stepsPerFrame: 1))
        XCTAssertFalse(FocusRangePlanner.exceedsFrameLimit(span: 12, stepsPerFrame: 1))
        XCTAssertEqual(FocusRangePlanner.frameCount(span: 500, stepsPerFrame: 1),
                       FocusStackPlan.frameRange.upperBound)
    }

    /// A stack with gaps can't be fixed afterwards — the missing focus was never recorded — while
    /// extra frames only cost time, so the safest spacing is the right default.
    func testOverlapDefaultsToTheSafestSetting() {
        XCTAssertEqual(FocusOverlap.default, .maximum)
        XCTAssertEqual(FocusOverlap.maximum.stepsPerFrame, 1)
        for option in FocusOverlap.allCases {
            XCTAssertEqual(option.stepsPerFrame, option.rawValue)
            XCTAssertFalse(option.label.isEmpty)
            XCTAssertFalse(option.detail.isEmpty)
        }
    }

    // MARK: - Auto-find scan

    private func samples(_ curve: [Int: Int]) -> [FocusScanSample] {
        curve.map { FocusScanSample(position: $0.key, score: $0.value) }
    }

    func testScanReadsTheSharpRun() throws {
        let curve: [Int: Int] = [-6: 10, -5: 12, -4: 15, -3: 25, -2: 62, -1: 80, 0: 95,
                                 1: 92, 2: 84, 3: 70, 4: 61, 5: 30, 6: 14, 7: 11]
        let suggestion = try XCTUnwrap(FocusScanReader.read(samples(curve)))
        XCTAssertEqual(suggestion.peakPosition, 0)
        XCTAssertEqual(suggestion.nearMark, -2)
        XCTAssertEqual(suggestion.farMark, 4)
        XCTAssertFalse(suggestion.clippedAtEdge)
        // The scan walks out and back, so samples arrive in whatever order it visited them.
        XCTAssertEqual(FocusScanReader.read(samples(curve).shuffled()), suggestion)
    }

    /// A subject running past the scanned window is a range floor, not the whole subject, and the
    /// photographer has to be told so they can extend it.
    func testScanFlagsARunReachingTheWindowEdge() {
        let scores = [40, 60, 80, 95, 90, 88, 86]
        let clipped = (0..<scores.count).map { FocusScanSample(position: $0, score: scores[$0]) }
        XCTAssertEqual(FocusScanReader.read(clipped)?.clippedAtEdge, true)
    }

    /// A scan that never rises saw no focus transition — a textureless subject, or a lens that
    /// never moved. Suggesting a range from that is worse than admitting nothing.
    func testFlatScanYieldsNothing() {
        XCTAssertNil(FocusScanReader.read((-5...5).map { FocusScanSample(position: $0, score: 44) }))
        XCTAssertNil(FocusScanReader.read((-5...5).map {
            FocusScanSample(position: $0, score: 44 + abs($0) % 2)
        }))
        XCTAssertNil(FocusScanReader.read([FocusScanSample(position: 0, score: 90)]))
    }

    /// A distant highlight or a second object can push an unrelated position over the threshold;
    /// walking outward from the peak keeps the range from stretching across a gap.
    func testScanDoesNotStretchAcrossAGap() throws {
        let twoPeaks: [Int: Int] = [-1: 20, 0: 95, 1: 88, 2: 30, 3: 12, 4: 15, 5: 90, 6: 20]
        let suggestion = try XCTUnwrap(FocusScanReader.read(samples(twoPeaks)))
        XCTAssertEqual(suggestion.nearMark, 0)
        XCTAssertEqual(suggestion.farMark, 1)
    }
}

/// The depth map: where each part of the frame comes into focus across a sweep.
final class FocusDepthMapTests: XCTestCase {

    /// A scene with three surfaces at known focus offsets, plus blank tiles with no detail.
    private func scene(planes: [Int: Int], blankCells: Set<Int>, offsets: [Int]) -> [Int: [Double]] {
        var frames: [Int: [Double]] = [:]
        let cells = FocusDepthMap.grid * FocusDepthMap.grid
        for offset in offsets {
            var tiles = [Double](repeating: 0, count: cells)
            for cell in 0..<cells {
                if blankCells.contains(cell) { tiles[cell] = 0.001; continue }
                let peakAt = planes[cell] ?? 0
                let distance = Double(abs(offset - peakAt))
                tiles[cell] = 1.0 / (1.0 + distance * 0.4)
            }
            frames[offset] = tiles
        }
        return frames
    }

    private func centreCell(_ column: Int, _ row: Int) -> Int { row * FocusDepthMap.grid + column }

    func testFindsEachTilesFocusOffset() {
        let planes = [centreCell(5, 5): -10, centreCell(6, 5): 0, centreCell(6, 6): 12]
        let frames = scene(planes: planes, blankCells: [], offsets: Array(-30...30))
        let map = FocusDepthMap(framesByOffset: frames)
        for (cell, expected) in planes {
            let peak = map.peaks.first { $0.cell == cell }
            XCTAssertEqual(peak?.offset, expected, "tile \(cell) should peak at \(expected)")
        }
    }

    /// Tiles with no detail must be discarded: a blank wall focuses at no distance, and letting it
    /// vote would anchor the range wherever its noise happened to peak.
    func testTilesWithoutDetailAreIgnored() {
        let blank = Set(0..<(FocusDepthMap.grid * FocusDepthMap.grid / 2))
        let planes = [centreCell(5, 5): -8, centreCell(6, 6): 6]
        let frames = scene(planes: planes, blankCells: blank, offsets: Array(-20...20))
        let map = FocusDepthMap(framesByOffset: frames)
        XCTAssertTrue(map.usableTiles.allSatisfy { !blank.contains($0.cell) })
        XCTAssertFalse(map.usableTiles.isEmpty)
    }

    /// The range must span the subject's surfaces, which is the whole point — a range covering only
    /// the nearest surface is what made earlier stacks miss most of the subject.
    func testRangeSpansTheSubjectsDepth() throws {
        var planes: [Int: Int] = [:]
        for row in 4..<8 {
            planes[centreCell(5, row)] = -10
            planes[centreCell(6, row)] = 0
            planes[centreCell(7, row)] = 14
        }
        let frames = scene(planes: planes, blankCells: [], offsets: Array(-40...40))
        let map = FocusDepthMap(framesByOffset: frames)
        let range = try XCTUnwrap(map.subjectRange())
        XCTAssertLessThanOrEqual(range.near, -10, "must reach the nearest surface")
        XCTAssertGreaterThanOrEqual(range.far, 14, "must reach the furthest surface")
        XCTAssertGreaterThan(map.coverage(near: range.near, far: range.far), 0.85)
    }

    /// Narrowing the range must lose coverage — the property that makes coverage meaningful advice.
    func testNarrowingTheRangeLosesCoverage() throws {
        var planes: [Int: Int] = [:]
        for row in 4..<8 {
            planes[centreCell(5, row)] = -12
            planes[centreCell(6, row)] = 0
            planes[centreCell(7, row)] = 12
        }
        let frames = scene(planes: planes, blankCells: [], offsets: Array(-40...40))
        let map = FocusDepthMap(framesByOffset: frames)
        let full = try XCTUnwrap(map.subjectRange())
        let wide = map.coverage(near: full.near, far: full.far)
        let narrow = map.coverage(near: -2, far: 2)
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertLessThan(narrow, 0.5)
    }

    /// Border tiles are excluded: a distant corner coming into focus would otherwise stretch the
    /// stack across the entire scene depth.
    func testBackgroundAtTheEdgesDoesNotStretchTheRange() throws {
        var planes: [Int: Int] = [:]
        for row in 4..<8 { for column in 4..<8 { planes[centreCell(column, row)] = 0 } }
        for row in 0..<FocusDepthMap.grid { planes[centreCell(0, row)] = -60 }
        let frames = scene(planes: planes, blankCells: [], offsets: Array(-70...70))
        let map = FocusDepthMap(framesByOffset: frames)
        let range = try XCTUnwrap(map.subjectRange())
        XCTAssertGreaterThan(range.near, -30, "a far-left background column must not drag the range out")
    }

    /// Depth of field decides how many frames a stack needs, so it must be measured from the sweep
    /// rather than assumed. A wider depth of field must mean fewer frames.
    func testDepthOfFieldWidensWithBlurFalloff() throws {
        func sceneWith(falloff: Double) -> [Int: [Double]] {
            var frames: [Int: [Double]] = [:]
            let cells = FocusDepthMap.grid * FocusDepthMap.grid
            for offset in -40...40 {
                var tiles = [Double](repeating: 0.001, count: cells)
                for row in 4..<10 {
                    for column in 4..<10 {
                        let distance = Double(abs(offset))
                        tiles[row * FocusDepthMap.grid + column] = 1.0 / (1.0 + distance * falloff)
                    }
                }
                frames[offset] = tiles
            }
            return frames
        }
        let shallow = try XCTUnwrap(FocusDepthMap(framesByOffset: sceneWith(falloff: 0.5)).depthOfFieldSteps())
        let deep = try XCTUnwrap(FocusDepthMap(framesByOffset: sceneWith(falloff: 0.05)).depthOfFieldSteps())
        XCTAssertGreaterThan(deep, shallow, "a slower falloff is a deeper depth of field")
        XCTAssertGreaterThanOrEqual(shallow, 1)
    }

    /// Too few tiles to measure must report nothing rather than a fabricated number — the caller
    /// falls back instead of shooting a bracket spaced on noise.
    func testDepthOfFieldNeedsEnoughTiles() {
        XCTAssertNil(FocusDepthMap(framesByOffset: [:]).depthOfFieldSteps())
    }

    func testEmptyInputYieldsNoRange() {
        XCTAssertNil(FocusDepthMap(framesByOffset: [:]).subjectRange())
        XCTAssertTrue(FocusDepthMap(framesByOffset: [:]).peaks.isEmpty)
    }
}

/// Choosing the bracket's spacing, which the app now does instead of asking.
final class FocusOverlapAutoTests: XCTestCase {

    /// The only reason not to shoot every step is the frame limit, so take the finest that fits.
    func testPicksTheTightestSpacingThatFits() {
        XCTAssertEqual(FocusOverlap.tightestThatFits(span: 18), .maximum)   // 19 frames
        XCTAssertEqual(FocusOverlap.tightestThatFits(span: 39), .maximum)   // 40 frames, exactly the cap
        XCTAssertEqual(FocusOverlap.tightestThatFits(span: 50), .tight)     // 26 frames
        XCTAssertEqual(FocusOverlap.tightestThatFits(span: 90), .moderate)
    }

    /// Whatever it returns must actually be shootable, or the range gets silently truncated.
    func testChosenSpacingAlwaysFitsWhereItCan() {
        for span in stride(from: 2, through: 150, by: 4) {
            let overlap = FocusOverlap.tightestThatFits(span: span)
            let frames = FocusRangePlanner.frameCount(span: span, stepsPerFrame: overlap.stepsPerFrame)
            XCTAssertGreaterThanOrEqual(frames, 2)
            if !FocusRangePlanner.exceedsFrameLimit(span: span, stepsPerFrame: FocusOverlap.loose.stepsPerFrame) {
                XCTAssertLessThanOrEqual(frames, FocusStackPlan.frameRange.upperBound,
                                         "span \(span) should fit with \(overlap.label)")
            }
        }
    }

    /// A span too deep for even the loosest spacing must still return something shootable, with the
    /// caller left to warn — silently dropping part of a measured range is the worse failure.
    func testImpossiblySpanFallsBackRatherThanFailing() {
        let overlap = FocusOverlap.tightestThatFits(span: 400)
        XCTAssertEqual(overlap, .loose)
        XCTAssertTrue(FocusRangePlanner.exceedsFrameLimit(span: 400, stepsPerFrame: overlap.stepsPerFrame))
    }
}

/// Which end a bracket starts from, now that the scan leaves focus at one extreme.
final class FocusBracketDirectionTests: XCTestCase {

    private func range(near: Int, far: Int, position: Int) -> FocusRange {
        var r = FocusRange(magnitude: 1, position: position)
        r.nearMark = near
        r.farMark = far
        return r
    }

    /// Focus parked at the far end must shoot backwards rather than walk the whole span first.
    /// That walk was ~90 steps of travel for nothing.
    func testStartsFromWhicheverEndIsNearer() throws {
        let atFarEnd = try XCTUnwrap(FocusRangePlanner.startEnd(for: range(near: -20, far: 10, position: 12)))
        XCTAssertEqual(atFarEnd.start, 10)
        XCTAssertTrue(atFarEnd.towardCamera, "starting at the far end means stepping toward the camera")

        let atNearEnd = try XCTUnwrap(FocusRangePlanner.startEnd(for: range(near: -20, far: 10, position: -25)))
        XCTAssertEqual(atNearEnd.start, -20)
        XCTAssertFalse(atNearEnd.towardCamera)
    }

    /// Whichever way round the marks were made, the ends are the ends.
    func testMarkOrderDoesNotChangeTheEnds() throws {
        let forward = try XCTUnwrap(FocusRangePlanner.startEnd(for: range(near: -20, far: 10, position: 12)))
        let swapped = try XCTUnwrap(FocusRangePlanner.startEnd(for: range(near: 10, far: -20, position: 12)))
        XCTAssertEqual(forward.start, swapped.start)
        XCTAssertEqual(forward.towardCamera, swapped.towardCamera)
    }

    /// The plan must step in the direction that actually crosses the range.
    func testPlanStepsAcrossTheRangeFromEitherEnd() throws {
        for position in [-25, 12] {
            let r = range(near: -20, far: 10, position: position)
            let plan = try XCTUnwrap(FocusRangePlanner.plan(for: r, overlap: .maximum,
                                                            settleSeconds: 0.25, returnToStart: true))
            let end = try XCTUnwrap(FocusRangePlanner.startEnd(for: r))
            XCTAssertEqual(plan.step.isNear, end.towardCamera)
            XCTAssertEqual(plan.frameCount,
                           FocusRangePlanner.frameCount(span: 30, stepsPerFrame: 1))
        }
    }

    func testNoStartEndWithoutAUsableRange() {
        XCTAssertNil(FocusRangePlanner.startEnd(for: FocusRange(magnitude: 1)))
        XCTAssertNil(FocusRangePlanner.startEnd(for: range(near: 5, far: 5, position: 0)))
    }
}

/// The frame cap must never silently shorten a measured range.
final class FocusFrameCapTests: XCTestCase {

    /// A 48-step subject at 1-step spacing needs 49 frames and the cap is 40 — the old behaviour
    /// clamped the count and left the last nine steps unphotographed.
    func testWideningSpacingCoversTheWholeRange() {
        let span = 48
        var spacing = 1
        while FocusRangePlanner.exceedsFrameLimit(span: span, stepsPerFrame: spacing),
              spacing < FocusStackPlan.stepsPerFrameRange.upperBound {
            spacing += 1
        }
        let frames = FocusRangePlanner.frameCount(span: span, stepsPerFrame: spacing)
        XCTAssertLessThanOrEqual(frames, FocusStackPlan.frameRange.upperBound)
        // The frames must actually span the range, not stop short.
        XCTAssertGreaterThanOrEqual((frames - 1) * spacing, span)
    }

    /// Whatever the span, the chosen spacing must cover it within the cap wherever that is possible.
    func testEveryReasonableSpanCanBeCovered() {
        for span in stride(from: 4, through: 160, by: 4) {
            var spacing = 1
            while FocusRangePlanner.exceedsFrameLimit(span: span, stepsPerFrame: spacing),
                  spacing < FocusStackPlan.stepsPerFrameRange.upperBound {
                spacing += 1
            }
            let frames = FocusRangePlanner.frameCount(span: span, stepsPerFrame: spacing)
            if spacing < FocusStackPlan.stepsPerFrameRange.upperBound {
                XCTAssertGreaterThanOrEqual((frames - 1) * spacing, span,
                                            "span \(span) at every \(spacing) steps leaves a gap")
            }
        }
    }
}
