import Foundation

/// A centre-anchored scale plus a translation — the transform a focus bracket actually needs.
///
/// Racking focus changes the lens's magnification ("focus breathing"): the subject grows or shrinks
/// by a fraction of a percent to a few percent across a stack, usually with a small shift from
/// imperfect rigidity. A pure translation cannot cancel that — align the centre and the corners
/// stay doubled — so scale is the one extra degree of freedom that matters. Rotation is *not*
/// modelled: a tripod-mounted body racking focus does not roll, and fitting an unneeded parameter
/// mostly buys noise.
///
/// Convention: this maps a **destination** pixel to the **source** pixel it should be sampled from,
/// which is the direction a resampler needs.
public struct SimilarityTransform: Equatable {
    public var scale: Double
    public var tx: Double
    public var ty: Double

    public static let identity = SimilarityTransform(scale: 1, tx: 0, ty: 0)

    public init(scale: Double, tx: Double, ty: Double) {
        self.scale = scale
        self.tx = tx
        self.ty = ty
    }

    /// Where destination pixel (x, y) reads from, given the image's centre.
    @inline(__always)
    public func source(x: Double, y: Double, centerX: Double, centerY: Double) -> (x: Double, y: Double) {
        (centerX + (x - centerX) * scale + tx, centerY + (y - centerY) * scale + ty)
    }

    /// Composition: applying `self` then `other` as a single transform. Used to chain
    /// frame-to-frame estimates into a common reference frame.
    public func concatenated(with other: SimilarityTransform) -> SimilarityTransform {
        SimilarityTransform(scale: scale * other.scale,
                            tx: tx * other.scale + other.tx,
                            ty: ty * other.scale + other.ty)
    }

    /// Rescales a transform estimated at one pyramid level for use at a level `factor` times larger.
    /// Scale is dimensionless and carries over untouched; translation is in pixels and does not.
    public func scaledToResolution(factor: Double) -> SimilarityTransform {
        SimilarityTransform(scale: scale, tx: tx * factor, ty: ty * factor)
    }

    /// Largest displacement this transform introduces anywhere in an image of the given size — the
    /// honest "how far did this frame move" number, since a tiny scale change still shifts corners.
    public func maxDisplacement(width: Int, height: Int) -> Double {
        let halfW = Double(width) / 2, halfH = Double(height) / 2
        let corner = ((scale - 1) * halfW + abs(tx)) * ((scale - 1) * halfW + abs(tx))
            + ((scale - 1) * halfH + abs(ty)) * ((scale - 1) * halfH + abs(ty))
        return corner.squareRoot()
    }
}

/// Registers the frames of a focus bracket onto a common geometry.
///
/// Two design choices are load-bearing:
///
/// - **Frames are matched to their immediate neighbour, then chained**, rather than each being
///   matched to one reference. Adjacent frames in a bracket differ by one focus step, so they look
///   almost alike; the first and last frame of a deep stack can look like different pictures, and a
///   correlation between them is far less trustworthy. Chaining accumulates a little drift but each
///   individual estimate is made under near-ideal conditions.
/// - **Matching happens on heavily downsampled luma.** Registration information lives in coarse
///   structure, which survives defocus; fine detail is exactly what differs between a sharp and a
///   blurred frame, so feeding it in would have the matcher trying to explain blur as motion.
public enum FocusStackAlign {
    /// Longest edge the coarsest matching level is allowed to be. Small enough that an exhaustive
    /// search over the whole parameter grid is cheap, large enough to localise to ~1 coarse pixel.
    static let coarsestEdge = 48

    /// The scale range searched, in ±fraction. Focus breathing on normal glass is well under 3%;
    /// macro lenses breathe hardest and are also where stacking is most used, so the window is
    /// generous. A wider window is not free — it invites the matcher to explain blur as zoom.
    static let scaleRange = 0.03

    /// Translation searched at the coarsest level, in pixels **at that level**. 10 coarse pixels on
    /// a 48 px edge is a fifth of the frame, far more than a tripod-mounted bracket ever shifts.
    static let coarseTranslation = 10

    /// A match must beat this correlation to be trusted. Below it the frames genuinely do not
    /// correspond (someone bumped the tripod, the subject moved) and forcing a transform on them
    /// would be worse than leaving the frame where it is.
    public static let minimumCorrelation = 0.5

