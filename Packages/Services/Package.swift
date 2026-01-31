// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Services",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "Services", targets: ["Services"])
    ],
    dependencies: [
        // ← 既存
        .package(path: "../Domain"),
        .package(path: "../Support"),
        // ← ここを追加（URLと package 名がとても大事）
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            from: "1.20.0"
        )
    ],
    targets: [
        .target(
            name: "Services",
            dependencies: [
                // ← 既存
                .product(name: "Domain", package: "Domain"),
                .product(name: "Support", package: "Support"),
                // ← ここを追加（綴り必ずこの通り）
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
                // 拡張を使うなら↓も追加（使わないなら不要）
                // .product(name: "onnxruntime_extensions", package: "onnxruntime-swift-package-manager"),
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
