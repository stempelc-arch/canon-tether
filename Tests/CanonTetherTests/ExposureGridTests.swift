import XCTest
import CanonTetherCore

/// Value lists as gphoto2 reports them off a 1DX II, per exposure-increment custom function.
private enum Lists {
    static let thirdShutter = ["bulb", "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40",
                               "1/50", "1/60", "1/80", "1/100", "1/125", "1/160", "1/200", "1/250",
                               "1/320", "1/400", "1/500", "1/640", "1/800", "1/1000"]
    static let thirdAperture = ["1.4", "1.6", "1.8", "2", "2.2", "2.5", "2.8", "3.2", "3.5", "4",
                                "4.5", "5", "5.6", "6.3", "7.1", "8", "9", "10", "11", "13", "14",
                                "16", "18", "20", "22"]
    static let halfShutter = ["bulb", "1/8", "1/10", "1/15", "1/20", "1/30", "1/45", "1/60", "1/90",
                              "1/125", "1/180", "1/250", "1/350", "1/500", "1/750", "1/1000"]
    static let halfAperture = ["1.4", "1.7", "2", "2.4", "2.8", "3.5", "4", "4.8", "5.6", "6.7", "8",
                               "9.5", "11", "13", "16", "19", "22"]
}

private func settings(shutter: [String], aperture: [String], iso: [String] = []) -> [CameraSetting] {
    var result = [
        CameraSetting(path: ExposureGrid.shutterPath, label: "Shutter Speed",
                      current: shutter.last ?? "", choices: shutter, readOnly: false),
        CameraSetting(path: ExposureGrid.aperturePath, label: "Aperture",
                      current: aperture.first ?? "", choices: aperture, readOnly: false)
    ]
    if !iso.isEmpty {
        result.append(CameraSetting(path: ExposureGrid.isoPath, label: "ISO Speed",
                                    current: iso.first ?? "", choices: iso, readOnly: false))
    }
    return result
}

final class ExposureGridTests: XCTestCase {
    func testDetectsThirdStopGrid() {
        XCTAssertEqual(
            ExposureGrid.detect(in: settings(shutter: Lists.thirdShutter, aperture: Lists.thirdAperture)),
            .third
        )
    }

    func testDetectsHalfStopGrid() {
        XCTAssertEqual(
            ExposureGrid.detect(in: settings(shutter: Lists.halfShutter, aperture: Lists.halfAperture)),
            .half
        )
    }

    /// ISO follows its own custom function ("ISO speed setting increments"), so a body on 1-stop ISO
    /// must not drag the reading off the shutter/aperture grid.
    func testFullStopISODoesNotAffectDetection() {
        let fullStopISO = ["Auto", "100", "200", "400", "800", "1600", "3200", "6400"]
        XCTAssertEqual(
            ExposureGrid.detect(in: settings(shutter: Lists.thirdShutter,
                                             aperture: Lists.thirdAperture,
                                             iso: fullStopISO)),
            .third
        )
    }

    /// Detection has to reject rather than guess when the camera is on neither grid — otherwise the
    /// inspector would print a confident readout that doesn't match the body.
    func testFullStopListsAreNotReportedAsAGrid() {
        let fullShutter = ["bulb", "1/8", "1/15", "1/30", "1/60", "1/125", "1/250", "1/500", "1/1000"]
        let fullAperture = ["1.4", "2", "2.8", "4", "5.6", "8", "11", "16", "22"]
        XCTAssertNil(ExposureGrid.detect(in: settings(shutter: fullShutter, aperture: fullAperture)))
    }

    func testTooFewValuesIsUndetermined() {
        XCTAssertNil(ExposureGrid.detect(in: settings(shutter: ["1/60", "1/80"], aperture: ["4"])))
        XCTAssertNil(ExposureGrid.detect(in: []))
    }

    /// "bulb" breaks the chain instead of being skipped, so no gap is measured across it.
    func testNonNumericEntriesDoNotCreateGaps() {
        let withHoles = ["bulb", "1/8", "1/10", "1/13", "1/15", "Unknown value", "1/500", "1/640",
                         "1/800", "1/1000"]
        XCTAssertEqual(
            ExposureGrid.detect(in: settings(shutter: withHoles, aperture: Lists.thirdAperture)),
            .third
        )
    }

    func testStopsConversions() {
        XCTAssertEqual(ExposureGrid.stops(of: "200", path: ExposureGrid.isoPath)!, 1.0, accuracy: 0.001)
        XCTAssertEqual(ExposureGrid.stops(of: "1/125", path: ExposureGrid.shutterPath)!,
                       ExposureGrid.stops(of: "1/250", path: ExposureGrid.shutterPath)! - 1.0,
                       accuracy: 0.001)
        XCTAssertEqual(ExposureGrid.stops(of: "f/2.8", path: ExposureGrid.aperturePath)!, 3.0, accuracy: 0.01)
        XCTAssertNil(ExposureGrid.stops(of: "Auto", path: ExposureGrid.isoPath))
        XCTAssertNil(ExposureGrid.stops(of: "bulb", path: ExposureGrid.shutterPath))
    }

    func testSecondsParsing() {
        XCTAssertEqual(ExposureGrid.seconds(from: "1/125")!, 0.008, accuracy: 0.0001)
        XCTAssertEqual(ExposureGrid.seconds(from: "0.3")!, 0.3, accuracy: 0.0001)
        XCTAssertEqual(ExposureGrid.seconds(from: "30")!, 30, accuracy: 0.0001)
        XCTAssertNil(ExposureGrid.seconds(from: "bulb"))
    }
}
