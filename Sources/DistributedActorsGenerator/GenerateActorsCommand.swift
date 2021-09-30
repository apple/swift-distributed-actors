//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import DistributedActors
import Foundation
import Logging

@main
public struct GenerateActorsCommand: ParsableCommand {
    @Option(help: "Print verbose information while analyzing and generating sources")
    var logLevel: String = "info"

    var logLevelValue: Logger.Level {
        switch self.logLevel {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return .info
        }
    }

    @Flag(name: .shortAndLong, help: "Print verbose all generated sources")
    var printGenerated: Bool = false

    @Option(help: "Source diretory to scan")
    var sourceDirectory: String = ""

    @Option(help: "Target diretory to generate in")
    var targetDirectory: String = ""

    @Option(help: "Number of buckets to generate")
    var buckets: Int = 1

    @Argument()
    var targets: [String] = []

    public init() {}
}

extension GenerateActorsCommand {
    public func run() throws {
        guard !self.sourceDirectory.isEmpty else {
            fatalError("source directory is required")
        }
        guard !self.targetDirectory.isEmpty else {
            fatalError("target directory is required")
        }

        let sourceDirectory = try Directory(path: self.sourceDirectory)

        try FileManager.default.createDirectory(atPath: self.targetDirectory, withIntermediateDirectories: true)
        let targetDirectory = try Directory(path: self.targetDirectory)

        let generator = GenerateActors(logLevel: self.logLevelValue, printGenerated: self.printGenerated)
        _ = try generator.run(
            sourceDirectory: sourceDirectory,
            targetDirectory: targetDirectory,
            buckets: self.buckets,
            targets: self.targets // ,
        )
    }
}
