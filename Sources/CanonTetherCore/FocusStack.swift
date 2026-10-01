import Foundation

/// A plain interleaved float image — the currency the whole stacking pipeline trades in.
///
/// Deliberately *not* `ScopeFrame`: the scopes measure a small RGBA snapshot for display, while
/// stacking merges real pixel data at whatever size the renderer hands it, needs an arbitrary
/// channel count (3 for RGB merges, 1 for the luma planes alignment works on) and gets mutated in
/// place level by level. Values are extended-range sRGB floats, same convention as `ScopeFrame`,
/// so a wide-gamut source survives the merge rather than being clipped on the way in.
public struct StackImage: Equatable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public var data: [Float]   // row-major, interleaved, no row padding

    public init(width: Int, height: Int, channels: Int, data: [Float]) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    /// A zero-filled image of the given shape.
    public init(width: Int, height: Int, channels: Int) {
        self.init(width: width, height: height, channels: channels,
                  data: [Float](repeating: 0, count: max(0, width * height * channels)))
    }

    public var isValid: Bool {
        width > 0 && height > 0 && channels > 0 && data.count == width * height * channels
    }

    public var pixelCount: Int { width * height }

    /// Same shape (dimensions *and* channel count) as another image — the precondition every
    /// multi-image operation here needs, checked once rather than trusted.
    public func matchesShape(of other: StackImage) -> Bool {
        width == other.width && height == other.height && channels == other.channels
    }

    @inline(__always)
    public func value(x: Int, y: Int, channel: Int) -> Float {
        data[(y * width + x) * channels + channel]
    }

    /// Rec.709 luma as a single-channel image. Alignment works on this rather than on colour: it
    /// halves the sampling cost and drops chroma noise, which carries no registration information.
    public func luma() -> StackImage {
        guard isValid else { return StackImage(width: 0, height: 0, channels: 1, data: []) }
        var out = [Float](repeating: 0, count: pixelCount)
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                if channels >= 3 {
                    for i in 0..<(width * height) {
                        let p = i * channels
                        dst[i] = 0.2126 * src[p] + 0.7152 * src[p + 1] + 0.0722 * src[p + 2]
                    }
                } else {
                    for i in 0..<(width * height) { dst[i] = src[i * channels] }
                }
            }
        }
        return StackImage(width: width, height: height, channels: 1, data: out)
    }
}

