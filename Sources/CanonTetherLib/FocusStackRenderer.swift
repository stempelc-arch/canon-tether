import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CanonTetherCore

/// Renders a focus bracket into one merged full-resolution image.
///
/// The hard constraint here is memory, not maths. A 1D X Mark II frame is 20 MP; as interleaved
/// RGB floats that is ~240 MB, and the merge needs every frame of the bracket resident *plus* a
/// Laplacian pyramid for each (~1.3× again). A ten-frame stack done naively asks for ~6 GB and
/// either thrashes or is killed. So the pipeline is:
///
/// 1. **Decode once, to disk.** Each frame is decoded at full resolution into a flat 16-bit scratch
///    file. Decoding a CR2 is the expensive step and this way it happens exactly once per frame,
///    rather than once per frame per tile.
/// 2. **Align on thumbnails.** Registration information lives in coarse structure (see
///    `FocusStackAlign`), so the transforms are estimated from small previews and then rescaled to
///    full resolution. This costs nothing and is more robust than matching at full size.
/// 3. **Merge in overlapped horizontal strips.** Only a band of rows from each frame is resident at
///    once. Strips overlap generously and only their interiors are kept, because pyramid blending
///    near a strip edge sees a clamped boundary that isn't really there.
///
/// Note on colour: per CLAUDE.md, ImageIO's RAW decode clamps to sRGB, so the merged output is an
/// sRGB-gamut 16-bit TIFF. That is the ceiling of this decode path, not a choice made here.
public enum FocusStackRenderer {
    /// Rows per strip. Chosen so a ten-frame bracket's resident set stays a few hundred MB at
    /// 1DX II resolution: 10 frames × 5472 px × (512 + 2×192) rows × 3 ch × 4 B ≈ 590 MB peak.
    /// Rows of final image each strip produces.
    ///
    /// 1024 rather than 512: every strip also processes `stripOverlap` rows either side and throws
    /// them away, so a 512-row strip does 896 rows of work for 512 rows of result — 1.75× — while a
    /// 1024-row strip does 1408 for 1024, or 1.375×. Measured on a 24-frame bracket that is 80s of
    /// strip time against 59s, for 2% more peak memory, with byte-identical output.
    static let stripRows = 1024

    /// Rows of overlap on each side of a strip, discarded from the result.
    ///
    /// This must exceed the reach of the pyramid blending, or a seam appears at every strip
    /// boundary. With `pyramidLevels` levels the coarsest band's kernel spans roughly
    /// `2^levels` pixels, so the overlap is sized from that rather than picked by feel.
    static let stripOverlap = 192

    /// Pyramid depth used per strip. Capped below what a full frame would support: a strip is only
    /// ~900 rows tall including overlap, and levels coarser than the strip itself carry no
    /// information while widening the overlap needed to hide them.
    static let pyramidLevels = 6

    /// Long edge of the previews alignment is estimated from.
    static let alignmentEdge = 640

    /// What a finished render produced.
    public struct Render {
        public let outputURL: URL
        public let coverage: CoverageMap
        public let critique: FocusStackCritique
        public let alignments: [FocusStackAlign.FrameAlignment]
        public let sourceCount: Int
        /// True when the source frames are the same picture plus noise — see
        /// `FocusStackDiagnostics`. The merge still runs and still produces a file; this is what
        /// lets the app say *why* it looks unchanged.
        public let framesAreStatic: Bool

        /// Frames whose alignment couldn't be trusted — the honest caveat to show alongside the
        /// result, since those frames were merged at their best guess rather than a verified fit.
        public var untrustedFrames: [Int] {
            alignments.enumerated().filter { !$0.element.isTrusted }.map(\.offset)
        }
    }

    public enum RenderError: Error, LocalizedError {
        case needsTwoFrames
        case decodeFailed(URL)
        case sizeMismatch
        case writeFailed(URL)

        public var errorDescription: String? {
            switch self {
            case .needsTwoFrames:
                return "A focus stack needs at least two frames."
            case .decodeFailed(let url):
                return "Couldn't read \(url.lastPathComponent)."
            case .sizeMismatch:
                return "These frames aren't all the same size — a stack has to be one bracket from one camera."
            case .writeFailed(let url):
                return "Couldn't write the merged image to \(url.lastPathComponent)."
            }
        }
    }

