import Foundation

public struct RSSISample: Codable, Equatable {
    public let rssi: Int
    public let at: Date

    public init(rssi: Int, at: Date) {
        self.rssi = rssi
        self.at = at
    }
}

public struct RSSIStatistics {
    /// Smoothing time constant. Time-based, so uneven sample rates smooth over the same window.
    public static let timeConstant: TimeInterval = 3
    /// Raw samples kept between two `takeRecentSamples()` calls; older ones are counted, not kept.
    public static let maxRecentSamples = 16

    public private(set) var raw: Int?
    public private(set) var smoothed: Double?
    public private(set) var sampleCount: Int = 0
    public private(set) var lastSampleAt: Date?
    /// Accepted raw samples since the last `takeRecentSamples()`, oldest first.
    public private(set) var recentSamples: [RSSISample] = []
    public private(set) var droppedRecentSamples = 0

    private var samples: [Double] = []

    /// Returns and clears the raw samples since the previous call, plus how many did not fit.
    public mutating func takeRecentSamples() -> (samples: [RSSISample], dropped: Int) {
        defer {
            recentSamples.removeAll()
            droppedRecentSamples = 0
        }
        return (recentSamples, droppedRecentSamples)
    }

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
        if recentSamples.count == Self.maxRecentSamples {
            recentSamples.removeFirst()
            droppedRecentSamples += 1
        }
        recentSamples.append(RSSISample(rssi: rssi, at: now))
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
