import Foundation

/// Pure parsing of gphoto2 shell output. Kept in the Foundation-only core so it's unit-testable
/// without linking the SwiftUI/AppKit app.
public enum CaptureOutput {
    /// All "Saving file as X" filenames in a command's output, in order. A single `wait-event`
    /// window can download more than one frame, and the marker can appear mid-line (right after an
    /// answered "Overwrite? [y|n]" prompt), so this scans by marker position, not per line.
    public static func savedFilenames(in output: String) -> [String] {
        var names: [String] = []
        var cursor = output.startIndex
        while let range = output.range(of: "Saving file as ", range: cursor..<output.endIndex) {
            let rest = output[range.upperBound...]
            let name = String(rest.prefix(while: { !$0.isNewline })).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
            cursor = range.upperBound
        }
        return names
    }
}
