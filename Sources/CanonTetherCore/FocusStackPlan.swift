import Foundation

/// One nudge of the focus motor, as Canon's PTP `manualfocusdrive` action expresses it: a direction
/// and one of three coarsenesses. There is **no absolute focus position** in this protocol — the
/// body accepts "go nearer by a small/medium/large amount" and reports nothing back about where the
/// lens ended up. Everything here is therefore open-loop: a bracket is a count of nudges, not a
/// range between two known distances, and the app can only verify coverage *after* the fact from
/// the merged stack's coverage map.
public enum FocusStep: String, CaseIterable, Identifiable, Sendable {
    case nearSmall, nearMedium, nearLarge
    case farSmall, farMedium, farLarge

    public var id: String { rawValue }

    public var isNear: Bool {
        switch self {
        case .nearSmall, .nearMedium, .nearLarge: return true
        case .farSmall, .farMedium, .farLarge: return false
        }
    }

    /// 1, 2 or 3 — the coarseness index Canon uses.
    public var magnitude: Int {
        switch self {
        case .nearSmall, .farSmall: return 1
        case .nearMedium, .farMedium: return 2
        case .nearLarge, .farLarge: return 3
        }
    }

    /// How big the nudge is, on its own — the UI presents size and direction as separate controls,
    /// because burying direction inside a six-way size menu is how a bracket ends up racking the
    /// wrong way and the photographer only finds out after the merge.
    public var magnitudeLabel: String {
        ["", "Fine", "Medium", "Coarse"][magnitude]
    }

    /// Phrased from the subject's point of view rather than the lens's: "nearer"/"further" alone is
    /// ambiguous about what it is near to.
    public var directionLabel: String {
        isNear ? "Toward the camera" : "Away from the camera"
    }

    public var label: String {
        "\(magnitudeLabel) — \(isNear ? "toward camera" : "away from camera")"
    }

    /// Builds a step from the two things the UI actually controls.
    public static func step(towardCamera: Bool, magnitude: Int) -> FocusStep {
        let clamped = Swift.min(Swift.max(magnitude, 1), 3)
        return FocusStep.allCases.first { $0.isNear == towardCamera && $0.magnitude == clamped } ?? .farSmall
    }

    /// The same step in the opposite direction.
    public var reversed: FocusStep {
        FocusStep.allCases.first { $0.isNear != isNear && $0.magnitude == magnitude } ?? self
    }

    /// The canonical gphoto2 choice string ("Near 1", "Far 3"). Used as a *fallback*: the real
    /// value sent is matched against what the body actually lists, since the exact spelling has
    /// varied between libgphoto2 versions and Canon generations.
    public var canonicalChoice: String {
        "\(isNear ? "Near" : "Far") \(magnitude)"
    }

    /// Picks the choice string this camera advertises for this step, out of the list `get-config
    /// /main/actions/manualfocusdrive` returned. Matching is on direction + magnitude rather than
    /// on an exact string, so a differently-spelled build ("Near 1"/"near1"/"Near step 1") still
    /// resolves instead of the feature silently doing nothing.
    public static func choice(for step: FocusStep, in choices: [String]) -> String? {
        let wanted = step.isNear ? "near" : "far"
        let digit = Character("\(step.magnitude)")
        let match = choices.first { choice in
            let lower = choice.lowercased()
            return lower.contains(wanted) && lower.contains(digit)
        }
        return match ?? choices.first { $0.caseInsensitiveCompare(step.canonicalChoice) == .orderedSame }
    }

    /// Whether a camera's advertised choice list looks like a usable focus-drive control at all —
    /// i.e. it offers both directions in at least one magnitude. A body that lists only "None"
    /// has the property but cannot drive focus, and the UI must say so rather than shooting a
    /// bracket of identical frames.
    public static func isDrivable(choices: [String]) -> Bool {
        let hasNear = choices.contains { $0.lowercased().contains("near") }
        let hasFar = choices.contains { $0.lowercased().contains("far") }
        return hasNear && hasFar
    }
}

