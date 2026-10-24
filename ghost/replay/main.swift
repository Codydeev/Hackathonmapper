// Replays every scenario in ghost/fixtures/ through the tracker the app ships and prints what a
// person would have seen: seconds as a ghost, how often the true path was inside the 95% circle,
// the median miss, and every recovery. Built and run by ghost/replay/run.sh.
//
//   replay <fixtures-dir> <out-dir>
import Foundation

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let files = try! FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

func f(_ v: Double?, _ d: Int = 1) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "-" }

var md = "| scenario | checks | ghost s | truth in r95 | median miss m | recoveries (gap s, miss m, in r95, action) |\n"
md += "|---|---|---|---|---|---|\n"
var failures: [String] = []
for url in files {
    let scenario = try! GhostReplay.load(Data(contentsOf: url))
    let r = GhostReplay.run(scenario)
    failures += r.failures
    let recoveries = r.recoveries.map { "\(Int($0.gap)), \(Int($0.error.rounded())), \($0.insideR95.map { $0 ? "yes" : "no" } ?? "-"), \($0.action.rawValue)" }
    md += "| \(scenario.name) | \(r.failures.isEmpty ? "pass" : "FAIL \(r.failures.count)") | \(r.ghostSeconds) | "
    md += "\(f(r.ghostCoverageR95.map { $0 * 100 }, 0))% | \(f(r.ghostMedianError)) | \(recoveries.joined(separator: "; ")) |\n"
}
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try! md.write(to: out.appendingPathComponent("replay-table.md"), atomically: true, encoding: .utf8)
print(md)
for line in failures { print(line) }
exit(failures.isEmpty ? 0 : 1)
