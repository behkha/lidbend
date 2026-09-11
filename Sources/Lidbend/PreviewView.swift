import SwiftUI
import MetalKit

/// Live miniature of the effect, driven by the same renderer as the overlay.
///
/// `style` and `progress` override the live values, which is how the style
/// cards show each look at a fixed bend.
struct BendPreview: NSViewRepresentable {
    enum Source { case live, placeholder }

    @ObservedObject var controller: AppController
    var style: BendStyle? = nil
    var progress: Float? = nil
    var source: Source = .live
    var framesPerSecond = 60

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.metalDevice)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = framesPerSecond
        view.autoResizeDrawable = true
        view.delegate = context.coordinator
        view.layer?.isOpaque = true
        context.coordinator.style = style
        context.coordinator.progress = progress
        context.coordinator.source = source
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.style = style
        context.coordinator.progress = progress
        context.coordinator.source = source
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var style: BendStyle?
        var progress: Float?
        var source: Source = .live

        private let controller: AppController
        private var renderer: BendRenderer?
        private let start = CACurrentMediaTime()

        init(controller: AppController) {
            self.controller = controller
            super.init()
            if let device = controller.metalDevice {
                renderer = try? BendRenderer(device: device, pixelFormat: .bgra8Unorm)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }
            var frame = controller.makeFrame()
            if let style { frame.style = style }
            if let progress { frame.progress = progress }
            frame.time = Float(CACurrentMediaTime() - start)
            let texture = source == .live ? controller.previewTexture : controller.placeholderTexture
            renderer.render(frame: frame, source: texture,
                            to: drawable, descriptor: descriptor, viewSize: view.drawableSize)
        }
    }
}

/// The preview framed as a MacBook: black lid with a notch, the screen inset
/// with rounded top corners, and a slim deck beneath. Every part is scaled
/// from the width so the proportions hold at any size.
struct MacBookFrame<Screen: View>: View {
    @ViewBuilder var screen: () -> Screen

    /// Total height as a fraction of width: lid plus deck.
    static var aspectRatio: CGFloat { 1 / ((1 - 2 * 0.0381) / 1.54 + 0.031) }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let lidWidth = w * (1 - 2 * 0.0381)
            let lidHeight = lidWidth / 1.54
            let bezel = Color(white: 0.07)

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: w * 0.0483,
                                           topTrailingRadius: w * 0.0483)
                        .fill(bezel)

                    screen()
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: w * 0.034,
                                                          topTrailingRadius: w * 0.034))
                        .padding(EdgeInsets(top: w * 0.015, leading: w * 0.015,
                                            bottom: w * 0.022, trailing: w * 0.015))

                    NotchShape()
                        .fill(bezel)
                        .frame(width: w * 0.2206, height: w * 0.2206 * 9 / 64)
                        .offset(y: w * 0.015)
                }
                .frame(width: lidWidth, height: lidHeight)

                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: w * 0.0103,
                                           bottomTrailingRadius: w * 0.0103)
                        .fill(Color(white: 0.52))
                    UnevenRoundedRectangle(bottomLeadingRadius: w * 0.0138,
                                           bottomTrailingRadius: w * 0.0138)
                        .fill(Color.black.opacity(0.35))
                        .frame(width: w * 0.248, height: w * 0.0121)
                }
                .frame(width: w, height: w * 0.031)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
    }
}

/// The camera housing hanging from the top bezel, in a 64×9 box.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 64
        let sy = rect.height / 9
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: p(0, 0))
        path.addQuadCurve(to: p(2, 2), control: p(2, 0))
        path.addLine(to: p(2, 5))
        path.addQuadCurve(to: p(6, 9), control: p(2, 9))
        path.addLine(to: p(58, 9))
        path.addQuadCurve(to: p(62, 5), control: p(62, 9))
        path.addLine(to: p(62, 2))
        path.addQuadCurve(to: p(64, 0), control: p(62, 0))
        path.closeSubpath()
        return path
    }
}
