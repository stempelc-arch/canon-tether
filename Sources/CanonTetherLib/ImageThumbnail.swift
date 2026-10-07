import Foundation
import ImageIO
import CoreGraphics

/// Loads a downsampled `CGImage` at (close to) a requested size, for any file the app handles.
///
/// Exists because of a trap that silently wrecked image quality app-wide. The obvious ImageIO
/// recipe — `kCGImageSourceCreateThumbnailFromImageIfAbsent` with a `ThumbnailMaxPixelSize` — only
/// *creates* a thumbnail when the file doesn't already have one. A JPEG always has one: the
/// **160×120 EXIF thumbnail**. So ImageIO returns that and ignores the requested size entirely:
///
///     JPEG, asked for 1600px:  IfAbsent -> 160x120     Always -> 1600x1067
///     CR2,  asked for 1600px:  IfAbsent -> 1600x1067   Always -> 1600x1067
///
/// A CR2's embedded preview is big, which is why this never showed while captures were RAW — and
/// why it appeared the moment brackets started shooting JPEG. Every JPEG in the gallery, the client
/// review window and the scopes was a 160×120 image scaled up.
///
/// `FromImageAlways` alone is not the answer either: it forces a full RAW decode, throwing away the
/// embedded-preview speed the rest of the app depends on. So: ask the cheap way, check what came
/// back, and only pay for a full decode when the cheap answer is too small to use.
enum ImageThumbnail {
    /// Fraction of the requested size a cheap thumbnail must reach to be accepted. A little slack
    /// because embedded previews come in fixed sizes and rarely match a request exactly — an
    /// 1120 px preview for a 1600 px request is fine; a 160 px one is not.
    static let acceptableFraction = 0.75

    static func load(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: source, maxPixel: maxPixel)
    }

    static func load(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: source, maxPixel: maxPixel)
    }

    private static func load(source: CGImageSource, maxPixel: Int) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        let cheap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        if let cheap, isBigEnough(cheap, maxPixel: maxPixel) { return cheap }

        // Too small to be what was asked for — decode from the full image instead.
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? cheap
    }

    private static func isBigEnough(_ image: CGImage, maxPixel: Int) -> Bool {
        // The source may simply be smaller than the request; that isn't a failure.
        Double(max(image.width, image.height)) >= Double(maxPixel) * acceptableFraction
    }
}
