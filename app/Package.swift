// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XRKConverter",
    platforms: [.macOS(.v13)],
    targets: [
        // All app logic lives here — this is what the 95% coverage target measures.
        .target(
            name: "XRKConverterCore",
            path: "Sources/XRKConverterCore"
        ),
        // Thin SwiftUI shell (@main + views). Excluded from the coverage metric.
        .executableTarget(
            name: "XRKConverter",
            dependencies: ["XRKConverterCore"],
            path: "Sources/XRKConverter"
        ),
        .testTarget(
            name: "XRKConverterCoreTests",
            dependencies: ["XRKConverterCore"],
            path: "Tests/XRKConverterCoreTests"
        ),
    ]
)
