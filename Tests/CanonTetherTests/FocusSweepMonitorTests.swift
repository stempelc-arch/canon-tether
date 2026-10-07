import XCTest
@testable import CanonTetherCore

/// Every case here is a failure that reached the photographer on real hardware.
///
/// The stop rules used to live inline in `GPhotoSession.scanFocus`, where the only way to check a
/// calibration was to shoot a sweep and read the log. Four separate misfires shipped that way.
final class FocusSweepMonitorTests: XCTestCase {

    private let grid = FocusDepthMap.grid

    private func flat(_ value: Double) -> [Double] {
        [Double](repeating: value, count: grid * grid)
    }

    /// Middle tiles at `middle`, edge tiles at `edge` — the aggregate reads only the middle.
    private func split(middle: Double, edge: Double) -> [Double] {
        var tiles = flat(edge)
        for row in (grid / 4)..<(grid - grid / 4) {
            for column in (grid / 4)..<(grid - grid / 4) {
                tiles[row * grid + column] = middle
            }
        }
        return tiles
    }

    /// The sweep opens by driving into the near stop, so its first frames are identical by design.
    /// Reading that as travel exhausted aborted real sweeps after four samples, reporting a
    /// well-textured subject as having no usable tiles.
    func testOpeningPlateauDoesNotStopTheSweep() {
        var monitor = FocusSweepMonitor()
        for offset in 0..<25 {
            let stop = monitor.record(offset: offset, tiles: flat(1),
                                      unchanged: offset == 0 ? nil : true)
            XCTAssertNil(stop, "a sweep that has never moved cannot be at the end of its travel")
        }
    }

    /// A defocused subject barely changes between two focus steps either. At three samples the
    /// end-of-travel rule sat well inside the ordinary blurred end of a sweep.
    func testDefocusedPlateauDoesNotStopTheSweep() {
        var monitor = FocusSweepMonitor()
        for offset in 0..<6 {
            XCTAssertNil(monitor.record(offset: offset, tiles: flat(1),
                                        unchanged: offset == 0 ? nil : false))
        }
        for offset in 6..<(6 + FocusSweepMonitor.endOfTravelSamples - 1) {
            XCTAssertNil(monitor.record(offset: offset, tiles: flat(1), unchanged: true),
                         "one sample short of the rule must not stop the sweep")
        }
    }

    func testGenuineEndOfTravelIsStillCaught() {
        var monitor = FocusSweepMonitor()
        var stop: FocusSweepMonitor.Stop?
        var samples = 0
        for offset in 0..<6 where stop == nil {
            stop = monitor.record(offset: offset, tiles: flat(1),
                                  unchanged: offset == 0 ? nil : false)
            samples += 1
        }
        for offset in 6..<40 where stop == nil {
            stop = monitor.record(offset: offset, tiles: flat(1), unchanged: true)
            samples += 1
        }
        XCTAssertEqual(stop, .endOfTravel)
        XCTAssertGreaterThanOrEqual(samples, FocusSweepMonitor.minimumSamples)
    }

    /// Neither rule may end a sweep that has not yet collected enough to be worth trusting.
    func testNoStopBeforeTheMinimumSampleCount() {
        var monitor = FocusSweepMonitor()
        _ = monitor.record(offset: 0, tiles: flat(1), unchanged: nil)
        _ = monitor.record(offset: 1, tiles: flat(1), unchanged: false)
        for offset in 2..<(FocusSweepMonitor.minimumSamples - 1) {
            // Identical *and* fallen away — both rules pulling at once.
            XCTAssertNil(monitor.record(offset: offset, tiles: flat(0.1), unchanged: true))
        }
    }

    /// Offsets step by 2, as a real sweep does, and run well past the peak: the sweep may not
    /// finish until it has travelled `minimumTravelPastPeak` beyond the sharpest point, so anything
    /// behind the subject has had a chance to come into focus.
    func testSubjectThatPeakedAndFellAwayStopsTheSweep() {
        var monitor = FocusSweepMonitor()
        var stop: FocusSweepMonitor.Stop?
        for step in 0..<12 where stop == nil {
            stop = monitor.record(offset: step * 2, tiles: flat(1), unchanged: false)
        }
        XCTAssertNil(stop, "a subject still sharp is not stopped on")
        var lastOffset = 0
        for step in 12..<60 where stop == nil {
            lastOffset = step * 2
            stop = monitor.record(offset: lastOffset, tiles: flat(0.2), unchanged: false)
        }
        XCTAssertEqual(stop, .measured)
        XCTAssertGreaterThanOrEqual(lastOffset, FocusSweepMonitor.minimumTravelPastPeak,
                                    "only after looking far enough behind the subject")
    }

