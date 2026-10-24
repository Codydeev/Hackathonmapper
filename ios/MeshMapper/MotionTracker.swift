import CoreMotion
import Foundation
import MeshCore

/// Core Motion feeds for dead reckoning: device motion at 50 Hz and barometric relative altitude.
/// Callbacks run on the main queue.
final class MotionTracker {
    static let sampleRate = 50.0

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    var onSample: ((MotionSample) -> Void)?
    /// Meters since `start()`; nil without a barometer or before the first reading.
    private(set) var relativeAltitude: Double?

    var isMotionAvailable: Bool { motion.isDeviceMotionAvailable }
    var isAltitudeAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1 / Self.sampleRate
        // Gyro-only yaw: smooth indoors, where steel and electronics skew the compass. The fusion
        // estimates the slow drift that remains.
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            self?.onSample?(MotionSample(
                time: data.timestamp,
                gravity: Vector3(data.gravity.x, data.gravity.y, data.gravity.z),
                userAcceleration: Vector3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z),
                rotationRate: Vector3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
            ))
        }
        relativeAltitude = nil
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                self?.relativeAltitude = data?.relativeAltitude.doubleValue
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        relativeAltitude = nil
    }
}
