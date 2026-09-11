import Foundation

/// Critically damped spring used to smooth the raw hinge readings, which come
/// in quantised to whole degrees and jitter by a degree or two while moving.
struct MotionSpring {
    var value: Double
    var velocity: Double = 0
    /// 0 = follow the target closely, 1 = very soft.
    var smoothing: Double = 0.7

    init(value: Double = 0) {
        self.value = value
    }

    /// Stiffness runs on a log scale from snappy to floaty. At the default
    /// the spring settles in about half a second, which reads as the lid
    /// gliding rather than the desktop chasing every degree.
    private var stiffness: Double {
        let t = max(0, min(1, smoothing))
        return 400 * pow(30.0 / 400.0, t)
    }

    mutating func step(toward target: Double, dt: Double) {
        let dt = min(max(dt, 1.0 / 240.0), 1.0 / 20.0)
        let k = stiffness
        let c = 2 * (k).squareRoot()          // critical damping
        let acceleration = k * (target - value) - c * velocity
        velocity += acceleration * dt
        value += velocity * dt

        if abs(target - value) < 0.0002 && abs(velocity) < 0.0002 {
            value = target
            velocity = 0
        }
    }

    mutating func reset(to target: Double) {
        value = target
        velocity = 0
    }
}
