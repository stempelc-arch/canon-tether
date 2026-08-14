import Foundation

/// Which stop grid the camera body is currently reporting exposure values on.
///
/// Canon puts "exposure level increments" on the body as a custom function (C.Fn I-1), and the
/// camera only reports — and only accepts — the values on whichever grid that function selects.
/// libgphoto2's PTP driver exposes no config for it, so the app can neither change the grid nor
/// invent the values the body withheld: thinning a 1/3-stop list down to a 1/2-stop grid leaves
/// nothing but whole stops, because Canon's half-stop values (ISO 140, 1/90, f/1.7) are absent from
/// the third-stop list entirely. So the inspector shows every value the camera reports and just
/// names the grid — the pickers always match the body, and the increment is changed on the body.
public enum ExposureGrid: String, Sendable, Equatable {
    case third = "1/3"
    case half = "1/2"

    /// The inspector's readout, e.g. "1/3-stop increments".
    public var label: String { "\(rawValue)-stop increments" }

    public static let isoPath = "/main/imgsettings/iso"
    public static let shutterPath = "/main/capturesettings/shutterspeed"
    public static let aperturePath = "/main/capturesettings/aperture"

    /// The three settings that trade off against each other, in the order the inspector shows them.
    public static let exposurePaths: [String] = [isoPath, shutterPath, aperturePath]

    /// Shutter and aperture are the two settings governed by "exposure level increments", so the
    /// grid is read from them. ISO is deliberately excluded: it follows a separate custom function
    /// ("ISO speed setting increments", 1/3 or 1 stop), and a body set to 1-stop ISO would drag the
    /// measurement off the real exposure grid.
    static let gridPaths: [String] = [shutterPath, aperturePath]

    /// Canon's published values are rounded names rather than exact powers (f/13 is really f/12.7,
    /// 1/60s is really 1/64s), so individual gaps scatter by up to ~0.15 stop. Measuring the median
    /// gap absorbs that; 0.09 is then wide enough to accept a real list and narrow enough that the
    /// two grids can't be confused with each other, or with a full-stop list.
    private static let tolerance = 0.09

    /// The grid the camera is on, or nil if its lists are too short or too irregular to tell.
    public static func detect(in settings: [CameraSetting]) -> ExposureGrid? {
        let gaps = gridPaths.flatMap { path -> [Double] in
            guard let setting = settings.first(where: { $0.path == path }) else { return [] }
            return self.gaps(in: setting.choices, path: path)
        }
        guard gaps.count >= 4 else { return nil }

        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        if abs(median - 1.0 / 3.0) <= tolerance { return .third }
        if abs(median - 0.5) <= tolerance { return .half }
        return nil
    }

    /// Distances in stops between each pair of adjacent numeric values in one choice list.
    /// A non-numeric entry ("Auto", "bulb", "Unknown value") breaks the chain rather than being
    /// skipped over, so no gap is ever measured across a hole in the list.
    private static func gaps(in choices: [String], path: String) -> [Double] {
        var result: [Double] = []
        var previous: Double?
        for choice in choices {
            guard let stops = stops(of: choice, path: path) else {
                previous = nil
                continue
            }
            if let previous { result.append(abs(stops - previous)) }
            previous = stops
        }
        return result
    }

    /// A value's distance in stops from that setting's reference point (ISO 100, 1 second, f/1).
    /// Only relative position matters, so the sign and reference are arbitrary but fixed.
    /// Returns nil for anything non-numeric.
    public static func stops(of value: String, path: String) -> Double? {
        let raw = value.trimmingCharacters(in: .whitespaces)
        switch path {
        case isoPath:
            guard let iso = Double(raw), iso > 0 else { return nil }
            return log2(iso / 100)
        case shutterPath:
            guard let seconds = seconds(from: raw), seconds > 0 else { return nil }
            return -log2(seconds)
        case aperturePath:
            let number = raw.hasPrefix("f/") ? String(raw.dropFirst(2)) : raw
            guard let fNumber = Double(number), fNumber > 0 else { return nil }
            return 2 * log2(fNumber)
        default:
            return nil
        }
    }

    /// Whether a rising `stops(of:)` value means more light or less. ISO climbs with exposure;
    /// shutter and aperture are measured so that climbing means a faster speed or a smaller
    /// opening, i.e. less light. This is what lets one "+" mean the same thing on all three rows.
    private static func exposureSign(for path: String) -> Double? {
        switch path {
        case isoPath: return 1
        case shutterPath, aperturePath: return -1
        default: return nil
        }
    }

    /// The adjacent value in `choices` that is one step brighter (or darker) than `current`.
    ///
    /// Steps are found by exposure distance rather than by position in the list, so the result
    /// doesn't depend on the order gphoto2 happens to report, and non-numeric entries ("Auto",
    /// "bulb") are never stepped onto. Returns nil at either end of the camera's range, or when
    /// `current` itself is non-numeric — the caller disables the button.
    public static func neighbor(
        of current: String,
        in choices: [String],
        path: String,
        brighter: Bool
    ) -> String? {
        guard let sign = exposureSign(for: path),
              let currentStops = stops(of: current, path: path) else { return nil }
        let currentBrightness = sign * currentStops

        var best: (value: String, brightness: Double)?
        for choice in choices {
            guard let stops = stops(of: choice, path: path) else { continue }
            let brightness = sign * stops
            // Strictly past the current value in the requested direction…
            guard brighter ? brightness > currentBrightness : brightness < currentBrightness else { continue }
            // …and of those, the nearest one.
            if best == nil || (brighter ? brightness < best!.brightness : brightness > best!.brightness) {
                best = (choice, brightness)
            }
        }
        return best?.value
    }

    /// Parses gphoto2's shutter-speed spellings: "1/125" → 0.008, "0.3" → 0.3, "30" → 30.
    /// Returns nil for "bulb" and friends.
    public static func seconds(from value: String) -> Double? {
        guard value.contains("/") else { return Double(value) }
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }
}
