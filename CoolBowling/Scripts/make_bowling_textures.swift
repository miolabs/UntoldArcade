// Generates the CoolBowling lane texture: maple boards with a foul line and
// arrows (the pins, ball, pit cover and ball return are artist models under
// Resources/Models). Run: swift make_bowling_textures.swift <outDir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func savePNG(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name)")
}
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// --- Lane: maple boards (repeat along length), foul line at v = 0, arrows at v ≈ 0.25.
do {
    let W = 512, H = 2048
    let c = context(W, H)
    let boards = 39
    for b in 0 ..< boards {
        let t = 0.80 + Double(b % 5) * 0.03 + Double((b * 7) % 3) * 0.015
        c.setFillColor(CGColor(red: t, green: t * 0.82, blue: t * 0.58, alpha: 1))
        c.fill(CGRect(x: Int(Double(b) / Double(boards) * Double(W)), y: 0, width: Int(Double(W) / Double(boards)) + 1, height: H))
    }
    c.setStrokeColor(CGColor(red: 0.55, green: 0.42, blue: 0.25, alpha: 0.5)); c.setLineWidth(1)
    for b in 0 ... boards { let x = Double(b) / Double(boards) * Double(W); c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: Double(H))) }
    c.strokePath()
    // Foul line at the near end.
    c.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 8, width: W, height: 6))
    // Arrows.
    c.setFillColor(CGColor(red: 0.2, green: 0.15, blue: 0.1, alpha: 0.85))
    for (i, u) in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8].enumerated() {
        let x = u * Double(W), y = Double(H) * (0.22 + Double(abs(i - 3)) * 0.015)
        let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y + 40)); p.addLine(to: CGPoint(x: x - 12, y: y)); p.addLine(to: CGPoint(x: x + 12, y: y)); p.closeSubpath()
        c.addPath(p); c.fillPath()
    }
    savePNG(c.makeImage()!, "lane_baseColor.png")
}
