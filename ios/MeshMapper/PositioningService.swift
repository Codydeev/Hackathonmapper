import CoreLocation
import Foundation
import MeshCore

/// This phone's positioning engine and everything that feeds it: its own GNSS (used only while the
/// integrity check trusts it), Core Motion, Bluetooth snapshots and the positions other phones
/// relay. `tick()` returns the contract `PositionEstimate` once a second. It can also record every
/// input as JSON lines so a field walk can be replayed through the same engine on a Mac
/// (`Positioning.Replay`).
///
/// Integration (GhostCoreHub / pipeline): create one per app run, call `start()`, forward inputs as
/// they arrive, call `tick()` from the one-second loop, and `withdraw(anchor:reason:)` when a
/// phone's integrity drops. Times from other phones are never compared with ours: relayed records
/// are timed by receipt minus their `freshness.ageAtHandoff`.
@MainActor
final class PositioningService: ObservableObject {
    @Published private(set) var estimate: Positioning.Estimate?
    @Published private(set) var record: PositionEstimate?
    @Published private(set) var recordingURL: URL?
    @Published private(set) var calibration: Positioning.CalibrationSession?
    /// "Simulate losing GPS": fixes are kept from the engine (and recorded as reference only).
    @Published var gnssHidden = false

    let selfId: String
    let frameId: String
    let motion = MotionSource()

    private var engine: Positioning.Engine
    private var anchorProvenance: [String: Provenance] = [:]
    private var recorder: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(selfId: String, frameId: String = GeoFrame.defaultFrameId) {
        self.selfId = selfId
        self.frameId = frameId
        engine = Positioning.Engine(selfId: selfId, frameId: frameId)
    }

    /// This phone's monotonic clock (Core Motion's), which the engine runs on.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A wall-clock date from this phone converted to its monotonic clock.
    static func monotonic(_ date: Date) -> TimeInterval { now - Date().timeIntervalSince(date) }

    func start() {
        motion.onMotion = { [weak self] sample in
            self?.engine.ingest(motion: sample)
            self?.write(.motion(sample: sample))
        }
        motion.onCompass = { [weak self] sample in
            self?.engine.ingest(compass: sample)
            self?.write(.compass(sample: sample))
        }
        motion.start()
    }

    func stop() {
        motion.stop()
        stopRecording()
    }

    /// Starts over, e.g. when the frame changes.
    func reset() {
        engine = Positioning.Engine(selfId: selfId, frameId: frameId)
        anchorProvenance = [:]
        estimate = nil
        record = nil
    }

    // MARK: Inputs

    /// This phone's own fix; `trusted` is its IntegrityAssessment's verdict (`status == .trusted`).
    func ingest(location: CLLocation, trusted: Bool) {
        let t = Self.monotonic(location.timestamp)
        guard let fix = Positioning.GNSSFix.make(
            frameId: frameId, t: t, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy, courseDegrees: location.course,
            courseAccuracyDegrees: location.courseAccuracy, speed: location.speed, trusted: trusted) else { return }
        if gnssHidden {
            // Kept from the engine; good fixes stay in the recording as the reference for replay.
            if fix.horizontalAccuracy <= 10 { write(.truth(position: fix.position, t: t)) }
            return
        }
        engine.ingest(gnss: fix)
        write(.gnss(fix: fix))
    }

    func ingest(observation: PeerObservation, receivedAt: Date = Date()) {
        let samples = Positioning.ContractMapping.rssiSamples(from: observation, selfId: selfId,
                                                              receivedAt: Self.monotonic(receivedAt), clock: .now())
        for s in samples {
            engine.ingest(rssi: s)
            calibration?.record(s)
            write(.rssi(sample: s))
        }
    }

    /// Another phone's relayed position with its own GNSS assessment (if it sent one).
    @discardableResult
    func ingest(relayed position: PositionEstimate, integrity: IntegrityAssessment?, receivedAt: Date = Date()) -> String? {
        switch Positioning.ContractMapping.anchor(from: position, integrity: integrity, selfId: selfId,
                                                  receivedAt: Self.monotonic(receivedAt)) {
        case .anchor(let a):
            engine.ingest(anchor: a)
            anchorProvenance[a.id] = position.provenance
            write(.anchor(anchor: a))
            return nil
        case .refused(let reason):
            // A phone that was anchoring us and stopped qualifying leaves at once.
            if anchorProvenance[position.subjectId] != nil { withdraw(anchor: position.subjectId, reason: reason) }
            return reason
        }
    }

    func withdraw(anchor id: String, reason: String) {
        let t = Self.now
        engine.removeAnchor(id, at: t, reason: reason)
        anchorProvenance[id] = nil
        write(.removeAnchor(id: id, t: t))
    }

    /// "I am here": a pinned spot or a marked start point.
    func declare(_ point: Positioning.Vec2, sigma: Double) {
        let t = Self.now
        engine.declare(position: point, sigma: sigma, at: t)
        write(.declared(position: point, sigma: sigma, t: t))
    }

    func setModel(_ model: Positioning.PathLossModel, for channel: Positioning.RSSIChannel) {
        engine.setModel(model, for: channel)
    }

    // MARK: Output

    /// The estimate for now, as a contract record. Call once a second.
    @discardableResult
    func tick(simulated: Bool = false) -> PositionEstimate {
        let e = engine.estimate(at: Self.now)
        let upstream = e.anchorIds.compactMap { anchorProvenance[$0] }
        let r = Positioning.ContractMapping.positionEstimate(e, subjectId: selfId, clock: .now(), upstream: upstream,
                                                             simulated: simulated)
        estimate = e
        record = r
        return r
    }

    func motionObservation(window: TimeInterval = 1) -> MotionObservation {
        Positioning.ContractMapping.motionObservation(engine.motionSummary(at: Self.now, window: window), subjectId: selfId,
                                                      frameId: frameId, clock: .now())
    }

    // MARK: Calibration (ARCHITECTURE.md T2: 2, 5, 10, 20 m)

    func beginCalibration(peerId: String, channel: Positioning.RSSIChannel, peerModel: String, environment: String) {
        calibration = Positioning.CalibrationSession(peerId: peerId, channel: channel, observerModel: Self.hardwareModel,
                                                     peerModel: peerModel, environment: environment)
    }

    func calibrationStep(distance: Double?, label: String = "") {
        if let distance { calibration?.begin(distance: distance, label: label) } else { calibration?.end() }
    }

    /// Fits and, if `apply`, uses the model for that channel from now on.
    func finishCalibration(apply: Bool) throws -> Positioning.CalibrationResult? {
        guard let session = calibration else { return nil }
        let result = try session.fit(window: 4, date: ISO8601DateFormatter().string(from: Date()))
        if apply { setModel(result.model, for: session.channel) }
        return result
    }

    func cancelCalibration() { calibration = nil }

    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Recording

    func startRecording() throws {
        stopRecording()
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("positioning-\(selfId)-\(stamp).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        recorder = try FileHandle(forWritingTo: url)
        recordingURL = url
        write(.header(selfId: selfId, frameId: frameId, note: "\(Self.hardwareModel) \(stamp)"))
    }

    func stopRecording() {
        try? recorder?.close()
        recorder = nil
    }

    private func write(_ record: Positioning.LogRecord) {
        guard let recorder, var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        recorder.write(data)
    }
}
