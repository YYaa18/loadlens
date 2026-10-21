import AppKit
import CoreGraphics

@main
struct IconGen {
    static func main() {
        let args = CommandLine.arguments
        let output = args.count > 1 ? args[1] : "icon_1024.png"
        let size = 1024
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(data: nil,
                                  width: size,
                                  height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("cannot create context")
        }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let plate = squirclePath(rect: iconRect, exponent: 5)

        // Soft drop shadow under the plate.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(plate)
        ctx.setFillColor(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(plate)
        ctx.clip()

        // Background gradient.
        let background = gradient([
            NSColor(srgbRed: 0.13, green: 0.17, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.04, green: 0.06, blue: 0.09, alpha: 1)
        ], [0, 1])
        ctx.drawLinearGradient(background,
                               start: CGPoint(x: 210, y: 900),
                               end: CGPoint(x: 850, y: 160),
                               options: [])

        // Top sheen.
        let sheen = gradient([
            NSColor.white.withAlphaComponent(0.10),
            NSColor.white.withAlphaComponent(0)
        ], [0, 1])
        ctx.drawRadialGradient(sheen,
                               startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 900), endRadius: 560,
                               options: [])

        // Faint concentric rings for depth.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.035).cgColor)
        ctx.setLineWidth(2)
        for radius in [330, 430, 530] as [CGFloat] {
            ctx.strokeEllipse(in: CGRect(x: 468 - radius, y: 570 - radius,
                                         width: radius * 2, height: radius * 2))
        }

        // Magnifier handle (drawn first so the ring overlaps the joint).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
                      color: NSColor.black.withAlphaComponent(0.30).cgColor)
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 612, y: 445))
        handle.addLine(to: CGPoint(x: 733, y: 324))
        ctx.addPath(handle)
        ctx.setLineWidth(66)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1).cgColor)
        ctx.strokePath()
        ctx.restoreGState()

        // Lens interior.
        let lensCenter = CGPoint(x: 468, y: 570)
        let innerRadius: CGFloat = 176
        let innerRect = CGRect(x: lensCenter.x - innerRadius,
                               y: lensCenter.y - innerRadius,
                               width: innerRadius * 2,
                               height: innerRadius * 2)
        ctx.setFillColor(NSColor(srgbRed: 0.035, green: 0.05, blue: 0.07, alpha: 0.97).cgColor)
        ctx.fillEllipse(in: innerRect)

        // Warm glow behind the bars.
        ctx.saveGState()
        ctx.addEllipse(in: innerRect)
        ctx.clip()
        let glow = gradient([
            NSColor(srgbRed: 1.0, green: 0.48, blue: 0.22, alpha: 0.30),
            NSColor(srgbRed: 1.0, green: 0.48, blue: 0.22, alpha: 0)
        ], [0, 1])
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: lensCenter.x, y: 480), startRadius: 8,
                               endCenter: CGPoint(x: lensCenter.x, y: 480), endRadius: 210,
                               options: [])
        ctx.restoreGState()

        // Baseline.
        let baseline = CGRect(x: 360, y: 445, width: 216, height: 8)
        ctx.addPath(CGPath(roundedRect: baseline, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.fillPath()

        // Three ascending bars.
        drawBar(ctx, rect: CGRect(x: 377, y: 453, width: 46, height: 110),
                color: NSColor(srgbRed: 1.0, green: 0.80, blue: 0.40, alpha: 1))
        drawBar(ctx, rect: CGRect(x: 445, y: 453, width: 46, height: 160),
                color: NSColor(srgbRed: 1.0, green: 0.54, blue: 0.24, alpha: 1))
        drawBar(ctx, rect: CGRect(x: 513, y: 453, width: 46, height: 205),
                color: NSColor(srgbRed: 1.0, green: 0.35, blue: 0.30, alpha: 1))

        // Magnifier ring.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(58)
        ctx.setStrokeColor(NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1).cgColor)
        ctx.strokeEllipse(in: CGRect(x: lensCenter.x - 205, y: lensCenter.y - 205,
                                     width: 410, height: 410))
        ctx.restoreGState()

        // Inner rim of the plate.
        ctx.addPath(plate)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        ctx.strokePath()

        ctx.restoreGState()

        guard let image = ctx.makeImage() else { fatalError("cannot make image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("cannot encode png")
        }
        try! data.write(to: URL(fileURLWithPath: output))
        print("wrote \(output)")
    }

    static func drawBar(_ ctx: CGContext, rect: CGRect, color: NSColor) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 23, cornerHeight: 23, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    static func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
        let cgColors = colors.map { $0.cgColor } as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: cgColors,
                          locations: locations)!
    }

    /// Continuous superellipse, close to the macOS squircle.
    static func squirclePath(rect: CGRect, exponent: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let centerX = rect.midX
        let centerY = rect.midY
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let steps = 720
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
            let cosine = cos(t)
            let sine = sin(t)
            let x = centerX + radiusX * copysign(pow(abs(cosine), 2 / exponent), cosine)
            let y = centerY + radiusY * copysign(pow(abs(sine), 2 / exponent), sine)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}
