import CoreMotion
import Foundation
import MeshCore

/// Core Motion for the positioning engine: device motion at 50 Hz (gravity, user acceleration and
/// the bias-corrected rotation rate) and, from the calibrated magnetic field, a tilt-compensated
/// compass at 10 Hz. Raw Core Motion sensors need no permission prompt (only the pedometer and
/// activity APIs do, and they are not used). Timestamps are Core Motion's, seconds since boot,
/// which is the engine's clock.
@MainActor
final class MotionSource: ObservableObject {
    nonisolated static let rate = 50.0
    nonisolated static let compassEvery = 5

    @Published private(set) var isRunning = false
    @Published private(set) var compassState = "not started"

    let isAvailable: Bool
    /// True minus magnetic north, radians; Tampere is about +11°.
    var declination = Positioning.Compass.tampereDeclination
    var onMotion: ((Positioning.MotionSample) -> Void)?
    var onCompass: ((Positioning.CompassSample) -> Void)?

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "positioning.motion"
        return q
    }()

    init() {
        isAvailable = manager.isDeviceMotionAvailable
    }

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / Self.rate
        // A magnetic reference frame makes Core Motion deliver the calibrated field. Heading comes
        // from our own tilt-compensated compass, so the engine can gate disturbances itself.
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
        let declination = self.declination
        var count = 0
        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let g = motion.gravity, a = motion.userAcceleration, w = motion.rotationRate
            let gravity = Positioning.Vec3(g.x, g.y, g.z)
            let sample = Positioning.MotionSample(t: motion.timestamp, gravity: gravity,
                                                  userAcceleration: Positioning.Vec3(a.x, a.y, a.z),
                                                  rotationRate: Positioning.Vec3(w.x, w.y, w.z))
            count += 1
            var compass: Positioning.CompassSample?
            var state: String?
            if count % Self.compassEvery == 0 {
                (compass, state) = Self.compass(motion.magneticField, gravity: gravity, t: motion.timestamp,
                                                declination: declination)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onMotion?(sample)
                if let compass { self.onCompass?(compass) }
                if let state, state != self.compassState { self.compassState = state }
            }
        }
        isRunning = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }

    /// Compass reading with an honest sigma for Core Motion's calibration level; disturbed when
    /// field strength or dip is off the local Earth field.
    nonisolated static func compass(_ field: CMCalibratedMagneticField, gravity: Positioning.Vec3, t: TimeInterval,
                                    declination: Double) -> (Positioning.CompassSample?, String) {
        let sigmaDegrees: Double
        switch field.accuracy {
        case .high: sigmaDegrees = 6
        case .medium: sigmaDegrees = 12
        case .low: sigmaDegrees = 25
        default: return (nil, "uncalibrated: wave the phone in a figure eight")
        }
        let b = Positioning.Vec3(field.field.x, field.field.y, field.field.z)
        guard let h = Positioning.Compass.heading(magneticField: b, gravity: gravity, declination: declination) else {
            return (nil, "no heading")
        }
        let disturbed = Positioning.Compass.isDisturbed(strength: h.strength, dip: h.dip)
        let sample = Positioning.CompassSample(t: t, heading: h.heading, sigma: Positioning.degrees(sigmaDegrees), disturbed: disturbed)
        return (sample, disturbed ? "disturbed (\(Int(h.strength.rounded())) µT)" : "ok ±\(Int(sigmaDegrees))°")
    }
}
