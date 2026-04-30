// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Test2",
    platforms: [
        .iOS(.v18)
    ],
    targets: [
        .executableTarget(
            name: "Test2",
            path: "Sources"
        )
    ]
)
