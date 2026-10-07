import Foundation

/// The rendering that turns linear scene light into a photograph, learned from the camera's own
/// frame rather than invented.
///
/// The merge works in linear light because that is the only space in which exposures combine
/// correctly. But linear light encoded straight to sRGB is not a photograph — it has no toe, so
/// shadows sit flat and lifted, and no colour rendering, so everything reads washed out and cold.
/// Measured against a normal conversion of the same frame: shadows more than twice as bright and
/// the blue channel three times too high. The first version of this feature shipped exactly that,
/// and it looked terrible next to the straight-out-of-camera frame it was supposed to improve on.
///
/// So rather than guessing at a filmic curve, this samples the *same frame* rendered two ways —
/// linear, and as the RAW pipeline normally renders it — and builds the transfer between them. The
/// merged result then looks like an ordinary conversion of the metered exposure, which is exactly
/// the promise: the photograph you shot, with the highlights it could not hold.
public struct HDRToneCurve: Sendable {

    /// Fraction of a channel's maximum below which the learned curve is still considered to be
    /// carrying information rather than merely clipping.
    /// Fraction of the camera's rendered maximum below which its curve is reproduced exactly.
    /// Covers the midtones and shadows — the bulk of any photograph.
    public static let holdBelow: Float = 0.6
    /// How much of the S-curve to blend in, 0…1.
    ///
    /// 0.45 lands near the "+60 contrast" the photographer was reaching for by hand on a merge that
    /// already had the right range.
    public static let contrastStrength: Float = 0.45

    /// A smoothstep S about mid-grey, blended by `contrastStrength`.
    public static func contrast(_ value: Float) -> Float {
        let v = Swift.min(Swift.max(value, 0), 1)
        let s = v * v * (3 - 2 * v)              // 0 at 0, 1 at 1, steeper through the middle
        return v + (s - v) * contrastStrength
    }

    /// How far up the range the shadow lift reaches. Above this, nothing is touched.
    public static let shadowRange: Float = 0.5
    /// Gamma applied at the very bottom. Below 1 brightens; 0.75 is a modest lift — about +60% at
    /// 10% grey, +20% at 25%, and under +5% by the time it fades out.
    public static let shadowGamma: Float = 0.75

    /// Opens the shadows without lifting black off the floor.
    public static func lift(_ value: Float) -> Float {
        guard value > 0, value < shadowRange else { return value }
        let fade = 1 - value / shadowRange          // full strength at black, nothing at the range
        return value + (powf(value, shadowGamma) - value) * fade
    }

    /// Shape of the extension above the handover. Below 1 is convex, keeping some contrast in the
    /// recovered range rather than letting it flatten into a wash near white.
    public static let highlightGamma: Float = 0.85

    /// Entries per channel. 256 is plenty: the curve is smooth, and the samples come from millions
    /// of pixels.
    public static let resolution = 256

    /// Brightest scene radiance worth showing, in reference-exposure units. The compression is
    /// anchored to it so that the brightest recovered detail lands *at* display white instead of
    /// being crushed against it.
    public var sceneWhite: Float = 1
    /// Per-channel lookup over linear 0…1.
    private var table: [[Float]]
    /// Where each channel's curve reaches at linear 1.0 — the top of the ordinary rendering, and
    /// the floor of the headroom the shoulder has to work with.
    private var whitePoint: [Float]

    public var channels: Int { table.count }

