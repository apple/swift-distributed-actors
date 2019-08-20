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
import DistributedActorsConcurrencyHelpers
import SwiftBenchmarkTools
import Dispatch
import class Foundation.ProcessInfo

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

// MARK: Ping Pong Benchmark
//
// This benchmark spawns a number of actors (2, more than cores, less than cores, equal nr as cores),
// and makes them send ping pong messages between each other pairwise. This should show the latency
// and throughput of direct "ping pong" messaging between highly messaged actors.

fileprivate let cores = ProcessInfo.processInfo.activeProcessorCount

fileprivate let twoActors = 2
fileprivate let lessThanCoresActors = cores / 2
fileprivate let sameAsCoresActors = cores
fileprivate let moreThanCoresActors = cores * 2

public let ActorPingPongBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "ActorPingPongBenchmarks.bench_actors_ping_pong(twoActors)",
        runFunction: bench_actors_ping_pong(numActors: twoActors),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system.spawn("supervisor", (supervisorBehavior()))
            }
        },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorPingPongBenchmarks.bench_actors_ping_pong(lessThanCoresActors)",
        runFunction: bench_actors_ping_pong(numActors: lessThanCoresActors),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system.spawn("supervisor", (supervisorBehavior()))
            }
        },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorPingPongBenchmarks.bench_actors_ping_pong(sameAsCoresActors)",
        runFunction: bench_actors_ping_pong(numActors: sameAsCoresActors),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system.spawn("supervisor", (supervisorBehavior()))
            }
        },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorPingPongBenchmarks.bench_actors_ping_pong(moreThanCoresActors)",
        runFunction: bench_actors_ping_pong(numActors: moreThanCoresActors),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system.spawn("supervisor", (supervisorBehavior()))
            }
        },
        tearDownFunction: tearDown
    ),
]

private func setUp(and postSetUp: () -> Void = { () in () }) {
    _system = ActorSystem("ActorPingPongBenchmarks") { settings in
        settings.defaultLogLevel = .error
    }
    postSetUp()
}

private func tearDown() {
    system.shutdown()
    _system = nil
}

// === -----------------------------------------------------------------------------------------------------------------
fileprivate enum PingPongCommand {
    case startPingPong(
        messagesPerPair: Int,
        numActors: Int,
        // dispatcher: String,
        throughput: Int,
        shutdownTimeout: TimeAmount,
        replyTo: ActorRef<PingPongCommand>)

    case pingPongStarted(completedLatch: CountDownLatch, startNanoTime: UInt64, totalNumMessages: Int)

    case stop
}

// === -----------------------------------------------------------------------------------------------------------------

fileprivate let mutex = Mutex()

fileprivate var supervisor: ActorRef<PingPongCommand>! = nil

fileprivate func supervisorBehavior() -> Behavior<PingPongCommand> {
    return .receive { context, message in
        switch message {
        case let .startPingPong(numMessagesPerActorPair, numActors, throughput, _, replyTo):
            let numPairs = numActors / 2
            let totalNumMessages = numPairs * numMessagesPerActorPair / 2

            let latch = CountDownLatch(from: numActors)

            let actors = try startPingPongActorPairs(
                context: context,
                latch: latch,
                messagesPerPair: numMessagesPerActorPair,
                numPairs: numPairs
            )

            let startNanoTime = SwiftBenchmarkTools.Timer().getTimeAsInt()
            replyTo.tell(.pingPongStarted(completedLatch: latch, startNanoTime: startNanoTime, totalNumMessages: totalNumMessages))

            initiatePingPongForPairs(refs: actors, inFlight: throughput * 2)

            return .same

        case .stop:
            context.children.stopAll()

            return .same

        case .pingPongStarted:
            return .same
        }
    }
}


