import Foundation

// Ambient radio fingerprinting (experimental). A phone records the Bluetooth LE advertisements it
// can hear at a spot whose position is known, and later compares what it hears with those
// recordings: "this sounds like the spot by the main door, give or take 12 m", or "insufficient
// evidence".
//
// Everything here is an observation of the surroundings. The devices behind the advertisements
// (beacons, TVs, printers, other people's phones and earbuds) are not GhostCore peers: they do not
// relay messages, report positions or act as anchors, and nothing here claims to know where they
// are. A match places the phone near a spot somebody recorded, never at a device.
//
// Isolated on purpose: GNSS integrity, positioning and the pipeline do not use this module until
// field data shows that it helps (AmbientRadioTests guards that). Nothing readable about other
// people's devices is kept: identifiers and advertisement contents are reduced to digests. What
// iOS lets an app see, what is stored and why fingerprints decay is in docs/AMBIENT_RADIO.md.

/// How an advertiser, or a kind of advertiser, is recognised again. Values are digests.
public struct AmbientEmitterKey: Hashable, Codable, Comparable, CustomStringConvertible {
    public enum Kind: String, Codable {
        /// iOS's identifier for the advertiser (`CBPeripheral.identifier`), digested: a random UUID
        /// iOS assigns on this phone, never the hardware address. It changes when the advertiser
        /// rotates its address (most phones, watches and earbuds do, about every 15 minutes), and
        /// another phone sees a different one for the same device.
        case ios
        /// An Eddystone-UID beacon's namespace and instance, digested: set by whoever configured
        /// the beacon, the same on every phone, stable until reconfigured.
        case eddystoneUID
        /// The n-th strongest steady advertiser of one advertisement class (`classDigest#n`). Not a
        /// device: it survives address rotation, but a new device of the same class can take the rank.
        case classRank
    }

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// Recognised by any phone, not only the one that recorded it.
    public var isPortable: Bool { kind != .ios }
    /// One device, rather than a rank within a class.
    public var isIdentity: Bool { kind != .classRank }
    public var description: String { "\(kind.rawValue):\(value)" }

    public static func < (a: AmbientEmitterKey, b: AmbientEmitterKey) -> Bool { a.description < b.description }

    public static func ios(_ identifier: UUID) -> AmbientEmitterKey {
        AmbientEmitterKey(kind: .ios, value: digest(identifier.uuidString))
    }

    /// Eddystone service (16-bit UUID FEAA) UID frame: type 0x00, Tx power, a 10-byte namespace and
    /// a 6-byte instance. Other Eddystone frames (URL, TLM, EID) are not stable identities.
    public static func eddystoneUID(serviceData: Data) -> AmbientEmitterKey? {
        let bytes = [UInt8](serviceData)
        guard bytes.count >= 18, bytes[0] == 0x00 else { return nil }
        return AmbientEmitterKey(kind: .eddystoneUID, value: digest(bytes[2..<18].map { String(format: "%02x", $0) }.joined()))
    }

    /// The most stable key an advertisement allows. `serviceData` is keyed by service UUID string
    /// (`CBUUID.uuidString`, "FEAA" for Eddystone).
    public static func best(identifier: UUID, serviceData: [String: Data] = [:]) -> AmbientEmitterKey {
        serviceData.first { $0.key.uppercased() == "FEAA" }.flatMap { eddystoneUID(serviceData: $0.value) } ?? ios(identifier)
    }

    /// What kind of advertisement this is, whichever device sent it: the company and the first
    /// payload byte of the manufacturer data (a message type for Apple and Microsoft), the
    /// advertised services and connectability. Survives address rotation; many devices share one.
    /// Only the digest is kept, never the manufacturer data.
    public static func advertisementClass(manufacturerData: Data?, serviceUUIDs: [String], connectable: Bool?) -> String {
        var parts: [String] = []
        if let manufacturerData, manufacturerData.count >= 2 {
            let bytes = [UInt8](manufacturerData)
            parts.append(String(format: "m%02x%02x", bytes[1], bytes[0]))
            if bytes.count >= 3 { parts.append(String(format: "t%02x", bytes[2])) }
        }
        parts += serviceUUIDs.map { "s" + $0.uppercased() }.sorted()
        if let connectable { parts.append(connectable ? "c" : "n") }
        return digest(parts.joined(separator: "|"))
    }

