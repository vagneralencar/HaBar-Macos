// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HaBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HaBar", targets: ["HaBar"])
    ],
    targets: [
        .executableTarget(
            name: "HaBar",
            path: "Sources/HaBar"
        ),
        .testTarget(name: "HaBarTests", dependencies: ["HaBar"])
    ]
)
