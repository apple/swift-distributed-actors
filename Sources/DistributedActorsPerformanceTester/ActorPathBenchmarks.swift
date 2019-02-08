//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import Swift Distributed ActorsActor
import SwiftBenchmarkTools

public let ActorPathBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "ActorPathBenchmarks.run_createShortPath",
        runFunction: run_createShortPath,
        tags: [])
]

func run_createShortPath(n: Int) {
    let root = ActorPath._rootPath
    let user = try! root / ActorPathSegment("user")
    let master = try! user / ActorPathSegment("master")
    let worker = try! master / ActorPathSegment("worker")
    let _ = worker
}
