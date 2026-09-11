import Foundation
import ScreenCaptureKit
import Metal
import CoreVideo
import AppKit

/// Streams the live desktop into a Metal texture using ScreenCaptureKit.
///
/// Our own overlay window is excluded from the capture, otherwise the effect
/// would feed back into itself.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    enum State {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Latest frame, valid on the main thread only.
    private(set) var texture: MTLTexture?
    private(set) var frameSize: CGSize = .zero
    /// Media time of the most recent frame; drives the overlay stall watchdog.
    private(set) var lastFrameTime: CFTimeInterval = 0

    var onFirstFrame: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private var excludedWindowNumbers: Set<Int> = []
    private var targetDisplayID: CGDirectDisplayID?
    private let outputQueue = DispatchQueue(label: "app.lidbend.capture", qos: .userInteractive)
    private var startGeneration = 0
    private var announcedFirstFrame = false
    /// Set synchronously so a caller polling every frame cannot pile up
    /// overlapping SCShareableContent requests while the first one is in flight.
    private var isStarting = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    var isRunning: Bool {
        if isStarting { return true }
        if case .running = state { return true }
        return false
    }

    /// Starts (or restarts) capture of `displayID`, hiding the given windows.
    func start(displayID: CGDirectDisplayID, excluding windowNumbers: Set<Int>) {
        targetDisplayID = displayID
        excludedWindowNumbers = windowNumbers
        startGeneration += 1
        isStarting = true
        let generation = startGeneration

        Task { @MainActor in
            defer { if generation == self.startGeneration { self.isStarting = false } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)

                guard generation == self.startGeneration else { return }
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else {
                    self.fail("No capturable display found.")
                    return
                }

                let excluded = content.windows.filter {
                    windowNumbers.contains(Int($0.windowID))
                        || $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                }

                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.width = display.width * Self.scaleFactor(for: displayID)
                config.height = display.height * Self.scaleFactor(for: displayID)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 4
                config.showsCursor = true
                config.capturesAudio = false
                config.scalesToFit = false

                await self.stopStream()
                guard generation == self.startGeneration else { return }

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen,
                                           sampleHandlerQueue: self.outputQueue)
                try await stream.startCapture()

                guard generation == self.startGeneration else {
                    try? await stream.stopCapture()
                    return
                }

                self.stream = stream
                self.state = .running
                self.announcedFirstFrame = false
            } catch {
                self.fail(Self.describe(error))
            }
        }
    }

    /// Performs a single content query for the sole purpose of raising the
    /// consent prompt. ScreenCaptureKit's own API is what actually triggers it;
    /// CGRequestScreenCaptureAccess often returns without prompting for SCK
    /// clients, so the button would appear to do nothing.
    func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func stop() {
        startGeneration += 1
        isStarting = false
        Task { @MainActor in
            await self.stopStream()
            self.state = .idle
            self.texture = nil
        }
    }

    @MainActor
    private func stopStream() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// Re-applies the window exclusion list without tearing the stream down.
    func updateExclusions(_ windowNumbers: Set<Int>) {
        guard isRunning, let displayID = targetDisplayID,
              windowNumbers != excludedWindowNumbers else { return }
        start(displayID: displayID, excluding: windowNumbers)
    }

    @MainActor
    private func fail(_ message: String) {
        state = .failed(message)
        onFailure?(message)
    }

    private static func scaleFactor(for displayID: CGDirectDisplayID) -> Int {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return Int(screen?.backingScaleFactor ?? 2.0)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801:
                return "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then reopen Lidbend."
            default:
                break
            }
        }
        return nsError.localizedDescription
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        // Skip frames the compositor marked as containing nothing new.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                    createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)

        guard result == kCVReturnSuccess,
              let cvTexture, let metalTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        DispatchQueue.main.async {
            self.texture = metalTexture
            self.frameSize = CGSize(width: width, height: height)
            self.lastFrameTime = CACurrentMediaTime()
            if !self.announcedFirstFrame {
                self.announcedFirstFrame = true
                self.onFirstFrame?()
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.stream = nil
            self.fail(Self.describe(error))
        }
    }
}
