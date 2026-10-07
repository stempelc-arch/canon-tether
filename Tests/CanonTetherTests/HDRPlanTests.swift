import XCTest
@testable import CanonTetherCore

final class HDRPlanTests: XCTestCase {

    /// A 1D X Mark II third-stop shutter list, as the body reports it.
    private let choices = ["30","25","20","15","13","10","8","6","5","4","3.2","2.5","2","1.6","1.3","1",
                           "0.8","0.6","0.5","0.4","0.3","1/4","1/5","1/6","1/8","1/10","1/13","1/15",
                           "1/20","1/25","1/30","1/40","1/50","1/60","1/80","1/100","1/125","1/160",
                           "1/200","1/250","1/320","1/400","1/500","1/640","1/800","1/1000","1/1250",
                           "1/1600","1/2000","1/2500","1/3200","1/4000","1/5000","1/6400","1/8000"]

    /// `ExposureGrid.stops` measures shutter as `-log2(seconds)`, so its scale rises as the frame
    /// gets *darker*. Getting that sign backwards shoots the bracket inside out — the merge still
    /// runs and the result quietly loses the range it was supposed to gain.
    func testShutterOffsetsGoTheRightWay() {
        XCTAssertEqual(HDRPlan.shutter(stopsFrom: "1/125", stops: -2, in: choices), "1/500")
        XCTAssertEqual(HDRPlan.shutter(stopsFrom: "1/125", stops: 2, in: choices), "1/30")
        XCTAssertEqual(HDRPlan.shutter(stopsFrom: "1/125", stops: -4, in: choices), "1/2000")
        XCTAssertEqual(HDRPlan.shutter(stopsFrom: "1/125", stops: 4, in: choices), "1/8")
        XCTAssertEqual(HDRPlan.shutter(stopsFrom: "1/125", stops: 0, in: choices), "1/125")
    }


    /// Running out of shutter range is refused, never silently shot at whatever is nearest: a
    /// bracket at the wrong offsets produces a merge that looks fine and holds less range.
    func testOutOfRangeIsRefused() {
        XCTAssertNil(HDRPlan.shutter(stopsFrom: "1/8000", stops: -2, in: choices))
    }

    /// Bodies set to half-stop increments offer a different list; the nearest value within a third
    /// of a stop still counts.
    func testWorksOnAHalfStopGrid() {
        let halves = ["1/30","1/45","1/60","1/90","1/125","1/180","1/250","1/350","1/500","1/750","1/1000"]
        XCTAssertEqual(HDRPlan.shutter(stopsFrom: "1/125", stops: -2, in: halves), "1/500")
    }

}
