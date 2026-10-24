import CoreBluetooth
import MeshCore
import SwiftUI

/// Experimental: record what a spot sounds like over Bluetooth, and later ask which recorded spot
/// this sounds like. Nothing here feeds positioning or the GPS check, the devices heard are
/// observations only, and the recorded spots stay on this phone (docs/AMBIENT_RADIO.md).
struct AmbientRadioView: View {
    /// Where this phone is, when that is known well enough to record a spot.
    struct Spot: Equatable {
        let x: Double
        let z: Double
        let r95: Double
        let source: SpotPositionSource
    }

    static let recordSeconds: TimeInterval = 20
    static let compareSeconds: TimeInterval = 15

    let deviceId: String
    let frameId: String
    /// This phone as GhostCore shows it.
    let selfPhone: () -> GhostPhone?

    @StateObject private var scanner = AmbientRadioScanner()
    @StateObject private var store = FingerprintStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var label = ""
    @State private var message: String?
    @State private var match: FingerprintMatch?
    @State private var now = Date()

    /// The phone's own position, if a spot may be recorded there: a declared spot, or its GPS when
    /// the GPS check trusts it (or is off, which is recorded as unchecked). Bluetooth estimates and
    /// predictions are too rough to label a spot with.
    static func knownSpot(_ phone: GhostPhone?) -> Spot? {
        guard let phone, phone.isSelf, let selected = phone.selected, let position = selected.position else { return nil }
        switch (selected.kind, selected.method) {
        case (.declared, _):
            return Spot(x: position.x, z: position.z, r95: selected.uncertainty.r95, source: .declared)
        case (.measured, .gnss) where phone.integrity == nil && !phone.gnssUnconfirmed:
            return Spot(x: position.x, z: position.z, r95: selected.uncertainty.r95, source: .gnssUnchecked)
        case (.measured, .gnss) where phone.integrity?.mayAnchorOthers == true:
            return Spot(x: position.x, z: position.z, r95: selected.uncertainty.r95, source: .gnss)
        default:
            return nil
        }
    }

    private var listened: TimeInterval {
        scanner.startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    var body: some View {
        let spot = Self.knownSpot(selfPhone())
        Form {
            Section {
                Text("Experimental. Listens to the Bluetooth devices around you (beacons, TVs, other people's phones) and remembers what a spot sounds like. Those devices are not GhostCore phones: they relay nothing and say nothing about where they are. Nothing here feeds positioning or the GPS check, and recorded spots stay on this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Listen") {
                Toggle("Listen to nearby Bluetooth", isOn: Binding(
                    get: { scanner.startedAt != nil },
                    set: { $0 ? scanner.start() : scanner.stop() }))
                LabeledContent("Devices heard", value: "\(scanner.devicesHeard)")
                LabeledContent("Listening for", value: "\(Int(listened)) s")
                if [.unauthorized, .poweredOff, .unsupported].contains(scanner.bluetoothState) {
                    Text("Bluetooth is off or not allowed for this app.").foregroundStyle(.red)
                }
                Text("Listening shares the radio with the mesh's own discovery. Switch it off before a demo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Record this spot") {
                if let spot {
                    LabeledContent("Position", value: "±\(Int(spot.r95.rounded())) m, \(Self.describe(spot.source))")
                } else {
                    Text("Record only where this phone's position is known: a pinned spot, or GPS that is not flagged.")
                        .foregroundStyle(.secondary)
                }
                TextField("Name, e.g. Main door", text: $label)
                Button("Record the last \(Int(Self.recordSeconds)) s here") { record(at: spot) }
                    .disabled(spot == nil || listened < Self.recordSeconds || label.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Stand still while it listens. Phones and earbuds change their Bluetooth address about every 15 minutes, so a spot is best recorded where fixed devices (beacons, TVs, printers) can be heard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Which spot does this sound like?") {
                Button("Compare the last \(Int(Self.compareSeconds)) s") { compare() }
                    .disabled(listened < Self.compareSeconds || store.database.fingerprints.isEmpty)
                if let match {
                    Text(match.summary)
                    ForEach(match.candidates, id: \.fingerprintId) { candidate in
                        LabeledContent(candidate.label,
                                       value: "\(Self.percent(candidate.posterior)), \(candidate.commonDevices) devices in common")
                    }
                    LabeledContent("Somewhere not recorded", value: Self.percent(match.elsewhere))
                }
            }
            if let message {
                Section { Text(message) }
            }
            Section("Recorded spots (\(store.database.fingerprints.count))") {
                ForEach(store.database.fingerprints) { fingerprint in
                    VStack(alignment: .leading) {
                        Text(fingerprint.label)
                        Text("\(fingerprint.emitters.filter(\.emitter.isIdentity).count) steady devices · \(Self.describe(fingerprint.positionSource)) · \(Self.age(fingerprint.recordedAt, now: now))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.database.fingerprints[$0].id }
                    ids.forEach(store.remove(id:))
                }
                if !store.database.fingerprints.isEmpty {
                    Button("Delete all spots", role: .destructive) { store.removeAll() }
                }
            }
        }
        .navigationTitle("Ambient radio")
        .onDisappear { scanner.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scanner.stop() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func record(at spot: Spot?) {
        guard let spot else { return }
        let name = label.trimmingCharacters(in: .whitespaces)
        switch RadioFingerprint.record(scanner.snapshot(seconds: Self.recordSeconds), label: name, frameId: frameId,
                                       x: spot.x, z: spot.z, positionSource: spot.source, positionR95: spot.r95,
                                       recordedBy: deviceId) {
        case let .success(fingerprint):
            store.add(fingerprint)
            label = ""
            message = "Recorded \"\(fingerprint.label)\": \(fingerprint.emitters.filter(\.emitter.isIdentity).count) steady devices, \(fingerprint.unsteadyCount) left out as unsteady."
        case .failure(.tooShort):
            message = "Listen for at least \(Int(Self.recordSeconds)) s first."
        case .failure(.tooFewSteadyDevices):
            message = "Too few steady devices here to tell this spot apart. Nothing was recorded."
        case .failure(.invalidPosition):
            message = "This phone's position is not usable for a spot."
        }
    }

    private func compare() {
        match = FingerprintMatcher().match(scanner.snapshot(seconds: Self.compareSeconds), in: store.database,
                                           frameId: frameId, deviceId: deviceId)
    }

    private static func describe(_ source: SpotPositionSource) -> String {
        switch source {
        case .declared: "pinned spot"
        case .gnss: "checked GPS"
        case .gnssUnchecked: "GPS, not checked"
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }

    private static func age(_ time: TimeInterval, now: Date) -> String {
        let minutes = Int((now.timeIntervalSince1970 - time) / 60)
        return minutes < 1 ? "just now" : minutes < 120 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }
}
