// swift-tools-version:5.10
import PackageDescription
import Foundation

let tapSpikePlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Spikes/ProcessTapSpike/CLI/Info.plist").path

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Speech-to-text: WhisperKit, now part of the Argmax OSS SDK (v1.0.0+)
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        // Global hotkeys with a built-in recorder UI
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(name: "ProcessTapSpikeCore", path: "Spikes/ProcessTapSpike/Core"),
        .target(name: "ProcessTapSpikeRing", path: "Spikes/ProcessTapSpike/Ring"),
        .executableTarget(
            name: "ProcessTapSpike",
            dependencies: ["ProcessTapSpikeCore", "ProcessTapSpikeRing"],
            path: "Spikes/ProcessTapSpike/CLI",
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", tapSpikePlist
            ])]
        ),
        .testTarget(name: "ProcessTapSpikeTests", dependencies: ["ProcessTapSpikeCore"],
                    path: "Tests/ProcessTapSpikeTests"),
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/LocalFlow"
        ),
        .testTarget(
            name: "LocalFlowTests",
            dependencies: ["LocalFlow"],
            path: "Tests/LocalFlowTests"
        )
    ]
)
