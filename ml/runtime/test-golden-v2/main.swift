// Checks the Swift runtime with a v2 model (map + destination) against
// predictions made by PyTorch on the Hervanta map.
//   swiftc -O ml/runtime/MovementModel.swift ml/runtime/test-golden-v2/main.swift -o /tmp/mm-test-v2 && /tmp/mm-test-v2 ml/export

import Foundation

struct Case: Decodable {
    let hist: [[Double]]
    let acc: Double
    let h: Double
    let destination: [Double]?
    let patchSum: Double
    let weights: [Double]
    let means: [[Double]]
    let covs: [[Double]]
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ml/export")
let model = try MovementModel(json: Data(contentsOf: dir.appendingPathComponent("movement-model-v2.json")))
let map = try MovementModel.MapLayer(png: Data(contentsOf: dir.appendingPathComponent("maps/hervanta.png")),
                                     meta: Data(contentsOf: dir.appendingPathComponent("maps/hervanta.json")))
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("golden-v2.json")))

var worst = 0.0, worstPatch = 0.0
let start = Date()
for c in cases {
    let hist = c.hist.map { MovementModel.Point($0[0], $0[1]) }
    let dest = c.destination.map { MovementModel.Point($0[0], $0[1]) }
    let prep = model.prepare(history: hist, accuracy: c.acc, map: map, destination: dest)
    let patchSum = model.samplePatch(map, origin: prep.origin, th: prep.th).reduce(0, +)
    worstPatch = max(worstPatch, abs(patchSum - c.patchSum) / (1e-3 + 1e-4 * c.patchSum))
    let p = model.predict(prepared: prep, horizon: c.h)
    for k in c.weights.indices {
        let got = [p.means[k].x, p.means[k].y], cov = [p.covs[k].xx, p.covs[k].xy, p.covs[k].yy]
        worst = max(worst, abs(p.weights[k] - c.weights[k]) / 1e-3)
        for i in 0..<2 { worst = max(worst, abs(got[i] - c.means[k][i]) / (1e-2 + 1e-4 * abs(c.means[k][i]))) }
        for i in 0..<3 { worst = max(worst, abs(cov[i] - c.covs[k][i]) / (1e-2 + 1e-3 * abs(c.covs[k][i]))) }
    }
}
let ms = Date().timeIntervalSince(start) * 1000 / Double(cases.count)
print("\(cases.count) golden cases: worst error \(String(format: "%.3f", worst)) of tolerance, map patch \(String(format: "%.3f", worstPatch)), \(String(format: "%.2f", ms)) ms each with the map")
exit(worst <= 1 && worstPatch <= 1 ? 0 : 1)
