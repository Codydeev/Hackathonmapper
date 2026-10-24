import Foundation

/// Extended Kalman filter over this phone's floor position (x, z), its radio's RSSI offset (dB) and
/// the gyro heading's offset from the frame (radians).
///
/// Steps move the estimate and grow its uncertainty; each anchor's RSSI corrects it in the dB
/// domain, where fading is roughly Gaussian. Because uncertainty only grows as fast as the phone
/// walks, an RSSI value implying a jump the steps cannot explain fails the innovation gate. The
/// offsets absorb errors that differ between devices and sensors: a radio reading a few dB hot or
/// cold, and gyro heading that slowly drifts away from the frame over minutes of walking.
public struct PositionFilter {
    public enum UpdateResult: Equatable {
        case accepted, rejected, skipped
    }

    static let size = 4

    /// x, z (meters), receiver offset (dB), heading offset (radians).
    public private(set) var state: [Double]
    public private(set) var covariance: [[Double]]

    public var x: Double { state[0] }
    public var z: Double { state[1] }
    public var receiverOffsetDB: Double { state[2] }
    /// Added to the dead-reckoning heading to get the frame heading.
    public var headingOffset: Double { state[3] }
    /// One-sigma radial position error, meters.
    public var accuracy: Double { max(0, covariance[0][0] + covariance[1][1]).squareRoot() }
    /// Radius holding the position 95 % of the time, what `accuracyMeters` means on the wire:
    /// 2.4477 per-axis sigmas, and `accuracy` is √2 per-axis sigmas.
    public var r95: Double { accuracy * SignalMap.r95PerSigma / 2.squareRoot() }
    public var receiverOffsetSigmaDB: Double { max(0, covariance[2][2]).squareRoot() }
    public var headingOffsetSigma: Double { max(0, covariance[3][3]).squareRoot() }

    public init(x: Double, z: Double, positionSigma: Double, receiverOffsetDB: Double = 0,
                offsetSigmaDB: Double = 4, headingSigma: Double = 0.2) {
        state = [x, z, receiverOffsetDB, 0]
        let variances = [positionSigma * positionSigma, positionSigma * positionSigma,
                         offsetSigmaDB * offsetSigmaDB, headingSigma * headingSigma]
        covariance = (0..<Self.size).map { i in (0..<Self.size).map { i == $0 ? variances[i] : 0 } }
    }

    /// Restarts the position; the learned offsets are kept.
    public mutating func reset(x: Double, z: Double, positionSigma: Double) {
        state[0] = x
        state[1] = z
        for i in 0..<Self.size {
            for j in 0..<2 {
                covariance[i][j] = 0
                covariance[j][i] = 0
            }
        }
        covariance[0][0] = positionSigma * positionSigma
        covariance[1][1] = positionSigma * positionSigma
    }

    /// Restarts the heading offset, after the user re-aligned the heading with the frame.
    public mutating func resetHeading(sigma: Double) {
        state[3] = 0
        for i in 0..<Self.size {
            covariance[i][3] = 0
            covariance[3][i] = 0
        }
        covariance[3][3] = sigma * sigma
    }

    /// Moves by a step of `length` meters at dead-reckoning `heading`. Stride error runs along the
    /// step, per-step heading noise across it, and `headingDrift` (radians) is gyro drift per step.
    public mutating func predict(length: Double, heading: Double, alongSigma: Double, crossSigma: Double,
                                 headingDrift: Double) {
        let theta = heading + state[3]
        let dx = length * sin(theta)
        let dz = length * cos(theta)
        state[0] += dx
        state[1] += dz

        // P = F P Fᵀ, where F is the identity except for the step's dependence on the heading offset.
        var f = (0..<Self.size).map { i in (0..<Self.size).map { i == $0 ? 1.0 : 0.0 } }
        f[0][3] = dz
        f[1][3] = -dx
        let fp = (0..<Self.size).map { i in
            (0..<Self.size).map { j in (0..<Self.size).reduce(0.0) { $0 + f[i][$1] * covariance[$1][j] } }
        }
        covariance = (0..<Self.size).map { i in
            (0..<Self.size).map { j in (0..<Self.size).reduce(0.0) { $0 + fp[i][$1] * f[j][$1] } }
        }

        let ux = sin(theta)
        let uz = cos(theta)
        let along = alongSigma * alongSigma
        let cross = crossSigma * crossSigma
        // Q = R · diag(along, cross) · Rᵀ with R = [[ux, uz], [uz, -ux]].
        covariance[0][0] += along * ux * ux + cross * uz * uz
        covariance[1][1] += along * uz * uz + cross * ux * ux
        covariance[0][1] += (along - cross) * ux * uz
        covariance[1][0] += (along - cross) * ux * uz
        covariance[3][3] += headingDrift * headingDrift
    }

