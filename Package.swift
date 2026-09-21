// swift-tools-version: 5.9
import Foundation
import PackageDescription

#if compiler(>=6.0)
let compilerSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]
#else
let compilerSwiftSettings: [SwiftSetting] = []
#endif

let translationSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["SCRIPTA_HAS_TRANSLATION"] == "1"
    ? [.define("SCRIPTA_HAS_TRANSLATION")] : []

let fmSuggestionsSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["SCRIPTA_HAS_FM_SUGGESTIONS"] == "1"
    ? [.define("SCRIPTA_HAS_FM_SUGGESTIONS")] : []

let extraSwiftSettings = compilerSwiftSettings + translationSettings + fmSuggestionsSettings

let translationLinker: [LinkerSetting] =
    ProcessInfo.processInfo.environment["SCRIPTA_HAS_TRANSLATION"] == "1"
    ? [.linkedFramework("Translation")] : []

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
            ] + translationLinker
        ),
    ]
)