    /// Aggregate sharpness is dominated by whatever is brightest and most textured. A real sweep
    /// ended while nine tiles were still improving: the range came out 12 steps wide for a subject
    /// that ran much further, and the far end of the stack was soft.
    func testTilesStillSharpeningHoldTheSweepOpen() {
        var monitor = FocusSweepMonitor()
        var stop: FocusSweepMonitor.Stop?
        for offset in 0..<12 where stop == nil {
            stop = monitor.record(offset: offset, tiles: split(middle: 1, edge: 0.01), unchanged: false)
        }
        // The middle collapses, taking the aggregate well past falloff, while a handful of tiles
        // inside the judged area climb on slowly.
        var climber = 1.1
        for offset in 12..<24 where stop == nil {
            climber *= 1.06
            var tiles = split(middle: 0.1, edge: 0.01)
            for k in 0..<5 { tiles[(grid / 2) * grid + grid / 4 + k] = climber }
            stop = monitor.record(offset: offset, tiles: tiles, unchanged: false)
        }
        XCTAssertNil(stop, "the aggregate has fallen, but parts of the subject are still coming into focus")
        XCTAssertTrue(monitor.stillImproving)
    }

    /// The sweep's stop rules must use the same box the depth map does.
    ///
    /// Judging improvement over the whole frame meant that as focus racked past the subject, the
    /// background came into focus and the sweep read it as "the subject is still sharpening".
    /// Measured on a real run: 190 steps of travel and 96 samples for a subject occupying 80 steps
    /// and 40 samples — 59% of the sweep spent looking past where it needed to.
    func testImprovementIsJudgedInsideTheSubjectBoxOnly() {
        let corner = FocusDepthMap.Region(x: 0, y: 0, width: 0.25, height: 0.25)
        var boxed = FocusSweepMonitor(region: corner)
        var wholeFrame = FocusSweepMonitor()
        var background = 0.01
        for offset in 0..<10 {
            background *= 1.5
            var tiles = flat(background)                    // everything outside keeps sharpening
            for row in 0..<(grid / 4) {
                for column in 0..<(grid / 4) { tiles[row * grid + column] = 1 }   // static subject
            }
            _ = boxed.record(offset: offset, tiles: tiles, unchanged: false)
            _ = wholeFrame.record(offset: offset, tiles: tiles, unchanged: false)
        }
        XCTAssertFalse(boxed.stillImproving,
                       "a static subject is not 'still sharpening' because the background is")
        XCTAssertTrue(wholeFrame.stillImproving,
                      "whole-frame judging is fooled by the background — the behaviour this replaced")
    }

    /// A false end of travel truncates the sweep; a false "moved" costs one sample. So an
    /// unmeasurable frame must count as movement.
    func testUnreadableFrameCountsAsMovement() {
        var monitor = FocusSweepMonitor()
        _ = monitor.record(offset: 0, tiles: flat(1), unchanged: false)
        for offset in 1..<30 {
            XCTAssertNil(monitor.record(offset: offset, tiles: flat(1), unchanged: nil))
        }
        XCTAssertFalse(monitor.isAtEndOfTravel)
    }

    /// The caller must not extend a sweep whose lens has run out of travel — extending further only
    /// re-photographs the same frame.
    func testEndOfTravelGatesTheExtensionLoop() {
        var monitor = FocusSweepMonitor()
        _ = monitor.record(offset: 0, tiles: flat(1), unchanged: false)
        XCTAssertFalse(monitor.isAtEndOfTravel)
        for offset in 1..<30 { _ = monitor.record(offset: offset, tiles: flat(1), unchanged: true) }
        XCTAssertTrue(monitor.isAtEndOfTravel)
    }

    /// A second surface coming into focus must keep the sweep running.
    ///
    /// Tiles of a mesh peak on the wires and then fall away; when the contents behind come into
    /// focus those same tiles climb *again*, without ever beating the wires. Counting only new
    /// bests, the sweep stopped at +9 on a real pen cup whose pens came sharp at +29 — so the
    /// depth map had nothing past the wires to find and the stack left the contents soft.
    func testASecondSurfaceComingIntoFocusKeepsTheSweepOpen() {
        var monitor = FocusSweepMonitor()
        var stop: FocusSweepMonitor.Stop?
        // The front surface sharpens and falls away.
        for offset in 0..<14 where stop == nil {
            let value = 1.0 - abs(Double(offset) - 4) * 0.12
            stop = monitor.record(offset: offset, tiles: split(middle: max(value, 0.08), edge: 0.01),
                                  unchanged: false)
        }
        // Now something behind it climbs back — never beating the front peak.
        for offset in 14..<26 where stop == nil {
            let value = 0.08 + Double(offset - 14) * 0.03
            stop = monitor.record(offset: offset, tiles: split(middle: value, edge: 0.01), unchanged: false)
        }
        XCTAssertNil(stop, "tiles climbing out of their own trough are a second surface arriving")
        XCTAssertTrue(monitor.stillImproving)
    }

    /// The counterpart: an opaque subject falls away and stays down, and must not be kept open by
    /// the noise that always makes a few tiles tick upward.
    func testAnOpaqueSubjectStillStopsTheSweep() {
        var monitor = FocusSweepMonitor()
        var stop: FocusSweepMonitor.Stop?
        for step in 0..<60 where stop == nil {
            let value = 1.0 - abs(Double(step) - 4) * 0.12
            stop = monitor.record(offset: step * 2, tiles: split(middle: max(value, 0.05), edge: 0.01),
                                  unchanged: false)
        }
        XCTAssertEqual(stop, .measured, "nothing is coming into focus any more")
    }
}
