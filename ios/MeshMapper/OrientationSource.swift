import Combine
import CoreMotion
import Foundation
import MeshCore

/// The phone's attitude from Core Motion at 10 Hz: true-north heading and compass quality for
/// UWB bearings and the heading-up map, and gravity for a mounted anchor's tilt. One motion
/// manager for the whole app. All callbacks and callers run on the main queue.
final class OrientationSource: ObservableObject {
    static let updateInterval: TimeInterval = 0.1
    /// Published heading changes smaller than this are not republished, to spare SwiftUI.
    static let headingStep = 1.0

    /// Map heading (degrees from +z north towards +x east) the phone faces; nil without a
    /// calibrated true-north reference.
    @Published private(set) var heading: Double?
    /// Compass error in degrees from the magnetometer calibration; nil when uncalibrated or unknown.
    @Published private(set) var compassErrorDegrees: Double?
    /// Latest attitude in the `.xTrueNorthZVertical` frame; nil without a true-north reference.
    private(set) var attitude: RotationMatrix?
    /// Gravity in the device frame (g units), or nil when Core Motion has no sample yet.
    private(set) var gravity: Vector3?

    private let motion = CMMotionManager()
    private var usesTrueNorth = false

    var isRunning: Bool { motion.isDeviceMotionActive }

    /// True north needs the magnetometer and Location Services; without them only gravity is measured.
    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        start(trueNorth: frames.contains(.xTrueNorthZVertical))
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        attitude = nil
        gravity = nil
        if heading != nil { heading = nil }
        if compassErrorDegrees != nil { compassErrorDegrees = nil }
    }

    private func start(trueNorth: Bool) {
        usesTrueNorth = trueNorth
        motion.deviceMotionUpdateInterval = Self.updateInterval
        let frame: CMAttitudeReferenceFrame = trueNorth ? .xTrueNorthZVertical : .xArbitraryCorrectedZVertical
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] sample, error in
            guard let self else { return }
            if error != nil, self.usesTrueNorth {
                // For example Location Services off: keep gravity, give up on bearings.
                self.motion.stopDeviceMotionUpdates()
                self.attitude = nil
                if self.heading != nil { self.heading = nil }
                if self.compassErrorDegrees != nil { self.compassErrorDegrees = nil }
                self.start(trueNorth: false)
                return
            }
            guard let sample else { return }
            self.apply(sample)
        }
    }

    private func apply(_ sample: CMDeviceMotion) {
        gravity = Vector3(sample.gravity.x, sample.gravity.y, sample.gravity.z)
        guard usesTrueNorth else { return }
        let m = sample.attitude.rotationMatrix
        let matrix = RotationMatrix(m11: m.m11, m12: m.m12, m13: m.m13,
                                    m21: m.m21, m22: m.m22, m23: m.m23,
                                    m31: m.m31, m32: m.m32, m33: m.m33)
        let error = Self.compassError(sample.magneticField.accuracy)
        attitude = error == nil ? nil : matrix
        if compassErrorDegrees != error { compassErrorDegrees = error }
        let newHeading = error == nil ? nil : PeerBearing.headingDegrees(attitude: matrix)
        if let newHeading, let heading {
            let change = abs(newHeading - heading).truncatingRemainder(dividingBy: 360)
            if min(change, 360 - change) >= Self.headingStep { self.heading = newHeading }
        } else if newHeading != heading {
            heading = newHeading
        }
    }

    /// MAP_DESIGN.md R4: 10°, 20° or 35° for high, medium or low calibration; none when uncalibrated.
    static func compassError(_ accuracy: CMMagneticFieldCalibrationAccuracy) -> Double? {
        switch accuracy {
        case .high: return 10
        case .medium: return 20
        case .low: return 35
        case .uncalibrated: return nil
        @unknown default: return nil
        }
    }
}
