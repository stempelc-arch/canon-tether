import Foundation
import Combine
import CanonTetherCore

/// Scores each capture for **focus** and **exposure**, and remembers both verdicts *on the file* the
/// way flags are kept — native macOS **Finder tags** (visible/filterable in Finder and Spotlight)
/// plus the exact readings in custom **extended attributes**. No sidecar: the verdicts travel with
/// the photo and come back when a project (capture folder) is reopened, and the cached readings let a
/// revisited shot skip re-analysis.
///
/// Both checks measure the same downsampled grid, so a shot is decoded **once** (via `ScopeSampler`,
/// the ImageIO path the scopes use) and handed to both Foundation-only analysers in Core
/// (`FocusAnalyzer`, `ExposureAnalyzer`). This type is the app-side glue: sample, evaluate, publish,
/// persist.
@MainActor
final class ShotAnalysisStore: ObservableObject {
    /// Focus verdict per capture, driving the focus badge. Populated lazily as shots are shown/scrolled.
    @Published private(set) var focus: [URL: FocusResult] = [:]
    /// Exposure verdict per capture, driving the exposure badge.
    @Published private(set) var exposure: [URL: ExposureResult] = [:]

    // MARK: - Preferences
    //
    // The sharp/clip cut-offs used to be photographer-adjustable sliders. That asked the user to
    // dial in a number with no ground truth to check it against, and a slider set wrong is *less*
    // reliable than a fixed, deliberately-calibrated value — so the checks now only expose an
    // on/off switch per CLAUDE.md's ExposureGrid precedent (detect, don't ask the user to tune).
    // The thresholds themselves stay fixed constants, tunable in code if real-camera calibration
    // ever calls for it, but never a runtime dial.

    static let focusEnabledKey = "focusCheckEnabled"
    static let exposureEnabledKey = "exposureCheckEnabled"

    /// Sharpness score (0–100) at/above which a shot reads as sharp. Calibrated 2026-08-13 against
    /// ~1,660 real 1DX II files in `Aug 13 Tests/` (a dedicated focus-check set plus a full client
    /// stills session): the score is a *relative* sharpness-vs-surroundings read (see
    /// `FocusAnalyzer`'s doc comment), not an absolute one, so it runs far lower than intuition
    /// suggests on ordinary photography — a plain studio backdrop or a smoke/gel-lit portrait
    /// dilutes or dims the gradient the metric measures even when the subject is crisply in focus.
    /// The old threshold (60) was derived without real files and would have flagged the *majority*
    /// of a genuinely well-shot session as soft (real-session median score was 33, p90 was 56).
    /// Visually checked dozens of files across the score range: everything below ~10 was
    /// unambiguously soft or too dark to judge; everything from the mid-20s up, including plenty in
    /// the 25–40 band, was visibly sharp on inspection. 25 sits just above that gap.
    static let focusThreshold = 25
    /// The soft band sits a fixed gap below the sharp cut-off; everything between is "borderline".
    private static let focusSoftGap = 15
    static var focusSoftThreshold: Int { max(focusThreshold - focusSoftGap, 5) }

    /// Fraction of the frame [0, 1] that may blow out before exposure reads as overexposed.
    /// Calibrated 2026-08-13 against the same real session as the focus threshold: the old single
    /// 5% limit shared by both highlights and shadows let visibly blown-out fabric/skin through as
    /// "good" — real examples (`IMG_1117`, `IMG_1123`, `IMG_1473` in that session) had only 1.7–3.3%
    /// highlight clip yet showed clearly flat, textureless blown-out shirts, because a bust portrait
    /// against a dark backdrop needs only a small fraction of blown subject pixels to look wrong.
    /// 99% of real shots in that session had under ~1.8% highlight clip, so 2% sits just above the
    /// normal noise floor while catching the blown examples found by inspection.
    static let exposureHighlightClipLimit = 0.02
    /// Shadow tolerance stays looser than highlight: crushed blacks from a dark/moody backdrop are
    /// often the deliberate look (over half of the same real session sat above 2% shadow clip, most
    /// of it clearly intentional low-key lighting), where blown highlights on the subject never are.
    static let exposureShadowClipLimit = 0.05
    /// Fraction of the frame that may sit in the near-white band (see `ExposureAnalyzer.nearWhiteLevel`)
    /// before exposure reads as overexposed, independent of hard clipping. Added 2026-08-13 after a
    /// dedicated exposure-bracket test set (`Aug 13 Tests/FIlter Tests/`) showed the hard-clip-only
    /// check missing a genuinely blown sky: two shots had 23–25% of the frame at ≥93% luma — a washed-
    /// out, textureless sky — yet under 0.1% at the hard ≥98% cutoff, so `exposureHighlightClipLimit`
    /// alone never saw it. Re-ran the near-white measurement across the full 1,510-file real session:
    /// p99 there was 12.6%, far below the 23–25% in the blown-sky shots, so 10% separates the two
    /// cleanly without flagging normal specular highlights (skin, jewelry, fabric sheen).
    static let exposureNearWhiteLimit = 0.10

