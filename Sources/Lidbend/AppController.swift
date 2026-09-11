import AppKit
import Combine
import CoreGraphics
import Metal
import SwiftUI

/// Ties the hinge sensor, the desktop capture and the overlay together.
@MainActor
final class AppController: ObservableObject {

    static let shared = AppController()

    // Observable state for the settings UI.
    @Published private(set) var lidAngle: Double?
    @Published private(set) var restAngle: Double = 130
    /// Bend progress for the UI, published in half-percent steps so the
    /// settings window is not re-rendered on every tick. Rendering reads the
    /// unquantised spring value through `makeFrame()`.
    @Published private(set) var progress: Double = 0
    @Published private(set) var sensorAvailable = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var needsScreenRecording = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published var isPaused = false

    private let settings = AppSettings.shared
    private let sensor = LidAngleSensor()
    private var capture: DesktopCapture?
    private var overlay: OverlayController?
    private var device: MTLDevice?

    private var spring = MotionSpring(value: 0)
    private var rest: Double = 130
    private var lastTick = CACurrentMediaTime()
    /// Stand-in scene for previews; also what the style cards always show, so
    /// the three looks stay comparable whatever is on the real desktop.
    private(set) lazy var placeholderTexture: MTLTexture? =
        device.flatMap { PlaceholderScene.makeTexture(device: $0) }
    private var tickTimer: Timer?
    private var captureIdleSince: CFTimeInterval?
    private var previewClients = 0
    private var captureRetryAt: CFTimeInterval?
    private var lastPermissionCheck: CFTimeInterval = 0
    private var cancellables = Set<AnyCancellable>()
    private var wasEngaged = false

