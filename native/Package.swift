// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipShelf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipShelfCore", targets: ["ClipShelfCore"]),
        .library(name: "ShareInboxShared", targets: ["ShareInboxShared"]),
        .executable(name: "ClipShelf", targets: ["ClipShelf"]),
        .executable(name: "ClipShelfHistoryBenchmark", targets: ["ClipShelfHistoryBenchmark"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipShelfCore", dependencies: ["CSQLite"]),
        .target(name: "ShareInboxShared"),
        .executableTarget(name: "ClipShelf", dependencies: ["ClipShelfCore", "ShareInboxShared"]),
        .executableTarget(name: "ClipShelfHistoryBenchmark", dependencies: ["ClipShelfCore"], path: "Benchmarks/HistoryBenchmark"),
        .testTarget(name: "ClipShelfCoreTests", dependencies: ["ClipShelfCore"]),
        .testTarget(name: "ClipShelfAppTests", dependencies: ["ClipShelf", "ClipShelfCore"]),
        .testTarget(name: "ClipShelfServicesTests", dependencies: ["ClipShelf", "ClipShelfCore", "ShareInboxShared"]),
        .testTarget(name: "ClipShelfMCPTests", dependencies: ["ClipShelf", "ClipShelfCore"]),
        .testTarget(name: "ClipShelfSyncTests", dependencies: ["ClipShelf", "ClipShelfCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
