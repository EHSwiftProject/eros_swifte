// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ErosKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "EHModels", targets: ["EHModels"]),
        .library(name: "EHParsing", targets: ["EHParsing"]),
        .library(name: "EHNetwork", targets: ["EHNetwork"]),
        .library(name: "EHStore", targets: ["EHStore"]),
        .library(name: "EHDownload", targets: ["EHDownload"]),
        .library(name: "EHReader", targets: ["EHReader"]),
        // Fixture loader and hygiene checks; for tests and the capture tool only, never linked by the app.
        .library(name: "EHFixtures", targets: ["EHFixtures"]),
        // MockURLProtocol and RecordingThrottle; for tests only, never linked by the app. Dynamic so that a hosted
        // test bundle can depend on it and the host app alone, without a second, static copy of EHNetwork.
        .library(name: "EHNetworkTesting", type: .dynamic, targets: ["EHNetworkTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "EHModels"),
        .target(
            name: "EHParsing",
            dependencies: [
                "EHModels",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .target(name: "EHNetwork", dependencies: ["EHModels", "EHParsing"]),
        .target(
            name: "EHStore",
            dependencies: ["EHModels", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "EHDownload", dependencies: ["EHModels", "EHNetwork", "EHStore"]),
        .target(name: "EHReader", dependencies: ["EHModels", "EHNetwork", "EHStore", "EHDownload"]),
        .target(
            name: "EHFixtures",
            dependencies: ["EHModels"],
            path: "Tests/Fixtures",
            // local/: git-ignored private captures (only .gitkeep is tracked, so the directory always exists).
            exclude: ["README.md", "local"],
            resources: [.copy("eh"), .copy("ex"), .copy("constructed"), .copy("manifest.json")]
        ),
        .target(name: "EHNetworkTesting", dependencies: ["EHNetwork"], path: "Tests/NetworkTesting"),
        .testTarget(name: "EHModelsTests", dependencies: ["EHModels"], resources: [.copy("Golden")]),
        .testTarget(name: "EHParsingTests", dependencies: ["EHParsing", "EHFixtures"]),
        .testTarget(
            name: "EHNetworkTests",
            dependencies: ["EHNetwork", "EHModels", "EHParsing", "EHFixtures", "EHNetworkTesting"]
        ),
        .testTarget(
            name: "EHStoreTests",
            dependencies: [
                "EHStore", "EHModels", "EHNetworkTesting",
                // DatabaseError and its result codes, for the store's damage checks.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "EHDownloadTests", dependencies: ["EHDownload"]),
        .testTarget(name: "EHReaderTests", dependencies: ["EHReader"]),
        .testTarget(name: "EHFixturesTests", dependencies: ["EHFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
