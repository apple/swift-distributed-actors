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

import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

// TODO: Add more tests
class SWIMMembershipShellStateTests: XCTestCase {
    let system = ActorSystem("SupervisionTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
    }

    func test_updateState_shouldNotOverwriteEqualState() throws {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(.init())

        state.addMember(probe.ref, status: .suspect(incarnation: 1))
        state.incrementProtocolPeriod()

        let markResult = state.mark(probe.ref, as: .suspect(incarnation: 1))
        guard case .ignoredDueToOlderStatus(currentStatus: .suspect(incarnation: 1)) = markResult else {
            let expected = SWIMMembershipShell.State.MarkResult.ignoredDueToOlderStatus(currentStatus: .suspect(incarnation: 1))
            throw self.testKit.fail("Expected `\(expected), got \(markResult)`")
        }

        state.membershipInfo(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }
}
