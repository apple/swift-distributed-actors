//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackagePlugin

let generatorPath = try targetBuildContext.tool(named: "DistributedActorsGenerator").path

let inputFiles = targetBuildContext.inputFiles.map { $0.path }.filter { $0.extension?.lowercased() == "swift" }

let buckets = 5 // # of buckets for consistent hashing
let outputFiles = !inputFiles.isEmpty ? (0 ..< buckets).map { targetBuildContext.pluginWorkDirectory.appending("GeneratedDistributedActors_\($0).swift") } : []

commandConstructor.addBuildCommand(
    displayName: "Generating distributed actors",
    executable: generatorPath,
    arguments: [
        "--source-directory", targetBuildContext.targetDirectory.string,
        "--target-directory", targetBuildContext.pluginWorkDirectory.string,
        "--buckets", "\(buckets)",
    ],
    inputFiles: inputFiles,
    outputFiles: outputFiles
)