/// A focus bracket: how many frames, what size nudge between them, and which way to travel.
public struct FocusStackPlan: Equatable, Sendable {
    /// Total frames captured, including the one at the starting focus position.
    public var frameCount: Int
    /// The nudge applied *between* frames. Its direction sets the travel direction.
    public var step: FocusStep
    /// How many nudges of `step` are applied between consecutive frames. Lets the bracket travel in
    /// multiples of a coarseness the body offers, since only three coarsenesses exist.
    public var stepsPerFrame: Int
    /// Seconds to wait after driving focus before firing, so the lens has settled. Open-loop again:
    /// nothing reports when the motor stopped, so this is a timeout, not a handshake.
    ///
    /// 0.15 s. Successively 0.4 → 0.25 → 0.15 as the costs hiding behind it were removed (the tether
    /// watch queueing every step, then the preview that follows it anyway). The preview that
    /// re-arms live view takes ~400 ms by itself, during which the lens is settling regardless, so
    /// most of this wait was being paid twice.
    public var settleSeconds: Double
    /// Return the lens to where it started when the bracket finishes. Strongly wanted in practice —
    /// without it every bracket leaves focus somewhere new and the next one starts from a different
    /// place. It is a best-effort reversal of the same nudges, not a seek to a remembered position.
    public var returnToStart: Bool

    public static let frameRange = 2...40
    public static let stepsPerFrameRange = 1...10
    public static let settleRange = 0.1...3.0

    /// Defaults to stepping **away** from the camera. That matches how focus stacking is actually
    /// shot — focus on the nearest part of the subject, then walk focus back through it — and a
    /// default that racks the wrong way is invisible until the merge comes out wrong.
    public init(frameCount: Int = 8,
                step: FocusStep = .farSmall,
                stepsPerFrame: Int = 1,
                settleSeconds: Double = 0.15,
                returnToStart: Bool = true) {
        self.frameCount = frameCount.clamped(to: FocusStackPlan.frameRange)
        self.step = step
        self.stepsPerFrame = stepsPerFrame.clamped(to: FocusStackPlan.stepsPerFrameRange)
        self.settleSeconds = min(max(settleSeconds, FocusStackPlan.settleRange.lowerBound),
                                 FocusStackPlan.settleRange.upperBound)
        self.returnToStart = returnToStart
    }

    /// Nudges applied between frames — `frameCount - 1` gaps.
    public var totalSteps: Int { (frameCount - 1) * stepsPerFrame }

    /// The full nudge sequence for the return leg, if enabled.
    public var returnSteps: Int { returnToStart ? totalSteps : 0 }

    /// Rough wall-clock estimate, for the UI to show before the photographer commits to a bracket
    /// that might take a minute. `secondsPerFrame` is the measured cost of one capture-and-download
    /// on this link, which the caller supplies because it differs hugely between USB and PTP/IP.
    public func estimatedSeconds(secondsPerFrame: Double) -> Double {
        let capturing = Double(frameCount) * secondsPerFrame
        let driving = Double(totalSteps + returnSteps) * settleSeconds
        return capturing + driving
    }

    /// A human summary of what will happen, for the confirmation line in the UI.
    public var summary: String {
        let nudges = stepsPerFrame == 1 ? "" : " ×\(stepsPerFrame)"
        let direction = step.isNear ? "toward the camera" : "away from the camera"
        return "\(frameCount) frames in \(step.magnitudeLabel.lowercased())\(nudges) steps, moving focus \(direction). "
            + "Set focus on the \(step.isNear ? "furthest" : "nearest") part of the subject before starting."
    }
}

