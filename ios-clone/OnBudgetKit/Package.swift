// swift-tools-version: 6.0
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
        // NOTE (apiclient, Nov 9, 2026): the target root is "Sources"
        // (not "Sources/OnBudgetKit") so the API layer in
        // Sources/API/ compiles into the same OnBudgetKit module as
        // the scaffold files in Sources/OnBudgetKit/. Do not narrow
        // this back to Sources/OnBudgetKit — the API files would
        // silently drop out of the module.
        .target(
            name: "OnBudgetKit",
            path: "Sources"
        ),
        .testTarget(
            name: "OnBudgetKitTests",
            dependencies: ["OnBudgetKit"],
            path: "Tests/OnBudgetKitTests"
        ),
    ]
)
