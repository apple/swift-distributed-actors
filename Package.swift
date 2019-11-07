// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let targets: [PackageDescription.Target] = [
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actors

    .target(
        name: "DistributedActors",
        dependencies: [
            "NIO",
            "NIOSSL",
            "NIOExtras",
            "NIOFoundationCompat",

            "SwiftProtobuf",

            "Logging", "Metrics",
            "Backtrace",

            "DistributedActorsConcurrencyHelpers",
            "CDistributedActorsMailbox",
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: GenActors

    .target(
        name: "GenActors",
        dependencies: [
            "DistributedActors",
            "SwiftSyntax",
            "Stencil",
            "Files",
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: TestKit

    /// This target is intended only for use in tests, though we have no way to mark this
    .target(
        name: "DistributedActorsTestKit",
        dependencies: ["DistributedActors", "DistributedActorsConcurrencyHelpers"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Documentation

    .testTarget(
        name: "DistributedActorsDocumentationTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
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

    .testTarget(
        name: "GenActorsTests",
        dependencies: [
            "GenActors",
            "DistributedActorsTestKit",
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Integration Tests - `it_` prefixed
    .target(
        name: "it_ProcessIsolated_escalatingWorkers",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_escalatingWorkers"
    ),
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
    .target(
        name: "it_ProcessIsolated_backoffRespawn",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_backoffRespawn"
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
    // MARK: Samples are defined in Samples/Package.swift
    // ==== ----------------------------------------------------------------------------------------------------------------

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Internals; NOT SUPPORTED IN ANY WAY

    .target(
        name: "CDistributedActorsMailbox",
        dependencies: []
    ),

    .target(
        name: "CDistributedActorsAtomics",
        dependencies: []
    ),

    .target(
        name: "DistributedActorsConcurrencyHelpers",
        dependencies: ["CDistributedActorsAtomics"]
    ),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.8.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.2.0"),

    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.7.0"),

    // ~~~ workaround for backtraces ~~~
    .package(url: "https://github.com/ianpartridge/swift-backtrace.git", .branch("master")),

    // ~~~ SSWG APIs ~~~
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "1.0.0"),

    // ~~~ only for GenActors ~~~
    // swift-syntax is Swift version dependent, and added  as such below
    .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.13.0"), // BSD license
    .package(url: "https://github.com/JohnSundell/Files", from: "4.0.0"), // MIT license
]

#if swift(>=5.1)
dependencies.append(contentsOf: [
    .package(url: "https://github.com/apple/swift-syntax.git", .exact("0.50100.0")),
])
#elseif swift(>=5.0)
dependencies.append(contentsOf: [
    .package(url: "https://github.com/apple/swift-syntax.git", .exact("0.50000.0")),
])
#else
fatalError("Currently only Swift 5.1 is supported. 5.0 could be supported, if you need Swift 5.0 support please reach out to to the team.")
#endif

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

        /* --- genActors --- */

        .executable(
            name: "GenActors",
            targets: ["GenActors"]
        ),

        /* ---  performance --- */
        .executable(
            name: "DistributedActorsBenchmarks",
            targets: ["DistributedActorsBenchmarks"]
        ),
    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