    /// FNV-1a, 64 bit, as 16 hex digits: keeps identifiers and advertisement contents out of
    /// storage. Not cryptographic; a class comes from a small space and could be guessed back.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// One advertisement from a passive scan. An observation of the surroundings, not a peer.
public struct AmbientAdvertisement: Equatable {
    public let time: TimeInterval
    public let emitter: AmbientEmitterKey
    /// dBm.
    public let rssi: Double
    /// `AmbientEmitterKey.advertisementClass`, when known.
    public let advertisementClass: String?
    /// Advertised service UUIDs; used only to leave GhostCore's own peers out, never stored.
    public let serviceUUIDs: [String]

    public init(time: TimeInterval, emitter: AmbientEmitterKey, rssi: Double, advertisementClass: String? = nil,
                serviceUUIDs: [String] = []) {
        self.time = time
        self.emitter = emitter
        self.rssi = rssi
        self.advertisementClass = advertisementClass
        self.serviceUUIDs = serviceUUIDs
    }
}

/// What a scan heard of one emitter (or class rank) over an interval.
public struct AmbientEmitterSummary: Codable, Equatable {
    public let emitter: AmbientEmitterKey
    /// Median RSSI, dBm, to 0.5 dB.
    public let rssi: Double
    /// Robust spread (1.4826 × median absolute deviation), dB.
    public let spread: Double
    /// Share of the interval's one-second slots in which it was heard, 0...1.
    public let presence: Double
    public let samples: Int
    /// Least-squares slope of the per-second median RSSI, dB/s. Something walking past changes fast.
    public let trend: Double

    public init(emitter: AmbientEmitterKey, rssi: Double, spread: Double, presence: Double, samples: Int, trend: Double) {
        self.emitter = emitter
        self.rssi = rssi
        self.spread = spread
        self.presence = presence
        self.samples = samples
        self.trend = trend
    }
}

/// Everything heard over one interval.
public struct AmbientSnapshot: Codable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// Devices and class ranks, sorted by key.
    public let emitters: [AmbientEmitterSummary]

    public init(start: TimeInterval, end: TimeInterval, emitters: [AmbientEmitterSummary]) {
        self.start = start
        self.end = end
        self.emitters = emitters
    }

    public var duration: TimeInterval { end - start }
}

/// Rolling buffer of advertisements, summarised over any recent interval.
public struct AmbientRecorder {
    /// Samples kept per emitter; scans with duplicates allowed deliver several a second.
    public static let maxSamplesPerEmitter = 1_200
    /// Class ranks kept per class: deeper ranks shuffle whenever anyone walks by.
    public static let maxRanksPerClass = 3
    /// A device ranks within its class only if heard in this share of the interval.
    public static let rankPresence = 0.5

    /// Service UUIDs whose advertisers are left out (GhostCore's own mesh service: those are peers,
    /// handled by the mesh, and they move).
    public let excludedServices: Set<String>
    /// Seconds kept.
    public let horizon: TimeInterval
    private var samples: [AmbientEmitterKey: [(time: TimeInterval, rssi: Double)]] = [:]
    private var classes: [AmbientEmitterKey: String] = [:]

    public init(excludedServices: Set<String> = [], horizon: TimeInterval = 120) {
        self.excludedServices = Set(excludedServices.map { $0.uppercased() })
        self.horizon = horizon
    }

    /// Devices currently in the buffer.
    public var emitterCount: Int { samples.count }

