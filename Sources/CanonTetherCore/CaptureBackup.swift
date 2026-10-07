import Foundation

/// Writes every capture to more than one disk.
///
/// Before this, a frame landed in exactly one folder on one drive. On a tethered shoot the camera
/// often isn't writing a card either, so for a stretch of time the only copy of a client's session
/// was on a single disk — the one failure in this app that loses work rather than costing time.
///
/// The shape is the standard one: the working copy on the internal disk, plus two separate
/// externals, written at the same time rather than synced afterwards. Nothing here limits the count
/// to two; `destinations` is a list.
///
/// Lives in Core, with no SwiftUI, so the tests run in CI — the only place this suite runs at all.
public enum CaptureBackup {

    /// One place a copy is kept. `root` is the folder chosen in Preferences, typically the top of an
    /// external volume; captures are mirrored *underneath* it.
    public struct Destination: Identifiable, Equatable, Codable, Sendable {
        public let id: UUID
        /// Folder chosen by the photographer.
        public var root: URL
        /// What to call it in the UI — usually the volume name.
        public var label: String

        public init(id: UUID = UUID(), root: URL, label: String) {
            self.id = id
            self.root = root
            self.label = label
        }
    }

    public enum Skipped: Equatable, Sendable {
        /// The drive isn't there. The common case, and not an error: externals get unplugged.
        case notMounted
        /// An identical copy is already present, same size — a re-run, not a failure.
        case alreadyPresent
    }

    public enum Result: Equatable, Sendable {
        case copied(bytes: Int64)
        case skipped(Skipped)
        case failed(String)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    public struct Outcome: Equatable, Sendable {
        public let destination: Destination
        public let result: Result
        public init(destination: Destination, result: Result) {
            self.destination = destination
            self.result = result
        }
    }

    // MARK: - Where a copy goes

    /// The path a capture should take underneath a backup root, preserving the layout it has in the
    /// project: `<project folder>/<any subfolder>/<file>`.
    ///
    /// The project folder's own name is kept, so one external can safely back up several projects
    /// and a restore is a drag rather than a reconstruction. Focus-stack subfolders come along for
    /// the same reason.
    public static func relativePath(of file: URL, inProjectAt project: URL) -> String {
        let fileParts = file.standardizedFileURL.pathComponents
        let projectParts = project.standardizedFileURL.pathComponents
        // Everything from the project folder's own name onward.
        guard projectParts.count >= 1, fileParts.count > projectParts.count,
              Array(fileParts.prefix(projectParts.count)) == projectParts else {
            // Not inside the project after all — keep the filename, and let it land at the root
            // rather than refusing to back the shot up at all.
            return file.lastPathComponent
        }
        let projectName = projectParts[projectParts.count - 1]
        return ([projectName] + fileParts.dropFirst(projectParts.count)).joined(separator: "/")
    }

    // MARK: - Copying

    /// Copies one capture to every destination, all at once.
    ///
    /// Concurrent because the drives are independent: writing to three disks in series makes a
    /// shoot three times as slow to reach safety, for no reason. Failures are per-destination and
    /// never propagate — a backup drive that has been unplugged must not break the shoot, and the
    /// photographer needs to be told, not stopped.
    public static func mirror(_ file: URL,
                              inProjectAt project: URL,
                              to destinations: [Destination],
                              fileManager: FileManager = .default) async -> [Outcome] {
        guard !destinations.isEmpty else { return [] }
        let relative = relativePath(of: file, inProjectAt: project)

        return await withTaskGroup(of: Outcome.self) { group in
            for destination in destinations {
                group.addTask {
                    Outcome(destination: destination,
                            result: copy(file, to: destination, relative: relative, fileManager: fileManager))
                }
            }
            var results: [Outcome] = []
            for await outcome in group { results.append(outcome) }
            // Stable order, so the UI doesn't reshuffle between shots.
            return destinations.compactMap { d in results.first { $0.destination.id == d.id } }
        }
    }

    /// One destination. Synchronous — the copy itself is blocking file IO, and the concurrency that
    /// matters is between drives, which `mirror` provides.
    static func copy(_ file: URL,
                     to destination: Destination,
                     relative: String,
                     fileManager: FileManager = .default) -> Result {
        // **The destination root must already exist.**
        //
        // If an external unmounts, its `/Volumes/<name>` folder simply disappears, and creating
        // directories along that path writes to the *boot* disk instead — silently filling the
        // startup volume with what looks like a successful backup, in a place nothing will look.
        // So an absent root is "not mounted", never something to create.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .skipped(.notMounted)
        }

        let target = destination.root.appendingPathComponent(relative)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let sourceSize = try size(of: file, fileManager: fileManager)
            if fileManager.fileExists(atPath: target.path) {
                // Same size means this shot is already safely here — a reconnected drive catching
                // up, not a name collision. A *different* size is a truncated earlier attempt and
                // must be replaced.
                if let existing = try? size(of: target, fileManager: fileManager), existing == sourceSize {
                    return .skipped(.alreadyPresent)
                }
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: file, to: target)

            // Verify by size before calling it backed up.
            //
            // A copy that ran out of disk, or onto a drive pulled mid-write, leaves a short file
            // and no error worth trusting. Size is checked rather than a checksum deliberately:
            // it catches the failures that actually happen here (truncation, a full disk) for the
            // cost of a stat, where hashing every frame means reading it back off each drive.
            let written = try size(of: target, fileManager: fileManager)
            guard written == sourceSize else {
                try? fileManager.removeItem(at: target)
                return .failed("copied \(written) of \(sourceSize) bytes — removed the partial file")
            }
            return .copied(bytes: written)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func size(of url: URL, fileManager: FileManager = .default) throws -> Int64 {
        let values = try fileManager.attributesOfItem(atPath: url.path)
        return (values[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Reporting

    /// One line for the status bar, or `nil` when every destination is fine.
    ///
    /// Silence when all is well and a specific name when it is not: "backup failed" with no drive
    /// named leaves the photographer unable to act without digging through a log mid-shoot.
    public static func warning(for outcomes: [Outcome]) -> String? {
        let failed = outcomes.filter { $0.result.isFailure }.map(\.destination.label)
        let missing = outcomes.filter { $0.result == .skipped(.notMounted) }.map(\.destination.label)
        switch (failed.isEmpty, missing.isEmpty) {
        case (true, true):
            return nil
        case (false, _):
            return "Backup failed to \(list(failed))" + (missing.isEmpty ? "" : "; \(list(missing)) not connected")
        case (true, false):
            return "\(list(missing)) not connected — that copy wasn't made"
        }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}
