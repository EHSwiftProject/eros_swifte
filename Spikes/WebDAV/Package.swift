// swift-tools-version: 6.2
import PackageDescription

// Compatibility spike for WebDAV sync with the Flutter app (design §6.3, M0 Task 13).
// The offline tests run in scripts/test.sh (with the WEBDAV_SPIKE_* variables cleared); the
// integration tests still need a local WebDAV server (scripts/serve-local-webdav.sh). M7 moves
// the useful parts into ErosKit and deletes this directory.
let package = Package(
    name: "WebDAV",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "WebDAVSpike", targets: ["WebDAVSpike"]),
    ],
    targets: [
        .target(name: "WebDAVSpike"),
        .testTarget(
            name: "WebDAVSpikeTests",
            dependencies: ["WebDAVSpike"],
            resources: [.copy("Golden"), .copy("MultiStatus")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