    /// Builds the transfer from paired samples of the same pixels.
    ///
    /// - Parameters:
    ///   - linear: scene-linear values, interleaved.
    ///   - rendered: the same pixels as the RAW pipeline normally renders them, display-referred.
    public init(linear: [Float], rendered: [Float], channels: Int, sceneWhite: Float = 1) {
        self.sceneWhite = sceneWhite
        let n = min(linear.count, rendered.count)
        var sums = [[Double]](repeating: [Double](repeating: 0, count: Self.resolution), count: channels)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: Self.resolution), count: channels)

        var index = 0
        while index + channels <= n {
            for channel in 0..<channels {
                let l = linear[index + channel]
                guard l.isFinite, l >= 0 else { continue }
                let bin = Swift.min(Self.resolution - 1, Int(Swift.min(l, 1) * Float(Self.resolution - 1)))
                sums[channel][bin] += Double(rendered[index + channel])
                counts[channel][bin] += 1
            }
            index += channels
        }

        table = []
        whitePoint = []
        for channel in 0..<channels {
            var curve = [Float](repeating: 0, count: Self.resolution)
            // Fill measured bins, then carry the last known value across empty ones — a scene need
            // not contain every brightness, and a gap must not become a step in the curve.
            var last: Float = 0
            for bin in 0..<Self.resolution {
                if counts[channel][bin] > 0 {
                    last = Float(sums[channel][bin] / Double(counts[channel][bin]))
                }
                curve[bin] = last
            }
            // Monotonic by construction. Noise in a sparsely-sampled bin can otherwise put a dip in
            // the curve, which renders as a band of inverted contrast across a gradient.
            for bin in 1..<Self.resolution {
                curve[bin] = Swift.max(curve[bin], curve[bin - 1])
            }

            // **Trust the learned curve only where it is still gentle; extend it smoothly.**
            //
            // The reference frame is the one with blown highlights — that is why there is a bracket
            // at all — so wherever it clipped, the rendering it teaches is just "white". The curve
            // arrives at white early and stays flat, and compressed highlights land in that flat top
            // and come back as white with no separation.
            //
            // The first attempt kept the curve and ramped from wherever it saturated to white. That
            // was worse: saturation happens within a few bins of the top, so the ramp was extremely
            // steep and amplified tiny differences in the recovered range into visible blotches — a
            // clean sky in the source came back mottled.
            //
            // So the handover happens low, at `holdBelow`. Below it the camera's own rendering is
            // reproduced exactly (midtones and shadows: the bulk of any photograph). Above it, the
            // whole remaining input range is spread smoothly across the whole remaining display
            // range, which is gentle by construction and has nowhere to band.
            let maximum = Swift.max(curve[Self.resolution - 1], 0.0001)
            var handover = Self.resolution - 1
            for bin in 0..<Self.resolution where curve[bin] >= Self.holdBelow * maximum {
                handover = bin
                break
            }
            if handover < Self.resolution - 1 {
                let start = curve[handover]
                let span = Float(Self.resolution - 1 - handover)
                for bin in (handover + 1)..<Self.resolution {
                    let t = Float(bin - handover) / span
                    // Slightly convex, so the recovered range keeps a little contrast rather than
                    // flattening into an even wash as it approaches white.
                    curve[bin] = start + (1 - start) * powf(t, Self.highlightGamma)
                }
            }
            // Contrast and the shadow lift are **not** baked in here.
            //
            // This table is per channel, because it is reproducing the camera's own rendering
            // including its white balance. Applying a *tonal* curve per channel as well stretches
            // the gaps between R, G and B — which is a saturation and hue shift, not a brightness
            // change. Shipped that way it turned a warm wall into a garish orange and read as
            // exactly the over-processed look this feature exists to avoid. Tonality is applied to
            // luminance in `render`, with the colour ratios carried across unchanged.

            table.append(curve)
            whitePoint.append(curve[Self.resolution - 1])
        }
    }

    /// Applies the learned rendering, extending above linear 1.0 with a global shoulder.
    ///
    /// Below 1.0 this *is* the ordinary rendering, so the picture matches a normal conversion of the
    /// metered frame. Above it — the range only the bracket has — an asymptotic shoulder fills
    /// whatever display headroom the rendering left above its own white point.
    public func apply(_ radiance: Float, channel: Int) -> Float {
        guard channel < table.count else { return radiance }
        // **Compress first, render second.**
        //
        // The obvious order — render below white, then fit recovered highlights above it — cannot
        // work: an ordinary rendering already reaches display white at linear 1.0, so there is no
        // headroom left to put anything in. Shipped that way, every recovered highlight collapsed
        // onto white, and because each channel's curve reaches white at a slightly different point,
        // a recovered sky came out **cyan and mottled** — green and blue pinned, red alone carrying
        // detail.
        //
        // Doing it the other way round is also how a photographer would: pull the highlights down
        // in *scene* terms until they fit, then develop the frame normally. Below the knee the
        // radiance is untouched, so the midtones and shadows still render exactly as an ordinary
        // conversion of the metered frame.
        let compressed = Self.compress(radiance, sceneWhite: sceneWhite)
        let curve = table[channel]
        let position = Swift.min(Swift.max(compressed, 0), 1) * Float(Self.resolution - 1)
        let low = Int(position)
        let high = Swift.min(low + 1, Self.resolution - 1)
        let t = position - Float(low)
        return curve[low] * (1 - t) + curve[high] * t
    }

    /// Folds the scene's whole range into 0…1 of linear light, anchored so `sceneWhite` lands
    /// exactly at 1.
    ///
    /// `L (1 + L/W²) / (1 + L)` — the extended Reinhard curve. Three properties earn it the job:
    /// it is monotonic and smooth everywhere (no knee to band across a sky), it leaves dark values
    /// almost untouched (a shadow at 0.02 moves by well under a percent), and it maps `W` to exactly
    /// 1 so the brightest thing the bracket found becomes white rather than one of many values
    /// crushed against it.
    ///
    /// **An asymptotic knee was tried first and does not work here.** Squeezing everything above a
    /// knee into the band below 1 left a recovered sky at 0.958 linear — which an ordinary
    /// rendering maps to white anyway, so the sky came back with no tonal separation at all, cyan
    /// where the three channels hit white at slightly different points. To *show* recovered
    /// highlights they have to be rendered darker than white; there is no way around spending
    /// display range on them.
    ///
    /// The cost is a small, global darkening of the upper midtones — on a real frame, a midtone at
    /// 0.18 moves to about 0.15, a quarter of a stop. That is the honest price of the extra range,
    /// and it is uniform across the frame rather than the local, neighbourhood-dependent
    /// manipulation that makes tone-mapped images look wrong.
    public static func compress(_ radiance: Float, sceneWhite: Float) -> Float {
        let value = Swift.max(radiance, 0)
        let white = Swift.max(sceneWhite, 1)
        return value * (1 + value / (white * white)) / (1 + value)
    }

    /// Renders a whole merged image.
    ///
    /// Two stages, deliberately separated. The learned curve runs **per channel**, because it is
    /// reproducing a rendering that includes white balance. Contrast and the shadow lift then run on
    /// **luminance only**, and every channel is scaled by the same factor — so the picture's
    /// tonality changes while its colour does not.
    public func render(_ radiance: StackImage) -> StackImage {
        var out = radiance
        let channels = radiance.channels
        guard channels >= 3 else {
            for i in 0..<out.data.count {
                let rendered = apply(radiance.data[i], channel: i % channels)
                out.data[i] = Swift.min(Swift.max(Self.lift(Self.contrast(rendered)), 0), 1)
            }
            return out
        }
        for pixel in stride(from: 0, to: out.data.count - channels + 1, by: channels) {
            let r = apply(radiance.data[pixel], channel: 0)
            let g = apply(radiance.data[pixel + 1], channel: 1)
            let b = apply(radiance.data[pixel + 2], channel: 2)
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard luma > 0.0001 else {
                out.data[pixel] = r; out.data[pixel + 1] = g; out.data[pixel + 2] = b
                continue
            }
            let shaped = Self.lift(Self.contrast(luma))
            let gain = shaped / luma
            out.data[pixel]     = Swift.min(Swift.max(r * gain, 0), 1)
            out.data[pixel + 1] = Swift.min(Swift.max(g * gain, 0), 1)
            out.data[pixel + 2] = Swift.min(Swift.max(b * gain, 0), 1)
            for extra in 3..<channels { out.data[pixel + extra] = radiance.data[pixel + extra] }
        }
        return out
    }
}
