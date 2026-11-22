// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"])
    ],
    targets: [
        .executableTarget(
            name: "MacPilot",
            path: "Sources/MacPilot"
        ),
        .testTarget(
            name: "MacPilotTests",
            dependencies: ["MacPilot"],
            path: "Tests/MacPilotTests",
            exclude: ["Fixtures"]
        )
    ]
)
