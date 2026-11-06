// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Siphon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Siphon", targets: ["Siphon"])
    ],
    targets: [
        .executableTarget(
            name: "Siphon",
            path: "Sources/Siphon"
        )
    ]
)
