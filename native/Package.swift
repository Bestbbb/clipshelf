// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipShelf",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipShelfCore", targets: ["ClipShelfCore"]),
        .library(name: "ShareInboxShared", targets: ["ShareInboxShared"]),
        .library(name: "ClipShelfLocalization", targets: ["ClipShelfLocalization"]),
        .executable(name: "ClipShelf", targets: ["ClipShelf"]),
        .executable(name: "ClipShelfHistoryBenchmark", targets: ["ClipShelfHistoryBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipShelfLocalization", resources: [.process("Resources")]),
        .target(name: "ClipShelfCore", dependencies: ["CSQLite", "ClipShelfLocalization"]),
        .target(name: "ShareInboxShared", dependencies: ["ClipShelfLocalization", "ClipShelfCore"]),
        .executableTarget(name: "ClipShelf", dependencies: [
            "ClipShelfCore", "ShareInboxShared", "ClipShelfLocalization", .product(name: "Sparkle", package: "Sparkle"),
        ], exclude: ["Sparkle-LICENSE.txt", "Resources"], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
        ]),
        .executableTarget(name: "ClipShelfHistoryBenchmark", dependencies: ["ClipShelfCore"], path: "Benchmarks/HistoryBenchmark"),
        .testTarget(name: "ClipShelfCoreTests", dependencies: ["ClipShelfCore"]),
        .testTarget(name: "ClipShelfLocalizationTests", dependencies: ["ClipShelfLocalization"]),
        .testTarget(name: "ClipShelfAppTests", dependencies: ["ClipShelf", "ClipShelfCore"]),
        .testTarget(name: "ClipShelfServicesTests", dependencies: ["ClipShelf", "ClipShelfCore", "ShareInboxShared"]),
        .testTarget(name: "ClipShelfMCPTests", dependencies: ["ClipShelf", "ClipShelfCore"]),
        .testTarget(name: "ClipShelfSyncTests", dependencies: ["ClipShelf", "ClipShelfCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
