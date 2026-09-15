import Foundation

/// A depth map of the scene, built by sweeping focus and recording **where each tile of the frame
/// comes into focus**.
///
/// This replaces measuring one sharpness curve, which cannot answer the question a stack asks.
/// A whole-frame curve reports the sharpest region *anywhere*, so racking through a deep scene
/// always finds something sharp and the curve never falls off — measured on a real sweep, it had no
/// near edge at all. A single small region gives a clean peak, but its width is the lens's depth of
/// field, not the subject's depth. Neither tells you how far the subject extends.
///
/// Per-tile peaks do. Each tile looks at scene at its own distance, so the offset where it peaks
/// *is* that part's focus position, and the spread of those positions across the subject is exactly
/// the range a bracket must cover. Measured on a real subject, this produced a legible map: centre
/// tiles peaking at −5…−21 with the flanking columns at +17…+38 — a curved object, near in the
/// middle, receding at the sides.
public struct FocusDepthMap {
    /// Tiles across and down.
    ///
    /// 24, not 12. Measured on a real sweep with a box drawn around a cylindrical subject, a 12×12
    /// grid put only three tile-columns across it — too coarse to separate the barrel's curved
    /// edges from the background behind them, so the range stopped at the front face and the sides
    /// came out soft. At 24×24 the subject's shape appears: centre columns at −9, edge columns at
    /// +5, a clean symmetric curve, and the range extends to cover it.
    ///
    /// Finer is not automatically better. At this resolution *without* a drawn box the whole
    /// scene's depths risk merging into one continuum (a receding table fills every gap), which is
    /// why the border exclusion scales with the grid and why a drawn box matters most here.
    public static let grid = 24

    /// One tile's read across the whole sweep.
    public struct TilePeak: Equatable, Sendable {
        public let cell: Int
        /// Focus offset at which this tile was sharpest.
        public let offset: Int
        public let peak: Double
        public let floor: Double
        /// How many distinct focus events this tile shows. More than one means it spans an edge
        /// between subject and background.
        public let peakCount: Int

        public init(cell: Int, offset: Int, peak: Double, floor: Double, peakCount: Int = 1) {
            self.cell = cell
            self.offset = offset
            self.peak = peak
            self.floor = floor
            self.peakCount = peakCount
        }

        /// How decisively this tile came into and out of focus. A tile of blank wall has detail
        /// nowhere and a near-zero contrast; only tiles that genuinely transition carry depth.
        public var contrast: Double { peak > 0 ? (peak - floor) / peak : 0 }

        public var column: Int { cell % FocusDepthMap.grid }
        public var row: Int { cell / FocusDepthMap.grid }
    }

    public let peaks: [TilePeak]
    /// The extremes of the swept range. A tile peaking at either is not a measurement: its true
    /// peak may lie outside the sweep, and at the near extreme the lens is usually against its end
    /// stop, where consecutive frames are identical and any "peak" is noise.
    private let sweptRange: (first: Int, last: Int)?
    /// Each tile's full sharpness curve, kept so depth of field can be measured from the same sweep
    /// rather than guessed at.
    private let curves: [Int: [(offset: Int, value: Double)]]

    /// Minimum contrast and absolute sharpness for a tile to be believed. Calibrated on a real
    /// sweep, where 28 of 144 tiles cleared these — the rest being smooth wall and out-of-frame
    /// areas with no detail to focus on at any distance.
    public static let minimumContrast = 0.35
    public static let minimumPeak = 0.02

    /// A tile's sharpness peak must clear this share of its best reading to count as a real focus
    /// event rather than a ripple in the curve.
    /// Depths further apart than this belong to different things in the scene.
    ///
    /// Measured on a real frame: the subject's own surfaces ran −21…+8 in a continuous spread while
    /// the background sat at +17…+39. A gap of 12 bridged that 9-step separation and merged subject
    /// with wall; 8 keeps them apart while still treating the subject's own surfaces as one object.
    public static let clusterGap = 8

