import Foundation
import SwiftUI

enum BendStyle: String, CaseIterable, Identifiable {
    case silk, shade, frost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silk: return "Silk"
        case .shade: return "Shade"
        case .frost: return "Frost"
        }
    }

    var blurb: String {
        switch self {
        case .silk: return "Warm sheen sweeping across the fold."
        case .shade: return "Deep contact shadow, minimal softening."
        case .frost: return "Cool, heavily diffused glass."
        }
    }

    /// Look parameters baked into the style.
    var look: StyleLook {
        switch self {
        case .silk:
            return StyleLook(tint: SIMD3(1.02, 0.995, 0.965), sheen: 0.16,
                             blurBias: 0.85, shadowBias: 0.95, saturation: 1.04, grain: 0.0)
        case .shade:
            return StyleLook(tint: SIMD3(0.96, 0.97, 1.0), sheen: 0.04,
                             blurBias: 0.45, shadowBias: 1.5, saturation: 1.1, grain: 0.0)
        case .frost:
            return StyleLook(tint: SIMD3(0.95, 0.98, 1.06), sheen: 0.10,
                             blurBias: 1.7, shadowBias: 0.7, saturation: 0.72, grain: 0.012)
        }
    }
}

struct StyleLook {
    var tint: SIMD3<Float>
    var sheen: Float
    var blurBias: Float
    var shadowBias: Float
    var saturation: Float
    var grain: Float
}

enum AngleSource: String, CaseIterable, Identifiable {
    case sensor, manual
    var id: String { rawValue }
    var title: String { self == .sensor ? "Hinge sensor" : "Manual" }
}

/// Where the bend line sits on screen.
enum FoldPreset: String, CaseIterable, Identifiable {
    case lid, duo, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lid: return "Lid"
        case .duo: return "Duo"
        case .custom: return "Custom"
        }
    }
    var hingeV: Double? {
        switch self {
        case .lid: return 0.0
        case .duo: return 0.5
        case .custom: return nil
        }
    }
}

/// User-facing settings, persisted to UserDefaults.
///
/// `@AppStorage` only publishes changes inside a `View`, so each property is a
/// plain `@Published` value that writes through to `UserDefaults` on set.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var style: BendStyle { didSet { defaults.set(style.rawValue, forKey: "style") } }
    @Published var angleSource: AngleSource { didSet { defaults.set(angleSource.rawValue, forKey: "angleSource") } }
    @Published var foldPreset: FoldPreset { didSet { defaults.set(foldPreset.rawValue, forKey: "foldPreset") } }

    /// Peak tilt applied at a fully closed lid, in degrees.
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: "intensity") } }
    /// 0 = nearly flat projection, 1 = strong wide-angle perspective.
    @Published var perspective: Double { didSet { defaults.set(perspective, forKey: "perspective") } }
    @Published var blur: Double { didSet { defaults.set(blur, forKey: "blur") } }
    @Published var shadow: Double { didSet { defaults.set(shadow, forKey: "shadow") } }
    /// Radius of the bend arc; low values read as a hard crease.
    @Published var softness: Double { didSet { defaults.set(softness, forKey: "softness") } }
    @Published var hingeV: Double { didSet { defaults.set(hingeV, forKey: "hingeV") } }

    /// How far below the resting lid angle the hinge must travel before the
    /// effect engages, in degrees. Keeps normal working angles untouched.
    @Published var deadband: Double { didSet { defaults.set(deadband, forKey: "deadband") } }
    /// Lid angle at which the effect reaches full strength.
    @Published var closedThreshold: Double { didSet { defaults.set(closedThreshold, forKey: "closedThreshold") } }
    /// Override angle used when `angleSource == .manual`.
    @Published var manualAngle: Double { didSet { defaults.set(manualAngle, forKey: "manualAngle") } }

    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var motionSmoothing: Double { didSet { defaults.set(motionSmoothing, forKey: "motionSmoothing") } }

    /// Effective bend-line position, honouring the preset.
    var effectiveHingeV: Double { foldPreset.hingeV ?? hingeV }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "enabled": true,
            "style": BendStyle.silk.rawValue,
            "angleSource": AngleSource.sensor.rawValue,
            "foldPreset": FoldPreset.lid.rawValue,
            "intensity": 72.0,
            "perspective": 0.7,
            "blur": 0.65,
            "shadow": 0.7,
            "softness": 0.2,
            "hingeV": 0.0,
            "deadband": 8.0,
            "closedThreshold": 25.0,
            "manualAngle": 100.0,
            "playSound": true,
            "motionSmoothing": 0.7,
        ])

        enabled = defaults.bool(forKey: "enabled")
        style = BendStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .silk
        angleSource = AngleSource(rawValue: defaults.string(forKey: "angleSource") ?? "") ?? .sensor
        foldPreset = FoldPreset(rawValue: defaults.string(forKey: "foldPreset") ?? "") ?? .lid
        intensity = defaults.double(forKey: "intensity")
        perspective = defaults.double(forKey: "perspective")
        blur = defaults.double(forKey: "blur")
        shadow = defaults.double(forKey: "shadow")
        softness = defaults.double(forKey: "softness")
        hingeV = defaults.double(forKey: "hingeV")
        deadband = defaults.double(forKey: "deadband")
        closedThreshold = defaults.double(forKey: "closedThreshold")
        manualAngle = defaults.double(forKey: "manualAngle")
        playSound = defaults.bool(forKey: "playSound")
        motionSmoothing = defaults.double(forKey: "motionSmoothing")
    }

    func resetToDefaults() {
        style = .silk
        intensity = 72
        perspective = 0.7
        blur = 0.65
        shadow = 0.7
        softness = 0.2
        foldPreset = .lid
        hingeV = 0
        deadband = 8
        closedThreshold = 25
        motionSmoothing = 0.7
    }
}
