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

import Dispatch
import DistributedActors
import DistributedActorsConcurrencyHelpers
import class Foundation.ProcessInfo
import SwiftBenchmarkTools

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

// MARK: Remote Ping Pong Benchmark

public let ActorRemotePingPongBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "ActorRemotePingPongBenchmarks.bench_actors_remote_ping_pong(2)",
        runFunction: bench_actors_remote_ping_pong(numActors: 2),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system._spawn("supervisor", supervisorBehavior())
            }
        },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorRemotePingPongBenchmarks.bench_actors_remote_ping_pong(8)",
        runFunction: bench_actors_remote_ping_pong(numActors: 8),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system._spawn("supervisor", supervisorBehavior())
            }
        },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorRemotePingPongBenchmarks.bench_actors_remote_ping_pong(16)",
        runFunction: bench_actors_remote_ping_pong(numActors: 16),
        tags: [.actor],
        setUpFunction: {
            setUp { () in
                supervisor = try! system._spawn("supervisor", supervisorBehavior())
            }
        },
        tearDownFunction: tearDown
    ),
]

var _pongNode: ClusterSystem?

private func setUp(and postSetUp: () -> Void = { () in () }) {
    _system = ClusterSystem("PingNode") { settings in
        settings.logging.logLevel = .error
        settings.node.port = 7111
    }
    _pongNode = ClusterSystem("PongNode") { settings in
        settings.logging.logLevel = .error
        settings.node.port = 7222
    }

    postSetUp()
}

private func tearDown() {
    try! system.shutdown().wait()
    _system = nil
    try! _pongNode?.shutdown().wait()
    _pongNode = nil
}

// === -----------------------------------------------------------------------------------------------------------------
private enum PingPongCommand: _NotActuallyCodableMessage {
    case startPingPong(
        messagesPerPair: Int,
        numActors: Int,
        throughput: Int,
        shutdownTimeout: Duration,
        replyTo: _ActorRef<PingPongCommand>
    )

    case pingPongStarted(completedLatch: CountDownLatch, startNanoTime: UInt64, totalNumMessages: Int)

    case stop
}

// === -----------------------------------------------------------------------------------------------------------------

private let mutex = _Mutex()

private var supervisor: _ActorRef<PingPongCommand>!

private func supervisorBehavior() -> _Behavior<PingPongCommand> {
    .receive { context, message in
        switch message {
        case .startPingPong(let numMessagesPerActorPair, let numActors, let throughput, _, let replyTo):
            let numPairs = numActors / 2
            let totalNumMessages = numPairs * numMessagesPerActorPair

            let latch = CountDownLatch(from: numActors)

            let actors = try startRemotePingPongActorPairs(
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

private func initiatePingPongForPairs(refs: [(_ActorRef<EchoMessage>, _ActorRef<EchoMessage>)], inFlight: Int) {
    for (pingRef, pongRef) in refs {
        let message = EchoMessage(replyTo: pongRef)
        for _ in 1 ... inFlight {
            pingRef.tell(message)
        }
    }
}

private func startRemotePingPongActorPairs(
    context: _ActorContext<PingPongCommand>,
    latch: CountDownLatch,
    messagesPerPair: Int,
    numPairs: Int
) throws -> [(_ActorRef<EchoMessage>, _ActorRef<EchoMessage>)] {
    let pingPongBehavior = newPingPongBehavior(messagesPerPair: messagesPerPair, latch: latch)

    var actors: [(_ActorRef<EchoMessage>, _ActorRef<EchoMessage>)] = []
    let startSpawning = SwiftBenchmarkTools.Timer().getTimeAsInt()
    actors.reserveCapacity(numPairs)

    for i in 0 ..< numPairs {
        let ping = try system._spawn("ping-\(i)", pingPongBehavior)
        let pong = try _pongNode!._spawn("pong-\(i)", pingPongBehavior)
        let actorPair = (ping, pong)
        actors.append(actorPair)
    }
    let doneSpawning = SwiftBenchmarkTools.Timer().getTimeAsInt()

    print("    Spawning \(numPairs * 2) actors took: \(Duration.nanoseconds(Int64(doneSpawning - startSpawning)).milliseconds) ms")

    return actors
}

private struct EchoMessage: Codable, CustomStringConvertible {
    var seqNr: Int
    let replyTo: _ActorRef<EchoMessage>

    init(replyTo: _ActorRef<EchoMessage>) {
        self.replyTo = replyTo
        self.seqNr = 0
    }

    init(replyTo: _ActorRef<EchoMessage>, seqNr: Int) {
        self.replyTo = replyTo
        self.seqNr = seqNr
    }

    var description: String {
        "EchoMessage(\(seqNr) replyTo: \(replyTo.id.name))"
    }
}

private func newPingPongBehavior(messagesPerPair: Int, latch: CountDownLatch) -> _Behavior<EchoMessage> {
    .setup { context in
        var left = messagesPerPair / 2

        return .receiveMessage { message in
            let pong = EchoMessage(replyTo: context.myself, seqNr: message.seqNr + 1)
            message.replyTo.tell(pong)

            if left > 0 {
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

private func bench_actors_remote_ping_pong(numActors: Int) -> (Int) -> Void {
    { _ in
        let numMessagesPerActorPair = 2_000_000

        let latchGuardian = BenchmarkLatchPersonality<PingPongCommand>()
        let benchmarkLatchRef = latchGuardian.ref

        supervisor.tell(
            .startPingPong(
                messagesPerPair: numMessagesPerActorPair,
                numActors: numActors,
                throughput: 200,
                shutdownTimeout: .seconds(30),
                replyTo: benchmarkLatchRef
            )
        )

        let start = latchGuardian.blockUntilMessageReceived()
        guard case .pingPongStarted(let completedLatch, let startNanoTime, let totalNumMessages) = start else {
            fatalError("Boom")
        }

        completedLatch.wait()

        let time = SwiftBenchmarkTools.Timer().getTimeAsInt() - startNanoTime

        print("    \(totalNumMessages) messages by \(numActors) actors took: \(time.milliseconds) ms (total: \(totalNumMessages / time.milliseconds * 1000) msg/s)")
        try! system.shutdown().wait()
    }
}
