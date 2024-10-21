// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import class Foundation.ProcessInfo
import PackageDescription

// Workaround: Since we cannot include the flat just as command line options since then it applies to all targets,
// and ONE of our dependencies currently produces one warning, we have to use this workaround to enable it in _our_
// targets when the flag is set. We should remove the dependencies and then enable the flag globally though just by passing it.
var globalSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Products

let products: [PackageDescription.Product] = [
    .library(
        name: "DistributedCluster",
        targets: ["DistributedCluster"]
    ),
]

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Targets

var targets: [PackageDescription.Target] = [
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster

    .target(
        name: "DistributedCluster",
        dependencies: [
            "DistributedActorsConcurrencyHelpers",
            "CDistributedActorsMailbox", // TODO(swift): remove mailbox runtime, use Swift actors directly
            .product(name: "OrderedCollections", package: "swift-collections"),
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "SWIM", package: "swift-cluster-membership"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "ServiceDiscovery", package: "swift-service-discovery"),
            .product(name: "Backtrace", package: "swift-backtrace"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: TestKit

    /// This target is intended only for use in tests, though we have no way to mark this
    .target(
        name: "DistributedActorsTestKit",
        dependencies: [
            "DistributedCluster",
            "DistributedActorsConcurrencyHelpers",
            .product(name: "Atomics", package: "swift-atomics"),
        ]
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Tests

    .testTarget(
        name: "DistributedClusterTests",
        dependencies: [
            "DistributedCluster",
            "DistributedActorsTestKit",
            .product(name: "Atomics", package: "swift-atomics"),
        ]
    ),

    .testTarget(
        name: "DistributedActorsTestKitTests",
        dependencies: [
            "DistributedCluster",
            "DistributedActorsTestKit",
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: MultiNodeTestKit

    // MultiNodeTest plugin and library --------------------------------------------------------------------------------
    .plugin(
        name: "MultiNodeTestPlugin",
        capability: .command(
            intent: .custom(verb: "multi-node", description: "Run MultiNodeTestKit based tests across multiple processes or physical compute nodes")
            /* permissions: needs full network access */
        ),
        dependencies: []
        
    ),
    .target(
        name: "MultiNodeTestKit",
        dependencies: [
            "DistributedCluster",
            // "DistributedActorsTestKit", // can't depend on it because it'll pull in XCTest, and that crashes in executable then
            .product(name: "Backtrace", package: "swift-backtrace"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "OrderedCollections", package: "swift-collections"),
        ]
    ),
    .executableTarget(
        name: "MultiNodeTestKitRunner",
        dependencies: [
            // Depend on tests to run:
            "DistributedActorsMultiNodeTests",

            // Dependencies:
            "MultiNodeTestKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Multi Node Tests

    // MultiNodeTests declared within this project
    .target(
        name: "DistributedActorsMultiNodeTests",
        dependencies: [
            "MultiNodeTestKit",
        ],
        path: "MultiNodeTests/DistributedActorsMultiNodeTests"
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Integration Tests - `it_` prefixed

    // TODO: convert to multi-node test
    .executableTarget(
        name: "it_Clustered_swim_suspension_reachability",
        dependencies: [
            "DistributedCluster",
        ],
        path: "IntegrationTests/tests_01_cluster/it_Clustered_swim_suspension_reachability"
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Performance / Benchmarks
    // TODO: Use new benchmarking infra

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Internals; NOT SUPPORTED IN ANY WAY

    .target(
        name: "CDistributedActorsMailbox",
        dependencies: []
    ),

    .target(
        name: "DistributedActorsConcurrencyHelpers",
        dependencies: [],
        exclude: [
            "README.md",
        ]
    ),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-atomics", from: "1.1.0"),

    // .package(url: "https://github.com/apple/swift-cluster-membership", from: "0.3.0"),
//    .package(name: "swift-cluster-membership", path: "Packages/swift-cluster-membership"), // FIXME: just work in progress
    .package(url: "https://github.com/apple/swift-cluster-membership", branch: "main"),

    .package(url: "https://github.com/apple/swift-nio", from: "2.75.0"),
    .package(url: "https://github.com/apple/swift-nio-extras", from: "1.24.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.28.0"),

    .package(url: "https://github.com/apple/swift-protobuf", from: "1.25.1"),

    // ~~~ backtraces ~~~
    // TODO: optimally, library should not pull swift-backtrace
    .package(url: "https://github.com/swift-server/swift-backtrace", from: "1.1.1"),

    // ~~~ Swift libraries ~~~
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0-beta"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.0.5"),

    // ~~~ Observability ~~~
    .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
    // swift-metrics 1.x and 2.x are almost API compatible, so most clients should use
    .package(url: "https://github.com/apple/swift-metrics", "1.0.0" ..< "3.0.0"),
    .package(url: "https://github.com/apple/swift-service-discovery", from: "1.3.0"),

    // ~~~ SwiftPM Plugins ~~~
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),

    // ~~~ Command Line ~~~~
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.3"),
]

if ProcessInfo.processInfo.environment["VALIDATE_DOCS"] != nil {
    dependencies.append(
        // internal only docc assisting fishy-docs plugin:
        .package(name: "FishyDocsPlugin", path: "./InternalPlugins/FishyDocs/")
    )

    targets.append(
        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Documentation

        // Target used to verify compilation of code snippets from documentation
        .testTarget(
            name: "DocsTests",
            dependencies: [
                "DistributedCluster",
            ],
            exclude: [
                "README.md",
            ],
            plugins: [
                .plugin(name: "FishyDocsPlugin", package: "FishyDocsPlugin"),
            ]
        )
    )
}

// This is a workaround since current published nightly docker images don't have the latest Swift availabilities yet
let platforms: [SupportedPlatform]?
#if os(Linux)
platforms = nil
#else
platforms = [
    // we require the 'distributed actor' language and runtime feature:
    .iOS(.v18),
    .macOS(.v15),
    .tvOS(.v18),
    .watchOS(.v11),
]
#endif

var package = Package(
    name: "swift-distributed-actors",
    platforms: platforms,
    products: products,

    dependencies: dependencies,

    targets: targets.map { target in
        var swiftSettings = target.swiftSettings ?? []
        if target.type != .plugin {
            swiftSettings.append(contentsOf: globalSwiftSettings)
        }
        if !swiftSettings.isEmpty {
            target.swiftSettings = swiftSettings
        }
        return target
    },

    cxxLanguageStandard: .cxx11
)
