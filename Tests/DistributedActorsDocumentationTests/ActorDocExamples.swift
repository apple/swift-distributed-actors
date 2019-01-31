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

class ActorDocExamples: XCTestCase {

    func example_spawn() throws {
        // tag::spawn[]
        let system = ActorSystem("ExampleSystem") // <1>

        let greeterBehavior: Behavior<String> = .receiveMessage { name in // <2>
            print("Hello \(name)!")
            return .same
        }

        let greeterRef: ActorRef<String> = try system.spawn(greeterBehavior, name: "greeter") // <3>

        greeterRef.tell("Caplin") // <4>

        // prints: "Hello Caplin!"
        // end::spawn[]
    }
}
