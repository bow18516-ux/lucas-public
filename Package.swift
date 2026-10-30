// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JaplosClone",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lucasd", targets: ["japlosd"]),
        .executable(name: "JaplosApp", targets: ["JaplosApp"]),
        .library(name: "JaplosProtocol", targets: ["JaplosProtocol"]),
        .library(name: "JaplosKernel", targets: ["JaplosKernel"]),
        .library(name: "JaplosRuntime", targets: ["JaplosRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "JaplosProtocol"),
        .target(
            name: "JaplosKernel",
            dependencies: ["JaplosProtocol"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "JaplosRuntime",
            dependencies: ["JaplosProtocol", "JaplosKernel"],
            resources: [
                .copy("Resources/Prompts"),
                .copy("Resources/Injection"),
            ]
        ),
        .executableTarget(
            name: "japlosd",
            dependencies: ["JaplosKernel", "JaplosRuntime"]
        ),
        .executableTarget(
            name: "JaplosApp",
            dependencies: [
                "JaplosProtocol",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "JaplosProtocolTests",
            dependencies: ["JaplosProtocol"]
        ),
    ]
)
