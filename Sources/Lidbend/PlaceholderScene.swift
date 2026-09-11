import AppKit
import Metal

/// A stand-in desktop for the settings previews when no capture is available:
/// a soft sky, two ranges of hills and the lock-screen clock. Drawn once with
/// Core Graphics and uploaded as a BGRA texture.
enum PlaceholderScene {

    static func makeTexture(device: MTLDevice) -> MTLTexture? {
        let scale: CGFloat = 4
        let width = Int(280 * scale)
        let height = Int(182 * scale)

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue          // BGRA in memory
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }

        // Work in a top-down 280×182 space so the paths read naturally.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context)

        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)
        return texture
    }

    private static func draw(in context: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()

        func gradient(_ from: (CGFloat, CGFloat, CGFloat), _ to: (CGFloat, CGFloat, CGFloat)) -> CGGradient? {
            CGGradient(colorsSpace: space,
                       colors: [CGColor(red: from.0, green: from.1, blue: from.2, alpha: 1),
                                CGColor(red: to.0, green: to.1, blue: to.2, alpha: 1)] as CFArray,
                       locations: [0, 1])
        }

        // Sky.
        if let sky = gradient((0.30, 0.35, 0.44), (0.76, 0.80, 0.85)) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: 182), options: [])
        }

        // Moon.
        context.setFillColor(CGColor(red: 0.94, green: 0.96, blue: 1.0, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 202, y: 38, width: 22, height: 22))

        // Far hills.
        let far = CGMutablePath()
        far.move(to: CGPoint(x: 0, y: 116))
        far.addCurve(to: CGPoint(x: 190, y: 112),
                     control1: CGPoint(x: 40, y: 132), control2: CGPoint(x: 120, y: 100))
        far.addCurve(to: CGPoint(x: 280, y: 96),
                     control1: CGPoint(x: 260, y: 124), control2: CGPoint(x: 260, y: 96))
        far.addLine(to: CGPoint(x: 280, y: 182))
        far.addLine(to: CGPoint(x: 0, y: 182))
        far.closeSubpath()
        context.saveGState()
        context.addPath(far)
        context.clip()
        if let g = gradient((0.88, 0.90, 0.93), (0.52, 0.57, 0.62)) {
            context.drawLinearGradient(g, start: CGPoint(x: 280, y: 0),
                                       end: CGPoint(x: 0, y: 182), options: [])
        }
        context.restoreGState()

        // Near hills.
        let near = CGMutablePath()
        near.move(to: CGPoint(x: 0, y: 131))
        near.addCurve(to: CGPoint(x: 150, y: 138),
                      control1: CGPoint(x: 40, y: 111), control2: CGPoint(x: 100, y: 112))
        near.addCurve(to: CGPoint(x: 280, y: 153),
                      control1: CGPoint(x: 200, y: 164), control2: CGPoint(x: 230, y: 160))
        near.addLine(to: CGPoint(x: 280, y: 182))
        near.addLine(to: CGPoint(x: 0, y: 182))
        near.closeSubpath()
        context.saveGState()
        context.addPath(near)
        context.clip()
        if let g = gradient((0.80, 0.83, 0.87), (0.46, 0.53, 0.60)) {
            context.drawLinearGradient(g, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 140, y: 182), options: [])
        }
        context.restoreGState()

        // Home indicator.
        context.setFillColor(CGColor(gray: 1, alpha: 0.7))
        context.addPath(CGPath(roundedRect: CGRect(x: 112, y: 172, width: 56, height: 1.6),
                               cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
        context.fillPath()

        // Clock. The context is already flipped, so tell AppKit so text draws
        // the right way up.
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let date = NSAttributedString(string: "Wednesday, September 9", attributes: [
            .font: NSFont.systemFont(ofSize: 6.4, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.82),
            .paragraphStyle: paragraph,
        ])
        date.draw(in: CGRect(x: 0, y: 22, width: 280, height: 10))

        let time = NSAttributedString(string: "9:41", attributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
            .kern: -1.4,
            .paragraphStyle: paragraph,
        ])
        time.draw(in: CGRect(x: 0, y: 30, width: 280, height: 44))

        NSGraphicsContext.restoreGraphicsState()
    }
}
