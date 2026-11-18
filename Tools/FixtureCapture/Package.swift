// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FixtureCapture",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../Packages/ErosKit"),
    ],
    targets: [
        .target(
            name: "FixtureCaptureCore",
            dependencies: [
                .product(name: "EHModels", package: "ErosKit"),
                .product(name: "EHParsing", package: "ErosKit"),
                .product(name: "EHNetwork", package: "ErosKit"),
                .product(name: "EHFixtures", package: "ErosKit"),
            ]
        ),
        .executableTarget(
            name: "fixture-capture",
            dependencies: [
                "FixtureCaptureCore",
                .product(name: "EHModels", package: "ErosKit"),
                .product(name: "EHNetwork", package: "ErosKit"),
                .product(name: "EHParsing", package: "ErosKit"),
                .product(name: "EHFixtures", package: "ErosKit"),
            ]
        ),
        .testTarget(
            name: "FixtureCaptureCoreTests",
            dependencies: [
                "FixtureCaptureCore",
                .product(name: "EHModels", package: "ErosKit"),
                .product(name: "EHNetwork", package: "ErosKit"),
                .product(name: "EHParsing", package: "ErosKit"),
                .product(name: "EHFixtures", package: "ErosKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