    /// Adds one advertisement; false when it is dropped (a GhostCore peer, or no usable RSSI: iOS
    /// reports 127 when it has none).
    @discardableResult
    public mutating func add(_ advertisement: AmbientAdvertisement) -> Bool {
        guard advertisement.rssi.isFinite, advertisement.rssi != 127, (-127...20).contains(advertisement.rssi),
              advertisement.time.isFinite, advertisement.emitter.isIdentity,
              !advertisement.serviceUUIDs.contains(where: { excludedServices.contains($0.uppercased()) }) else { return false }
        var list = samples[advertisement.emitter, default: []]
        if list.count == Self.maxSamplesPerEmitter { list.removeFirst() }
        list.append((advertisement.time, advertisement.rssi))
        samples[advertisement.emitter] = list
        if let advertisementClass = advertisement.advertisementClass { classes[advertisement.emitter] = advertisementClass }
        return true
    }

    /// Forgets everything older than `horizon` before `now`.
    public mutating func prune(now: TimeInterval) {
        let cutoff = now - horizon
        for (key, list) in samples {
            let kept = list.filter { $0.time >= cutoff }
            samples[key] = kept.isEmpty ? nil : kept
            if kept.isEmpty { classes[key] = nil }
        }
    }

    public mutating func removeAll() {
        samples = [:]
        classes = [:]
    }

    /// Summary of what was heard in `[start, end)`: each device, then each class's strongest steady
    /// devices as ranks.
    public func snapshot(from start: TimeInterval, to end: TimeInterval) -> AmbientSnapshot {
        let slots = max(1, Int((end - start).rounded(.up)))
        var devices: [AmbientEmitterSummary] = []
        for (key, list) in samples {
            let inside = list.filter { $0.time >= start && $0.time < end }
            guard !inside.isEmpty else { continue }
            devices.append(Self.summary(key, inside, start: start, slots: slots))
        }
        var ranks: [AmbientEmitterSummary] = []
        let byClass = Dictionary(grouping: devices.filter { $0.presence >= Self.rankPresence && classes[$0.emitter] != nil },
                                 by: { classes[$0.emitter]! })
        for (advertisementClass, members) in byClass {
            let ordered = members.sorted { ($0.rssi, $1.emitter) > ($1.rssi, $0.emitter) }
            for (index, member) in ordered.prefix(Self.maxRanksPerClass).enumerated() {
                ranks.append(AmbientEmitterSummary(
                    emitter: AmbientEmitterKey(kind: .classRank, value: "\(advertisementClass)#\(index + 1)"),
                    rssi: member.rssi, spread: member.spread, presence: member.presence, samples: member.samples,
                    trend: member.trend))
            }
        }
        return AmbientSnapshot(start: start, end: end, emitters: (devices + ranks).sorted { $0.emitter < $1.emitter })
    }

    private static func summary(_ key: AmbientEmitterKey, _ inside: [(time: TimeInterval, rssi: Double)],
                                start: TimeInterval, slots: Int) -> AmbientEmitterSummary {
        var bySlot: [Int: [Double]] = [:]
        for sample in inside { bySlot[min(slots - 1, max(0, Int(sample.time - start))), default: []].append(sample.rssi) }
        let values = inside.map(\.rssi)
        let middle = median(values)
        let spread = 1.4826 * median(values.map { abs($0 - middle) })
        // In slot order, so the same samples always give bit-identical sums.
        let points = bySlot.keys.sorted().map { (Double($0) + 0.5, median(bySlot[$0]!)) }
        return AmbientEmitterSummary(emitter: key, rssi: (middle * 2).rounded() / 2, spread: spread,
                                     presence: Double(bySlot.count) / Double(slots), samples: inside.count,
                                     trend: slope(points))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Least-squares slope; 0 with fewer than three points.
    static func slope(_ points: [(Double, Double)]) -> Double {
        guard points.count >= 3 else { return 0 }
        let n = Double(points.count)
        let mx = points.map(\.0).reduce(0, +) / n, my = points.map(\.1).reduce(0, +) / n
        let sxx = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        guard sxx > 0 else { return 0 }
        return points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +) / sxx
    }
}

