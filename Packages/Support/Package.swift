// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Support",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "Support", targets: ["Support"])
    ],
    targets: [
        .target(name: "Support", path: "Sources/Support"),
        .testTarget(name: "SupportTests", dependencies: ["Support"], path: "Tests/SupportTests")
    ]
)
