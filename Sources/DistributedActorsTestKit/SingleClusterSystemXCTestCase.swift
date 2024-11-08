//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsConcurrencyHelpers
@testable import DistributedCluster
import Foundation
import NIO
import XCTest

/// Base class to handle the repetitive setUp/tearDown code involved in most `ClusterSystem` requiring tests.
open class SingleClusterSystemXCTestCase: ClusteredActorSystemsXCTestCase {
    public var system: ClusterSystem {
        guard let node = self._nodes.first else {
            fatalError("No system spawned!")
        }
        return node
    }

    public var eventLoopGroup: EventLoopGroup {
        self.system._eventLoopGroup
    }

    public var testKit: ActorTestKit {
        self.testKit(self.system)
    }

    private var actorStatsBefore: InspectKit.ActorStats = .init()

    public var logCapture: LogCapture {
        guard let handler = self._logCaptures.first else {
            fatalError("No log capture installed!")
        }
        return handler
    }

    override open func setUp() async throws {
        try await super.setUp()
        _ = await self.setUpNode(String(describing: type(of: self)))
    }

    override open func tearDown() async throws {
        try await super.tearDown()
    }

    override open func setUpNode(_ name: String, _ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        await super.setUpNode(name) { settings in
            settings.enabled = false
            modifySettings?(&settings)
        }
    }
}
