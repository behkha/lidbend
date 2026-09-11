import Foundation
import IOKit.hid

/// Reads the hinge angle from the internal lid-angle HID sensor found on
/// Apple silicon MacBooks (HID usage page 0x20 "Sensor", usage 0x8A).
///
/// The sensor exposes a 3-byte feature report on report ID 1:
///   byte 0: report id
///   byte 1: angle low byte
///   byte 2: angle high byte
/// The angle is in whole degrees, 0 (closed) to ~180 (fully open).
final class LidAngleSensor {

    /// Latest reading in degrees, or nil when no sensor is available.
    private(set) var angle: Double?
    /// True when a matching HID device was found and opened.
    private(set) var isAvailable = false

    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "app.lidbend.lid-sensor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var onChange: ((Double?) -> Void)?

    // Some machines briefly fail a read while the sensor wakes; tolerate a few.
    private var consecutiveFailures = 0

    init() {
        openDevice()
    }

    deinit {
        stop()
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    private func openDevice() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: 0x20,   // Sensor
            kIOHIDPrimaryUsageKey: 0x8A,       // Orientation / lid angle
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else { return }

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

        self.device = device
        self.isAvailable = true
        self.angle = readAngle()
    }

    /// Polls the sensor at `hz` and delivers readings on the main queue.
    func start(hz: Int = 60, onChange: @escaping (Double?) -> Void) {
        guard isAvailable, timer == nil else { return }
        self.onChange = onChange

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(hz), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let value = self.readAngle()
            DispatchQueue.main.async {
                self.angle = value
                self.onChange?(value)
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onChange = nil
    }

    private func readAngle() -> Double? {
        guard let device else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = buffer.count

        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length)
        guard result == kIOReturnSuccess, length >= 3 else {
            consecutiveFailures += 1
            return consecutiveFailures > 8 ? nil : angle
        }
        consecutiveFailures = 0

        let raw = Int(buffer[1]) | (Int(buffer[2]) << 8)
        // Guard against garbage while the sensor is waking up.
        guard (0...360).contains(raw) else { return angle }
        return Double(raw)
    }
}
