// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"])
    ],
    dependencies: [
        // Auto-updates. Pinned exactly; bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "MacPilot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MacPilot",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "MacPilotTests",
            dependencies: ["MacPilot"],
            path: "Tests/MacPilotTests",
            exclude: ["Fixtures"]
        )
    ]
)
