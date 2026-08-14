import XCTest
@testable import CanonTetherCore   // reaches the internal Colorimetry helper for the wide-gamut test

/// The scopes are a measurement tool, so what's checked here is where a known colour lands, not
/// how it looks: a grey card on the 50 % line and dead centre, 75 % bars in their graticule boxes,
/// and nothing the camera can produce falling off the edge of the plot.
final class ScopeAnalysisTests: XCTestCase {

    private let waveformHeight = 250
    private let vectorSize = 320

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int = 64, height: Int = 64) -> ScopeFrame {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { pixels.append(contentsOf: [r, g, b, 255]) }
        return ScopeFrame(width: width, height: height, bytes: pixels)
    }

    /// The row carrying the most light in one waveform column.
    private func brightestRow(_ raster: ScopeRaster, column: Int) -> Int {
        var best = 0, bestValue = -1
        for row in 0..<raster.height {
            let offset = (row * raster.width + column) * 4
            let value = Int(raster.rgba[offset]) + Int(raster.rgba[offset + 1]) + Int(raster.rgba[offset + 2])
            if value > bestValue { bestValue = value; best = row }
        }
        return best
    }

    /// The brightest cell in a vectorscope, as a point. Total brightness rather than one channel:
    /// the trace is colourised, so a red arm has almost nothing in green.
    private func peak(_ raster: ScopeRaster) -> (x: Int, y: Int) {
        var best = (x: 0, y: 0, value: -1)
        for row in 0..<raster.height {
            for column in 0..<raster.width {
                let offset = (row * raster.width + column) * 4
                let value = Int(raster.rgba[offset]) + Int(raster.rgba[offset + 1]) + Int(raster.rgba[offset + 2])
                if value > best.value { best = (column, row, value) }
            }
        }
        return (best.x, best.y)
    }

    private func colour(_ raster: ScopeRaster, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * raster.width + x) * 4
        return (Int(raster.rgba[offset]), Int(raster.rgba[offset + 1]), Int(raster.rgba[offset + 2]))
    }

    // MARK: - Waveform

    func testMidGreyPlotsHalfwayUp() {
        let raster = ScopeRenderer.waveform(solid(128, 128, 128), mode: .luma,
                                            width: 128, height: waveformHeight)
        XCTAssertEqual(brightestRow(raster, column: 64), (255 - 128) * (waveformHeight - 1) / 255)
    }

    func testBlackAndWhitePinToTheEdges() {
        let black = ScopeRenderer.waveform(solid(0, 0, 0), mode: .luma, width: 128, height: waveformHeight)
        let white = ScopeRenderer.waveform(solid(255, 255, 255), mode: .luma, width: 128, height: waveformHeight)
        XCTAssertEqual(brightestRow(black, column: 10), waveformHeight - 1)
        XCTAssertEqual(brightestRow(white, column: 10), 0)
    }

    func testTraceIsBrightAndEmptyCellsStayDark() {
        let raster = ScopeRenderer.waveform(solid(128, 128, 128), mode: .luma,
                                            width: 128, height: waveformHeight)
        let row = brightestRow(raster, column: 64)
        XCTAssertGreaterThan(raster.rgba[(row * raster.width + 64) * 4 + 1], 200)
        XCTAssertLessThan(raster.rgba[((row + 20) * raster.width + 64) * 4 + 1], 30)
    }

    func testParadeSplitsChannelsIntoThreePanels() {
        // Pure red: the R panel pegs at 100 %, the other two sit on the floor.
        let raster = ScopeRenderer.waveform(solid(255, 0, 0), mode: .parade, width: 300, height: waveformHeight)
        XCTAssertEqual(brightestRow(raster, column: 50), 0)
        XCTAssertEqual(brightestRow(raster, column: 150), waveformHeight - 1)
        XCTAssertEqual(brightestRow(raster, column: 250), waveformHeight - 1)

        // …and the R panel's trace is tinted red, not white.
        let cell = 50 * 4
        XCTAssertGreaterThan(raster.rgba[cell], 200)
        XCTAssertGreaterThan(raster.rgba[cell], 2 * raster.rgba[cell + 1])
    }

    // MARK: - Vectorscope

    func testNeutralGreySitsAtTheCentre() {
        let raster = ScopeRenderer.vectorscope(solid(128, 128, 128), size: vectorSize)
        let point = peak(raster)
        XCTAssertLessThanOrEqual(abs(point.x - vectorSize / 2), 1)
        XCTAssertLessThanOrEqual(abs(point.y - vectorSize / 2), 1)

        // Colourised, a neutral has no hue to show: the centre reads white.
        let centre = colour(raster, x: point.x, y: point.y)
        XCTAssertGreaterThan(centre.r, 200)
        XCTAssertLessThanOrEqual(abs(centre.r - centre.g), 12)
        XCTAssertLessThanOrEqual(abs(centre.r - centre.b), 12)
    }

    /// Each arm is drawn in the colour it represents, so a saturated frame paints its own hue.
    func testTraceIsColourisedByHue() {
        let cases: [(name: String, rgb: (UInt8, UInt8, UInt8), dominant: KeyPath<(r: Int, g: Int, b: Int), Int>)] = [
            ("red", (191, 0, 0), \.r),
            ("green", (0, 191, 0), \.g),
            ("blue", (0, 0, 191), \.b)
        ]
        for testCase in cases {
            let raster = ScopeRenderer.vectorscope(
                solid(testCase.rgb.0, testCase.rgb.1, testCase.rgb.2), size: vectorSize)
            let point = peak(raster)
            let painted = colour(raster, x: point.x, y: point.y)
            let dominant = painted[keyPath: testCase.dominant]
            let others = [painted.r, painted.g, painted.b].reduce(0, +) - dominant
            XCTAssertGreaterThan(dominant, 180, "\(testCase.name) arm is too dim")
            XCTAssertGreaterThan(dominant * 2, others, "\(testCase.name) arm isn't dominated by its own channel")
        }
    }

    /// Enlarging the plot spreads the same hits over more cells; the gain compensates, so the trace
    /// doesn't fade out as the panel grows.
    func testTraceKeepsItsBrightnessAtLargerRasterSizes() {
        let frame = solid(191, 0, 0, width: 128, height: 128)
        for size in [320, 512, 768] {
            let raster = ScopeRenderer.vectorscope(frame, size: size)
            let point = peak(raster)
            XCTAssertGreaterThan(colour(raster, x: point.x, y: point.y).r, 180,
                                 "trace faded at raster size \(size)")
        }
    }

    func testSeventyFivePercentBarsLandOnTheirTargets() {
        let bars: [(String, UInt8, UInt8, UInt8)] = [
            ("R", 191, 0, 0), ("Yl", 191, 191, 0), ("G", 0, 191, 0),
            ("Cy", 0, 191, 191), ("B", 0, 0, 191), ("Mg", 191, 0, 191)
        ]
        let radius = Double(vectorSize) / 2
        for (name, r, g, b) in bars {
            let point = peak(ScopeRenderer.vectorscope(solid(r, g, b), size: vectorSize))
            guard let target = ScopeRenderer.vectorTargets.first(where: { $0.name == name }) else {
                return XCTFail("no graticule target named \(name)")
            }
            let dx = Double(point.x) - (radius + target.x * radius)
            let dy = Double(point.y) - (radius + target.y * radius)
            // Within the 8 px target box the graticule draws.
            XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), 4, "\(name) bar missed its box")
        }
    }

    /// The gain is set so nothing in sRGB can plot outside the graticule ring and be clipped away —
    /// 100 % green and magenta are the furthest-out colours that exist, at ~0.89 of the radius.
    func testFullySaturatedColoursStayInsideTheRing() {
        let primaries: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 255, 255), (255, 0, 255), (255, 255, 0)
        ]
        let radius = Double(vectorSize) / 2
        for (r, g, b) in primaries {
            let point = peak(ScopeRenderer.vectorscope(solid(r, g, b), size: vectorSize))
            let dx = Double(point.x) - radius, dy = Double(point.y) - radius
            let distance = (dx * dx + dy * dy).squareRoot() / radius
            XCTAssertGreaterThan(distance, 0.6, "(\(r),\(g),\(b)) plotted too close to the centre")
            XCTAssertLessThan(distance, 0.95, "(\(r),\(g),\(b)) plotted outside the ring")
        }
    }

    func testSkinToneLineRunsBetweenRedAndYellow() {
        func compassAngle(_ x: Double, _ y: Double) -> Double { atan2(-y, x) * 180 / .pi }
        let red = ScopeRenderer.vectorTargets.first { $0.name == "R" }!
        let yellow = ScopeRenderer.vectorTargets.first { $0.name == "Yl" }!
        XCTAssertGreaterThan(ScopeRenderer.skinToneAngleDegrees, compassAngle(red.x, red.y))
        XCTAssertLessThan(ScopeRenderer.skinToneAngleDegrees, compassAngle(yellow.x, yellow.y))
    }

    // MARK: - Gamut boundary

    private func vertex(_ hex: [ScopePoint], _ name: String) -> ScopePoint {
        // Order returned by gamutBoundary: R, Yl, G, Cy, B, Mg.
        hex[["R", "Yl", "G", "Cy", "B", "Mg"].firstIndex(of: name)!]
    }

    func testSRGBBoundaryMatchesWhereFullPrimariesPlot() {
        // The sRGB hexagon must sit exactly where 100 % sRGB pixels land in the trace, so it reads
        // as a true "inside = legal" line.
        let hex = ScopeRenderer.gamutBoundary(.sRGB)
        for (name, rgb) in [("R", (UInt8(255), UInt8(0), UInt8(0))),
                            ("G", (UInt8(0), UInt8(255), UInt8(0))),
                            ("B", (UInt8(0), UInt8(0), UInt8(255)))] {
            let point = peak(ScopeRenderer.vectorscope(solid(rgb.0, rgb.1, rgb.2), size: vectorSize))
            let radius = Double(vectorSize) / 2
            let traceRadius = ((Double(point.x) - radius) * (Double(point.x) - radius) +
                               (Double(point.y) - radius) * (Double(point.y) - radius)).squareRoot() / radius
            XCTAssertEqual(vertex(hex, name).radius, traceRadius, accuracy: 0.03,
                           "sRGB \(name) boundary should match the 100 % \(name) trace")
        }
    }

    func testWiderGamutsReachPastSRGB() {
        let sRGB = ScopeRenderer.gamutBoundary(.sRGB)
        let adobe = ScopeRenderer.gamutBoundary(.adobeRGB)
        let p3 = ScopeRenderer.gamutBoundary(.displayP3)
        // The wider spaces' green primaries are their most out-of-sRGB corner.
        XCTAssertGreaterThan(vertex(adobe, "G").radius, vertex(sRGB, "G").radius + 0.05)
        XCTAssertGreaterThan(vertex(p3, "G").radius, vertex(sRGB, "G").radius + 0.05)
        XCTAssertGreaterThan(vertex(p3, "R").radius, vertex(sRGB, "R").radius + 0.02)
        // Adobe shares sRGB's red chromaticity, so same hue angle even though it's a brighter primary.
        XCTAssertEqual(atan2(-vertex(adobe, "R").y, vertex(adobe, "R").x),
                       atan2(-vertex(sRGB, "R").y, vertex(sRGB, "R").x), accuracy: 0.02)
    }

    /// A wide-gamut source must actually push the trace past the sRGB hexagon — the whole reason for
    /// extended-range sampling. Synthesise an Adobe-RGB-saturated green as the extended-sRGB values
    /// it becomes, and confirm it plots beyond sRGB green and out toward the Adobe boundary.
    func testWideGamutContentPlotsBeyondSRGB() {
        // Adobe RGB green (its 100 % green corner) expressed in extended sRGB.
        let toSRGB = Colorimetry.gamutToSRGBLinear(.adobeRGB)
        let lin = toSRGB.apply((0, 1, 0))
        let g = ScopeFrame(width: 32, height: 32, rgba: (0..<(32 * 32)).flatMap { _ in
            [Float(Colorimetry.encodeSRGB(lin.0)), Float(Colorimetry.encodeSRGB(lin.1)),
             Float(Colorimetry.encodeSRGB(lin.2)), 1]
        })
        let point = peak(ScopeRenderer.vectorscope(g, size: vectorSize))
        let radius = Double(vectorSize) / 2
        let traceRadius = ((Double(point.x) - radius) * (Double(point.x) - radius) +
                           (Double(point.y) - radius) * (Double(point.y) - radius)).squareRoot() / radius
        // Note: clamped at the raster edge (radius 1.0), but that's still well past sRGB green (~0.89).
        XCTAssertGreaterThan(traceRadius, ScopeRenderer.gamutBoundary(.sRGB)[2].radius)
    }

    // MARK: - Robustness

    func testShortBufferIsRejectedAndRendersBlank() {
        let junk = ScopeFrame(width: 10, height: 10, bytes: [1, 2, 3])
        XCTAssertFalse(junk.isValid)
        XCTAssertEqual(ScopeRenderer.waveform(junk, mode: .rgb, width: 64, height: 64).rgba.count, 64 * 64 * 4)
        XCTAssertEqual(ScopeRenderer.vectorscope(junk, size: 64).rgba.count, 64 * 64 * 4)
    }
}
