//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift Distributed Actors project authors
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

final class BasicClusterSystemLifecycleTests: SingleClusterSystemXCTestCase, @unchecked Sendable {
    func test_system_shouldAssignIdentityAndReadyActor() async throws {
        try runAsyncAndBlock {
            let first = await setUpNode("first")

            var stub: StubDistributedActor? = StubDistributedActor(actorSystem: first)
            _ = stub
            stub = nil

            let identity = try self.logCapture.awaitLogContaining(testKit, text: "Assign identity")
            let idString = "\(identity.metadata!["actor/id"]!)"
            let ready = try self.logCapture.awaitLogContaining(testKit, text: "Actor ready")
            "\(ready.metadata!["actor/id"]!)".shouldEqual(idString)
        }
    }
}
