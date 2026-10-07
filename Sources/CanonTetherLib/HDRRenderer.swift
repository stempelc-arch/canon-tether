import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CanonTetherCore

/// Renders an exposure bracket into one image holding more dynamic range than a single frame can.
///
/// The decode is the part that matters. `ImageIO` on a CR2 from this body returns **8 bits per
/// component, clipped at white** — measured — which discards exactly what shooting RAW is for.
/// `CIRAWFilter` rendered into a linear working space, with Apple's "boost" curve off, returns
/// float data that runs *above* 1.0: on a single test frame it peaked at 1.56 before any
/// bracketing. That headroom is the feature.
///
/// No alignment. A bracket is shot in a couple of seconds on a tripod under app control, and
/// registering differently-exposed frames reliably is a different and much harder problem than
/// registering a focus stack — a bad estimate would smear the very highlights the bracket exists to
/// recover. If a frame moves, the honest answer is to reshoot.
enum HDRRenderer {

    struct Render {
        let outputURL: URL
        let sourceCount: Int
        /// Stops of highlight detail recovered beyond what the metered frame could hold.
        let recoveredStops: Double
    }

    enum RenderError: LocalizedError {
        case needsTwoFrames
        case decodeFailed(URL)
        case sizeMismatch
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .needsTwoFrames: return "An HDR merge needs at least two exposures."
            case .decodeFailed(let url): return "Couldn't read \(url.lastPathComponent)."
            case .sizeMismatch: return "The frames aren't all the same size."
            case .writeFailed: return "Couldn't write the merged image."
            }
        }
    }

    /// Rows per strip. Three frames of a 20 MP RAW as linear RGBA float is ~1 GB if held whole;
    /// in strips it is a few tens of MB.
    static let stripRows = 512

    static func render(urls: [URL],
                       referenceIndex: Int,
                       outputURL: URL,
                       progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> Render {
        guard urls.count >= 2 else { throw RenderError.needsTwoFrames }

        progress(0.02, "Reading exposures…")
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linearSpace,
                                          .outputColorSpace: linearSpace,
                                          .cacheIntermediates: false])

        // Decode each frame's *relative* exposure from its own EXIF, rather than trusting the
        // bracket to have been shot as planned. If the body clamped a shutter speed, or the
        // photographer bracketed by hand, the file says what actually happened.
        var images: [CIImage] = []
        var exposures: [Double] = []
        for url in urls {
            guard let filter = CIRAWFilter(imageURL: url) else { throw RenderError.decodeFailed(url) }
            // **The camera's own rendering, left alone.** The output is made of these frames, so
            // every region ends up rendered the way the camera renders a correctly-exposed frame —
            // which is where the brightness, contrast and colour come from, rather than from
            // constants chosen by code that cannot see the room.
            guard let image = filter.outputImage else { throw RenderError.decodeFailed(url) }
            images.append(image)
            exposures.append(relativeExposure(of: url) ?? 1)
        }
        guard images.allSatisfy({ $0.extent.size == images[0].extent.size }) else {
            throw RenderError.sizeMismatch
        }

        let extent = images[0].extent
        let width = Int(extent.width), height = Int(extent.height)
        let channels = 3
        var output = [UInt16](repeating: 0, count: width * height * channels)
        var rowBuffer = [Float](repeating: 0, count: width * stripRows * 4)
        let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!

        var row = 0
        while row < height {
            let rows = min(stripRows, height - row)
            let bandRect = CGRect(x: extent.minX, y: extent.minY + CGFloat(height - row - rows),
                                  width: extent.width, height: CGFloat(rows))
            var strips: [StackImage] = []
            for image in images {
                rowBuffer.withUnsafeMutableBytes { raw in
                    context.render(image, toBitmap: raw.baseAddress!,
                                   rowBytes: width * 4 * MemoryLayout<Float>.size,
                                   bounds: bandRect, format: .RGBAf, colorSpace: displaySpace)
                }
                var strip = StackImage(width: width, height: rows, channels: channels)
                for pixel in 0..<(width * rows) {
                    strip.data[pixel * 3 + 0] = rowBuffer[pixel * 4 + 0]
                    strip.data[pixel * 3 + 1] = rowBuffer[pixel * 4 + 1]
                    strip.data[pixel * 3 + 2] = rowBuffer[pixel * 4 + 2]
                }
                strips.append(strip)
            }

            let fused = try ExposureFusion.fuse(strips)
            for i in 0..<(width * rows * channels) {
                output[row * width * channels + i] = UInt16(min(max(fused.data[i], 0), 1) * 65535)
            }
            row += rows
            progress(0.05 + 0.9 * Double(row) / Double(height),
                     "Blending \(Int(Double(row) / Double(height) * 100))%…")
        }

        progress(0.97, "Writing merged image…")
        try writeTIFF(output, width: width, height: height, to: outputURL)

        // Stops of range the bracket itself covered, from the exposures actually used — the
        // honest measure now that nothing is tone mapped.
        let spread = exposures.max().flatMap { high in exposures.min().map { log2(high / $0) } } ?? 0
        progress(1, "Done.")
        return Render(outputURL: outputURL, sourceCount: urls.count, recoveredStops: spread)
    }
    /// Mean brightness of a frame, in linear light, for the timelapse ramp.
    ///
    /// A high percentile rather than the mean: the mean of a landscape is dominated by whichever of
    /// sky and ground is larger, so a camera panned slightly between sequences would meter
    /// differently for no reason the viewer can see. The 70th percentile tracks "how bright is the
    /// lit part of this scene", which is what a ramp should hold steady, and ignores both a dark
    /// foreground and a small bright sun.
    static func rampBrightness(of url: URL) -> Double? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        guard let image = filter.outputImage else { return nil }
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linearSpace,
                                          .outputColorSpace: linearSpace,
                                          .cacheIntermediates: false])
        let edge: CGFloat = 400
        let scale = edge / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 0, h > 0 else { return nil }
        var buffer = [Float](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: small.extent, format: .RGBAf, colorSpace: linearSpace)
        }
        var luma = [Float](); luma.reserveCapacity(w * h)
        for pixel in 0..<(w * h) {
            let value = 0.2126 * buffer[pixel * 4] + 0.7152 * buffer[pixel * 4 + 1]
                      + 0.0722 * buffer[pixel * 4 + 2]
            if value.isFinite, value > 0 { luma.append(value) }
        }
        guard !luma.isEmpty else { return nil }
        luma.sort()
        return Double(luma[Int(Double(luma.count) * 0.70)])
    }

    /// Develops one timelapse frame with a gain, straight to a 16-bit TIFF.
    ///
    /// The gain is what makes a 1/3-stop exposure click invisible, so it is applied in **linear**
    /// light, before the rendering — a gain applied to already-rendered values would lighten the
    /// shadows and the highlights by different amounts and leave a different seam behind.
    static func developRamped(_ url: URL, gainStops: Double, to outputURL: URL) throws {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RenderError.decodeFailed(url) }
        // Apple's rendering, plus the correction as an exposure adjustment — `exposure` is in stops
        // and acts on scene light, which is exactly what the deflicker gain is.
        filter.exposure = Float(gainStops)
        guard let image = filter.outputImage else { throw RenderError.decodeFailed(url) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.outputColorSpace: space])
        guard let cg = context.createCGImage(image, from: image.extent,
                                             format: .RGBA16, colorSpace: space) else {
            throw RenderError.writeFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw RenderError.writeFailed
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.writeFailed }
    }

    /// What one exposure recorded: how much it lost at each end.
    ///
    /// Read at low resolution — this decides whether to shoot another frame, and the answer is a
    /// fraction of the picture, not a per-pixel judgement. A full decode per probe would add
    /// seconds to every bracket for no change in the decision.
    static func coverage(of url: URL) -> HDRAutoBracket.Coverage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        guard let image = filter.outputImage else { return nil }
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linearSpace,
                                          .outputColorSpace: linearSpace,
                                          .cacheIntermediates: false])
        let edge: CGFloat = 500
        let scale = edge / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 0, h > 0 else { return nil }
        var buffer = [Float](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: small.extent, format: .RGBAf, colorSpace: linearSpace)
        }

        var clipped = 0, crushed = 0
        let total = w * h
        for pixel in 0..<total {
            let r = buffer[pixel * 4], g = buffer[pixel * 4 + 1], bch = buffer[pixel * 4 + 2]
            // Clipped if *any* channel has run out: a blown red leaves the pixel's colour wrong even
            // where the others still hold detail.
            if r >= clipLevel || g >= clipLevel || bch >= clipLevel { clipped += 1 }
            // Crushed on luminance rather than per channel — a deep blue shadow is not a fault.
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * bch
            if luma < noiseFloor { crushed += 1 }
        }
        return HDRAutoBracket.Coverage(clipped: Double(clipped) / Double(total),
                                       crushed: Double(crushed) / Double(total))
    }

    /// Linear value at which a frame is out of highlight information.
    ///
    /// 1.0 is this frame's white point. `CIRAWFilter` does return values above it, reconstructed
    /// from whichever channels had not yet saturated, but that reconstruction is a guess about
    /// colour — it is exactly what a darker frame in the bracket exists to replace.
    static let clipLevel: Float = 1.0

    /// Linear luminance below which there is nothing worth merging.
    ///
    /// About nine stops under the frame's white point. Below that this sensor's read noise is a
    /// large share of the signal at the ISOs a tethered shoot uses, and a brighter exposure is the
    /// only thing that helps.
    static let noiseFloor: Float = 0.002

    /// Relative exposure from EXIF: how much light this frame collected, on an arbitrary but
    /// consistent scale. Only ratios matter to the merge.
    static func relativeExposure(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        let seconds = exif[kCGImagePropertyExifExposureTime] as? Double ?? 1
        let fNumber = exif[kCGImagePropertyExifFNumber] as? Double ?? 1
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first ?? 100
        guard seconds > 0, fNumber > 0, iso > 0 else { return nil }
        // Light collected is proportional to time x sensitivity / f-number^2.
        return seconds * (iso / 100) / (fNumber * fNumber)
    }

    /// Which frame the merge should anchor to: the one whose exposure sits in the middle.
    static func referenceIndex(for urls: [URL]) -> Int {
        let exposures = urls.map { relativeExposure(of: $0) ?? 1 }
        let sorted = exposures.sorted()
        let median = sorted[sorted.count / 2]
        return exposures.firstIndex(of: median) ?? 0
    }

    private static func writeTIFF(_ pixels: [UInt16], width: Int, height: Int, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw RenderError.writeFailed }
        var mutable = pixels
        let byteCount = width * height * 3 * MemoryLayout<UInt16>.size
        guard let provider = CGDataProvider(data: Data(bytes: &mutable, count: byteCount) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16,
                                  bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                                            .union(.byteOrder16Little),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw RenderError.writeFailed }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw RenderError.writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.writeFailed }
    }
}
