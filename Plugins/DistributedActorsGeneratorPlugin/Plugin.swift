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

@main struct MyPlugin: BuildToolPlugin {
    func createBuildCommands(context: TargetBuildContext) throws -> [Command] {
        let generatorPath = try context.tool(named: "DistributedActorsGenerator").path

        let inputFiles = context.inputFiles.map { $0.path }.filter { $0.extension?.lowercased() == "swift" }

        let buckets = 5 // # of buckets for consistent hashing
        let outputFiles = !inputFiles.isEmpty ? (0 ..< buckets).map {
            context.pluginWorkDirectory.appending("GeneratedDistributedActors_\($0).swift")
        } : []

        let command = Command.buildCommand(
            displayName: "Generating distributed actors for target '\(context.targetName)'",
            executable: generatorPath,
            arguments: [
                "--source-directory", context.targetDirectory.string,
                "--target-directory", context.pluginWorkDirectory.string,
                "--buckets", "\(buckets)",
            ],
            inputFiles: inputFiles,
            outputFiles: outputFiles
        )

        return [command]
    }
}
