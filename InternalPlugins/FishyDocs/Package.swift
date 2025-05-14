// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FishyDocs",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .plugin(
            name: "FishyDocsPlugin",
            targets: [
                "FishyDocsPlugin"
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.1.3"),
    ],
    targets: [
        .plugin(
            name: "FishyDocsPlugin",
            //            capability: .command(intent: .custom(verb: "fishy-docs", description: "Extracts source snippets from fishy-docs annotated docc documentation files")),
            capability: .buildTool(),
            dependencies: [
                "FishyDocs"
            ]
        ),
        .executableTarget(
            name: "FishyDocs",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "FishyDocsTests",
            dependencies: [
                "FishyDocs"
            ]
        ),
    ]
)
