//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsTestKit
import Files
import Foundation
import GenActors
import XCTest

final class GenCodableTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.serialization.registerCodable(for: JackOfAllTrades.Message.self, underId: 10001)
            settings.serialization.registerCodable(for: GeneratedActor.Messages.Parking.self, underId: 10002)
            settings.serialization.registerCodable(for: GeneratedActor.Messages.Ticketing.self, underId: 10003)
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_message_roundtrip() throws {
        let m = JackOfAllTrades.Message.parking(.park)

        let xdict = try XPCSerialization.serializeActorMessage(self.system, message: m)
        let b = try XPCSerialization.deserializeActorMessage(self.system, xdict: xdict)
    }
}
