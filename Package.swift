// swift-tools-version: 5.9
import PackageDescription

#if compiler(>=6.0)
let extraSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]
#else
let extraSwiftSettings: [SwiftSetting] = []
#endif

let package = Package(
    name: "Scripta",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Scripta", targets: ["Scripta"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ScriptaCore",
            path: "Sources/ScriptaCore",
            swiftSettings: extraSwiftSettings
        ),
        .systemLibrary(
            name: "CWhisper",
            path: "Sources/CWhisper/include"
        ),
        .executableTarget(
            name: "Scripta",
            dependencies: [
                "ScriptaCore",
                "CWhisper",
            ],
            path: "Sources/Scripta",
            exclude: ["Info.plist"],
            swiftSettings: extraSwiftSettings,
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Scripta/Info.plist",
                    "-LSources/CWhisper/lib",
                    "-lwhisper",
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