fileprivate func initiatePingPongForPairs(refs: [(ActorRef<EchoMessage>, ActorRef<EchoMessage>)], inFlight: Int) {
    for (pingRef, pongRef) in refs {
        let message = EchoMessage(replyTo: pongRef)
        for _ in 1...inFlight {
            pingRef.tell(message)
        }
    }
}


fileprivate func startPingPongActorPairs(
    context: ActorContext<PingPongCommand>,
    latch: CountDownLatch,
    messagesPerPair: Int,
    numPairs: Int) throws -> [(ActorRef<EchoMessage>, ActorRef<EchoMessage>)] {
    let pingPongBehavior = newPingPongBehavior(messagesPerPair: messagesPerPair, latch: latch)

    var actors: [(ActorRef<EchoMessage>, ActorRef<EchoMessage>)] = []
    let startSpawning = SwiftBenchmarkTools.Timer().getTimeAsInt()
    actors.reserveCapacity(numPairs)
    for i in 0..<numPairs {
        let ping = try context.spawn("ping-\(i)", (pingPongBehavior))
        let pong = try context.spawn("pong-\(i)", (pingPongBehavior))
        let actorPair = (ping, pong)
        actors.append(actorPair)
    }
    let doneSpawning = SwiftBenchmarkTools.Timer().getTimeAsInt()

    print("    Spawning \(numPairs * 2) actors too: \(Swift Distributed ActorsActor.TimeAmount.nanoseconds(Int(doneSpawning - startSpawning)).milliseconds) ms")

    return actors
}

fileprivate struct EchoMessage: CustomStringConvertible {
    var seqNr: Int
    let replyTo: ActorRef<EchoMessage>

    init(replyTo: ActorRef<EchoMessage>) {
        self.replyTo = replyTo
        self.seqNr = 0
    }
    init(replyTo: ActorRef<EchoMessage>, seqNr: Int) {
        self.replyTo = replyTo
        self.seqNr = seqNr
    }

    var description: String {
        return "EchoMessage(\(seqNr) replyTo: \(replyTo.address.name))"
    }
}

fileprivate func newPingPongBehavior(messagesPerPair: Int, latch: CountDownLatch) -> Behavior<EchoMessage> {
    return .setup { context in
        var left = messagesPerPair / 2

        return .receiveMessage { message in
            let pong = EchoMessage(replyTo: context.myself, seqNr: message.seqNr + 1)
            message.replyTo.tell(pong)

            if (left > 0) {
                left -= 1
                return .same
            } else {
                latch.countDown()
                context.log.info("Stop.")
                return .stop // note that this will likely lead to dead letters
            }
        }
    }
}

// === -----------------------------------------------------------------------------------------------------------------

fileprivate func bench_actors_ping_pong(numActors: Int) -> (Int) -> Void {
    return { _ in
        let numMessagesPerActorPair = 2_000_000
        // let totalMessages = numMessagesPerActorPair * numActors / 2

        // Terrible hack
        let latchGuardian = BenchmarkLatchGuardian<PingPongCommand>(parent: system._root, name: "benchmarkLatch", system: system)
        let benchmarkLatchRef: ActorRef<PingPongCommand> = ActorRef(.guardian(latchGuardian as Guardian))

        supervisor.tell(
            .startPingPong(
                messagesPerPair: numMessagesPerActorPair,
                numActors: numActors,
                // dispatcher: "", // not used
                throughput: 50,
                shutdownTimeout: .seconds(30),
                replyTo: benchmarkLatchRef)
        )

        let start = latchGuardian.blockUntilMessageReceived()
        guard case let .pingPongStarted(completedLatch, startNanoTime, totalNumMessages) = start else {
            fatalError("Boom")
        }

        completedLatch.wait()

        let time = SwiftBenchmarkTools.Timer().getTimeAsInt() - startNanoTime

        pprint("    \(totalNumMessages) messages by \(numActors) actors took: \(time.milliseconds) ms (total: \(totalNumMessages / time.milliseconds * 1000) msg/s)")
        system.shutdown()
    }
}

