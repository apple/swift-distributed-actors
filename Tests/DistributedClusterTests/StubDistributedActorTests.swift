//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import DistributedActorsTestKit
import Foundation
import NIO
import XCTest

@testable import DistributedCluster

final class StubDistributedActorTests: SingleClusterSystemXCTestCase {
    func test_StubDistributedActor_shouldAlwaysResolveAsRemote() {
        let anyID = system.assignID(StubDistributedActor.self)

        let resolved = system._resolveStub(id: anyID)
        __isRemoteActor(resolved).shouldBeTrue()
    }
}
