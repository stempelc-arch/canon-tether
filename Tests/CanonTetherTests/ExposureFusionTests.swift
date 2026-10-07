import XCTest
@testable import CanonTetherCore

/// Exposure fusion: take each part of the picture from whichever exposure rendered it well, rather
/// than merging to radiance and inventing a rendering afterwards.
final class ExposureFusionTests: XCTestCase {

    private func flat(_ value: Float, width: Int = 32, height: Int = 32) -> StackImage {
        var image = StackImage(width: width, height: height, channels: 3)
        for i in 0..<image.data.count { image.data[i] = value }
        return image
    }

    /// Mid-grey is what a correctly-exposed frame looks like; the ends carry noise or nothing.
    func testWellExposednessPrefersTheMiddle() {
        XCTAssertGreaterThan(ExposureFusion.wellExposedness(0.5), ExposureFusion.wellExposedness(0.1))
        XCTAssertGreaterThan(ExposureFusion.wellExposedness(0.5), ExposureFusion.wellExposedness(0.95))
        XCTAssertEqual(ExposureFusion.wellExposedness(0.3), ExposureFusion.wellExposedness(0.7),
                       accuracy: 1e-5, "symmetric about mid-grey")
    }

    /// Weighting channels separately would pull a saturated colour toward whichever frame placed
    /// *that channel* near mid-grey, which shifts hue. Weights come from luminance.
    func testWeightsComeFromLuminance() {
        var red = StackImage(width: 2, height: 1, channels: 3)
        red.data = [1, 0, 0, 1, 0, 0]
        let weights = ExposureFusion.weights(for: red)
        XCTAssertEqual(weights.channels, 1)
        XCTAssertEqual(weights.data[0], weights.data[1])
        // Luma of pure red is 0.2126, so it is treated as a dark pixel, not a blown one.
        XCTAssertEqual(weights.data[0], ExposureFusion.wellExposedness(0.2126), accuracy: 1e-5)
    }

    /// A bracket of identical frames must come back as that frame — the fusion adds nothing of its
    /// own when there is nothing to choose between.
    func testIdenticalFramesFuseToThemselves() throws {
        let frames = [flat(0.45), flat(0.45), flat(0.45)]
        let fused = try ExposureFusion.fuse(frames)
        for value in fused.data { XCTAssertEqual(value, 0.45, accuracy: 0.02) }
    }

    /// The point of the whole thing: where one frame is blown and another is correct, the correct
    /// one wins.
    func testTakesTheWellExposedFrame() throws {
        let blown = flat(0.99)
        let good = flat(0.5)
        let black = flat(0.01)
        let fused = try ExposureFusion.fuse([blown, good, black])
        for value in fused.data {
            XCTAssertEqual(value, 0.5, accuracy: 0.08, "the usable exposure dominates")
        }
    }

    /// Output must stay inside the display range — it is a picture, not a radiance map.
    func testOutputStaysInRange() throws {
        var bright = StackImage(width: 16, height: 16, channels: 3)
        var dark = bright
        for i in 0..<bright.data.count {
            bright.data[i] = Float(i % 7) / 6
            dark.data[i] = Float((i * 3) % 5) / 4
        }
        let fused = try ExposureFusion.fuse([bright, dark])
        XCTAssertTrue(fused.data.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testRejectsAnUnusableBracket() {
        XCTAssertThrowsError(try ExposureFusion.fuse([flat(0.5)])) { error in
            XCTAssertEqual(error as? ExposureFusion.FusionError, .needsTwoFrames)
        }
        var odd = StackImage(width: 4, height: 4, channels: 3)
        odd.data = [Float](repeating: 0.5, count: odd.data.count)
        XCTAssertThrowsError(try ExposureFusion.fuse([flat(0.5), odd])) { error in
            XCTAssertEqual(error as? ExposureFusion.FusionError, .sizeMismatch)
        }
    }
}
