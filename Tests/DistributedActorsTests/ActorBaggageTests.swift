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
        let first: ActorRef<String> = try self.system.spawn("first", .receive { message, context in
            p.tell("message:\(message)")
            p.tell("baggage: \(context.baggage)")
            return .stop
        })

        let sender: ActorRef<String> = try self.system.spawn("caplin-the-sender", .setup {
            first.tell("Hello!")
            return .stop
        })

        try p.expectMessage("message:Hello!")
        try p.expectMessage("BAG")
    }
}
