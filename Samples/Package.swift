// swift-tools-version:5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var globalSwiftSettings: [SwiftSetting]

var globalConcurrencyFlags: [String] = [
  "-Xfrontend", "-enable-experimental-distributed",
]

globalSwiftSettings = [
  SwiftSetting.unsafeFlags(globalConcurrencyFlags),
]

var targets: [PackageDescription.Target] = [
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .executableTarget(
        name: "SampleDiningPhilosophers",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleDiningPhilosophers",
        exclude: [
          "dining-philosopher-fsm.graffle",
          "dining-philosopher-fsm.svg",
        ],
        plugins: [
          .plugin(name: "DistributedActorsGeneratorPlugin", package: "swift-distributed-actors"),
        ]
    ),
    .executableTarget(
        name: "SampleCluster",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleCluster",
        plugins: [
          .plugin(name: "DistributedActorsGeneratorPlugin", package: "swift-distributed-actors"),
        ]
    ),
    .executableTarget(
        name: "SampleReceptionist",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleReceptionist",
        plugins: [
          .plugin(name: "DistributedActorsGeneratorPlugin", package: "swift-distributed-actors"),
        ]
    ),
    .executableTarget(
        name: "SampleMetrics",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
            .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
        ],
        path: "Sources/SampleMetrics",
        plugins: [
          .plugin(name: "DistributedActorsGeneratorPlugin", package: "swift-distributed-actors"),
        ]
    ),
    .executableTarget(
        name: "SampleGenActors",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleGenActors",
        plugins: [
            .plugin(name: "DistributedActorsGeneratorPlugin", package: "swift-distributed-actors"),
        ]
    ),

    /* --- tests --- */

    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
            .product(name: "DistributedActorsTestKit", package: "swift-distributed-actors"),
        ],
        path: "Tests/NoopTests"
    ),
]

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(name: "swift-distributed-actors", path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~

    // for metrics examples:
    .package(url: "https://github.com/MrLotU/SwiftPrometheus", from: "1.0.0-alpha.11"), // Apache v2 license
]

let package = Package(
    name: "swift-distributed-actors-samples",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v8),
        // ...
    ],
    products: [
        /* ---  samples --- */

        .executable(
            name: "SampleDiningPhilosophers",
            targets: ["SampleDiningPhilosophers"]
        ),
        .executable(
            name: "SampleCluster",
            targets: ["SampleCluster"]
        ),
        .executable(
            name: "SampleMetrics",
            targets: ["SampleMetrics"]
        ),
        .executable(
            name: "SampleGenActors",
            targets: ["SampleGenActors"]
        ),
    ],

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
