// swift-tools-version: 5.9
import PackageDescription

#if compiler(>=6.0)
let mlxVersion: Package.Dependency = .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.0")
let transformersVersion: Package.Dependency = .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0")
let extraSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]
#else
let mlxVersion: Package.Dependency = .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.21.2")
let transformersVersion: Package.Dependency = .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.14")
let extraSwiftSettings: [SwiftSetting] = []
#endif

let package = Package(
    name: "MeetingPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPilot", targets: ["MeetingPilot"]),
    ],
    dependencies: [
        mlxVersion,
        transformersVersion,
    ],
    targets: [
        .target(
            name: "MeetingPilotCore",
            path: "Sources/MeetingPilotCore",
            swiftSettings: extraSwiftSettings
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
            swiftSettings: extraSwiftSettings,
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
