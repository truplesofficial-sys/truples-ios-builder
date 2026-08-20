// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorCallKitPlugin",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorCallKitPlugin",
            targets: ["CapacitorCallKitPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "7.4.4")
    ],
    targets: [
        .target(
            name: "CapacitorCallKitPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/CallKitPlugin"
        )
    ]
)
