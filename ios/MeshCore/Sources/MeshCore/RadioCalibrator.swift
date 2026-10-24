import Foundation

/// Fits the radio model's p0 (dBm at 1 m) online from links that have both an RSSI and a UWB
/// distance, so links with RSSI only (phones without UWB, or beyond UWB range) get distances from
/// what these phones in this place actually receive. The path-loss exponent stays fixed: one
/// demo field gives too narrow a spread of distances to fit both.
public struct RadioCalibrator {
    /// Samples kept (the most recent ones).
    public static let window = 120
    /// Below this many samples the base model is used as it is.
    public static let minimumSamples = 10
    /// A fitted p0 outside this range is clamped into it.
    public static let p0Range = -75.0 ... -45.0
    /// UWB distances below this are skipped: the model is flat under 0.5 m.
    public static let minimumDistance = 0.5

    public let base: RadioModel
    private var samples: [Double] = []

    public init(base: RadioModel = .outdoors) {
        self.base = base
    }

    public var sampleCount: Int { samples.count }

    /// One link: the p0 that would make the model predict `rssi` at `uwbDistance`.
    public mutating func add(rssi: Double, uwbDistance: Double) {
        guard rssi.isFinite, uwbDistance.isFinite, uwbDistance >= Self.minimumDistance else { return }
        samples.append(rssi + 10 * base.n * log10(uwbDistance))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// Every link of one update that has both measurements.
    public mutating func add(_ measurements: [LinkMeasurement]) {
        for m in measurements {
            guard let rssi = m.rssi, let distance = m.uwbDistance else { continue }
            add(rssi: rssi, uwbDistance: distance)
        }
    }

    /// The base model with p0 set to the median of the samples (robust to body-blocked links).
    public var radio: RadioModel {
        guard samples.count >= Self.minimumSamples else { return base }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        var fitted = base
        fitted.p0 = min(max(median, Self.p0Range.lowerBound), Self.p0Range.upperBound)
        return fitted
    }
}
