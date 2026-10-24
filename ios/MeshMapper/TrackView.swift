import MeshCore
import SwiftUI

/// Where the other phones are, worked out on this phone from the mesh alone: no Wi-Fi, laptop or
/// map tiles. Phones with GPS (or a typed spot) anchor the picture; a phone without GPS is placed
/// from the UWB distances and signal strength of its links, with a circle showing how sure that is.
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
                        if let center {
                            RadarView(phones: tracker.phones, links: tracker.links, center: center)
                                .frame(height: 320)
                                .listRowInsets(EdgeInsets())
                        } else {
                            Text("Nobody in the mesh has a position yet. One phone with GPS (outdoors) or a fixed spot (Position tab) is enough to place the others. Until then, the Bluetooth distances below still work.")
                                .foregroundStyle(.secondary)
                        }
                        Text(selfText).font(.subheadline)
                    } footer: {
                        Text("North is up, this phone in the middle. Green: own GPS or fixed spot. Orange: UWB-ranged or Bluetooth estimate; the circle holds 95 % of it. A dashed ring: distance known, direction unknown. Grey: out of reach, at its last spot, circle growing at walking pace. Solid links have a UWB distance, dashed ones only Bluetooth.")
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
                        Text("Distance to linked phones (no GPS needed)")
                    } footer: {
                        Text("UWB distances are measured to within centimetres to tens of centimetres. Without UWB the distance comes from signal strength (≈): rough, because bodies, walls and pockets weaken the signal.")
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

    /// The radar centres on this phone, or on the first placed phone while this one has no spot.
    private var center: FloorPoint? {
        tracker.me?.point ?? tracker.phones.first { if case .placed = $0.state { return true } else { return false } }?.point
    }

    private var selfText: String {
        guard let me = tracker.me else { return "This phone: starting…" }
        switch me.state {
        case .placed(.manual): return "This phone: fixed spot"
        case .placed(let source):
            let title = MapPresentation.statusTitle(basis: me.basis ?? .reported(source), ambiguous: false)
            return "This phone: \(title) ±\(meters(me.radius ?? 0))"
        case .estimated:
            if let ring = me.ring, me.directionUnresolved {
                return "This phone: \(MapPresentation.ringMeters(ring.radius)) from \(label(of: ring.around)), direction unknown"
            }
            let title = MapPresentation.statusTitle(basis: me.basis ?? .bluetooth, ambiguous: me.ambiguous)
            return "This phone: \(title) ±\(meters(me.radius ?? 0))"
        case .lastSeen: return "This phone: no fix right now, last spot \(meters(me.radius ?? 0)) wide"
        case .unplaced: return "This phone: no GPS and no link to a placed phone yet"
        }
    }

    private func relation(to phone: TrackedPhone) -> String? {
        // A ring: its centre is the neighbour, so only the measured distance to it means anything.
        if let ring = phone.ring, phone.directionUnresolved {
            return "\(MapPresentation.ringMeters(ring.radius)) from \(label(of: ring.around)), direction unknown"
        }
        guard let from = tracker.me?.point, let to = phone.point else { return nil }
        let dx = to.x - from.x
        let dz = to.z - from.z
        let distance = meters(hypot(dx, dz))
        // Two candidate spots: the centre's direction means nothing.
        if phone.ambiguous { return "~\(distance), direction unclear" }
        let bearing = (atan2(dx, dz) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360)
        let compass = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((bearing + 22.5) / 45) % 8]
        return "\(distance) \(compass)"
    }

    private func label(of id: String) -> String {
        guard let phone = tracker.phones.first(where: { $0.id == id }) else { return shortID(id) }
        return phone.isSelf ? "you" : phone.label
    }

    /// "3.42 m UWB · -61 dBm" with a UWB distance, otherwise the rough distance from signal strength.
    private func directDistance(_ neighbor: MeshNeighbor) -> String {
        let rssi = (neighbor.connectionRSSI ?? neighbor.advertisementRSSI)?.smoothed
        let observation = model.directNeighbors.first { $0.id == neighbor.deviceId }
        if let uwb = observation?.uwbDistanceM {
            let dBm = rssi.map { " · \(Int($0.rounded())) dBm" } ?? ""
            return "\(MapPresentation.linkLabel(uwb: uwb, rssiDistance: nil)) UWB\(dBm)"
        }
        guard let rssi else { return "no signal reading yet" }
        let radio = tracker.radio
        let near = radio.distance(forRSSI: rssi + radio.sigma)
        let far = radio.distance(forRSSI: rssi - radio.sigma)
        return "≈ \(meters(radio.distance(forRSSI: rssi))) (\(meters(near))–\(meters(far))) · \(Int(rssi.rounded())) dBm"
    }
}