    /// Merges `urls` (in focus order) and writes the result next to them.
    ///
    /// Runs off the main actor; `progress` is called with 0–1 and a short phase label and may be
    /// invoked from a background thread, so callers must hop to the main actor themselves.
    public static func render(
        urls: [URL],
        outputURL: URL? = nil,
        subjectRegion: (x: Double, y: Double, width: Double, height: Double)? = nil,
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) throws -> Render {
        guard urls.count >= 2 else { throw RenderError.needsTwoFrames }

        // Phase timings. The merge turned out to be the *largest* phase of a stack — 5.6s a frame
        // against the bracket's 3.7 — and which part of it owns that was not recorded anywhere.
        let started = Date()
        var mark = started
        func phase(_ name: String) {
            let now = Date()
            FileHandle.appendLog(String(format: "merge: %@ %.1fs", name, now.timeIntervalSince(mark)))
            mark = now
        }

        // 1. Alignment, from small previews.
        progress(0.02, "Aligning frames…")
        // Decoded in parallel: 24 independent JPEG decodes, and they were costing 16s in a row.
        var previewSlots = [StackImage?](repeating: nil, count: urls.count)
        previewSlots.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                slots[index] = loadImage(urls[index], maxPixel: alignmentEdge)
            }
        }
        var previews: [StackImage] = []
        for (index, slot) in previewSlots.enumerated() {
            guard let slot else { throw RenderError.decodeFailed(urls[index]) }
            previews.append(slot)
        }
        guard previews.allSatisfy({ $0.matchesShape(of: previews[0]) }) else {
            throw RenderError.sizeMismatch
        }
        let previewAlignments = FocusStackAlign.align(previews)
        // Checked on the previews, before any of the expensive work: if the lens never moved, that
        // is the headline fact about this stack and it must not be buried under a clean-looking
        // merge of N identical frames.
        let framesAreStatic = FocusStackDiagnostics.framesAreStatic(previews)

        phase("align")

        // 2. Decode every frame to a scratch file at full resolution.
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        // Also in parallel. Each frame decodes to its own scratch file and shares nothing, so the
        // only coordination is collecting the results and the first error.
        //
        // Concurrency is capped rather than left to `concurrentPerform`'s default: a full-
        // resolution decode holds a 20 MP RGBA16 CGImage plus its packed copy, so letting every
        // core decode at once multiplies that by the core count for no gain — this is bounded by
        // ImageIO and the disk write, not by arithmetic.
        var planeSlots = [ScratchPlane?](repeating: nil, count: urls.count)
        var sizeSlots = [(width: Int, height: Int)?](repeating: nil, count: urls.count)
        var decodeError: Error?
        let decodeLock = NSLock()
        var decoded = 0
        let decodeWorkers = min(4, urls.count)
        planeSlots.withUnsafeMutableBufferPointer { planeBuffer in
            sizeSlots.withUnsafeMutableBufferPointer { sizeBuffer in
                DispatchQueue.concurrentPerform(iterations: decodeWorkers) { worker in
                    var index = worker
                    while index < urls.count {
                        decodeLock.lock()
                        let stop = decodeError != nil
                        decodeLock.unlock()
                        if stop { return }
                        do {
                            guard let cg = loadCGImage(urls[index]) else {
                                throw RenderError.decodeFailed(urls[index])
                            }
                            sizeBuffer[index] = (cg.width, cg.height)
                            planeBuffer[index] = try ScratchPlane(
                                image: cg,
                                url: scratchDirectory.appendingPathComponent("frame-\(index).raw"))
                        } catch {
                            decodeLock.lock()
                            decodeError = decodeError ?? error
                            decodeLock.unlock()
                            return
                        }
                        decodeLock.lock()
                        decoded += 1
                        let done = decoded
                        decodeLock.unlock()
                        progress(0.05 + 0.45 * Double(done) / Double(urls.count), "Reading frames…")
                        index += decodeWorkers
                    }
                }
            }
        }
        if let decodeError { throw decodeError }
        var planes: [ScratchPlane] = []
        for (index, slot) in planeSlots.enumerated() {
            guard let slot else { throw RenderError.decodeFailed(urls[index]) }
            planes.append(slot)
        }
        guard let size = sizeSlots.first ?? nil else { throw RenderError.decodeFailed(urls[0]) }
        guard sizeSlots.allSatisfy({ $0?.width == size.width && $0?.height == size.height }) else {
            throw RenderError.sizeMismatch
        }
        phase("decode")

        // Rescale the preview transforms to full resolution. Scale is dimensionless; translation
        // is in pixels and must be multiplied by exactly the factor between the two resolutions.
        let factor = Double(size.width) / Double(previews[0].width)
        let alignments = previewAlignments.map {
            FocusStackAlign.FrameAlignment(transform: $0.transform.scaledToResolution(factor: factor),
                                           correlation: $0.correlation)
        }

        // 3. Strip-wise merge, strips in parallel.
        //
        // Each strip is independent by construction — that is the whole point of the overlap — so
        // the only shared state is the output buffer, and each strip writes a disjoint band of it.
        // Measured, a 5-frame stack took 59 s single-threaded, which is most of the wait between
        // pressing the button and seeing a result.
        var stripRanges: [(start: Int, end: Int)] = []
        var cursor = 0
        while cursor < size.height {
            let end = min(cursor + stripRows, size.height)
            stripRanges.append((cursor, end))
            cursor = end
        }

        var output = [UInt16](repeating: 0, count: size.width * size.height * 3)
        let coverageLock = NSLock()
        var coverageAccumulator: CoverageAccumulator?
        var stripError: Error?
        let progressLock = NSLock()
        var stripsDone = 0

        // Each worker needs its own file handles: `ScratchPlane` seeks, so one shared handle read
        // from several threads would interleave reads and hand back scrambled rows.
        let planeURLs = planes.map(\.url)
        let planeSize = (width: size.width, height: size.height)

        output.withUnsafeMutableBufferPointer { buffer in
            let raw = buffer
            // Leave a core or two for the UI and the live-view decode. Measured, saturating all of
            // them made the feed appear dead during a merge, which is the more visible failure.
            let cores = Swift.max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
            // Bounded by memory as well as by cores.
            //
            // Each worker holds *every frame's* band at once, plus the pyramid the merge builds
            // from them — so the footprint scales with the bracket, and the bracket is chosen by
            // the subject rather than by the machine. Measured on a 24-frame stack: 22.6 GB peak,
            // on a 32 GB Mac. The same stack on a 16 GB machine would swap itself to a standstill
            // or be killed, and nothing in the code noticed how much it was asking for.
            //
            // Half of physical memory is the budget; one worker is always allowed, because
            // finishing slowly beats refusing to finish.
            let bandRows = Swift.min(size.height, stripRows + 2 * stripOverlap)
            let bytesPerWorker = Double(urls.count) * Double(bandRows) * Double(size.width)
                * 3 * 4 * 2.4      // channels x Float x (bands + pyramid + merged)
            let budget = Double(ProcessInfo.processInfo.physicalMemory) * 0.5
            let byMemory = Swift.max(1, Int(budget / Swift.max(bytesPerWorker, 1)))
            let workers = Swift.min(cores, byMemory)
            if workers < cores {
                FileHandle.appendLog(String(format:
                    "merge: %d workers (memory-bound: %.1f GB per worker, %.0f GB budget)",
                    workers, bytesPerWorker / 1_073_741_824, budget / 1_073_741_824))
            }
            let batches = Swift.min(workers, stripRanges.count)
            DispatchQueue.concurrentPerform(iterations: batches) { batch in
                var index = batch
                while index < stripRanges.count {
                    defer { index += batches }
                let strip = stripRanges[index]
                let readStart = max(0, strip.start - stripOverlap)
                let readEnd = min(size.height, strip.end + stripOverlap)
                do {
                    var frames: [StackImage] = []
                    frames.reserveCapacity(planeURLs.count)
                    for (url, alignment) in zip(planeURLs, alignments) {
                        let plane = try ScratchPlane(reopening: url,
                                                     width: planeSize.width, height: planeSize.height)
                        frames.append(try plane.readWarpedBand(rows: readStart..<readEnd,
                                                               fullHeight: planeSize.height,
                                                               transform: alignment.transform))
                    }
                    let merged = try FocusStackMerge.merge(frames, levels: pyramidLevels)
                    writeStrip(merged.image, into: raw,
                               imageWidth: planeSize.width,
                               keep: strip.start..<strip.end,
                               bandStart: readStart)
                    coverageLock.lock()
                    if coverageAccumulator == nil {
                        coverageAccumulator = CoverageAccumulator(sourceCount: planeURLs.count,
                                                                  width: merged.coverage.width,
                                                                  bandRows: readEnd - readStart,
                                                                  coverageRows: merged.coverage.height)
                    }
                    coverageAccumulator?.add(merged.coverage,
                                             bandRows: readStart..<readEnd,
                                             keepRows: strip.start..<strip.end)
                    coverageLock.unlock()
                } catch {
                    coverageLock.lock(); stripError = stripError ?? error; coverageLock.unlock()
                }
                progressLock.lock()
                stripsDone += 1
                let fraction = 0.5 + 0.45 * Double(stripsDone) / Double(stripRanges.count)
                progressLock.unlock()
                // Percent, not "x of y".
                //
                // This counted *strips* — horizontal bands of the image — directly after a status
                // line counting frames, so "Merging 1 of 4" right after "21 frames" read as though
                // the merge had thrown 17 frames away. Strip count is an implementation detail of
                // how the image is divided for memory, and halving it (512 → 1024 rows) changed
                // this number for reasons that have nothing to do with the photographer's stack.
                progress(fraction, "Merging \(Int((Double(stripsDone) / Double(stripRanges.count)) * 100))%…")
                }
            }
        }
        if let stripError { throw stripError }
        phase("strips")

        // 4. Write the merged image.
        progress(0.97, "Writing merged image…")
        let destination = outputURL ?? defaultOutputURL(for: urls[0])
        try writeTIFF(output, width: size.width, height: size.height, to: destination)
        phase("write")
        FileHandle.appendLog(String(format: "merge: total %.1fs for %d frames",
                                    Date().timeIntervalSince(started), urls.count))

        let coverage = coverageAccumulator?.map()
            ?? CoverageMap(width: 1, height: 1, sourceCount: urls.count, winner: [0], confidence: [0])
        progress(1, "Done.")
        return Render(outputURL: destination,
                      coverage: coverage,
                      critique: FocusStackCritique(coverage: coverage, region: subjectRegion),
                      alignments: alignments,
                      sourceCount: urls.count,
                      framesAreStatic: framesAreStatic)
    }

    /// `<first frame>-stack.tif`, so a merged result sorts next to the bracket that made it.
    public static func defaultOutputURL(for first: URL) -> URL {
        first.deletingLastPathComponent()
            .appendingPathComponent(first.deletingPathExtension().lastPathComponent + "-stack.tif")
    }

    // MARK: - Strip assembly

    /// Copies the keep-region of a merged band into the output buffer, converting float to 16-bit.
    static func writeStrip(_ band: StackImage, into output: UnsafeMutableBufferPointer<UInt16>,
                           imageWidth: Int, keep: Range<Int>, bandStart: Int) {
        for y in keep {
            let bandRow = y - bandStart
            guard bandRow >= 0, bandRow < band.height else { continue }
            for x in 0..<imageWidth {
                let source = (bandRow * band.width + x) * band.channels
                let destination = (y * imageWidth + x) * 3
                for c in 0..<3 {
                    let v = band.data[source + c]
                    // Clamp on the way out: the merge is a weighted sum of band-pass coefficients
                    // and can legitimately overshoot slightly at a high-contrast focus boundary.
                    output[destination + c] = UInt16(min(max(v, 0), 1) * 65535)
                }
            }
        }
    }

    /// Stitches each strip's coverage map into one full-frame map. Coverage comes off a pooled
    /// pyramid level, so it is a fraction of full resolution; the accumulator tracks that scale.
    struct CoverageAccumulator {
        let sourceCount: Int
        let width: Int
        /// Image rows per coverage row. Derived from the first strip's actual band height rather
        /// than assumed: `FocusStackMerge` pools the coverage map down by a fixed factor, but the
        /// **first and last strips are shorter than the nominal band** (they have overlap on one
        /// side only, and the last is truncated by the image edge). Assuming the nominal height
        /// mis-scaled every row of the map, sliding the whole thing against the image.
        let poolFactor: Double
        var rows: [Int: (winner: [Int], confidence: [Float])] = [:]

        init(sourceCount: Int, width: Int, bandRows: Int, coverageRows: Int) {
            self.sourceCount = sourceCount
            self.width = width
            self.poolFactor = coverageRows > 0 ? Double(bandRows) / Double(coverageRows) : 1
        }

        mutating func add(_ map: CoverageMap, bandRows: Range<Int>, keepRows: Range<Int>) {
            for y in keepRows {
                let local = Int(Double(y - bandRows.lowerBound) / poolFactor)
                guard local >= 0, local < map.height else { continue }
                let start = local * map.width
                guard start + map.width <= map.winner.count else { continue }
                rows[Int(Double(y) / poolFactor)] = (
                    Array(map.winner[start..<(start + map.width)]),
                    Array(map.confidence[start..<(start + map.width)])
                )
            }
        }

        func map() -> CoverageMap {
            let ordered = rows.keys.sorted()
            var winner: [Int] = [], confidence: [Float] = []
            winner.reserveCapacity(ordered.count * width)
            confidence.reserveCapacity(ordered.count * width)
            for key in ordered {
                winner.append(contentsOf: rows[key]!.winner)
                confidence.append(contentsOf: rows[key]!.confidence)
            }
            return CoverageMap(width: width, height: ordered.count, sourceCount: sourceCount,
                               winner: winner, confidence: confidence)
        }
    }

    // MARK: - Image I/O

    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Full-resolution decode. Deliberately 16-bit integer, not float: CLAUDE.md records that a
    /// full-size decode into a **float** context returns garbage on these files, and 16 bits is
    /// ample for a merge whose inputs are 14-bit sensor data anyway.
    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    /// Small preview for alignment, via the same thumbnail path the scopes use.
    static func loadImage(_ url: URL, maxPixel: Int) -> StackImage? {
        // See `ImageThumbnail`. This one matters twice over: alignment is estimated from these
        // previews, and so is the static-bracket check — both were running on a 160×120 EXIF
        // thumbnail for JPEG brackets.
        guard let cg = ImageThumbnail.load(url, maxPixel: maxPixel) else { return nil }
        return ScratchPlane.floatImage(from: cg)
    }

    static func writeTIFF(_ pixels: [UInt16], width: Int, height: Int, to url: URL) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw RenderError.writeFailed(url)
        }
        var mutable = pixels
        let byteCount = width * height * 3 * MemoryLayout<UInt16>.size
        guard let provider = CGDataProvider(data: Data(bytes: &mutable, count: byteCount) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 16,
                                  bitsPerPixel: 48,
                                  bytesPerRow: width * 3 * MemoryLayout<UInt16>.size,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                                      .union(.byteOrder16Little),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw RenderError.writeFailed(url)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw RenderError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.writeFailed(url) }
    }
}

