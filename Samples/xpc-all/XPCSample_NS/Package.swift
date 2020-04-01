// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let targets: [PackageDescription.Target] = [
    .target(
        name: "HelloXPCProtocol",
        dependencies: [
        ]
    ),
    .target(
        name: "HelloXPC",
        dependencies: [
            "HelloXPCProtocol",
        ]
    ),

    .target(
        name: "HelloXPCService",
        dependencies: [
            "HelloXPCProtocol",
        ]
    ),
]

var dependencies: [Package.Dependency] = [
]

let package = Package(
    name: "HelloNSXPC",
    products: [
        .executable(
            name: "HelloXPC",
            targets: [
                "HelloXPC",
            ]
        ),
    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