    static var focusEnabled: Bool { UserDefaults.standard.object(forKey: focusEnabledKey) as? Bool ?? true }
    static var exposureEnabled: Bool { UserDefaults.standard.object(forKey: exposureEnabledKey) as? Bool ?? true }

    /// Long edge the photo is decoded to for both reads. Larger than the scopes' sample: focus lives
    /// in the high-frequency detail a heavier downsample would smear away, and the extra resolution
    /// only sharpens the exposure histogram.
    private static let sampleSize = 1600

    private static let focusScoreXattr = "com.canontether.focusScore"
    private static let exposureXattr = "com.canontether.exposure"
    private static let sharpTag = "Sharp", softTag = "Soft"
    private static let overTag = "Overexposed", underTag = "Underexposed"

    // MARK: - Scoring

    /// Analyses `url` for whichever checks are enabled and not already done (or `force` for a
    /// recompute), publishing and persisting the results. Cached readings in the file's xattrs
    /// short-circuit the pixel work; the photo is sampled only if some enabled check still needs it.
    func analyze(_ url: URL, force: Bool = false) {
        Task { await performAnalysis(url, force: force) }
    }

    /// Same checks as `analyze`, but for a whole folder at once (e.g. opening a project or toggling
    /// "Show Good Shots Only"): runs with a small bounded concurrency instead of firing one
    /// unstructured `Task` per photo. An uncapped fan-out over a big session — real sessions here run
    /// into the thousands of files (see the calibration notes above) — starts that many simultaneous
    /// ImageIO decodes at once, which thrashes disk/CPU and floods the main actor with per-photo
    /// published updates; capping keeps decode work steady instead of bursty.
    private static let maxConcurrentAnalyses = 4