    /// Share of the subject's tiles a depth group must hold to be treated as the subject itself.
    public static let minimumClusterShare = 0.1

    public static let peakSignificance = 0.5

    /// Peaks closer together than this are the same focus event seen through noise.
    public static let peakSeparation = 6

    /// Builds the map from per-frame tile sharpness, keyed by focus offset.
    ///
    /// Each tile's depth is the **nearest significant peak** in its sharpness curve, not the
    /// highest. That distinction is what lets a box be drawn *around* a subject rather than inside
    /// it: a tile straddling the subject's outline contains subject and background both, so its
    /// curve has two humps — and the background's is often the taller, being higher-contrast. Taking
    /// the tallest made such tiles report the wall's distance while sitting on the subject, which is
    /// how a subject a few steps deep produced a fifty-step range. The subject is always in front of
    /// its background, so the nearer hump is the one that belongs to it.
    public init(framesByOffset: [Int: [Double]]) {
        let offsets = framesByOffset.keys.sorted()
        var found: [TilePeak] = []
        guard let first = offsets.first, let last = offsets.last, let sample = framesByOffset[first] else {
            peaks = []
            curves = [:]
            sweptRange = nil
            return
        }
        sweptRange = (first, last)
        var collected: [Int: [(offset: Int, value: Double)]] = [:]
        for cell in 0..<sample.count {
            var curve: [(offset: Int, value: Double)] = []
            for offset in offsets {
                guard let tiles = framesByOffset[offset], cell < tiles.count else { continue }
                curve.append((offset, tiles[cell]))
            }
            guard curve.count >= 3,
                  let best = curve.max(by: { $0.value < $1.value }),
                  let worst = curve.min(by: { $0.value < $1.value }) else { continue }

            // Smoothed before looking for maxima: preview noise invents them otherwise.
            var smoothed = curve
            for i in 1..<(curve.count - 1) {
                smoothed[i].value = (curve[i - 1].value + curve[i].value + curve[i + 1].value) / 3
            }
            var maxima: [(offset: Int, value: Double)] = []
            for i in 1..<(smoothed.count - 1) {
                let value = smoothed[i].value
                guard value >= smoothed[i - 1].value, value >= smoothed[i + 1].value,
                      value >= best.value * Self.peakSignificance else { continue }
                if let last = maxima.last, smoothed[i].offset - last.offset < Self.peakSeparation {
                    if value > last.value { maxima[maxima.count - 1] = (smoothed[i].offset, value) }
                    continue
                }
                maxima.append((smoothed[i].offset, value))
            }
            let depth = maxima.first?.offset ?? best.offset
            collected[cell] = curve
            found.append(TilePeak(cell: cell, offset: depth, peak: best.value, floor: worst.value,
                                  peakCount: Swift.max(maxima.count, 1)))
        }
        peaks = found
        curves = collected
    }

    /// Tiles whose focus peak can be believed.
    public var usableTiles: [TilePeak] {
        peaks.filter {
            guard $0.contrast > Self.minimumContrast, $0.peak > Self.minimumPeak else { return false }
            // Peaks pinned to the edge of the sweep are unconstrained — the curve was still rising
            // when the sweep ran out, or the lens was against a stop and every frame was the same.
            // Observed: one such tile at the sweep's first sample formed its own cluster and was
            // chosen as the subject, producing a 4-step range covering 0% of the actual subject.
            if let sweptRange, $0.offset == sweptRange.first || $0.offset == sweptRange.last {
                return false
            }
            return true
        }
    }

