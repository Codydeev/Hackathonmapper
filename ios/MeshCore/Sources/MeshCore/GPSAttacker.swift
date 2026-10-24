import Foundation

// Simulated interference applied on top of any GNSS stream (simulated or the phone's real one),
// so the GPS check can be demonstrated anywhere, legally. Swift port of js/attacker.js in the
// Luotsi prototype (gps-katoaa), with the same seeded noise stream:
//   jam       accuracy collapses, then fixes stop (Gulf of Finland style jamming)
//   teleport  receiver locks onto a fake signal placing you at Pulkovo airport
//   drag      sophisticated spoof: position slides away slowly at walking pace

public enum GPSAttack: String, CaseIterable {
    /// Fixes scatter by ~30 m with accuracy collapsing from 60 m for 3 s, then stop.
    case jam
    /// Fixes come from the teleport target (±2 m) with a confident 3 m accuracy.
    case teleport
    /// Fixes slide away from the true position at a steady rate (0.5 m/s towards 75° by default).
    case drag
}

public struct GPSAttacker {
    /// Pulkovo airport, the teleport target used in the Luotsi demo.
    public static let pulkovo = (latitude: 59.8003, longitude: 30.2625)

    public private(set) var mode: GPSAttack?
    private var rand: SeededRandom
    private var startedAt = 0.0
    /// m/s and radians (0 = north, clockwise); both persist from one drag to the next.
    private var dragRate = 0.5
    private var dragDirection = LuotsiGeo.rad(75)
    private let fake: (x: Double, y: Double)

    /// `teleportTo`: the fake position (Pulkovo) in the same local frame as the fixes.
    public init(teleportTo: (x: Double, y: Double), seed: UInt32 = 11) {
        fake = teleportTo
        rand = SeededRandom(seed: seed)
    }

    /// Starts (or switches to) an attack at time `t`. For a drag, a non-zero `dragRate` (m/s) and a
    /// `dragDirectionDegrees` (0 = north, clockwise) replace the previous ones; otherwise those stay.
    public mutating func start(_ mode: GPSAttack, t: Double, dragRate: Double? = nil, dragDirectionDegrees: Double? = nil) {
        self.mode = mode
        startedAt = t
        // JavaScript `if (opts.dragRate)`: zero or NaN leave the rate unchanged.
        if let dragRate, dragRate != 0, !dragRate.isNaN { self.dragRate = dragRate }
        if let dragDirectionDegrees { dragDirection = LuotsiGeo.rad(dragDirectionDegrees) }
    }

    public mutating func stop() {
        mode = nil
    }

    /// Seconds since the attack started; 0 when there is none.
    public func elapsed(t: Double) -> Double {
        mode == nil ? 0 : t - startedAt
    }

    /// The fix the receiver would report, or nil for no fix.
    public mutating func apply(t: Double, x: Double, y: Double, accuracy: Double) -> (x: Double, y: Double, accuracy: Double)? {
        guard let mode else { return (x, y, accuracy) }
        let dt = t - startedAt
        switch mode {
        case .jam:
            guard dt < 3 else { return nil }
            let jx = x + 30 * rand.gauss()
            let jy = y + 30 * rand.gauss()
            return (jx, jy, 60 + 40 * dt)
        case .teleport:
            let fx = fake.x + 2 * rand.gauss()
            let fy = fake.y + 2 * rand.gauss()
            return (fx, fy, 3)
        case .drag:
            let off = dragRate * dt
            return (x + off * sin(dragDirection), y + off * cos(dragDirection), accuracy)
        }
    }
}