func meters(_ value: Double) -> String {
    value >= 1000 ? String(format: "%.1f km", value / 1000) : "\(Int(value.rounded())) m"
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
        switch phone.state {
        case .placed(.manual): return "Fixed spot"
        case .placed(let source):
            let title = MapPresentation.statusTitle(basis: phone.basis ?? .reported(source), ambiguous: false)
            return "\(title) ±\(meters(phone.radius ?? 0))"
        case .estimated:
            let hops = phone.hops.map { " · \($0) hop\($0 == 1 ? "" : "s")" } ?? ""
            let title = MapPresentation.statusTitle(basis: phone.basis ?? .bluetooth, ambiguous: phone.ambiguous)
            return "\(title) ±\(meters(phone.radius ?? 0))\(hops)"
        case .lastSeen:
            return "Out of reach \(ageText(since: phone.since, now: now)) · within \(meters(phone.radius ?? 0)) of last spot"
        case .unplaced: return "No GPS, no link to a placed phone yet"
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

/// North-up plot around `center`, with distance rings, Bluetooth links, trails and uncertainty.
struct RadarView: View {
    let phones: [TrackedPhone]
    let links: [TrackedLink]
    let center: FloorPoint

    var body: some View {
        Canvas { context, size in
            // A direction-unresolved phone has no point of its own: it is drawn as its ring.
            let placed = phones.filter { $0.point != nil && !($0.directionUnresolved && $0.ring != nil) }
            let ringPhones: [(phone: TrackedPhone, ring: EstimateRing)] = phones.compactMap { phone in
                guard phone.directionUnresolved, let ring = phone.ring else { return nil }
                return (phone, ring)
            }
            // Fit every phone; an uncertainty circle may add up to 100 m.
            let extent = placed.reduce(10.0) { result, phone in
                let p = phone.point!
                return max(result, hypot(p.x - center.x, p.z - center.z) + min(phone.radius ?? 0, 100))
            }
            let step = [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000].first { extent / $0 <= 4 } ?? 10_000
            let rings = max(1, Int((extent / step).rounded(.up)))
            let scale = (min(size.width, size.height) / 2 - 20) / (Double(rings) * step)
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            func screen(_ p: FloorPoint) -> CGPoint {
                CGPoint(x: mid.x + (p.x - center.x) * scale, y: mid.y - (p.z - center.z) * scale)
            }
            func circle(_ c: CGPoint, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }

            for i in 1...rings {
                let r = Double(i) * step * scale
                context.stroke(circle(mid, r), with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                context.draw(Text(meters(Double(i) * step)).font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: mid.x + r * 0.71 + 2, y: mid.y - r * 0.71 - 7), anchor: .leading)
            }
            context.draw(Text("N").font(.caption.bold()).foregroundColor(.secondary), at: CGPoint(x: mid.x, y: 10))

            let byId = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
            for link in links {
                guard let a = byId[link.a]?.point, let b = byId[link.b]?.point else { continue }
                var path = Path()
                path.move(to: screen(a))
                path.addLine(to: screen(b))
                let style = link.uwbDistance != nil ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1, dash: [3, 3])
                context.stroke(path, with: .color(.secondary.opacity(0.45)), style: style)
            }

            for (phone, ring) in ringPhones {
                let c = screen(ring.center)
                let color = phone.isSelf ? Color.blue : TrackStyle.color(phone.state)
                let caption = MapPresentation.ringCaption(label: phone.isSelf ? "You" : phone.label, radius: ring.radius)
                context.stroke(circle(c, ring.radius * scale), with: .color(color.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                context.draw(Text(caption).font(.caption2), at: CGPoint(x: c.x, y: c.y - ring.radius * scale - 8))
            }

            for phone in placed {
                let p = screen(phone.point!)
                let color = phone.isSelf ? Color.blue : TrackStyle.color(phone.state)
                if phone.trail.count > 1 {
                    var path = Path()
                    path.addLines(phone.trail.map(screen))
                    context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 2)
                }
                for point in phone.cloud {
                    let q = screen(point)
                    context.fill(Path(ellipseIn: CGRect(x: q.x - 1.2, y: q.y - 1.2, width: 2.4, height: 2.4)),
                                 with: .color(color.opacity(0.35)))
                }
                if let radius = phone.radius, radius > 0 {
                    let style = phone.state == .lastSeen ? StrokeStyle(lineWidth: 1.5, dash: [5, 4]) : StrokeStyle(lineWidth: 1.5)
                    context.stroke(circle(p, radius * scale), with: .color(color.opacity(0.7)), style: style)
                }
                // An ambiguous estimate has no meaningful centre: show only its cloud and circle.
                if !phone.ambiguous {
                    context.fill(circle(p, phone.isSelf ? 6 : 5), with: .color(color))
                }
                context.draw(Text(phone.isSelf ? "You" : phone.label).font(.caption2.weight(.semibold)),
                             at: CGPoint(x: p.x, y: p.y - 13))
            }
        }
        .clipped()
    }
}
