// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "JitKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
        .library(name: "GitTestKit", targets: ["GitTestKit"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Features", targets: ["Features"]),
        .executable(name: "JitBench", targets: ["JitBench"]),
    ],
    targets: [
        // Foundation/Darwin only — never AppKit or SwiftUI (ADR-0002). Enforced by GitCoreTests.
        .target(name: "GitCore", swiftSettings: strict),
        .target(name: "GitTestKit", dependencies: ["GitCore"], swiftSettings: strict),
        .target(name: "DesignSystem", swiftSettings: strict),
        .target(name: "Features", dependencies: ["GitCore", "DesignSystem"], swiftSettings: strict),
        .executableTarget(name: "JitBench", dependencies: ["GitCore", "GitTestKit"], swiftSettings: strict),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore", "GitTestKit"], swiftSettings: strict),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
