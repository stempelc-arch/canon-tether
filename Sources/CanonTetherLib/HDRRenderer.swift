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
                       look: HDRLook = HDRSettings.load(),
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
            // Apple's own rendering turned off: this is a measurement, not a picture yet.
            filter.boostAmount = 0
            filter.isGamutMappingEnabled = false
            guard let image = filter.outputImage else { throw RenderError.decodeFailed(url) }
            images.append(image)
            exposures.append(relativeExposure(of: url) ?? 1)
        }
        guard images.allSatisfy({ $0.extent.size == images[0].extent.size }) else {
            throw RenderError.sizeMismatch
        }

        // Learn the rendering from the reference frame itself.
        //
        // Merging happens in linear light, but linear encoded straight to sRGB is not a photograph:
        // no toe, no colour rendering — measured against a normal conversion, shadows came out more
        // than twice as bright and the blue channel three times too high. Rendering the *same*
        // frame both ways and building the transfer between them means the merged picture matches
        // an ordinary conversion of the metered exposure, and differs only where the bracket
        // actually added something.
        var toneCurve = try learnedToneCurve(from: urls[min(max(referenceIndex, 0), urls.count - 1)],
                                             context: context, linearSpace: linearSpace)
        toneCurve.look = look
        // How bright the scene actually gets, measured on a small merge before committing to the
        // full one. The compression is anchored to this so the brightest recovered detail lands at
        // white; guessing it from the darkest frame's exposure instead would anchor to the range
        // the bracket *could* have reached rather than the range the scene actually used, and throw
        // away contrast on every ordinary subject.
        let measured = try sceneWhite(images: images, exposures: exposures,
                                      reference: min(max(referenceIndex, 0), urls.count - 1),
                                      context: context, linearSpace: linearSpace)
        // Expose the merged scene, rather than inheriting the metered frame's exposure.
        var keyGain = targetKey / measured.key
        let limit = powf(2, look.exposureLimit)
        keyGain = Swift.min(Swift.max(keyGain, 1 / limit), limit)
        toneCurve.sceneWhite = measured.white * keyGain
        FileHandle.appendLog(String(format:
            "hdr: scene key %.4f -> exposing %+.2f stops; white %.2f (%.2f stops over)",
            measured.key, log2(Double(keyGain)), toneCurve.sceneWhite,
            log2(Double(max(toneCurve.sceneWhite, 1)))))

        let extent = images[0].extent
        let width = Int(extent.width), height = Int(extent.height)
        let channels = 3
        var output = [UInt16](repeating: 0, count: width * height * channels)
        var peakRadiance = [Float]()

        let reference = min(max(referenceIndex, 0), urls.count - 1)
        var rowBuffer = [Float](repeating: 0, count: width * stripRows * 4)

        var row = 0
        while row < height {
            let rows = min(stripRows, height - row)
            let bandRect = CGRect(x: extent.minX, y: extent.minY + CGFloat(height - row - rows),
                                  width: extent.width, height: CGFloat(rows))

            // One frame's strip at a time, straight into a float buffer — no scratch files, because
            // only a few strips are ever resident.
            var frames: [HDRMerge.Frame] = []
            for (index, image) in images.enumerated() {
                rowBuffer.withUnsafeMutableBytes { raw in
                    context.render(image, toBitmap: raw.baseAddress!,
                                   rowBytes: width * 4 * MemoryLayout<Float>.size,
                                   bounds: bandRect, format: .RGBAf, colorSpace: linearSpace)
                }
                // No flip. Core Image's origin is bottom-left, so `bandRect` is computed from the
                // bottom, but `render(toBitmap:)` fills the buffer top-down within those bounds —
                // the two conventions cancel and the strip lands the right way up.
                //
                // Worth stating because the obvious "CI is bottom-left, so flip it" correction is
                // wrong here, and it was reached honestly: the first test merged three CR2s that
                // turned out to be *different scenes*, whose garbage output looked exactly like a
                // coordinate bug. Verify a pipeline on inputs you have actually looked at.
                var strip = StackImage(width: width, height: rows, channels: channels)
                for pixel in 0..<(width * rows) {
                    strip.data[pixel * 3 + 0] = rowBuffer[pixel * 4 + 0]
                    strip.data[pixel * 3 + 1] = rowBuffer[pixel * 4 + 1]
                    strip.data[pixel * 3 + 2] = rowBuffer[pixel * 4 + 2]
                }
                frames.append(HDRMerge.Frame(image: strip, exposure: exposures[index]))
            }

            var radiance = try HDRMerge.radiance(from: frames, reference: reference)
            peakRadiance.append(contentsOf: radiance.data.filter { $0 > 1 })
            // Apply the scene exposure before the curve, in linear light — it is an exposure
            // change, and exposure belongs in linear.
            if keyGain != 1 {
                for i in 0..<radiance.data.count { radiance.data[i] *= keyGain }
            }
            let shown = toneCurve.render(radiance)
            for i in 0..<(width * rows * channels) {
                output[row * width * channels + i] = UInt16(min(max(shown.data[i], 0), 1) * 65535)
            }

            row += rows
            progress(0.05 + 0.9 * Double(row) / Double(height), "Merging \(Int(Double(row) / Double(height) * 100))%…")
        }

        progress(0.97, "Writing merged image…")
        try writeTIFF(output, width: width, height: height, to: outputURL)

        var recovered = StackImage(width: max(peakRadiance.count, 1), height: 1, channels: 1)
        if !peakRadiance.isEmpty { recovered.data = peakRadiance }
        progress(1, "Done.")
        return Render(outputURL: outputURL,
                      sourceCount: urls.count,
                      recoveredStops: peakRadiance.isEmpty ? 0 : HDRMerge.recoveredStops(recovered))
    }

    /// The brightest radiance worth rendering as white, from a low-resolution merge.
    ///
    /// A high percentile rather than the maximum: a single specular glint would otherwise set the
    /// anchor and darken the entire picture to accommodate one pixel nobody looks at.
    private static func sceneWhite(images: [CIImage],
                                   exposures: [Double],
                                   reference: Int,
                                   context: CIContext,
                                   linearSpace: CGColorSpace) throws -> (white: Float, key: Float) {
        let edge: CGFloat = 600
        let scale = edge / images[0].extent.width
        var frames: [HDRMerge.Frame] = []
        for (index, image) in images.enumerated() {
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let w = Int(small.extent.width), h = Int(small.extent.height)
            guard w > 0, h > 0 else { throw RenderError.decodeFailed(URL(fileURLWithPath: "/"))}
            var buffer = [Float](repeating: 0, count: w * h * 4)
            buffer.withUnsafeMutableBytes { raw in
                context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                               bounds: small.extent, format: .RGBAf, colorSpace: linearSpace)
            }
            var strip = StackImage(width: w, height: h, channels: 3)
            for pixel in 0..<(w * h) {
                strip.data[pixel * 3 + 0] = buffer[pixel * 4 + 0]
                strip.data[pixel * 3 + 1] = buffer[pixel * 4 + 1]
                strip.data[pixel * 3 + 2] = buffer[pixel * 4 + 2]
            }
            frames.append(HDRMerge.Frame(image: strip, exposure: exposures[index]))
        }
        let radiance = try HDRMerge.radiance(from: frames, reference: reference)
        var values = radiance.data.filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return (white: 1, key: 1) }
        values.sort()
        let percentile = values[Int(Double(values.count) * 0.999)]
        let median = values[values.count / 2]
        // Never below 1: a scene that fitted in one exposure must render exactly as that exposure
        // did, with no compression at all.
        return (white: Swift.max(percentile, 1), key: Swift.max(median, 1e-6))
    }

    /// Linear level the merged scene's middle is placed at.
    ///
    /// Middle grey. **The merge is exposed for the result, not for the metered frame.** Anchoring
    /// the output to the metered exposure was the original design and it is why an HDR of a dark
    /// room with a bright window came back looking exactly like the dark room: the extra exposures
    /// recovered the window, and the shadows they also recorded were rendered at the brightness the
    /// *metered* frame gave them, which is to say black. The whole point of shooting a bracket is
    /// that no single frame's exposure is right for the scene.
    static let targetKey: Float = 0.18

    /// Most the result may be brightened or darkened relative to the metered frame, in stops.
    ///
    /// Bounded because the key is a median and a median can be misled — a frame that is mostly dark
    /// wall has a low median and does not want three stops of lift. Beyond this the photographer's
    /// own metering is the better guide.
    static let keyAdjustmentLimit: Float = 3

    /// Samples the reference frame rendered two ways and builds the transfer between them.
    ///
    /// Done at low resolution on purpose: the curve is a statistical summary over millions of
    /// samples either way, and a full-size second decode would double the slowest part of the merge
    /// for no additional accuracy.
    private static func learnedToneCurve(from url: URL,
                                         context: CIContext,
                                         linearSpace: CGColorSpace) throws -> HDRToneCurve {
        guard let linearFilter = CIRAWFilter(imageURL: url),
              let renderedFilter = CIRAWFilter(imageURL: url) else { throw RenderError.decodeFailed(url) }
        linearFilter.boostAmount = 0
        linearFilter.isGamutMappingEnabled = false
        // The other one left entirely alone — this is the rendering the photographer would get from
        // any ordinary conversion of this file, and matching it is the whole point.
        guard let linearImage = linearFilter.outputImage,
              let renderedImage = renderedFilter.outputImage else { throw RenderError.decodeFailed(url) }

        let edge: CGFloat = 1000
        let scale = edge / linearImage.extent.width
        let smallLinear = linearImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let smallRendered = renderedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(smallLinear.extent.width), h = Int(smallLinear.extent.height)
        guard w > 0, h > 0 else { throw RenderError.decodeFailed(url) }

        var linearPixels = [Float](repeating: 0, count: w * h * 4)
        var renderedPixels = [Float](repeating: 0, count: w * h * 4)
        linearPixels.withUnsafeMutableBytes { raw in
            context.render(smallLinear, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: smallLinear.extent, format: .RGBAf, colorSpace: linearSpace)
        }
        // The rendered side is read in sRGB, which is what "as normally converted" means.
        let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!
        renderedPixels.withUnsafeMutableBytes { raw in
            context.render(smallRendered, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: smallRendered.extent, format: .RGBAf, colorSpace: displaySpace)
        }

        // Drop alpha, keeping the two sides aligned pixel for pixel.
        var linear = [Float](); linear.reserveCapacity(w * h * 3)
        var rendered = [Float](); rendered.reserveCapacity(w * h * 3)
        for pixel in 0..<(w * h) {
            for channel in 0..<3 {
                linear.append(linearPixels[pixel * 4 + channel])
                rendered.append(renderedPixels[pixel * 4 + channel])
            }
        }
        return HDRToneCurve(linear: linear, rendered: rendered, channels: 3)
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
