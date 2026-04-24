// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPilot", targets: ["MeetingPilot"]),
        .executable(name: "DiarizeTest", targets: ["DiarizeTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", "0.9.0"..<"0.12.0"),
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
                .product(name: "WhisperKit", package: "WhisperKit"),
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
        .executableTarget(
            name: "DiarizeTest",
            dependencies: ["MeetingPilotCore"],
            path: "Sources/DiarizeTest"
        ),
    ]
)