    /// The outcome for one frame: where it goes, and whether the fit can be believed.
    public struct FrameAlignment: Equatable {
        public let transform: SimilarityTransform
        public let correlation: Double
        public var isTrusted: Bool { correlation >= minimumCorrelation }

        public init(transform: SimilarityTransform, correlation: Double) {
            self.transform = transform
            self.correlation = correlation
        }
    }

    /// Aligns every frame onto the geometry of `referenceIndex` (default: the middle frame, which
    /// halves the worst-case chain length and so the worst-case accumulated drift).
    ///
    /// Frames must all be the same shape. Returns one alignment per input, in order.
    public static func align(_ frames: [StackImage], referenceIndex: Int? = nil) -> [FrameAlignment] {
        guard frames.count > 1 else {
            return frames.map { _ in FrameAlignment(transform: .identity, correlation: 1) }
        }
        let reference = referenceIndex ?? frames.count / 2
        let lumas = frames.map { $0.luma() }

        // Neighbour-to-neighbour estimates: step[i] maps frame i onto frame i-1's geometry.
        var results = [FrameAlignment](repeating: FrameAlignment(transform: .identity, correlation: 1),
                                       count: frames.count)

        func walk(from start: Int, to end: Int, step: Int) {
            var accumulated = SimilarityTransform.identity
            var worstCorrelation = 1.0
            var index = start
            // `end` is one past the last frame to visit, in whichever direction: the bound has to
            // be tested against `next`, not against `index`, or the last iteration indexes past it.
            while true {
                let next = index + step
                if next == end { break }
                let fit = estimate(moving: lumas[next], fixed: lumas[index])
                // An untrusted step must not poison the rest of the chain: carry the running
                // transform forward unchanged rather than folding a bad estimate into it.
                if fit.correlation >= minimumCorrelation {
                    accumulated = fit.transform.concatenated(with: accumulated)
                }
                worstCorrelation = min(worstCorrelation, fit.correlation)
                results[next] = FrameAlignment(transform: accumulated, correlation: worstCorrelation)
                index = next
            }
        }

        walk(from: reference, to: -1, step: -1)
        walk(from: reference, to: frames.count, step: 1)
        return results
    }

    /// Estimates the transform taking `moving` onto `fixed`, coarse-to-fine.
    public static func estimate(moving: StackImage, fixed: StackImage) -> FrameAlignment {
        guard moving.isValid, fixed.isValid, moving.matchesShape(of: fixed) else {
            return FrameAlignment(transform: .identity, correlation: 0)
        }
        // Build matching pyramids down to `coarsestEdge`.
        var movingLevels = [moving], fixedLevels = [fixed]
        while max(movingLevels[0].width, movingLevels[0].height) > coarsestEdge * 2 {
            movingLevels.insert(StackPyramid.reduce(movingLevels[0]), at: 0)
            fixedLevels.insert(StackPyramid.reduce(fixedLevels[0]), at: 0)
        }

        // Coarsest level: exhaustive over the whole plausible parameter grid.
        var best = SimilarityTransform.identity
        var bestScore = -Double.infinity
        let scaleSteps = 12
        for s in -scaleSteps...scaleSteps {
            let scale = 1 + scaleRange * Double(s) / Double(scaleSteps)
            for ty in -coarseTranslation...coarseTranslation {
                for tx in -coarseTranslation...coarseTranslation {
                    let candidate = SimilarityTransform(scale: scale, tx: Double(tx), ty: Double(ty))
                    let score = correlation(moving: movingLevels[0], fixed: fixedLevels[0], candidate)
                    if score > bestScore { bestScore = score; best = candidate }
                }
            }
        }

        // Finer levels: the estimate is already close, so only a local refinement is needed.
        for level in 1..<movingLevels.count {
            let factor = Double(movingLevels[level].width) / Double(movingLevels[level - 1].width)
            best = best.scaledToResolution(factor: factor)
            bestScore = correlation(moving: movingLevels[level], fixed: fixedLevels[level], best)
            // Two passes of a shrinking local search: a single pass at one step size tends to stop
            // on the edge of its own neighbourhood when the level's optimum moved more than a step.
            for refinement in 0..<2 {
                let translationStep = 1.0 / Double(1 << refinement)
                let scaleStep = 0.002 / Double(1 << refinement)
                var improved = true
                while improved {
                    improved = false
                    for ds in -1...1 {
                        for dy in -1...1 {
                            for dx in -1...1 where !(ds == 0 && dx == 0 && dy == 0) {
                                let candidate = SimilarityTransform(
                                    scale: best.scale + Double(ds) * scaleStep,
                                    tx: best.tx + Double(dx) * translationStep,
                                    ty: best.ty + Double(dy) * translationStep
                                )
                                let score = correlation(moving: movingLevels[level], fixed: fixedLevels[level], candidate)
                                if score > bestScore + 1e-6 {
                                    bestScore = score
                                    best = candidate
                                    improved = true
                                }
                            }
                        }
                    }
                }
            }
        }
        return FrameAlignment(transform: best, correlation: bestScore.isFinite ? bestScore : 0)
    }

