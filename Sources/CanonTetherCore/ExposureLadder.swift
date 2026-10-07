import Foundation

/// Turns "give me a third of a stop more light" into a shutter speed and an ISO the body will take.
///
/// Two controls, one ladder. Shutter is preferred because it costs nothing until it runs out; ISO is
/// held in reserve for when it does. **Aperture never ramps** — the iris does not return to exactly
/// the same position shot to shot, so ramping it introduces the very flicker the whole feature
/// exists to avoid, and it would change depth of field through the sequence as well.
public struct ExposureLadder: Sendable {

    /// Shutter speeds the body offers, as it spells them.
    public let shutterChoices: [String]
    /// ISO values the body offers.
    public let isoChoices: [String]
    /// Longest exposure allowed, in seconds. A frame that outlasts the interval cannot be shot.
    public let longestShutter: Double
    /// Highest ISO the sequence may reach.
    public let highestISO: Double

    public init(shutterChoices: [String], isoChoices: [String],
                longestShutter: Double, highestISO: Double) {
        self.shutterChoices = shutterChoices
        self.isoChoices = isoChoices
        self.longestShutter = longestShutter
        self.highestISO = highestISO
    }

    public struct Settings: Equatable, Sendable {
        public let shutter: String
        public let iso: String
        public init(shutter: String, iso: String) {
            self.shutter = shutter
            self.iso = iso
        }
    }

    /// Total light a pair collects, in stops. Higher means brighter.
    public func exposure(of settings: Settings) -> Double? {
        guard let shutterStops = ExposureGrid.stops(of: settings.shutter, path: ExposureGrid.shutterPath),
              let isoStops = ExposureGrid.stops(of: settings.iso, path: ExposureGrid.isoPath) else { return nil }
        // `stops` rises as the shutter gets *faster*, so it counts against exposure; ISO counts for.
        return isoStops - shutterStops
    }

    /// The pair `stops` brighter than `current`, as close as the body's own values allow.
    ///
    /// Which control moves is decided by which direction the light is going:
    ///
    /// - **More light**: lengthen the shutter first, up to `longestShutter`, and only then raise ISO.
    ///   Shutter costs nothing but motion blur, which a timelapse of a landscape does not care about;
    ///   ISO costs noise in every frame after it.
    /// - **Less light**: bring ISO back down first, then shorten the shutter. The mirror image, and
    ///   for the same reason — as soon as the scene can afford it, the sequence should be at base ISO.
    ///
    /// Returns `nil` when the body has nothing left in that direction, which is how a night ramp
    /// discovers it has run out rather than silently holding still.
    public func settings(from current: Settings, changingBy stops: Double) -> Settings? {
        guard let currentExposure = exposure(of: current) else { return nil }
        let target = currentExposure + stops

        let usableShutters = shutterChoices.filter { choice in
            guard let seconds = ExposureGrid.seconds(from: choice) else { return false }
            return seconds <= longestShutter
        }
        let usableISOs = isoChoices.filter { choice in
            guard let value = Double(choice) else { return false }
            return value <= highestISO
        }
        guard !usableShutters.isEmpty, !usableISOs.isEmpty else { return nil }

        let baseISO = usableISOs.min { (Double($0) ?? 0) < (Double($1) ?? 0) } ?? current.iso
        let brighter = stops > 0

        // Try to land the whole change on the shutter, holding ISO where it is — with one
        // exception: when going darker, spend ISO back down to base before touching the shutter.
        var isoToUse = current.iso
        if !brighter, let currentISO = Double(current.iso), let base = Double(baseISO), currentISO > base {
            // How much darker can ISO alone make it?
            let isoHeadroom = log2(currentISO / base)
            if isoHeadroom >= -stops {
                // ISO can absorb all of it. Pick the ISO closest to the target, keep the shutter.
                if let iso = nearest(in: usableISOs, path: ExposureGrid.isoPath,
                                     toStops: (ExposureGrid.stops(of: current.iso, path: ExposureGrid.isoPath) ?? 0) + stops) {
                    return Settings(shutter: current.shutter, iso: iso)
                }
            }
            isoToUse = baseISO      // spend it all and let the shutter take the rest
        }

        let isoStops = ExposureGrid.stops(of: isoToUse, path: ExposureGrid.isoPath) ?? 0
        // Exposure = isoStops - shutterStops, so the shutter must supply this many stops.
        let wantedShutterStops = isoStops - target
        if let shutter = nearest(in: usableShutters, path: ExposureGrid.shutterPath, toStops: wantedShutterStops),
           let landed = exposure(of: Settings(shutter: shutter, iso: isoToUse)),
           abs(landed - target) <= Self.tolerance {
            return Settings(shutter: shutter, iso: isoToUse)
        }

        // The shutter could not reach it. Put the remainder on ISO — this is the night end of a
        // ramp, where the shutter is already as long as the interval allows.
        guard brighter else {
            // Going darker with the shutter already at its fastest: nothing left.
            if let shutter = nearest(in: usableShutters, path: ExposureGrid.shutterPath, toStops: wantedShutterStops),
               let landed = exposure(of: Settings(shutter: shutter, iso: isoToUse)), landed < currentExposure {
                return Settings(shutter: shutter, iso: isoToUse)
            }
            return nil
        }
        let longest = usableShutters.min { (ExposureGrid.seconds(from: $0) ?? 0) > (ExposureGrid.seconds(from: $1) ?? 0) }
        guard let longest, let longestStops = ExposureGrid.stops(of: longest, path: ExposureGrid.shutterPath) else {
            return nil
        }
        let neededISOStops = target + longestStops
        guard let iso = nearest(in: usableISOs, path: ExposureGrid.isoPath, toStops: neededISOStops),
              let landed = exposure(of: Settings(shutter: longest, iso: iso)),
              landed > currentExposure + Self.tolerance else { return nil }
        return Settings(shutter: longest, iso: iso)
    }

    /// Within a third of a stop counts as landing on the request — that is the body's own grid.
    static let tolerance = 0.17

    private func nearest(in choices: [String], path: String, toStops target: Double) -> String? {
        var best: (choice: String, distance: Double)?
        for choice in choices {
            guard let value = ExposureGrid.stops(of: choice, path: path) else { continue }
            let distance = abs(value - target)
            if best == nil || distance < best!.distance { best = (choice, distance) }
        }
        return best?.choice
    }
}