    func analyzeAll(_ urls: [URL], force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<Self.maxConcurrentAnalyses {
                guard let url = iterator.next() else { break }
                group.addTask { await self.performAnalysis(url, force: force) }
            }
            while await group.next() != nil {
                if let url = iterator.next() {
                    group.addTask { await self.performAnalysis(url, force: force) }
                }
            }
        }
    }

    private func performAnalysis(_ url: URL, force: Bool) async {
        let wantFocus = Self.focusEnabled && (force || focus[url] == nil)
        let wantExposure = Self.exposureEnabled && (force || exposure[url] == nil)
        guard wantFocus || wantExposure else { return }

        let focusSharp = Self.focusThreshold, focusSoft = Self.focusSoftThreshold
        let highlightLimit = Self.exposureHighlightClipLimit, shadowLimit = Self.exposureShadowClipLimit
        let nearWhiteLimit = Self.exposureNearWhiteLimit

        // Serve from cache where we can, and only decode if something still needs pixels.
        var needFocus = wantFocus, needExposure = wantExposure
        if needFocus, !force, let cached = Self.readFocusScore(url) {
            focus[url] = FocusResult(cachedScore: cached, sharpThreshold: focusSharp, softThreshold: focusSoft)
            needFocus = false
        }
        if needExposure, !force, let cached = Self.readExposure(url) {
            exposure[url] = ExposureResult(cachedHighlightClip: cached.0, shadowClip: cached.1,
                                           nearWhite: cached.2, median: cached.3,
                                           highlightClipLimit: highlightLimit,
                                           shadowClipLimit: shadowLimit, nearWhiteLimit: nearWhiteLimit)
            needExposure = false
        }
        guard needFocus || needExposure else { return }

        guard let frame = await ScopeSampler.sample(url, maxPixel: Self.sampleSize) else { return }

        var focusResult: FocusResult?
        var exposureResult: ExposureResult?
        if needFocus {
            let r = FocusAnalyzer.evaluate(frame, sharpThreshold: focusSharp, softThreshold: focusSoft)
            focus[url] = r
            focusResult = r
        }
        if needExposure {
            let r = ExposureAnalyzer.evaluate(frame, highlightClipLimit: highlightLimit,
                                               shadowClipLimit: shadowLimit, nearWhiteLimit: nearWhiteLimit)
            exposure[url] = r
            exposureResult = r
        }
        await Self.persist(focus: focusResult, exposure: exposureResult, to: url)
    }

    /// Drops every remembered result for a project (capture-folder) switch, mirroring
    /// `ReviewModel.resetForNewProject`. Tags/xattrs stay on the files, so revisiting the folder
    /// reloads them from cache.
    func resetForNewProject() {
        focus = [:]
        exposure = [:]
    }

    // MARK: - Persistence (off the main actor — file I/O)

    nonisolated private static func persist(focus: FocusResult?, exposure: ExposureResult?, to url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                if let focus { writeFocusScore(focus.score, to: url) }
                if let exposure { writeExposure(exposure, to: url) }
                // Tags share one read/write of the file's tag set so focus and exposure don't clobber
                // each other's tag.
                writeTags(focus: focus, exposure: exposure, to: url)
                continuation.resume()
            }
        }
    }

    // MARK: xattr — focus score

    nonisolated private static func readFocusScore(_ url: URL) -> Int? {
        guard let text = readXattr(focusScoreXattr, from: url) else { return nil }
        return Int(text)
    }

    nonisolated private static func writeFocusScore(_ score: Int, to url: URL) {
        writeXattr(focusScoreXattr, "\(score)", to: url)
    }

    // MARK: xattr — exposure readings

    /// Stored as "highlightClip,shadowClip,nearWhite,median" so the verdict can be re-bucketed
    /// without pixels.
    nonisolated private static func readExposure(_ url: URL) -> (Double, Double, Double, Double)? {
        guard let text = readXattr(exposureXattr, from: url) else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    nonisolated private static func writeExposure(_ result: ExposureResult, to url: URL) {
        writeXattr(exposureXattr, "\(result.highlightClip),\(result.shadowClip),\(result.nearWhite),\(result.median)", to: url)
    }

    // MARK: xattr helpers

    nonisolated private static func readXattr(_ name: String, from url: URL) -> String? {
        let path = url.path
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(bytes: buffer[0..<read], encoding: .utf8)
    }

    nonisolated private static func writeXattr(_ name: String, _ value: String, to url: URL) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
    }

    // MARK: Finder tags

    /// Sets the focus (Sharp/Soft) and/or exposure (Overexposed/Underexposed) Finder tags to match
    /// the given verdicts in a single read-modify-write, leaving other tags (e.g. Flagged) untouched.
    /// Only decisive states get a tag — a borderline focus or a good exposure carries none — so
    /// filtering Finder for "Soft" or "Overexposed" surfaces exactly the shots to review.
    nonisolated private static func writeTags(focus: FocusResult?, exposure: ExposureResult?, to url: URL) {
        var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        if let focus {
            tags.removeAll { $0 == sharpTag || $0 == softTag }
            switch focus.verdict {
            case .sharp: tags.append(sharpTag)
            case .soft: tags.append(softTag)
            case .borderline: break
            }
        }
        if let exposure {
            tags.removeAll { $0 == overTag || $0 == underTag }
            switch exposure.verdict {
            case .over: tags.append(overTag)
            case .under: tags.append(underTag)
            case .good: break
            }
        }
        // `URLResourceValues.tagNames` is read-only; NSURL's key setter is the writable path.
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
