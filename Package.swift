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

    .target(
        name: "DistributedActorsSampleProcessIsolated",
        dependencies: [
            "DistributedActors",
        ]
    ),

    /// This target is intended only for use in tests, though we have no way to mark this
    .target(
        name: "DistributedActorsTestKit",
        dependencies: ["DistributedActors", "DistributedActorsConcurrencyHelpers"]
    ),

    .target(
        name: "CDistributedActorsMailbox",
        dependencies: []
    ),

    .target(
        name: "CDistributedActorsRunQueue",
        dependencies: []
    ),

    // NOT SUPPORTED transient library until Swift receives Atomics
    .target(name: "CDistributedActorsAtomics",
            dependencies: []),

    // NOT SUPPORTED transient library until Swift receives Atomics
    .target(
        name: "DistributedActorsConcurrencyHelpers",
        dependencies: ["CDistributedActorsAtomics"]
    ),

    /* test targets */

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

    /* --- performance --- */
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

    /* --- samples --- */
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
]

let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.7.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.2.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
]

let package = Package(
    name: "DistributedActors",
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
