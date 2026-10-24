import Foundation

/// Pure rules for the on-phone map (labels, camera span and refit, consistency checks, titles),
/// kept out of the SwiftUI views so they can be unit tested without MapKit.
///
/// Honesty (app.md): nothing here calls a position "measured". A UWB distance is measured, a
/// position solved from it is "UWB-ranged", and a position from signal strength is a
/// "Bluetooth estimate".
public enum MapPresentation {
    /// Narrowest span the camera shows, in meters, so a phone 2 m away is not a full screen away.
    public static let minimumSpan = 25.0
    /// Widest span the camera fits automatically.
    public static let maximumSpan = 20_000.0
    /// Span per meter to the farthest direct neighbour.
    public static let neighborSpanFactor = 2.5
    /// The camera refits only when the needed span changes by more than this fraction.
    public static let refitChange = 0.3
    /// ...or when this phone moved by more than this fraction of the shown span.
    public static let recenterFraction = 0.25
    /// A drawn link is inconsistent when it differs from the measured distance by more than
    /// max(`inconsistentMeters`, `inconsistentFraction` × measured).
    public static let inconsistentMeters = 1.0
    public static let inconsistentFraction = 0.3
    /// Heading-up rotates the map only when the compass moved more than this many degrees.
    public static let headingStep = 4.0

    /// "3.42 m" for a UWB distance, "≈ 4 m" for a distance from signal strength, "" for neither.
    public static func linkLabel(uwb: Double?, rssiDistance: Double?) -> String {
        if let uwb, uwb.isFinite, uwb >= 0 { return String(format: "%.2f m", uwb) }
        if let rssiDistance, rssiDistance.isFinite, rssiDistance >= 0 { return "≈ " + roughMeters(rssiDistance) }
        return ""
    }

    /// Whole meters (km beyond 1000), never "0 m": signal strength is not that precise.
    public static func roughMeters(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.1f km", value / 1000) }
        return "\(max(1, Int(value.rounded()))) m"
    }

    /// Camera span (meters, the narrower screen side) centred on `selfPoint`: 2.5 × the farthest
    /// direct neighbour, at least `minimumSpan`.
    public static func cameraSpan(selfPoint: FloorPoint?, neighbors: [FloorPoint]) -> Double {
        guard let selfPoint else { return minimumSpan }
        let farthest = neighbors
            .map { hypot($0.x - selfPoint.x, $0.z - selfPoint.z) }
            .filter(\.isFinite)
            .max() ?? 0
        return min(maximumSpan, max(minimumSpan, neighborSpanFactor * farthest))
    }

    /// Hysteresis: refit when there is no fitted span yet or the needed one changed by > 30 %.
    public static func shouldRefit(current: Double?, needed: Double) -> Bool {
        guard let current, current > 0, current.isFinite else { return true }
        return abs(needed - current) / current > refitChange
    }

    /// Recentre when this phone walked more than a quarter of the shown span away from the centre.
    public static func shouldRecenter(moved: Double, span: Double) -> Bool {
        moved > recenterFraction * span
    }

    /// True when the link drawn on the map is off from the measured distance by more than
    /// max(1 m, 30 %): the layout could not honour that measurement.
    public static func isInconsistent(drawn: Double, measured: Double) -> Bool {
        guard drawn.isFinite, measured.isFinite else { return false }
        return abs(drawn - measured) > max(inconsistentMeters, inconsistentFraction * measured)
    }

    /// Smallest difference between two compass angles, 0...180 degrees.
    public static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).truncatingRemainder(dividingBy: 360)
        let wrapped = d < 0 ? d + 360 : d
        return min(wrapped, 360 - wrapped)
    }

    /// Whether heading-up should rotate the map from `current` to `heading`.
    public static func shouldRotate(current: Double, heading: Double) -> Bool {
        angleDifference(current, heading) > headingStep
    }

    /// Short title for where a position comes from.
    public static func statusTitle(basis: PositionBasis, ambiguous: Bool) -> String {
        let title: String
        switch basis {
        case .reported(let source):
            switch source {
            case .gps: title = "GPS"
            case .manual: title = "Pinned spot"
            case .uwb: title = "UWB anchor fix"
            case .none: title = "No position"
            }
        case .gpsRefined: title = "GPS + UWB"
        case .uwbRanged: title = "UWB-ranged"
        case .bluetooth: title = "Bluetooth estimate"
        }
        return ambiguous ? title + " · direction unknown" : title
    }

    /// Caption of a direction-unresolved phone's ring: "Otter 42 · 4.1 m · direction unknown".
    public static func ringCaption(label: String, radius: Double) -> String {
        "\(label) · \(ringMeters(radius)) · direction unknown"
    }

    /// One decimal below 100 m, whole meters above.
    public static func ringMeters(_ value: Double) -> String {
        value < 100 ? String(format: "%.1f m", value) : roughMeters(value)
    }
}
