// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let targets: [PackageDescription.Target] = [
    // libxpc
    .target(
        name: "XPCServiceProvider",
        dependencies: []
    ),
    .target(
        name: "XPCLibCaller",
        dependencies: [
        ]
    ),
]

var dependencies: [Package.Dependency] = [
]

let package = Package(
    name: "XPCSample_C",
    products: [
        .executable(
            name: "XPCLibCaller",
            targets: [
                "XPCLibCaller",
            ]
        ),
        .executable(
            name: "XPCServiceProvider",
            targets: [
                "XPCServiceProvider",
            ]
        ),

    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
