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

/// `ActorRef` which acts like a "latch" which can await the receipt of exactly one message;
@usableFromInline
internal class BenchmarkLatchRef<Message>: ActorRef<Message> {
    let startTime = Atomic<UInt64>(value: 0)
    let receptacle = BlockingReceptacle<Message>()

    override func tell(_ message: Message) {
        self.receptacle.offerOnce(message)
        self.startTime.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
    }

    override func sendSystemMessage(_ message: SystemMessage) {
        // ignore
    }

    override var path: UniqueActorPath {
        var fakePath: ActorPath = ._rootPath
        try! fakePath.append(segment: .init("benchmarkLatch"))
        return UniqueActorPath(path: fakePath, uid: .opaque)
    }

    func blockUntilMessageReceived() -> Message {
        return receptacle.wait(atMost: .seconds(10))!
    }

    func timeSinceUnlocked() -> Swift Distributed ActorsActor.TimeAmount? {
        let time = Int64(SwiftBenchmarkTools.Timer().getTimeAsInt()) - Int64(self.startTime.load())
        if time > 0 {
            return Swift Distributed ActorsActor.TimeAmount.nanoseconds(Int(time))
        } else {
            return nil
        }
    }
}
