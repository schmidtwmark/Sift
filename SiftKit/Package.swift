// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SiftKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SiftKit", targets: ["SiftKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SiftKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "SiftKitTests", dependencies: ["SiftKit"]),
    ]
)
