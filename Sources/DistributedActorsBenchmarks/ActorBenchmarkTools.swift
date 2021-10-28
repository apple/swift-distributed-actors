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
import Atomics
import SwiftBenchmarkTools

@usableFromInline
internal class BenchmarkLatchPersonality<Message: Codable>: _CellDelegate<Message> {
    let startTime: ManagedAtomic<UInt64> = .init(0)
    let receptacle = BlockingReceptacle<Message>()

    deinit {
//        startTime.destroy()
    }

    override func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        self.receptacle.offerOnce(message)
        self.startTime.store(SwiftBenchmarkTools.Timer().getTimeAsInt(), ordering: .relaxed)
    }

    override var address: ActorAddress {
        ActorAddress(local: .init(protocol: "test", systemName: "test", host: "127.0.0.1", port: 7337, nid: .random()), path: ._system, incarnation: .wellKnown)
    }

    var ref: _ActorRef<Message> {
        .init(.delegate(self as _CellDelegate))
    }

    func blockUntilMessageReceived() -> Message {
        self.receptacle.wait(atMost: .seconds(10))!
    }

    func timeSinceUnlocked() -> DistributedActors.TimeAmount? {
        let time = Int64(SwiftBenchmarkTools.Timer().getTimeAsInt()) - Int64(self.startTime.load(ordering: .relaxed))
        if time > 0 {
            return DistributedActors.TimeAmount.nanoseconds(Int(time))
        } else {
            return nil
        }
    }
}
