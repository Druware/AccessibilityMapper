// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AccessibilityMapper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AccessibilityMapper",
            path: "Sources/AccessibilityMapper"
        )
    ]
)
