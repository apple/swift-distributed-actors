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
import NIO
import XCTest

/// Base class to handle the repetitive setUp/tearDown code involved in most ActorSystem requiring tests.
// TODO: Document and API guarantees
open class ActorSystemXCTestCase: ClusteredActorSystemsXCTestCase {
    public var system: ActorSystem {
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

    public var logCapture: LogCapture {
        guard let handler = self._logCaptures.first else {
            fatalError("No log capture installed!")
        }
        return handler
    }

    open override func setUp() {
        super.setUp()
        _ = self.setUpNode(String(describing: type(of: self))) { _ in
            ()
        }
    }

    open override func tearDown() {
        super.tearDown()
    }

    open override func setUpNode(_ name: String, _ modifySettings: ((inout ActorSystemSettings) -> Void)?) async -> ActorSystem {
        await super.setUpNode(name) { settings in
            settings.cluster.enabled = false
            modifySettings?(&settings)
        }
    }
}
