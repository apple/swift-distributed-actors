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

    let system = ActorSystem("ExampleSystem")

    func example_spawn() throws {

        // tag::supervise_props[]
        enum GreeterError: Error {
            case doesNotLike(name: String)
        }

        func isMyFriend(_ name: String) -> Bool {
            fatalError("undefined")
        }

        func greeterBehavior(friends: [String]) -> Behavior<String> {
            return .receive { context, name in

                guard isMyFriend(name) else {
                    context.log.warning("Overreacting to \(name)... Letting it crash!")
                    throw GreeterError.doesNotLike(name: name)
                }

                context.log.info("Hello \(name)!")
                return .same
            }
        }

        let friends = ["Caplin", "Kapi"]

        let props = Props().addSupervision(strategy: .restart(atMost: 5, within: .seconds(1))) // <1>
        let greeterRef: ActorRef<String> = try system.spawn(greeterBehavior(friends: friends), name: "greeter",
            props: props) // <2>

        greeterRef.tell("Caplin") // ok!
        greeterRef.tell("Beelzebub") // crash!
        // greeter is restarted
        greeterRef.tell("Kapi") // ok! 

        // end::supervise_props[]
    }
}
