// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DataStores",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "DataStores", targets: ["DataStores"])
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.6.0")
    ],
    targets: [
        .target(
            name: "DataStores",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk")
            ],
            path: "Sources/DataStores"
        ),
        .testTarget(
            name: "DataStoresTests",
            dependencies: ["DataStores"],
            path: "Tests/DataStoresTests"
        )
    ]
)

