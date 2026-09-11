import AppKit
import MetalKit
import QuartzCore

/// Full-screen, click-through window that displays the bent desktop.
///
/// The window never accepts mouse or key events, and it hides itself if frames
/// stop arriving, so a stall can't leave the screen covered.
@MainActor
final class OverlayController: NSObject, MTKViewDelegate {

    /// Supplies the render state for the next frame.
    var frameProvider: (() -> BendRenderer.Frame)?
    /// Supplies the current desktop texture.
    var textureProvider: (() -> MTLTexture?)?
    /// Called when the overlay hides itself because frames stopped arriving.
    var onStall: (() -> Void)?

    private(set) var isVisible = false

    private let device: MTLDevice
    private let renderer: BendRenderer
    private var window: NSWindow?
    private var view: MTKView?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastTextureTime: CFTimeInterval = 0
    private var startTime = CACurrentMediaTime()

    /// Hide the overlay if the desktop texture goes stale for this long.
    private let stallTimeout: CFTimeInterval = 2.0

    init(device: MTLDevice) throws {
        self.device = device
        self.renderer = try BendRenderer(device: device, pixelFormat: .bgra8Unorm)
        super.init()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Window numbers to exclude from the desktop capture.
    var windowNumbers: Set<Int> {
        guard let window else { return [] }
        return [window.windowNumber]
    }

    /// The screen the effect renders on: the built-in display when there is one.
    static var targetScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
    }

    static var targetDisplayID: CGDirectDisplayID? {
        guard let screen = targetScreen,
              let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else { return nil }
        return number.uint32Value
    }

    private func makeWindowIfNeeded() {
        guard window == nil, let screen = Self.targetScreen else { return }

        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120     // capped at the display's own rate
        view.autoResizeDrawable = true
        view.delegate = self
        view.layer?.isOpaque = true

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        window.contentView = view
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true            // never steal clicks
        window.sharingType = .none                  // keep it out of screen captures
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.alphaValue = 0

        self.view = view
        self.window = window
    }

    func show() {
        makeWindowIfNeeded()
        guard let window, !isVisible else { return }
        isVisible = true
        lastTextureTime = CACurrentMediaTime()
        window.setFrame(Self.targetScreen?.frame ?? window.frame, display: false)
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard let window, isVisible else { return }
        isVisible = false
        guard animated else {
            window.alphaValue = 0
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if !self.isVisible { window.orderOut(nil) }
            }
        }
    }

    @objc private func screensChanged() {
        guard let window, let screen = Self.targetScreen else { return }
        window.setFrame(screen.frame, display: true)
    }

    /// Marks the desktop texture as fresh; used by the stall watchdog.
    func noteFrameArrived() {
        lastTextureTime = CACurrentMediaTime()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard isVisible,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let frameProvider else { return }

        let now = CACurrentMediaTime()
        if now - lastTextureTime > stallTimeout {
            hide()
            onStall?()
            return
        }
        lastFrameTime = now

        var frame = frameProvider()
        frame.time = Float(now - startTime)

        renderer.render(frame: frame,
                        source: textureProvider?(),
                        to: drawable,
                        descriptor: descriptor,
                        viewSize: view.drawableSize)
    }
}
