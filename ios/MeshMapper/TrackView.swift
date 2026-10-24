import MeshCore
import SwiftUI

/// Where the other phones are, worked out on this phone from Bluetooth alone: no Wi-Fi, laptop or
/// map tiles. The signal map lays phones out so that their distances are the measured Bluetooth
/// ranges; phones with GPS (or a typed spot) anchor it in the world when there are enough of them.
@MainActor
struct TrackView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var tracker: BluetoothTracker
    @ObservedObject var bluetooth: BluetoothMesh

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Form {
                    Section {
                        if let me = tracker.me?.signal, me.placed {
                            SignalRadarView(phones: tracker.phones, links: tracker.links, me: me)
                                .frame(height: 320)
                                .listRowInsets(EdgeInsets())
                            Text(frameText(me)).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("No Bluetooth links yet. The signal map appears as soon as this phone hears another mapping phone.")
                                .foregroundStyle(.secondary)
                        }
                        Text(selfText).font(.subheadline)
                    } header: {
                        Text("Signal map")
                    } footer: {
                        Text("Laid out from Bluetooth ranges: lines are links, labelled with the measured distance, and the map keeps those distances. Dashed rings: only the distance is known, not the direction.")
                    }

                    Section("Phones") {
                        let others = tracker.phones.filter { !$0.isSelf }
                        if others.isEmpty { Text("No other phones heard yet").foregroundStyle(.secondary) }
                        ForEach(others) { phone in
                            TrackRow(phone: phone, relation: relation(to: phone), now: context.date)
                        }
                    }

                    Section {
                        if bluetooth.neighbors.isEmpty { Text("No linked phones").foregroundStyle(.secondary) }
                        ForEach(bluetooth.neighbors) { neighbor in
                            LabeledContent(neighbor.label ?? shortID(neighbor.deviceId), value: directDistance(neighbor))
                        }
                    } header: {
                        Text("Bluetooth distance (no GPS needed)")
                    } footer: {
                        Text("Straight from signal strength, so distance only, no direction, and rough beyond a few meters: bodies, walls and pockets weaken the signal. \(radioText)")
                    }

                    Section {
                        Toggle("Simulate losing GPS", isOn: $model.simulateGPSLoss)
                            .disabled(model.positionChoice == .manual)
                    } header: {
                        Text("Demo")
                    } footer: {
                        Text("This phone stops sharing its GPS; every other phone then places it from Bluetooth.")
                    }
                }
            }
            .navigationTitle("Track")
        }
    }

    private func frameText(_ me: SignalNode) -> String {
        switch me.frame {
        case .world: return "North is up: placed phones anchor this map in the world."
        case .pinned: return "One placed phone: distances are real, but the map may be turned or mirrored."
        case .relative: return "No placed phone: distances are real, but the map may be turned or mirrored."
        }
    }

    private var radioText: String {
        let radio = tracker.radio
        let calibrated = radio != RadioModel.standard
        return String(format: "Radio model: %.0f dBm at 1 m, exponent %.2f%@.", radio.p0, radio.n,
                      calibrated ? ", calibrated from placed phones" : "")
    }

    private var selfText: String {
        guard let me = tracker.me else { return "This phone: starting…" }
        switch me.state {
        case .placed(.gps): return "This phone: GPS ±\(meters(me.radius ?? 0))"
        case .placed(.uwb): return "This phone: UWB ±\(meters(me.radius ?? 0))"
        case .placed(.fused): return "This phone: motion + anchors ±\(meters(me.radius ?? 0))"
        case .placed: return "This phone: fixed spot"
        case .estimated where me.ambiguous: return "This phone: placed from Bluetooth, direction from the others unknown"
        case .estimated: return "This phone: placed from Bluetooth ±\(meters(me.radius ?? 0))"
        case .lastSeen: return "This phone: no fix right now, last spot \(meters(me.radius ?? 0)) wide"
        case .unplaced: return "This phone: not linked to a placed phone yet"
        }
    }

    /// The measured range when the phones hear each other; otherwise the distance across the
    /// signal map; a compass direction only when the map is anchored and both spots are known.
    private func relation(to phone: TrackedPhone) -> String? {
        if let link = tracker.link(between: model.deviceID, and: phone.id) {
            return "\(meters(link.measured)) · Bluetooth"
        }
        guard let mine = tracker.me?.signal, let theirs = phone.signal, mine.placed, theirs.placed,
              mine.component == theirs.component else {
            // Not connected through the mesh: only the world positions relate them.
            guard let from = tracker.me?.point, let to = phone.point else { return nil }
            let spread = (tracker.me?.radius ?? 0) + (phone.radius ?? 0)
            return "~\(meters(hypot(to.x - from.x, to.z - from.z))) on map, ±\(meters(spread))"
        }
        let dx = theirs.x - mine.x
        let dz = theirs.z - mine.z
        let distance = "~\(meters(hypot(dx, dz))) via mesh"
        guard mine.frame == .world, !phone.ambiguous, tracker.me?.ambiguous == false else { return distance }
        let bearing = (atan2(dx, dz) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360)
        let compass = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((bearing + 22.5) / 45) % 8]
        return "\(distance) \(compass)"
    }

    private func directDistance(_ neighbor: MeshNeighbor) -> String {
        guard let rssi = (neighbor.connectionRSSI ?? neighbor.advertisementRSSI)?.smoothed else { return "no signal reading yet" }
        let radio = tracker.radio
        let near = radio.distance(forRSSI: rssi + radio.sigma)
        let far = radio.distance(forRSSI: rssi - radio.sigma)
        let onMap = tracker.link(between: model.deviceID, and: neighbor.deviceId).map { " · map \(meters($0.layout))" } ?? ""
        return "≈ \(meters(radio.distance(forRSSI: rssi))) (\(meters(near))–\(meters(far))) · \(Int(rssi.rounded())) dBm\(onMap)"
    }
}

