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

            let radiance = try HDRMerge.radiance(from: frames, reference: reference)
            peakRadiance.append(contentsOf: radiance.data.filter { $0 > 1 })
            let shown = HDRMerge.render(radiance)
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
