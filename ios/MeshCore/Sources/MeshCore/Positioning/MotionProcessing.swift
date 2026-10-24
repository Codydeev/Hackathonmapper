import Foundation

extension Positioning {
    /// One Core Motion device-motion sample, device frame (x right, y up the screen, z out of the
    /// screen). `gravity` and `userAcceleration` are in g, `rotationRate` in rad/s, as
    /// `CMDeviceMotion` reports them.
    public struct MotionSample: Equatable, Codable {
        public let t: TimeInterval
        public let gravity: Vec3
        public let userAcceleration: Vec3
        public let rotationRate: Vec3

        public init(t: TimeInterval, gravity: Vec3, userAcceleration: Vec3, rotationRate: Vec3) {
            self.t = t
            self.gravity = gravity
            self.userAcceleration = userAcceleration
            self.rotationRate = rotationRate
        }
    }

    /// Heading of the phone's forward axis from the magnetometer, already tilt-compensated and
    /// turned to true north.
    public struct CompassSample: Equatable, Codable {
        public let t: TimeInterval
        /// Radians clockwise from true north.
        public let heading: Double
        /// 1-sigma, radians.
        public let sigma: Double
        /// The field strength or dip is off what the Earth gives here: steel, magnets, a car.
        public let disturbed: Bool

        public init(t: TimeInterval, heading: Double, sigma: Double, disturbed: Bool = false) {
            self.t = t
            self.heading = heading
            self.sigma = sigma
            self.disturbed = disturbed
        }
    }

    /// One detected step. `length` is the uncorrected model length; the engine scales it.
    public struct StepEvent: Equatable, Codable {
        public enum Source: String, Codable { case detector, pedometer }
        public let t: TimeInterval
        public let length: Double
        public let source: Source

        public init(t: TimeInterval, length: Double, source: Source) {
            self.t = t
            self.length = length
            self.source = source
        }
    }

    public enum DeviceAxes {
        /// Unit up vector in the device frame (gravity points down).
        public static func up(gravity: Vec3) -> Vec3? { gravity.scaled(-1).normalized }

        /// Heading rate, rad/s clockwise seen from above: minus the rotation about up. Independent of
        /// how the phone is held, which is why the gyro can carry heading through pose changes.
        public static func headingRate(_ s: MotionSample) -> Double? {
            guard let up = up(gravity: s.gravity) else { return nil }
            return -s.rotationRate.dot(up)
        }

        /// The device axis treated as "forward": the top edge (+y) when the phone lies flat, the back
        /// (-z) when it stands upright. Both point the same way through the usual tilt-up gesture.
        public static func forward(up: Vec3) -> Vec3? {
            let top = Vec3(0, 1, 0)
            let back = Vec3(0, 0, -1)
            let topH = top - up.scaled(top.dot(up))
            let backH = back - up.scaled(back.dot(up))
            return (topH.length >= 0.5 ? topH : backH).normalized
        }
    }

    public enum Compass {
        /// Tilt-compensated heading of the forward axis from Core Motion's calibrated magnetic field
        /// (µT, device frame), plus field strength and dip to spot disturbances.
        public static func heading(magneticField b: Vec3, gravity: Vec3, declination: Double)
            -> (heading: Double, strength: Double, dip: Double)? {
            guard let up = DeviceAxes.up(gravity: gravity), let forward = DeviceAxes.forward(up: up),
                  let north = (b - up.scaled(b.dot(up))).normalized else { return nil }
            let east = north.cross(up)
            let magnetic = atan2(forward.dot(east), forward.dot(north))
            let strength = b.length
            let dip = asin(max(-1, min(1, -b.dot(up) / max(strength, 1e-9))))
            return (Positioning.wrap(magnetic + declination), strength, dip)
        }

        /// Earth's field near Tampere (WMM 2025): ~52.5 µT, dip ~74°, declination ~+11° east.
        public static let tampereStrength = 52.5
        public static let tampereDip = Positioning.degrees(74)
        public static let tampereDeclination = Positioning.degrees(11)

        public static func isDisturbed(strength: Double, dip: Double, expectedStrength: Double = tampereStrength,
                                       expectedDip: Double = tampereDip) -> Bool {
            abs(strength - expectedStrength) > 8 || abs(dip - expectedDip) > Positioning.degrees(8)
        }
    }

    /// Step detector on gravity-aligned vertical acceleration: low-pass, then a peak above
    /// `peakThreshold` at least `minInterval` after the previous step, with step length from the
    /// Weinberg model L = K (aMax - aMin)^(1/4) over the stride (at most `strideWindow` back). K is a
    /// population default; the engine learns a personal scale while GNSS is good.
    public struct StepDetector {
        public var peakThreshold = 0.08
        public var minInterval: TimeInterval = 0.3
        public var strideWindow: TimeInterval = 1.0
        public var weinbergK = 0.45
        public var cutoffHz = 3.0

        private var filtered: Double?
        private var history: [(t: TimeInterval, v: Double)] = []
        private var rising = false
        private var lastStep: TimeInterval = -Double.infinity

        public init() {}

        public mutating func add(_ s: MotionSample) -> StepEvent? {
            guard let up = DeviceAxes.up(gravity: s.gravity) else { return nil }
            let raw = s.userAcceleration.dot(up)
            let dt = history.last.map { max(1e-3, s.t - $0.t) } ?? 0.02
            let rc = 1 / (2 * Double.pi * cutoffHz)
            let value = filtered.map { $0 + dt / (rc + dt) * (raw - $0) } ?? raw
            filtered = value
            defer {
                history.append((s.t, value))
                history.removeAll { $0.t < s.t - strideWindow }
            }
            guard let prev = history.last else { return nil }
            var step: StepEvent?
            if value < prev.v && rising && prev.v >= peakThreshold && prev.t - lastStep >= minInterval {
                // Peak at the previous sample; amplitude over this stride only.
                let stride = history.filter { $0.t > max(lastStep, prev.t - strideWindow) }.map(\.v)
                let amplitude = max(0, (stride.max() ?? 0) - (stride.min() ?? 0)) * 9.80665
                step = StepEvent(t: prev.t, length: weinbergK * pow(amplitude, 0.25), source: .detector)
                lastStep = prev.t
            }
            rising = value > prev.v
            return step
        }
    }

    /// Stationary when user acceleration and rotation stay tiny for a full window. Used to stop
    /// position growth and to measure gyro bias (true rate is zero).
    public struct StationarityDetector {
        public var window: TimeInterval = 1
        public var maxAccelerationStd = 0.012
        public var maxRotation = 0.05

        private var samples: [(t: TimeInterval, a: Double, w: Double, rate: Double)] = []

        public init() {}

        /// Returns the mean heading rate over the window if the phone has been still for all of it.
        public mutating func add(_ s: MotionSample) -> Double? {
            guard let rate = DeviceAxes.headingRate(s) else { return nil }
            samples.append((s.t, s.userAcceleration.length, s.rotationRate.length, rate))
            samples.removeAll { $0.t < s.t - window }
            guard let first = samples.first, s.t - first.t >= window * 0.9, samples.count >= 5 else { return nil }
            let mean = samples.map(\.a).reduce(0, +) / Double(samples.count)
            let variance = samples.map { ($0.a - mean) * ($0.a - mean) }.reduce(0, +) / Double(samples.count)
            guard variance.squareRoot() <= maxAccelerationStd, samples.allSatisfy({ $0.w <= maxRotation }) else { return nil }
            return samples.map(\.rate).reduce(0, +) / Double(samples.count)
        }
    }
}
