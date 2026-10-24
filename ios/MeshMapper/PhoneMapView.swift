import MapKit
import MeshCore
import SwiftUI

/// The whole app for most people: one map with this phone and every phone the mesh reaches.
/// A phone without GPS is placed here, on the phone itself, from the UWB distances and Bluetooth
/// signal of the phones around it; when the mesh loses it, the movement model keeps predicting
/// where it is. Links carry their measured distance, and a phone whose direction is unknown is
/// drawn as a ring around its neighbour, not as a dot.
@MainActor
struct PhoneMapView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var tracker: BluetoothTracker
    @ObservedObject var predictor: MovementPredictor
    @ObservedObject var bluetooth: BluetoothMesh
    @ObservedObject var location: LocationSource

    /// Starts over the frame's origin (Hervanta campus) until there is someone to show.
    @State private var camera: MapCameraPosition = {
        guard let origin = GeoFrame.origins[GeoFrame.defaultFrameId] else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        return .region(MKCoordinateRegion(center: center, latitudinalMeters: 600, longitudinalMeters: 600))
    }()
    @State private var following = true
    @State private var pinning = false
    @State private var headingUp = false
    @State private var showParticles = false
    @State private var showLegend = false
    /// Link whose distance label is shown although it does not touch this phone.
    @State private var selectedLink: String?
    /// What the camera was last fitted to, for the refit hysteresis.
    @State private var fittedSpan: Double?
    @State private var fittedCenter: FloorPoint?
    @State private var fittedIds: Set<String> = []
    @State private var appliedHeading = 0.0
    /// Camera distance per meter of span, learned from MapKit after each north-up fit, so a
    /// heading-up camera shows the same span.
    @State private var distancePerSpan = 1.6
    @State private var learningSpan: Double?
    @State private var lastCamera: MapCamera?

    private static let gpsColor = MapColors.gps
    private static let gpsUWBColor = MapColors.gpsUWB
    private static let uwbColor = MapColors.uwb
    private static let bluetoothColor = MapColors.bluetooth
    private static let predictedColor = MapColors.predicted
    private static let linkColor = MapColors.link
    private static let inconsistentColor = MapColors.inconsistent

    var body: some View {
        let drawing = makeDrawing()
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(drawing.links) { link in
                        MapPolyline(coordinates: [link.from, link.to])
                            .stroke(link.color, style: StrokeStyle(lineWidth: link.solid ? 2.5 : 1.5,
                                                                   dash: link.solid ? [] : [4, 4]))
                        Annotation("", coordinate: link.mid) {
                            LinkTag(text: link.label, color: link.color, expanded: link.showsLabel)
                                .onTapGesture { selectedLink = selectedLink == link.id ? nil : link.id }
                        }
                        .annotationTitles(.hidden)
                    }
                    ForEach(drawing.rings) { ring in
                        MapCircle(center: ring.center, radius: ring.radius)
                            .foregroundStyle(ring.color.opacity(0.06))
                            .stroke(ring.color, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        Annotation("", coordinate: ring.captionAt, anchor: .bottom) {
                            RingCaption(text: ring.caption, color: ring.color)
                        }
                        .annotationTitles(.hidden)
                    }
                    if showParticles {
                        ForEach(drawing.particles) { dot in
                            Annotation("", coordinate: dot.coordinate) { Dot(color: dot.color, size: 3) }
                                .annotationTitles(.hidden)
                        }
                    }
                    ForEach(drawing.markers) { marker in
                        if let radius = marker.radius, radius > 0 {
                            MapCircle(center: marker.coordinate, radius: radius)
                                .foregroundStyle(marker.color.opacity(0.14))
                                .stroke(marker.color.opacity(0.8),
                                        style: StrokeStyle(lineWidth: 1, dash: marker.dashed ? [4, 4] : []))
                        }
                        Annotation(marker.title, coordinate: marker.coordinate) {
                            PhoneMarker(color: marker.color, isSelf: marker.isSelf, dashed: marker.dashed)
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .mapControls { MapCompass(); MapScaleView() }
                .onMapCameraChange(frequency: .onEnd) { context in
                    lastCamera = context.camera
                    if let span = learningSpan, span > 0 {
                        distancePerSpan = min(5, max(0.5, context.camera.distance / span))
                        learningSpan = nil
                    }
                }
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
                           name: model.label, hint: pinning ? "Tap the map where you are standing" : nil)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer()
                if showLegend {
                    MapLegend()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                controls
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        // The published value is set after this fires: fit once the tick has finished.
        .onReceive(tracker.$phones) { _ in Task { @MainActor in refit() } }
        .onReceive(model.orientation.$heading) { heading in rotate(to: heading) }
        .onChange(of: headingUp) { _, _ in
            following = true
            refit(force: true)
        }
        .onAppear { refit(animated: false) }
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

            Button {
                if model.positionChoice == .manual { model.unpin() } else { pinning.toggle() }
            } label: {
                Label(model.positionChoice == .manual ? "Unpin" : (pinning ? "Cancel" : "Pin me"),
                      systemImage: model.positionChoice == .manual ? "pin.slash" : "mappin.and.ellipse")
            }

            if !following {
                Button {
                    following = true
                    refit(force: true)
                } label: { Image(systemName: "scope") }
                    .accessibilityLabel("Show everyone")
            }

            Menu {
                Toggle(isOn: $headingUp) { Label("Heading up", systemImage: "location.north.line") }
                Toggle(isOn: $showLegend) { Label("Legend", systemImage: "list.bullet") }
                Toggle(isOn: $showParticles) { Label("Particles (debug)", systemImage: "circle.dotted") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Map options")

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
            if source == .manual {
                return ("Pinned spot", "You placed yourself on the map · \(nearbyText)", Self.gpsColor)
            }
            let basis = me.basis ?? .reported(source)
            return ("\(MapPresentation.statusTitle(basis: basis, ambiguous: false)) \(radius)", nearbyText,
                    Self.color(for: basis))
        case .estimated:
            let basis = me.basis ?? .bluetooth
            let hops = me.hops.map { " · \($0) hop\($0 == 1 ? "" : "s")" } ?? ""
            let tint = Self.color(for: basis)
            if me.directionUnresolved {
                let title = MapPresentation.statusTitle(basis: basis, ambiguous: true)
                guard let ring = me.ring else { return (title, "\(radius)\(hops)", tint) }
                return (title, "\(MapPresentation.ringMeters(ring.radius)) from \(label(of: ring.around))\(hops)", tint)
            }
            let via = strongestPlacedNeighbor(of: me.id).map { " via \($0)" } ?? ""
            return (MapPresentation.statusTitle(basis: basis, ambiguous: false), "\(radius)\(via)\(hops)", tint)
        case .lastSeen:
            let age = Int(Date().timeIntervalSince(me.since))
            return predictor.clouds[me.id] != nil
                ? ("Position lost \(age) s ago", "Movement model is predicting where you are", Self.predictedColor)
                : ("Position lost \(age) s ago", "Showing your last known spot", Self.predictedColor)
        case .unplaced:
            return ("Looking for a phone with GPS…", nearbyText, .gray)
        }
    }

    /// The placed phone this one is located from: a UWB link first, then the strongest signal.
    private func strongestPlacedNeighbor(of id: String) -> String? {
        let placed = Set(tracker.phones.filter {
            if case .placed = $0.state { return true }
            return $0.state == .estimated && !$0.directionUnresolved
        }.map(\.id))
        return tracker.links
            .filter { $0.touches(id) && placed.contains($0.other(than: id)) }
            .max { rank($0) < rank($1) }
            .map { label(of: $0.other(than: id)) }
    }

    private func rank(_ link: TrackedLink) -> (Int, Double) {
        (link.uwbDistance == nil ? 0 : 1, link.rssi ?? -200)
    }

    private func label(of id: String) -> String {
        guard let phone = tracker.phones.first(where: { $0.id == id }) else { return shortID(id) }
        return phone.isSelf ? "you" : phone.label
    }

    // MARK: - Drawing

    private struct MarkerDrawing: Identifiable {
        let id: String
        let title: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
        let isSelf: Bool
        let dashed: Bool
        let radius: Double?
    }

    private struct RingDrawing: Identifiable {
        let id: String
        let center: CLLocationCoordinate2D
        let radius: Double
        let captionAt: CLLocationCoordinate2D
        let caption: String
        let color: Color
    }

    private struct LinkDrawing: Identifiable {
        let id: String
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        let mid: CLLocationCoordinate2D
        let label: String
        let solid: Bool
        let color: Color
        let showsLabel: Bool
    }

    private struct ParticleDrawing: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
    }

    private struct Drawing {
        var markers: [MarkerDrawing] = []
        var rings: [RingDrawing] = []
        var links: [LinkDrawing] = []
        var particles: [ParticleDrawing] = []
    }

    /// Everything the map shows this second, worked out once per render.
    private func makeDrawing() -> Drawing {
        var drawing = Drawing()
        var points: [String: FloorPoint] = [:]
        for phone in tracker.phones {
            if let ring = unresolvedRing(of: phone) {
                guard let center = coordinate(ring.center),
                      let top = coordinate(FloorPoint(x: ring.center.x, z: ring.center.z + ring.radius)) else { continue }
                let caption = phone.ring != nil
                    ? MapPresentation.ringCaption(label: name(phone), radius: ring.radius)
                    : "\(name(phone)) · direction unknown"
                drawing.rings.append(RingDrawing(id: phone.id, center: center, radius: ring.radius, captionAt: top,
                                                 caption: caption, color: color(phone)))
                continue
            }
            guard let point = drawnPoint(phone), let c = coordinate(point) else { continue }
            points[phone.id] = point
            if let cloud = predictor.clouds[phone.id] {
                drawing.markers.append(MarkerDrawing(id: phone.id, title: name(phone), coordinate: c,
                                                     color: Self.predictedColor, isSelf: phone.isSelf, dashed: true,
                                                     radius: cloud.radius))
                if showParticles {
                    for (i, p) in cloud.points.enumerated() {
                        if let dot = coordinate(p) {
                            drawing.particles.append(ParticleDrawing(id: "\(phone.id)#p\(i)", coordinate: dot,
                                                                     color: Self.predictedColor))
                        }
                    }
                }
            } else {
                drawing.markers.append(MarkerDrawing(id: phone.id, title: name(phone), coordinate: c,
                                                     color: color(phone), isSelf: phone.isSelf,
                                                     dashed: phone.state == .lastSeen, radius: phone.radius))
                if showParticles {
                    for (i, p) in phone.cloud.prefix(60).enumerated() {
                        if let dot = coordinate(p) {
                            drawing.particles.append(ParticleDrawing(id: "\(phone.id)#e\(i)", coordinate: dot,
                                                                     color: color(phone)))
                        }
                    }
                }
            }
        }

        let selfId = tracker.me?.id
        for link in tracker.links {
            // A phone drawn as a ring has no point: its ring already shows the link.
            guard let a = points[link.a], let b = points[link.b],
                  let from = coordinate(a), let to = coordinate(b),
                  let mid = coordinate(FloorPoint(x: (a.x + b.x) / 2, z: (a.z + b.z) / 2)) else { continue }
            let label = MapPresentation.linkLabel(uwb: link.uwbDistance, rssiDistance: link.rssiDistance)
            let drawn = hypot(b.x - a.x, b.z - a.z)
            let inconsistent = link.measuredDistance.map { MapPresentation.isInconsistent(drawn: drawn, measured: $0) } ?? false
            let touchesSelf = selfId.map { link.touches($0) } ?? false
            let showsLabel = !label.isEmpty && (touchesSelf || selectedLink == link.id)
            drawing.links.append(LinkDrawing(id: link.id, from: from, to: to, mid: mid, label: label,
                                             solid: link.uwbDistance != nil,
                                             color: inconsistent ? Self.inconsistentColor : Self.linkColor,
                                             showsLabel: showsLabel))
        }
        return drawing
    }

    /// Where the phone's dot goes: the prediction once it took over, nothing for a ring.
    private func drawnPoint(_ phone: TrackedPhone) -> FloorPoint? {
        if let cloud = predictor.clouds[phone.id] { return cloud.center }
        if phone.directionUnresolved { return nil }
        return phone.point
    }

    /// The ring of a direction-unresolved phone: the measured distance around its neighbour, or its
    /// 95 % circle when the locator gave no ring.
    private func unresolvedRing(of phone: TrackedPhone) -> (center: FloorPoint, radius: Double)? {
        guard phone.directionUnresolved, predictor.clouds[phone.id] == nil else { return nil }
        if let ring = phone.ring { return (ring.center, ring.radius) }
        guard let point = phone.point, let radius = phone.radius, radius > 0 else { return nil }
        return (point, radius)
    }

    // MARK: - Geometry

    private func coordinate(_ point: FloorPoint) -> CLLocationCoordinate2D? {
        GeoFrame.coordinate(frameId: model.frameID, x: point.x, z: point.z)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func name(_ phone: TrackedPhone) -> String {
        phone.isSelf ? "You" : phone.label
    }

    private func color(_ phone: TrackedPhone) -> Color {
        switch phone.state {
        case .placed(let source): return Self.color(for: phone.basis ?? .reported(source))
        case .estimated: return Self.color(for: phone.basis ?? .bluetooth)
        case .lastSeen: return Self.predictedColor
        case .unplaced: return .gray
        }
    }

    private static func color(for basis: PositionBasis) -> Color {
        switch basis {
        case .reported(.uwb): return uwbColor
        case .reported(.none): return .gray
        case .reported: return gpsColor
        case .gpsRefined: return gpsUWBColor
        case .uwbRanged: return uwbColor
        case .bluetooth: return bluetoothColor
        }
    }

    // MARK: - Camera

    /// Centre on this phone; span 2.5 × its farthest direct neighbour (at least 25 m). Without a
    /// spot of its own, the middle of everyone shown.
    private func cameraTarget() -> (center: FloorPoint, span: Double, ids: Set<String>)? {
        var shown: [String: FloorPoint] = [:]
        for phone in tracker.phones {
            if let ring = unresolvedRing(of: phone) {
                shown[phone.id] = FloorPoint(x: ring.center.x + ring.radius, z: ring.center.z)
            } else if let point = drawnPoint(phone) {
                shown[phone.id] = point
            }
        }
        guard !shown.isEmpty else { return nil }
        let ids = Set(shown.keys)
        if let me = tracker.me, let center = drawnPoint(me) ?? unresolvedRing(of: me)?.center {
            let direct = tracker.links.filter { $0.touches(me.id) }.compactMap { shown[$0.other(than: me.id)] }
            let others = shown.filter { $0.key != me.id }.map(\.value)
            let span = MapPresentation.cameraSpan(selfPoint: center, neighbors: direct.isEmpty ? others : direct)
            return (center, span, ids)
        }
        let all = Array(shown.values)
        let center = FloorPoint(x: all.map(\.x).reduce(0, +) / Double(all.count),
                                z: all.map(\.z).reduce(0, +) / Double(all.count))
        return (center, MapPresentation.cameraSpan(selfPoint: center, neighbors: all), ids)
    }

    /// Refits only when the needed span changes by > 30 %, this phone walked off-centre, a phone
    /// appears, or `force` (the scope button): the camera does not jump every second.
    private func refit(force: Bool = false, animated: Bool = true) {
        guard following, let target = cameraTarget() else { return }
        let appeared = !target.ids.isSubset(of: fittedIds)
        fittedIds = target.ids
        let moved = fittedCenter.map { hypot(target.center.x - $0.x, target.center.z - $0.z) } ?? .infinity
        guard force || appeared
                || MapPresentation.shouldRefit(current: fittedSpan, needed: target.span)
                || MapPresentation.shouldRecenter(moved: moved, span: fittedSpan ?? target.span),
              let center = coordinate(target.center) else { return }
        fittedSpan = target.span
        fittedCenter = target.center
        let position: MapCameraPosition
        if headingUp {
            let heading = model.orientation.heading ?? appliedHeading
            appliedHeading = heading
            position = .camera(MapCamera(centerCoordinate: center, distance: target.span * distancePerSpan,
                                         heading: heading, pitch: 0))
        } else {
            appliedHeading = 0
            learningSpan = target.span
            position = .region(MKCoordinateRegion(center: center, latitudinalMeters: target.span,
                                                  longitudinalMeters: target.span))
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { camera = position }
        } else {
            camera = position
        }
    }

    /// Heading up: turn the map with the compass, in steps so it does not shimmer.
    private func rotate(to heading: Double?) {
        guard headingUp, following, let heading, var turned = lastCamera,
              MapPresentation.shouldRotate(current: appliedHeading, heading: heading) else { return }
        appliedHeading = heading
        turned.heading = heading
        camera = .camera(turned)
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String
    let tint: Color
    let name: String
    let hint: String?

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
            if let hint {
                Label(hint, systemImage: "hand.tap").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Which colour and line means what; honest names, never "measured position".
private struct MapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            swatch(MapColors.gps, "GPS")
            swatch(MapColors.gpsUWB, "GPS + UWB")
            swatch(MapColors.uwb, "UWB-ranged")
            swatch(MapColors.bluetooth, "Bluetooth estimate")
            swatch(MapColors.predicted, "Predicted (movement model)")
            line(dashed: false, MapColors.link, "UWB distance, \"3.42 m\"")
            line(dashed: true, MapColors.link, "Bluetooth distance, \"≈ 4 m\"")
            line(dashed: false, MapColors.inconsistent, "Map disagrees with the distance")
            HStack(spacing: 8) {
                Circle().stroke(MapColors.bluetooth, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 12, height: 12)
                Text("Ring: distance known, direction unknown")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(text)
        }
    }

    private func line(dashed: Bool, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 6))
                path.addLine(to: CGPoint(x: 12, y: 6))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 12, height: 12)
            Text(text)
        }
    }
}

/// Marker colour by where the position comes from, shared by the map and its legend.
private enum MapColors {
    static let gps = Color(red: 0.72, green: 0.57, blue: 1.0)
    static let gpsUWB = Color(red: 0.45, green: 0.55, blue: 1.0)
    static let uwb = Color(red: 0.25, green: 0.85, blue: 0.45)
    static let bluetooth = Color(red: 0.31, green: 0.83, blue: 0.92)
    static let predicted = Color.orange
    static let link = Color.indigo.opacity(0.85)
    /// The drawn link disagrees with its measured distance.
    static let inconsistent = Color(red: 1.0, green: 0.72, blue: 0.1)
}

/// A link's distance label, or a small tap target that shows it.
private struct LinkTag: View {
    let text: String
    let color: Color
    let expanded: Bool

    var body: some View {
        if expanded {
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color, in: Capsule())
        } else {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
    }
}

private struct RingCaption: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
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
