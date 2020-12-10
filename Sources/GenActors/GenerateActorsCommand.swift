//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
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
import Logging

struct GenerateActorsCommand: ParsableCommand {
    @Flag(help: "Remove *all* +Gen... source files before generating a new batch of files")
    var clean = false

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
    var printGenerated = false

    @Argument()
    var scanTargets = [String]()
}

extension GenerateActorsCommand {
    mutating public func run() throws {
        let gen = GenerateActors(command: self)
        _ = try gen.run()
    }
}