/// What the coverage map of a finished stack says about the bracket that produced it — the only
/// feedback loop available, since focus position is never reported by the camera.
public struct FocusStackCritique: Equatable {
    public enum Verdict: Equatable {
        case good
        /// The subject runs past one end of the bracket: the outermost frame is still winning a
        /// large share, so there was more subject where the bracket stopped looking.
        case rangeClippedAtStart(share: Double)
        case rangeClippedAtEnd(share: Double)
        case wastedAtStart(frames: Int)
        case wastedAtEnd(frames: Int)
    }

    public let verdicts: [Verdict]

    /// Frames whose share of the merged image is below this are doing essentially nothing — the
    /// bracket travelled past the subject before or after those frames.
    public static let deadFrameShare = 0.01
    /// An end frame winning more than this is holding territory that continues past it.
    ///
    /// An interior frame wins a slice of the subject and hands over to its neighbour. An *end*
    /// frame has no neighbour on one side, so when it wins a large share the likeliest reason is
    /// that the subject carried on and the bracket did not.
    public static let clippedEndShare = 0.15

    public init(coverage: CoverageMap,
                region: (x: Double, y: Double, width: Double, height: Double)? = nil) {
        var found: [Verdict] = []
        // Coverage is deliberately **not** judged here any more.
        //
        // `confidence` is the winning frame's share of the total sharpness at a cell, so the more
        // frames a bracket has, the more of them are nearly sharp anywhere, and the lower every
        // winner's share becomes. The metric falls as sampling improves. Measured on two brackets
        // of the same subject minutes apart: 20 frames scored 67% and 24 frames scored 68%, while
        // a direct per-tile comparison of the two merged images found the 24-frame result **14.7%
        // sharper** in median tile sharpness, better in 180 of 263 textured tiles. It reported the
        // better stack as no better, and told the photographer 33% of a visibly excellent stack
        // "was never sharp" — advice to shoot more frames, which is what they were already
        // complaining about.
        //
        // The deeper reason is not a bad threshold: a single merge cannot know whether a *denser*
        // bracket would have been sharper, because the sharpest frame it has is the only evidence
        // it has. That question is answerable by shooting two brackets and comparing, and not
        // otherwise. So the critique now reports only what one merge can establish.
        let shares = coverage.shares()
        // The subject running past the end of the bracket, though, is visible in one merge: the
        // outermost frame keeps winning instead of handing over.
        if let first = shares.first, first > FocusStackCritique.clippedEndShare {
            found.append(.rangeClippedAtStart(share: first))
        }
        if let last = shares.last, shares.count > 1, last > FocusStackCritique.clippedEndShare {
            found.append(.rangeClippedAtEnd(share: last))
        }
        let leading = shares.prefix { $0 < FocusStackCritique.deadFrameShare }.count
        let trailing = shares.reversed().prefix { $0 < FocusStackCritique.deadFrameShare }.count
        // A stack where *every* frame is dead is a degenerate read, not advice worth giving.
        if leading + trailing < shares.count {
            if leading > 0 { found.append(.wastedAtStart(frames: leading)) }
            if trailing > 0 { found.append(.wastedAtEnd(frames: trailing)) }
        }
        verdicts = found.isEmpty ? [.good] : found
    }

