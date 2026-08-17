import Foundation

/// Dotted-numeric version comparison, for deciding whether a published release is newer than the
/// running build. Foundation-only and in Core so it's unit-testable.
public enum SemanticVersion {
    /// Parses "1.2.3", "v1.2", "1.2.3-beta" into comparable numeric components. Anything
    /// non-numeric ends the version (so "1.2.3-beta" compares as 1.2.3), and missing components
    /// read as zero, so "1.2" and "1.2.0" are equal.
    public static func components(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst()) : trimmed
        var parts: [Int] = []
        for piece in withoutPrefix.split(separator: ".") {
            let digits = piece.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parts.append(value)
            // A component carrying a suffix ("3-beta") is the last one that counts.
            if digits.count != piece.count { break }
        }
        return parts
    }

    /// Whether `candidate` represents a strictly newer version than `current`. Returns false if
    /// either side has no parseable numbers, so a malformed tag can never nag the user to "update".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate), rhs = components(current)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
