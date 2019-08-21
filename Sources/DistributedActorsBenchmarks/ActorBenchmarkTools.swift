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

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import SwiftBenchmarkTools

/// `ActorRef` which acts like a "latch" which can await the receipt of exactly one message;
@usableFromInline
internal class BenchmarkLatchGuardian<Message>: Guardian { // This is an ugly hack to inject a personality into an actor ref
    let startTime = Atomic<UInt64>(value: 0)
    let receptacle = BlockingReceptacle<Message>()

    override init(parent: ReceivesSystemMessages, name: String, system: ActorSystem) {
        super.init(parent: parent, name: name, system: system)
    }

    override func trySendUserMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        self.receptacle.offerOnce(message as! Message)
        self.startTime.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
    }

    override func sendSystemMessage(_ message: SystemMessage, file: String = #file, line: UInt = #line) {
        // ignore
    }

    override var address: ActorAddress {
        var fakePath: ActorPath = ._root
        try! fakePath.append(segment: .init("benchmarkLatch"))
        return ActorAddress(path: fakePath, incarnation: .perpetual)
    }

    func blockUntilMessageReceived() -> Message {
        return self.receptacle.wait(atMost: .seconds(10))!
    }

    func timeSinceUnlocked() -> DistributedActors.TimeAmount? {
        let time = Int64(SwiftBenchmarkTools.Timer().getTimeAsInt()) - Int64(self.startTime.load())
        if time > 0 {
            return DistributedActors.TimeAmount.nanoseconds(Int(time))
        } else {
            return nil
        }
    }
}
