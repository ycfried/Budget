// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnBudgetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OnBudgetCore", targets: ["OnBudgetCore"])],
    targets: [
        .target(name: "OnBudgetCore"),
        .testTarget(name: "OnBudgetCoreTests", dependencies: ["OnBudgetCore"])
    ]
)
