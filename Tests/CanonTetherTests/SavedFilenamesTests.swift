import XCTest
import CanonTetherCore

final class SavedFilenamesTests: XCTestCase {

    func testExtractsSingleFilename() {
        let output = """
        capture-image-and-download --force-overwrite
        New file is in location /capt0000.cr2 on the camera
        Saving file as capt0000.cr2
        gphoto2: {...} />
        """
        XCTAssertEqual(CaptureOutput.savedFilenames(in: output), ["capt0000.cr2"])
    }

    func testExtractsMultipleFilenamesInOrder() {
        // One wait-event window can download several frames (e.g. a burst).
        let output = """
        Saving file as capt0000.cr2
        Saving file as capt0001.cr2
        Saving file as capt0002.cr2
        gphoto2: {...} />
        """
        XCTAssertEqual(CaptureOutput.savedFilenames(in: output),
                       ["capt0000.cr2", "capt0001.cr2", "capt0002.cr2"])
    }

    func testHandlesMarkerMidLineAfterOverwritePrompt() {
        // The "Saving file as" text can land right after an answered [y|n] prompt with no newline
        // before it, so extraction must be marker-position based, not per-line.
        let output = "File capt0000.cr2 exists. Overwrite? [y|n] ySaving file as capt0000.cr2\n"
        XCTAssertEqual(CaptureOutput.savedFilenames(in: output), ["capt0000.cr2"])
    }

    func testNoMatchesReturnsEmpty() {
        let output = "wait-event-and-download 2s\ngphoto2: {...} />"
        XCTAssertTrue(CaptureOutput.savedFilenames(in: output).isEmpty)
    }
}
