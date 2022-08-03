// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import class Foundation.ProcessInfo
import PackageDescription

// Workaround: Since we cannot include the flat just as command line options since then it applies to all targets,
// and ONE of our dependencies currently produces one warning, we have to use this workaround to enable it in _our_
// targets when the flag is set. We should remove the dependencies and then enable the flag globally though just by passing it.
var globalSwiftSettings: [SwiftSetting] = []

var targets: [PackageDescription.Target] = [
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actors

    .target(
        name: "DistributedActors",
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
            "DistributedActors",
            "DistributedActorsConcurrencyHelpers",
            .product(name: "Atomics", package: "swift-atomics"),
        ]
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Tests

    .testTarget(
        name: "DistributedActorsTests",
        dependencies: [
            "DistributedActors",
            "DistributedActorsTestKit",
            .product(name: "Atomics", package: "swift-atomics"),
        ]
    ),

    .testTarget(
        name: "DistributedActorsTestKitTests",
        dependencies: [
            "DistributedActors",
            "DistributedActorsTestKit",
        ]
    ),

//    .testTarget(
//        name: "CDistributedActorsMailboxTests",
//        dependencies: [
//            "CDistributedActorsMailbox",
//            "DistributedActorsTestKit"
//        ]
//    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Integration Tests - `it_` prefixed

    .executableTarget(
        name: "it_Clustered_swim_suspension_reachability",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_01_cluster/it_Clustered_swim_suspension_reachability"
    ),
//    .target(
//        name: "it_Clustered_swim_ungraceful_shutdown",
//        dependencies: [
//            "DistributedActors",
//        ],
//        path: "IntegrationTests/tests_04_cluster/it_Clustered_swim_ungraceful_shutdown"
//    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Performance / Benchmarks

//    .executableTarget(
//        name: "DistributedActorsBenchmarks",
//        dependencies: [
//            "DistributedActors",
//            "SwiftBenchmarkTools",
//            .product(name: "Atomics", package: "swift-atomics"),
//        ],
//        exclude: [
//          "README.md",
//          "BenchmarkProtos/bench.proto",
//        ]
//    ),
//    .target(
//        name: "SwiftBenchmarkTools",
//        dependencies: ["DistributedActors"],
//        exclude: [
//          "README_SWIFT.md"
//        ]
//    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples are defined in Samples/Package.swift
    // ==== ----------------------------------------------------------------------------------------------------------------

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
    .package(url: "https://github.com/apple/swift-atomics", from: "1.0.2"),

    // .package(url: "https://github.com/apple/swift-cluster-membership", from: "0.3.0"),
//    .package(name: "swift-cluster-membership", path: "Packages/swift-cluster-membership"), // FIXME: just work in progress
    .package(url: "https://github.com/apple/swift-cluster-membership", branch: "main"),

    .package(url: "https://github.com/apple/swift-nio", from: "2.40.0"),
    .package(url: "https://github.com/apple/swift-nio-extras", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.16.1"),

    .package(url: "https://github.com/apple/swift-protobuf", from: "1.7.0"),

    // ~~~ backtraces ~~~
    // TODO: optimally, library should not pull swift-backtrace
    .package(url: "https://github.com/swift-server/swift-backtrace", from: "1.1.1"),

    // ~~~ Swift libraries ~~~
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "0.0.3"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.0.1"),

    // ~~~ Observability ~~~
    .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
    // swift-metrics 1.x and 2.x are almost API compatible, so most clients should use
    .package(url: "https://github.com/apple/swift-metrics", "1.0.0" ..< "3.0.0"),
    .package(url: "https://github.com/apple/swift-service-discovery", from: "1.0.0"),

    // ~~~ SwiftPM Plugins ~~~
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
]

let products: [PackageDescription.Product] = [
    .library(
        name: "DistributedActors",
        targets: ["DistributedActors"]
    ),
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
                "DistributedActors",
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
    .iOS(.v16),
    .macOS(.v13),
    .tvOS(.v16),
    .watchOS(.v9),
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
