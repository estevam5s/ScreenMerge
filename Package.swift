// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenMerge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenMerge",
            path: "Sources"
        )
    ]
)
