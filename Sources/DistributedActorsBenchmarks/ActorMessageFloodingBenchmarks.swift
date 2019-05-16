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
import DistributedActorsConcurrencyHelpers

public let ActorMessageFloodingBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "ActorMessageFloodingBenchmarks.10_000_000_messages",
        runFunction: { _ in try! bench_messageFlooding(10_000_000) },
        tags: [],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "ActorMessageFloodingBenchmarks.bench_messageFlooding_send(10_000_000)",
        runFunction: { _ in try! bench_messageFlooding_send(10_000_000) },
        tags: [],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    )
]

private func setUp() {
    _system = ActorSystem("ActorMessageFloodingBenchmarks")
}
private func tearDown() {
    system.shutdown()
    _system = nil
}

func flooding_behavior(latch: CountDownLatch, messageCount: Int) -> Behavior<Int> {
    return .setup { _ in
        var count = messageCount
        return .receiveMessage { _ in
            count -= 1
            if count == 0 {
                latch.countDown()
            }
            return .same
        }
    }
}

func bench_messageFlooding(_ messageCount: Int) throws -> Void {
    let timer = SwiftBenchmarkTools.Timer()
    let latch = CountDownLatch(from: 1)

    let ref = try system.spawnAnonymous(flooding_behavior(latch: latch, messageCount: messageCount))

    let start = timer.getTime()

    for i in 1 ... messageCount {
        ref.tell(i)
    }

    latch.wait()

    let stop = timer.getTime()

    let time = timer.diffTimeInNanoSeconds(from: start, to: stop)

    let seconds = (Double(time) / 1_000_000_000)
    let perSecond = Int(Double(messageCount) / seconds)

    print("Processed \(messageCount) message in \(String(format: "%.3f", seconds)) seconds \(perSecond) msgs/s")
}

func bench_messageFlooding_send(_ messageCount: Int) throws -> Void {
    let timer = SwiftBenchmarkTools.Timer()
    let latch = CountDownLatch(from: 1)

    let ref = try system.spawnAnonymous(flooding_behavior(latch: latch, messageCount: messageCount))

    let startSending = timer.getTime()

    for i in 1 ... messageCount {
        ref.tell(i)
    }
    let stopSending = timer.getTime()

    latch.wait()

    let sendingTime = timer.diffTimeInNanoSeconds(from: startSending, to: stopSending)
    let sendingSeconds = (Double(sendingTime) / 1000_000_000)
    let sendingPerSecond = Int((Double(messageCount) / sendingSeconds))

    print("Sending \(messageCount) messages took:    \(String(format: "%.3f", sendingSeconds)) seconds \(sendingPerSecond) msgs/s")
}