/// One decoded frame, parked on disk as flat 16-bit RGB so only the rows a strip needs are ever
/// resident. Reads come back already warped by the frame's alignment transform, because warping
/// during the read avoids materialising a second full-size copy of the band.
struct ScratchPlane {
    let url: URL
    let width: Int
    let height: Int
    private let handle: FileHandle

    static let channels = 3
    var bytesPerRow: Int { width * ScratchPlane.channels * MemoryLayout<UInt16>.size }

    /// Reopens an already-written scratch file with its **own** file handle.
    ///
    /// Required for parallel strips: `readWarpedBand` seeks, so sharing one handle across threads
    /// interleaves seeks and reads and returns scrambled rows.
    init(reopening url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FocusStackRenderer.RenderError.decodeFailed(url)
        }
        self.handle = handle
    }

    init(image: CGImage, url: URL) throws {
        self.url = url
        self.width = image.width
        self.height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FocusStackRenderer.RenderError.decodeFailed(url)
        }
        // CoreGraphics has no 16-bit-per-component context *without* an alpha channel — asking for
        // one returns nil and the decode silently fails. So draw into RGBA16 (`noneSkipLast`) and
        // pack down to the 3-channel layout the scratch file stores, rather than carrying a fourth
        // channel of padding through every strip read for the whole merge.
        let pixelCount = image.width * image.height
        var rgba = [UInt16](repeating: 0, count: pixelCount * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 16,
                bytesPerRow: image.width * 4 * MemoryLayout<UInt16>.size,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                    .union(.byteOrder16Little).rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw FocusStackRenderer.RenderError.decodeFailed(url) }
        var buffer = [UInt16](repeating: 0, count: pixelCount * ScratchPlane.channels)
        for i in 0..<pixelCount {
            buffer[i * 3] = rgba[i * 4]
            buffer[i * 3 + 1] = rgba[i * 4 + 1]
            buffer[i * 3 + 2] = rgba[i * 4 + 2]
        }
        let data = buffer.withUnsafeBytes { Data($0) }
        try data.write(to: url)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FocusStackRenderer.RenderError.decodeFailed(url)
        }
        self.handle = handle
    }

    /// Reads the rows of this frame that the given output band needs, warped into the band's own
    /// coordinates. The rows actually read are the *source* rows the transform reaches for, which
    /// for a centre-anchored scale is not the same span as the destination rows.
    func readWarpedBand(rows: Range<Int>, fullHeight: Int, transform: SimilarityTransform) throws -> StackImage {
        let centerX = Double(width - 1) / 2, centerY = Double(fullHeight - 1) / 2
        let topSource = transform.source(x: 0, y: Double(rows.lowerBound), centerX: centerX, centerY: centerY).y
        let bottomSource = transform.source(x: 0, y: Double(rows.upperBound - 1), centerX: centerX, centerY: centerY).y
        // One row of margin each side for the bilinear tap.
        let firstRow = max(0, Int(min(topSource, bottomSource).rounded(.down)) - 1)
        let lastRow = min(height - 1, Int(max(topSource, bottomSource).rounded(.up)) + 1)
        guard firstRow <= lastRow else {
            return StackImage(width: width, height: rows.count, channels: ScratchPlane.channels)
        }

        let sourceRows = lastRow - firstRow + 1
        try handle.seek(toOffset: UInt64(firstRow * bytesPerRow))
        guard let data = try handle.read(upToCount: sourceRows * bytesPerRow),
              data.count == sourceRows * bytesPerRow else {
            throw FocusStackRenderer.RenderError.decodeFailed(url)
        }
        var source = StackImage(width: width, height: sourceRows, channels: ScratchPlane.channels)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: UInt16.self)
            for i in 0..<samples.count { source.data[i] = Float(samples[i]) / 65535 }
        }

        // Warp straight into band coordinates: destination row r of the band is image row
        // rows.lowerBound + r, whose source row is offset by firstRow within what we just read.
        var out = StackImage(width: width, height: rows.count, channels: ScratchPlane.channels)
        let c = ScratchPlane.channels
        for r in 0..<rows.count {
            let destY = Double(rows.lowerBound + r)
            for x in 0..<width {
                let p = transform.source(x: Double(x), y: destY, centerX: centerX, centerY: centerY)
                let sx = min(max(p.x, 0), Double(width - 1))
                let sy = min(max(p.y - Double(firstRow), 0), Double(sourceRows - 1))
                let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, sourceRows - 1)
                let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                let i00 = (y0 * width + x0) * c, i10 = (y0 * width + x1) * c
                let i01 = (y1 * width + x0) * c, i11 = (y1 * width + x1) * c
                let d = (r * width + x) * c
                for ch in 0..<c {
                    let top = source.data[i00 + ch] * (1 - fx) + source.data[i10 + ch] * fx
                    let bottom = source.data[i01 + ch] * (1 - fx) + source.data[i11 + ch] * fx
                    out.data[d + ch] = top * (1 - fy) + bottom * fy
                }
            }
        }
        return out
    }

    /// Draws a `CGImage` into a float `StackImage` — the small-preview path, where a whole-image
    /// float buffer is affordable.
    static func floatImage(from image: CGImage) -> StackImage? {
        let w = image.width, h = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var data = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            data[i * 3] = Float(bytes[i * 4]) / 255
            data[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
            data[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
        }
        return StackImage(width: w, height: h, channels: 3, data: data)
    }
}