    /// One line of plain advice per finding.
    public var advice: [String] {
        verdicts.map { verdict in
            switch verdict {
            case .good:
                return "Focus coverage looks complete."
            case .rangeClippedAtStart(let share):
                return "The first frame covers \(Int((share * 100).rounded()))% of the image — the subject probably starts before the bracket did."
            case .rangeClippedAtEnd(let share):
                return "The last frame covers \(Int((share * 100).rounded()))% of the image — the subject probably continues past where the bracket stopped."
            case .wastedAtStart(let frames):
                return "The first \(frames) frame\(frames == 1 ? "" : "s") added nothing — start the bracket closer to the subject."
            case .wastedAtEnd(let frames):
                return "The last \(frames) frame\(frames == 1 ? "" : "s") added nothing — \(frames) fewer frames would cover the same subject."
            }
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        // Swift-qualified: inside an Int extension, bare `min`/`max` resolve to Int.min/Int.max.
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// What the body reports about its ability to drive focus over PTP. Probed at runtime rather than
/// assumed: `manualfocusdrive` is a Canon vendor action whose presence depends on body, lens, lens
/// switch position and firmware, and the honest states are three, not two.
public enum FocusDriveCapability: Equatable, Sendable {
    /// Drivable, with the exact choice strings this body advertises.
    case available(choices: [String])
    /// The property exists but offers no direction to drive in — typically no lens attached.
    case presentButNotDrivable
    /// The **switch on the lens barrel** is set to MF, so the body can't drive the focus motor at
    /// all. Distinguished from the body simply being in manual focus mode — which is the state
    /// focus stacking *needs* — by `focusmode` being read-only: with the lens in AF the body lets
    /// the mode be changed, with the lens in MF it is stuck reporting Manual.
    case lensSwitchInManualFocus(lens: String?)
    /// The body doesn't expose the property at all.
    case unsupported
    /// The probe itself failed (camera busy, link dropped) — distinct from "not supported", because
    /// it is worth retrying and must not be cached as a permanent no.
    case unknown(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// What the UI tells the photographer when a bracket can't be shot.
    public var explanation: String? {
        switch self {
        case .available:
            return nil
        case .presentButNotDrivable:
            return "The camera won't drive focus right now. Check a lens is attached and live view can start."
        case .lensSwitchInManualFocus(let lens):
            let which = lens.map { "The \($0)" } ?? "The lens"
            return "\(which) has its switch set to MF, so the camera can't drive focus. "
                + "Set the switch on the lens to AF — the app puts the body itself into manual "
                + "focus while it works."
        case .unsupported:
            return "This camera doesn't support driving focus from the computer."
        case .unknown(let reason):
            return "Couldn't tell whether the camera can drive focus: \(reason)"
        }
    }
}

/// Where a running bracket has got to, for the progress UI.
public struct FocusBracketProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing
        case capturing(frame: Int, of: Int)
        case steppingFocus(frame: Int, of: Int)
        case returningFocus
        case finished
        case cancelled
    }

    public let phase: Phase
    public let framesCaptured: Int

    public init(phase: Phase, framesCaptured: Int) {
        self.phase = phase
        self.framesCaptured = framesCaptured
    }

    public var label: String {
        switch phase {
        case .preparing: return "Preparing…"
        case .capturing(let frame, let total): return "Frame \(frame) of \(total)…"
        case .steppingFocus(let frame, let total): return "Stepping focus (\(frame) of \(total))…"
        case .returningFocus: return "Returning focus…"
        case .finished: return "Bracket complete."
        case .cancelled: return "Bracket cancelled."
        }
    }

    /// 0–1 for a determinate bar; nil while there's nothing meaningful to show.
    public func fraction(of total: Int) -> Double? {
        guard total > 0 else { return nil }
        switch phase {
        case .preparing: return 0
        case .finished, .cancelled: return 1
        case .returningFocus: return 1
        case .capturing(let frame, _), .steppingFocus(let frame, _):
            return Swift.min(Double(frame) / Double(total), 1)
        }
    }
}

/// What a finished bracket produced: its frames, and the folder they were grouped into.
///
/// The frames are kept out of the gallery on purpose — a dozen near-identical rack-focus frames are
/// not a dozen photographs, and filling the filmstrip with them buries the actual shots. Only the
/// merged image from `directory` is reviewed.
public struct FocusBracketResult: Sendable {
    public let frames: [URL]
    public let directory: URL

    public init(frames: [URL], directory: URL) {
        self.frames = frames
        self.directory = directory
    }
}

/// Checks whether a bracket's frames actually differ — i.e. whether the lens moved at all.
///
/// This exists because of a real failure that is almost impossible to read from the output: with the
/// camera body in an AF mode, `manualfocusdrive` is accepted and acknowledged while the lens stays
/// exactly where it is. The bracket then captures N copies of one photograph, the merge dutifully
/// blends them, and the result looks like a broken merge rather than a camera that never racked.
/// Measured on a real 8-frame bracket in that state: every frame scored 84, the sharpest region sat
/// in the same tile in all eight, and consecutive frames differed by 0.33% — sensor noise.
///
/// So the merge says so out loud instead of leaving it to be guessed at.
public enum FocusStackDiagnostics {
    /// Sharpness of one frame, on the same scale `FocusMovement` expects.
    public static func sharpness(of image: StackImage) -> Double {
        guard image.isValid else { return 0 }
        // `ScopeFrame` wants RGBA; stack frames are RGB.
        var rgba = [Float](repeating: 1, count: image.pixelCount * 4)
        let channels = image.channels
        for i in 0..<image.pixelCount {
            for c in 0..<Swift.min(3, channels) {
                rgba[i * 4 + c] = image.data[i * channels + c]
            }
        }
        let value = FocusAnalyzer.measure(
            ScopeFrame(width: image.width, height: image.height, rgba: rgba)).sharpness
        return value.isFinite ? value : 0
    }

    /// Mean absolute difference in luma between two same-shaped frames, in [0, 1].
    ///
    /// Kept for reporting only. It must **not** be used to decide whether focus changed: measured,
    /// frames three focus steps apart differ by 0.0048 and frames where the lens never moved differ
    /// by 0.0039 — indistinguishable. See `FocusMovement`.
    public static func difference(_ a: StackImage, _ b: StackImage) -> Double {
        guard a.isValid, b.isValid, a.matchesShape(of: b) else { return 0 }
        let lumaA = a.luma(), lumaB = b.luma()
        var total = 0.0
        for i in 0..<lumaA.data.count {
            total += abs(Double(lumaA.data[i]) - Double(lumaB.data[i]))
        }
        return total / Double(lumaA.data.count)
    }

    /// True when no consecutive pair differs in **sharpness** by more than noise — the lens never
    /// moved, and the bracket is one photograph repeated.
    public static func framesAreStatic(_ frames: [StackImage]) -> Bool {
        guard frames.count >= 2 else { return false }
        let readings = frames.map(sharpness(of:))
        for index in 1..<readings.count {
            if FocusMovement.moved(from: readings[index - 1], to: readings[index]) { return false }
        }
        return true
    }
}

/// Decides whether the lens actually moved between two focus measurements.
///
/// **Sharpness, never pixel difference.** Measured on real brackets from this rig: frames three
/// focus steps apart differ by 0.0048 in mean pixel luma, and frames where the lens never moved at
/// all differ by 0.0039 — the same number. Defocus is a high-frequency effect, so any downsampled
/// or whole-frame average washes it out. The same frames' *sharpness* differs by 6.5–20% when
/// moving and at most 0.35% when static, which is a clean order-of-magnitude separation.
///
/// This mistake has now been made twice in this codebase (once judging a focus-drive diagnostic,
/// once judging end-of-travel), so it lives here as one shared, tested decision.
public enum FocusMovement {
    /// Relative sharpness change that counts as real movement. Sits an order of magnitude above the
    /// worst static reading (0.35%) and well below the smallest real one (6.5%).
    public static let minimumRelativeChange = 0.02

    public static func moved(from before: Double, to after: Double) -> Bool {
        // Unmeasurable readings report "moved" on purpose. The two errors are not symmetric: a
        // false stall stops driving early and silently mis-counts the range, corrupting everything
        // downstream, while a false "moved" merely keeps going — and a bracket that ends up static
        // is caught by `FocusStackDiagnostics` at merge time.
        guard before > 0, after > 0, before.isFinite, after.isFinite else { return true }
        return abs(after - before) / Swift.max(before, after) >= minimumRelativeChange
    }
}
