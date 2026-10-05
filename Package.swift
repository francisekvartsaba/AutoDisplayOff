// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoDisplayOff",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AutoDisplayOff",
            path: "Sources/AutoDisplayOff"
        )
    ]
)
