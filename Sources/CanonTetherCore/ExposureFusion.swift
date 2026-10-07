import Foundation

/// Blends a bracket by taking each part of the picture from whichever exposure rendered it well.
///
/// **This replaces tone mapping rather than tuning it.** Merging to radiance and then rendering it
/// means inventing a rendering — how bright the result should be, how much contrast, how much
/// saturation survives — and every one of those is a judgement call made by code that cannot see the
/// room. Tuning them produced a dim result, then a flat one, then a garish one.
///
/// The bracket already answers all three. For every part of the scene some frame exposed it
/// correctly, and the camera knows perfectly well how to render a correctly-exposed frame — that is
/// what its own processing does. So the frames are rendered normally and *blended*, and the output
/// is the camera's own rendering everywhere, chosen per region. No key, no curve, no saturation
/// control, nothing to dial.
///
/// This is Mertens-style exposure fusion. The blending is done on Laplacian pyramids, which is what
/// keeps it from haloing: a seam between two exposures is spread across every spatial scale rather
/// than cut at one, so there is no edge for a halo to form along.
public enum ExposureFusion {

    /// How much a pixel counts, from how well exposed it is.
    ///
    /// A Gaussian about mid-grey. Values near black carry noise and values near white carry nothing
    /// at all, and both should defer to whichever frame placed this part of the scene in the middle
    /// of its range — which is the frame whose rendering of it is worth having.
    public static func wellExposedness(_ value: Float) -> Float {
        let d = value - 0.5
        return expf(-(d * d) / (2 * sigma * sigma))
    }

    /// Width of that Gaussian. 0.2 keeps a usefully wide band in the middle rather than trusting
    /// only the pixels that happen to land near 0.5.
    public static let sigma: Float = 0.2

    /// Floor so that a pixel no frame exposed well still comes from the least-bad one rather than
    /// from an arbitrary division by zero.
    public static let weightFloor: Float = 1e-4

    /// Per-pixel weights for one frame, from its own rendered values.
    ///
    /// Luminance, not per channel: weighting channels separately would pull a saturated red toward
    /// whichever frame happened to place *red* near mid-grey, which shifts hue.
    public static func weights(for image: StackImage) -> StackImage {
        var out = StackImage(width: image.width, height: image.height, channels: 1)
        let c = image.channels
        for pixel in 0..<(image.width * image.height) {
            let base = pixel * c
            let luma: Float
            if c >= 3 {
                luma = 0.2126 * image.data[base] + 0.7152 * image.data[base + 1]
                     + 0.0722 * image.data[base + 2]
            } else {
                luma = image.data[base]
            }
            out.data[pixel] = Swift.max(wellExposedness(luma), weightFloor)
        }
        return out
    }

    public enum FusionError: Error, Equatable {
        case needsTwoFrames
        case sizeMismatch
    }

    /// Fuses rendered frames into one picture.
    ///
    /// - Parameter frames: the bracket as the camera renders it — display-referred, not linear.
    ///   That is the point: the output is made of the camera's own rendering.
    public static func fuse(_ frames: [StackImage], levels: Int = 6) throws -> StackImage {
        guard frames.count >= 2 else { throw FusionError.needsTwoFrames }
        guard frames.allSatisfy({ $0.matchesShape(of: frames[0]) }) else { throw FusionError.sizeMismatch }

        // Normalise the weights so every pixel's contributions sum to one — otherwise a region no
        // frame exposed well comes out darker than its neighbours for no reason a viewer can see.
        var maps = frames.map { weights(for: $0) }
        let pixels = frames[0].width * frames[0].height
        for pixel in 0..<pixels {
            var total: Float = 0
            for index in 0..<maps.count { total += maps[index].data[pixel] }
            guard total > 0 else { continue }
            for index in 0..<maps.count { maps[index].data[pixel] /= total }
        }

        // Blend each frequency band separately.
        //
        // This is what stops a seam. Blending the images directly would cut between exposures along
        // a hard boundary wherever the weights change quickly, and that edge is exactly what a halo
        // is. Combining band by band spreads each transition over that band's own scale — the coarse
        // bands cross over gradually, the fine bands keep their detail.
        let pyramids = frames.map { StackPyramid.laplacianPyramid($0, levels: levels) }
        let weightPyramids = maps.map { StackPyramid.gaussianPyramid($0, levels: levels) }

        var blended: [StackImage] = []
        for level in 0..<pyramids[0].count {
            let shape = pyramids[0][level]
            var accumulated = StackImage(width: shape.width, height: shape.height,
                                         channels: shape.channels)
            for (index, pyramid) in pyramids.enumerated() {
                let band = pyramid[level]
                let weight = weightPyramids[index][level]
                for pixel in 0..<(shape.width * shape.height) {
                    let w = weight.data[pixel]
                    let base = pixel * shape.channels
                    for channel in 0..<shape.channels {
                        accumulated.data[base + channel] += band.data[base + channel] * w
                    }
                }
            }
            blended.append(accumulated)
        }
        var result = StackPyramid.collapse(blended)
        for i in 0..<result.data.count { result.data[i] = Swift.min(Swift.max(result.data[i], 0), 1) }
        return result
    }
}
