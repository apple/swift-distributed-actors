//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import struct DistributedActors.TimeAmount
import DistributedActorsTestKit
import Foundation
import XCTest

final class ActorBaggageTests: ActorSystemTestBase {
    func test_baggage_carrySender() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let first: ActorRef<String> = try self.system.spawn("first", .receive { context, _ in
            p.tell("baggage:actor/sender:\(context.baggage.actorSender!)")
            return .stop
        })

        let sender: ActorRef<String> = try self.system.spawn("caplin-the-sender", .setup { _ in
            first.tell("Hello!")
            return .stop
        })

        let baggageString: String = try p.expectMessage()
        baggageString.shouldStartWith(prefix: "baggage:actor/sender:/user/caplin-the-sender")
    }
}
