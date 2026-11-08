// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RelayVSR",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RelayVSR",
            path: "Sources/RelayVSR"
        )
    ]
)
