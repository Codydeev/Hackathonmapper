// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeshCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MeshCore", targets: ["MeshCore"])],
    targets: [
        .target(name: "MeshCore"),
        // SignalMapTests reads the golden file next to it by path; it is data, not a source.
        .testTarget(name: "MeshCoreTests", dependencies: ["MeshCore"], exclude: ["signalmap-golden.json"])
    ]
)
