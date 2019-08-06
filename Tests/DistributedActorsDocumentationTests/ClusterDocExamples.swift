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

// tag::imports[]

import Swift Distributed ActorsActor

// end::imports[]

import XCTest
@testable import SwiftDistributedActorsActorTestKit

class ClusterDocExamples: XCTestCase {

    func example_receive_behavior() throws {
        // tag::joining[]
        let system = ActorSystem("ClusterJoining") { settings in 
            settings.cluster.enabled = true // <1>
            // system will bind by default on `localhost:7337`
        }

        let otherNode = Node(systemName: "ClusterJoining", host: "localhost", port: 8228)
        system.join(node: otherNode) // TODO not final API // <2>
        // TODO provide a proper API for this; perhaps system.tell(.cluster(.join)) or similar ?

        // end::joining[]
    }
}
