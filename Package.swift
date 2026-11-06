// swift-tools-version: 6.0
import Foundation
import PackageDescription

// libmpv comes from Homebrew (`brew install mpv`) and is loaded from there at runtime.
// Homebrew lives in /opt/homebrew on Apple silicon and /usr/local on Intel.
let homebrew = ["/opt/homebrew", "/usr/local"].first {
    FileManager.default.fileExists(atPath: "\($0)/include/mpv/client.h")
} ?? "/opt/homebrew"

let package = Package(
    name: "Plexxed",
    platforms: [.macOS("26.0")],
    targets: [
        .systemLibrary(
            name: "Cmpv",
            path: "Sources/Cmpv",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "Plexxed",
            dependencies: ["Cmpv"],
            path: "Sources/Plexxed",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(homebrew)/include", "-Xcc", "-DGL_SILENCE_DEPRECATION"]),
            ],
            linkerSettings: [
                .linkedFramework("OpenGL"),
                .linkedFramework("QuartzCore"),
                .unsafeFlags(["-L\(homebrew)/lib"]),
            ]
        ),
    ]
)
