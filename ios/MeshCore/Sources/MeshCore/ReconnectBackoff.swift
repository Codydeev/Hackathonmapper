import Foundation

/// Retry schedule for a failed outgoing BLE link: 5, 10, 20, 40, then 60 s, plus up to 2 s of
/// jitter so neighbors that lost each other at the same moment don't retry in lockstep. A link that
/// stayed ready for `stableLinkAge` clears its failure count.
public enum ReconnectBackoff {
    public static let initialDelay: TimeInterval = 5
    public static let maximumDelay: TimeInterval = 60
    public static let maximumJitter: TimeInterval = 2
    public static let stableLinkAge: TimeInterval = 30

    /// Delay before the next attempt after `failures` consecutive failures (1 for the first).
    public static func delay(afterFailures failures: Int, jitter: TimeInterval = .random(in: 0...maximumJitter)) -> TimeInterval {
        let exponent = Double(min(max(failures, 1), 16) - 1)
        return min(maximumDelay, initialDelay * pow(2, exponent)) + min(max(jitter, 0), maximumJitter)
    }
}
