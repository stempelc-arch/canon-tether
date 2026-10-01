import Foundation

/// What the merge produced: the fused image, plus a per-pixel record of which frame won, which is
/// what tells the photographer whether the bracket actually *covered* the subject.
public struct FocusStackResult {
    public let image: StackImage
    /// Winning source index per pixel at the map's own (coarse) resolution — the "depth map". It is
    /// deliberately coarser than the image: it comes off a mid pyramid level, where the sharpness
    /// read is stable, and it is only ever shown as an overlay.
    public let coverage: CoverageMap

    public init(image: StackImage, coverage: CoverageMap) {
        self.image = image
        self.coverage = coverage
    }
}

/// Which source frame won each region, and how strongly. `confidence` is the winner's share of the
/// total sharpness at that cell, so a region where nothing was ever sharp reads as low confidence
/// rather than silently attributing itself to whichever frame was marginally least blurred.
public struct CoverageMap: Equatable {
    public let width: Int
    public let height: Int
    public let sourceCount: Int
    public let winner: [Int]
    public let confidence: [Float]

    public init(width: Int, height: Int, sourceCount: Int, winner: [Int], confidence: [Float]) {
        self.width = width
        self.height = height
        self.sourceCount = sourceCount
        self.winner = winner
        self.confidence = confidence
    }

    /// Fraction of the frame where *some* frame was convincingly the sharpest. A low number means
    /// the stack has gaps — too few steps, or a step size that skipped past part of the subject.
    ///
    /// `region` restricts this to the subject, in normalised coordinates. Measured over the whole
    /// frame the number is meaningless on any photograph with a deliberately blurred background —
    /// a perfectly good stack reported "51% of the frame was never sharp", which reads as a defect
    /// and is simply a description of the bokeh.
    public func coverageFraction(minConfidence: Float = 0.5,
                                 region: (x: Double, y: Double, width: Double, height: Double)? = nil) -> Double {
        guard !confidence.isEmpty, width > 0, height > 0 else { return 0 }
        var covered = 0, total = 0
        for row in 0..<height {
            for column in 0..<width {
                if let region {
                    let nx = (Double(column) + 0.5) / Double(width)
                    let ny = (Double(row) + 0.5) / Double(height)
                    guard nx >= region.x, nx <= region.x + region.width,
                          ny >= region.y, ny <= region.y + region.height else { continue }
                }
                total += 1
                if confidence[row * width + column] >= minConfidence { covered += 1 }
            }
        }
        guard total > 0 else { return 0 }
        return Double(covered) / Double(total)
    }

    /// How much of the frame each source frame contributed. A frame contributing ~nothing is a
    /// wasted shot at one end of the bracket — the app uses this to suggest a tighter range.
    public func shares() -> [Double] {
        guard !winner.isEmpty, sourceCount > 0 else { return [] }
        var counts = [Int](repeating: 0, count: sourceCount)
        for w in winner where w >= 0 && w < sourceCount { counts[w] += 1 }
        return counts.map { Double($0) / Double(winner.count) }
    }
}

/// Fuses a bracket of identically-shaped, already-aligned frames into one all-in-focus image.
///
/// The method is pyramid fusion: build a Laplacian pyramid per frame, and at every level blend the
/// frames by a *smoothed local energy* weight rather than picking a winner outright. Two details
/// carry most of the quality:
///
/// - **Energy is measured over a neighbourhood, not per pixel.** A single Laplacian coefficient is
///   dominated by noise; a blurred frame's noise can beat a sharp frame's flat region pixel-for-
///   pixel. Box-blurring the energy first makes the decision regional, which is what it physically
///   is — focus is a property of an area, not of one sample.
/// - **Weights are soft, not winner-take-all.** `selectivity` raises the contrast between
///   competing frames but always leaves a gradient, so a focus boundary crossfades over the level's
///   own scale. Hard selection here is exactly what produces the halo-and-seam look that gives
///   naive focus stacks away.
///
/// The base (coarsest) level is a **plain average**, not a contest: defocus barely touches the
/// lowest frequencies, so there is no sharpness signal to choose on, and choosing anyway makes
/// large flat areas pick up the brightness of whichever frame happened to win — banding across
/// skies and backdrops. Averaging also cancels per-frame sensor noise in exactly the band where it
/// is most visible.
public enum FocusStackMerge {
    /// Exponent on each frame's local energy. ~4 puts a frame with twice a rival's energy about 16×
    /// ahead — decisive where one frame is genuinely sharper, still smooth where they are close.
    public static let selectivity: Float = 4

