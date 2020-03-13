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

import DistributedActors
import SwiftBenchmarkTools

assert({
    print("===========================================================================")
    print("=   !!  YOU ARE RUNNING DistributedActorsBenchmarks IN DEBUG MODE  !!     =")
    print("=     When running on the command line, use: `swift run -c release`       =")
    print("===========================================================================")
    return true
}())

var _system: ActorSystem?
var system: ActorSystem {
    return _system!
}

@inline(__always)
private func registerBenchmark(_ bench: BenchmarkInfo) {
    registeredBenchmarks.append(bench)
}

@inline(__always)
private func registerBenchmark(_ benches: [BenchmarkInfo]) {
    benches.forEach(registerBenchmark)
}

@inline(__always)
private func registerBenchmark(_ name: String, _ function: @escaping (Int) -> Void, _ tags: [BenchmarkCategory]) {
    registerBenchmark(BenchmarkInfo(name: name, runFunction: function, tags: tags))
}

registerBenchmark(ActorTreeTraversalBenchmarks)
registerBenchmark(SerializationCodableBenchmarks)
// registerBenchmark(SerializationProtobufBenchmarks) // TODO: unlock again
registerBenchmark(RingBenchmarks)
registerBenchmark(ActorPingPongBenchmarks)
registerBenchmark(ActorMessageFloodingBenchmarks)
registerBenchmark(ActorSpawnBenchmarks)

main()