    /// Zero-mean normalised cross-correlation over the region where the warped `moving` image still
    /// lands inside its own bounds. Zero-mean and normalised because a focus change also changes
    /// apparent contrast and (slightly) brightness — a raw difference metric would chase those
    /// instead of the geometry.
    static func correlation(moving: StackImage, fixed: StackImage, _ transform: SimilarityTransform) -> Double {
        let w = fixed.width, h = fixed.height
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        // Skip the outer eighth: near the border a warp reads from outside the source, and clamped
        // edge pixels would contribute a constant that inflates the correlation.
        let insetX = max(1, w / 8), insetY = max(1, h / 8)
        guard w - 2 * insetX > 2, h - 2 * insetY > 2 else { return 0 }

        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        var n = 0.0
        for y in insetY..<(h - insetY) {
            for x in insetX..<(w - insetX) {
                let p = transform.source(x: Double(x), y: Double(y), centerX: cx, centerY: cy)
                guard p.x >= 0, p.y >= 0, p.x <= Double(w - 1), p.y <= Double(h - 1) else { continue }
                let a = Double(fixed.value(x: x, y: y, channel: 0))
                let b = sampleBilinear(moving, x: p.x, y: p.y)
                sumA += a; sumB += b
                sumAA += a * a; sumBB += b * b; sumAB += a * b
                n += 1
            }
        }
        guard n > 16 else { return 0 }
        let varA = sumAA - sumA * sumA / n
        let varB = sumBB - sumB * sumB / n
        let cov = sumAB - sumA * sumB / n
        let denom = (varA * varB).squareRoot()
        guard denom > 1e-12 else { return 0 }
        return cov / denom
    }

    /// Bilinear sample of channel 0, clamped at the border.
    @inline(__always)
    static func sampleBilinear(_ image: StackImage, x: Double, y: Double) -> Double {
        let w = image.width, h = image.height
        let x0 = min(max(Int(x.rounded(.down)), 0), w - 1)
        let y0 = min(max(Int(y.rounded(.down)), 0), h - 1)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let c = image.channels
        let v00 = Double(image.data[(y0 * w + x0) * c])
        let v10 = Double(image.data[(y0 * w + x1) * c])
        let v01 = Double(image.data[(y1 * w + x0) * c])
        let v11 = Double(image.data[(y1 * w + x1) * c])
        return v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + v01 * (1 - fx) * fy + v11 * fx * fy
    }

    /// Resamples `image` through `transform`, bilinearly, keeping the original size. Pixels that
    /// would read from outside the source clamp to the edge — the merge's own weighting then tends
    /// to reject those regions anyway, since a smeared clamped edge carries little energy.
    public static func warp(_ image: StackImage, by transform: SimilarityTransform) -> StackImage {
        guard image.isValid else { return image }
        if transform == .identity { return image }
        let w = image.width, h = image.height, c = image.channels
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        var out = [Float](repeating: 0, count: w * h * c)
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        let p = transform.source(x: Double(x), y: Double(y), centerX: cx, centerY: cy)
                        let sx = min(max(p.x, 0), Double(w - 1))
                        let sy = min(max(p.y, 0), Double(h - 1))
                        let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                        let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                        let i00 = (y0 * w + x0) * c, i10 = (y0 * w + x1) * c
                        let i01 = (y1 * w + x0) * c, i11 = (y1 * w + x1) * c
                        let d = (y * w + x) * c
                        for ch in 0..<c {
                            let top = src[i00 + ch] * (1 - fx) + src[i10 + ch] * fx
                            let bottom = src[i01 + ch] * (1 - fx) + src[i11 + ch] * fx
                            dst[d + ch] = top * (1 - fy) + bottom * fy
                        }
                    }
                }
            }
        }
        return StackImage(width: w, height: h, channels: c, data: out)
    }
}