    /// Radius of the box blur applied to the energy map, in pixels *at each level*. Because it is
    /// per-level, its real-world extent doubles with each coarser band, which is the behaviour we
    /// want: fine detail is decided locally, coarse structure regionally.
    public static let energyRadius = 2

    /// Guards the weight normalisation where every frame is flat (a blank sky: all energies ~0).
    /// Without it the normalisation is 0/0; with it, ties fall back to an even blend.
    static let energyFloor: Float = 1e-8

    public enum MergeError: Error, LocalizedError {
        case empty
        case shapeMismatch

        public var errorDescription: String? {
            switch self {
            case .empty: return "There are no frames to stack."
            case .shapeMismatch: return "The frames in this stack aren't the same size."
            }
        }
    }

    /// Merges `frames` (all the same shape, already aligned). Progress is reported 0–1.
    public static func merge(
        _ frames: [StackImage],
        levels: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> FocusStackResult {
        guard let first = frames.first, first.isValid else { throw MergeError.empty }
        guard frames.allSatisfy({ $0.isValid && $0.matchesShape(of: first) }) else {
            throw MergeError.shapeMismatch
        }
        if frames.count == 1 {
            let flat = CoverageMap(width: 1, height: 1, sourceCount: 1, winner: [0], confidence: [1])
            return FocusStackResult(image: first, coverage: flat)
        }

        let levelCount = levels ?? StackPyramid.levelCount(width: first.width, height: first.height)
        var pyramids: [[StackImage]] = []
        pyramids.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            pyramids.append(StackPyramid.laplacianPyramid(frame, levels: levelCount))
            progress?(0.6 * Double(index + 1) / Double(frames.count))
        }

        // A short frame can bottom out early; fuse only the bands every frame actually has.
        let depth = pyramids.map(\.count).min() ?? 1
        var fused: [StackImage] = []
        fused.reserveCapacity(depth)
        var coverage: CoverageMap?

        for level in 0..<(depth - 1) {
            let bands = pyramids.map { $0[level] }
            let (weights, energies) = weightMaps(for: bands)
            fused.append(blend(bands, weights: weights))
            // Coverage is read off the **finest** band, then downsampled — not off a mid level.
            // Defocus is a high-frequency phenomenon: by mid-pyramid a blurred frame and a sharp one
            // carry almost the same energy, so the winner there is decided by noise (measured: a
            // synthetic half-blurred pair attributed only ~67% of its sharp half correctly). Taking
            // the argmax fine and *then* pooling keeps the signal and still yields a stable map.
            if level == 0 { coverage = coverageMap(from: energies) }
            progress?(0.6 + 0.35 * Double(level + 1) / Double(depth))
        }
        fused.append(average(pyramids.map { $0[depth - 1] }))

        let image = StackPyramid.collapse(fused)
        progress?(1)
        let map = coverage ?? CoverageMap(width: 1, height: 1, sourceCount: frames.count,
                                          winner: [0], confidence: [0])
        return FocusStackResult(image: image, coverage: map)
    }