/// Where a recorded spot's position came from.
public enum SpotPositionSource: String, Codable {
    /// Typed or pinned by a person, or surveyed: independent of GNSS.
    case declared
    /// This phone's GNSS, trusted by the integrity engine when the spot was recorded.
    case gnss
    /// This phone's GNSS with the GPS check off: nobody judged it.
    case gnssUnchecked
}

/// What a spot sounded like when it was recorded.
public struct RadioFingerprint: Codable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let frameId: String
    /// The spot on the frame's floor plane, meters.
    public let x: Double
    public let z: Double
    public let positionSource: SpotPositionSource
    /// 95 % radius of the spot's own position, meters.
    public let positionR95: Double
    /// App device ID of the recording phone: its `ios` keys mean nothing on other phones.
    public let recordedBy: String
    public let recordedAt: TimeInterval
    public let duration: TimeInterval
    /// Devices and class ranks that stayed steady through the recording.
    public let emitters: [AmbientEmitterSummary]
    /// Heard but left out as unsteady: passing by, heard too rarely, or too erratic.
    public let unsteadyCount: Int

    public struct Options: Equatable {
        /// Seconds of standing still a recording needs.
        public var minDuration: TimeInterval = 15
        public var minPresence = 0.5
        public var minSamples = 5
        /// dB.
        public var maxSpread = 8.0
        /// dB/s: faster than this, the emitter (or someone between) was moving.
        public var maxTrend = 0.4
        /// A spot with fewer steady devices cannot be told apart from others.
        public var minSteadyDevices = 3

        public init() {}
    }

    public enum Problem: String, Error, Equatable {
        case tooShort, tooFewSteadyDevices, invalidPosition
    }

    /// Keeps what stayed steady through `snapshot`, recorded standing still at a known spot.
    public static func record(_ snapshot: AmbientSnapshot, id: String = UUID().uuidString, label: String, frameId: String,
                              x: Double, z: Double, positionSource: SpotPositionSource, positionR95: Double,
                              recordedBy: String, options: Options = Options()) -> Result<RadioFingerprint, Problem> {
        guard x.isFinite, z.isFinite, abs(x) <= DashboardContract.maxCoordinate, abs(z) <= DashboardContract.maxCoordinate,
              positionR95.isFinite, positionR95 >= 0 else { return .failure(.invalidPosition) }
        guard snapshot.duration >= options.minDuration else { return .failure(.tooShort) }
        let steady = snapshot.emitters.filter {
            $0.presence >= options.minPresence && $0.samples >= options.minSamples
                && $0.spread <= options.maxSpread && abs($0.trend) <= options.maxTrend
        }
        guard steady.filter(\.emitter.isIdentity).count >= options.minSteadyDevices else { return .failure(.tooFewSteadyDevices) }
        let devices = snapshot.emitters.filter(\.emitter.isIdentity).count
        return .success(RadioFingerprint(
            id: id, label: DashboardContract.truncatedLabel(label), frameId: frameId, x: x, z: z,
            positionSource: positionSource, positionR95: positionR95, recordedBy: recordedBy, recordedAt: snapshot.end,
            duration: snapshot.duration, emitters: steady, unsteadyCount: devices - steady.filter(\.emitter.isIdentity).count))
    }
}

/// The recorded spots. They stay on the phone that recorded them.
public struct FingerprintDatabase: Codable, Equatable {
    public private(set) var fingerprints: [RadioFingerprint]

    public init(fingerprints: [RadioFingerprint] = []) {
        self.fingerprints = fingerprints
    }

    /// Adds a spot, replacing one with the same ID.
    public mutating func add(_ fingerprint: RadioFingerprint) {
        fingerprints.removeAll { $0.id == fingerprint.id }
        fingerprints.append(fingerprint)
    }

    public mutating func remove(id: String) {
        fingerprints.removeAll { $0.id == id }
    }

