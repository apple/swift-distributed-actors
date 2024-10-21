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

import Dispatch
import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import NIO
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct StubDistributedActorTests {
    
    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }
    
    @Test
    func test_StubDistributedActor_shouldAlwaysResolveAsRemote() {
        let anyID = self.testCase.system.assignID(StubDistributedActor.self)
        
        let resolved = self.testCase.system._resolveStub(id: anyID)
        __isRemoteActor(resolved).shouldBeTrue()
    }
}
