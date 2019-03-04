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

import Swift Distributed ActorsActor
import SwiftBenchmarkTools

public let ActorTreeTraversalBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "ActorResolve.bench_resolveShallowRef",
        runFunction: bench_visitSingleRef,
        tags: [],
        setUpFunction: { setUp(and: setUp_visitSingleRef) },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorResolve.bench_visit_depth_1000_total_1000",
        runFunction: bench_visit,
        tags: [],
        setUpFunction: { setUp(and: setUp_visit_depth_1000_total_1000) },
        tearDownFunction: tearDown
    )
]

private func setUp(and postSetUp: () -> Void) {
    _system = ActorSystem("ActorResolveBenchmarks")
    postSetUp()
}
private func tearDown() {
    system.terminate()
    _system = nil
}

// -------

func setUp_visitSingleRef() {
    let _: ActorRef<Never> = try! system.spawn(.ignore, name: "top")
}
func bench_visitSingleRef(n: Int) {
//    system._traverse { ref in () }
}

// -------

func setUp_visit_depth_10_total_10() {
    func spawnDeeper(stillMore n: Int) -> Behavior<Never> {
        if n == 0 {
            return .setup { context in
                return .same
            }
        } else {
            return Behavior<Never>.setup { context in
                try context.spawn(spawnDeeper(stillMore: n - 1), name: "a\(n)")
                return .same
            }
        }
    }
    _ = try! system.spawn(spawnDeeper(stillMore: 10), name: "top")
}
func bench_visit(n: Int) {
//    system._traverse { ref in () }
}

func setUp_visit_depth_1000_total_1000() {
    func spawnDeeper(stillMore n: Int) -> Behavior<Never> {
        if n == 0 {
            return .setup { context in
                return .same
            }
        } else {
            return Behavior<Never>.setup { context in
                try context.spawn(spawnDeeper(stillMore: n - 1), name: "a\(n)")
                return .same
            }
        }
    }
    _ = try! system.spawn(spawnDeeper(stillMore: 1000), name: "top")
}
