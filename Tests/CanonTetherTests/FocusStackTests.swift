import XCTest
@testable import CanonTetherCore

/// Focus-stacking maths. These mirror the `swiftc` harness used during development (CLAUDE.md
/// records why local `swift test` can't be relied on here) so CI is the thing that actually guards
/// this code on every push.
final class FocusStackTests: XCTestCase {

    // MARK: - Fixtures

    /// Deterministic texture with energy in every frequency band.
    private func texture(_ w: Int, _ h: Int, channels: Int = 3, seed: UInt64 = 1) -> StackImage {
        var data = [Float](repeating: 0, count: w * h * channels)
        var rng = seed &* 2654435761 &+ 12345
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float((rng >> 33) % 1000) / 1000
        }
        for y in 0..<h {
            for x in 0..<w {
                let checker: Float = ((x / 2 + y / 2) % 2 == 0) ? 0.75 : 0.25
                let ramp = Float(x + y) / Float(w + h)
                let v = min(max(0.5 * checker + 0.4 * ramp + 0.1 * rand(), 0), 1)
                for c in 0..<channels { data[(y * w + x) * channels + c] = v }
            }
        }
        return StackImage(width: w, height: h, channels: channels, data: data)
    }

    /// Smooth, non-repeating scene — alignment must not be able to lock onto a periodic false match.
    private func scene(_ w: Int, _ h: Int) -> StackImage {
        var data = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
                let v = 0.5 + 0.22 * sin(fx * 7.1 + fy * 2.3) + 0.18 * cos(fy * 5.7 - fx * 1.9)
                    + 0.08 * sin(fx * 23 + fy * 19)
                for c in 0..<3 { data[(y * w + x) * 3 + c] = Float(min(max(v, 0), 1)) }
            }
        }
        return StackImage(width: w, height: h, channels: 3, data: data)
    }

    private func blurRegion(_ image: StackImage, xRange: Range<Int>, passes: Int) -> StackImage {
        var out = image
        let k = [Float](repeating: 1.0 / 9, count: 9)
        for _ in 0..<passes {
            let blurred = StackPyramid.convolve(out, kernel: k)
            for y in 0..<out.height {
                for x in xRange {
                    for c in 0..<out.channels {
                        let i = (y * out.width + x) * out.channels + c
                        out.data[i] = blurred.data[i]
                    }
                }
            }
        }
        return out
    }

    private func gradientEnergy(_ image: StackImage, xRange: Range<Int>) -> Double {
        var total = 0.0
        let w = image.width, c = image.channels
        for y in 1..<(image.height - 1) {
            for x in xRange where x > 0 && x < w - 1 {
                for ch in 0..<c {
                    let gx = image.data[(y * w + x + 1) * c + ch] - image.data[(y * w + x - 1) * c + ch]
                    let gy = image.data[((y + 1) * w + x) * c + ch] - image.data[((y - 1) * w + x) * c + ch]
                    total += Double(gx * gx + gy * gy)
                }
            }
        }
        return total
    }

    // MARK: - Pyramid

    /// The Laplacian pyramid must reconstruct exactly, including at odd sizes — an inexact pyramid
    /// silently costs the merge contrast rather than failing visibly.
    func testPyramidRoundTripIsExact() {
        for (w, h) in [(64, 64), (65, 33), (17, 40), (100, 71)] {
            let image = texture(w, h)
            let pyramid = StackPyramid.laplacianPyramid(
                image, levels: StackPyramid.levelCount(width: w, height: h))
            let back = StackPyramid.collapse(pyramid)
            XCTAssertEqual(back.width, w)
            XCTAssertEqual(back.height, h)
            var maxError: Float = 0
            for i in 0..<image.data.count {
                maxError = max(maxError, abs(image.data[i] - back.data[i]))
            }
            XCTAssertLessThan(maxError, 1e-4, "roundtrip error at \(w)x\(h)")
        }
    }

    /// Odd dimensions must round *up* through reduce, or expand can't get back to the original.
    func testReduceKeepsOddDimensions() {
        let reduced = StackPyramid.reduce(texture(65, 33, channels: 1))
        XCTAssertEqual(reduced.width, 33)
        XCTAssertEqual(reduced.height, 17)
    }

    /// Expand's kernel is doubled per axis to compensate for zero-stuffing; without that, every
    /// expanded level comes back dark. Interior only — the border legitimately sees fewer taps.
    func testExpandPreservesSignalLevel() {
        let source = texture(65, 33, channels: 1)
        let reduced = StackPyramid.reduce(source)
        let expanded = StackPyramid.expand(reduced, toWidth: 65, toHeight: 33)
        func interiorMean(_ image: StackImage, inset: Int) -> Float {
            var sum: Float = 0
            var n = 0
            for y in inset..<(image.height - inset) {
                for x in inset..<(image.width - inset) {
                    sum += image.data[(y * image.width + x) * image.channels]
                    n += 1
                }
            }
            return sum / Float(n)
        }
        XCTAssertEqual(interiorMean(reduced, inset: 2), interiorMean(expanded, inset: 4), accuracy: 0.02)
    }

    // MARK: - Merge

    /// The headline behaviour: two complementary half-blurred frames fuse to sharp everywhere.
    func testMergeRecoversSharpnessFromBothFrames() throws {
        let (w, h) = (128, 96)
        let base = texture(w, h)
        let sharpLeft = blurRegion(base, xRange: (w / 2)..<w, passes: 4)
        let sharpRight = blurRegion(base, xRange: 0..<(w / 2), passes: 4)
        let result = try FocusStackMerge.merge([sharpLeft, sharpRight])

        // The seam itself is skipped: a crossfade there is intended, not a defect.
        let margin = 8
        for (zone, sharp, soft) in [(margin..<(w / 2 - margin), sharpLeft, sharpRight),
                                    ((w / 2 + margin)..<(w - margin), sharpRight, sharpLeft)] {
            let merged = gradientEnergy(result.image, xRange: zone)
            XCTAssertGreaterThan(merged, gradientEnergy(soft, xRange: zone) * 3,
                                 "merge should beat the blurred frame")
            XCTAssertGreaterThan(merged, gradientEnergy(sharp, xRange: zone) * 0.85,
                                 "merge should retain the sharp frame's detail")
        }
    }

    /// Coverage must attribute each region to the frame that was actually sharp there.
    func testCoverageAttributesRegionsToTheSharpFrame() throws {
        let (w, h) = (128, 96)
        let base = texture(w, h)
        let result = try FocusStackMerge.merge([
            blurRegion(base, xRange: (w / 2)..<w, passes: 4),
            blurRegion(base, xRange: 0..<(w / 2), passes: 4)
        ])
        let coverage = result.coverage
        XCTAssertEqual(coverage.sourceCount, 2)

        var leftCorrect = 0, leftTotal = 0, rightCorrect = 0, rightTotal = 0
        for y in 0..<coverage.height {
            for x in 0..<coverage.width {
                let fraction = Double(x) / Double(coverage.width)
                let winner = coverage.winner[y * coverage.width + x]
                if fraction < 0.35 { leftTotal += 1; if winner == 0 { leftCorrect += 1 } }
                if fraction > 0.65 { rightTotal += 1; if winner == 1 { rightCorrect += 1 } }
            }
        }
        XCTAssertGreaterThan(Double(leftCorrect) / Double(leftTotal), 0.9)
        XCTAssertGreaterThan(Double(rightCorrect) / Double(rightTotal), 0.9)
        XCTAssertEqual(coverage.shares().count, 2)
        XCTAssertTrue(coverage.shares().allSatisfy { $0 > 0.3 }, "both frames should contribute")
    }

    /// Merging identical frames must be a no-op — not a brightness or contrast shift.
    func testMergingIdenticalFramesChangesNothing() throws {
        let base = texture(64, 48)
        let merged = try FocusStackMerge.merge([base, base, base])
        var maxDelta: Float = 0
        for i in 0..<base.data.count {
            maxDelta = max(maxDelta, abs(base.data[i] - merged.image.data[i]))
        }
        XCTAssertLessThan(maxDelta, 1e-3)
    }

    /// A flat frame has no sharpness signal at all: the weight normalisation must not divide by
    /// zero, and the result must stay flat rather than filling with NaN.
    func testFlatFramesStayFlat() throws {
        let flat = StackImage(width: 32, height: 32, channels: 3,
                              data: [Float](repeating: 0.5, count: 32 * 32 * 3))
        let merged = try FocusStackMerge.merge([flat, flat])
        XCTAssertTrue(merged.image.data.allSatisfy { $0.isFinite && abs($0 - 0.5) < 1e-3 })
    }

    func testMergeRejectsEmptyAndMismatchedInput() {
        XCTAssertThrowsError(try FocusStackMerge.merge([]))
        XCTAssertThrowsError(try FocusStackMerge.merge([texture(16, 16), texture(20, 16)]))
    }

    // MARK: - Alignment

    /// Known transforms of the magnitude real focus breathing produces must be recovered to under
    /// a pixel of residual displacement.
    func testAlignmentRecoversKnownTransforms() {
        let base = scene(240, 180)
        let truths: [(String, SimilarityTransform)] = [
            ("shift", SimilarityTransform(scale: 1, tx: 3, ty: -2)),
            ("breathe", SimilarityTransform(scale: 1.012, tx: 0, ty: 0)),
            ("breathe + shift", SimilarityTransform(scale: 0.991, tx: -2.5, ty: 1.5)),
            ("identity", .identity)
        ]
        for (name, truth) in truths {
            let moved = FocusStackAlign.warp(base, by: truth)
            let fit = FocusStackAlign.estimate(moving: moved, fixed: base)
            XCTAssertTrue(fit.isTrusted, "\(name) should be a trusted fit (r=\(fit.correlation))")
            // The fit should invert the truth: truth.source ∘ fit.source == identity, which is
            // exactly fit.concatenated(with: truth). Residual displacement is the honest measure —
            // scale and translation trade off, so only their net effect matters.
            let residual = fit.transform.concatenated(with: truth)
                .maxDisplacement(width: base.width, height: base.height)
            XCTAssertLessThan(residual, 1.0, "\(name) residual \(residual)px")
        }
    }

    /// A whole bracket aligned onto its middle frame.
    func testAlignmentChainRegistersEveryFrame() {
        let base = scene(240, 180)
        let frames = (0..<5).map { i -> StackImage in
            let step = Double(i - 2)
            return FocusStackAlign.warp(base, by: SimilarityTransform(
                scale: 1 + 0.006 * step, tx: 1.2 * step, ty: -0.8 * step))
        }
        let fits = FocusStackAlign.align(frames)
        XCTAssertEqual(fits.count, 5)
        XCTAssertEqual(fits[2].transform, .identity, "the reference frame shouldn't move")
        for i in 0..<5 {
            XCTAssertTrue(fits[i].isTrusted)
            let corrected = FocusStackAlign.warp(frames[i], by: fits[i].transform)
            let after = FocusStackAlign.correlation(
                moving: corrected.luma(), fixed: frames[2].luma(), .identity)
            XCTAssertGreaterThan(after, 0.995, "frame \(i) should land on the reference")
        }
    }

    /// Frames that genuinely don't correspond must be reported untrusted rather than forced into a
    /// transform, and a bad link must not poison the rest of the chain.
    func testUncorrelatedFramesAreFlaggedAndDoNotPoisonTheChain() {
        let base = scene(240, 180)
        var noise = base
        var seed: UInt64 = 99
        for i in 0..<noise.data.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise.data[i] = Float((seed >> 33) % 1000) / 1000
        }
        XCTAssertFalse(FocusStackAlign.estimate(moving: noise, fixed: base).isTrusted)

        var frames = (0..<5).map { i -> StackImage in
            let step = Double(i - 2)
            return FocusStackAlign.warp(base, by: SimilarityTransform(
                scale: 1 + 0.006 * step, tx: 1.2 * step, ty: -0.8 * step))
        }
        let reference = frames[2]
        frames[3] = noise
        let fits = FocusStackAlign.align(frames)
        XCTAssertFalse(fits[3].isTrusted)
        XCTAssertFalse(fits[4].isTrusted, "a frame downstream of a bad link is also uncertain")
        let recovered = FocusStackAlign.warp(frames[4], by: fits[4].transform)
        let correlation = FocusStackAlign.correlation(
            moving: recovered.luma(), fixed: reference.luma(), .identity)
        XCTAssertGreaterThan(correlation, 0.9, "the bad link shouldn't drag frame 4 off the scene")
    }

    func testIdentityWarpIsANoOp() {
        let base = scene(64, 48)
        XCTAssertEqual(FocusStackAlign.warp(base, by: .identity).data, base.data)
    }

    func testTransformCompositionMatchesSequentialWarps() {
        let base = scene(240, 180)
        let a = SimilarityTransform(scale: 1.01, tx: 2, ty: -1)
        let b = SimilarityTransform(scale: 0.995, tx: -1.5, ty: 0.5)
        let sequential = FocusStackAlign.warp(FocusStackAlign.warp(base, by: b), by: a)
        let atOnce = FocusStackAlign.warp(base, by: a.concatenated(with: b))
        var maxDiff: Float = 0
        for y in 20..<(base.height - 20) {
            for x in 20..<(base.width - 20) {
                let i = (y * base.width + x) * base.channels
                maxDiff = max(maxDiff, abs(sequential.data[i] - atOnce.data[i]))
            }
        }
        XCTAssertLessThan(maxDiff, 0.02)
    }

    // MARK: - Plan and capability

    /// Choice matching is on direction + magnitude, not an exact string, because the spelling has
    /// varied between libgphoto2 versions.
    func testFocusStepMatchesCameraChoiceSpellings() {
        let canonical = ["None", "Near 1", "Near 2", "Near 3", "Far 1", "Far 2", "Far 3"]
        XCTAssertEqual(FocusStep.choice(for: .nearSmall, in: canonical), "Near 1")
        XCTAssertEqual(FocusStep.choice(for: .farLarge, in: canonical), "Far 3")

        let alternate = ["none", "near1", "near2", "near3", "far1", "far2", "far3"]
        XCTAssertEqual(FocusStep.choice(for: .nearMedium, in: alternate), "near2")
        XCTAssertEqual(FocusStep.choice(for: .farSmall, in: alternate), "far1")

        XCTAssertNil(FocusStep.choice(for: .nearSmall, in: ["None"]))
    }

    /// A body listing only "None" has the property but cannot drive focus — the UI must be able to
    /// tell that apart from real support, or a bracket shoots N identical frames.
    func testDrivabilityNeedsBothDirections() {
        XCTAssertTrue(FocusStep.isDrivable(choices: ["Near 1", "Far 1"]))
        XCTAssertFalse(FocusStep.isDrivable(choices: ["None"]))
        XCTAssertFalse(FocusStep.isDrivable(choices: ["Near 1", "Near 2"]))
        XCTAssertFalse(FocusStep.isDrivable(choices: []))
    }

    func testStepReversalFlipsDirectionAndKeepsMagnitude() {
        for step in FocusStep.allCases {
            XCTAssertEqual(step.reversed.magnitude, step.magnitude)
            XCTAssertNotEqual(step.reversed.isNear, step.isNear)
            XCTAssertEqual(step.reversed.reversed, step)
        }
    }

    /// The plan clamps every field, so a stale or hand-edited defaults entry can't put the UI into
    /// a state its own steppers can't represent.
    /// The default must step **away** from the camera: stacking is shot by focusing the nearest
    /// part of the subject and walking focus back through it, so a default that racks toward the
    /// camera runs off the subject — and it is invisible until the merge comes out wrong.
    func testDefaultPlanStepsAwayFromTheCamera() {
        let plan = FocusStackPlan()
        XCTAssertFalse(plan.step.isNear)
        XCTAssertEqual(plan.step.magnitude, 1, "default should be the finest step")
        XCTAssertTrue(plan.summary.contains("away from the camera"), plan.summary)
        XCTAssertTrue(plan.summary.contains("nearest"), "should say where to set focus first")
    }

    /// Direction and size are separate controls in the UI, so the two must recombine into every
    /// step exactly — a dropped combination would silently fall back to some other step.
    func testStepConstructionFromDirectionAndMagnitude() {
        for step in FocusStep.allCases {
            XCTAssertEqual(FocusStep.step(towardCamera: step.isNear, magnitude: step.magnitude), step)
        }
        // Out-of-range magnitudes clamp rather than falling through to an unrelated step.
        XCTAssertEqual(FocusStep.step(towardCamera: true, magnitude: 0), .nearSmall)
        XCTAssertEqual(FocusStep.step(towardCamera: true, magnitude: 9), .nearLarge)
        XCTAssertEqual(FocusStep.step(towardCamera: false, magnitude: 9), .farLarge)
    }

    func testPlanClampsOutOfRangeValues() {
        let plan = FocusStackPlan(frameCount: 999, stepsPerFrame: 0, settleSeconds: 99)
        XCTAssertEqual(plan.frameCount, FocusStackPlan.frameRange.upperBound)
        XCTAssertEqual(plan.stepsPerFrame, FocusStackPlan.stepsPerFrameRange.lowerBound)
        XCTAssertEqual(plan.settleSeconds, FocusStackPlan.settleRange.upperBound)
    }

    func testPlanStepArithmetic() {
        let plan = FocusStackPlan(frameCount: 8, stepsPerFrame: 2, returnToStart: true)
        XCTAssertEqual(plan.totalSteps, 14, "seven gaps between eight frames, two nudges each")
        XCTAssertEqual(plan.returnSteps, 14)

        let oneWay = FocusStackPlan(frameCount: 8, stepsPerFrame: 2, returnToStart: false)
        XCTAssertEqual(oneWay.returnSteps, 0)
        XCTAssertGreaterThan(plan.estimatedSeconds(secondsPerFrame: 2),
                             oneWay.estimatedSeconds(secondsPerFrame: 2))
    }

    // MARK: - Static-bracket detection

    /// The failure this guards against: with the body in an AF mode the camera acknowledges every
    /// focus command and the lens never moves, so the bracket is N copies of one photograph. Real
    /// measurement from such a bracket: consecutive frames differed by 0.0015–0.002.
    func testIdenticalFramesAreDetectedAsStatic() {
        let base = texture(96, 72)
        var noisy = base
        var seed: UInt64 = 7
        for i in 0..<noisy.data.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noisy.data[i] += Float((seed >> 33) % 100) / 100 * 0.004   // sensor-noise scale
        }
        XCTAssertTrue(FocusStackDiagnostics.framesAreStatic([base, noisy, base]))
        XCTAssertFalse(FocusMovement.moved(from: FocusStackDiagnostics.sharpness(of: base),
                                           to: FocusStackDiagnostics.sharpness(of: noisy)))
    }

    /// A bracket that really did rack focus must never be flagged — a false positive here tells the
    /// photographer their working setup is broken.
    func testFramesWithRealFocusChangeAreNotStatic() {
        let sharp = texture(96, 72)
        let blurred = blurRegion(sharp, xRange: 0..<96, passes: 3)
        XCTAssertFalse(FocusStackDiagnostics.framesAreStatic([sharp, blurred]))
        XCTAssertTrue(FocusMovement.moved(from: FocusStackDiagnostics.sharpness(of: sharp),
                                          to: FocusStackDiagnostics.sharpness(of: blurred)))
    }

    func testStaticDetectionNeedsTwoFrames() {
        XCTAssertFalse(FocusStackDiagnostics.framesAreStatic([texture(32, 32)]))
        XCTAssertFalse(FocusStackDiagnostics.framesAreStatic([]))
    }

    // MARK: - Movement detection

    /// Calibrated against real brackets from the rig, and the reason this is sharpness-based.
    ///
    /// Pixel difference cannot do this job: measured, frames three focus steps apart differ by
    /// 0.0048 in mean luma while frames where the lens never moved differ by 0.0039 — so a detector
    /// built on pixel difference called *everything* stalled. Sharpness separates the same frames by
    /// an order of magnitude.
    func testMovementDetectionOnRealBracketSharpness() {
        // Lens genuinely racking: three focus steps between consecutive frames.
        let moving = [17.706, 16.561, 14.238, 11.796, 9.491, 7.572, 6.178, 5.329]
        for index in 1..<moving.count {
            XCTAssertTrue(FocusMovement.moved(from: moving[index - 1], to: moving[index]),
                          "pair \(index) should read as movement")
        }

        // Lens against an end stop: the camera acknowledged every nudge and nothing moved.
        let static_ = [38.173, 38.247, 38.253, 38.385, 38.521, 38.703, 38.868, 38.948]
        for index in 1..<static_.count {
            XCTAssertFalse(FocusMovement.moved(from: static_[index - 1], to: static_[index]),
                           "pair \(index) should read as stalled")
        }
    }

    /// An unreadable measurement must report movement, not stalling. The errors aren't symmetric: a
    /// false stall mis-counts the range and corrupts every later step, while a false "moved" only
    /// keeps driving — and a static bracket is caught at merge time anyway.
    func testUnmeasurableReadingsReportMovement() {
        XCTAssertTrue(FocusMovement.moved(from: 0, to: 0))
        XCTAssertTrue(FocusMovement.moved(from: .nan, to: 12))
        XCTAssertTrue(FocusMovement.moved(from: 12, to: .infinity))
        XCTAssertTrue(FocusMovement.moved(from: -1, to: 12))
    }

    func testMovementThresholdBoundary() {
        XCTAssertFalse(FocusMovement.moved(from: 100, to: 101))          // 1%
        XCTAssertTrue(FocusMovement.moved(from: 100, to: 103))           // 3%
        XCTAssertTrue(FocusMovement.moved(from: 103, to: 100))           // symmetric
    }

    // MARK: - Critique

    func testCritiqueReportsGapsAndWastedFrames() {
        // Full coverage, both frames pulling their weight.
        let good = CoverageMap(width: 2, height: 2, sourceCount: 2,
                               winner: [0, 0, 1, 1], confidence: [1, 1, 1, 1])
        XCTAssertEqual(FocusStackCritique(coverage: good).verdicts, [.good])

        // Low confidence everywhere is *not* a defect verdict any more. The winner's share falls
        // as frames are added, so judging it told photographers to shoot more frames precisely
        // when they already had enough.
        let lowConfidence = CoverageMap(width: 2, height: 2, sourceCount: 2,
                                        winner: [0, 0, 1, 1], confidence: [0.1, 0.1, 0.1, 0.1])
        XCTAssertEqual(FocusStackCritique(coverage: lowConfidence).verdicts, [.good],
                       "a merge cannot know whether a denser bracket would have been sharper")

        // Three frames where the first contributes nothing: the bracket started too far away.
        let wastedStart = CoverageMap(width: 4, height: 1, sourceCount: 3,
                                      winner: [1, 1, 2, 2], confidence: [1, 1, 1, 1])
        XCTAssertTrue(FocusStackCritique(coverage: wastedStart).verdicts.contains(.wastedAtStart(frames: 1)))

        let wastedEnd = CoverageMap(width: 4, height: 1, sourceCount: 3,
                                    winner: [0, 0, 1, 1], confidence: [1, 1, 1, 1])
        XCTAssertTrue(FocusStackCritique(coverage: wastedEnd).verdicts.contains(.wastedAtEnd(frames: 1)))

        XCTAssertFalse(FocusStackCritique(coverage: good).advice.isEmpty)
    }

    /// Progress reporting drives a determinate bar, so it must stay in range even if a phase
    /// reports a frame number beyond the planned count.
    func testBracketProgressFractionStaysInRange() {
        let over = FocusBracketProgress(phase: .capturing(frame: 99, of: 8), framesCaptured: 8)
        XCTAssertEqual(over.fraction(of: 8), 1)
        XCTAssertEqual(FocusBracketProgress(phase: .preparing, framesCaptured: 0).fraction(of: 8), 0)
        XCTAssertEqual(FocusBracketProgress(phase: .finished, framesCaptured: 8).fraction(of: 8), 1)
        XCTAssertNil(FocusBracketProgress(phase: .preparing, framesCaptured: 0).fraction(of: 0))
    }

    func testCapabilityExplainsOnlyFailures() {
        XCTAssertNil(FocusDriveCapability.available(choices: ["Near 1", "Far 1"]).explanation)
        XCTAssertNotNil(FocusDriveCapability.unsupported.explanation)
        XCTAssertNotNil(FocusDriveCapability.presentButNotDrivable.explanation)
        XCTAssertNotNil(FocusDriveCapability.unknown(reason: "busy").explanation)
        XCTAssertNotNil(FocusDriveCapability.lensSwitchInManualFocus(lens: nil).explanation)
    }

    /// The barrel-switch case must name the lens and point at the switch — not at the body's focus
    /// mode, which is the state stacking actually needs and must never be reported as the fault.
    func testLensSwitchMessageNamesTheLensAndTheSwitch() throws {
        let message = try XCTUnwrap(
            FocusDriveCapability.lensSwitchInManualFocus(lens: "EF 85mm f/1.8 USM").explanation)
        XCTAssertTrue(message.contains("EF 85mm f/1.8 USM"), message)
        XCTAssertTrue(message.lowercased().contains("switch"), message)
        XCTAssertNotEqual(FocusDriveCapability.lensSwitchInManualFocus(lens: nil),
                          FocusDriveCapability.presentButNotDrivable)
    }
}

