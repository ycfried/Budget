// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnBudgetKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "OnBudgetKit",
            targets: ["OnBudgetKit"]
        ),
    ],
    targets: [
        .target(
            name: "OnBudgetKit",
            path: "Sources/OnBudgetKit"
        ),
        .testTarget(
            name: "OnBudgetKitTests",
            dependencies: ["OnBudgetKit"],
            path: "Tests/OnBudgetKitTests"
        ),
    ]
)
