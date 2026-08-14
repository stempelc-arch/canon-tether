import AppKit

// Renders a 1024×1024 app icon: a dark gradient squircle (macOS icon grid margins) with the
// white "camera.aperture" SF Symbol centered. Output: icon-1024.png next to this script's cwd.

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Background squircle, inset to leave the standard macOS icon margin.
let inset = CGFloat(size) * 0.09
let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
let corner = rect.width * 0.235
let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
ctx.saveGState()
bg.addClip()
let colors = [
    NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.26, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Centered white aperture symbol.
let symbolConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.5, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig) {
    let s = symbol.size
    let symbolRect = CGRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2, width: s.width, height: s.height)
    symbol.draw(in: symbolRect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: "icon-1024.png"))
print("wrote icon-1024.png")
