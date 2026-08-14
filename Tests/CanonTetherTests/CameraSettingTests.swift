import XCTest
import CanonTetherCore

final class CameraSettingTests: XCTestCase {

    // A representative RADIO property as gphoto2 prints it.
    private let isoOutput = """
    Label: ISO Speed
    Readonly: 0
    Type: RADIO
    Current: 800
    Choice: 0 Auto
    Choice: 1 100
    Choice: 2 200
    Choice: 10 800
    END
    """

    func testParsesLabelCurrentAndChoices() {
        let setting = CameraSetting.parse(from: isoOutput, path: "/main/imgsettings/iso")
        XCTAssertNotNil(setting)
        XCTAssertEqual(setting?.label, "ISO Speed")
        XCTAssertEqual(setting?.current, "800")
        XCTAssertEqual(setting?.readOnly, false)
        XCTAssertEqual(setting?.choices, ["Auto", "100", "200", "800"])
    }

    func testMultiWordChoiceValuesArePreserved() {
        // Image Format choices contain spaces ("Large Fine JPEG", "RAW + 0x50") — the leading
        // numeric index must be dropped without truncating the rest of the value.
        let output = """
        Label: Image Format
        Readonly: 0
        Type: RADIO
        Current: RAW
        Choice: 0 Large Fine JPEG
        Choice: 1 RAW
        Choice: 2 RAW + 0x50
        END
        """
        let setting = CameraSetting.parse(from: output, path: "/main/imgsettings/imageformat")
        XCTAssertEqual(setting?.current, "RAW")
        XCTAssertEqual(setting?.choices, ["Large Fine JPEG", "RAW", "RAW + 0x50"])
    }

    func testReadonlyFlagParsed() {
        let output = """
        Label: Battery Level
        Readonly: 1
        Type: TEXT
        Current: 100%
        END
        """
        let setting = CameraSetting.parse(from: output, path: "/main/status/batterylevel")
        XCTAssertEqual(setting?.readOnly, true)
        XCTAssertEqual(setting?.current, "100%")
        XCTAssertTrue(setting?.choices.isEmpty ?? false)
    }

    func testMissingCurrentReturnsNil() {
        // A property the camera doesn't expose in its current mode has no Current: line.
        let output = """
        Label: Aperture
        Readonly: 0
        Type: RADIO
        END
        """
        XCTAssertNil(CameraSetting.parse(from: output, path: "/main/capturesettings/aperture"))
    }

    func testLabelFallsBackToPathComponent() {
        let output = "Current: 5.6\nChoice: 0 5.6\nEND"
        let setting = CameraSetting.parse(from: output, path: "/main/capturesettings/aperture")
        XCTAssertEqual(setting?.label, "aperture")
    }
}
