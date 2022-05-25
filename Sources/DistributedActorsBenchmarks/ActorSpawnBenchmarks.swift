//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsConcurrencyHelpers
import SwiftBenchmarkTools

public let ActorSpawnBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "ActorSpawnBenchmarks.bench_SpawnTopLevel",
        runFunction: { _ in try! bench_SpawnTopLevel(50000) },
        tags: [],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorSpawnBenchmarks.bench_SpawnChildren",
        runFunction: { _ in try! bench_SpawnChildren(50000) },
        tags: [],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
]

private func setUp() {
    _system = ClusterSystem("ActorSpawnBenchmarks")
}

private func tearDown() {
    _system = nil
}

func bench_SpawnTopLevel(_ actorCount: Int) throws {
    let timer = SwiftBenchmarkTools.Timer()

    let start = timer.getTime()

    for i in 1 ... actorCount {
        let _: _ActorRef<Never> = try system._spawn("test-\(i)", .ignore)
    }

    let stop = timer.getTime()

    let time = timer.diffTimeInNanoSeconds(from: start, to: stop)

    let seconds = (Double(time) / 1_000_000_000)
    let perSecond = Int(Double(actorCount) / seconds)

    print("Spawned \(actorCount) top-level actors in \(String(format: "%.3f", seconds)) seconds. (\(perSecond) actors/s)")

    let shutdownStart = timer.getTime()
    try! system.shutdown().wait()
    let shutdownStop = timer.getTime()
    let shutdownTime = timer.diffTimeInNanoSeconds(from: shutdownStart, to: shutdownStop)
    let shutdownSeconds = (Double(shutdownTime) / 1_000_000_000)
    let stopsPerSecond = Int(Double(actorCount) / shutdownSeconds)

    print("Stopped \(actorCount) top-level actors in \(String(format: "%.3f", shutdownSeconds)) seconds. (\(stopsPerSecond) actors/s)")
}
