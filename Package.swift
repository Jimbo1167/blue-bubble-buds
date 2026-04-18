// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlueBubbleBuds",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BlueBubbleBuds",
            path: "Sources/BlueBubbleBuds"
        )
    ]
)
