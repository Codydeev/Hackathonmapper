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
    private var pending: [String: DeviceUpdate] = [:]
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

    private func endpoint(_ origin: String, path: String) throws -> URL {
        guard let components = URLComponents(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else {
            throw URLError(.badURL)
        }
        return url.appendingPathComponent(path)
    }

    func checkConnection(origin: String) {
        checkTask?.cancel()
        connectionStatus = "Checking…"
        checkTask = Task {
            do {
                var request = URLRequest(url: try endpoint(origin, path: "api/health"))
                request.timeoutInterval = 3
                let (_, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                connectionStatus = "Dashboard reachable"
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
            pending[device.id] = device
        }
        pendingCount = pending.count
    }

    func start(origin: String, gatewayId: String, frameId: String) {
        stop()
        enabled = true
        rejectedBody = nil
        worker = Task {
            var delay = 1.0
            while !Task.isCancelled {
                if !pending.isEmpty {
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
                            request.httpBody = body
                            let (data, response) = try await URLSession.shared.data(for: request)
                            try Task.checkCancellation()
                            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                            if (200..<300).contains(http.statusCode) {
                                for sent in snapshot where pending[sent.id] == sent { pending[sent.id] = nil }
                                pendingCount = pending.count
                                lastSuccess = Date()
                                lastError = nil
                                delay = 1
                            } else if (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                                rejectedBody = body
                                lastError = "HTTP \(http.statusCode): \(String(decoding: data.prefix(512), as: UTF8.self)). Correct the data/frame or restart gateway."
                                delay = 1
                            } else {
                                throw URLError(.badServerResponse)
                            }
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        lastError = error.localizedDescription
                        delay = min(5, delay * 2)
                    }
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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
        lastSuccess = nil
        lastError = nil
    }
}