    /// Emitters heard strongly at spots too far apart for one fixed device to be near both: carried
    /// along (the user's own watch or earbuds, a companion's phone), so never evidence of place.
    /// −72 dBm is within a few meters of a typical advertiser.
    public func travellingEmitters(strongerThan strong: Double = -72, apart: Double = 30) -> Set<AmbientEmitterKey> {
        var travelling = Set<AmbientEmitterKey>()
        for (i, a) in fingerprints.enumerated() {
            for b in fingerprints[(i + 1)...] where a.frameId == b.frameId && hypot(a.x - b.x, a.z - b.z) >= apart {
                let strongInB = Set(b.emitters.filter { $0.rssi >= strong }.map(\.emitter))
                for emitter in a.emitters where emitter.rssi >= strong && strongInB.contains(emitter.emitter) {
                    travelling.insert(emitter.emitter)
                }
            }
        }
        return travelling
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FingerprintDatabase {
        try JSONDecoder().decode(FingerprintDatabase.self, from: data)
    }
}

/// The answer to "which recorded spot does this sound like?".
public struct FingerprintMatch: Equatable {
    public enum Verdict: String, Codable {
        case match, insufficientEvidence
    }

    public enum Reason: String, Codable, CaseIterable {
        /// Listened for less than the minimum window.
        case windowTooShort
        /// No spot recorded in this frame.
        case noFingerprints
        /// Too few steady devices heard at all.
        case tooFewEmittersHeard
        /// No recorded spot shares enough with what is heard now (elsewhere, or the devices rotated
        /// their addresses since).
        case tooFewCommonEmitters
        /// Two spots far apart fit about equally well.
        case ambiguous
        /// The best fit is not convincing against "somewhere not recorded".
        case weakMatch
    }

    public struct Candidate: Equatable {
        public let fingerprintId: String
        public let label: String
        public let x: Double
        public let z: Double
        /// 0...1, shared with the other spots and with "somewhere not recorded".
        public let posterior: Double
        /// Devices heard now that were recorded there.
        public let commonDevices: Int
        /// Class ranks heard now that were recorded there.
        public let commonClassRanks: Int
        /// Median |ΔRSSI| over everything in common, dB.
        public let rssiDifference: Double?
    }

    public let verdict: Verdict
    public let reasons: [Reason]
    /// Best first, at most three.
    public let candidates: [Candidate]
    /// Probability of being at none of the recorded spots.
    public let elsewhere: Double
    /// A match only: where, and a 95 % radius never below the matcher's `spotRadius`.
    public let x: Double?
    public let z: Double?
    public let r95: Double?
    /// Posterior of the matched spot together with any spots close to it.
    public let confidence: Double?
    public let positionSource: SpotPositionSource?
    /// Steady devices used from the live window.
    public let devicesHeard: Int
    /// One line for the UI.
    public let summary: String

    public var isMatch: Bool { verdict == .match }
}

/// Compares what is heard now with the recorded spots.
public struct FingerprintMatcher {
    public struct Options: Equatable {
        /// Seconds of listening needed, standing still.
        public var minWindow: TimeInterval = 10
        /// Live emitters heard in less of the window than this are ignored (passing by).
        public var minPresence = 0.3
        /// Devices, or class ranks, a spot must share with what is heard now.
        public var minCommon = 3
        /// Devices (not class ranks) a spot must share. Class ranks exist in every building ("the
        /// strongest Apple phone"), so on their own they matched other buildings in a third of
        /// synthetic visits: they may strengthen a match, never make one.
        public var minCommonDevices = 2
        /// Compare device identities (lost when devices rotate their address).
        public var useDevices = true
        /// Compare class ranks (survive rotation, but any device of the class can fill a rank).
        public var useClasses = true
        /// Class ranks repeat much of what the devices say, so they count this much.
        public var classWeight = 0.5
        /// dB: how much one emitter's level differs between two visits to the same spot (body,
        /// orientation, people in between, another phone model).
        public var rssiSigma = 6.0
        /// Recorded emitters stronger than this that are not heard now count against a spot.
        public var strongRSSI = -75.0
        /// Chance a recorded emitter is not heard on a later visit: strong ones rarely vanish (unless
        /// they rotate their address or are switched off), weak ones often.
        public var missStrong = 0.25
        public var missWeak = 0.7
        /// Weight of "somewhere not recorded", as one more spot.
        public var elsewhereWeight = 1.0
        public var minConfidence = 0.7
        /// How far from a recorded spot the surroundings still sound alike, meters: the floor on r95.
        /// Moving 15 m relative to a device 20 m away changes its level by about 6 dB, no more than
        /// two visits to the same spot differ, so a fingerprint cannot resolve finer than this.
        public var spotRadius = 20.0

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    private func uses(_ key: AmbientEmitterKey) -> Bool {
        key.isIdentity ? options.useDevices : options.useClasses
    }

