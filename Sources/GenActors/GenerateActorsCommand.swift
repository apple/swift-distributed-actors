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

struct GenerateActorsCommand: ParsableCommand {
    @Flag(help: "Remove *all* +Gen... source files before generating a new batch of files")
    var clean: Bool

    @Flag(name: .shortAndLong, help: "Print verbose information while analyzing and generating sources")
    var verbose: Bool

    @Flag(name: .shortAndLong, help: "Print verbose all generated sources")
    var printGenerated: Bool

    @Argument()
    var scanTargets: [String]
}

extension GenerateActorsCommand {
    public func run() throws {
        let gen = GenerateActors(command: self)
        _ = try gen.run()
    }
}
