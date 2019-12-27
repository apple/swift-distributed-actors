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

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
import NIO
import XCTest

/// Base class to handle the repetitive setUp/tearDown code involved in most ActorSystem requiring tests.
class ActorSystemTestBase: ClusteredNodesTestBase {
    var system: ActorSystem {
        guard let node = self._nodes.first else {
            fatalError("No system spawned!")
        }
        return node
    }

    var eventLoopGroup: EventLoopGroup {
        self.system._eventLoopGroup
    }

    var testKit: ActorTestKit {
        self.testKit(self.system)
    }

    var logCapture: LogCapture {
        guard let handler = self._logCaptures.first else {
            fatalError("No log capture installed!")
        }
        return handler
    }

    override func setUp() {
        super.setUp()
        _ = self.setUpNode(String(describing: type(of: self))) { _ in
            ()
        }
    }

    override func tearDown() {
        super.tearDown()
    }

    override func setUpNode(_ name: String, _ modifySettings: ((inout ActorSystemSettings) -> Void)?) -> ActorSystem {
        super.setUpNode(name) { settings in
            settings.cluster.enabled = false
            modifySettings?(&settings)
        }
    }
}