/// Gaussian/Laplacian pyramid machinery, the backbone of the merge.
///
/// Focus stacking by picking the sharper *pixel* produces visible seams and halos wherever the
/// winner flips, because neighbouring pixels can come from frames whose brightness and blur differ.
/// Fusing in a Laplacian pyramid instead lets each spatial frequency band choose independently and
/// blends the choice over a band-appropriate distance — the standard Burt & Adelson construction —
/// so a focus boundary crossfades rather than cuts.
public enum StackPyramid {
    /// The separable 5-tap binomial kernel (1 4 6 4 1)/16 Burt & Adelson use. Wide enough to be a
    /// decent low-pass, narrow enough that the edge clamping below stays cheap.
    static let kernel: [Float] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]

    /// Half-samples a blurred copy: dimensions go to `(n + 1) / 2`, so odd sizes keep their last
    /// row/column instead of being truncated away (which would make `expand` unable to get back).
    public static func reduce(_ image: StackImage) -> StackImage {
        let blurred = convolve(image, kernel: kernel)
        let w = (image.width + 1) / 2, h = (image.height + 1) / 2
        let c = image.channels
        var out = [Float](repeating: 0, count: w * h * c)
        blurred.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let sy = min(y * 2, image.height - 1)
                    for x in 0..<w {
                        let sx = min(x * 2, image.width - 1)
                        let s = (sy * image.width + sx) * c, d = (y * w + x) * c
                        for ch in 0..<c { dst[d + ch] = src[s + ch] }
                    }
                }
            }
        }
        return StackImage(width: w, height: h, channels: c, data: out)
    }

    /// The inverse of `reduce` up to the detail `reduce` threw away: zero-stuff to the target size
    /// and low-pass. The kernel is doubled per axis because only a quarter of the output samples
    /// carry energy after zero-stuffing — omit that and every expanded level comes back dark.
    public static func expand(_ image: StackImage, toWidth: Int, toHeight: Int) -> StackImage {
        let c = image.channels
        var upsampled = [Float](repeating: 0, count: toWidth * toHeight * c)
        image.data.withUnsafeBufferPointer { src in
            upsampled.withUnsafeMutableBufferPointer { dst in
                for y in 0..<image.height {
                    let dy = y * 2
                    guard dy < toHeight else { continue }
                    for x in 0..<image.width {
                        let dx = x * 2
                        guard dx < toWidth else { continue }
                        let s = (y * image.width + x) * c, d = (dy * toWidth + dx) * c
                        for ch in 0..<c { dst[d + ch] = src[s + ch] }
                    }
                }
            }
        }
        let stuffed = StackImage(width: toWidth, height: toHeight, channels: c, data: upsampled)
        return convolve(stuffed, kernel: kernel.map { $0 * 2 })
    }

    /// Separable convolution with edge clamping (the border repeats rather than darkening, which a
    /// zero-padded edge would do and which the merge would then read as a sharp edge).
    public static func convolve(_ image: StackImage, kernel k: [Float]) -> StackImage {
        guard image.isValid, !k.isEmpty else { return image }
        let w = image.width, h = image.height, c = image.channels
        let radius = k.count / 2
        let taps = k.count

        // Borders are clamped, the interior is not.
        //
        // The straightforward version tested `min(max(…))` per tap, per channel, per pixel — two
        // branches in the innermost loop of the whole merge, which is 87% of a stack's render time
        // (199s of 229s on a 24-frame bracket). Only the first and last `radius` columns and rows
        // can actually fall outside, so the interior runs as a flat walk at a fixed stride and the
        // edges keep the clamped form. The accumulation order is unchanged, so the result is
        // bit-for-bit identical to the naive version — worth preserving, since the merged TIFF is
        // checksummed against a reference render.
        var horizontal = [Float](repeating: 0, count: w * h * c)
        image.data.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { dst in
                k.withUnsafeBufferPointer { kp in
                    let lo = min(radius, w)
                    let hi = max(lo, w - radius)
                    for y in 0..<h {
                        let row = y * w
                        func clamped(_ x: Int) {
                            for ch in 0..<c {
                                var sum: Float = 0
                                for t in 0..<taps {
                                    let sx = min(max(x + t - radius, 0), w - 1)
                                    sum += kp[t] * src[(row + sx) * c + ch]
                                }
                                dst[(row + x) * c + ch] = sum
                            }
                        }
                        for x in 0..<lo { clamped(x) }
                        for x in lo..<hi {
                            let base = (row + x - radius) * c
                            let out = (row + x) * c
                            for ch in 0..<c {
                                var sum: Float = 0
                                var p = base + ch
                                for t in 0..<taps {
                                    sum += kp[t] * src[p]
                                    p += c
                                }
                                dst[out + ch] = sum
                            }
                        }
                        for x in hi..<w { clamped(x) }
                    }
                }
            }
        }

        var vertical = [Float](repeating: 0, count: w * h * c)
        horizontal.withUnsafeBufferPointer { src in
            vertical.withUnsafeMutableBufferPointer { dst in
                k.withUnsafeBufferPointer { kp in
                    let lo = min(radius, h)
                    let hi = max(lo, h - radius)
                    let stride = w * c
                    func clampedRow(_ y: Int) {
                        for x in 0..<w {
                            for ch in 0..<c {
                                var sum: Float = 0
                                for t in 0..<taps {
                                    let sy = min(max(y + t - radius, 0), h - 1)
                                    sum += kp[t] * src[(sy * w + x) * c + ch]
                                }
                                dst[(y * w + x) * c + ch] = sum
                            }
                        }
                    }
                    for y in 0..<lo { clampedRow(y) }
                    for y in lo..<hi {
                        let base = (y - radius) * stride
                        let out = y * stride
                        for x in 0..<w {
                            for ch in 0..<c {
                                var sum: Float = 0
                                var p = base + x * c + ch
                                for t in 0..<taps {
                                    sum += kp[t] * src[p]
                                    p += stride
                                }
                                dst[out + x * c + ch] = sum
                            }
                        }
                    }
                    for y in hi..<h { clampedRow(y) }
                }
            }
        }
        return StackImage(width: w, height: h, channels: c, data: vertical)
    }

    /// A Laplacian pyramid: `levels - 1` band-pass levels, finest first, with the residual
    /// low-pass ("base") as the final entry. Collapsing this exactly reconstructs the input, which
    /// is what `StackPyramidTests` pins — an inexact pyramid silently costs contrast in the merge.
    public static func laplacianPyramid(_ image: StackImage, levels: Int) -> [StackImage] {
        var pyramid: [StackImage] = []
        var current = image
        for _ in 0..<max(0, levels - 1) {
            // Below 4 px a level carries no usable band and `reduce` stops shrinking meaningfully.
            guard current.width >= 4, current.height >= 4 else { break }
            let down = reduce(current)
            let up = expand(down, toWidth: current.width, toHeight: current.height)
            var band = current
            for i in 0..<band.data.count { band.data[i] -= up.data[i] }
            pyramid.append(band)
            current = down
        }
        pyramid.append(current)
        return pyramid
    }

    /// Rebuilds an image from `laplacianPyramid`'s output.
    public static func collapse(_ pyramid: [StackImage]) -> StackImage {
        guard var current = pyramid.last else {
            return StackImage(width: 0, height: 0, channels: 0, data: [])
        }
        for level in stride(from: pyramid.count - 2, through: 0, by: -1) {
            let band = pyramid[level]
            let up = expand(current, toWidth: band.width, toHeight: band.height)
            var sum = band
            for i in 0..<sum.data.count { sum.data[i] += up.data[i] }
            current = sum
        }
        return current
    }

    /// How many pyramid levels an image of this size supports, capped so the coarsest level stays
    /// big enough to mean something.
    public static func levelCount(width: Int, height: Int, max maxLevels: Int = 7) -> Int {
        var levels = 1
        var w = width, h = height
        while w >= 8 && h >= 8 && levels < maxLevels {
            w = (w + 1) / 2
            h = (h + 1) / 2
            levels += 1
        }
        return levels
    }
}
