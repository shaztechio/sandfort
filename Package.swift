// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sandfort",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SandfortApp", targets: ["SandfortApp"])
    ],
    targets: [
        .executableTarget(
            name: "SandfortApp",
            path: "sources/sandfortapp"
        ),
        .testTarget(
            name: "SandfortAppTests",
            dependencies: ["SandfortApp"],
            path: "tests/sandfortapptests"
        )
    ]
)
