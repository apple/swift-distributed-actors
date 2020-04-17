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

@usableFromInline
internal class BenchmarkLatchPersonality<Message: Codable>: CellDelegate<Message> {
    let startTime = Atomic<UInt64>(value: 0)
    let receptacle = BlockingReceptacle<Message>()

    override func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        self.receptacle.offerOnce(message)
        self.startTime.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
    }

    override var address: ActorAddress {
        ActorAddress(path: ._system, incarnation: .wellKnown)
    }

    var ref: ActorRef<Message> {
        .init(.delegate(self as CellDelegate))
    }

    func blockUntilMessageReceived() -> Message {
        self.receptacle.wait(atMost: .seconds(10))!
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
