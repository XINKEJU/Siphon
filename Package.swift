// swift-tools-version:5.10
import PackageDescription

// SwiftPM writes the deployment target into BOTH fields of LC_BUILD_VERSION:
// minos *and* sdk. macOS 26+ reads the sdk field to decide whether an app gets
// the modern window chrome (Liquid Glass toolbar/sidebar and the new window
// controls). Without an explicit -platform_version the binary claims sdk 14.0
// and AppKit silently renders the pre-Tahoe opaque title bar, even on macOS 27.
// Pin the linked SDK to 26.0 (the first release with the new design) while
// keeping the minimum deployment target at 14.0. build-app.sh lifts this to
// the actual SDK of the build machine for the shipped .app.
let modernSDKLinkerFlags: [String] = [
    "-Xlinker", "-platform_version",
    "-Xlinker", "macos",
    "-Xlinker", "14.0",
    "-Xlinker", "26.0"
]

let package = Package(
    name: "Siphon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Siphon", targets: ["Siphon"]),
        // Native Messaging gateway spawned by Chrome/Edge/Brave.
        .executable(name: "SiphonNM", targets: ["SiphonNM"]),
        .library(name: "SiphonBridge", targets: ["SiphonBridge"])
    ],
    targets: [
        // Shared stdio framing for the gateway (tests compile this file directly).
        .target(
            name: "SiphonBridge",
            path: "Sources/SiphonBridge"
        ),
        .executableTarget(
            name: "SiphonNM",
            dependencies: ["SiphonBridge"],
            path: "Sources/SiphonNM"
        ),
        .executableTarget(
            name: "Siphon",
            // LocalAuthBootstrap shares the token file path with SiphonNM.
            dependencies: ["SiphonBridge"],
            path: "Sources/Siphon",
            swiftSettings: [
                // Optimize the shipped binary for size (smaller .app, often better
                // code locality) instead of the default speed tuning.
                .unsafeFlags(["-Osize", "-whole-module-optimization"],
                             .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags(modernSDKLinkerFlags),
                // Drop unreachable code/data from the final Mach-O. Must be wrapped
                // in -Xlinker because linkerSettings flow through the swiftc driver.
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
            ]
        )
    ]
)
