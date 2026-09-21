// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorCallkitPlugin",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorCallkitPlugin",
            targets: ["CapacitorCallkitPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "7.4.4")
    ],
    targets: [
        .target(
            name: "CapacitorCallkitPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/CallKitPlugin"
        )
    ]
)
