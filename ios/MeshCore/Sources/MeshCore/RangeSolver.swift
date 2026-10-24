import Foundation

/// RSSI from one anchor, already corrected for both radios' offsets.
public struct RangeInput: Equatable {
    public let anchorX: Double
    public let anchorZ: Double
    public let verticalOffset: Double
    public let rssi: Double
    public let sigmaDB: Double

    public init(anchorX: Double, anchorZ: Double, verticalOffset: Double, rssi: Double, sigmaDB: Double) {
        self.anchorX = anchorX
        self.anchorZ = anchorZ
        self.verticalOffset = verticalOffset
        self.rssi = rssi
        self.sigmaDB = sigmaDB
    }
}

public struct RangeFix: Equatable {
    public let x: Double
    public let z: Double
    /// One-sigma radial error from the geometry and RSSI spread, meters.
    public let accuracy: Double
    public let anchorCount: Int
    /// Weighted RMS of the remaining RSSI residuals, dB.
    public let residualDB: Double
}

/// RSSI-only position from three or more anchors: robust (Huber-weighted) Gauss-Newton in the
/// dB domain. Shown on its own in the app and used to start or recover the fused estimate;
/// never published as a measured position by itself.
public enum RangeSolver {
    public static func solve(_ inputs: [RangeInput], model: PathLossModel, iterations: Int = 15) -> RangeFix? {
        let usable = inputs.filter { $0.rssi.isFinite && $0.sigmaDB > 0 }
        guard usable.count >= 3 else { return nil }

        // Start at the centroid weighted toward the strongest (closest) anchors.
        let weights = usable.map { input -> Double in
            let d = model.distance(for: input.rssi)
            return 1 / (d * d)
        }
        let total = weights.reduce(0, +)
        var x = zip(usable, weights).reduce(0.0) { $0 + $1.0.anchorX * $1.1 } / total
        var z = zip(usable, weights).reduce(0.0) { $0 + $1.0.anchorZ * $1.1 } / total

        var information = [[0.0, 0.0], [0.0, 0.0]]
        var residualDB = 0.0
        for _ in 0..<iterations {
            var a = [[0.0, 0.0], [0.0, 0.0]]
            var b = [0.0, 0.0]
            var squares = 0.0
            var weightSum = 0.0
            for input in usable {
                var dx = x - input.anchorX
                var dz = z - input.anchorZ
                if dx * dx + dz * dz < 1e-6 { dx = 0.01; dz = 0.01 }
                let d2 = dx * dx + dz * dz + input.verticalOffset * input.verticalOffset
                let distance = d2.squareRoot()
                let residual = input.rssi - model.predictedRSSI(at: distance)
                let slope = distance > PathLossModel.minDistance ? -model.dBPerLogDistance / d2 : 0
                let j = [slope * dx, slope * dz]
                // Huber: full weight within 1.5 σ, then down-weighted so one blocked anchor can't dominate.
                let normalized = abs(residual) / input.sigmaDB
                let robust = normalized <= 1.5 ? 1 : 1.5 / normalized
                let w = robust / (input.sigmaDB * input.sigmaDB)
                for r in 0..<2 {
                    for c in 0..<2 { a[r][c] += w * j[r] * j[c] }
                    b[r] += w * j[r] * residual
                }
                squares += w * residual * residual
                weightSum += w
            }
            information = a
            residualDB = weightSum > 0 ? (squares / weightSum).squareRoot() : 0
            // A little damping keeps nearly collinear anchors from throwing the estimate away.
            let damping = 1e-3 * (a[0][0] + a[1][1]) + 1e-9
            a[0][0] += damping
            a[1][1] += damping
            guard let delta = solveLinearSystem(a, b) else { break }
            let length = (delta[0] * delta[0] + delta[1] * delta[1]).squareRoot()
            let scale = length > 5 ? 5 / length : 1
            x += delta[0] * scale
            z += delta[1] * scale
            if length < 1e-3 { break }
        }

        let det = information[0][0] * information[1][1] - information[0][1] * information[1][0]
        let trace = information[0][0] + information[1][1]
        let accuracy = det > 1e-12 ? (trace / det).squareRoot() : DashboardContract.maxAccuracyMeters
        guard x.isFinite, z.isFinite else { return nil }
        return RangeFix(x: x, z: z, accuracy: min(accuracy, DashboardContract.maxAccuracyMeters),
                        anchorCount: usable.count, residualDB: residualDB)
    }
}