func meters(_ value: Double) -> String {
    if value >= 1000 { return String(format: "%.1f km", value / 1000) }
    // Short Bluetooth ranges are good to about a meter; show one decimal below 10 m.
    if value < 10 { return String(format: "%.1f m", value) }
    return "\(Int(value.rounded())) m"
}

@MainActor
struct TrackRow: View {
    let phone: TrackedPhone
    let relation: String?
    let now: Date

    var body: some View {
        HStack {
            Circle().fill(TrackStyle.color(phone.state)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.label).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let relation { Text(relation).font(.callout.monospacedDigit()).multilineTextAlignment(.trailing) }
        }
    }

    private var detail: String {
        let moved = phone.reported.map { _ in " · moved to fit its Bluetooth links" } ?? ""
        switch phone.state {
        case .placed(.gps): return "GPS ±\(meters(phone.radius ?? 0))\(moved)"
        case .placed(.uwb): return "UWB ±\(meters(phone.radius ?? 0))\(moved)"
        case .placed(.fused): return "Motion + anchors ±\(meters(phone.radius ?? 0))\(moved)"
        case .placed: return "Fixed spot\(moved)"
        case .estimated:
            let hops = phone.hops.map { " · \($0) hop\($0 == 1 ? "" : "s")" } ?? ""
            if let ring = phone.ring { return "Bluetooth: \(meters(ring.radius)) from a placed phone, direction unknown\(hops)" }
            return "Bluetooth ±\(meters(phone.radius ?? 0))\(hops)"
        case .lastSeen:
            return "Out of reach \(ageText(since: phone.since, now: now)) · within \(meters(phone.radius ?? 0)) of last spot"
        case .unplaced:
            return phone.signal?.placed == true ? "On the signal map only: no placed phone in its group" : "No links yet"
        }
    }
}

enum TrackStyle {
    static func color(_ state: TrackedPhone.State) -> Color {
        switch state {
        case .placed: return .green
        case .estimated: return .orange
        case .lastSeen, .unplaced: return .gray
        }
    }
}

/// The signal map around this phone: every phone in its connected group at its layout position,
/// so distances on screen are the measured Bluetooth ranges. North is up only in a world-anchored
/// map; otherwise the orientation is arbitrary (but stable from second to second).
struct SignalRadarView: View {
    let phones: [TrackedPhone]
    let links: [TrackedLink]
    let me: SignalNode

    var body: some View {
        Canvas { context, size in
            let group = phones.filter { $0.signal?.placed == true && $0.signal?.component == me.component }
            let layout = Dictionary(uniqueKeysWithValues: group.map { ($0.id, FloorPoint(x: $0.signal!.x, z: $0.signal!.z)) })
            let extent = layout.values.reduce(3.0) { max($0, hypot($1.x - me.x, $1.z - me.z) + 1) }
            let step = [0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500].first { extent / $0 <= 4 } ?? 1000
            let rings = max(1, Int((extent / step).rounded(.up)))
            let scale = (min(size.width, size.height) / 2 - 20) / (Double(rings) * step)
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            func screen(_ p: FloorPoint) -> CGPoint {
                CGPoint(x: mid.x + (p.x - me.x) * scale, y: mid.y - (p.z - me.z) * scale)
            }
            func circle(_ c: CGPoint, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }

            for i in 1...rings {
                let r = Double(i) * step * scale
                context.stroke(circle(mid, r), with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                context.draw(Text(meters(Double(i) * step)).font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: mid.x + r * 0.71 + 2, y: mid.y - r * 0.71 - 7), anchor: .leading)
            }
            if me.frame == .world {
                context.draw(Text("N").font(.caption.bold()).foregroundColor(.secondary), at: CGPoint(x: mid.x, y: 10))
            }

            for link in links {
                guard let a = layout[link.a], let b = layout[link.b] else { continue }
                var path = Path()
                path.move(to: screen(a))
                path.addLine(to: screen(b))
                context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                let middle = screen(FloorPoint(x: (a.x + b.x) / 2, z: (a.z + b.z) / 2))
                context.draw(Text(meters(link.measured)).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                             at: CGPoint(x: middle.x, y: middle.y - 7))
            }

            for phone in group {
                guard let signal = phone.signal, let p = layout[phone.id] else { continue }
                let color = phone.isSelf ? Color.blue : TrackStyle.color(phone.state)
                if let center = signal.ringCenter.flatMap({ layout[$0] }), let radius = signal.ringRadius {
                    // Distance known, direction not: the phone is somewhere on this ring.
                    context.stroke(circle(screen(center), radius * scale), with: .color(color.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    context.stroke(circle(screen(p), 5), with: .color(color), lineWidth: 1.5)
                } else {
                    context.fill(circle(screen(p), phone.isSelf ? 6 : 5), with: .color(color))
                }
                context.draw(Text(phone.isSelf ? "You" : phone.label).font(.caption2.weight(.semibold)),
                             at: CGPoint(x: screen(p).x, y: screen(p).y - 13))
            }
        }
        .clipped()
    }
}
