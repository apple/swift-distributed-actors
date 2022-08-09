// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MultiNodeTestPlugin",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .plugin(
            name: "MultiNodeTestPlugin",
            targets: [
                "MultiNodeTestPlugin",
            ]
        ),
    ],
    dependencies: [
        .package(name: "swift-distributed-actors", path: "../"),
    ],
    targets: [
        .plugin(
            name: "MultiNodeTestPlugin",
            capability: .command(
                intent: .custom(verb: "multi-node", description: "Run MultiNodeTestKit based tests across multiple processes or physical compute nodes")
                /* permissions: needs full network access */
            ),
            dependencies: [
            ]
        ),
    ]
)