    /// A region of the frame, in normalised coordinates (0–1, y down), that the photographer has
    /// marked as the subject. When set, only tiles inside it are considered.
    public struct Region: Equatable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        func contains(column: Int, row: Int) -> Bool {
            let cx = (Double(column) + 0.5) / Double(FocusDepthMap.grid)
            let cy = (Double(row) + 0.5) / Double(FocusDepthMap.grid)
            return cx >= x && cx <= x + width && cy >= y && cy <= y + height
        }
    }

    /// Tiles that describe the subject. With a `region` the photographer has said where it is;
    /// without one the border is excluded, since an edge tile is usually background.
    /// Tiles whose focus peak sits at an end of the swept range — their true focus is somewhere
    /// beyond where the scan looked, so any range built from this sweep is a floor, not the subject.
    ///
    /// Worth reporting rather than swallowing: measured on a real sweep, 56 tiles were pinned to
    /// the last sample because focus started 47 steps in front of the subject, and the stack that
    /// followed left every far surface soft.
    public func tilesPinnedAtEdge(region: Region? = nil) -> Int {
        guard let sweptRange else { return 0 }
        let candidates = peaks.filter { $0.contrast > Self.minimumContrast && $0.peak > Self.minimumPeak }
        return candidates.filter { peak in
            guard peak.offset == sweptRange.first || peak.offset == sweptRange.last else { return false }
            guard let region else { return true }
            return region.contains(column: peak.column, row: peak.row)
        }.count
    }

    public func subjectTiles(border: Int = FocusDepthMap.grid / 4, region: Region? = nil) -> [TilePeak] {
        if let region {
            return usableTiles.filter { region.contains(column: $0.column, row: $0.row) }
        }
        return usableTiles.filter {
            $0.column >= border && $0.column < Self.grid - border
                && $0.row >= border && $0.row < Self.grid - border
        }
    }

    /// Groups tile depths that sit within `gap` steps of one another.
    ///
    /// The scene is not one depth. Measured on a real frame, the tiles picked out three distinct
    /// groups: the subject's front face at −17…−7, its top rim at +8…+10, and +24…+38 — the last
    /// being tiles straddling the subject's *outline*, which contain background as well as subject,
    /// so when focus reaches the wall their background content sharpens and dominates. Those tiles
    /// report the background's distance while sitting squarely on the subject, which is how a
    /// 16-step subject produced a 50-step range.
    public static func cluster(_ offsets: [Int], gap: Int = Self.clusterGap) -> [[Int]] {
        guard !offsets.isEmpty else { return [] }
        let sorted = offsets.sorted()
        var groups: [[Int]] = [[sorted[0]]]
        for value in sorted.dropFirst() {
            if value - (groups[groups.count - 1].last ?? value) <= gap {
                groups[groups.count - 1].append(value)
            } else {
                groups.append([value])
            }
        }
        return groups
    }

    /// The focus range a bracket must cover to render the subject sharp throughout.
    ///
    /// Trimmed by percentile rather than taking the extremes: a single mis-read tile — a specular
    /// highlight, a noisy patch — should not add ten frames to every stack. `margin` then pads the
    /// result, because the cost of a gap is unrecoverable while the cost of a spare frame is a
    /// second of shooting.
    public func subjectRange(trim: Double = 0,
                             margin: Int = 2,
                             border: Int = FocusDepthMap.grid / 4,
                             region: Region? = nil) -> (near: Int, far: Int)? {
        let tiles = subjectTiles(border: border, region: region)
        guard tiles.count >= 3 else { return nil }

        // The nearest depth group **only**.
        //
        // A subject is in front of its background by definition — you cannot photograph through it —
        // so when tile depths separate into groups, the nearest is the subject and anything beyond
        // is what shows through the gaps around its outline. An earlier version absorbed a further
        // group when it held a large enough share of tiles, on the theory that a big group must be
        // part of the subject. It is not: measured on a real frame, background tiles were 45% of
        // the total, so that rule swallowed the wall and turned a 29-step subject into 59 steps.
        // Size is not evidence of belonging; being in front is.
        // The nearest group **that is substantial enough to be a subject**. A stray tile or two at
        // some odd depth — a specular highlight, a noisy patch — must not outrank the body of the
        // subject simply by being nearer.
        let groups = Self.cluster(tiles.map(\.offset))
        let minimumTiles = Swift.max(2, Int(Double(tiles.count) * Self.minimumClusterShare))
        guard let chosen = groups.first(where: { $0.count >= minimumTiles })
            ?? groups.max(by: { $0.count < $1.count }) else { return nil }

        let offsets = chosen.sorted()
        // No percentile trim by default.
        //
        // It was there to reject stray tiles, but clustering and the edge rule already do that, and
        // trimming only ever costs depth. Measured on a real subject whose tiles ran −29…+11, a 5%
        // trim returned −21…13 and the far end of the stack came out soft. A trimmed range loses
        // subject that cannot be recovered afterwards; an untrimmed one costs a frame or two.
        let effectiveTrim = offsets.count >= 20 ? trim : 0
        let index = { (p: Double) -> Int in
            offsets[Swift.min(offsets.count - 1, Swift.max(0, Int((Double(offsets.count - 1) * p).rounded())))]
        }
        let near = index(effectiveTrim) - margin
        let far = index(1 - effectiveTrim) + margin
        guard far > near else { return nil }
        return (near, far)
    }

    /// How many focus steps one frame stays acceptably sharp over — the depth of field, measured
    /// rather than assumed, and the thing that actually decides how many captures a stack needs.
    ///
    /// Taken as the lower quartile of the per-tile sharp width, not the median: spacing has to
    /// satisfy the *narrowest* part of the subject, and a tile with a broad peak (flat, low-detail)
    /// would otherwise licence a spacing that leaves the crisp parts with gaps.
    ///
    /// Measured on a real subject: median 8 steps, lower quartile 6 — so an 18-step span needs
    /// about 4 frames, where shooting every step was taking 19.
    public func depthOfFieldSteps(sharpFraction: Double = 0.8, region: Region? = nil) -> Int? {
        var widths: [Int] = []
        for tile in subjectTiles(region: region) {
            guard let curve = curves[tile.cell], curve.count >= 3 else { continue }
            let values = curve.map(\.value)
            guard let peak = values.max(), let floor = values.min(), peak > floor else { continue }
            let threshold = floor + (peak - floor) * sharpFraction
            let above = curve.filter { $0.value >= threshold }.map(\.offset)
            guard let lo = above.min(), let hi = above.max() else { continue }
            widths.append(hi - lo + 1)
        }
        guard widths.count >= 3 else { return nil }
        widths.sort()
        return Swift.max(1, widths[widths.count / 4])
    }

    /// The per-tile sharp widths behind `depthOfFieldSteps`, as (lower quartile, median, upper).
    ///
    /// Frame count is decided by the lower quartile, and how conservative that is depends entirely
    /// on how far the median sits above it — a spread that is worth seeing rather than assuming
    /// when a bracket's frame count is being argued about.
    public func depthOfFieldSpread(sharpFraction: Double = 0.8,
                                   region: Region? = nil) -> (lower: Int, median: Int, upper: Int)? {
        var widths: [Int] = []
        for tile in subjectTiles(region: region) {
            guard let curve = curves[tile.cell], curve.count >= 3 else { continue }
            let values = curve.map(\.value)
            guard let peak = values.max(), let floor = values.min(), peak > floor else { continue }
            let threshold = floor + (peak - floor) * sharpFraction
            let above = curve.filter { $0.value >= threshold }.map(\.offset)
            guard let lo = above.min(), let hi = above.max() else { continue }
            widths.append(hi - lo + 1)
        }
        guard widths.count >= 3 else { return nil }
        widths.sort()
        return (widths[widths.count / 4], widths[widths.count / 2], widths[widths.count * 3 / 4])
    }

    /// Fraction of believable tiles whose peak sits inside the given range — how much of the
    /// subject a bracket over that range would actually render sharp.
    public func coverage(near: Int, far: Int, region: Region? = nil) -> Double {
        let tiles = subjectTiles(region: region)
        guard !tiles.isEmpty else { return 0 }
        let inside = tiles.filter { $0.offset >= near && $0.offset <= far }.count
        return Double(inside) / Double(tiles.count)
    }
}
