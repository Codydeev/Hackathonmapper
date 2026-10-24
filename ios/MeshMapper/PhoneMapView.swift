import MapKit
import MeshCore
import SwiftUI

/// The whole app for most people: one map with this phone and every phone the mesh reaches.
/// A phone without GPS is placed here, on the phone itself, from the Bluetooth signal of the
/// phones around it; when Bluetooth loses it, the movement model keeps predicting where it is.
@MainActor
struct PhoneMapView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var tracker: BluetoothTracker
    @ObservedObject var predictor: MovementPredictor
    @ObservedObject var bluetooth: BluetoothMesh
    @ObservedObject var location: LocationSource
    /// Not observed here: only the status card redraws when the GPS check changes.
    let gpsGuard: GPSGuard

    /// Starts over the frame's origin (Hervanta campus) until there is someone to show.
    @State private var camera: MapCameraPosition = {
        guard let origin = GeoFrame.origins[GeoFrame.defaultFrameId] else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        return .region(MKCoordinateRegion(center: center, latitudinalMeters: 600, longitudinalMeters: 600))
    }()
    @State private var following = true
    @State private var pinning = false

    private static let gpsColor = Color(red: 0.72, green: 0.57, blue: 1.0)
    private static let bluetoothColor = Color(red: 0.31, green: 0.83, blue: 0.92)
    private static let predictedColor = Color.orange

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(tracker.links) { link in
                        if let a = coordinate(ofPhone: link.a), let b = coordinate(ofPhone: link.b) {
                            MapPolyline(coordinates: [a, b])
                                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                    }
                    ForEach(tracker.phones) { phone in
                        // Route model: which way a lost phone probably went, and where along each route by now.
                        if let options = predictor.routes[phone.id]?.options {
                            ForEach(options) { option in
                                if let band = polyline(option.band) {
                                    MapPolyline(coordinates: band)
                                        .stroke(Self.routeColor(option.id).opacity(0.3), lineWidth: 12)
                                }
                                if let line = polyline(option.line) {
                                    MapPolyline(coordinates: line)
                                        .stroke(Self.routeColor(option.id).opacity(0.9), lineWidth: 3)
                                }
                                if let here = option.here.flatMap(coordinate) {
                                    Annotation("", coordinate: here) {
                                        RouteTag(percent: option.probability, color: Self.routeColor(option.id))
                                    }
                                }
                            }
                        }
                        if let cloud = predictor.clouds[phone.id] {
                            ForEach(Array(cloud.points.enumerated()), id: \.offset) { _, point in
                                if let c = coordinate(point) {
                                    Annotation("", coordinate: c) { Dot(color: Self.predictedColor, size: 4) }
                                }
                            }
                            if let c = coordinate(cloud.center) {
                                Annotation(name(phone), coordinate: c) {
                                    PhoneMarker(color: Self.predictedColor, isSelf: phone.isSelf, dashed: true)
                                }
                            }
                        } else if let point = phone.point, let c = coordinate(point) {
                            if let radius = phone.radius, radius > 0 {
                                MapCircle(center: c, radius: radius)
                                    .foregroundStyle(color(phone).opacity(0.14))
                                    .stroke(color(phone).opacity(0.8), lineWidth: 1)
                            }
                            ForEach(Array(phone.cloud.prefix(60).enumerated()), id: \.offset) { _, point in
                                if let dot = coordinate(point) {
                                    Annotation("", coordinate: dot) { Dot(color: Self.bluetoothColor, size: 3) }
                                }
                            }
                            Annotation(name(phone), coordinate: c) {
                                PhoneMarker(color: color(phone), isSelf: phone.isSelf, dashed: phone.state == .lastSeen)
                            }
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .mapControls { MapCompass(); MapScaleView() }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in following = false })
                .onTapGesture(coordinateSpace: .local) { point in
                    guard pinning, let c = proxy.convert(point, from: .local) else { return }
                    model.pinHere(latitude: c.latitude, longitude: c.longitude)
                    pinning = false
                    following = true
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                StatusCard(title: status.title, detail: status.detail, tint: status.tint,
                           name: model.label, hint: pinning ? "Tap the map where you are standing" : nil,
                           gpsGuard: gpsGuard)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer()
                if let lost = lostWithRoutes {
                    RoutesCard(name: lost.phone.isSelf ? "You" : lost.phone.label, since: lost.phone.since, routes: lost.routes)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                controls
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .onReceive(tracker.$phones) { _ in fitCamera() }
        .onAppear { fitCamera(animated: false) }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                model.simulateGPSLoss.toggle()
            } label: {
                Label(model.simulateGPSLoss ? "GPS off (demo)" : "GPS on",
                      systemImage: model.simulateGPSLoss ? "location.slash.fill" : "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(model.simulateGPSLoss ? .orange : Self.gpsColor)
            // Long press: demo attacks on this phone's GPS, caught by the GPS check.
            .contextMenu {
                ForEach(GPSAttack.allCases, id: \.self) { attack in
                    Button(GPSGuard.label(attack)) { gpsGuard.setAttack(attack) }
                }
                if gpsGuard.attack != nil {
                    Button("Stop the attack", role: .destructive) { gpsGuard.setAttack(nil) }
                }
            }

            Button {
                if model.positionChoice == .manual { model.unpin() } else { pinning.toggle() }
            } label: {
                Label(model.positionChoice == .manual ? "Unpin" : (pinning ? "Cancel" : "Pin me"),
                      systemImage: model.positionChoice == .manual ? "pin.slash" : "mappin.and.ellipse")
            }

            if !following {
                Button { following = true; fitCamera() } label: { Image(systemName: "scope") }
                    .accessibilityLabel("Show everyone")
            }

            Button { model.showingSettings = true } label: { Image(systemName: "gearshape.fill") }
                .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Status

    private var status: (title: String, detail: String, tint: Color) {
        guard model.isRunning else { return ("Mesh stopped", "Open settings to start it", .gray) }
        let nearby = bluetooth.neighbors.count
        let nearbyText = nearby == 0 ? "No phones nearby yet" : "\(nearby) phone\(nearby == 1 ? "" : "s") nearby"
        guard let me = tracker.me else {
            return model.gpsPosition == nil && model.positionChoice == .gps
                ? ("Looking for a phone with GPS…", nearbyText, .gray)
                : ("Starting…", nearbyText, .gray)
        }
        let radius = me.radius.map { "±\(Int($0.rounded())) m" } ?? ""
        switch me.state {
        case .placed(let source):
            return source == .manual
                ? ("Pinned spot", "You placed yourself on the map · \(nearbyText)", Self.gpsColor)
                : ("GPS \(radius)", nearbyText, Self.gpsColor)
        case .estimated:
            let hops = me.hops.map { " · \($0) hop\($0 == 1 ? "" : "s")" } ?? ""
            let via = strongestPlacedNeighbor(of: me.id).map { " via \($0)" } ?? ""
            let title = me.ambiguous ? "Bluetooth: direction unclear" : "Found over Bluetooth"
            return (title, "\(radius)\(via)\(hops)", Self.bluetoothColor)
        case .lastSeen:
            let age = Int(Date().timeIntervalSince(me.since))
            return predictor.clouds[me.id] != nil
                ? ("Position lost \(age) s ago", "Movement model is predicting where you are", Self.predictedColor)
                : ("Position lost \(age) s ago", "Showing your last known spot", Self.predictedColor)
        case .unplaced:
            return ("Looking for a phone with GPS…", nearbyText, .gray)
        }
    }

    /// The placed phone with the strongest signal to `id`: who this phone is located from.
    private func strongestPlacedNeighbor(of id: String) -> String? {
        let placed = Set(tracker.phones.filter {
            if case .placed = $0.state { return true }
            return $0.state == .estimated
        }.map(\.id))
        return tracker.links
            .filter { ($0.a == id && placed.contains($0.b)) || ($0.b == id && placed.contains($0.a)) }
            .max { $0.rssi < $1.rssi }
            .flatMap { link in
                let other = link.a == id ? link.b : link.a
                return tracker.phones.first { $0.id == other }?.label
            }
    }

    /// The lost phone whose route options the card describes (the first one, by name).
    private var lostWithRoutes: (phone: TrackedPhone, routes: MovementPredictor.Routes)? {
        tracker.phones.lazy.compactMap { phone in predictor.routes[phone.id].map { (phone, $0) } }.first
    }

    static func routeColor(_ rank: Int) -> Color {
        [Color(red: 1.0, green: 0.42, blue: 0.21), .yellow, .pink, .mint][min(rank, 3)]
    }

    // MARK: - Geometry

    private func polyline(_ points: [FloorPoint]) -> [CLLocationCoordinate2D]? {
        let coordinates = points.compactMap(coordinate)
        return coordinates.count > 1 ? coordinates : nil
    }

    private func coordinate(_ point: FloorPoint) -> CLLocationCoordinate2D? {
        GeoFrame.coordinate(frameId: model.frameID, x: point.x, z: point.z)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func coordinate(ofPhone id: String) -> CLLocationCoordinate2D? {
        if let cloud = predictor.clouds[id] { return coordinate(cloud.center) }
        return tracker.phones.first { $0.id == id }?.point.flatMap(coordinate)
    }

    private func name(_ phone: TrackedPhone) -> String {
        phone.isSelf ? "You" : phone.label
    }

    private func color(_ phone: TrackedPhone) -> Color {
        switch phone.state {
        case .placed: return Self.gpsColor
        case .estimated: return Self.bluetoothColor
        case .lastSeen: return Self.predictedColor
        case .unplaced: return .gray
        }
    }

    /// Keeps every phone in view until the user pans; the scope button brings it back.
    private func fitCamera(animated: Bool = true) {
        guard following else { return }
        var points: [(c: CLLocationCoordinate2D, r: Double)] = []
        for phone in tracker.phones {
            if let cloud = predictor.clouds[phone.id], let c = coordinate(cloud.center) {
                points.append((c, 30))
            } else if let p = phone.point, let c = coordinate(p) {
                points.append((c, phone.radius ?? 10))
            }
        }
        guard !points.isEmpty else { return }
        let lats = points.map(\.c.latitude), lons = points.map(\.c.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        let pad = max(60, (points.map(\.r).max() ?? 0) * 2.5)
        let spanLat = (lats.max()! - lats.min()!) * 111_000 + pad
        let spanLon = (lons.max()! - lons.min()!) * 111_000 * cos(center.latitude * .pi / 180) + pad
        let region = MKCoordinateRegion(center: center, latitudinalMeters: max(spanLat, 120), longitudinalMeters: max(spanLon, 120))
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String
    let tint: Color
    let name: String
    let hint: String?
    @ObservedObject var gpsGuard: GPSGuard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
            if !detail.isEmpty {
                Text(detail).font(.subheadline)
            }
            if let check = gpsGuard.summary {
                Label(check.text, systemImage: GPSCheckStyle.icon(check.level))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GPSCheckStyle.color(check.level))
                    .lineLimit(2)
            }
            if let hint {
                Label(hint, systemImage: "hand.tap").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// "65 %" at the spot a lost phone has probably reached along one route.
private struct RouteTag: View {
    let percent: Double
    let color: Color

    var body: some View {
        Text("\(Int((percent * 100).rounded())) %")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
            .foregroundStyle(.black)
            .shadow(radius: 2)
    }
}

/// Which way a lost phone probably went, in words, from the route model.
private struct RoutesCard: View {
    let name: String
    let since: Date
    let routes: MovementPredictor.Routes

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name) out of reach \(ageText(since: since, now: context.date)) · probably")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(routes.options.prefix(3)) { option in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int((option.probability * 100).rounded())) %")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(PhoneMapView.routeColor(option.id))
                            .frame(width: 44, alignment: .leading)
                        Text(option.text).font(.subheadline).lineLimit(1)
                    }
                }
                if routes.offPath >= 0.05 {
                    Text("\(Int((routes.offPath * 100).rounded())) % left the paths")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct PhoneMarker: View {
    let color: Color
    let isSelf: Bool
    let dashed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: isSelf ? 22 : 16, height: isSelf ? 22 : 16)
            Circle()
                .stroke(.white, style: StrokeStyle(lineWidth: isSelf ? 3 : 2, dash: dashed ? [3, 3] : []))
                .frame(width: isSelf ? 22 : 16, height: isSelf ? 22 : 16)
        }
        .shadow(radius: 2)
    }
}

private struct Dot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle().fill(color.opacity(0.7)).frame(width: size, height: size)
    }
}
