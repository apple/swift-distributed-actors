// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var targets: [PackageDescription.Target] = [
    .target(
        name: "SwiftyInstrumentsPackageDefinition",
        dependencies: []
    ),
]

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

// ==== ------------------------------------------------------------------------------------------------------------

targets.append(
    contentsOf: [
        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Actor Instruments Package Definition

        .target(
            name: "ActorInstrumentsPackageDefinition",
            dependencies: [
                "GenActorInstruments",
                "SwiftyInstrumentsPackageDefinition",
            ]
        ),

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: GenActorInstruments

        .target(
            name: "GenActorInstruments",
            dependencies: [
                "DistributedActors",
                "SwiftyInstrumentsPackageDefinition",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "XMLCoder", package: "XMLCoder"),
            ]
        ),
    ]
)

#endif

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(path: "../../"),

    // ~~~ for rendering the PackageDefinition XML ~~~
    .package(url: "https://github.com/MaxDesiatov/XMLCoder.git", from: "0.11.1"), // MIT
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "0.3.2")), // not API stable, Apache v2
]

let package = Package(
    name: "swift-distributed-actors-instruments",
    products: [
        .executable(
            name: "ActorInstrumentsPackageDefinition",
            targets: ["ActorInstrumentsPackageDefinition"]
        ),

        .library(
            name: "SwiftyInstrumentsPackageDefinition",
            targets: ["SwiftyInstrumentsPackageDefinition"]
        ),

    ],

    dependencies: dependencies,

    targets: targets
)
