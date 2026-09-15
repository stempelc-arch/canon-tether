import Foundation
import CanonTetherCore
import AppKit
import ImageIO

/// Drives focus stacking: probing whether the body can drive focus, shooting the bracket, and
/// merging the result.
///
/// Separate from `CameraViewModel` on purpose. A bracket publishes progress on every frame and
/// every focus nudge, and a merge publishes progress many times a second for a minute or more;
/// putting that on the shared view model would invalidate the toolbar, inspector and filmstrip
/// throughout — the same mistake live view frames caused and that `LiveViewFeed` exists to avoid.
@MainActor
final class FocusStackModel: ObservableObject {
    /// The bracket settings, persisted so a photographer's step size survives a relaunch.
    @Published var plan = FocusStackPlan() {
        didSet {
            if !isLoadingPlan { savePlan() }
            // Counts measured at one nudge size mean nothing at another (see `FocusRange`), so a
            // step-size change retires the marks instead of silently rescaling them into a number
            // that would look authoritative and be wrong.
            if plan.step.magnitude != range.magnitude {
                range = FocusRange(magnitude: plan.step.magnitude)
            }
        }
    }
    /// Set while `loadPlan` writes into `plan`, so merely *reading* stored settings doesn't write
    /// them straight back. Without this a plan the photographer never touched gets persisted on
    /// first launch, which then pins them to whatever the default was at the time — the defaults
    /// can never be improved afterwards.
    private var isLoadingPlan = false

    @Published private(set) var capability: FocusDriveCapability?
    @Published private(set) var isProbing = false

    @Published private(set) var bracketProgress: FocusBracketProgress?
    @Published private(set) var isCapturing = false
    /// The frames the most recent bracket produced, in focus order. These stay out of the gallery
    /// (see `FocusBracketResult`); only the merged image is reviewed.
    @Published private(set) var lastBracket: [URL] = []
    /// The subfolder those frames were grouped into, and where the merged TIFF is written.
    @Published private(set) var lastBracketDirectory: URL?

    /// Tile signatures from the last sweep, keyed by the offset each was taken at. The bracket
    /// positions itself against these rather than trusting a step count — see
    /// `GPhotoSession.seekToOffset`.
    private var sweepReference: [(offset: Int, tiles: [Double])] = []

    @Published private(set) var isMerging = false
    @Published private(set) var mergeFraction: Double = 0
    @Published private(set) var mergeStatus = ""
    @Published private(set) var lastRender: FocusStackRenderer.Render?

    @Published var errorMessage: String?

    /// Called with the merged TIFF once a merge succeeds, so the owner can put it in the gallery.
    /// The merged image is the *only* part of a bracket the photographer reviews, so this is how a
    /// focus stack becomes a capture as far as the rest of the app is concerned.
    var onStackMerged: ((URL) -> Void)?

    // MARK: - Ranging

    /// The counted-nudge range (see `FocusRange`). Recreated whenever the step size changes, since
    /// counts measured at one nudge size mean nothing at another.
    @Published private(set) var range = FocusRange(magnitude: 1)
    /// Overlap *is* the frame spacing (see `FocusOverlap`), so it writes straight through to the
    /// plan — there is no second, separate notion of spacing to drift out of sync with it.
    /// Shoot brackets as JPEG rather than RAW. On by default: a stack is a dozen-plus frames, the
    /// RAW download dominates the per-frame cycle, and the merge is clamped to sRGB by ImageIO's
    /// decode regardless — so RAW costs real time here and buys the merged result very little.
    /// Scoped to the bracket; ordinary single shots keep whatever the camera is set to.
    @Published var captureAsJPEG = true {
        didSet {
            if !isLoadingPlan { UserDefaults.standard.set(captureAsJPEG, forKey: Self.jpegDefaultsKey) }
        }
    }

    private static let jpegDefaultsKey = "focusStackCaptureAsJPEG"

    @Published var overlap = FocusOverlap.default {
        didSet {
            if plan.stepsPerFrame != overlap.stepsPerFrame {
                plan.stepsPerFrame = overlap.stepsPerFrame
            }
        }
    }
    @Published private(set) var isRacking = false
    /// True while waiting for the camera to start producing previews again after a bracket.
    @Published private(set) var isRecoveringLiveView = false
    @Published private(set) var scanProgress: String?
    /// Live-view magnification, 1× / 5× / 10×. Not persisted: a punched-in preview is a thing you
    /// do while marking, not a setting you want to find still applied next session.
    @Published private(set) var zoom = 1
    /// Result of the focus-drive experiment, shown verbatim — it is evidence, not a summary.
    @Published private(set) var diagnosis: String?

    /// The area of the frame the photographer has marked as the subject, in normalised coordinates.
    ///
    /// Without it the scan has to guess, and its guess includes tiles straddling the subject's
    /// outline — which contain background as well as subject, so they report the *wall's* distance
    /// and stretch the range far past the subject. Drawing the box is the only way the app can know
    /// what "the subject" means in a given frame. Keep it inside the outline, not around it.
    @Published var subjectRegion: FocusDepthMap.Region?

