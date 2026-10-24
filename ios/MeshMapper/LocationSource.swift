import CoreLocation
import Foundation

/// The phone's own GPS. A fix counts only while it is fresh and precise enough to place the phone
/// in the shared frame; otherwise the phone reports no position (`PositionSource.none`) and the
/// dashboard places it from its Bluetooth links instead.
@MainActor
final class LocationSource: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let maxAccuracyMeters: CLLocationAccuracy = 30
    /// A phone lying still (the GPS anchor on a table) gets few or no new fixes; its last one stays good.
    static let maxAge: TimeInterval = 30

    @Published private(set) var latest: CLLocation?
    /// Compass, for the GPS check's step directions.
    @Published private(set) var heading: CLHeading?
    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // iOS otherwise pauses updates when the phone is still, and the anchor would drop out.
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 1
            manager.startUpdatingHeading()
        }
    }

    /// The latest fix if it can be used as a measured position right now.
    func usableFix(at now: Date = Date()) -> CLLocation? {
        guard let latest, latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy <= Self.maxAccuracyMeters,
              now.timeIntervalSince(latest.timestamp) <= Self.maxAge else { return nil }
        return latest
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.latest = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.heading = newHeading }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (no fix yet) are normal; the fix simply goes stale.
    }
}
