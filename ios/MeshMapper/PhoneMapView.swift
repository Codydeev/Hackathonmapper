import MapKit
import MeshCore
import SwiftUI

/// The whole app for most people: one map with this phone and every phone the mesh reaches, drawn
/// by GhostCore's map layer. Each phone shows how it is placed (GPS trusted, Bluetooth estimate with
/// its 95% circle, predicted with its age), the links and relay routes between phones, and, when the
/// trust checks refuse a GPS fix, where that fix claimed to be and why it was refused.
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
    @State private var selected: SelectedPhone?
    @State private var showingSimulation = false

    private struct SelectedPhone: Identifiable { let id: String }

    var body: some View {
        let scene = currentScene()
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    GhostMapContent(scene: scene, selectedId: selected?.id) { selected = SelectedPhone(id: $0) }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
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
            .sheet(item: $selected) { phone in
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    TrustExplainer(phoneId: phone.id, scene: currentScene()) { selected = nil }
                }
                .presentationDetents([.medium, .large])
            }

            VStack(spacing: GhostTheme.gap2) {
                if scene.anySimulated {
                    SimulationBanner(scenario: scene.scenario, stop: scenarioControls().stop)
                }
                StatusPanel(scene: scene, name: model.label, fallback: fallbackStatus,
                            hint: pinning ? "Tap the map where you are standing" : nil)
                    .onTapGesture { if let me = scene.me { selected = SelectedPhone(id: me.id) } }
                Spacer()
                if let me = scene.me, showsCompare(me, scene) {
                    CompareCard(phone: me, scene: scene)
                        .onTapGesture { selected = SelectedPhone(id: me.id) }
                }
                GhostLegend(integrityConnected: scene.integrityConnected)
                controls
            }
            .padding(.horizontal, GhostTheme.gap3)
            .padding(.top, GhostTheme.gap2)
            .padding(.bottom, GhostTheme.gap3)
            .sheet(isPresented: $showingSimulation) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ScenarioPanel(controls: scenarioControls(), scenario: currentScene().scenario) { showingSimulation = false }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .environment(\.colorScheme, .dark)
        .onReceive(tracker.$phones) { _ in fitCamera() }
        .onAppear { fitCamera(animated: false) }
    }

    /// The one place the map's data is assembled.
    private func currentScene() -> VizScene {
        VizScene.legacy(model: model, tracker: tracker, predictor: predictor, location: location)
    }

    /// What the simulation panel may inject on this build.
    private func scenarioControls() -> VizScenarioControls {
        var controls = VizScenarioControls()
        // This phone ignoring its own GPS is an input change: it then publishes no position and is
        // placed by its peers like any phone without GPS.
        controls.supportedGNSS = [.outage, .restore]
        controls.gnss = { fault in
            switch fault {
            case .outage: model.simulateGPSLoss = true
            case .restore: model.simulateGPSLoss = false
            case .jump, .drift: break
            }
        }
        controls.stop = model.simulateGPSLoss ? { model.simulateGPSLoss = false } : nil
        controls.peers = bluetooth.neighbors.map {
            VizScenarioControls.Peer(id: $0.deviceId, label: $0.label ?? shortID($0.deviceId), linkUp: true)
        }
        return controls
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: GhostTheme.gap2) {
            Button {
                showingSimulation = true
            } label: {
                Label("Simulate", systemImage: "film.stack")
                    .frame(maxWidth: .infinity)
            }
            .tint(GhostTheme.simulation)
            .foregroundStyle(.black)

            Button {
                if model.positionChoice == .manual { model.unpin() } else { pinning.toggle() }
            } label: {
                Label(model.positionChoice == .manual ? "Unpin" : (pinning ? "Cancel" : "Pin me"),
                      systemImage: model.positionChoice == .manual ? "pin.slash" : "mappin.and.ellipse")
            }
            .tint(GhostTheme.surfaceRaised)

            if !following {
                Button { following = true; fitCamera() } label: { Image(systemName: "scope") }
                    .tint(GhostTheme.surfaceRaised)
                    .accessibilityLabel("Show everyone")
            }

            Button { model.showingSettings = true } label: { Image(systemName: "gearshape.fill") }
                .tint(GhostTheme.surfaceRaised)
                .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Status

    /// Shown until the tracker has this phone.
    private var fallbackStatus: (title: String, detail: String) {
        guard model.isRunning else { return ("Mesh stopped", "Open settings to start it") }
        let nearby = bluetooth.neighbors.count
        let nearbyText = nearby == 0 ? "No phones nearby yet" : "\(nearby) phone\(nearby == 1 ? "" : "s") nearby"
        return model.gpsPosition == nil && model.positionChoice == .gps
            ? ("Looking for a phone with GPS…", nearbyText)
            : ("Starting…", nearbyText)
    }

    /// The raw-vs-estimate card earns its space when the two disagree or GPS is not simply trusted.
    private func showsCompare(_ me: VizPhone, _ scene: VizScene) -> Bool {
        guard let fix = me.comparedFix else { return false }
        if let status = me.integrity?.status, [.rejected, .suspect, .degraded, .insufficientEvidence].contains(status) { return true }
        guard let shown = scene.drawnPoint(me.id) else { return true }
        return hypot(shown.x - fix.point.x, shown.z - fix.point.z) > max(10, me.r95 ?? 0)
    }

    // MARK: - Camera

    /// Keeps every phone (and any refused GPS fix) in view until the user pans; the scope button
    /// brings it back.
    private func fitCamera(animated: Bool = true) {
        guard following else { return }
        let scene = currentScene()
        var points: [(c: CLLocationCoordinate2D, r: Double)] = []
        func add(_ p: FloorPoint?, _ r: Double) {
            guard let p, let c = GeoFrame.coordinate(frameId: scene.frameId, x: p.x, z: p.z) else { return }
            points.append((CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), r))
        }
        for phone in scene.phones {
            add(scene.drawnPoint(phone.id), phone.kind == .predicted ? 30 : (phone.r95 ?? 10))
            if let integrity = phone.integrity, integrity.status == .rejected || integrity.status == .suspect {
                add(integrity.evaluatedFix?.point, 10)
            }
        }
        guard !points.isEmpty else { return }
        let lats = points.map(\.c.latitude), lons = points.map(\.c.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        // Extra room top and bottom for the status card and the controls.
        let pad = max(80, (points.map(\.r).max() ?? 0) * 2.5)
        let spanLat = (lats.max()! - lats.min()!) * 111_000 * 1.6 + pad
        let spanLon = (lons.max()! - lons.min()!) * 111_000 * cos(center.latitude * .pi / 180) * 1.2 + pad
        let region = MKCoordinateRegion(center: center, latitudinalMeters: max(spanLat, 140), longitudinalMeters: max(spanLon, 140))
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}
