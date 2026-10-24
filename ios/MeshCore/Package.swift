// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeshCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MeshCore", targets: ["MeshCore"])],
    targets: [
        .target(name: "MeshCore"),
        .testTarget(name: "MeshCoreTests", dependencies: ["MeshCore"])
    ]
)
