// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPilot", targets: ["MeetingPilot"]),
        .executable(name: "DiarizeTest", targets: ["DiarizeTest"]),
    ],
    targets: [
        .target(
            name: "MeetingPilotCore",
            path: "Sources/MeetingPilotCore"
        ),
        .executableTarget(
            name: "MeetingPilot",
            dependencies: ["MeetingPilotCore"],
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
