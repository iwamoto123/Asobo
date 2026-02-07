// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Domain",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "Domain", targets: ["Domain"])
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.6.0")
    ],
    targets: [
        .target(
            name: "Domain",
            dependencies: [
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk")
            ],
            path: "Sources/Domain"
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests")
    ]
)
