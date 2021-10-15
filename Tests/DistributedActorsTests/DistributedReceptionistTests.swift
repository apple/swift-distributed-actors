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

import _Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

distributed actor Forwarder {
    let probe: ActorTestProbe<String>
    let name: String
    init(probe: ActorTestProbe<String>, name: String, transport: ActorTransport) {
        defer { transport.actorReady(self) }
        self.probe = probe
        self.name = name
    }

    distributed func forward(message: String) {
        probe.tell("\(self.id.underlying) \(name) forwarded: \(message)")
    }
}

extension DistributedReception.Key {
    static var forwarders: DistributedReception.Key<Forwarder> {
        "forwarder/*"
    }

}

final class DistributedReceptionistTests: ActorSystemXCTestCase {
    let receptionistBehavior = OperationLogClusterReceptionist(settings: .default).behavior

    func test_receptionist_shouldRespondWithRegisteredRefsForKey() throws {
        try runAsyncAndBlock {
            let receptionist = system.receptionist
            let probe: ActorTestProbe<String> = self.testKit.spawnTestProbe()

            let forwarderA = Forwarder(probe: probe, name: "A", transport: system)
            let forwarderB = Forwarder(probe: probe, name: "B", transport: system)

            await receptionist.register(forwarderA, with: .forwarders)
            await receptionist.register(forwarderB, with: .forwarders)
            let listing = await receptionist.lookup(.forwarders)

            listing.count.shouldEqual(2)
            for forwarder in listing {
                try await forwarder.forward(message: "test")
            }

            try probe.expectMessagesInAnyOrder(["forwardedA:test", "forwardedB:test"])
        }
    }

}