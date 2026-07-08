// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "simlease",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimLeaseCore", targets: ["SimLeaseCore"]),
        .executable(name: "simlease", targets: ["simlease"]),
        .executable(name: "SimLeaseApp", targets: ["SimLeaseApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "SimLeaseCore"),
        .executableTarget(
            name: "simlease",
            dependencies: [
                "SimLeaseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "SimLeaseApp", dependencies: ["SimLeaseCore"]),
        .testTarget(name: "SimLeaseCoreTests", dependencies: ["SimLeaseCore"]),
    ]
)
