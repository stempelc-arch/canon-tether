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

    func testSubjectThatPeakedAndFellAwayStopsTheSweep() {
        var monitor = FocusSweepMonitor()
        var stop: FocusSweepMonitor.Stop?
        for offset in 0..<12 where stop == nil {
            stop = monitor.record(offset: offset, tiles: flat(1), unchanged: false)
        }
        XCTAssertNil(stop, "a subject still sharp is not stopped on")
        for offset in 12..<20 where stop == nil {
            stop = monitor.record(offset: offset, tiles: flat(0.2), unchanged: false)
        }
        XCTAssertEqual(stop, .measured)
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
        var edge = 0.01
        for offset in 12..<24 where stop == nil {
            edge *= 1.5
            stop = monitor.record(offset: offset, tiles: split(middle: 0.1, edge: edge), unchanged: false)
        }
        XCTAssertNil(stop, "the aggregate has fallen, but parts of the scene are still coming into focus")
        XCTAssertTrue(monitor.stillImproving)
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
}
