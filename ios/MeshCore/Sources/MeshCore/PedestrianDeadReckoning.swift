import Foundation

public struct Vector3: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func dot(_ other: Vector3) -> Double { x * other.x + y * other.y + z * other.z }
    public var length: Double { dot(self).squareRoot() }
}

/// One Core Motion device-motion sample in device coordinates: `gravity` and `userAcceleration`
/// in g, `rotationRate` in rad/s (bias corrected). `time` is seconds on a monotonic clock.
public struct MotionSample {
    public let time: TimeInterval
    public let gravity: Vector3
    public let userAcceleration: Vector3
    public let rotationRate: Vector3

    public init(time: TimeInterval, gravity: Vector3, userAcceleration: Vector3, rotationRate: Vector3) {
        self.time = time
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
    }
}

public struct Step: Equatable {
    public let time: TimeInterval
    public let length: Double
    /// Frame heading in radians: 0 faces +z, positive turns toward +x (clockwise seen from above).
    public let heading: Double

    public init(time: TimeInterval, length: Double, heading: Double) {
        self.time = time
        self.length = length
        self.heading = heading
    }

    /// Displacement in the frame's floor plane.
    public var dx: Double { length * sin(heading) }
    public var dz: Double { length * cos(heading) }
}

/// Pedestrian dead reckoning from device motion. Steps are peaks of the vertical acceleration,
/// stride length follows their swing (Weinberg), and heading integrates the gyro rate about
/// gravity, so it works whether the phone is held flat or upright. Heading is relative: align it
/// with the frame once (`alignHeading`); it drifts slowly after that and must never be presented
/// as a measured position on its own.
public struct PedestrianDeadReckoning {
    public struct Configuration {
        /// Weinberg constant: stride = K · (peak-to-peak vertical acceleration in m/s²)^¼.
        public var strideConstant = 0.47
        public var strideRange = 0.25...1.2
        /// Minimum filtered vertical acceleration of a step peak, m/s².
        public var peakThreshold = 1.2
        public var minStepInterval: TimeInterval = 0.28
        /// A longer pause ends a walk; the next peak starts a new one.
        public var maxStepInterval: TimeInterval = 2.0
        public var smoothingCutoffHz = 3.0

        public init() {}
    }

    public static let standardGravity = 9.80665

    public var configuration: Configuration
    public private(set) var heading: Double = 0
    public private(set) var stepCount = 0
    public private(set) var lastStep: Step?
    private var lastStepInterval: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private var filtered = 0.0
    private var previous = 0.0
    private var rising = false
    private var swingMin = 0.0
    private var swingMax = 0.0
    private var headingSin = 0.0
    private var headingCos = 0.0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Sets the current frame heading, for example 0 while the user faces +z.
    public mutating func alignHeading(_ value: Double) {
        heading = normalizedAngle(value)
        headingSin = 0
        headingCos = 0
    }

    public func isWalking(at time: TimeInterval) -> Bool {
        lastStep.map { time - $0.time <= configuration.maxStepInterval } ?? false
    }

    /// Walking speed from the latest step; 0 once the phone stops stepping.
    public func speed(at time: TimeInterval) -> Double {
        guard isWalking(at: time), let lastStep, let lastStepInterval else { return 0 }
        return lastStep.length / max(lastStepInterval, configuration.minStepInterval)
    }

    /// Feeds one sample; returns a step when one completes.
    public mutating func process(_ sample: MotionSample) -> Step? {
        let gravityLength = sample.gravity.length
        guard gravityLength > 0.1 else { return nil }
        let down = Vector3(x: sample.gravity.x / gravityLength, y: sample.gravity.y / gravityLength,
                           z: sample.gravity.z / gravityLength)
        let vertical = -sample.userAcceleration.dot(down) * Self.standardGravity

        guard let last = lastSampleTime, sample.time - last > 0, sample.time - last < 0.5 else {
            // First sample or a gap in the feed: restart the filters without integrating across it.
            lastSampleTime = sample.time
            filtered = vertical
            previous = vertical
            rising = false
            swingMin = vertical
            swingMax = vertical
            return nil
        }
        let dt = sample.time - last
        lastSampleTime = sample.time

        // The rotation rate about "up" is counterclockwise seen from above; heading turns clockwise.
        heading = normalizedAngle(heading + sample.rotationRate.dot(down) * dt)
        headingSin += sin(heading)
        headingCos += cos(heading)

        let alpha = 1 - exp(-2 * Double.pi * configuration.smoothingCutoffHz * dt)
        filtered += alpha * (vertical - filtered)
        swingMin = min(swingMin, filtered)
        swingMax = max(swingMax, filtered)
        defer { previous = filtered }

        // A step is a local maximum of the filtered vertical acceleration above the threshold.
        let wasRising = rising
        rising = filtered > previous
        guard wasRising, !rising, previous >= configuration.peakThreshold else { return nil }
        let interval = lastStep.map { sample.time - $0.time } ?? .infinity
        guard interval >= configuration.minStepInterval else { return nil }

        let swing = max(0, swingMax - swingMin)
        let range = configuration.strideRange
        let length = min(range.upperBound, max(range.lowerBound, configuration.strideConstant * pow(swing, 0.25)))
        let stepHeading = headingSin == 0 && headingCos == 0 ? heading : atan2(headingSin, headingCos)
        let step = Step(time: sample.time, length: length, heading: stepHeading)
        lastStepInterval = interval <= configuration.maxStepInterval ? interval : nil
        lastStep = step
        stepCount += 1
        swingMin = filtered
        swingMax = filtered
        headingSin = 0
        headingCos = 0
        return step
    }
}
