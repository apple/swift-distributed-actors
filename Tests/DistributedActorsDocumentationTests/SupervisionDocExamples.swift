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

class SupervisionDocExamples {

    func example_spawn() throws {
        // tag::top_level_spawn[]
        let system = ActorSystem("ExampleSystem")

        let greeterBehavior: Behavior<String> = .receiveMessage { name in
            print("Hello \(name)!")
            return .same
        }

        let greeterRef: ActorRef<String> = try system.spawn(greeterBehavior, name: "greeter")

        greeterRef.tell("Caplin") // <>

        // "Hello Caplin!"
        // end::top_level_spawn[]
    }
}
