import SwiftUI
import ImageIO
import CoreGraphics
import CanonTetherCore

/// Exposure metadata pulled from a capture's embedded EXIF, for the preview overlay.
struct PhotoMetadata: Equatable {
    var aperture: String?     // "f/1.8"
    var shutter: String?      // "1/125"
    var iso: String?          // "ISO 800"
    var whiteBalance: String? // "Daylight · 5200K"
    var focalLength: String?  // "50mm"
    var lens: String?
    var dimensions: String?   // "5472 × 3648"

    var isEmpty: Bool {
        aperture == nil && shutter == nil && iso == nil && whiteBalance == nil
            && focalLength == nil && lens == nil
    }

    static func load(_ url: URL) async -> PhotoMetadata {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: extract(url))
            }
        }
    }

    private static func extract(_ url: URL) -> PhotoMetadata {
        var meta = PhotoMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return meta
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]

        if let f = exif?[kCGImagePropertyExifFNumber] as? Double {
            meta.aperture = f == f.rounded() ? "f/\(Int(f))" : String(format: "f/%.1f", f)
        }
        // t must be strictly positive and finite: malformed EXIF with ExposureTime 0 makes 1/t
        // infinite, and Int(inf) traps — one bad file would crash the app whenever it's shown.
        if let t = exif?[kCGImagePropertyExifExposureTime] as? Double, t > 0, t.isFinite {
            meta.shutter = t >= 1 ? String(format: "%.0f\"", t) : "1/\(Int((1 / t).rounded()))"
        }
        if let isoList = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoList.first {
            meta.iso = "ISO \(iso)"
        }
        // Base EXIF only distinguishes auto from manual white balance; the actual preset lives in
        // Canon's MakerNote. `WhiteBalanceIndex` has no public ImageIO constant, hence the literal.
        let canon = props[kCGImagePropertyMakerCanonDictionary] as? [CFString: Any]
        if let index = canon?["WhiteBalanceIndex" as CFString] as? Int {
            meta.whiteBalance = SettingDisplay.whiteBalanceLabel(makerNoteIndex: index)
        }
        if meta.whiteBalance == nil, let wb = exif?[kCGImagePropertyExifWhiteBalance] as? Int {
            meta.whiteBalance = wb == 0 ? "Auto WB" : nil
        }
        if let fl = exif?[kCGImagePropertyExifFocalLength] as? Double {
            meta.focalLength = "\(Int(fl.rounded()))mm"
        }
        meta.lens = (aux?[kCGImagePropertyExifAuxLensModel] as? String)
            ?? (exif?[kCGImagePropertyExifLensModel] as? String)
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            meta.dimensions = "\(w) × \(h)"
        }
        return meta
    }
}

/// A compact, unobtrusive EXIF readout for the bar under the preview.
struct MetadataBar: View {
    let metadata: PhotoMetadata

    var body: some View {
        HStack(spacing: 14) {
            segment("camera.aperture", metadata.aperture)
            segment("clock", metadata.shutter)
            segment("circle.lefthalf.filled", metadata.iso)
            segment("thermometer", metadata.whiteBalance)
            segment("camera.metering.center.weighted", metadata.focalLength)
            if let lens = metadata.lens {
                segment("camera", lens)
            }
        }
    }

    @ViewBuilder
    private func segment(_ symbol: String, _ value: String?) -> some View {
        if let value {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
        }
    }
}
