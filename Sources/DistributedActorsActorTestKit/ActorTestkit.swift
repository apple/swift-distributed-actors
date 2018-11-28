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


import NIOConcurrencyHelpers
import Swift Distributed ActorsActor

import XCTest

/// Contains helper functions for testing Actor based code.
/// Due to their asynchronous nature Actors are sometimes tricky to write assertions for,
/// since all communication is asynchronous and no access to internal state is offered.
///
/// The [[ActorTestKit]] offers a number of helpers such as test probes and helper functions to
/// make testing actor based "from the outside" code manageable and pleasant.
final public class ActorTestKit {

    private let system: ActorSystem

    private let testProbeNames = AtomicAnonymousNamesGenerator(prefix: "testProbe-")

    public init(_ system: ActorSystem) {
        self.system = system
    }

    // MARK: Test Probes

    /// Spawn an [[ActorTestProbe]] which offers various assertion methods for actor messaging interactions.
    public func spawnTestProbe<M>(name maybeName: String? = nil, expecting type: M.Type = M.self) -> ActorTestProbe<M> {
        let name = maybeName ?? testProbeNames.nextName()
        return .init(spawn: { b in try system.spawn(b, name: name) })
    }

}
