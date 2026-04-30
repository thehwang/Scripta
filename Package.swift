// swift-tools-version: 5.9
import PackageDescription

#if compiler(>=6.0)
let extraSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]
#else
let extraSwiftSettings: [SwiftSetting] = []
#endif

let package = Package(
    name: "MeetingPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPilot", targets: ["MeetingPilot"]),
    ],
    dependencies: [],
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
