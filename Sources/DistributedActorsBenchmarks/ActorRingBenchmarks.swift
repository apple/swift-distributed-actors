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
import DistributedActorsConcurrencyHelpers
import SwiftBenchmarkTools

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

// MARK: Ring Benchmark

//
// Based on Joe Armstrong's task from the Programming Erlang book:
// > Write a ring benchmark.
// > Create N processes in a ring.
// > Send a message round the ring M times so that a total of N * M messages get sent.
// > Time how long this takes for different values of N and M.
//
//
// This benchmark measures how much time it takes to send messages around such "ring",
// it involves waking up multiple actors and as such also shows the efficiency of the scheduling.

public let RingBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "RingBenchmarks.bench_ring_m100_000_n10_000",
        runFunction: bench_ring_m100_000_n10_000,
        tags: [.actor],
        setUpFunction: { setUp { () in
            initLoop(m: 100_000, n: 10000)
        } },
        tearDownFunction: tearDown
    ),
]

private func setUp(and postSetUp: () -> Void = { () in () }) {
    _system = ActorSystem("RingBenchmarks") { _ in
//        settings.logLevel = .error
    }
    postSetUp()
}

private func tearDown() {
    system.shutdown().wait()
    _system = nil
}

// === -----------------------------------------------------------------------------------------------------------------

private let q = LinkedBlockingQueue<Int>()

private let spawnStart = Atomic<UInt64>(value: 0)
private let spawnStop = Atomic<UInt64>(value: 0)

private let ringStart = Atomic<UInt64>(value: 0)
private let ringStop = Atomic<UInt64>(value: 0)

// === -----------------------------------------------------------------------------------------------------------------

private struct Token: ActorMessage {
    let payload: Int

    init(_ payload: Int) {
        self.payload = payload
    }
}

private let mutex = _Mutex()

private func loopMember(id: Int, next: ActorRef<Token>, msg: Token) -> Behavior<Token> {
    return .receive { _, msg in
        switch msg.payload {
        case 1:
            ringStop.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
            q.enqueue(0) // done
            // pprint("DONE RING SEND. \(time(nil))")
            return .stop
        default:
            // context.log.info("Send \(Token(msg.payload - 1)) \(context.myself.path.name) >>> \(next.path.name)")
            next.tell(Token(msg.payload - 1))
            return .same
        }
    }
}

private var loopEntryPoint: ActorRef<Token>!

private func initLoop(m messages: Int, n actors: Int) {
    loopEntryPoint = try! system.spawn("a0", .setup { context in
        // TIME spawning
        // pprint("START SPAWN... \(SwiftBenchmarkTools.Timer().getTimeAsInt())")
        spawnStart.store(SwiftBenchmarkTools.Timer().getTimeAsInt())

        var loopRef = context.myself
        for i in (1 ... actors).reversed() {
            loopRef = try context.spawn("a\(actors - i)", loopMember(id: i, next: loopRef, msg: Token(messages)))
            // context.log.info("SPAWNed \(loopRef.path.name)...")
        }
        // pprint("DONE SPAWN... \(SwiftBenchmarkTools.Timer().getTime())")
        spawnStop.store(SwiftBenchmarkTools.Timer().getTimeAsInt())

        return .receiveMessage { m in
            // pprint("START RING SEND... \(SwiftBenchmarkTools.Timer().getTime())")

            // context.log.info("Send \(m) \(context.myself.path.name) >>> \(loopRef.path.name)")
            loopRef.tell(m)

            // END TIME spawning
            return loopMember(id: 1, next: loopRef, msg: m)
        }
    })
}

// === -----------------------------------------------------------------------------------------------------------------

func bench_ring_m100_000_n10_000(n: Int) {
    ringStart.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
    loopEntryPoint.tell(Token(100_000))

    _ = q.poll(.seconds(20))
    pprint("    Spawning           : \((spawnStop.load() - spawnStart.load()).milliseconds) ms")
    pprint("    Sending around Ring: \((ringStop.load() - ringStart.load()).milliseconds) ms")
}
