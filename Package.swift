// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrimeConnectionKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PrimeConnectionKit", targets: ["PrimeConnectionKit"]),
        .library(name: "HPLink", targets: ["HPLink"]),
    ],
    targets: [
        // Transport, wire protocol, content codecs and the working-folder store.
        // Deliberately free of AppKit so it stays testable and reusable.
        .target(
            name: "HPLink",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The AppKit application.
        .executableTarget(
            name: "PrimeConnectionKit",
            dependencies: ["HPLink"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Link diagnostic for a real calculator.
        .executableTarget(
            name: "PrimeProbe",
            dependencies: ["HPLink"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HPLinkTests",
            dependencies: ["HPLink"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
