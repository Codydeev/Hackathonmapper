import Foundation

public struct RSSIStatistics {
    /// Smoothing time constant. Time-based, so uneven sample rates smooth over the same window.
    public static let timeConstant: TimeInterval = 3

    public private(set) var raw: Int?
    public private(set) var smoothed: Double?
    public private(set) var sampleCount: Int = 0
    public private(set) var lastSampleAt: Date?

    private var samples: [Double] = []

    public init() {}

    @discardableResult
    public mutating func record(_ rssi: Int, at now: Date = Date()) -> Bool {
        guard rssi != 127, (-127...20).contains(rssi) else { return false }
        let value = Double(rssi)
        raw = rssi
        if let smoothed, let lastSampleAt {
            let elapsed = max(0, now.timeIntervalSince(lastSampleAt))
            let alpha = 1 - exp(-elapsed / Self.timeConstant)
            self.smoothed = smoothed + alpha * (value - smoothed)
        } else {
            smoothed = value
        }
        lastSampleAt = now
        if sampleCount < Int.max { sampleCount += 1 }
        if samples.count == 20 { samples.removeFirst() }
        samples.append(value)
        return true
    }

    // Population deviation over the last 20 accepted samples; nil before any samples.
    public var standardDeviation: Double? {
        guard !samples.isEmpty else { return nil }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { sum, value in
            sum + (value - mean) * (value - mean)
        } / Double(samples.count)
        return variance.squareRoot()
    }
}
