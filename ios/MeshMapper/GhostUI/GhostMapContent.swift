import MapKit
import MeshCore
import SwiftUI

/// Everything GhostCore draws on the map, bottom to top: Bluetooth links, relay routes, uncertainty
/// (circles, candidate rings, particle and prediction clouds), raw GPS the trust checks refused, and
/// the phones themselves.
struct GhostMapContent: MapContent {
    let scene: VizScene
    let selectedId: String?
    let onSelect: (String) -> Void

    var body: some MapContent {
        ForEach(scene.links) { link in
            if let a = coordinate(scene.drawnPoint(link.a)), let b = coordinate(scene.drawnPoint(link.b)) {
                MapPolyline(coordinates: [a, b])
                    .stroke(.white.opacity(Self.linkOpacity(link.rssi)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
            }
        }

        ForEach(scene.routes.filter { !$0.relays.isEmpty }) { route in
            let hops = ([route.origin] + route.relays + [scene.selfId]).compactMap { coordinate(scene.drawnPoint($0)) }
            if hops.count >= 2 {
                MapPolyline(coordinates: hops)
                    .stroke(GhostTheme.route.opacity(0.85),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [10, 6]))
            }
        }

        ForEach(scene.phones) { phone in
            uncertainty(phone)
        }

        ForEach(scene.phones) { phone in
            rawFixGhost(phone)
        }

        ForEach(scene.phones) { phone in
            if let point = scene.drawnPoint(phone.id), let c = coordinate(point) {
                Annotation("", coordinate: c, anchor: .center) {
                    GhostMarker(phone: phone, presentation: VizPresentation.of(phone, scene: scene),
                                selected: phone.id == selectedId, now: scene.now)
                        .onTapGesture { onSelect(phone.id) }
                }
            }
        }
    }

    // MARK: - Layers

    @MapContentBuilder
    private func uncertainty(_ phone: VizPhone) -> some MapContent {
        let tint = GhostMarker.color(VizPresentation.of(phone, scene: scene).tint)
        if phone.kind == .predicted, let prediction = phone.prediction {
            ForEach(Array(prediction.cloud.prefix(80).enumerated()), id: \.offset) { _, p in
                if let c = coordinate(p) {
                    MapCircle(center: c, radius: 1.3).foregroundStyle(GhostTheme.predicted.opacity(0.55))
                }
            }
            if let r95 = prediction.r95, r95 > 0, let c = coordinate(prediction.center) {
                MapCircle(center: c, radius: r95)
                    .foregroundStyle(GhostTheme.predicted.opacity(0.08))
                    .stroke(GhostTheme.predicted.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
        } else if phone.ambiguous, !phone.candidates.isEmpty {
            // An estimate that cannot pick between spots: one ring per candidate, no single dot.
            ForEach(Array(phone.candidates.enumerated()), id: \.offset) { _, p in
                if let c = coordinate(p) {
                    MapCircle(center: c, radius: max(phone.r95 ?? 8, 4) / 2)
                        .foregroundStyle(tint.opacity(0.10))
                        .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                }
            }
        } else if let point = phone.point, let c = coordinate(point) {
            ForEach(Array(phone.cloud.enumerated()), id: \.offset) { _, p in
                if let dot = coordinate(p) {
                    MapCircle(center: dot, radius: 0.9).foregroundStyle(tint.opacity(0.45))
                }
            }
            if let r95 = phone.r95, r95 > 0 {
                MapCircle(center: c, radius: r95)
                    .foregroundStyle(tint.opacity(0.12))
                    .stroke(tint.opacity(0.85), lineWidth: 1.5)
            }
        }
    }

    /// The raw GPS fix the trust checks judged, when it was refused or doubted and lies away from
    /// where GhostCore puts the phone: a red ghost with a dashed line back to the estimate.
    @MapContentBuilder
    private func rawFixGhost(_ phone: VizPhone) -> some MapContent {
        if let integrity = phone.integrity, let fix = integrity.evaluatedFix,
           [.rejected, .suspect, .degraded].contains(integrity.status),
           let raw = coordinate(fix.point) {
            let tint = integrity.status == .rejected ? GhostTheme.rejected : GhostTheme.suspect
            if let shown = scene.drawnPoint(phone.id), let estimate = coordinate(shown),
               hypot(shown.x - fix.point.x, shown.z - fix.point.z) > 3 {
                MapPolyline(coordinates: [raw, estimate])
                    .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [2, 6]))
            }
            MapCircle(center: raw, radius: max(fix.claimedR95, 2))
                .foregroundStyle(tint.opacity(0.10))
                .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Annotation("", coordinate: raw, anchor: .center) {
                RawFixMarker(label: phone.isSelf ? "Raw GPS" : "\(phone.label) raw GPS",
                             status: integrity.status, simulated: fix.simulated)
                    .onTapGesture { onSelect(phone.id) }
            }
        }
    }

    // MARK: - Geometry

    private func coordinate(_ point: FloorPoint?) -> CLLocationCoordinate2D? {
        guard let point, let c = GeoFrame.coordinate(frameId: scene.frameId, x: point.x, z: point.z) else { return nil }
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    /// Stronger links draw brighter: -55 dBm and up fully, fading out by -95 dBm.
    static func linkOpacity(_ rssi: Double) -> Double {
        0.25 + 0.6 * min(1, max(0, (rssi + 95) / 40))
    }
}