    /// `deviceId`: this phone. Spots recorded by another phone are compared on portable keys only.
    public func match(_ snapshot: AmbientSnapshot, in database: FingerprintDatabase, frameId: String,
                      deviceId: String) -> FingerprintMatch {
        let spots = database.fingerprints.filter { $0.frameId == frameId }
        let travelling = database.travellingEmitters()
        let live = snapshot.emitters.filter {
            $0.presence >= options.minPresence && !travelling.contains($0.emitter) && uses($0.emitter)
        }
        let devicesHeard = live.filter(\.emitter.isIdentity).count
        func insufficient(_ reason: FingerprintMatch.Reason, _ candidates: [FingerprintMatch.Candidate] = [],
                          elsewhere: Double = 1, detail: String) -> FingerprintMatch {
            FingerprintMatch(verdict: .insufficientEvidence, reasons: [reason], candidates: candidates, elsewhere: elsewhere,
                             x: nil, z: nil, r95: nil, confidence: nil, positionSource: nil, devicesHeard: devicesHeard,
                             summary: "Insufficient evidence: \(detail)")
        }
        guard snapshot.duration >= options.minWindow else {
            return insufficient(.windowTooShort, detail: "listen for at least \(Int(options.minWindow)) s, standing still")
        }
        guard !spots.isEmpty else { return insufficient(.noFingerprints, detail: "no spots recorded here yet") }
        guard devicesHeard >= options.minCommon || (!options.useDevices && live.count >= options.minCommon) else {
            return insufficient(.tooFewEmittersHeard, detail: "only \(devicesHeard) steady device\(devicesHeard == 1 ? "" : "s") heard")
        }

        // Log-likelihood of each spot against "somewhere not recorded", under which every live
        // emitter is unexplained (its RSSI anywhere in a 60 dB span).
        let liveByKey = Dictionary(live.map { ($0.emitter, $0) }, uniquingKeysWith: { a, _ in a })
        var scored: [(spot: RadioFingerprint, logLikelihood: Double, devices: Int, ranks: Int, difference: Double?)] = []
        for spot in spots {
            let portableOnly = spot.recordedBy != deviceId
            let reference = spot.emitters.filter {
                !travelling.contains($0.emitter) && uses($0.emitter) && (!portableOnly || $0.emitter.isPortable)
            }
            let referenceKeys = Set(reference.map(\.emitter))
            var logLikelihood = 0.0
            var differences: [Double] = []
            var devices = 0, ranks = 0
            for emitter in reference {
                let weight = emitter.emitter.isIdentity ? 1 : options.classWeight
                if let heard = liveByKey[emitter.emitter] {
                    let sigma = (options.rssiSigma * options.rssiSigma + emitter.spread * emitter.spread
                                 + heard.spread * heard.spread).squareRoot()
                    let difference = heard.rssi - emitter.rssi
                    differences.append(abs(difference))
                    if emitter.emitter.isIdentity { devices += 1 } else { ranks += 1 }
                    logLikelihood += weight * (-0.5 * (difference / sigma) * (difference / sigma)
                                               - log(sigma * (2 * Double.pi).squareRoot() / 60))
                } else {
                    logLikelihood += weight * log((emitter.rssi >= options.strongRSSI ? options.missStrong : options.missWeak) / 0.9)
                }
            }
            for heard in live where heard.rssi >= options.strongRSSI && !referenceKeys.contains(heard.emitter)
                && (!portableOnly || heard.emitter.isPortable) {
                logLikelihood += (heard.emitter.isIdentity ? 1 : options.classWeight) * log(0.5)
            }
            let enough = max(devices, ranks) >= options.minCommon && devices >= options.minCommonDevices
            scored.append((spot, enough ? logLikelihood : -.infinity, devices, ranks,
                           differences.isEmpty ? nil : AmbientRecorder.median(differences)))
        }

        let elsewhereLog = log(options.elsewhereWeight)
        let top = max(elsewhereLog, scored.map(\.logLikelihood).max() ?? elsewhereLog)
        let total = exp(elsewhereLog - top) + scored.map { exp($0.logLikelihood - top) }.reduce(0, +)
        let elsewhere = exp(elsewhereLog - top) / total
        let ranked = scored.map { item in
            FingerprintMatch.Candidate(fingerprintId: item.spot.id, label: item.spot.label, x: item.spot.x, z: item.spot.z,
                                       posterior: item.logLikelihood.isFinite ? exp(item.logLikelihood - top) / total : 0,
                                       commonDevices: item.devices, commonClassRanks: item.ranks,
                                       rssiDifference: item.difference)
        }.sorted {
            ($0.posterior, $0.commonDevices + $0.commonClassRanks, $1.fingerprintId)
                > ($1.posterior, $1.commonDevices + $1.commonClassRanks, $0.fingerprintId)
        }
        let shown = Array(ranked.prefix(3))

        guard let best = ranked.first, best.posterior > 0 else {
            let most = ranked.map { max($0.commonDevices, $0.commonClassRanks) }.max() ?? 0
            return insufficient(.tooFewCommonEmitters, shown, elsewhere: elsewhere,
                                detail: "at most \(most) of the recorded signals heard here")
        }
        // Spots close together sound alike: their posteriors add up, and the radius covers them all.
        let cluster = ranked.filter { hypot($0.x - best.x, $0.z - best.z) <= 2 * options.spotRadius && $0.posterior > 0 }
        let confidence = cluster.map(\.posterior).reduce(0, +)
        guard confidence >= options.minConfidence else {
            if let rival = ranked.first(where: { hypot($0.x - best.x, $0.z - best.z) > 2 * options.spotRadius && $0.posterior >= 0.2 }) {
                return insufficient(.ambiguous, shown, elsewhere: elsewhere,
                                    detail: "sounds like \"\(best.label)\" or \"\(rival.label)\"")
            }
            return insufficient(.weakMatch, shown, elsewhere: elsewhere,
                                detail: "closest is \"\(best.label)\" at \(Int((confidence * 100).rounded())) %")
        }
        let x = cluster.map { $0.x * $0.posterior }.reduce(0, +) / confidence
        let z = cluster.map { $0.z * $0.posterior }.reduce(0, +) / confidence
        let spot = spots.first { $0.id == best.fingerprintId }!
        let reach = cluster.map { hypot($0.x - x, $0.z - z) }.max() ?? 0
        let r95 = (options.spotRadius * options.spotRadius + spot.positionR95 * spot.positionR95).squareRoot() + reach
        return FingerprintMatch(
            verdict: .match, reasons: [], candidates: shown, elsewhere: elsewhere, x: x, z: z, r95: r95,
            confidence: confidence, positionSource: spot.positionSource, devicesHeard: devicesHeard,
            summary: "Sounds like \"\(best.label)\" (±\(Int(r95.rounded())) m, \(Int((confidence * 100).rounded())) %)")
    }
}
