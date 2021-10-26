//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ActorSystemTransportTests: ActorSystemXCTestCase {

    func test_system_shouldAssignIdentityAndReadyActor() throws {
        try runAsyncAndBlock {
            let first = self.setUpNode("first") { settings in
                settings.cluster.disable()
            }

            let stub = StubDistributedActor(transport: first)

            let identity = try self.logCapture.awaitLogContaining(testKit, text: "Assign identity")
            let idString = "\(identity.metadata!["actor/identity"]!)"
            let ready = try self.logCapture.awaitLogContaining(testKit, text: "Actor ready")
            "\(ready.metadata!["actor/identity"]!)".shouldEqual(idString)
        }
    }
}
