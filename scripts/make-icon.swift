// Draws the app icon into a 1024×1024 PNG.
// Usage: scripts/make-icon.sh (writes Resources/AppIcon.icns)
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

// macOS icon grid: 824pt body centered in 1024 with a continuous-corner squircle.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x0B4F8A))
ctx.fillPath()
ctx.restoreGState()

// Body gradient: cyan at the top to deep ocean blue at the bottom.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(
    colorsSpace: space,
    colors: [color(0x5BD8FF), color(0x1E8CF0), color(0x1646B8)] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(
    colorsSpace: space, colors: [color(0xFFFFFF, 0.3), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 880), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 880), endRadius: 560, options: []
)

// Waves along the bottom.
for (i, alpha) in [0.18, 0.12].enumerated() {
    let wave = CGMutablePath()
    let base = 250 - CGFloat(i) * 60
    wave.move(to: CGPoint(x: 100, y: base))
    for k in 0..<5 {
        let x0 = 100 + CGFloat(k) * 170
        wave.addCurve(
            to: CGPoint(x: x0 + 170, y: base),
            control1: CGPoint(x: x0 + 55, y: base + 40), control2: CGPoint(x: x0 + 115, y: base - 40)
        )
    }
    wave.addLine(to: CGPoint(x: 924, y: 100))
    wave.addLine(to: CGPoint(x: 100, y: 100))
    wave.closeSubpath()
    ctx.addPath(wave)
    ctx.setFillColor(color(0xFFFFFF, alpha))
    ctx.fillPath()
}
ctx.restoreGState()

// A pyramid of shipping containers: three at the bottom, two on top of them, one on the summit.
let boxW: CGFloat = 196, boxH: CGFloat = 124, gap: CGFloat = 18
func container(at origin: CGPoint) {
    let rect = CGRect(origin: origin, size: CGSize(width: boxW, height: boxH))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x0A2A70, 0.4))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    // Corrugation ribs.
    ctx.setFillColor(color(0x1E8CF0, 0.28))
    for r in 0..<5 {
        let x = rect.minX + 30 + CGFloat(r) * 30
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: x, y: rect.minY + 24, width: 14, height: boxH - 48),
            cornerWidth: 7, cornerHeight: 7, transform: nil
        ))
    }
    ctx.fillPath()
}

let rowY: [CGFloat] = [330, 330 + boxH + gap, 330 + 2 * (boxH + gap)]
for i in 0..<3 { container(at: CGPoint(x: 512 - 1.5 * boxW - gap + CGFloat(i) * (boxW + gap), y: rowY[0])) }
for i in 0..<2 { container(at: CGPoint(x: 512 - boxW - gap / 2 + CGFloat(i) * (boxW + gap), y: rowY[1])) }
container(at: CGPoint(x: 512 - boxW / 2, y: rowY[2]))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
