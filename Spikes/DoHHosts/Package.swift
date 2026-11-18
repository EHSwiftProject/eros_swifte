// swift-tools-version: 6.2
import PackageDescription

// Feasibility spike for DoH and custom hosts (design §5.5). Tests and the CLI hit the network,
// so this package is intentionally not part of scripts/test.sh.
let package = Package(
    name: "DoHHosts",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "DoHSpike", targets: ["DoHSpike"]),
        .executable(name: "doh-spike", targets: ["doh-spike"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ErosKit"),
    ],
    targets: [
        .target(
            name: "DoHSpike",
            dependencies: [.product(name: "EHNetwork", package: "ErosKit")]
        ),
        .executableTarget(
            name: "doh-spike",
            dependencies: ["DoHSpike", .product(name: "EHNetwork", package: "ErosKit")]
        ),
        .testTarget(
            name: "DoHSpikeTests",
            dependencies: ["DoHSpike", .product(name: "EHNetwork", package: "ErosKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
