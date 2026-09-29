import Foundation

/// Merges a set of differently-exposed frames into one image with more dynamic range than the
/// camera can hold in a single shot.
///
/// **This is not a tone mapper, and deliberately so.** The cliché "HDR look" — grey flat midtones,
/// haloed edges, crunchy local contrast — comes from *local* operators, which decide each pixel's
/// output from its neighbourhood. Nothing here looks at a neighbourhood. The frames are combined in
/// linear light, the result is scaled so the properly-exposed frame's midtones land exactly where
/// that frame put them, and the only tone manipulation is a **global** shoulder applied to the
/// highlight range that a single exposure could not hold.
///
/// So the result should read as the photograph you metered for, with the blown highlights recovered
/// and the shadows cleaner. Shadows are not lifted: lifting them is the other half of the cliché,
/// and anyone who wants that can do it afterwards with the extra information now present.
public enum HDRMerge {

    // MARK: - Transfer

    /// sRGB's electro-optical transfer function — encoded value to linear light.
    ///
    /// Frames arrive gamma-encoded. Averaging them in that space is simply wrong: a stop of
    /// exposure is a factor of two in *light*, not in code value, and blending encoded values makes
    /// the midtones drift in a way no amount of curve-tweaking afterwards can undo.
    public static func linearize(_ encoded: Float) -> Float {
        let v = min(max(encoded, 0), 1)
        return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    /// The inverse, for writing the result back out.
    public static func encode(_ linear: Float) -> Float {
        let v = max(linear, 0)
        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
        return min(max(encoded, 0), 1)
    }

    // MARK: - Reliability

    /// How much a sample from one frame should count toward the result.
    ///
    /// Zero at both ends and smooth in between: a clipped highlight carries no information about how
    /// bright the scene actually was, and a value down in the noise floor carries almost none about
    /// anything. Between those, a sample's usefulness rises toward the middle of the frame's range,
    /// where the sensor is most linear and the signal-to-noise best.
    ///
    /// The curve is a raised cosine rather than the usual triangle. A triangle has a corner at the
    /// midpoint, and the weights of two overlapping exposures then cross with a discontinuous
    /// derivative — which shows up as faint banding across smooth gradients like skies, exactly
    /// where an HDR merge is most visible.
    public static func reliability(of encoded: Float) -> Float {
        // Ignore the very ends outright: sensor clipping and black level are not signal.
        guard encoded > deadZone, encoded < 1 - deadZone else { return 0 }
        let t = (encoded - deadZone) / (1 - 2 * deadZone)      // 0…1 across the usable range
        return 0.5 - 0.5 * cosf(2 * .pi * t)                    // raised cosine, 0 at both ends
    }

    /// Fraction of the encoded range at each end treated as unusable.
    public static let deadZone: Float = 0.02

    // MARK: - Merging

    /// One frame of the bracket.
    public struct Frame {
        public let image: StackImage
        /// Relative exposure: how much light this frame collected, compared with any other frame.
        ///
        /// Proportional to `shutter x ISO / aperture^2`. Only the *ratios* matter, so any consistent
        /// scale works.
        public let exposure: Double

        public init(image: StackImage, exposure: Double) {
            self.image = image
            self.exposure = exposure
        }
    }

    public enum MergeError: Error, Equatable {
        case needsTwoFrames
        case sizeMismatch
        case invalidExposure
    }

    /// Combines the bracket into a linear radiance image, in units of the *reference* frame's
    /// exposure — so a value of 1.0 is what that frame rendered as white, and values above 1.0 are
    /// the highlight detail it could not hold.
    ///
    /// - Parameter reference: index of the frame that is correctly exposed for the subject. The
    ///   result is anchored to it, which is what keeps the picture looking like the one that was
    ///   metered rather than like an average of the bracket.
    public static func radiance(from frames: [Frame], reference: Int) throws -> StackImage {
        guard frames.count >= 2 else { throw MergeError.needsTwoFrames }
        guard frames.allSatisfy({ $0.image.matchesShape(of: frames[0].image) }) else {
            throw MergeError.sizeMismatch
        }
        guard frames.allSatisfy({ $0.exposure > 0 }) else { throw MergeError.invalidExposure }
        let referenceIndex = min(max(reference, 0), frames.count - 1)
        let referenceExposure = Float(frames[referenceIndex].exposure)

        let width = frames[0].image.width, height = frames[0].image.height
        let channels = frames[0].image.channels
        var out = StackImage(width: width, height: height, channels: channels)

        // Exposure of each frame relative to the reference. A frame given twice the light has
        // scale 2, and its linear values are divided by that to describe the same scene radiance.
        let scales = frames.map { Float($0.exposure) / referenceExposure }

        for i in 0..<(width * height * channels) {
            var weighted: Float = 0
            var total: Float = 0
            // Fallbacks for a pixel no frame renders usably.
            var brightestUsable: Float = 0     // from the least-exposed frame: highlight detail
            var darkestUsable: Float = .greatestFiniteMagnitude
            for (index, frame) in frames.enumerated() {
                let encoded = frame.image.data[i]
                let radiance = linearize(encoded) / scales[index]
                let weight = reliability(of: encoded)
                if weight > 0 {
                    weighted += radiance * weight
                    total += weight
                }
                brightestUsable = max(brightestUsable, radiance)
                darkestUsable = min(darkestUsable, radiance)
            }
            if total > 0 {
                out.data[i] = weighted / total
            } else {
                // Every frame clipped or crushed here. Blown in all of them means the scene really
                // is brighter than the bracket reached, so take the brightest estimate; black in
                // all of them means it really is that dark. Guessing beyond the bracket is how a
                // merge invents detail that was never photographed.
                let allClipped = frames.allSatisfy { $0.image.data[i] >= 1 - deadZone }
                out.data[i] = allClipped ? brightestUsable
                                         : (darkestUsable == .greatestFiniteMagnitude ? 0 : darkestUsable)
            }
        }
        return out
    }

    // MARK: - Rendering back to a picture

    /// Where the shoulder begins. Below this the result is the reference exposure, untouched.
    ///
    /// 0.75 in linear light is a bright highlight but not yet white — skin highlights, a lit wall.
    /// Putting the knee here leaves everything a normal exposure renders well exactly as it was,
    /// and spends the curve only on what a single frame could not hold.
    public static let defaultKnee: Float = 0.75

    /// Compresses recovered highlights into the top of the display range, and changes nothing else.
    ///
    /// Below `knee`, output equals input: the midtones and shadows of the reference exposure pass
    /// through untouched, which is the whole point — the photograph keeps the rendering that was
    /// metered for. Above it, a smooth asymptotic shoulder maps the remaining range into
    /// `knee…1.0`, so highlights that used to clip now roll off instead.
    ///
    /// The curve is C¹ at the knee (it matches both value and slope), so there is no visible edge
    /// where the shoulder starts — a discontinuity in slope there is precisely what makes a badly
    /// tone-mapped sky look like it has a band across it.
    public static func shoulder(_ value: Float, knee: Float = defaultKnee) -> Float {
        guard value > knee else { return max(value, 0) }
        guard knee < 1 else { return min(value, 1) }
        let headroom = 1 - knee                    // display range left for everything above the knee
        let excess = value - knee
        // Asymptotic: excess/(excess + headroom) approaches 1 as the input grows without bound, and
        // has slope 1 at excess = 0, matching the identity below the knee.
        return knee + headroom * (excess / (excess + headroom))
    }

    /// The finished, display-referred image: radiance in reference-exposure units, rolled off and
    /// re-encoded to sRGB.
    public static func render(_ radiance: StackImage, knee: Float = defaultKnee) -> StackImage {
        var out = radiance
        for i in 0..<out.data.count {
            out.data[i] = encode(shoulder(radiance.data[i], knee: knee))
        }
        return out
    }

    /// How many stops of highlight the merge actually recovered, for telling the photographer what
    /// the bracket bought them.
    ///
    /// Measured as the brightest radiance that survives into the result, in stops above what the
    /// reference exposure could hold. A bracket that returns ~0 recovered nothing — the extra frames
    /// were not needed, or were not different enough to matter.
    public static func recoveredStops(_ radiance: StackImage) -> Double {
        var peak: Float = 0
        // The very brightest pixel is usually a specular highlight; take a high percentile instead,
        // which is what the photographer will actually see as recovered detail.
        var sorted = radiance.data.filter { $0.isFinite && $0 > 1 }
        guard !sorted.isEmpty else { return 0 }
        sorted.sort()
        peak = sorted[Int(Double(sorted.count) * 0.99)]
        return peak > 1 ? log2(Double(peak)) : 0
    }
}
