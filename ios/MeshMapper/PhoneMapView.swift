import MapKit
import MeshCore
import SwiftUI

/// The whole app for most people: one map with this phone and every phone the mesh reaches, drawn
/// by GhostCore's map layer from what GhostCoreHub decided this second. Each phone shows how it is
/// placed (GPS trusted, Bluetooth estimate with its 95% circle, predicted with its age), the links and
/// relay routes between phones, and, when the trust checks refuse a GPS fix, where that fix claimed
/// to be and why it was refused.
@MainActor
struct PhoneMapView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var hub: GhostCoreHub
    @ObservedObject var predictor: MovementPredictor
    @ObservedObject var bluetooth: BluetoothMesh

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
    /// Peers whose link this phone forced down from the simulation panel (cleared by Stop).
    @State private var forcedDown: Set<String> = []

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
                #if DEBUG
                if FixturePreview.stage != nil { FixtureBanner() }
                #endif
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
                } else if let lost = lostWithPaths(scene), let paths = lost.likelyPaths {
                    LikelyPathsCard(phone: lost, paths: paths, now: scene.now)
                        .onTapGesture { selected = SelectedPhone(id: lost.id) }
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
        .onReceive(hub.$phones) { _ in fitCamera() }
        .onAppear {
            fitCamera(animated: false)
            #if DEBUG
            if let target = FixturePreview.open {
                switch target {
                case "simulation": showingSimulation = true
                case "self": selected = SelectedPhone(id: model.deviceID)
                default: selected = SelectedPhone(id: target)
                }
            }
            if let fault = FixturePreview.autoInject {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { scenarioControls().gnss?(fault) }
            }
            #endif
        }
    }

    /// The one place the map's data is assembled.
    private func currentScene() -> VizScene {
        #if DEBUG
        if let stage = FixturePreview.stage, let scene = FixturePreview.scene(stage: stage) { return scene }
        #endif
        return VizScene.hub(hub, model: model, predictor: predictor)
    }

    /// What the simulation panel injects. Every action is a raw input through GhostCoreHub: GNSS
    /// faults act on this phone's own GPS (other phones are other devices), a link toggle forces this
    /// phone's Bluetooth link to that peer down or up. Parameters follow ARCHITECTURE.md S2/S3.
    private func scenarioControls() -> VizScenarioControls {
        let me = model.deviceID
        var controls = VizScenarioControls()
        controls.scenarios = hub.availableScenarios.map { .init(id: $0.id, title: "\($0.id) · \($0.title)", summary: $0.summary) }
        controls.roles = Array(Set(hub.availableScenarios.flatMap { $0.phones.map(\.id) })).sorted()
        controls.run = { id, role, roleMap in
            guard let scenario = hub.availableScenarios.first(where: { $0.id == id }), let role else { return }
            model.simulateGPSLoss = false
            forcedDown = []
            hub.play(scenario, as: role, roles: roleMap)
        }
        if hub.simulationActive || hub.scenario?.isRunning == true || model.simulateGPSLoss {
            controls.stop = {
                model.simulateGPSLoss = false
                forcedDown = []
                hub.stop()
            }
        }
        controls.supportedGNSS = Set(VizScenarioControls.GNSSFault.allCases)
        controls.gnss = { fault in
            switch fault {
            case .jump: hub.inject(.gnssJump(subjectId: me, dx: 400, dz: 0))
            case .drift: hub.inject(.gnssDrift(subjectId: me, metersPerSecond: 1, bearingDegrees: 90))
            case .outage: hub.inject(.gnssOutage(subjectId: me, active: true))
            case .restore:
                model.simulateGPSLoss = false
                hub.inject(.gnssClear(subjectId: me))
            }
        }
        controls.peers = hub.phones.filter { !$0.isSelf }.map {
            VizScenarioControls.Peer(id: $0.id, label: $0.label, linkUp: !forcedDown.contains($0.id))
        }
        controls.setPeerLink = { peer, up in
            hub.inject(.peerLink(subjectId: me, peerId: peer, up: up))
            if up { forcedDown.remove(peer) } else { forcedDown.insert(peer) }
        }
        controls.unavailableReason = model.isRunning ? "Not available on this build." : "Start the mesh first."
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

    /// The predicted phone whose likely paths the card spells out: the selected one, else the first.
    private func lostWithPaths(_ scene: VizScene) -> VizPhone? {
        let lost = scene.phones.filter { $0.likelyPaths != nil }
        return lost.first { $0.id == selected?.id } ?? lost.first
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
            for option in phone.likelyPaths?.options ?? [] { add(option.here, 10) }
        }
        guard !points.isEmpty else { return }
        let lats = points.map(\.c.latitude), lons = points.map(\.c.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        // Extra room top and bottom for the status card and the controls.
        let pad = max(80, (points.map(\.r).max() ?? 0) * 2.5)
        let spanLat = (lats.max()! - lats.min()!) * 111_000 * 1.6 + pad
        // Wider sideways: labels hang off the dots horizontally.
        let spanLon = (lons.max()! - lons.min()!) * 111_000 * cos(center.latitude * .pi / 180) * 1.5 + pad * 1.5
        let region = MKCoordinateRegion(center: center, latitudinalMeters: max(spanLat, 140), longitudinalMeters: max(spanLon, 140))
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}
