// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let targets: [PackageDescription.Target] = [
    .target(
        name: "DistributedActors",
        dependencies: [
            "NIO",
            "NIOExtras",
            "NIOFoundationCompat",
            "NIOSSL",
            "Logging",
            "DistributedActorsConcurrencyHelpers",
            "CDistributedActorsMailbox",
            "CDistributedActorsRunQueue",
            "SwiftProtobuf",
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: TestKit

    /// This target is intended only for use in tests, though we have no way to mark this
    .target(
        name: "DistributedActorsTestKit",
        dependencies: ["DistributedActors", "DistributedActorsConcurrencyHelpers"]
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Tests

    .testTarget(
        name: "DistributedActorsTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
    ),
    .testTarget(
        name: "DistributedActorsTestKitTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
    ),

    .testTarget(
        name: "CDistributedActorsMailboxTests",
        dependencies: ["CDistributedActorsMailbox", "DistributedActorsTestKit"]
    ),

    .testTarget(
        name: "DistributedActorsConcurrencyHelpersTests",
        dependencies: ["DistributedActorsConcurrencyHelpers"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Integration Tests - `it_` prefixed
    .target(
        name: "it_ProcessIsolated_respawnsServants",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_respawnsServants"
    ),
    .target(
        name: "it_ProcessIsolated_noLeaking",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_noLeaking"
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Performance / Benchmarks

    .target(
        name: "DistributedActorsBenchmarks",
        dependencies: [
            "DistributedActors",
            "SwiftBenchmarkTools",
        ]
    ),
    .target(
        name: "SwiftBenchmarkTools",
        dependencies: ["DistributedActors"]
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .target(
        name: "DistributedActorsSampleDiningPhilosophers",
        dependencies: ["DistributedActors"]
    ),
    .target(
        name: "DistributedActorsSampleLetItCrash",
        dependencies: ["DistributedActors"]
    ),
    .target(
        name: "DistributedActorsSampleCluster",
        dependencies: ["DistributedActors"]
    ),
    /* --- documentation snippets --- */
    .testTarget(
        name: "DistributedActorsDocumentationTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Internals; NOT SUPPORTED IN ANY WAY

    .target(
        name: "CDistributedActorsMailbox",
        dependencies: []
    ),

    .target(
        name: "CDistributedActorsRunQueue",
        dependencies: []
    ),

    .target(name: "CDistributedActorsAtomics",
        dependencies: []),

    .target(
        name: "DistributedActorsConcurrencyHelpers",
        dependencies: ["CDistributedActorsAtomics"]
    ),
]

let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.7.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.2.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
]

let package = Package(
    name: "swift-distributed-actors",
    products: [
        .library(
            name: "DistributedActors",
            targets: ["DistributedActors"]
        ),
        .library(
            name: "DistributedActorsTestKit",
            targets: ["DistributedActorsTestKit"]
        ),

        /* ---  performance --- */
        .executable(
            name: "DistributedActorsBenchmarks",
            targets: ["DistributedActorsBenchmarks"]
        ),

        /* ---  samples --- */

        .executable(
            name: "DistributedActorsSampleDiningPhilosophers",
            targets: ["DistributedActorsSampleDiningPhilosophers"]
        ),
        .executable(
            name: "DistributedActorsSampleLetItCrash",
            targets: ["DistributedActorsSampleLetItCrash"]
        ),
        .executable(
            name: "DistributedActorsSampleCluster",
            targets: ["DistributedActorsSampleCluster"]
        ),
    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
