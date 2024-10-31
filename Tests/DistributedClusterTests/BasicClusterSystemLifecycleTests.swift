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

import DistributedActorsTestKit
@testable import DistributedCluster
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct BasicClusterSystemLifecycleTests {
    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }

    func test_system_shouldAssignIdentityAndReadyActor() async throws {
        let first = await self.testCase.setUpNode("first")

        var stub: StubDistributedActor? = StubDistributedActor(actorSystem: first)
        _ = stub
        stub = nil

        let identity = try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "Assign identity")
        let idString = "\(identity.metadata!["actor/id"]!)"
        let ready = try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "Actor ready")
        "\(ready.metadata!["actor/id"]!)".shouldEqual(idString)
    }
}
