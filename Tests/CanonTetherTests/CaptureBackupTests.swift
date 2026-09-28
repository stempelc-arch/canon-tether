import XCTest
@testable import CanonTetherCore

final class CaptureBackupTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeFile(at url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func destination(_ name: String, create: Bool = true) throws -> CaptureBackup.Destination {
        let root = scratch.appendingPathComponent(name)
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        return CaptureBackup.Destination(root: root, label: name)
    }

    // MARK: - Layout

    /// The project folder's own name is preserved, so one external can hold several shoots and a
    /// restore is a drag rather than a reconstruction.
    func testRelativePathKeepsTheProjectFolderName() {
        let project = URL(fileURLWithPath: "/Users/x/Desktop/Wedding")
        let file = project.appendingPathComponent("20260928-101500.jpg")
        XCTAssertEqual(CaptureBackup.relativePath(of: file, inProjectAt: project),
                       "Wedding/20260928-101500.jpg")
    }

    /// Focus-stack subfolders come along intact.
    func testRelativePathKeepsSubfolders() {
        let project = URL(fileURLWithPath: "/Users/x/Desktop/Wedding")
        let file = project.appendingPathComponent("20260928-1015 Focus Stack/20260928-1015-stack.tif")
        XCTAssertEqual(CaptureBackup.relativePath(of: file, inProjectAt: project),
                       "Wedding/20260928-1015 Focus Stack/20260928-1015-stack.tif")
    }

    /// A file that isn't under the project still gets backed up, at the root — losing the layout
    /// beats losing the shot.
    func testRelativePathFallsBackToTheFilename() {
        let project = URL(fileURLWithPath: "/Users/x/Desktop/Wedding")
        let stray = URL(fileURLWithPath: "/tmp/strange.jpg")
        XCTAssertEqual(CaptureBackup.relativePath(of: stray, inProjectAt: project), "strange.jpg")
    }

    // MARK: - Copying

    func testMirrorsToEveryDestination() async throws {
        let project = scratch.appendingPathComponent("Shoot")
        let file = project.appendingPathComponent("frame.jpg")
        try makeFile(at: file, bytes: 4096)
        let destinations = [try destination("DriveA"), try destination("DriveB")]

        let outcomes = await CaptureBackup.mirror(file, inProjectAt: project, to: destinations)
        XCTAssertEqual(outcomes.count, 2)
        for outcome in outcomes {
            XCTAssertEqual(outcome.result, .copied(bytes: 4096))
            let copied = outcome.destination.root.appendingPathComponent("Shoot/frame.jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        }
        XCTAssertNil(CaptureBackup.warning(for: outcomes))
    }

    /// Results come back in the order the destinations were given, whatever order the drives
    /// finish in — otherwise the Preferences list reshuffles between shots.
    func testOutcomeOrderFollowsTheDestinationList() async throws {
        let project = scratch.appendingPathComponent("Shoot")
        let file = project.appendingPathComponent("frame.jpg")
        try makeFile(at: file, bytes: 512)
        let destinations = [try destination("A"), try destination("B"), try destination("C")]
        let outcomes = await CaptureBackup.mirror(file, inProjectAt: project, to: destinations)
        XCTAssertEqual(outcomes.map(\.destination.label), ["A", "B", "C"])
    }

    /// **The failure this design exists to prevent.**
    ///
    /// When an external unmounts, its `/Volumes/<name>` folder disappears. Creating directories
    /// along that path writes to the *boot* disk instead — filling the startup volume with what
    /// looks like a successful backup, somewhere nothing will ever look for it. An absent root is
    /// "not mounted", never something to create.
    func testAnAbsentDriveIsSkippedAndNothingIsCreated() async throws {
        let project = scratch.appendingPathComponent("Shoot")
        let file = project.appendingPathComponent("frame.jpg")
        try makeFile(at: file, bytes: 128)
        let missing = try destination("Unplugged", create: false)

        let outcomes = await CaptureBackup.mirror(file, inProjectAt: project, to: [missing])
        XCTAssertEqual(outcomes.first?.result, .skipped(.notMounted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.root.path),
                       "an unmounted drive's path must never be created")
    }

    /// A drive plugged back in mid-shoot should catch up without re-copying what it already has.
    func testAnIdenticalCopyIsLeftAlone() async throws {
        let project = scratch.appendingPathComponent("Shoot")
        let file = project.appendingPathComponent("frame.jpg")
        try makeFile(at: file, bytes: 2048)
        let drive = try destination("DriveA")

        _ = await CaptureBackup.mirror(file, inProjectAt: project, to: [drive])
        let second = await CaptureBackup.mirror(file, inProjectAt: project, to: [drive])
        XCTAssertEqual(second.first?.result, .skipped(.alreadyPresent))
    }

    /// A short file left by an earlier interrupted copy is replaced, not mistaken for a good one.
    func testATruncatedEarlierCopyIsReplaced() async throws {
        let project = scratch.appendingPathComponent("Shoot")
        let file = project.appendingPathComponent("frame.jpg")
        try makeFile(at: file, bytes: 4096)
        let drive = try destination("DriveA")
        try makeFile(at: drive.root.appendingPathComponent("Shoot/frame.jpg"), bytes: 100)

        let outcomes = await CaptureBackup.mirror(file, inProjectAt: project, to: [drive])
        XCTAssertEqual(outcomes.first?.result, .copied(bytes: 4096))
        let size = try CaptureBackup.size(of: drive.root.appendingPathComponent("Shoot/frame.jpg"))
        XCTAssertEqual(size, 4096)
    }

    // MARK: - Telling the photographer

    /// Silence when all is well; a named drive when it is not. "Backup failed" with no name leaves
    /// the photographer unable to act without digging through a log mid-shoot.
    func testWarningNamesTheDrives() {
        let a = CaptureBackup.Destination(root: URL(fileURLWithPath: "/a"), label: "Shoot SSD")
        let b = CaptureBackup.Destination(root: URL(fileURLWithPath: "/b"), label: "Backup 2")

        XCTAssertNil(CaptureBackup.warning(for: [
            .init(destination: a, result: .copied(bytes: 1)),
            .init(destination: b, result: .skipped(.alreadyPresent))
        ]))

        XCTAssertEqual(CaptureBackup.warning(for: [.init(destination: b, result: .skipped(.notMounted))]),
                       "Backup 2 not connected — that copy wasn't made")

        let mixed = CaptureBackup.warning(for: [
            .init(destination: a, result: .failed("no space")),
            .init(destination: b, result: .skipped(.notMounted))
        ])
        XCTAssertEqual(mixed, "Backup failed to Shoot SSD; Backup 2 not connected")
    }

    func testListReadsAsEnglish() {
        XCTAssertEqual(CaptureBackup.list(["A"]), "A")
        XCTAssertEqual(CaptureBackup.list(["A", "B"]), "A and B")
        XCTAssertEqual(CaptureBackup.list(["A", "B", "C"]), "A, B, and C")
    }
}
