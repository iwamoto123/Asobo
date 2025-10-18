// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Domain",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "Domain", targets: ["Domain"])
    ],
    targets: [
        .target(name: "Domain", path: "Sources/Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests")
    ]
)
