// Checks the Swift route model against the JS runtime's golden cases, and
// times loading the graph and predicting.
//   swiftc -O ml/runtime/MovementModel.swift ml/runtime/RouteModel.swift ml/runtime/test-golden-routes/main.swift -o /tmp/mm-routes && /tmp/mm-routes ml/export

import Foundation

struct GoldenRoute: Decodable { let p: Double; let text: String; let turn: String; let n: Int; let start: [Double]; let end: [Double]; let length: Double }
struct GoldenMarker: Decodable { let point: [Double]; let atEnd: Bool }
struct GoldenOut: Decodable { let offPath: Double; let offNow: Bool; let bin: Int; let routes: [GoldenRoute]; let at: [String: [GoldenMarker]] }
struct Case: Decodable { let hist: [[Double]]; let acc: Double; let out: GoldenOut }

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ml/export")
let modelData = try Data(contentsOf: dir.appendingPathComponent("route-model.json"))
let graphData = try Data(contentsOf: dir.appendingPathComponent("graphs/hervanta.json"))
var t0 = Date()
let rm = try RouteModel(model: modelData, graph: graphData)
let loadMs = Date().timeIntervalSince(t0) * 1000
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("golden-routes.json")))

var mismatch = 0, worst = 0.0, predictMs = 0.0
for (ci, c) in cases.enumerated() {
    let hist = c.hist.map { MovementModel.Point($0[0], $0[1]) }
    t0 = Date()
    let pred = rm.predictRoutes(history: hist, accuracy: c.acc)
    predictMs += Date().timeIntervalSince(t0) * 1000
    let g = c.out
    guard pred.routes.count == g.routes.count, pred.offNow == g.offNow, pred.bin == g.bin else {
        mismatch += 1
        print("case \(ci): \(pred.routes.count) routes vs \(g.routes.count), offNow \(pred.offNow) vs \(g.offNow), bin \(pred.bin) vs \(g.bin)")
        continue
    }
    worst = max(worst, abs(pred.offPath - g.offPath))
    for (i, r) in pred.routes.enumerated() {
        let e = g.routes[i]
        if r.text != e.text || r.line.count != e.n {
            mismatch += 1
            print("case \(ci) route \(i): '\(r.text)' (\(r.line.count) pts) vs '\(e.text)' (\(e.n) pts)")
        }
        worst = max(worst, abs(r.p - e.p), abs(r.cum.last! - e.length) / 100, abs(r.line.last!.x - e.end[0]) / 100, abs(r.line.last!.y - e.end[1]) / 100)
    }
    for t in [120, 300, 600] {
        for (i, m) in rm.whereAlong(pred, seconds: Double(t)).enumerated() {
            let e = g.at[String(t)]![i]
            worst = max(worst, abs(m.point.x - e.point[0]) / 100, abs(m.point.y - e.point[1]) / 100)
            if m.atEnd != e.atEnd { mismatch += 1 }
        }
    }
}
print("\(cases.count) route golden cases: \(mismatch) mismatched routes or labels, worst difference \(String(format: "%.4f", worst)); graph load \(Int(loadMs)) ms, \(String(format: "%.2f", predictMs / Double(cases.count))) ms per prediction")
exit(mismatch == 0 && worst <= 0.01 ? 0 : 1)
