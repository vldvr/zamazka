// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Zamazka",
    platforms: [.macOS(.v14)],
    products: [
        // The detector for Redakciya (~/Projects_and_tools/redakciya): Detector, TextScanner, FindingKind.
        .library(name: "ZamazkaKit", targets: ["ZamazkaKit"]),
    ],
    targets: [
        .executableTarget(
            name: "Zamazka",
            dependencies: ["ZamazkaKit"]
        ),
        .target(
            name: "ZamazkaKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        // Detector checks on synthetic data. Run without Xcode: `swift run zamazka-checks`.
        .executableTarget(
            name: "zamazka-checks",
            dependencies: ["ZamazkaKit"],
            path: "Checks"
        ),
        // The promo video: `swift run zamazka-reel`. Not part of the app.
        .executableTarget(
            name: "zamazka-reel",
            dependencies: ["ZamazkaKit"],
            path: "Promo"
        ),
    ]
)
