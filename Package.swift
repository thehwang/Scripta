// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPilot", targets: ["MeetingPilot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.21.2"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.14"),
    ],
    targets: [
        .target(
            name: "MeetingPilotCore",
            path: "Sources/MeetingPilotCore"
        ),
        .executableTarget(
            name: "MeetingPilot",
            dependencies: [
                "MeetingPilotCore",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ],
            path: "Sources/MeetingPilot",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MeetingPilot/Info.plist"
                ])
            ]
        ),
    ]
)
