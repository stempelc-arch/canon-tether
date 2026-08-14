import Foundation

/// A single camera property (ISO, aperture, etc.) as reported by gphoto2's `get-config`,
/// with its current value and — for enum-type properties — the list of valid choices.
public struct CameraSetting: Identifiable, Equatable {
    public let path: String        // e.g. "/main/imgsettings/iso"
    public let label: String       // human-readable name from the camera, e.g. "ISO Speed"
    public let current: String     // the value currently in effect
    public let choices: [String]   // valid values for a RADIO/MENU property; empty for free-form/read-only ones
    public let readOnly: Bool

    public var id: String { path }

    public init(path: String, label: String, current: String, choices: [String], readOnly: Bool) {
        self.path = path
        self.label = label
        self.current = current
        self.choices = choices
        self.readOnly = readOnly
    }

    /// Parses the output of a gphoto2 `get-config <path>` command, whose format is:
    ///
    ///     Label: ISO Speed
    ///     Readonly: 0
    ///     Type: RADIO
    ///     Current: 400
    ///     Choice: 0 Auto
    ///     Choice: 1 100
    ///     ...
    ///     END
    ///
    /// Returns nil if the output has no `Current:` line (e.g. the property is unavailable in
    /// the camera's current mode).
    public static func parse(from output: String, path: String) -> CameraSetting? {
        // Fall back to the last path component if the camera doesn't report a label.
        var label = path.split(separator: "/").last.map(String.init) ?? path
        var current: String?
        var readOnly = false
        var choices: [String] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = line.valueAfter("Label:") {
                label = value
            } else if let value = line.valueAfter("Readonly:") {
                readOnly = (value == "1")
            } else if let value = line.valueAfter("Current:") {
                current = value
            } else if let value = line.valueAfter("Choice:") {
                // "Choice: 3 400" — drop the leading numeric index, keep the rest as the value.
                // The value itself may contain spaces (e.g. "Large Fine JPEG"), so split once only.
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    choices.append(String(parts[1]))
                } else if let single = parts.first {
                    choices.append(String(single))
                }
            }
        }

        guard let current else { return nil }
        return CameraSetting(path: path, label: label, current: current, choices: choices, readOnly: readOnly)
    }
}

private extension String {
    /// If the string starts with `prefix`, returns the trimmed remainder; otherwise nil.
    func valueAfter(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
