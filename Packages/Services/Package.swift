// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Services",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "Services", targets: ["Services"])
    ],
    dependencies: [
        // ← これが無いと Services 側で import Domain/Support できません
        .package(path: "../Domain"),
        .package(path: "../Support"),
    ],
    targets: [
        .target(
            name: "Services",
            // ← product 名は import 名と一致させる（超重要）
            dependencies: [
                .product(name: "Domain",  package: "Domain"),
                .product(name: "Support", package: "Support"),
            ],
            path: "Sources/Services"
        ),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Services"],
            path: "Tests/ServicesTests"
        )
    ]
)