    /// Random-walk noise for movement the step detector misses and slow radio drift.
    public mutating func addProcessNoise(seconds: Double, positionVariancePerSecond: Double, offsetVariancePerSecond: Double) {
        let dt = max(0, seconds)
        covariance[0][0] += positionVariancePerSecond * dt
        covariance[1][1] += positionVariancePerSecond * dt
        covariance[2][2] += offsetVariancePerSecond * dt
    }

    /// The range from this phone to an anchor, including the height difference.
    public func distance(toX anchorX: Double, z anchorZ: Double, verticalOffset: Double) -> Double {
        let dx = state[0] - anchorX
        let dz = state[1] - anchorZ
        return (dx * dx + dz * dz + verticalOffset * verticalOffset).squareRoot()
    }

    /// Corrects with one anchor's RSSI. `rssi` must already exclude the anchor's own radio offset.
    /// `gate` is the largest accepted squared innovation in standard deviations.
    @discardableResult
    public mutating func update(
        rssi: Double,
        sigmaDB: Double,
        anchorX: Double,
        anchorZ: Double,
        verticalOffset: Double,
        anchorSigma: Double,
        model: PathLossModel,
        gate: Double = 9
    ) -> UpdateResult {
        let dx = state[0] - anchorX
        let dz = state[1] - anchorZ
        let horizontal = (dx * dx + dz * dz).squareRoot()
        // The bearing to an anchor is undefined on top of it.
        guard horizontal > 0.05, rssi.isFinite else { return .skipped }
        let distance = (horizontal * horizontal + verticalOffset * verticalOffset).squareRoot()
        let predicted = model.predictedRSSI(at: distance) + state[2]
        // d rssi / d x = -(10 n / ln 10) · dx / d²; flat inside the model's minimum distance.
        let slope = distance > PathLossModel.minDistance ? -model.dBPerLogDistance / (distance * distance) : 0
        let h = [slope * dx, slope * dz, 1.0, 0.0]
        let anchorDB = model.dBPerLogDistance * anchorSigma / max(distance, PathLossModel.minDistance)
        let noise = sigmaDB * sigmaDB + anchorDB * anchorDB

        let ph = (0..<Self.size).map { i in (0..<Self.size).reduce(0.0) { $0 + covariance[i][$1] * h[$1] } }
        let s = (0..<Self.size).reduce(0.0) { $0 + h[$1] * ph[$1] } + noise
        let innovation = rssi - predicted
        guard s > 0, innovation * innovation / s <= gate else { return .rejected }
        apply(ph: ph, s: s, innovation: innovation)
        return .accepted
    }

    /// Corrects with a known position, for example standing next to an anchor.
    public mutating func observePosition(x targetX: Double, z targetZ: Double, sigma: Double) {
        let noise = sigma * sigma
        for (axis, target) in [(0, targetX), (1, targetZ)] {
            let ph = (0..<Self.size).map { covariance[$0][axis] }
            apply(ph: ph, s: covariance[axis][axis] + noise, innovation: target - state[axis])
        }
    }

    private mutating func apply(ph: [Double], s: Double, innovation: Double) {
        let gain = ph.map { $0 / s }
        for i in 0..<Self.size { state[i] += gain[i] * innovation }
        state[3] = normalizedAngle(state[3])
        for i in 0..<Self.size {
            for j in 0..<Self.size { covariance[i][j] -= gain[i] * ph[j] }
        }
        // Keep the covariance symmetric despite rounding.
        for i in 0..<Self.size {
            for j in (i + 1)..<Self.size {
                let mean = (covariance[i][j] + covariance[j][i]) / 2
                covariance[i][j] = mean
                covariance[j][i] = mean
            }
        }
    }
}
