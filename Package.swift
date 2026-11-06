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
        .executable(name: "Siphon", targets: ["Siphon"])
    ],
    targets: [
        .executableTarget(
            name: "Siphon",
            path: "Sources/Siphon",
            linkerSettings: [.unsafeFlags(modernSDKLinkerFlags)]
        )
    ]
)
