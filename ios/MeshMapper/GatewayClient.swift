import Combine
import Foundation
import MeshCore

@MainActor
final class GatewayClient: ObservableObject {
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var connectionStatus = "Not checked"
    @Published private(set) var pendingCount = 0
    @Published private(set) var enabled = false
    @Published private(set) var acceptedCount = 0
    @Published private(set) var ignoredCount = 0
    private var pending: [String: DeviceUpdate] = [:]
    /// Bumped whenever a pending report changes, so the worker can upload new data right away.
    private var pendingVersion = 0
    /// Upload new reports within this time, but no more often.
    static let minUploadGap: TimeInterval = 0.2
    /// Unchanged reports are re-sent this often as the gateway heartbeat.
    static let heartbeatInterval: TimeInterval = 1
    private static let pollInterval: TimeInterval = 0.05
    private var worker: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var rejectedBody: Data?

    private struct Batch: Encodable {
        let schemaVersion = 1
        let gatewayId: String
        let frameId: String
        let units = "m"
        let devices: [DeviceUpdate]
    }

    private struct UploadResult: Decodable {
        let accepted: Int
        let ignored: Int
    }

    private struct Health: Decodable {
        let mode: String?
    }

    private static let tokenRejected =
        "The dashboard refused the gateway token. Copy it again from `npm run tunnel` on the laptop."

    // Required only by the internet (tunnel) endpoint; the LAN server ignores the header.
    private func authorize(_ request: inout URLRequest, token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    /// Accepts what people actually paste: a missing `http://`, or the dashboard's full
    /// `…/api/updates` URL, and reduces it to the base URL.
    static func normalizedOrigin(_ origin: String) -> String {
        var text = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") { text = "http://" + text }
        for suffix in ["/api/updates", "/api/health", "/api", "/"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return text
    }

    private func endpoint(_ origin: String, path: String) throws -> URL {
        guard let components = URLComponents(string: Self.normalizedOrigin(origin)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else {
            throw URLError(.badURL)
        }
        return url.appendingPathComponent(path)
    }

    func checkConnection(origin: String, token: String) {
        checkTask?.cancel()
        connectionStatus = "Checking…"
        checkTask = Task {
            do {
                var request = URLRequest(url: try endpoint(origin, path: "api/health"))
                request.timeoutInterval = 3
                authorize(&request, token: token)
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 401 {
                    connectionStatus = "Token rejected"
                    lastError = Self.tokenRejected
                    return
                }
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                let mode = (try? JSONDecoder().decode(Health.self, from: data))?.mode
                connectionStatus = mode == "simulated"
                    ? "Reachable, but the dashboard shows simulated data (switch it to Live)"
                    : "Dashboard reachable"
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                connectionStatus = "Connection failed"
                lastError = error.localizedDescription
            }
        }
    }

    func enqueue(_ devices: [DeviceUpdate]) {
        for device in devices where pending[device.id] != nil || pending.count < 100 {
            if pending[device.id] != device { pendingVersion += 1 }
            pending[device.id] = device
        }
        pendingCount = pending.count
    }

    func start(origin: String, gatewayId: String, frameId: String, token: String) {
        stop()
        enabled = true
        rejectedBody = nil
        worker = Task {
            // One request in flight. New reports go out within minUploadGap; unchanged ones as a
            // heartbeat every heartbeatInterval; failures back off up to 5 s.
            var backoff = 0.0
            var retryAt = Date.distantPast
            var lastAttempt = Date.distantPast
            var sentVersion = -1
            while !Task.isCancelled {
                let now = Date()
                let sinceLast = now.timeIntervalSince(lastAttempt)
                let due = !pending.isEmpty && now >= retryAt && sinceLast >= Self.minUploadGap
                    && (pendingVersion != sentVersion || sinceLast >= Self.heartbeatInterval)
                if due {
                    lastAttempt = now
                    let version = pendingVersion
                    let snapshot = pending.values.sorted { $0.id < $1.id }
                    do {
                        for update in snapshot { try update.validate() }
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        let body = try encoder.encode(Batch(gatewayId: gatewayId, frameId: frameId, devices: snapshot))
                        if body != rejectedBody {
                            var request = URLRequest(url: try endpoint(origin, path: "api/updates"))
                            request.httpMethod = "POST"
                            request.timeoutInterval = 3
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            authorize(&request, token: token)
                            request.httpBody = body
                            let (data, response) = try await URLSession.shared.data(for: request)
                            try Task.checkCancellation()
                            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                            if http.statusCode == 401 {
                                // Retrying cannot fix a wrong token; stop until it is corrected.
                                lastError = Self.tokenRejected
                                stop()
                                return
                            }
                            if (200..<300).contains(http.statusCode) {
                                for sent in snapshot where pending[sent.id] == sent { pending[sent.id] = nil }
                                pendingCount = pending.count
                                if let result = try? JSONDecoder().decode(UploadResult.self, from: data) {
                                    acceptedCount += result.accepted
                                    ignoredCount += result.ignored
                                }
                                lastSuccess = Date()
                                lastError = nil
                                sentVersion = version
                                backoff = 0
                            } else if (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                                rejectedBody = body
                                lastError = "HTTP \(http.statusCode): \(String(decoding: data.prefix(512), as: UTF8.self)). Correct the data/frame or restart gateway."
                                sentVersion = version
                            } else {
                                throw URLError(.badServerResponse)
                            }
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        lastError = error.localizedDescription
                        backoff = min(5, max(1, backoff * 2))
                        retryAt = Date().addingTimeInterval(backoff)
                    }
                }
                do { try await Task.sleep(for: .seconds(Self.pollInterval)) } catch { return }
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        checkTask?.cancel()
        checkTask = nil
        enabled = false
    }

    func reset() {
        stop()
        pending.removeAll()
        pendingCount = 0
        rejectedBody = nil
        acceptedCount = 0
        ignoredCount = 0
        lastSuccess = nil
        lastError = nil
    }
}