/// Coverage advice must describe the subject, not the bokeh.
final class FocusCoverageRegionTests: XCTestCase {

    /// A stack that nails its subject against a deliberately blurred background reported "51% of
    /// the frame was never sharp" — true of the frame, meaningless as advice.
    func testCoverageIgnoresTheBackgroundWhenASubjectIsMarked() {
        let w = 20, h = 20
        var confidence = [Float](repeating: 0, count: w * h)   // background: never sharp
        for row in 6..<14 {
            for column in 6..<14 { confidence[row * w + column] = 1 }   // subject: fully covered
        }
        let map = CoverageMap(width: w, height: h, sourceCount: 3,
                              winner: [Int](repeating: 0, count: w * h), confidence: confidence)

        let wholeFrame = map.coverageFraction()
        XCTAssertLessThan(wholeFrame, 0.25, "most of the frame is background and legitimately soft")

        let subject = map.coverageFraction(region: (x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertGreaterThan(subject, 0.9, "the subject itself is covered")
    }

    /// The one thing a single merge *can* establish about its own range: an end frame that keeps
    /// winning instead of handing over to a neighbour means the subject ran past the bracket.
    func testRangeClippedAtEitherEndIsReported() {
        // Ten cells, three frames. The last frame holds four of them — it never handed over.
        let clippedEnd = CoverageMap(width: 10, height: 1, sourceCount: 3,
                                     winner: [0, 1, 1, 1, 1, 1, 2, 2, 2, 2],
                                     confidence: [Float](repeating: 1, count: 10))
        XCTAssertTrue(clippedEnd.verdictsContainClippedEnd,
                      "the subject continues past where the bracket stopped")

        let clippedStart = CoverageMap(width: 10, height: 1, sourceCount: 3,
                                       winner: [0, 0, 0, 0, 1, 1, 1, 1, 1, 2],
                                       confidence: [Float](repeating: 1, count: 10))
        XCTAssertTrue(FocusStackCritique(coverage: clippedStart).verdicts.contains {
            if case .rangeClippedAtStart = $0 { return true }; return false
        })

        // A bracket that hands over cleanly at both ends is not criticised.
        let clean = CoverageMap(width: 10, height: 1, sourceCount: 3,
                                winner: [0, 1, 1, 1, 1, 1, 1, 1, 2, 2],
                                confidence: [Float](repeating: 1, count: 10))
        XCTAssertFalse(FocusStackCritique(coverage: clean).verdicts.contains {
            if case .rangeClippedAtStart = $0 { return true }; return false
        })
    }
}

private extension CoverageMap {
    var verdictsContainClippedEnd: Bool {
        FocusStackCritique(coverage: self).verdicts.contains {
            if case .rangeClippedAtEnd = $0 { return true }
            return false
        }
    }
}
