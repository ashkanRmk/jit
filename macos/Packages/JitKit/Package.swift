// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "JitKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
        .library(name: "GitTestKit", targets: ["GitTestKit"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Services", targets: ["Services"]),
        .library(name: "Features", targets: ["Features"]),
        .executable(name: "JitBench", targets: ["JitBench"]),
        .executable(name: "jit-git-helper", targets: ["JitGitHelper"]),
        .executable(name: "TestRig", targets: ["TestRig"]),
    ],
    targets: [
        // Foundation/Darwin only — never AppKit or SwiftUI (ADR-0002). Enforced by GitCoreTests.
        .target(name: "GitCore", swiftSettings: strict),
        .target(name: "GitTestKit", dependencies: ["GitCore"], swiftSettings: strict),
        .target(name: "DesignSystem", swiftSettings: strict),
        // App state, persistence, sessions, file watching. Imports GitCore directly (no bridge layer); no UI.
        .target(name: "Services", dependencies: ["GitCore"], swiftSettings: strict),
        .target(name: "Features", dependencies: ["GitCore", "Services", "DesignSystem"], swiftSettings: strict),
        // Credential helper / askpass / GIT_SSH_COMMAND wrapper embedded at Contents/Helpers/jit-git-helper
        // (ADR-0016, ADR-0036). Foundation/Darwin only; holds no secrets at rest.
        .executableTarget(name: "JitGitHelper", swiftSettings: strict),
        // Dev-only local enterprise rig (ADR-0039): TLS front for git http-backend, proxy, GitLab API stub.
        // Never embedded in the app.
        .executableTarget(name: "TestRig", swiftSettings: strict),
        .executableTarget(
            name: "JitBench", dependencies: ["GitCore", "GitTestKit", "Features", "DesignSystem"], swiftSettings: strict
        ),
        .testTarget(
            name: "GitCoreTests", dependencies: ["GitCore", "GitTestKit"], exclude: ["Resources"], swiftSettings: strict
        ),
        .testTarget(
            name: "ServicesTests", dependencies: ["Services", "GitCore", "GitTestKit", "JitGitHelper"],
            swiftSettings: strict),
        .testTarget(
            name: "FeaturesTests", dependencies: ["Features", "Services", "GitCore", "GitTestKit", "DesignSystem"],
            exclude: ["__Snapshots__"], swiftSettings: strict),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
