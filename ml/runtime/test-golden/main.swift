// Checks the Swift runtime against predictions made by the trained PyTorch model.
//   swiftc -O ml/runtime/MovementModel.swift ml/runtime/test-golden/main.swift -o /tmp/mm-test && /tmp/mm-test ml/export

import Foundation

struct Case: Decodable {
    let hist: [[Double]]
    let acc: Double
    let h: Double
    let weights: [Double]
    let means: [[Double]]
    let covs: [[Double]]
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ml/export")
let model = try MovementModel(json: Data(contentsOf: dir.appendingPathComponent("movement-model.json")))
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("golden.json")))

var worst = 0.0
let start = Date()
for c in cases {
    let p = model.predict(history: c.hist.map { MovementModel.Point($0[0], $0[1]) }, accuracy: c.acc, horizon: c.h)
    for k in c.weights.indices {
        let got = [p.means[k].x, p.means[k].y], cov = [p.covs[k].xx, p.covs[k].xy, p.covs[k].yy]
        worst = max(worst, abs(p.weights[k] - c.weights[k]) / 1e-3)
        for i in 0..<2 { worst = max(worst, abs(got[i] - c.means[k][i]) / (1e-2 + 1e-4 * abs(c.means[k][i]))) }
        for i in 0..<3 { worst = max(worst, abs(cov[i] - c.covs[k][i]) / (1e-2 + 1e-3 * abs(c.covs[k][i]))) }
    }
}
let ms = Date().timeIntervalSince(start) * 1000 / Double(cases.count)
print("\(cases.count) golden cases, worst error \(String(format: "%.3f", worst)) of tolerance, \(String(format: "%.3f", ms)) ms per prediction")

let track = (0..<60).map { MovementModel.TrackPoint(t: 100 + 1.3 * Double($0), x: 1.3 * Double($0), y: 0) }
let hist = model.history(track: track, now: track.last!.t)
let histOk = hist.count == 31 && abs(hist[30].x - track.last!.x) < 1e-9 && abs(hist[0].x - (track.last!.x - 60)) < 1e-9
let pred = model.predict(history: hist, accuracy: 5, horizon: 60)
var g = SystemRandomNumberGenerator()
let dots = pred.sample(4000, using: &g)
let mx = dots.map(\.x).reduce(0, +) / Double(dots.count)
let ex = zip(pred.weights, pred.means).map { $0 * $1.x }.reduce(0, +)
print("history \(histOk ? "ok" : "WRONG"), sample mean x \(String(format: "%.1f", mx)) vs \(String(format: "%.1f", ex)) m")
exit(worst <= 1 && histOk && abs(mx - ex) < 4 ? 0 : 1)
