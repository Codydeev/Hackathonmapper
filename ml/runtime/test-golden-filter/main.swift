// Checks the Swift route filter against the JS filter's golden cases: same
// seed, same signals, same answer.
//   swiftc -O ml/runtime/MovementModel.swift ml/runtime/RouteModel.swift ml/runtime/RouteFilter.swift \
//     ml/runtime/test-golden-filter/main.swift -o /tmp/mm-filter && /tmp/mm-filter ml/export

import Foundation

struct Event: Decodable {
    let t: Double; let kind: String
    let dx: Double?; let dy: Double?; let seconds: Double?
    let listener: [Double]?; let listenerAcc: Double?; let rssi: Double?
}
struct Out: Decodable { let center: [Double]; let r95: Double }
struct Case: Decodable {
    let kind: String; let hist: [[Double]]; let acc: Double; let seed: UInt32; let particles: Int; let T: Double
    let events: [Event]; let truth: [Double]; let out: Out
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ml/export")
let routes = try RouteModel(model: Data(contentsOf: dir.appendingPathComponent("route-model.json")),
                            graph: Data(contentsOf: dir.appendingPathComponent("graphs/hervanta.json")))
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("golden-filter.json")))

var worst = 0.0, ms = 0.0
for (i, c) in cases.enumerated() {
    let t0 = Date()
    let f = RouteFilter(routes, particles: c.particles, seed: c.seed)
    var s = f.start(history: c.hist.map { MovementModel.Point($0[0], $0[1]) }, accuracy: c.acc)
    for e in c.events {
        f.advance(&s, to: e.t)
        if e.kind == "steps" { f.observeSteps(&s, dx: e.dx!, dy: e.dy!, seconds: e.seconds!) }
        else { f.observeBluetooth(&s, listener: MovementModel.Point(e.listener![0], e.listener![1]), listenerAcc: e.listenerAcc!, rssi: e.rssi!) }
    }
    f.advance(&s, to: c.T)
    let est = f.estimate(s)
    ms += Date().timeIntervalSince(t0) * 1000
    let diff = hypot(est.center.x - c.out.center[0], est.center.y - c.out.center[1])
    worst = max(worst, diff, abs(est.r95 - c.out.r95))
    let errSwift = hypot(est.center.x - c.truth[0], est.center.y - c.truth[1]), errJS = hypot(c.out.center[0] - c.truth[0], c.out.center[1] - c.truth[1])
    print("case \(i) \(c.kind): Swift vs JS \(String(format: "%.4f", diff)) m; error vs truth Swift \(String(format: "%.1f", errSwift)) m, JS \(String(format: "%.1f", errJS)) m")
}
print("\(cases.count) filter golden cases: worst difference \(String(format: "%.4f", worst)) m, \(String(format: "%.0f", ms / Double(cases.count))) ms per 5-minute replay")
exit(worst <= 0.01 ? 0 : 1)
