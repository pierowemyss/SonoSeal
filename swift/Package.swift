// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SonoSeal",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "AnalyzerCore"),
        .executableTarget(name: "SonoSeal", dependencies: ["AnalyzerCore"]),
        .testTarget(name: "AnalyzerCoreTests", dependencies: ["AnalyzerCore"]),
    ]
)
