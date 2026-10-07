import Foundation
import CanonTetherCore

/// The drives captures are mirrored to, and where that choice is kept.
///
/// Stored as paths rather than security-scoped bookmarks because this app is deliberately unsigned
/// and unsandboxed (see CLAUDE.md) — a plain path is what it can actually reopen next launch.
enum BackupSettings {
    static let userDefaultsKey = "backupDestinations"

    /// How many copies the standard practice asks for: the working copy on the internal disk plus
    /// two separate externals. Not a hard limit — it is what the UI offers to fill.
    static let recommendedCount = 2

    static func load(from defaults: UserDefaults = .standard) -> [CaptureBackup.Destination] {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map {
            // Symlinks resolved for the same reason `CaptureLocation.directory` does it: a chosen
            // folder reached through /var vs /private/var otherwise compares unequal to itself.
            CaptureBackup.Destination(id: $0.id,
                                      root: URL(fileURLWithPath: $0.path).resolvingSymlinksInPath(),
                                      label: $0.label)
        }
    }

    static func save(_ destinations: [CaptureBackup.Destination],
                     to defaults: UserDefaults = .standard) {
        let stored = destinations.map { Stored(id: $0.id, path: $0.root.path, label: $0.label) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    /// A sensible name for a newly chosen folder: the volume's name where there is one, so an
    /// external reads as "Shoot SSD" rather than "Volumes".
    static func label(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey]),
           let volume = values.volumeName, !volume.isEmpty {
            // Distinguish the folder from the drive when the chosen folder isn't the drive's root.
            let folder = url.lastPathComponent
            return folder.isEmpty || folder == volume ? volume : "\(volume) — \(folder)"
        }
        return url.lastPathComponent
    }

    private struct Stored: Codable {
        let id: UUID
        let path: String
        let label: String
    }
}