    private let session: GPhotoSession
    private let liveView: LiveViewFeed
    private var bracketTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    private var rackTask: Task<Void, Never>?
    private var liveViewRecoveryTask: Task<Void, Never>?
    /// Whether the last recovery attempt got the feed back. If it did not, the end of the merge is
    /// a second, later chance — by then the camera has had considerably longer to settle.
    private var liveViewRestored = true

    /// Asks the owner to turn live view on or off. Ranging needs it: focus drive is a live-view
    /// operation, and the photographer has to *see* what they are marking.
    var onSetLiveView: ((Bool) -> Void)?

    /// Forces the feed to restart even if the app believes it is already running. Used **only**
    /// after a bracket, where the session has stopped it behind the view model's back. Everywhere
    /// else the ordinary, idempotent `onSetLiveView` is correct: making every "ensure it's on" a
    /// stop-then-start turned repeat `onAppear` calls into a feed that thrashed and never settled.
    var onRestartLiveView: (() -> Void)?

    /// Half-width of the sweep taken around the peak the climb finds.
    ///
    /// Raised from 10 after replaying a recorded focus map: a subject spanning 24 focus steps plus
    /// depth of field needs a ~32-step range, which a ±10 window (21 stops) cannot contain — it
    /// returned a truncated range flagged `clipped` every time. ±20 covers it, at ~25 s of sweep.
    static let scanRadius = 20

    /// A suggested range must contain at least this much of the subject to be worth shooting.
    static let minimumSubjectCoverage = 0.5

    // v2: the v1 default stepped *toward* the camera, which is backwards for how stacking is shot
    // (focus the nearest point, walk focus away through the subject) and had already been written
    // to defaults on first launch. A new key retires those entries rather than silently keeping
    // everyone on the wrong direction.
    private static let planDefaultsKey = "focusStackPlan.v2"

    init(session: GPhotoSession, liveView: LiveViewFeed) {
        self.session = session
        self.liveView = liveView
        loadPlan()
        range = FocusRange(magnitude: plan.step.magnitude)
    }

    /// The plan that will actually be shot: derived from the marked range when there is one, so the
    /// frame count always matches the depth the photographer measured rather than a stale number.
    var effectivePlan: FocusStackPlan {
        guard range.isUsable, let span = range.span,
              let end = FocusRangePlanner.startEnd(for: range) else { return plan }
        // Spacing is whatever the depth-of-field measurement set on `plan`; the range supplies the
        // span, and the direction is whichever end focus is already nearest.
        return FocusStackPlan(
            frameCount: FocusRangePlanner.frameCount(span: span, stepsPerFrame: plan.stepsPerFrame),
            step: FocusStep.step(towardCamera: end.towardCamera, magnitude: range.magnitude),
            stepsPerFrame: plan.stepsPerFrame,
            settleSeconds: plan.settleSeconds,
            returnToStart: plan.returnToStart
        )
    }

    var hasRange: Bool { range.isUsable }

    /// True when the marked range needs more frames than a bracket can hold, so it would be
    /// silently truncated — said out loud rather than discovered in the merge.
    var rangeExceedsFrameLimit: Bool {
        guard let span = range.span else { return false }
        return FocusRangePlanner.exceedsFrameLimit(span: span, stepsPerFrame: overlap.stepsPerFrame)
    }

    var isBusy: Bool { isCapturing || isMerging || isRacking }

    // MARK: - Racking