    /// Per-frame, per-pixel blend weights for one pyramid level, already normalised to sum to 1.
    /// The unnormalised local energies come back too, because the coverage map needs the raw
    /// sharpness read and recomputing it would mean blurring every band a second time.
    static func weightMaps(for bands: [StackImage]) -> (weights: [StackImage], energies: [StackImage]) {
        let energies = bands.map { smoothedEnergy(of: $0) }
        let count = energies[0].data.count
        var weights = energies.map { energy -> StackImage in
            var w = energy
            for i in 0..<count { w.data[i] = powf(max(w.data[i], 0) + energyFloor, selectivity) }
            return w
        }
        for i in 0..<count {
            var total: Float = 0
            for w in weights { total += w.data[i] }
            if total > 0 {
                for j in 0..<weights.count { weights[j].data[i] /= total }
            } else {
                let even = 1 / Float(weights.count)
                for j in 0..<weights.count { weights[j].data[i] = even }
            }
        }
        return (weights, energies)
    }

    /// Local energy of a band: squared coefficient magnitude summed over channels, box-blurred so
    /// the decision is regional. Single channel out — colour channels of one frame share a focus.
    static func smoothedEnergy(of band: StackImage) -> StackImage {
        let w = band.width, h = band.height, c = band.channels
        var raw = [Float](repeating: 0, count: w * h)
        band.data.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    var sum: Float = 0
                    for ch in 0..<c {
                        let v = src[i * c + ch]
                        sum += v * v
                    }
                    dst[i] = sum
                }
            }
        }
        let energy = StackImage(width: w, height: h, channels: 1, data: raw)
        let side = Float(energyRadius * 2 + 1)
        return StackPyramid.convolve(energy, kernel: [Float](repeating: 1 / side, count: Int(side)))
    }

    /// Weighted sum of the bands.
    static func blend(_ bands: [StackImage], weights: [StackImage]) -> StackImage {
        var out = StackImage(width: bands[0].width, height: bands[0].height, channels: bands[0].channels)
        let c = out.channels
        for (band, weight) in zip(bands, weights) {
            for i in 0..<(out.width * out.height) {
                let w = weight.data[i]
                for ch in 0..<c { out.data[i * c + ch] += w * band.data[i * c + ch] }
            }
        }
        return out
    }

    /// Plain mean — used for the base level, see the type comment.
    static func average(_ images: [StackImage]) -> StackImage {
        var out = images[0]
        let scale = 1 / Float(images.count)
        for i in 0..<out.data.count { out.data[i] *= scale }
        for image in images.dropFirst() {
            for i in 0..<out.data.count { out.data[i] += scale * image.data[i] }
        }
        return out
    }

    /// How many times the fine-level energy is halved before the winner is chosen. Pooling energy
    /// over a region before comparing is what makes the map readable: per-pixel at full fineness it
    /// is salt-and-pepper, since individual coefficients of a sharp and a blurred frame cross over
    /// constantly even where the region as a whole is decisively sharper in one.
    static let coveragePooling = 2

    /// Turns per-frame local energies into "who won, and how convincingly".
    static func coverageMap(from energies: [StackImage]) -> CoverageMap {
        var pooled = energies
        for _ in 0..<coveragePooling {
            guard let first = pooled.first, first.width >= 4, first.height >= 4 else { break }
            pooled = pooled.map { StackPyramid.reduce($0) }
        }
        guard let reference = pooled.first else {
            return CoverageMap(width: 1, height: 1, sourceCount: energies.count, winner: [0], confidence: [0])
        }
        let count = reference.width * reference.height
        var winner = [Int](repeating: 0, count: count)
        var confidence = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var best: Float = -1
            var bestIndex = 0
            var total: Float = 0
            for (index, energy) in pooled.enumerated() {
                // Same exponent the blend uses, so "confidence" means the same thing as the weight
                // the winning frame actually received rather than a second, softer notion of it.
                let e = powf(max(energy.data[i], 0) + energyFloor, selectivity)
                total += e
                if e > best { best = e; bestIndex = index }
            }
            winner[i] = bestIndex
            confidence[i] = total > 0 ? best / total : 0
        }
        return CoverageMap(width: reference.width, height: reference.height,
                           sourceCount: pooled.count, winner: winner, confidence: confidence)
    }
}