    /// Angle-tracking rates, in degrees per second.
    private let restAttackRate: Double = 45
    private let restDecayRate: Double = 3

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            statusMessage = "This Mac does not expose a Metal device."
            return
        }
        self.device = device

        do {
            let overlay = try OverlayController(device: device)
            overlay.frameProvider = { [weak self] in self?.makeFrame() ?? Self.flatFrame }
            overlay.textureProvider = { [weak self] in self?.capture?.texture }
            overlay.onStall = { [weak self] in
                self?.statusMessage = "Desktop capture stalled; the overlay was hidden."
            }
            self.overlay = overlay
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let capture = DesktopCapture(device: device)
        capture.onFirstFrame = { [weak self] in
            self?.overlay?.noteFrameArrived()
            self?.statusMessage = nil
            self?.needsScreenRecording = false
            self?.captureRetryAt = nil
        }
        capture.onFailure = { [weak self] message in
            guard let self else { return }
            self.statusMessage = message
            if message.contains("Screen Recording") {
                self.needsScreenRecording = true
                self.hasScreenRecordingPermission = false
            }
            // Back off, but keep retrying: consent can be granted while we run.
            self.captureRetryAt = CACurrentMediaTime() + 5
            self.overlay?.hide()
        }
        self.capture = capture

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        if !hasScreenRecordingPermission {
            needsScreenRecording = true
            statusMessage = "Lidbend needs Screen Recording permission to see your desktop."
        }

        sensorAvailable = sensor.isAvailable
        if sensor.isAvailable {
            rest = sensor.angle ?? 130
            restAngle = rest
            sensor.start(hz: 60) { [weak self] angle in
                self?.publishLidAngle(angle)
            }
        } else {
            settings.angleSource = .manual
            statusMessage = "No hinge sensor found. Using the manual angle slider."
        }

        // One timer drives smoothing, engagement and the capture lifecycle.
        // It runs at 120 Hz so ProMotion displays get a fresh spring value on
        // every frame instead of every other one.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        settings.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.applySettingsChange() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        sensor.stop()
        capture?.stop()
        overlay?.hide(animated: false)
    }

    // MARK: - Preview clients

    /// The settings window keeps capture alive so its live preview has frames.
    func retainPreview() {
        previewClients += 1
        startCaptureIfNeeded()
    }

    func releasePreview() {
        previewClients = max(0, previewClients - 1)
    }

    var currentTexture: MTLTexture? { capture?.texture }
    /// The live desktop when it is available, otherwise a stand-in scene so
    /// the settings previews never sit empty.
    var previewTexture: MTLTexture? { capture?.texture ?? placeholderTexture }
    var metalDevice: MTLDevice? { device }

    /// `@Published` fires on every assignment, so only publish real changes.
    private func publishLidAngle(_ angle: Double?) {
        if lidAngle != angle { lidAngle = angle }
    }

    private func publishProgress(_ value: Double) {
        let quantised = (value * 200).rounded() / 200
        if progress != quantised { progress = quantised }
    }

    private func publishRestAngle() {
        let quantised = (rest * 2).rounded() / 2
        if restAngle != quantised { restAngle = quantised }
    }

    // MARK: - Per-frame update

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        refreshPermission(now: now)

        let reference: Double
        let angle: Double

        switch settings.angleSource {
        case .sensor:
            guard let sensed = sensor.angle else {
                trackTowardsFlat(dt: dt)
                return
            }
            angle = sensed
            updateRestAngle(with: sensed, dt: dt)
            reference = rest
        case .manual:
            angle = settings.manualAngle
            rest = 180
            publishRestAngle()
            reference = 180
        }

        let engageAt = reference - settings.deadband
        let closeAt = min(settings.closedThreshold, engageAt - 1)
        let span = max(engageAt - closeAt, 1)
        let raw = max(0, min(1, (engageAt - angle) / span))

        let active = settings.enabled && !isPaused
        spring.smoothing = settings.motionSmoothing
        spring.step(toward: active ? raw : 0, dt: dt)
        publishProgress(spring.value)

        updateEngagement(reference: reference, angle: angle, now: now)
    }

    /// Runs when the sensor has no reading: unwind smoothly and let go.
    private func trackTowardsFlat(dt: Double) {
        spring.smoothing = settings.motionSmoothing
        spring.step(toward: 0, dt: dt)
        publishProgress(spring.value)
        if spring.value < 0.002 { overlay?.hide() }
    }

    /// The reference angle chases the lid quickly upward and drifts down slowly,
    /// so the effect keys off closing motion rather than an absolute angle.
    private func updateRestAngle(with angle: Double, dt: Double) {
        if angle > rest {
            rest = min(angle, rest + restAttackRate * dt)
        } else {
            rest = max(angle, rest - restDecayRate * dt)
        }
        rest = min(max(rest, 40), 180)
        publishRestAngle()
    }

    private func updateEngagement(reference: Double, angle: Double, now: CFTimeInterval) {
        let engaged = spring.value > 0.002
        let warming = settings.enabled && !isPaused
            && angle < reference - settings.deadband * 0.4

        if engaged || warming || previewClients > 0 {
            captureIdleSince = nil
            startCaptureIfNeeded()
        } else if captureIdleSince == nil {
            captureIdleSince = now
        } else if let since = captureIdleSince, now - since > 6 {
            capture?.stop()
            captureIdleSince = nil
        }

        if engaged {
            // Only vouch for genuinely fresh frames — the last texture stays
            // referenced after a stall, so trusting it would defeat the
            // overlay's watchdog and leave the screen covered.
            if let capture, capture.texture != nil,
               now - capture.lastFrameTime < 1.0 {
                overlay?.noteFrameArrived()
            }
            overlay?.show()
        } else {
            overlay?.hide()
        }

        if wasEngaged && !engaged {
            wasEngaged = false
            if settings.playSound { Self.playClearSound() }
        } else if engaged {
            wasEngaged = true
        }
    }

    private func startCaptureIfNeeded() {
        guard let capture, let overlay, !capture.isRunning else { return }
        // Never touch ScreenCaptureKit without consent: each attempt raises the
        // system prompt again, which turns a retry loop into a dialog storm.
        guard hasScreenRecordingPermission else { return }
        if let retryAt = captureRetryAt, CACurrentMediaTime() < retryAt { return }
        captureRetryAt = nil
        guard let displayID = OverlayController.targetDisplayID else { return }
        capture.start(displayID: displayID, excluding: overlay.windowNumbers)
    }

    /// Raises the system consent prompt, from a button press only.
    func requestScreenRecordingPermission() {
        guard let capture else { return }
        statusMessage = "Waiting for permission…"
        Task { @MainActor in
            let granted = await capture.requestPermission()
            if granted {
                self.markPermissionGranted()
            } else {
                self.statusMessage = "Still no access. Quit Lidbend and open it again — macOS decides a process's access once, when it launches."
            }
        }
    }

    private func markPermissionGranted() {
        hasScreenRecordingPermission = true
        needsScreenRecording = false
        statusMessage = nil
        captureRetryAt = nil
    }

    /// Cheap, prompt-free check. macOS caches the answer per process, so a grant
    /// made in System Settings may not show up until Lidbend is relaunched.
    private func refreshPermission(now: CFTimeInterval) {
        guard !hasScreenRecordingPermission, now - lastPermissionCheck > 1 else { return }
        lastPermissionCheck = now
        // Only ever upgrades. macOS caches the preflight answer per process, so
        // treating a cached "no" as authoritative would undo a live grant.
        if CGPreflightScreenCaptureAccess() { markPermissionGranted() }
    }

    /// Opens the Screen Recording pane so the user can grant consent.
    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func applySettingsChange() {
        if settings.angleSource == .sensor && !sensor.isAvailable {
            settings.angleSource = .manual
        }
        if !settings.enabled {
            overlay?.hide()
            capture?.stop()
        }
        updateSensorPolling()
    }

    /// Switching the effect off should cost nothing, so the sensor stops too.
    private func updateSensorPolling() {
        guard sensor.isAvailable else { return }
        let wanted = settings.enabled && settings.angleSource == .sensor
        if wanted {
            sensor.start(hz: 60) { [weak self] angle in
                self?.publishLidAngle(angle)
            }
        } else {
            sensor.stop()
            publishLidAngle(nil)
        }
    }

    // MARK: - Frame state

    static let flatFrame = BendRenderer.Frame(
        progress: 0, style: .silk, intensityDegrees: 0, perspective: 0.5,
        blur: 0, shadow: 0, softness: 0.3, hingeV: 0, time: 0)

    func makeFrame() -> BendRenderer.Frame {
        BendRenderer.Frame(
            progress: Float(spring.value),
            style: settings.style,
            intensityDegrees: Float(settings.intensity),
            perspective: Float(settings.perspective),
            blur: Float(settings.blur),
            shadow: Float(settings.shadow),
            softness: Float(settings.softness),
            hingeV: Float(settings.effectiveHingeV),
            time: 0)
    }

    // MARK: - Sound

    private static var clearSound: NSSound? = {
        NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    }()

    private static func playClearSound() {
        guard let sound = clearSound else { return }
        sound.stop()
        sound.volume = 0.35
        sound.play()
    }
}