    /// Moves focus by `nudges` (positive = away from the camera) and tracks the cursor, so the app
    /// always knows where it is relative to the marks even though the camera never says.
    func rack(by nudges: Int) {
        guard nudges != 0, !isBusy, rackTask == nil else { return }
        isRacking = true
        onSetLiveView?(true)
        let step = FocusStep.step(towardCamera: nudges < 0, magnitude: range.magnitude)
        let count = abs(nudges)
        let settle = plan.settleSeconds
        let direction = nudges < 0 ? -1 : 1
        rackTask = Task { [session] in
            do {
                // Verified: the cursor must only advance by steps that actually moved the lens.
                // Counting nudges the camera accepted at an end stop is what desynchronises the
                // range from reality and puts the next bracket in the wrong place entirely.
                let (moved, stalled) = try await session.nudgeFocusVerified(
                    step, times: count, settleSeconds: settle)
                self.range.move(by: moved * direction)
                self.scanProgress = stalled
                    ? "Focus is at the end of its travel \(direction < 0 ? "toward" : "away from") the camera."
                    : nil
            } catch let interrupted as FocusDriveInterrupted {
                // Count what did land, or the cursor and the lens part company for good.
                self.range.move(by: interrupted.completed * direction)
                if !interrupted.isCancellation {
                    self.errorMessage = interrupted.localizedDescription
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRacking = false
            self.rackTask = nil
        }
    }

    /// Whether live view was already running when the panel opened, so closing it can put things
    /// back rather than switching off a feed the photographer had up for their own reasons.
    private var liveViewWasOnBeforeEntering = false

    /// Called when the focus-stacking window opens. Live view is not optional here — focus drive
    /// only works while it is running, and every control in this panel drives focus — so it starts
    /// with the window rather than waiting for the first rack to switch it on.
    func enterBracketingMode(liveViewIsOn: Bool) {
        guard !isInBracketingMode else { return }
        isInBracketingMode = true
        liveViewWasOnBeforeEntering = liveViewIsOn
        // The panel owns the camera while it is open: the tether watch would otherwise make every
        // live-view frame wait on its listening window, and the feed crawls.
        Task { [session] in await session.beginExclusiveSession() }
        onSetLiveView?(true)
        probeCapability()
    }

    /// Guards against SwiftUI calling `onAppear` more than once, which would unbalance the
    /// session's pause depth and leave the tether watch suspended for good.
    private var isInBracketingMode = false

    /// Called when the window closes: restore the magnification and the photographer's own live
    /// view state. A bracket still running keeps the feed — it needs it, and it stops it itself.
    func exitBracketingMode() {
        // The camera is handed back **before** the busy check: a merge is CPU work on this side and
        // has no claim on the camera, so there is no reason to keep the photographer locked out of
        // their own body while it finishes.
        if isInBracketingMode, !isCapturing, !isRacking {
            isInBracketingMode = false
            Task { [session] in
                await session.releaseCameraControls()
                await session.endExclusiveSession()
            }
        }
        guard !isBusy else { return }

        if zoom != 1 { setZoom(1) }
        if !liveViewWasOnBeforeEntering { onSetLiveView?(false) }
    }

    /// Punches the live view in so focus can actually be judged. Failure is reported but not
    /// treated as fatal — a body that refuses the zoom is still perfectly able to shoot a bracket.
    func setZoom(_ factor: Int) {
        guard factor != zoom, !isBusy else { return }
        let previous = zoom
        zoom = factor
        onSetLiveView?(true)
        Task { [session] in
            do {
                try await session.setLiveViewZoom(factor)
            } catch {
                self.zoom = previous
                self.errorMessage = "Couldn't change live view magnification: \(error.localizedDescription)"
            }
        }
    }

    /// Runs the on-camera focus-drive experiment and reports which strategy moved the lens.
    /// Measured, not inferred: each strategy's preview is compared against the one before it with
    /// the same difference metric that detects a static bracket.
    func diagnoseFocusDrive() {
        guard !isBusy, rackTask == nil else { return }
        isRacking = true
        errorMessage = nil
        diagnosis = nil
        scanProgress = "Testing focus drive on the camera…"
        onSetLiveView?(true)

        let magnitude = range.magnitude
        rackTask = Task { [session] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let frames = await session.diagnoseFocusDrive(magnitude: magnitude)
            var lines: [String] = []
            var scores: [Int] = []
            var previous: StackImage?
            for (label, data) in frames {
                guard let image = Self.stackImage(from: data) else { continue }
                // Sharpness, not pixel difference: defocusing a lens changes how sharp the frame is
                // by a huge margin, while live-view noise changes it barely at all. Pixel difference
                // could not tell those apart — its noise floor was the same size as the signal.
                let score = FocusAnalyzer.evaluate(
                    ScopeFrame(width: image.width, height: image.height,
                               rgba: Self.rgbaWithAlpha(image)),
                    sharpThreshold: 70, softThreshold: 40).score
                scores.append(score)
                let difference = previous.map { FocusStackDiagnostics.difference($0, image) } ?? 0
                lines.append(String(format: "%-28@ focus score %3d   pixel delta %.4f",
                                    label as NSString, score, difference))
                previous = image
            }

            if frames.isEmpty {
                lines = ["The camera returned no preview frames, so nothing could be measured."]
            } else if let low = scores.min(), let high = scores.max() {
                // A lens that racks 20 coarse steps and back swings the sharpness score widely. A
                // lens that never moves holds it flat.
                let swing = high - low
                lines.append("")
                lines.append("focus score swing: \(swing) (\(low)–\(high))")
                lines.append(swing >= 10
                    ? "The lens is moving. Focus drive works."
                    : "The lens did not move: the score barely changed across 20 steps each way. "
                      + "Focus drive is being accepted and ignored.")
            }
            self.diagnosis = lines.joined(separator: "\n")
            FileHandle.appendLog("focus drive diagnosis:")
            for line in lines { FileHandle.appendLog("  \(line)") }
            self.scanProgress = nil
            self.isRacking = false
            self.rackTask = nil
        }
    }

    /// `ScopeFrame` expects 4 channels; the renderer's preview loader produces 3.
    private static func rgbaWithAlpha(_ image: StackImage) -> [Float] {
        var out = [Float](repeating: 1, count: image.pixelCount * 4)
        for i in 0..<image.pixelCount {
            out[i * 4] = image.data[i * 3]
            out[i * 4 + 1] = image.data[i * 3 + 1]
            out[i * 4 + 2] = image.data[i * 3 + 2]
        }
        return out
    }

    private static func stackImage(from data: Data) -> StackImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ScratchPlane.floatImage(from: image)
    }

    /// Records a focus map (see `GPhotoSession.recordFocusMap`) so the scan algorithm can be
    /// developed against real frames offline instead of a camera round trip per change.
    func recordFocusMap() {
        guard !isBusy, rackTask == nil else { return }
        isRacking = true
        errorMessage = nil
        scanProgress = "Recording focus map…"
        onSetLiveView?(true)

        let magnitude = range.magnitude
        rackTask = Task { [session] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            do {
                let folder = try await session.recordFocusMap(magnitude: magnitude) { message in
                    Task { @MainActor in self.scanProgress = message }
                }
                let count = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
                self.scanProgress = "Recorded \(count) frames to \(folder.lastPathComponent)."
                FileHandle.appendLog("focus map written: \(folder.path) (\(count) frames)")
            } catch {
                self.errorMessage = error.localizedDescription
                self.scanProgress = nil
            }
            self.isRacking = false
            self.rackTask = nil
        }
    }

    /// The whole job in one action: sweep, find the subject, choose the bracket, shoot it, merge it.
    ///
    /// Everything it needs it can measure. The span comes from the depth map; the spacing is the
    /// tightest that fits a bracket (`FocusOverlap.tightestThatFits`); the direction is always away
    /// from the camera. Nothing here was a decision a photographer wanted to make — they were knobs
    /// exposed because the app could not yet work the answer out.
    func scanAndShoot() {
        guard !isBusy, rackTask == nil, bracketTask == nil else { return }
        autoFindRange(thenShoot: true)
    }

    /// Focuses the camera on whatever it is pointed at, so the sweep starts centred on the subject.
    func autofocus() {
        guard !isBusy, rackTask == nil else { return }
        isRacking = true
        errorMessage = nil
        scanProgress = "Focusing…"
        onSetLiveView?(true)
        rackTask = Task { [session] in
            do {
                try await session.autofocusNow()
                // Focus has moved, so any marks measured against the old position are meaningless.
                self.range = FocusRange(magnitude: self.range.magnitude)
                self.scanProgress = "Focused. Draw a box around the subject and Scan & Shoot."
            } catch {
                self.errorMessage = error.localizedDescription
                self.scanProgress = nil
            }
            self.isRacking = false
            self.rackTask = nil
        }
    }

    func markNear() { range.markNear() }
    func markFar() { range.markFar() }

    func clearRange() {
        range = FocusRange(magnitude: plan.step.magnitude)
    }

    /// Sweeps focus across the lens's travel and marks the subject's depth from a `FocusDepthMap`.
    ///
    /// Measures **where each tile of the frame comes into focus**, rather than how sharp the frame
    /// is overall. Validated against a recorded map of a real subject: the range it picks covers
    /// 90% of the subject's tiles, while the ranges the previous curve-based scan produced covered
    /// 18–27% — which is precisely the "didn't capture enough depth" this kept producing.
    func autoFindRange(thenShoot: Bool = false) {
        guard !isBusy, rackTask == nil else { return }
        isRacking = true
        errorMessage = nil
        scanProgress = "Sweeping focus…"
        onSetLiveView?(true)

        let magnitude = range.magnitude
        let settle = plan.settleSeconds
        let origin = range.position

        rackTask = Task { [session] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            var frames: [(offset: Int, frame: Data)] = []
            var travelled = 0
            do {
                let result = try await session.scanFocus(magnitude: magnitude, settleSeconds: settle) { stop, total in
                    Task { @MainActor in self.scanProgress = "Sweeping \(stop) of \(total)…" }
                }
                frames = result.samples
                travelled = result.travelled
            } catch let interrupted as FocusDriveInterrupted {
                travelled = interrupted.completed
                if !interrupted.isCancellation { self.errorMessage = interrupted.localizedDescription }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.range.position = origin + travelled

            self.scanProgress = "Building depth map…"

            // Every sweep is kept as its own focus map.
            //
            // Auto-find used to discard its frames, so when a result looked wrong the only way to
            // investigate was to ask for another camera run — which is what made this feature so
            // slow to get right. 91 small JPEGs cost ~20 MB and turn each run into a dataset that
            // can be replayed offline against any change.
            let scanFolder = CaptureLocation.directory.appendingPathComponent(
                "Focus Scan " + DateFormatter.captureFilenameFormatter.string(from: Date()))
            try? FileManager.default.createDirectory(at: scanFolder, withIntermediateDirectories: true)

            var byOffset: [Int: [Double]] = [:]
            var reference: [(offset: Int, tiles: [Double])] = []
            for (offset, data) in frames {
                try? data.write(to: scanFolder.appendingPathComponent(
                    String(format: "step_%+04d.jpg", origin + offset)))
                if let tiles = GPhotoSession.previewTileSharpness(of: data) {
                    byOffset[origin + offset] = tiles
                    reference.append((offset: origin + offset, tiles: tiles))
                }
            }
            FileHandle.appendLog("auto-find: sweep saved to \(scanFolder.lastPathComponent)")
            self.sweepReference = reference
            let map = FocusDepthMap(framesByOffset: byOffset)
            FileHandle.appendLog("auto-find: \(byOffset.count) frames, \(map.usableTiles.count) usable tiles, "
                                 + "\(map.subjectTiles(region: self.subjectRegion).count) on the subject"
                                 + (self.subjectRegion == nil ? " (no subject box drawn)" : " (in the drawn box)"))
            FileHandle.appendLog("auto-find: depth clusters "
                                 + "\(FocusDepthMap.cluster(map.subjectTiles(region: self.subjectRegion).map(\.offset)))")

            // Tiles still coming into focus at the edge of the sweep mean the subject runs past it.
            let pinned = map.tilesPinnedAtEdge(region: self.subjectRegion)
            let usableCount = map.subjectTiles(region: self.subjectRegion).count
            if pinned > 0 {
                FileHandle.appendLog("auto-find: \(pinned) tiles pinned at the edge of the sweep "
                                     + "(\(usableCount) usable) — subject may extend beyond it")
            }
            // `margin: 0` — the padding is applied once, below.
            //
            // `subjectRange`'s own margin and the depth-of-field pad here are the same idea, and
            // applying both padded every stack by seven steps at each end. Measured on a real
            // sweep: a subject clustered at −41…39 became a −48…46 bracket, and the two nearest
            // frames of the resulting ladder won no subject tiles at all — pure shooting time.
            let found0 = map.subjectRange(margin: 0, region: self.subjectRegion)
            let coverage0 = found0.map { map.coverage(near: $0.near, far: $0.far, region: self.subjectRegion) } ?? 0
            // A range the subject barely falls inside is a mis-read, not a narrow subject — shooting
            // it wastes a bracket and the result looks like a broken merge. Observed: a single stray
            // tile at the sweep's edge produced a 4-step range covering 0% of the subject.
            // Pad the ends by a depth of field.
            //
            // The measured range runs between the outermost tiles that could be measured, which is
            // where the subject's *detectable texture* ends — not where the subject does. A frame
            // covers a depth of field, so the end surfaces must sit inside the last frame rather
            // than on its boundary.
            //
            // **Half** a depth of field is what that takes, not a whole one: the last frame is
            // centred on the padded end and reaches half its depth of field either side, so half
            // is exactly enough to bring the outermost tile inside it. A full one pushed the frame
            // clear past the subject and bought nothing.
            let dof = map.depthOfFieldSteps(region: self.subjectRegion) ?? 2
            let dofPad = Swift.max(2, (dof + 1) / 2)
            let padded = found0.map { (near: $0.near - dofPad, far: $0.far + dofPad) }
            if let found = (coverage0 >= Self.minimumSubjectCoverage ? padded : nil) {
                self.range.nearMark = found.near
                self.range.farMark = found.far
                let covered = Int(map.coverage(near: found.near, far: found.far, region: self.subjectRegion) * 100)
                FileHandle.appendLog("auto-find: subject range \(found.near)…\(found.far) "
                                     + "(span \(found.far - found.near)), covers \(covered)% of subject tiles")
                let span = found.far - found.near
                // Spacing comes from the depth of field this very sweep measured, not from a knob
                // and not from "as many as will fit". One frame stays sharp over a measurable
                // number of steps; spacing any tighter than that is shooting the same picture
                // twice. Measured on a real subject: 6 steps of depth of field, so an 18-step span
                // needs ~4 frames where shooting every step was taking 19.
                let depthOfField = map.depthOfFieldSteps(region: self.subjectRegion)
                // 95% of it — very nearly the full measured depth of field.
                //
                // The safety margin people expect to need here is already spent twice over inside
                // the measurement: `depthOfFieldSteps` takes the **lower quartile** of the per-tile
                // sharp width, so spacing satisfies the narrowest part of the subject rather than
                // the average one, and it measures that width at 80% of each tile's peak, not at
                // the point where the tile visibly softens. Discounting the result a further 15%
                // on top was a third margin stacked on two, and it cost frames on every bracket:
                // on a real 80-step subject, 85% gave 23 frames where 95% gives 19.
                //
                // 75% was the original figure, set when positioning was open-loop and a frame could
                // land somewhere other than intended. The bracket now seeks its start by looking,
                // so that margin insures against a risk that no longer exists.
                var spacing = depthOfField.map { Swift.max(1, Int((Double($0) * 0.95).rounded())) }
                    ?? FocusOverlap.tightestThatFits(span: span).stepsPerFrame

                // Widen the spacing until the whole range fits in one bracket.
                //
                // `frameCount` clamps to the frame cap, so a range needing more frames than that was
                // silently **truncated**: a measured 48-step subject at 1-step spacing needs 49
                // frames, got 40, and the last nine steps were simply never photographed — the far
                // end of the subject stayed soft for a reason that looked like a bad range. Covering
                // all of the subject slightly more coarsely beats covering most of it finely.
                while FocusRangePlanner.exceedsFrameLimit(span: span, stepsPerFrame: spacing),
                      spacing < FocusStackPlan.stepsPerFrameRange.upperBound {
                    spacing += 1
                }
                // Apply it. This assignment went missing in an edit, so the plan kept whatever
                // spacing a previous run had left on it — usually the finest — and the bracket shot
                // far more frames than the measurement called for.
                self.plan.stepsPerFrame = Swift.min(spacing, FocusStackPlan.stepsPerFrameRange.upperBound)
                let frameTotal = FocusRangePlanner.frameCount(span: span,
                                                              stepsPerFrame: self.plan.stepsPerFrame)
                // Report how many planned frames actually have subject at their focus position.
                //
                // A frame that wins no tiles is a shutter actuation and a download — about four
                // seconds — spent photographing depth the subject does not occupy. Without this
                // the only symptom is a bracket that feels longer than the result justifies, with
                // nothing in the log to measure it against.
                let planned = stride(from: found.near, through: found.far, by: self.plan.stepsPerFrame)
                let depths = map.subjectTiles(region: self.subjectRegion).map(\.offset)
                let emptyFrames = planned.filter { position in
                    !depths.contains { depth in
                        planned.allSatisfy { abs(depth - position) <= abs(depth - $0) }
                    }
                }.count
                if let spread = map.depthOfFieldSpread(region: self.subjectRegion) {
                    FileHandle.appendLog("auto-find: depth of field spread — lower quartile "
                                         + "\(spread.lower), median \(spread.median), upper \(spread.upper) steps")
                }
                if emptyFrames > 0 {
                    FileHandle.appendLog("auto-find: \(emptyFrames) of \(frameTotal) planned frames "
                                         + "sit where no subject tile does")
                }
                FileHandle.appendLog("auto-find: depth of field \(depthOfField.map(String.init) ?? "unknown") steps"
                                     + " -> every \(self.plan.stepsPerFrame) steps, \(frameTotal) frames")
                self.scanProgress = pinned > usableCount / 4
                    ? "\(span)-step subject, \(frameTotal) frames — but part of it lies beyond where "
                      + "the scan could look, so the far edge may stay soft."
                    : "\(span)-step subject, \(covered)% covered — \(frameTotal) frames."
                if thenShoot {
                    self.isRacking = false
                    self.rackTask = nil
                    self.startBracket()
                    return
                }
            } else if let found = found0 {
                FileHandle.appendLog("auto-find: rejected range \(found.near)…\(found.far) — covers only "
                                     + "\(Int(coverage0 * 100))% of the subject")
                self.scanProgress = "Couldn't pin down the subject — the depths found cover only "
                    + "\(Int(coverage0 * 100))% of it. Try a tighter box around it."
            } else if self.errorMessage == nil {
                FileHandle.appendLog("auto-find: no usable range — too few tiles with a focus transition")
                // No instruction to "mark the ends by hand" — those controls were removed when the
                // panel was simplified, so that advice was impossible to follow.
                self.scanProgress = frames.isEmpty
                    ? "The scan got no frames from the camera — check live view is working."
                    : "Couldn't read the subject's depth: only \(map.usableTiles.count) parts of the "
                      + "frame had enough detail to focus on. Try a box over a more textured part of "
                      + "it, more light, or a smaller aperture."
            } else {
                self.scanProgress = nil
            }
            self.isRacking = false
            self.rackTask = nil
        }
    }

    func cancelRacking() {
        rackTask?.cancel()
    }

    /// Scores one JPEG preview frame for the focus scan.
    ///
    /// Reports **raw sharpness ×10, not the 0–100 focus-badge score.** That score is deliberately
    /// compressed by `FocusAnalyzer.halfScoreRatio` so it reads well as a confidence, and the
    /// compression destroys exactly the resolution a scan needs: a real sweep spanning sharpness
    /// 3.0–4.3 maps to scores 50–59, barely clearing the contrast the reader requires, and a
    /// narrower but perfectly real curve falls under it and is rejected. Scaled sharpness keeps the
    /// differences proportional, so `FocusScanReader.minimumContrast` means "0.8 sharpness units"
    /// against observed sweeps of 13–36.
    private static func focusScore(of data: Data) async -> Int? {
        guard let image = stackImage(from: data) else { return nil }
        let frame = ScopeFrame(width: image.width, height: image.height,
                               rgba: rgbaWithAlpha(image))
        let sharpness = FocusAnalyzer.measure(frame).sharpness
        guard sharpness.isFinite else { return nil }
        return Int((sharpness * 10).rounded())
    }

    // MARK: - Capability

    var canShoot: Bool {
        capability?.isAvailable == true && !isBusy
    }

    var canMerge: Bool { lastBracket.count >= 2 && !isCapturing && !isMerging }

    /// Asks the camera whether it can drive focus. Cheap and cached in the session, so the panel
    /// calls it every time it appears rather than caching a possibly-stale answer up here.
    func probeCapability(forceRefresh: Bool = false) {
        guard !isProbing else { return }
        isProbing = true
        Task { [session] in
            let result = await session.focusDriveCapability(forceRefresh: forceRefresh)
            self.capability = result
            self.isProbing = false
        }
    }

    // MARK: - Bracket

    func startBracket() {
        guard canShoot, bracketTask == nil else { return }
        errorMessage = nil
        lastRender = nil
        lastBracket = []
        isCapturing = true
        bracketProgress = FocusBracketProgress(phase: .preparing, framesCaptured: 0)

        let plan = effectivePlan
        // Walk to whichever end the bracket starts from — the nearer one, so the sweep's finishing
        // position is used rather than thrown away. Positive means "away from the camera".
        let startMark = FocusRangePlanner.startEnd(for: range)?.start
        let reference = sweepReference
        let magnitude = range.magnitude
        let settle = plan.settleSeconds
        let asJPEG = captureAsJPEG

        bracketTask = Task { [session] in
            var shouldMerge = false
            do {
                // A marked range is only meaningful if the bracket actually *starts* at its near
                // mark. Focus may be anywhere after racking around, so walk it there first.
                if let start = startMark {
                    // Position by **looking**, not by counting.
                    //
                    // A step count drifts the moment a nudge lands at an end of travel, and the
                    // count runs ahead of the lens from then on. On a real run that left the bracket
                    // shooting +105…+11 when it had been told −48…44: the subject was never
                    // photographed, while every number in the log looked right. The sweep's own
                    // frames are labelled pictures of each offset, so they can say where the lens
                    // actually is.
                    if !reference.isEmpty,
                       let landed = await session.seekToOffset(start, reference: reference,
                                                               magnitude: magnitude) {
                        self.range.position = landed
                        FileHandle.appendLog("bracket: positioned at offset \(landed) (target \(start))")
                    } else {
                        let delta = start - self.range.position
                        if delta != 0 {
                            let (moved, _) = try await session.nudgeFocusVerified(
                                FocusStep.step(towardCamera: delta < 0, magnitude: magnitude),
                                times: abs(delta), settleSeconds: settle)
                            self.range.move(by: moved * (delta < 0 ? -1 : 1))
                        }
                    }
                }
                let result = try await session.captureFocusStack(plan, asJPEG: asJPEG) { progress in
                    Task { @MainActor in self.bracketProgress = progress }
                }
                self.lastBracket = result.frames
                self.lastBracketDirectory = result.directory
                if result.frames.count < 2 {
                    self.errorMessage = "The bracket only produced \(result.frames.count) frame\(result.frames.count == 1 ? "" : "s")."
                } else {
                    shouldMerge = true
                }
            } catch let interrupted as FocusDriveInterrupted {
                // Whatever landed still counts — see `nudgeFocus`.
                if !interrupted.isCancellation {
                    self.errorMessage = interrupted.localizedDescription
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isCapturing = false
            self.bracketTask = nil
            // Merge first, live view second: the camera needs a while to start producing previews
            // again after a burst of stills, and the photographer should not wait for that to see
            // their result.
            if shouldMerge { self.merge() }

            // Then wait — patiently, and off to one side — for the camera to be willing again.
            self.recoverLiveView()

        }
    }

    /// Stops the bracket. The session still walks focus back to where it started — an aborted
    /// bracket that left the lens parked mid-rack would cost more to recover from than it saved.
    func cancelBracket() {
        bracketTask?.cancel()
    }

    // MARK: - Merge

    /// Merges the given frames (or the last bracket) into one full-resolution image, written into
    /// the bracket's own folder.
    func merge(_ urls: [URL]? = nil) {
        // Merge whatever is **in the bracket's folder**, not the list the capture loop happened to
        // collect.
        //
        // Those are not the same thing: a bracket wrote 24 frames to disk and handed back 8, so the
        // merge silently used a third of the stack. Which frames the drain managed to attribute is
        // an implementation detail of downloading; the folder is the photographer's stack, and the
        // only description of it that cannot drift.
        let frames = urls ?? framesInLastBracketFolder()
        guard frames.count >= 2, !isMerging else { return }
        FileHandle.appendLog("merge: \(frames.count) frames from "
                             + "\(lastBracketDirectory?.lastPathComponent ?? "the bracket")")
        // Named from the folder's stamp so the merged file and its folder read as one capture.
        let destination = lastBracketDirectory.map {
            $0.appendingPathComponent(CaptureLocation.mergedFileName(inStackFolder: $0))
        } ?? FocusStackRenderer.defaultOutputURL(for: frames[0])
        errorMessage = nil
        isMerging = true
        mergeFraction = 0
        mergeStatus = "Starting…"

        // `.utility`, not `.userInitiated`: the merge saturates every core for ~20 s, and at a
        // higher priority it starves the live-view decode — the feed freezes and reads as "live
        // view never came back", when in fact frames were arriving the whole time. The photographer
        // is watching the camera, not the progress bar; the merge can have the leftovers.
        // The critique is judged over the subject the photographer marked, not the whole frame.
        let region = subjectRegion.map { (x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        mergeTask = Task.detached(priority: .utility) {
            do {
                // The renderer is synchronous and CPU-bound for a minute or more on a real stack,
                // hence `Task.detached`: run on the main actor it would freeze the whole app, and
                // shots can still be landing in the gallery while a merge runs.
                let render = try FocusStackRenderer.render(urls: frames, outputURL: destination,
                                                           subjectRegion: region) { fraction, status in
                    Task { @MainActor in
                        self.mergeFraction = fraction
                        self.mergeStatus = status
                    }
                }
                await MainActor.run {
                    self.lastRender = render
                    self.mergeStatus = "Merged \(render.sourceCount) frames."
                    self.onStackMerged?(render.outputURL)
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            // Always check the feed is genuinely alive once the merge is done — the point at which
            // the photographer expects to be able to shoot again.
            //
            // Checking a stored "did the earlier recovery succeed" flag was not enough: it *had*
            // succeeded, live view restarted, and then the loop died partway through the merge with
            // nothing left to notice. Ask the session what is actually running instead of trusting
            // a flag recorded a minute earlier.
            let running = await self.session.liveViewIsRunning
            await MainActor.run {
                self.isMerging = false
                self.mergeTask = nil
                if !running { self.recoverLiveView() }
            }
        }
    }

    /// Brings the live feed back once the camera will talk again.
    ///
    /// Runs in the background and is safe to call more than once: after a burst of stills this body
    /// can refuse previews for a long time, and the only thing that matters is that the feed is
    /// running again before the next stack — focus drive does not work without it.
    func recoverLiveView() {
        guard liveViewRecoveryTask == nil else { return }
        isRecoveringLiveView = true
        liveViewRecoveryTask = Task { [session] in
            let ready = await session.waitForLiveViewReady()
            self.isRecoveringLiveView = false
            self.liveViewRestored = ready
            if ready { self.onRestartLiveView?() }
            self.liveViewRecoveryTask = nil
        }
    }

    /// Every captured frame in the last bracket's folder, in capture order (the filenames are
    /// timestamps, so lexicographic order is chronological).
    private func framesInLastBracketFolder() -> [URL] {
        guard let folder = lastBracketDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { return lastBracket }
        let frames = contents
            .filter { ["jpg", "jpeg", "cr2", "cr3"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return frames.count >= lastBracket.count ? frames : lastBracket
    }

    func revealRender() {
        guard let url = lastRender?.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Persistence

    private func savePlan() {
        let encoded: [String: Any] = [
            "frameCount": plan.frameCount,
            "step": plan.step.rawValue,
            "stepsPerFrame": plan.stepsPerFrame,
            "settleSeconds": plan.settleSeconds,
            "returnToStart": plan.returnToStart
        ]
        UserDefaults.standard.set(encoded, forKey: Self.planDefaultsKey)
    }

    private func loadPlan() {
        isLoadingPlan = true
        defer { isLoadingPlan = false }
        // Read before the plan guard: this preference is stored separately, so a photographer who
        // has set it but never touched the bracket settings must still get it back.
        if UserDefaults.standard.object(forKey: Self.jpegDefaultsKey) != nil {
            captureAsJPEG = UserDefaults.standard.bool(forKey: Self.jpegDefaultsKey)
        }
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.planDefaultsKey) else { return }
        // `FocusStackPlan`'s initialiser clamps every field, so a hand-edited or stale defaults
        // entry can't put the UI into a state its own steppers can't represent.
        plan = FocusStackPlan(
            frameCount: stored["frameCount"] as? Int ?? 8,
            step: (stored["step"] as? String).flatMap(FocusStep.init(rawValue:)) ?? .farSmall,
            stepsPerFrame: stored["stepsPerFrame"] as? Int ?? 1,
            settleSeconds: stored["settleSeconds"] as? Double ?? 0.4,
            returnToStart: stored["returnToStart"] as? Bool ?? true
        )
    }
}
